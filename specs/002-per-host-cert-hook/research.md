# Research: Per-Hostname Credential Store and Discovery Callback

**Branch**: `002-per-host-cert-hook` | **Date**: 2026-03-19 | **Feature**: [spec.md](./spec.md)

## Decision: Announcement wire format — add host field

**Decision**: Extend the existing UDP multicast JSON payload to include a `host` string field:

```json
{"service":"mtls-hello","port":8443,"host":"myhost"}
```

The `host` value is the announcing server's local hostname (from `std.socket.Socket.hostName` or `gethostname`).

**Rationale**:
- The current protocol (`specs/001-mtls-echo-discovery/contracts/discovery.md`) carries only `service` and `port`. Per-hostname credential lookup requires a hostname identifier.
- Adding a field to an existing JSON payload is backward-compatible: 001 instances ignore unrecognized fields; 002 instances continue to accept 001 messages (see handling below).
- The hostname enables the credential store lookup and becomes the `HOST_NAME` environment variable in the callback.

**Alternatives considered**:
- Use source IP address as the identity — simpler (no wire change), but IPs are ephemeral, NAT-unfriendly, and don't match the user's "per-hostname" requirement.
- Require operator to configure a static name per server — redundant; the hostname is already available and is a natural LAN identity.

## Decision: Handling older (001) announcements without a host field

**Decision**: Announcements that lack a `host` field are logged as discovered but do NOT trigger the callback script (credential lookup requires a hostname).

**Rationale**:
- Backward-compatible: 001 instances still show up in discovery logs.
- Without a hostname, there is no way to locate the peer's credential file, so the callback cannot provide the `PEER_CERT_FILE` env var. Omitting the callback for these peers is the safe default.
- If all peers are upgraded to 002, every announcement has a `host` field and the callback fires normally.

**Alternatives considered**:
- Use source IP as fallback name — mixes IPs and hostnames in the cert store, making provisioning confusing.
- Record the source IP as a synthetic hostname — same confusion.

## Decision: Credential store layout

**Decision**: Flat files under `certs/hosts/<hostname>.crt`. Each file contains the peer's X.509 server certificate (public key).

```
certs/hosts/
├── alpha.crt          # peer "alpha"'s server certificate
├── beta.local.crt     # peer "beta.local"'s server certificate
└── ...
```

The lookup is `certs/hosts/<hostname>.crt` with the hostname sanitized to prevent path traversal.

**Rationale**:
- Flat layout is simple and matches the user's mental model ("stored per-hostname").
- A single `.crt` file per host is sufficient for server certificate pinning (the peer's public key used to verify the server in the helper's curl invocation).
- Directories per hostname were considered (would allow key storage per host in the future) but add complexity without an immediate requirement.

**Alternatives considered**:
- `certs/hosts/<hostname>/server.crt` directory layout — allows future per-host key storage; more complex, not needed now.
- Key-value config file mapping hostnames to cert paths — reduces disk access but adds an indirection layer.

## Decision: Callback execution model

**Decision**: Use D's `std.process.spawnProcess` to execute the operator's script asynchronously (non-blocking, fire-and-forget). The server does NOT wait for the script to complete or capture its output.

Environment variables set before spawning:
- `HOST_NAME` — peer hostname from the announcement `host` field
- `PEER_CERT_FILE` — absolute path to the peer's certificate file (`certs/hosts/<hostname>.crt`)
- `PEER_NETLOC` — `hostname:port` (connection address)

**Rationale**:
- Non-blocking prevents the callback from stalling the discovery receive loop (and thus missing subsequent announcements).
- The script's stdout/stderr are inherited from the server process (go to the same terminal/log). The operator can redirect in their script if desired.
- `spawnProcess` does not invoke a shell; we set the executable to `/bin/sh` with args `["-c", "exec <script_path>"]` so the script runs via its shebang or via sh.

**Alternatives considered**:
- `std.process.execute` — blocking, would stall discovery loop on long-running scripts.
- vibe.d's `runTask` — would import vibe-core fiber machinery into the discovery thread, complicating the module boundary.
- `fork`+`exec` directly with `waitpid` in a thread — `spawnProcess` already handles this.

## Decision: Script exit handling

**Decision**: The server does NOT react to the script's exit code. Failed scripts (non-zero exit) are logged at warning level. The server continues operating.

