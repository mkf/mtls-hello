# Implementation Plan: Bundle Spooling with Hash-Range Deduplication

**Branch**: main | **Date**: 2026-08-05 | **Spec**: [spec.md](./spec.md)

## Summary

The POST `/bundle` endpoint stops applying bundles to bare repos immediately. Instead, it saves them to a spool directory (`<data-dir>/spool/<repo>/`). The sender queries the peer's spool coverage before bundling to skip already-covered ranges. A `merge-spool.sh` script lets the operator apply accumulated bundles on demand. Backward compatible with old servers/senders.

## Technical Context

**Language/Version**: Bash (handlers + scripts), D (server endpoint routing only)

**Primary Dependencies**: `git bundle`, `git rev-list`, `git for-each-ref`

**Storage**: `<data-dir>/spool/<repo>/<from-sha>-<to-sha>.bundle` files

**Testing**: BATS — spool a bundle, verify file exists, run merge-spool.sh, verify refs

**Project Type**: New handler script + new merge script + on-discover.sh changes

**Constraints**: Backward compatibility with old servers and senders. No file-level concatenation.

## Constitution Check

Template — PASS by default.

## Project Structure

### Files changed

```text
handlers/bundle.post.sh     # REWRITE: spool instead of apply
handlers/spool.get.sh       # NEW: GET /spool?repo=name lists covered ranges
handlers/head.get.sh        # EXISTS: returns HEAD SHA (unchanged)
scripts/merge-spool.sh      # NEW: applies spooled bundles to bare repos
scripts/on-discover.sh      # UPDATE: query /spool before bundling
scripts/sync-common.sh      # UPDATE: add spool query helper
```

### Data flow

```
Sender (on-discover.sh):
  1. GET /spool?repo=name → peer returns covered ranges
  2. Compute uncovered ranges (local refs minus covered)
  3. git bundle create for each uncovered range
  4. POST /bundle?repo=name&from=abc&to=def → peer spools it

Receiver (bundle.post.sh):
  1. Read POST body to a temp file (.tmp suffix)
  2. Extract from/to SHA from query params or bundle list-heads
  3. Move temp file to spool/<repo>/<from>-<to>.bundle
  4. Return 200 (spooled, not applied)

Operator (merge-spool.sh):
  1. For each repo in spool/:
     a. List .bundle files sorted by from-sha
     b. For each bundle: git fetch into bare repo
     c. Promote branches (same logic as old bundle.post.sh)
     d. Delete spool file on success
```

## Design Decisions

### Why spool instead of immediate apply

Immediate application caused: concurrent push corruption, 400 errors from large bundles, no deduplication, no operator control. Spooling decouples receiving from applying.

### Why query params for from/to SHA

The sender knows the commit range it's bundling. Passing `from=abc&to=def` as query params lets the receiver name the file deterministically without parsing the bundle. If params are missing (old sender), the receiver extracts them from `git bundle list-heads`.

### Why `.tmp` suffix during write

The merge script might run while a bundle is being POSTed. Writing to `.tmp` and renaming atomically prevents the merge script from seeing partial files.

### Backward compatibility

- **New sender → Old server**: Old server's `bundle.post.sh` applies immediately. New sender's POST still works — it just doesn't get spooling. The sender doesn't check the response for "spooled" vs "applied".
- **Old sender → New server**: New server's `bundle.post.sh` spools. Old sender gets 200 and thinks it was applied. No breakage — the operator runs `merge-spool.sh` later.
- **No query params**: Old sender doesn't send `from`/`to`. New server computes them from `git bundle list-heads`.

### Hash range naming

`<from-sha>-<to-sha>.bundle` where `from-sha` is the parent of the first commit in the bundle and `to-sha` is the last commit. For a full branch bundle (no exclusion), `from-sha` is `0000...0000` (all zeros). This is deterministic: the same commit range always produces the same filename.

## Implementation Strategy

### MVP: Spool + Merge (US1 + US4)

1. Rewrite `bundle.post.sh` to spool
2. Create `merge-spool.sh`
3. Test: POST a bundle, verify spool file, run merge, verify refs

### Then: Coverage query (US2)

4. Create `spool.get.sh` handler
5. Update `on-discover.sh` to query `/spool?repo=name` before bundling

### Then: Smart sizing (US3)

6. Add consolidation/chunking logic to `on-discover.sh` using `git bundle create` with multiple refs or commit ranges
