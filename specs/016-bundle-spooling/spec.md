# Feature Specification: Bundle Spooling with Hash-Range Deduplication

**Feature Branch**: main (inline)

**Created**: 2026-08-05

**Status**: Draft

**Input**: The bundle-accepting endpoint should spool bundles instead of applying them immediately. Bundles are identified by deterministic hash ranges (commit SHA ranges) and stored in a spool directory under the data directory. The bundler queries the peer to check if a range is already covered before sending. Bundle sizes should be optimized: not too small (consolidate when possible), chunked when exceeding 10MB. A user-invoked script merges accumulated bundles from the spool directory.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Bundles Are Spooled, Not Applied Automatically (Priority: P1)

A sender pushes a bundle to a peer. The peer's server receives the bundle via the POST endpoint. Instead of applying the bundle to the bare repository immediately (which was problematic with concurrent access, 400 errors, and unbounded growth), the server saves the bundle to a spool directory under the data directory. The bundle file is named after the commit range it covers (e.g., `<repo>/<from-sha>-<to-sha>.bundle`). The sender receives a confirmation that the bundle was spooled, not that it was applied.

**Why this priority**: Immediate application causes concurrency issues (two peers pushing simultaneously corrupt refs), makes error recovery difficult (half-applied bundles), and provides no deduplication. Spooling is the prerequisite for all other stories.

**Independent Test**: POST a bundle to a server, verify it creates a file in `<data-dir>/spool/<repo>/` named by the commit range, and the bare repository is NOT modified.

**Acceptance Scenarios**:

1. **Given** a server with a bare repository for "laptops", **When** a peer POSTs a bundle covering commits `abc..def` for repo "laptops", **Then** the file `<data-dir>/spool/laptops/abc-def.bundle` exists and `refs/heads/main` in the bare repo is unchanged.
2. **Given** a spooled bundle already exists for a range, **When** the same range is POSTed again, **Then** the existing file is overwritten (the bundle is idempotent).

---

### User Story 2 - Bundler Queries Coverage Before Sending (Priority: P1)

Before creating a bundle, the sender queries the peer's spool directory via an HTTP endpoint (`/spool?repo=name`) to determine which commit ranges are already covered. The sender then only bundles commits that the peer doesn't already have (or has pending). This eliminates redundant transfers and CPU for already-covered ranges.

**Why this priority**: Without coverage queries, every discovery cycle re-bundles and re-sends the same content even when the peer already has it. The HEAD check partially addresses this but only covers the tip commit, not intermediate ranges.

**Independent Test**: After syncing, run the bundler again; it queries `/spool?repo=name`, sees all ranges covered, and sends nothing.

**Acceptance Scenarios**:

1. **Given** the sender has commits `A-B-C-D` and the peer's spool indicates range `B-C` is covered, **When** the sender's bundler runs, **Then** it bundles `C-D` only.
2. **Given** the peer's spool covers all commits, **When** the sender's bundler runs, **Then** it sends zero bundles.

---

### User Story 3 - Smart Bundle Sizing via Git-Only Operations (Priority: P2)

The bundler sizes bundles using only `git bundle create` operations: multiple small branches can be bundled together in a single `git bundle create ref1 ref2 --tags` call, and very large histories are split by incrementally bundling commit ranges (e.g., `git bundle create out.bundle main ^already-covered-commit --tags`). No file-level concatenation or splitting is used.

**Why this priority**: Too-small bundles waste round-trips; too-large bundles hit size limits. Predictable ranges ensure the spool directory doesn't accumulate duplicate bundles of the same range from different senders or restart attempts.

**Independent Test**: Run the bundler with a mix of tiny and large repos; verify bundles are between 500KB and 10MB, and re-running the bundler with no changes produces bundles with the same range identifiers as before.

**Acceptance Scenarios**:

1. **Given** three branches with 200KB each, **When** the bundler runs, **Then** a single `git bundle create branch1 branch2 branch3 --tags` call produces one combined bundle.
2. **Given** a branch with 25MB of history, **When** the bundler runs, **Then** the history is sent in incremental ranges (e.g., `bundle create main ^midpoint --tags`), each under 10MB.
3. **Given** the same commit range, **When** the bundler runs again, **Then** the bundle is named with the same hash range as before (predictable).

---

### User Story 4 - User Merges Spooled Bundles (Priority: P2)