**Rationale**:
- The operator's script is responsible for handling its own errors (missing certs, unreachable peers). The server's job is to invoke the hook, not to enforce its outcome.
- A failing script should not disrupt the server.

**Alternatives considered**:
- Halt discovery on script failure — too aggressive; the operator's script may fail transiently (peer unreachable).
- Suppress all output — reduces debuggability.

## Decision: Self-announcement filtering

**Decision**: Announcements from the local host (where `host` matches the server's own hostname AND `port` matches the server's own HTTP port) do NOT trigger the callback.

**Rationale**:
- Multicast loopback (`IP_MULTICAST_LOOP = 1`) causes the server to receive its own announcements. Without filtering, every 5-second self-announcement would trigger a callback to itself.
- Matching on both `host` and `port` handles the case where multiple instances run on the same host on different ports — those ARE different peers and should trigger the callback.

**Note**: The existing 001 port-only self-filter is retained; the host filter is additive.

## Decision: Missing credential handling

**Decision**: If the peer's credential file (`certs/hosts/<hostname>.crt`) does not exist, log a warning and skip the callback for that announcement. The server does NOT create the file, generate a stub, or execute the script with an empty file path.

**Rationale**:
- Executing the script without a valid `PEER_CERT_FILE` would cause the `mtls_curl` helper to fail confusingly. Skipping is predictable and documented.
- Operator pre-provisioning is a stated assumption; missing certs indicate configuration error that should be surfaced as a warning, not silently tolerated.
- Auto-generating certs is out of scope (the project does not act as a CA).

**Alternatives considered**:
- Execute script with `PEER_CERT_FILE` unset or empty — script could check and handle gracefully, but defeats the purpose of the callback for that peer.
- Abort server on missing cert — too aggressive for an optional peer.

## Decision: Default callback script

**Decision**: Ship a default callback script at `scripts/on-discover.sh` that:
1. Defines the `mtls_curl` utility function
2. Logs the peer discovery event to stdout
3. Does NOT automatically call `mtls_curl` (the operator customizes the script to decide what endpoints to request)

The operator provides their own script via `--on-discovery <path>`. The shipped `scripts/on-discover.sh` serves as documentation and a skeleton.

**Rationale**:
- The utility function must be defined in the same file that gets executed (user's request: "a bash file... with a utility function").
- The server does not need to know the script's contents — it just executes the file. The function definition approach means the helper lives in the operator's namespace.
- Shipping a default skeleton ensures the feature is self-documenting and immediately testable (the operator can run `scripts/on-discover.sh` manually with mock env vars).

**Alternatives considered**:
- Source a separate helper file — the operator's script would `source scripts/mtls-helper.sh`. More modular but the user explicitly said "a bash file" (singular) containing the utility function. The sourced-helper approach could co-exist if the operator prefers it (they'd source from their script), but the default template just defines the function inline.
- Embed the function in the D binary's string constant — makes the script opaque and uneditable.

## Decision: Helper certificate usage (pinning)

**Decision**: The `mtls_curl` helper verifies the peer server using ONLY the peer's specific certificate file (`--cacert "$PEER_CERT_FILE"`), not the shared CA pool. The helper authenticates the client using `--cert` and `--key` pointing to the local client identity.

```bash
mtls_curl() {
  local path="${1:-/}"
  curl -sS --max-time 5 \
    --cacert "$PEER_CERT_FILE" \
    --cert "${OUR_CERT:-certs/certs/client.crt}" \
    --key "${OUR_KEY:-certs/private/client.key}" \
    "https://$PEER_NETLOC/$path"
}
```

**Rationale**:
- The user explicitly asked to use "the given hostnames public key" for verification — this is certificate pinning: trust only that specific peer's cert, not any cert signed by the CA.
- `OUR_CERT` and `OUR_KEY` are set by the server when spawning the script (from the new `--client-cert` / `--client-key` CLI args), with the defaults pointing to the existing test PKI.
- cURL's `--cacert` with a single-cert file enables pinning without modifying the system trust store.

**Alternatives considered**:
- `--pinnedpubkey` with a hash — requires extracting the public key hash, which is more complex for the operator to provision.
- CA-based verification via `--cacert ca.crt` — doesn't provide per-host verification; any cert signed by the CA would be trusted.
