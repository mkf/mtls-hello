# Contract: Discovery Callback Execution

**Branch**: `008-wire-discovery-callback` | **Date**: 2026-08-05 | **Feature**: [spec.md](../spec.md)

## Trigger

When the multicast worker receives a valid announcement from a peer (not itself), it spawns the script at the path specified by `CALLBACK_SCRIPT` (default: `scripts/on-discover.sh`) as a separate process.

## Environment

The following environment variables are set for the callback process:

| Variable | Value | Example |
|---|---|---|
| `HOST_NAME` | Our hostname (from server env or `"localhost"`) | `"alpha"` |
| `PEER_NETLOC` | `<peer_ip>:<peer_http_port>` | `"192.168.1.5:8443"` |
| `PEER_CERT_FILE` | `<trustDir>/<peer_hostname>.crt` | `"/srv/certs/trusted/beta.crt"` |
| `OUR_CERT` | Path to our client certificate (from server env `OUR_CERT`) | `"/srv/certs/client.crt"` |
| `OUR_KEY` | Path to our client key (from server env `OUR_KEY`) | `"/srv/certs/client.key"` |
| `REPOS_ROOT` | Base directory of bare repos (from server env `REPOS_ROOT`) | `"/srv/repos"` |

## Execution Model

- **Fire-and-forget**: The multicast thread spawns the process and does not wait.
- **No output capture**: stdout and stderr are inherited from the server process.
- **No concurrency limit**: Multiple callbacks may run concurrently for different peers.
- **No debouncing**: If the same peer announces twice in rapid succession, two callbacks are spawned.

## Error Handling

| Scenario | Behavior |
|---|---|
| Script file not found | `spawnProcess` throws; caught, logged as warning, discovery loop continues |
| Script permission denied | Same as above |
| Script exits non-zero | No server-side handling; the script's own output is visible in the server log |
| `OUR_CERT` or `OUR_KEY` unset | Script exits immediately with `${VAR?}` message; server does not pre-validate |

## Self-Ignore

Announcements from `127.0.0.1` or `::1` with the same port as our own server are skipped (no callback spawned). This is the existing self-ignore logic preserved from the current multicast implementation.
