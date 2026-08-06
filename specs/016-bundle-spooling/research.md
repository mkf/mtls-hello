# Research: Bundle Spooling with Hash-Range Deduplication

## Decision: Spool to `<data-dir>/spool/<repo>/` with deterministic filenames

**Decision**: Bundle files are stored at `<data-dir>/spool/<repo>/<from-sha>-<to-sha>.bundle`.

**Rationale**: Deterministic filenames enable deduplication — the same commit range from different senders or repeated discovery cycles produces the same file, which is simply overwritten. The spool directory is under the data-dir, which is already used for handlers and scripts.

**Alternatives considered**:
- UUID-based filenames — no deduplication, accumulates duplicates
- Timestamp-based filenames — no deduplication, hard to identify coverage
- Sender-hostname-prefixed filenames — prevents deduplication between senders

## Decision: Compute from/to SHA from query params, fall back to bundle parsing

**Decision**: The POST `/bundle?repo=name&from=abc&to=def` passes the range explicitly. If `from`/`to` are missing, the receiver runs `git bundle list-heads` to extract the tip SHA and `git log --oneline` to find the parent.

**Rationale**: The sender knows the range it bundled. Passing it as query params is simpler and faster than parsing the bundle on the receiver. The fallback ensures backward compatibility with old senders.

**Alternatives considered**:
- Always parse the bundle — slower, requires git on the receiver during POST
- Store bundles without range info — can't deduplicate, can't query coverage

## Decision: Atomic write with `.tmp` suffix

**Decision**: Write to `<from>-<to>.bundle.tmp`, then `mv` to `<from>-<to>.bundle`.

**Rationale**: Prevents the merge script from processing partial files. The `mv` is atomic on the same filesystem.

## Decision: `merge-spool.sh` reuses old bundle.post.sh logic

**Decision**: The merge script extracts the fetch-and-promote logic from the old `bundle.post.sh` and applies it to each spooled bundle in topological order.

**Rationale**: The old logic (fetch into per-peer namespace, promote to refs/heads) is proven. Moving it to a user-invoked script just changes WHEN it runs, not HOW.

## Decision: GET `/spool?repo=name` returns plain text list of ranges

**Decision**: The spool endpoint returns one range per line: `from-sha to-sha`. Simple, parseable by `on-discover.sh` with `grep`/`awk`.

**Rationale**: No JSON parsing needed in the shell script. The format is trivial to produce (list filenames in the spool dir) and consume (grep for coverage).

## Decision: Backward compatibility via response-agnostic POST

**Decision**: The sender doesn't check whether the response says "spooled" or "applied" — it just checks for HTTP 200. Old servers return "ok" (applied), new servers return "spooled" — both are 200.

**Rationale**: Simplest compatibility approach. The sender doesn't need to know the receiver's capability.
