# Implementation Plan: Bare-Repository Git Sync Between Peers

**Branch**: `006-bare-repo-git-sync` | **Date**: 2026-08-05 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/006-bare-repo-git-sync/spec.md`

## Summary

Replace the feature-003 working-tree-based, HEAD-comparison git sync model with **bare repositories** and **all-branch/all-tag sync** between discovered peers. On discovery, each host creates a `git bundle --all` for every bare repo and POSTs it to the peer. The receiver force-fetches branches into a per-peer remote-tracking namespace (`refs/remotes/<peer-hostname>/*`), then promotes fast-forwardable and missing branches to `refs/heads/*`. Diverged branches are preserved in the per-peer namespace, so no commits are discarded and no branch is skipped. Tags are fetched without force (conflicts skipped). Transport uses the existing HTTP POST mechanism (git bundle, no git-smart-http needed). Working-tree layout from features 003/005 is removed.

## Technical Context

**Language/Version**: D — LDC 1.27.1 via Guix (unchanged). No D code changes expected.

**Primary Dependencies**: git (bundle create, fetch with refspecs), bash (handlers/callback rewritten), curl (unchanged transport). Existing vibe-d / OpenSSL stack unchanged.

**Storage**: Filesystem — `REPOS_ROOT` directory containing bare git repositories (`*.git`). No database.

**Testing**: BATS (`tests/smoke.bats`). Replace the 003 US2 working-tree demo with a bare-repo multi-branch/tag sync test; adapt 005 symlink test for bare repos; add idempotency test. Existing tests from features 001–004 (trust, discovery, handlers, purgatory) unchanged.

**Target Platform**: Linux (x86_64), LAN-connected hosts. Deployed via `guix shell -f guix.scm` (unchanged).

**Project Type**: web-service (HTTPS server, single binary) with operator shell-script endpoints (unchanged).

**Performance Goals**: LAN scale — a handful of repositories, each with reasonable branch/tag counts. `git bundle --all` of a typical repo takes <1 second. Sync of 10 repos x ~5 branches completes in seconds.

**Constraints**: Working-tree `REPOS_ROOT` layout is **removed** — bare repos only. Existing sync-demo tests must be replaced, not broken. Symlink contract (feature 005) carries forward for bare repos.

**Scale/Scope**: Rewrite `handlers/bundle.post.sh` and `scripts/on-discover.sh`; replace 3–4 BATS tests; new contracts and docs. Expected ~80 lines of bash and ~150 lines of BATS; 0 lines of D.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- `.specify/memory/constitution.md` is an unfilled template — no named principles or binding gates exist.
- **Result: PASS** (no gate violations possible). Re-checked after Phase 1: no new gates introduced; still PASS.

## Project Structure

### Documentation (this feature)

```text
specs/006-bare-repo-git-sync/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   └── bare-sync.md     # Bare-repo sync protocol
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (repository root)

```text
handlers/
├── bundle.post.sh       # REWRITTEN: bare repo + namespace-mapped refs
└── head.get.sh          # REMOVED (HEAD comparison no longer needed)

scripts/
├── on-discover.sh       # REWRITTEN: bare repos + git bundle --all + push-everything
└── gen_certs.sh         # unchanged

tests/
└── smoke.bats           # replaced: working-tree demo → bare-repo multi-branch/tag sync
                         # adapted: symlinked tests (bare repos)
                         # added: idempotency test
```

**Structure Decision**: No structural change to the D server. The sync logic lives in bash scripts per the design intent from features 002/003. `head.get.sh` is removed — the new callback pushes everything unconditionally without comparing HEADs.

## Complexity Tracking

> No constitution violations. No complexity justifications required.
