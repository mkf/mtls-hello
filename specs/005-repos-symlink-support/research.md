# Research: REPOS_ROOT Symlinked Repositories

**Branch**: `005-repos-symlink-support` | **Date**: 2026-08-05 | **Feature**: [spec.md](./spec.md)

## Decision: Symlinked repository entries are a supported first-class layout

**Decision**: `REPOS_ROOT` entries may be either real directories or symlinks to directories stored elsewhere (absolute or relative targets; chains allowed). The existing handlers, callback, and demo flow operate on symlinked entries exactly as they do on real directories. No handler/callback/server code change is required.

**Rationale**:
- Empirical verification (performed during Phase 0 of this plan) confirmed git resolves symlinked repository directories correctly for every operation the flow uses:

  | Operation | Result through symlink |
  |---|---|
  | `git -C <entry> rev-parse HEAD` | correct HEAD returned |
  | `git -C <entry> bundle create <file> HEAD` | bundle created |
  | `git -C <entry> fetch <bundle> HEAD` + `merge --ff-only FETCH_HEAD` | fast-forward applied |
  | `git -C <entry> merge-base --is-ancestor` | correct ancestor check |
  | bash `for d in "$REPOS_ROOT"/*/; [ -d "$d" ]` | symlink-to-directory matched and reported as a directory |
  | symlink chain (`entry -> mid -> target`) | resolved correctly |

- `git -C` changes into the entry path; the OS resolves the symlink, so git operates on the real repository. No `realpath` preprocessing is needed.

**Alternatives considered**:
- Resolve symlinks to physical paths in the handlers (`realpath`) before invoking git — unnecessary complexity; git follows symlinks itself, and resolving would need care with relative targets and chains. Rejected.
- Rewrite/duplicate symlinked entries as real copies under `REPOS_ROOT` — defeats the purpose ("repos stored elsewhere"); rejected.
- Restrict `REPOS_ROOT` to real directories only — breaks the operator layout this feature explicitly supports; rejected.

## Decision: Broken symlink entries fail cleanly and in isolation

**Decision**: A broken or unresolvable symlink under `REPOS_ROOT` is treated as a missing/unavailable repository: HEAD lookup fails (handler exits non-zero → HTTP 500), bundle submission fails, and the discovery callback skips that entry with a log line. Other entries are unaffected.

**Rationale**:
- This falls out of existing behavior: `git -C` on a broken symlink fails immediately with a non-zero exit; the handlers' `set -euo pipefail` turns that into a failed invocation, and the callback's per-repo error handling (`|| { echo ...; skipped++; continue; }`) isolates it.
- No special-casing is required; the tests only need to assert the isolation.

**Alternatives considered**: Auto-remove or auto-repair broken symlinks — operator misconfiguration is not something the tooling should silently fix; rejected.

## Decision: The one real-world caveat is git's dubious-ownership protection

**Decision**: Document that git ≥ 2.35.2 refuses to operate on a repository whose owner differs from the invoking user (`safe.directory` / "detected dubious ownership"). Operators whose symlink targets live under another user's ownership must ensure ownership matches or configure `safe.directory`.

**Rationale**:
- This is a git security feature unrelated to symlinks per se, but it is the most likely real-world failure when repos are "stored elsewhere" under a different owner (e.g., a shared location).
- The automated tests run everything as one user, so they do not exercise this; documenting it prevents operator confusion.

**Alternatives considered**: Configure `safe.directory` globally from the handlers — mutates the operator's git configuration from server-side code; rejected (out of scope, documented instead).

## Decision: Test strategy

**Decision**: Two new BATS tests in `tests/smoke.bats`:

1. **US1 — fully symlinked demo**: Reuse the existing `mkfixture` machinery but create the real repositories in a separate directory and symlink each entry into both `local/` and `peer/` `REPOS_ROOT` trees. Run the demo exactly as the existing US2 test (one live server playing the peer side, callback simulated locally) and assert the identical invariants: `alpha`/`beta` reach local HEADs (bundle pushed), `gamma` skipped (in sync), `delta` untouched (diverged).
2. **US2 — broken symlink isolation**: One broken symlink among healthy entries; run the callback; assert healthy entries sync and the broken entry is skipped without affecting the others.

**Rationale**:
- The existing demo already exercises the full contract; the symlinked variant is the strongest proof that the layout is first-class (both sides fully symlinked).
- Keeping the existing real-directory test as-is provides regression coverage for the unchanged layout.

**Alternatives considered**: Parametrize the existing demo test over layout — more invasive to the existing passing test; a dedicated test keeps the real-directory baseline untouched. Rejected.

## Decision: No new CLI, config, or server surface

**Decision**: No new options, environment variables, or D code. `REPOS_ROOT` semantics are unchanged; this feature adds test coverage and contract documentation for the symlinked layout.

**Rationale**: The feature request is "make REPOS_ROOT tested to work even if subdirs there are all symlinked" — the verification is the deliverable. Adding config surface would violate YAGNI.
