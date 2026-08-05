# Feature Specification: Bare-Repository Git Sync Between Peers

**Feature Branch**: `006-bare-repo-git-sync`

**Created**: 2026-08-05

**Status**: Draft

**Input**: User description: "Actually, I would like REPOS_ROOT to be full of git bare repositories. I want two hosts running the server to discover each other and sync all regular branches and new tags between each other. Even if the branches were diverged."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Two Hosts Sync Bare Repos End-to-End (Priority: P1)

Two hosts, each running the server with a `REPOS_ROOT` directory full of bare git repositories, discover each other over the LAN. On discovery, every repository is synchronized: all regular branches from each host are pushed to the other, and any tags that exist on one host but are missing on the other are also pushed. Critically, branches that have **diverged** (both hosts have unique commits on the same branch name) are not skipped and do not cause data loss — after sync, every host retains its own branches intact and also has access to every peer's version of every branch and tag.

**Why this priority**: This is the core feature — the entire intent of the change. Without it, the existing HEAD-based sync (feature 003) only handles non-diverged branches and works on working trees, not bare repos. The shift to bare repos with full branch/tag sync is the whole feature.

**Independent Test**: Create two sets of bare repositories under separate `REPOS_ROOT` trees with a mix of states (ahead, behind, diverged, new branches, missing tags), simulate a mutual discovery (by invoking the callback for each side with the other's context), and assert that after sync every branch from every host exists on every host, diverged branches are both preserved, and missing tags are pushed.

**Acceptance Scenarios**:

1. **Given** two hosts each with bare repos containing branches the other does not have, **When** they discover each other and sync, **Then** every branch from host A exists on host B and vice versa.
2. **Given** both hosts have a branch named `main` where host A is ahead of host B (host B's `main` is an ancestor of host A's), **When** they sync, **Then** host B's `main` fast-forwards to host A's `main`, and host A's `main` is unchanged.
3. **Given** both hosts have a branch named `feature` with diverged histories (each host has unique commits the other lacks), **When** they sync, **Then** both hosts retain their own `feature` branch intact AND also receive the other host's `feature` branch under a namespace that identifies which host it came from — **no commits are lost**.
4. **Given** host A has a tag that host B does not, **When** they sync, **Then** host B receives that tag pointing to the same commit.
5. **Given** both hosts already have the same tag pointing to the same commit, **When** they sync, **Then** the tag is not duplicated or overwritten.
6. **Given** one host has a repository the other does not, **When** they sync, **Then** that repository is skipped cleanly — no error, and other repositories sync normally.
7. **Given** a bare repo with no commits (just initialized), **When** the sync runs, **Then** that repository is skipped without error.

---

### User Story 2 - Repeated Syncs Are Idempotent (Priority: P2)

After an initial sync brings both hosts up to date, a second discovery (or periodic re-sync) must be a no-op — no duplicate refs are created, no conflicts arise, and the second run completes without errors or side effects.

**Why this priority**: In a real deployment, peers announce periodically (multicast interval). Sync fires on each announcement, so idempotency is necessary to avoid buildup of duplicate refs or unnecessary network traffic.

**Independent Test**: Run the sync twice in a row with the same repository state; assert the second run produces no new refs and exits cleanly.

**Acceptance Scenarios**:

1. **Given** two hosts are already fully in sync, **When** they sync again, **Then** no new refs appear and the operation completes without errors.
2. **Given** a diverged branch was already synced in a previous run, **When** another sync occurs, **Then** the peer's version of that branch is not duplicated (the existing remote-tracking ref is updated if the peer has new commits, or left alone if unchanged).

---

### Edge Cases

- **Empty bare repository** (no commits): skipped, no error.
- **Repository exists on only one host**: skipped by the host that lacks it; the host that has it pushes its refs to the peer (which creates it or handles the missing target).
- **Both hosts add the same new branch independently**: it arrives as two different remote-tracking refs (each host sees the other's version under the peer namespace).
- **Tag with the same name but different objects on each host**: the already-existent tag on the receiving side is **not** overwritten; the sender's version is available via the peer-namespace ref (planning detail).
- **Many repositories (1–100)**: each synced independently; one failing repository does not block others (unchanged from feature 003).
- **Large repository with many branches and tags**: syncs within a bounded time (no indefinite hanging).
- **Symlinked bare repos under REPOS_ROOT**: must work identically to non-symlinked bare repos (carrying forward feature 005's guarantee).
- **A host discovers multiple peers simultaneously**: each peer's refs are stored under distinct namespaces, preventing inter-peer collisions.
- **Branch names containing special characters** (slashes, dots, dashes): synced correctly as refs.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST support `REPOS_ROOT` directories containing bare git repositories (no working tree, only repository metadata — typically named `*.git` or initialized with `git init --bare`).
- **FR-002**: On discovery of a peer, the system MUST synchronize every repository present under `REPOS_ROOT` on both hosts.
- **FR-003**: ALL regular branches (`refs/heads/*`) MUST be included in the sync — not just a single selected branch or HEAD.
- **FR-004**: Tags (`refs/tags/*`) that exist on one host and are missing on the other MUST be pushed to the peer.
- **FR-005**: When a branch exists on both hosts with DIVERGED histories (each host has commits the other lacks), BOTH versions MUST be preserved. Each host retains its own branches under their original names and receives the peer's branches under a peer‑identifying namespace — no commits are discarded, no branch is skipped.
- **FR-006**: After a successful sync, every host MUST have access to every branch from every peer (its own branches at their original `refs/heads/*` paths; peer branches under a distinct namespace).
- **FR-007**: Repeated syncs with the same peer and the same refs MUST be idempotent — no duplicate refs are created, and the operation exits without errors.
- **FR-008**: The working-tree `REPOS_ROOT` layout from features 003/005 is REMOVED. Bare repositories are the ONLY supported layout for `REPOS_ROOT`. Existing callback/handler scripts and their automated tests MUST be updated to operate on bare repos and sync all branches/tags (not just HEAD).
- **FR-009**: The automated test suite MUST include a scenario where two simulated hosts (invoking callbacks for each direction) each have bare repos with a mix of ahead, behind, diverged, and exclusive branches plus missing tags, and after sync MUST assert:
  - All branches from both hosts exist on both hosts.
  - Diverged branches are both preserved.
  - Missing tags were pushed.
  - Sync completes without errors.
- **FR-010**: A repository that exists on one host but not the other MUST be skipped cleanly for that peer pairing (no error, other repositories unaffected).

### Key Entities

- **Bare Repository**: A git repository without a working tree, stored as a directory containing the repository data directly (the contents of `.git`). Named by convention, e.g., `alpha.git`.
- **Branch Set**: All `refs/heads/*` entries in a repository — every regular branch, not just a selected one.
- **Tag Set**: All `refs/tags/*` entries in a repository — lightweight and annotated tags.
- **Peer Namespace**: A ref namespace identifying which peer pushed a given branch, e.g., `refs/remotes/<hostname>/<branch>`. Ensures diverged branches do not collide and no commits are lost.
- **Discovery Event**: A peer announcement received via multicast (feature 002), triggering synchronization for all repositories under `REPOS_ROOT`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In 100% of test runs, every branch from each host is present on every other host after sync.
- **SC-002**: In 100% of test runs where branches are diverged, both versions of every diverged branch exist on every host — no commits are discarded.
- **SC-003**: In 100% of test runs, every tag missing on the peer before sync is present on the peer after sync.
- **SC-004**: The end-to-end sync test (bare repos, two simulated hosts, all branch/tag states) completes in under 60 seconds.
- **SC-005**: Running the sync twice with identical refs produces no additional refs and no errors.
- **SC-006**: All existing tests from features 001–005 that are unrelated to `REPOS_ROOT` (trust, discovery, handler dispatch, purgatory) continue to pass unchanged. Existing sync-demo tests are updated to use bare repos and must pass with the new all-branch/tag sync model.

## Assumptions

- Bare repositories are named with a `.git` suffix by convention (e.g., `alpha.git`), but the system resolves the repository identity from the directory basename (e.g., `alpha` from `alpha.git`).
- Discovery is simulated in tests by invoking the callback directly (multicast does not work on the loopback interface), continuing the pattern from features 003 and 005.
- Mutual sync (each host pushing to the other) is triggered by each host's discovery callback — both directions are covered without a separate coordination protocol.
- Diverged branches are preserved via a per-peer ref namespace (e.g., `refs/remotes/<hostname>/<branch>`). The exact namespace mapping is a planning/implementation detail.
- Tags that already exist on both hosts with the same name and same commit are idempotent. Tags with the same name but different commits: the receiving host's existing tag wins; the sender's differing tag is available through the peer namespace.
- The peer namespace is stable across syncs for the same peer — repeated syncs update the same remote-tracking refs, not create new ones.
- Empty bare repositories (no commits) produce no refs and are skipped without error.
- Repository provisioning (creating bare repos) is an operator concern and out of scope.
- Symlinked bare repos work identically, per feature 005's contract.
