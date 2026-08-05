# Research: Wire Discovery Callback

**Feature**: 008-wire-discovery-callback | **Date**: 2026-08-05

## Decision: Spawn callback via `std.process.spawnProcess`

**Decision**: The multicast worker spawns `scripts/on-discover.sh` using D's `std.process.spawnProcess` with `Config.env` to pass the required environment variables. The spawn is fire-and-forget — the multicast thread does not wait for the callback to complete.

**Rationale**:
- `spawnProcess` returns immediately; the child process runs independently. This satisfies FR-005 (non-blocking).
- `Config.env` takes a `string[string]` associative array directly — no need to manipulate the OS environment.
- Fire-and-forget means the multicast loop is never blocked, even if the callback hangs or takes 30+ seconds (network timeouts).
- Failed spawns (e.g., script not found) throw a `ProcessException` which we catch, log, and continue — satisfying FR-006.

**Alternatives considered**:
- `std.process.execute` / `executeShell` — blocks until the callback completes; violates FR-005. Rejected.
- `core.sys.posix.unistd.fork` + `execve` — manual process creation with extreme control but more code, more platform-specific. Overkill. Rejected.
- Throwing the callback into a vibe.d `runTask` — the callback is a bash script, not D code. Rejected.

## Decision: Hostname from `environment` with default

**Decision**: The server reads `HOST_NAME` from `std.process.environment` at startup. If unset, it defaults to `"localhost"`. The value is stored in `MulticastConfig.hostName` and included in every announcement.

**Rationale**:
- `environment` is the D standard way to access process env vars. It is thread-safe (returns a snapshot AA).
- Defaulting to `"localhost"` satisfies US2 acceptance scenario 2 (basic functionality out of the box).
- CLI flags for HOST_NAME are deferred to keep this feature minimal.

**Alternatives considered**:
- CLI flag `--host-name=NAME` — more explicit but adds parseArgs complexity for a feature that already works with env vars. Deferred.
- Derive hostname from `gethostname()` — automatic but may not match the certificate CN. Operator should set it explicitly. Rejected.

## Decision: `PEER_CERT_FILE` constructed from trusted certs directory

**Decision**: On discovery, the multicast worker reads the peer's hostname from the announcement and constructs `PEER_CERT_FILE` as `<trustDir>/<peerHostname>.crt`. It does not check whether the file exists — the callback script handles that failure.

**Rationale**:
- The trust model (feature 004) stores trusted peer certificates at `<trustDir>/<hostname>.crt`. This path convention is already established.
- Not checking existence keeps the multicast thread fast; the callback's `curl` will fail if the cert is missing, which is logged.
- trustDir is already available in the server config (`ServerConfig.trust.trustDir`).

**Alternatives considered**:
- Pass the trustDir path via env var `TRUST_DIR` — the callback script doesn't use it directly. Better to construct the full path on the server side. Rejected.
- Scan the trust directory for a cert matching the peer's IP — certificates are matched to hostnames, not IPs. Rejected.

## Decision: Announcement format extended with `host` field

**Decision**: The announcement JSON gains a `"host"` field:

```json
{"service":"mtls-hello","port":8443,"host":"alpha"}
```

The existing `service` and `port` fields are unchanged. Backward-compatible: older servers ignoring `host` will still parse the announcement (the `host` field is simply unused).

**Rationale**:
- Adding a field to a JSON object is backward-compatible for readers that ignore unknown keys.
- The announcement is a single UDP packet (~60 bytes with hostname); well within the 1024-byte receive buffer and far below the 1500-byte MTU.
- No version negotiation needed — if `host` is missing (from an older server), the receiving side can fall back to a default or skip.

**Alternatives considered**:
- Include hostname in `service` field (e.g., `"mtls-hello/alpha"`) — couples identity with protocol name; rejected.
- Extend with a separate "identity" announcement — adds complexity without benefit. Rejected.

## Decision: Callback script path configurable via `CALLBACK_SCRIPT` env var

**Decision**: The multicast worker reads the callback script path from the `CALLBACK_SCRIPT` environment variable. If unset, it defaults to `scripts/on-discover.sh` (relative to working directory, for development). After `just install`, the operator sets `CALLBACK_SCRIPT=~/.local/share/mtls-hello/scripts/on-discover.sh`.

**Rationale**:
- In development, the server runs from the repo root, so `scripts/on-discover.sh` works.
- In production (feature 007), the binary is at `~/.local/bin/mtls-hello` and `CALLBACK_SCRIPT` must point to the installed location.
- An env var is simpler than a CLI flag and fits the existing pattern (HOST_NAME, OUR_CERT, OUR_KEY, REPOS_ROOT are all env vars).

**Alternatives considered**:
- CLI flag `--callback-script=PATH` — more explicit but adds parseArgs complexity; env var is sufficient.
- Hardcode the installed path — breaks development workflow. Rejected.
- Include in `--handlers-dir` — the callback is not an HTTP handler; mixing concerns. Rejected.

## Decision: Test strategy — simulate discovery via UDP

**Decision**: BATS tests verify the callback wiring by:
1. Starting a server with known env vars (HOST_NAME, etc.)
2. Sending a raw UDP packet simulating a peer announcement (using `echo '{"service":"mtls-hello","port":18443,"host":"test-peer"}' | nc -u -w0`)
3. Checking the server log for callback spawn traces
4. Verifying the server's own announcement contains the `host` field (by capturing with `nc -ul`)

**Rationale**: Actual multicast requires a LAN interface, which may not be available in CI. Sending a direct UDP packet to the listening port tests the code path without network infrastructure.
