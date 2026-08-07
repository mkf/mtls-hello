# Feature Specification: Codebase Simplification

**Feature Branch**: `026-codebase-simplification`

**Created**: 2026-08-07

**Status**: Draft

**Input**: User description: "We could do big improvement in making our codebase simpler. While maintaining all of the functionality stories. Probably wouldnt need to compromise on anything."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - All Features Still Work After Cleanup (Priority: P1)

An operator who relies on the system for mutual-TLS discovery, git sync, per-host drop-box, and NNCP packet relay upgrades to the simplified codebase. Every feature they depend on — multicast discovery, peer certificate capture and trust, git bundle sync, mod_dav drop-box, and the `/nncp/receive` endpoint — continues to work identically. No behavioral change is observable from the outside.

**Why this priority**: If any existing feature breaks, the simplification has negative value. This is the non-negotiable gate.

**Independent Test**: Run the full BATS + Robot Framework suite. Every test that passed before must pass after. Additionally, a live two-host mTLS round-trip (discovery → trust → drop-box PUT/GET → NNCP receive) completes successfully.

**Acceptance Scenarios**:

1. **Given** a system installed from the current codebase, **When** the operator upgrades to the simplified codebase, **Then** the discovery daemon finds peers, captures certificates, and fires the on-discovery.d/ callback chain exactly as before.
2. **Given** two trusted hosts, **When** one host pushes a git bundle and drops a file into the other's drop-box, **Then** both operations succeed with identical HTTP status codes and file layouts.
3. **Given** a peer sending an NNCP packet via `/nncp/receive`, **When** the packet is POSTed, **Then** the handler accepts it (202), runs `nncp-toss`, and the packet reaches its destination unchanged.

---

### User Story 2 - Developer Reads and Understands the Codebase Quickly (Priority: P2)

A developer who has never seen this project opens the repository. Within 15 minutes they can identify: what the D daemon does, what the shell scripts do, how Apache is configured, and where to find each feature's implementation. They do not encounter dead code, abandoned files, or duplicated logic that makes them ask "which of these five copies is the real one?"

**Why this priority**: The entire point of the simplification is to reduce cognitive load. If the developer experience doesn't improve measurably, the refactoring was wasted effort.

**Independent Test**: Count the number of source files, total lines, and duplication hotspots before and after. A developer can trace any user-facing feature (discovery, trust, sync, dropbox, NNCP) from entry point to completion without reading more than 3 files.

**Acceptance Scenarios**:

1. **Given** the simplified codebase, **When** a new developer opens the project, **Then** the file tree has no orphaned scripts, no dead D modules, and no duplicate implementations of the same logic.
2. **Given** a CGI handler that needs modification, **When** the developer looks for shared CGI boilerplate, **Then** they find a single sourced library — not five copy-pasted header-emission blocks.
3. **Given** a CLI wrapper that needs a new flag, **When** the developer opens the wrapper, **Then** they see the curl invocation inline with no duplicated argument-parsing or CN-extraction logic.

---

### User Story 3 - Maintainer Fixes a Bug in One Place (Priority: P3)

A maintainer discovers a bug in, for example, the certificate-fingerprint extraction logic. In the old codebase, the same logic was copy-pasted across `cgi-trust.sh`, `cgi-common.sh`, `drop-proxy.sh`, and `log-capture.sh`. In the simplified codebase, the maintainer edits one function in one file and the fix propagates everywhere.

**Why this priority**: Bug-fix velocity is the long-term ROI of simplification. This story validates that the consolidation actually happened, not just that lines were deleted.

**Independent Test**: For each shared concern (cert extraction, path resolution, CGI header emission, trust-store lookup), grep the codebase and confirm there is exactly one authoritative definition.

**Acceptance Scenarios**:

1. **Given** a shared concern like "extract peer CN from an X.509 certificate", **When** the maintainer greps for the implementation, **Then** they find exactly one function definition sourced by all callers.
2. **Given** a bug in the BLAKE2b digest computation, **When** the maintainer fixes it, **Then** the fix applies to both cert generation and the NNCP id derivation without editing a second file.

---

### Edge Cases

