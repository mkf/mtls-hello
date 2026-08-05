# Data Model: Install-Time Self-Signed Certificates

## Install Tree (after `just install`)

```
~/.local/share/mtls-hello/
├── certs/
│   ├── certs/
│   │   └── server.crt          # Self-signed X.509 cert (CN=hostname, 10yr)
│   └── private/
│       └── server.key          # RSA 2048 key, mode 0600
├── handlers/
│   └── bundle.post.sh
├── scripts/
│   ├── on-discover.sh
│   └── pre-push.sh.new
```

## Entities

| Entity | Path | Mode | Purpose |
|---|---|---|---|
| server.crt | `<data-dir>/certs/certs/server.crt` | 0644 | Server TLS certificate, self-signed, CN=$(hostname) |
| server.key | `<data-dir>/certs/private/server.key` | 0600 | Server private key, RSA 2048 |

## Generation Rules

- If `server.crt` exists → skip (never overwrite)
- If `server.crt` missing → generate both cert+key with `openssl req -x509`
- openssl missing → log warning, skip, don't fail install

## Test Fixture (BATS)

```bash
mkfixture_certs DIR   # sets SERVER_CERT, SERVER_KEY, CLIENT_CERT, CLIENT_KEY
```

| Variable | Path | CN | Validity |
|---|---|---|---|
| SERVER_CERT | `$dir/server.crt` | localhost | 1 day |
| SERVER_KEY | `$dir/server.key` | — | — |
| CLIENT_CERT | `$dir/client.crt` | test-client | 1 day |
| CLIENT_KEY | `$dir/client.key` | — | — |
