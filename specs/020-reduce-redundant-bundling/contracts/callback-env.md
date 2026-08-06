# Contract: Discovery Callback Environment

## Purpose

Document the environment variables available to `scripts/on-discover.sh` when the discovery callback fires. This feature does not add new environment variables; it reuses the existing variables from the 002 callback contract.

## Required Variables

| Variable | Source | Description | Used by this feature? |
|----------|--------|-------------|----------------------|
| `HOST_NAME` | Daemon CLI / config | Friendly name of this host, used for remote namespace and sync-state files. | Yes |
| `PEER_NETLOC` | Daemon, from discovery packet | Host and port of the peer (`host:port`). | Yes (used by existing curl functions) |
| `PEER_CERT_FILE` | Daemon, from trust store | Path to the pinned peer certificate file. | Yes (used by existing curl functions) |
| `OUR_CERT` | Daemon config | Path to our mTLS client certificate. | Yes (used by existing curl functions) |
| `OUR_KEY` | Daemon config | Path to our mTLS client key. | Yes (used by existing curl functions) |
| `REPOS_ROOT` | Daemon config | Directory containing bare repositories (`*.git`). | Yes |
| `DATA_DIR` | Daemon config | Runtime data directory. | Yes (used only to derive the shared-memory namespace) |

## Notes

- `DATA_DIR` is used to compute a unique hash for the `/dev/shm` namespace so that multiple mtls-hello instances on the same host do not collide. The sync-state data itself is not written under `DATA_DIR`.
- The callback contract remains unchanged; the optimization is transparent to the daemon.
- No new command-line arguments are introduced for this feature.