- What happens when a script that was consolidated had a subtle behavioral difference in one of its copies (e.g., different error message wording)? → The consolidated version must preserve the observable contract (exit code, output shape); message wording may change as long as the meaning is equivalent.
- What happens when a file is removed that an external system (systemd unit, Apache config, CI workflow) references by path? → The simplification must update all references; grep for every removed filename across the entire tree including `.github/`, `config/`, `justfile`, and `docker/`.
- What happens when a test file is simplified — does it lose coverage? → Each removed assertion must be traced to an equivalent assertion in the new test; net coverage must not decrease.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: All functionality delivered by specs 001–025 MUST remain operational after simplification. This includes: multicast discovery, peer certificate capture to purgatory, hostname-matched trust, on-discovery.d/ callback chain, git bundle creation and sync, mod_dav per-host drop-box, `/nncp/receive` endpoint, Ed25519/X25519 key generation, NNCP neighbor registration, and the install/systemd service setup.
- **FR-002**: The system's externally observable behavior MUST NOT change. This includes: HTTP response codes for every endpoint, CGI environment variables passed to handlers, the format of `nncp.hjson`, the directory layout under `--data-dir`, and the multicast announcement payload.
- **FR-003**: The full test suite (all BATS files + Robot Framework) MUST pass after simplification. No test may be deleted unless its assertions are covered by an equivalent or stricter test elsewhere.
- **FR-004**: Shared logic — CGI header emission, certificate/CN extraction, trust-store path resolution, base32/BLAKE2b helpers, and curl-common CLI boilerplate — MUST be consolidated into single sourced files. No copy-pasted implementations of the same algorithm may remain.
- **FR-005**: Dead code, orphaned files, and unused scripts MUST be removed. A file is "dead" if no other file sources, calls, references, or documents it AND no CI workflow, systemd unit, or Apache config invokes it.
- **FR-006**: Each remaining source file (D or shell) MUST have a single, clear responsibility describable in one sentence. Files that try to do multiple unrelated things must be split or merged.
- **FR-007**: The simplification MUST NOT introduce new runtime dependencies. The set of tools required at runtime (Apache, bash, openssl, git, the D daemon binary) remains identical.
- **FR-008**: Where the D daemon and shell scripts both implement the same concept (e.g., path resolution rules, hostname sanitization), the implementations MUST be consistent — not necessarily shared (different languages), but behaviorally identical.

### Key Entities

- **Feature Inventory**: The complete set of user-visible behaviors from specs 001–025. This is the regression baseline — nothing in this inventory may be lost.
- **Shared Library**: The set of sourced shell files (`cgi-common.sh`, `cgi-trust.sh`, `cleanup-common.sh`, `sync-common.sh`, `_common-cname.sh`) that provide cross-cutting functions. After simplification, each concern has exactly one home.
- **Dead Code Candidates**: Files and functions identified as unreferenced. These are the removal targets, subject to verification by the trace-and-grep rule in FR-005.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Total source lines (D + shell, excluding specs and tests) reduced by at least 15%. Measured as: `(before_total - after_total) / before_total ≥ 0.15`.
- **SC-002**: Number of source files (D + shell) reduced by at least 10%. Consolidation should merge near-duplicate scripts and remove orphans.
- **SC-003**: All existing BATS and Robot Framework tests pass with zero regressions. New tests added during the cleanup do not count as regressions.
- **SC-004**: For each of the top-5 duplication hotspots (cert extraction, CGI headers, path resolution, CLI curl boilerplate, sync state management), grep finds exactly one authoritative definition sourced by all callers.
- **SC-005**: A developer unfamiliar with the project can locate the implementation of any user-facing feature by reading no more than 3 source files, verified by a trace from entry point (daemon / Apache / CLI) to completion (handler / callback / file write).

## Assumptions

- The D daemon's role is stable: multicast discovery + outbound cert capture only. HTTP serving is permanently handled by Apache. No reversal of the Apache architecture decision.
- The shell scripts are the primary simplification target; the D code (898 lines) is already lean and may require only minor cleanup.
- The `specs/` directory is documentation, not source code — it is excluded from line-count metrics and is not a candidate for removal.
- The packaging scripts (`package-*.sh`, Docker files) are in scope for consolidation but must remain functional for CI release builds.
- "No compromise on anything" means all acceptance scenarios from prior specs must pass; it does NOT mean every internal implementation detail must be preserved — internal restructuring is explicitly desired.
- The test suite (`tests/` + `robot/`) is the regression oracle. If a test is overly coupled to implementation details (e.g., testing a specific filename rather than a behavior), the test may be updated to test the behavior instead.
