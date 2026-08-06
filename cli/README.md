# cli/ — Per-Host Drop-Box Client Wrappers

Thin bash wrappers over `curl` with mutual TLS. Each wrapper performs exactly
one HTTP method against `/drop/<cn>/<rest>` on a trusted server.

The caller's CN is auto-derived from `--cert` via `openssl x509 -subject`.

## Wrappers

| Wrapper | HTTP Method | Purpose |
|---------|-------------|---------|
| `mtls-drop.sh`   | PUT       | Upload a file |
| `mtls-fetch.sh`  | GET       | Download a file (supports `--range`) |
| `mtls-head.sh`   | HEAD      | Inspect headers |
| `mtls-del.sh`    | DELETE    | Remove a file or empty dir |
| `mtls-ls.sh`     | PROPFIND  | List drop-box contents |
| `mtls-props.sh`  | PROPFIND  | Show single-item metadata |
| `mtls-mkcol.sh`  | MKCOL     | Create a directory |
| `mtls-cp.sh`     | COPY      | Copy an item |
| `mtls-mv.sh`     | MOVE      | Move/rename an item |

## Common Options

All wrappers accept:

| Flag | Env | Notes |
|------|-----|-------|
| `--server URL` | `MTLS_SERVER` | e.g. `https://host:8443` |
| `--cert FILE`  | `MTLS_CLIENT_CERT` | client cert (also used to derive CN) |
| `--key FILE`   | `MTLS_CLIENT_KEY` | client key |
| `--cacert FILE`| `MTLS_CACERT` | trusted server cert |
| `--cn CN`      | (none) | override auto-derived CN |

See `specs/023-per-host-dropbox/contracts/client-cli.md` for the full contract.
