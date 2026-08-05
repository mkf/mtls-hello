# Contract: Discovery Callback Script

**Branch**: `002-per-host-cert-hook` | **Date**: 2026-03-19 | **Feature**: [spec.md](../spec.md)

## Overview

The operator provides a callback script (via `--on-discovery`) that the server executes on every peer announcement. The script receives the peer's identity, credential file, and connection address via environment variables. It may include a helper function `mtls_curl` for issuing authenticated requests to the peer.

## Environment Variables

| Variable | Example Value | Description |
|---|---|---|
| `HOST_NAME` | `alpha.local` | Peer's hostname (from the announcement `host` field) |
| `PEER_CERT_FILE` | `/home/user/mtls-hello/certs/hosts/alpha.local.crt` | Absolute path to the peer's public certificate |
| `PEER_NETLOC` | `alpha.local:8443` | Connection address: `<hostname>:<port>` |
| `OUR_CERT` | `certs/certs/client.crt` | Path to our client certificate for outgoing requests |
| `OUR_KEY` | `certs/private/client.key` | Path to our client private key for outgoing requests |

## Execution Contract

- The script is spawned as a child process of the server; it inherits the server's stdout/stderr.
- The server does NOT wait for the script to complete (fire-and-forget).
- The script's exit code is ignored by the server (non-zero is logged as a warning).
- The script's working directory is the server's working directory at startup.
- The script is executed via `/bin/sh -c "exec <script>"` — it may use a shebang line or plain shell syntax.

## Helper Function: mtls_curl

The callback script may define a function `mtls_curl` for issuing authenticated GET requests to the peer.

### Signature

```bash
mtls_curl <path>
```

### Example

```bash
mtls_curl "/hello%20world"
# → issues: GET https://$PEER_NETLOC/hello%20world
# → with mutual TLS using $OUR_CERT/$OUR_KEY (client) and $PEER_CERT_FILE (server verification)
```

### Semantics

- Issues a GET request to `https://$PEER_NETLOC/<path>`.
- Client authentication: `--cert "$OUR_CERT" --key "$OUR_KEY"`.
- Server verification: `--cacert "$PEER_CERT_FILE"` (certificate pinning — only the peer's specific cert is trusted).
- Timeout: 5 seconds.
- Output: response body to stdout, errors to stderr.
- Exit code: 0 on success (HTTP 2xx), non-zero on failure.

### Reference Implementation

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

## Default Script: scripts/on-discover.sh

The server ships a skeleton callback script that defines `mtls_curl` and logs discovered peers. The operator may use it as-is or customize it.

```bash
#!/bin/bash
# Discovery callback — executed on each peer announcement.
# Env: HOST_NAME, PEER_CERT_FILE, PEER_NETLOC, OUR_CERT, OUR_KEY

mtls_curl() {
  local path="${1:-/}"
  curl -sS --max-time 5 \
    --cacert "$PEER_CERT_FILE" \
    --cert "${OUR_CERT:-certs/certs/client.crt}" \
    --key "${OUR_KEY:-certs/private/client.key}" \
    "https://$PEER_NETLOC/$path"
}

echo "[on-discover] peer $HOST_NAME at $PEER_NETLOC (cert: $PEER_CERT_FILE)"

# Example: echo the peer's root path
# mtls_curl "/"
```

## Error Handling

| Scenario | Behavior |
|---|---|
| `OUR_CERT` or `OUR_KEY` not set | `mtls_curl` falls back to `certs/certs/client.crt` / `certs/private/client.key` |
| `PEER_CERT_FILE` points to missing file | `mtls_curl` fails with cURL error (non-zero exit) |
| Peer unreachable | `mtls_curl` fails with connection error (non-zero exit) |
| Script exits non-zero | Server logs warning, continues operating |
