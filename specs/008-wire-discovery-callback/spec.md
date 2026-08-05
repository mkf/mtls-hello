# Feature Specification: Wire Discovery Callback

**Feature Branch**: `008-wire-discovery-callback`

**Created**: 2026-08-05

**Status**: Implemented

**Input**: User description: "wire the multicast discovery callback to actually execute scripts/on-discover.sh when a peer is discovered"

## Clarifications

### Session 2026-08-05

- Q: Where should on-discover.sh live after `just install`? → A: Copy `scripts/on-discover.sh` to `~/.local/share/mtls-hello/scripts/` during install. Add `CALLBACK_SCRIPT` env var.
- Q: What is the default CALLBACK_SCRIPT path, and how does it work in production? → A: There is no default. The binary has no hardcoded path. If `CALLBACK_SCRIPT` is unset, the discovery callback is disabled (warning logged). The operator must set it explicitly.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Discovered Peer Triggers Sync (Priority: P1)

An operator runs two mtls-hello instances on the same LAN with REPOS_ROOT configured. When either instance discovers the other via multicast, it should automatically run `scripts/on-discover.sh` to push all its repos to the peer. No manual invocation required.

**Why this priority**: Without this, the multicast discovery infrastructure (features 001/002) exists but does nothing useful — peers are discovered but never sync. The `on-discover.sh` script and all git-sync features (003, 006) are unreachable through the normal discovery path.

**Independent Test**: Start two servers (or simulate a discovery event via BATS), verify that the callback script is invoked with the correct environment variables (HOST_NAME, PEER_NETLOC, PEER_CERT_FILE, OUR_CERT, OUR_KEY, REPOS_ROOT) and that repos are pushed.

**Acceptance Scenarios**:

1. **Given** two servers with HOST_NAME and REPOS_ROOT configured, **When** server A discovers server B via multicast, **Then** `scripts/on-discover.sh` is spawned with the correct env vars and A's repos appear on B.
2. **Given** a discovered peer whose certificate is absent from the trust store, **When** the callback runs, **Then** the callback fails cleanly (curl returns non-zero, callback logs "push failed"), and the server continues running unaffected.
3. **Given** the callback script is missing or not executable, **When** a peer is discovered, **Then** the server logs a warning and continues (the discovery loop is not interrupted).

---

### User Story 2 - Hostname Announced in Multicast (Priority: P2)

When a server announces itself on the multicast group, it includes its hostname so that peers can look up its certificate in their trust store.

**Why this priority**: The callback needs PEER_CERT_FILE to pin the peer's certificate. Without the hostname in the announcement, the receiving side cannot construct the cert path `<trustDir>/<hostname>.crt`.

**Independent Test**: Capture a multicast announcement packet, verify it contains a `host` field with the server's configured hostname.

**Acceptance Scenarios**:

1. **Given** a server started with `HOST_NAME=alpha`, **When** it sends a multicast announcement, **Then** the JSON payload contains `"host": "alpha"`.
2. **Given** a server started without `HOST_NAME` set, **When** it sends an announcement, **Then** the `host` field defaults to `"localhost"` (so basic functionality works out of the box).

---

### User Story 3 - Non-Blocking Callback Execution (Priority: P3)

The callback script is spawned as a separate process and does not block the multicast discovery loop. Multiple peers can be discovered in rapid succession without queuing.

**Why this priority**: The callback may involve network operations (POSTing bundles) that take several seconds. Blocking the discovery thread would prevent detection of new peers during that time.

**Independent Test**: Start a server, trigger a discovery of a non-responsive peer (where curl will time out after 30s), verify that a second peer discovered immediately after still triggers its own callback invocation.

**Acceptance Scenarios**:

1. **Given** a server discovers peer A, **When** the callback for peer A is still running (e.g., due to a slow network), **Then** a subsequent discovery of peer B spawns a second callback immediately without waiting for peer A's callback.
2. **Given** a callback process takes longer than the discovery interval, **When** the same peer is re-announced, **Then** a new callback may be spawned (idempotency is handled by the receiving side, per feature 006).

---

### Edge Cases