The operator runs a script (`scripts/merge-spool.sh`) that processes the spool directory: for each repo, it applies all spooled bundles to the bare repository in commit-topology order, merging branches where possible and preserving divergent branches. After successful application, the spooled bundle files are deleted. The script reports which bundles were applied and which were skipped (already merged, or missing dependencies).

**Why this priority**: The operator must have control over when bundles are applied — the server should never modify bare repositories without explicit user action. This prevents race conditions and allows the operator to review before merging.

**Independent Test**: Spool several bundles, run the merge script, verify the bare repository's refs are updated correctly and the spool files are cleaned up.

**Acceptance Scenarios**:

1. **Given** spooled bundles for "laptops" covering `A-B`, `B-C`, `C-D`, **When** `merge-spool.sh` runs, **Then** `refs/heads/main` is updated to `D` and all three spool files are deleted.
2. **Given** a spooled bundle whose parent commit is not present locally, **When** `merge-spool.sh` runs, **Then** that bundle is skipped with a clear message ("missing parent commit X").
3. **Given** two spooled bundles for the same range from different peers, **When** `merge-spool.sh` runs, **Then** the first is applied and the duplicate is skipped.

---

### Edge Cases

- Spool directory does not exist yet — the server creates it on first use.
- Bundle POSTed with no hash-range query parameter — the server computes the range from the bundle's list-heads and names it accordingly.
- Two peers spool overlapping ranges — the merge script handles this by applying in topological order.
- Disk full during spool write — the server returns 507 (Insufficient Storage) and does not write a partial file.
- Merge script run while a bundle is being POSTed — the merge script skips files being written (uses a `.tmp` suffix during write, renames on completion).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The POST `/bundle` endpoint MUST save the bundle to `<data-dir>/spool/<repo>/<from-sha>-<to-sha>.bundle` instead of applying it to the repository.
- **FR-002**: The server MUST expose a GET `/spool?repo=<name>` endpoint that lists covered commit ranges from the spool directory for that repo.
- **FR-003**: The bundler (on-discover.sh) MUST query the peer's `/spool?repo=name` before bundling to avoid sending already-covered ranges.
- **FR-004**: The bundler MUST use only `git bundle create` operations for all bundling. Small branches MAY be consolidated via `git bundle create ref1 ref2 --tags`. Large histories MAY be split via incremental `git bundle create main ^cutoff --tags`. No file-level concatenation or splitting is used.
- **FR-005**: Bundle file names MUST be deterministic for a given commit range (`<from-sha>-<to-sha>.bundle`), enabling deduplication.
- **FR-006**: A `scripts/merge-spool.sh` script MUST apply all spooled bundles to their respective bare repositories in topological order and clean up applied bundles.
- **FR-007**: The spool directory MUST be created under the data-dir in a `spool/` subdirectory.
- **FR-008**: Bundles being written MUST use a `.tmp` suffix and be renamed atomically on completion to prevent the merge script from processing partial files.
- **FR-009**: The merge script MUST skip bundles whose parent commit is not present locally, reporting them clearly.
- **FR-010**: The new spooling behavior MUST maintain backward compatibility with servers running the old (immediate-apply) bundle handler. A new sender talking to an old server should still work (the old server applies the bundle immediately). An old sender talking to a new server should also work (the new server spools the bundle, even though the old sender expects immediate application).

### Key Entities

- **Spool directory**: `<data-dir>/spool/<repo>/` containing `.bundle` files named by commit range.
- **Bundle range**: A pair of commit SHAs (`from-sha` and `to-sha`) identifying the commit range covered by a bundle.
- **Coverage query**: A GET request listing which ranges are already covered (spooled or applied) for a given repo.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After syncing, re-running the discovery cycle sends zero bundles (all ranges covered).
- **SC-002**: The merge script successfully applies all spooled bundles and deletes them, leaving the bare repository with the expected refs.
- **SC-003**: Bundles are created exclusively via `git bundle create` with refs or commit ranges; no file-level concatenation or splitting is used.
- **SC-004**: The same commit range always produces the same bundle file name across multiple discovery cycles.

## Assumptions

- The server's data directory is writable by the mtls-hello process.
- The operator runs `merge-spool.sh` periodically or on-demand; bundles accumulate until merged.
- The bare repository is NOT modified by the server process; only merge-spool.sh writes to it.
- Commit SHAs are unique and immutable (standard git property).
