# Implementation Plan: REPOS_ROOT Symlinked Repositories

**Branch**: `005-repos-symlink-support` | **Date**: 2026-08-05 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/005-repos-symlink-support/spec.md`

## Summary

`REPOS_ROOT` (feature 003) must work — and be covered by an automated test — when the repository entries under it are **symlinks pointing to repositories stored elsewhere**. Empirical verification (this plan's Phase 0) shows git already resolves symlinked repository directories correctly for every operation the flow uses: `rev-parse HEAD`, `bundle create`, `fetch <bundle>`, `merge --ff-only`, `merge-base --is-ancestor`, and bash glob iteration (`"$REPOS_ROOT"/*/` includes symlinks-to-directories, and `[ -d ]` is true for them). Symlink chains also resolve. Therefore the feature is primarily **test coverage + contract documentation**:

1. A BATS test (US1) that runs the full multi-repo sync demo with every `REPOS_ROOT` entry (both sides) symlinked to repositories stored in a separate directory, asserting the exact same invariants as the existing real-directory demo.
2. A BATS test (US2) with a broken symlink among healthy entries, proving clean failure isolation.
3. A contract (`contracts/repos-layout.md`) documenting the supported layout, resolution rules, and the one real-world caveat (git's `safe.directory` dubious-ownership protection).
4. Onboarding documentation (`quickstart.md`).

No handler, callback, or server code change is expected; if a test surfaces a gap, the fix is confined to the bash handlers/callback (e.g., resolving the entry path), not the D server.

## Technical Context

**Language/Version**: D — LDC 1.27.1 via Guix (unchanged from features 001–004).

**Primary Dependencies**: git (test-only, already a dev dependency since feature 003), bash handlers/callback (`handlers/head.get.sh`, `handlers/bundle.post.sh`, `scripts/on-discover.sh` — unchanged). No new runtime dependencies.

**Storage**: Filesystem — the `REPOS_ROOT` tree whose entries may be real directories or symlinks to directories elsewhere. No database.

**Testing**: BATS (`tests/smoke.bats`). New tests: US1 symlinked-layout sync demo (reuses the existing `mkfixture` machinery, symlinking entries to repos stored in a separate directory); US2 broken-symlink isolation. Existing 20 tests must keep passing.

**Target Platform**: Linux (x86_64), LAN-connected hosts. Deployed via `guix shell -f guix.scm` (unchanged).

**Project Type**: web-service (HTTPS server, single binary) with operator shell-script endpoints and a git-sync callback demo (unchanged).

**Performance Goals**: LAN scale — a handful of repositories, low request rate. Symlink resolution is performed by the OS/git and adds no measurable overhead.

**Constraints**: Git ≥ 2.35.2 refuses to operate on repositories whose owner differs from the invoking user (`safe.directory` "dubious ownership"). If a symlink target lives under another user's ownership, git errors — this is an operator-environment concern, not a code bug; it is documented in the contract and quickstart. The test environment runs everything as one user, so tests are unaffected. Entry resolution must not change feature-003 semantics (no new path-escape surface).

**Scale/Scope**: `tests/smoke.bats` (new BATS tests reusing `mkfixture`; expected ~60–100 lines), plus documentation: `research.md`, `data-model.md`, `contracts/repos-layout.md`, `quickstart.md`. Expected D code changes: none (only if a test uncovers a real gap in the bash handlers).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- `.specify/memory/constitution.md` is an unfilled template — no named principles or binding gates exist.
- **Result: PASS** (no gate violations possible). Re-checked after Phase 1: no new gates introduced; still PASS.

## Project Structure

### Documentation (this feature)

```text
specs/005-repos-symlink-support/
├── plan.md              # This file
├── research.md          # Phase 0 output — empirical verification + decisions
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output — symlinked REPOS_ROOT onboarding/troubleshooting
├── contracts/           # Phase 1 output
│   └── repos-layout.md  # REPOS_ROOT layout contract: symlink semantics + caveats
└── tasks.md             # Phase 2 output (/speckit.tasks — NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
source/
├── app.d               # wiring — unchanged
├── trust.d             # trust store (feature 004) — unchanged
├── handlers.d          # script endpoints (feature 003) — unchanged
└── multicast.d         # discovery (feature 001) — unchanged

handlers/
├── head.get.sh         # REPOS_ROOT HEAD lookup — unchanged (verified to work via symlinks)
└── bundle.post.sh      # REPOS_ROOT bundle apply — unchanged (verified to work via symlinks)

scripts/
├── on-discover.sh      # discovery callback iterating REPOS_ROOT — unchanged (verified)
└── gen_certs.sh        # PKI generation — unchanged

tests/
└── smoke.bats          # extended: symlinked-layout demo (US1) + broken-symlink isolation (US2)
```

**Structure Decision**: No structural change. The feature is test + documentation; the existing single-binary layout and bash handlers are retained because empirical verification shows they already handle symlinked entries. If a test gap appears, the fix is confined to the relevant bash handler/callback.

## Complexity Tracking

> No constitution violations. No complexity justifications required.
