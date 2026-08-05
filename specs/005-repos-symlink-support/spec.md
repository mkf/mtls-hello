# Feature Specification: REPOS_ROOT Symlinked Repositories

**Feature Branch**: `005-repos-symlink-support`

**Created**: 2026-08-05

**Status**: Draft

**Input**: User description: "make REPOS_ROOT tested to work even if subdirs there are all symlinked from elsewhere"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Multi-Repo Sync Works With Fully Symlinked REPOS_ROOT (Priority: P1)

An operator lays out their repositories so that the entries under `REPOS_ROOT` are not real directories but **symlinks pointing to repositories stored elsewhere** (e.g., `REPOS_ROOT/alpha -> /srv/git/alpha`). This is a common arrangement when repositories live in a shared or separately managed location. The multi-repo synchronization flow — HEAD lookup, bundle submission, and the discovery-triggered callback — must behave identically to the real-directory case: ahead repositories are pushed, in-sync repositories are skipped, and diverged repositories are left untouched.

**Why this priority**: The whole point of `REPOS_ROOT` is to be a configurable collection of repositories. Symlinked entries are a legitimate, already-present way to assemble that collection; if the flow breaks for them, operators cannot use the sync feature with their existing layout. The value is a working sync for the symlinked layout, proven by an automated test.

**Independent Test**: Run the automated sync demo with every repository entry under `REPOS_ROOT` (on both the local and peer sides) replaced by a symlink to a repository stored in a separate directory, and assert the exact same invariants as the existing real-directory demo (ahead → synced, in-sync → skipped, diverged → untouched). Delivers value by proving the symlinked layout is a first-class configuration.

**Acceptance Scenarios**:

1. **Given** `REPOS_ROOT` where every repository entry is a symlink to a repository stored elsewhere, **When** the discovery callback runs for each repository, **Then** every repository where the local side is ahead ends with the peer's repository advanced to the local HEAD.
2. **Given** a symlinked repository where both sides already share the same HEAD, **When** the callback runs, **Then** no bundle is sent for that repository.
3. **Given** a symlinked repository where the histories have diverged, **When** the callback runs, **Then** no bundle is sent and the peer's repository is unchanged.
4. **Given** a symlinked repository, **When** a peer requests its HEAD via the HEAD endpoint, **Then** the repository's actual HEAD is returned.
5. **Given** a symlinked repository on the receiving side, **When** a bundle is submitted for it, **Then** the repository fast-forwards to the bundle's HEAD.

---

### User Story 2 - Broken Symlink Targets Fail Cleanly (Priority: P2)

An operator has a `REPOS_ROOT` entry whose symlink points at a location that is temporarily unavailable or was never created (a broken symlink). The sync flow must not corrupt other repositories or hang the whole run: the affected repository is reported as failed/skipped with a clear log message, and every other repository is processed normally.

**Why this priority**: Robustness against a misconfigured or transiently unavailable entry — one bad link should not take down synchronization for the whole collection. Lower priority than the primary working case, but cheap to verify alongside it.

**Independent Test**: Create `REPOS_ROOT` with one broken symlink among healthy repositories (real dirs or valid symlinks), run the callback, and verify the healthy repositories sync while the broken entry is skipped without affecting them.

**Acceptance Scenarios**:

1. **Given** a `REPOS_ROOT` containing a broken symlink and at least one healthy repository, **When** the callback runs, **Then** the healthy repositories sync normally and the broken entry is reported as failed/skipped.
2. **Given** a broken symlink entry, **When** a HEAD lookup or bundle submission targets it, **Then** the request fails with a clear error and no other repository is affected.

---

### Edge Cases

- **Broken symlink under REPOS_ROOT**: treated as a missing/unavailable repository — not synced, logged, other repositories unaffected.
- **Symlink chain** (symlink → symlink → repository): must resolve like a direct symlink.
- **Mixed layout**: some real directories and some symlinks under the same `REPOS_ROOT` — each entry is handled independently.
- **Relative symlink targets** (e.g., `REPOS_ROOT/alpha -> ../git/alpha`): must resolve correctly relative to their location.
- **REPOS_ROOT itself is a symlink**: must behave identically to a real directory containing repo entries.
- **Symlink pointing to a diverged repository**: no bundle is sent (unchanged semantics).
- **Repository identifier that resolves outside REPOS_ROOT** (e.g., traversal): must not become newly reachable because of symlinks; behavior is unchanged from feature 003.
- **Symlinked repository that is already in sync**: skipped, no bundle sent.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST resolve a repository entry under `REPOS_ROOT` to its actual repository when the entry is a symlink pointing to a repository stored elsewhere.
- **FR-002**: HEAD lookups MUST operate on the resolved repository of a symlinked entry and return that repository's current HEAD.
- **FR-003**: Bundle submission MUST fast-forward the resolved repository of a symlinked entry, with the same success/failure semantics as a real directory.
- **FR-004**: The discovery callback MUST enumerate symlinked repository entries and classify each (ahead → push, in-sync → skip, diverged → skip) identically to real directories.
- **FR-005**: A broken or unresolvable symlink entry MUST fail cleanly (the affected repository is not synced and is logged) and MUST NOT block or corrupt other repositories.
- **FR-006**: Both absolute and relative symlink targets MUST be supported.
- **FR-007**: Mixed layouts (real directories and symlinks in the same `REPOS_ROOT`) MUST work, with each entry handled independently.
- **FR-008**: The automated test suite MUST include a scenario in which every repository entry under `REPOS_ROOT` (on both sides of the demo) is a symlink to a repository stored elsewhere, and MUST assert the same invariants as the existing non-symlinked sync demo.
- **FR-009**: The automated test suite MUST include the broken-symlink scenario described in User Story 2.
- **FR-010**: Existing behavior with real directories under `REPOS_ROOT` MUST remain unchanged (no regression).

### Key Entities

- **REPOS_ROOT layout**: The root collection directory. Each entry is a repository reference: either a real directory or a symlink to a directory stored elsewhere.
- **Repository (per side)**: An independent version-controlled repository tracked for synchronization, identified by its entry name under `REPOS_ROOT` (unchanged from feature 003).
- **Symlink target**: An external directory (outside `REPOS_ROOT`) containing a repository working tree; the actual location the sync operates on.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In 100% of test runs with a fully symlinked `REPOS_ROOT`, the sync outcome matches the real-directory demo exactly: every ahead repository ends synced, every in-sync repository is skipped, and every diverged repository is untouched.
- **SC-002**: In 100% of test runs, HEAD lookups and bundle submissions succeed through symlinked repository entries.
- **SC-003**: In 100% of test runs with a broken symlink present, healthy repositories still sync and the broken entry is skipped without errors on other repositories.
- **SC-004**: The symlinked-layout test completes in under 60 seconds.
- **SC-005**: The existing real-directory sync demo continues to pass unchanged (no regression).

## Assumptions

- Symlink targets are standard (non-bare) repository working trees with their own version-control metadata, matching the repositories used by the feature-003 demo.
- Symlink targets are on the same host and accessible to the server and callback processes; network-mounted or inaccessible targets are treated like broken symlinks (fail cleanly).
- The symlinked-layout test applies to both the local and peer `REPOS_ROOT` sides (the strongest case); mixed layouts are also exercised where practical.
- Broken symlinks are operator misconfiguration or transient unavailability; there is no automatic recovery or repair.
- Repository entry naming and identifier validation are unchanged from feature 003; this feature must not introduce new ways to address paths outside `REPOS_ROOT`.
- `REPOS_ROOT` itself may be a symlink; this is supported at no extra cost.
