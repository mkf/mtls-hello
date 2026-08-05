# Data Model: Per-Hostname Credential Store and Discovery Callback

**Branch**: `002-per-host-cert-hook` | **Date**: 2026-03-19 | **Feature**: [spec.md](./spec.md)

## Entities

### PeerAnnouncement

A decoded multicast announcement received from a peer.

| Field | Type | Source | Description |
|---|---|---|---|
| `service` | string | JSON `"service"` | Fixed `"mtls-hello"`; used to filter foreign traffic |
| `host` | string (nullable) | JSON `"host"` | Peer's hostname; missing on 001-protocol messages |
| `port` | ushort | JSON `"port"` | Peer's HTTPS listen port |
| `srcAddr` | string | UDP `receiveFrom` | Source IP address (logged, not used for identity) |

Validation: `service == "mtls-hello"`, `port` in 1–65535. `host` is optional (older peers).

### DiscoveryConfig

Runtime configuration for the discovery subsystem.

| Field | Type | Default | Description |
|---|---|---|---|
| `multicastGroup` | string | `"239.255.42.42"` | IPv4 multicast group address |
| `multicastPort` | ushort | `4242` | UDP port |
| `announceInterval` | Duration | 5 s | Time between announcements |
| `localHost` | string | `gethostname()` | This server's hostname (announced; used for self-filter) |
| `localPort` | ushort | CLI arg | This server's HTTPS port (announced; self-filter) |
| `peerCertDir` | string | `"certs/hosts"` | Directory containing per-hostname `.crt` files |
| `onDiscoverScript` | string (nullable) | null | Path to operator's callback script; null = disabled |
| `clientCert` | string | `"certs/certs/client.crt"` | Our client certificate for outgoing requests |
| `clientKey` | string | `"certs/private/client.key"` | Our client private key for outgoing requests |
| `enabled` | bool | true | Whether discovery is active (`--no-multicast` flips to false) |

### CallbackEnvironment

Environment variables injected into the spawned callback process.

| Variable | Value Source | Description |
|---|---|---|
| `HOST_NAME` | `PeerAnnouncement.host` | Peer's hostname |
| `PEER_CERT_FILE` | `credentialStore.resolve(host)` | Absolute path to `<peerCertDir>/<host>.crt` |
| `PEER_NETLOC` | `"<host>:<port>"` | Connection address: hostname:port |
| `OUR_CERT` | `DiscoveryConfig.clientCert` | Path to our client certificate |
| `OUR_KEY` | `DiscoveryConfig.clientKey` | Path to our client private key |

### CredentialStore

Logical mapping of hostname → certificate file path. Implemented as filesystem lookup.

| Operation | Input | Output | Error |
|---|---|---|---|
| `resolve(host)` | Hostname string | Absolute path `certs/hosts/<host>.crt` | Returns null/empty if file does not exist |

**Sanitization**: The hostname is stripped of `/`, `..`, and null bytes before path construction to prevent directory traversal.

### DiscoveryHook

The invocation contract for the operator's callback script.

| Aspect | Detail |
|---|---|
| **Executable** | `DiscoveryConfig.onDiscoverScript` (absolute or relative path) |
| **Spawn mode** | Non-blocking (`spawnProcess`), fire-and-forget |
| **Environment** | `CallbackEnvironment` variables + inherited server environment |
| **Working directory** | Server's working directory at startup |
| **Exit code** | Ignored by server; non-zero logged as warning |
| **Stdout/stderr** | Inherited from server process |

### RequestHelper (mtls_curl)

The utility function available inside the callback script.

| Aspect | Detail |
|---|---|
| **Signature** | `mtls_curl <path>` where `<path>` is a URL path (e.g., `/hello%20world`) |
| **Method** | GET |
| **URL** | `https://$PEER_NETLOC/<path>` |
| **Client auth** | `--cert "$OUR_CERT" --key "$OUR_KEY"` |
| **Server verification** | `--cacert "$PEER_CERT_FILE"` (certificate pinning) |
| **Exit code** | 0 on success (HTTP 2xx), non-zero on error |
| **Output** | Response body to stdout |

## State Transitions

The feature is stateless — no persistent entity state changes. The only dynamics are:

1. **Announcement received** → validate service → extract host → lookup cert → if found: spawn callback; if missing: log warning.
2. **Callback spawned** → script executes independently → server continues discovery loop.
3. **Self-announcement received** → filtered out (no callback).
