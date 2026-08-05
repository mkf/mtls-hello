# Data Model: Wire Discovery Callback

**Feature**: 008-wire-discovery-callback | **Date**: 2026-08-05

## Entities

### MulticastConfig (modified)

| Field | Type | Default | Description |
|---|---|---|---|
| group | string | `"239.255.42.42"` | Multicast group address |
| port | ushort | `4242` | Multicast UDP port |
| interval | Duration | `5.seconds` | Announcement interval |
| enabled | bool | `true` | Whether multicast is active |
| **hostName** | string | `"localhost"` | **NEW** — Our hostname (announced + used as callback env) |
| **trustDir** | string | `""` | **NEW** — Path to trusted peer certificate directory |
| **callbackScript** | string | `""` | Path from `CALLBACK_SCRIPT` env var; empty if unset (discovery callback disabled) |

### Discovery Announcement (modified)

JSON payload broadcast via UDP multicast:

```json
{
  "service": "mtls-hello",
  "port": 8443,
  "host": "alpha"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `service` | string | Yes | Always `"mtls-hello"` |
| `port` | number | Yes | Sender's HTTPS listen port |
| `host` | string | **NEW** | Sender's hostname (from `HOST_NAME` env var or `"localhost"`) |

### Callback Environment

Environment variables passed to `scripts/on-discover.sh`:

| Variable | Source | Example |
|---|---|---|
| `HOST_NAME` | Server env (`HOST_NAME`) or `"localhost"` | `"alpha"` |
| `PEER_NETLOC` | Constructed: `<peer_ip>:<peer_port>` | `"192.168.1.5:8443"` |
| `PEER_CERT_FILE` | Constructed: `<trustDir>/<peer_host>.crt` | `"/etc/mtls/trusted/beta.crt"` |
| `OUR_CERT` | Server env (`OUR_CERT`) | `"/etc/mtls/client.crt"` |
| `OUR_KEY` | Server env (`OUR_KEY`) | `"/etc/mtls/client.key"` |
| `REPOS_ROOT` | Server env (`REPOS_ROOT`) | `"/srv/repos"` |

**Invariants**:
- `PEER_NETLOC` is always `<IP>:<port>` from the discovery announcement.
- `PEER_CERT_FILE` is always `<trustDir>/<peerHostname>.crt` regardless of whether the file exists.
- `HOST_NAME`, `OUR_CERT`, `OUR_KEY`, `REPOS_ROOT` are passed through unchanged from the server process environment.
- If `OUR_CERT` or `OUR_KEY` is unset, the callback script exits immediately with `${VAR?}` — no special handling on the server side.