- What happens when the same peer is discovered multiple times in quick succession? Multiple callbacks may be spawned concurrently. The receiving side handles idempotency (feature 006), so duplicate pushes are harmless but noisy. A future optimization could add debouncing.
- What happens if `OUR_CERT` or `OUR_KEY` env vars are not set? The callback script exits immediately with `${VAR?}`; the server logs the spawn failure as a warning.
- What happens if `REPOS_ROOT` is empty or contains no repos? The callback loops over an empty directory and reports `synced=0 skipped=0`, then exits cleanly.
- What happens if the multicast announcement JSON is malformed? The current behavior (log and skip) is preserved; no callback is spawned for unparseable announcements.
- What happens if the callback script path changes or the server is run from a different working directory? If `CALLBACK_SCRIPT` is not set, the discovery callback is disabled — no path guessing occurs.
- What happens if a multicast announcement lacks a `"host"` field (e.g., from a pre-feature-008 peer)? The implementation defaults to `"unknown"`, constructing `PEER_CERT_FILE` as `<trustDir>/unknown.crt`. The callback will likely fail with a certificate error, which is handled gracefully.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The multicast announcement JSON MUST include a `host` field containing the server's HOST_NAME (defaulting to `"localhost"` if the environment variable is unset).
- **FR-002**: When a valid announcement is received from a peer, the server MUST construct `PEER_NETLOC` as `<peer_ip>:<peer_http_port>` from the announcement and the sender's address.
- **FR-003**: When a valid announcement is received, the server MUST construct `PEER_CERT_FILE` as `<trust-dir>/<peer_hostname>.crt`.
- **FR-004**: The server MUST spawn `scripts/on-discover.sh` as a separate process with environment variables `HOST_NAME`, `PEER_NETLOC`, `PEER_CERT_FILE`, `OUR_CERT`, `OUR_KEY`, and `REPOS_ROOT` passed through from the server's process environment.
- **FR-005**: Callback execution MUST be non-blocking — the multicast worker thread MUST NOT wait for the callback to complete.
- **FR-006**: If the callback script cannot be spawned (file not found, permission denied), the server MUST log a warning and continue the discovery loop.
- **FR-007**: The server's own announcements (loopback) MUST NOT trigger a callback (self-ignore logic preserved from the current implementation).
- **FR-008**: The HOST_NAME and CALLBACK_SCRIPT values are read from the server's process environment at startup (in `source/app.d`). OUR_CERT, OUR_KEY, and REPOS_ROOT are read by the multicast worker thread (`source/multicast.d`) on each receive loop iteration and passed through to the callback environment. The server itself does not parse or validate these values beyond reading them.
- **FR-009**: `just install` (from feature 007) MUST also copy `scripts/on-discover.sh` to `~/.local/share/mtls-hello/scripts/on-discover.sh`, creating the directory if needed.
- **FR-010**: The server MUST support a `CALLBACK_SCRIPT` environment variable that specifies the path to the discovery callback script. There is no default path hardcoded in the binary. If `CALLBACK_SCRIPT` is unset or empty, the discovery callback is disabled and a warning is logged when a peer is discovered.

### Key Entities

- **Discovery announcement**: A JSON payload sent via UDP multicast containing `service` (always `"mtls-hello"`), `port` (the HTTP server port), and `host` (the sender's hostname — new field).
- **Callback environment**: The set of environment variables passed to `scripts/on-discover.sh`: `HOST_NAME` (our identity), `PEER_NETLOC` (peer IP:port), `PEER_CERT_FILE` (path to peer's trusted certificate), `OUR_CERT` (our client cert for outgoing mTLS), `OUR_KEY` (our client key), `REPOS_ROOT` (where bare repos live).
- **Callback script path**: The path to the discovery callback script, specified via the `CALLBACK_SCRIPT` environment variable. There is no default — if unset, the discovery callback is disabled. `just install` places the script at `~/.local/share/mtls-hello/scripts/on-discover.sh`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After a peer announces itself, its repos appear on the receiving side within 60 seconds (accounting for network delay + bundle POST time).
- **SC-002**: When 2 peers are discovered in rapid succession, 2 independent callback processes are spawned within 3 seconds (none blocked by others).
- **SC-003**: A server with HOST_NAME=alpha announces `"host":"alpha"` in its discovery packet (verified by packet capture or BATS test).

## Assumptions

- The operator is responsible for setting `HOST_NAME`, `OUR_CERT`, `OUR_KEY`, and `REPOS_ROOT` as environment variables before starting the server. The server does not provide CLI flags for these (that could be added in a future feature).
- The peer's hostname is unique within the LAN and matches the filename in the trust store (e.g., peer "beta" has its cert at `<trust-dir>/beta.crt`).
- The callback script path has no default in the binary. The operator must set `CALLBACK_SCRIPT` to enable discovery-triggered sync. `just install` copies the script and prints the suggested value.
- The trust relationship (certificate exchange) is established out-of-band or via the onboarding flow (feature 004) before discovery triggers a sync. Without a trusted cert, the callback will attempt the push and fail with a TLS error — this is expected and handled gracefully.
- Debouncing (avoiding duplicate callback spawns for the same peer within a short window) is deferred to a future optimization.
