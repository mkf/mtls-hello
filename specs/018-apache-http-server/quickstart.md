# Quickstart: Apache HTTP Server Backend

**Feature**: Apache HTTP Server Backend
**Date**: 2026-08-06

## Prerequisites

- Debian bookworm or Arch Linux system.
- `curl` and `openssl` installed.
- The project source checked out or the native package installed.
- Root or sudo access is **not** required; the install script uses a user systemd service.

## Install

```bash
bash scripts/install.sh
```

This installs Apache if needed, generates self-signed server certificates, and creates a systemd user service. The default data directory is `$HOME/.local/share/mtls-hello`.

## Start the service

```bash
systemctl --user daemon-reload
systemctl --user start mtls-hello
```

If you want a random port, set `MTLS_PORT=0` before running install:

```bash
MTLS_PORT=0 bash scripts/install.sh
systemctl --user start mtls-hello
```

The chosen port is written to `<data-dir>/apache/port`. Note that the systemd
unit also needs to be edited to match the chosen port if you deviate from the
default 8443.

## Check the port

```bash
cat /path/to/data/apache/port
```

or, if a fixed port was used:

```bash
cat /path/to/data/port
```

## Make a test request with a trusted client certificate

Generate or reuse a client certificate, add it to the trust directory, then call the echo endpoint:

```bash
# Add a peer certificate to the trust store
bash scripts/trust-host.sh my-peer /path/to/peer.crt

# Call the server with the peer's certificate
PORT=$(cat /path/to/data/apache/port)
curl -sS --cacert /path/to/data/certs/certs/server.crt \
  --cert /path/to/peer.crt --key /path/to/peer.key \
  "https://localhost:${PORT}/hello"
```

Expected output:

```text
hello
```

## Capture an untrusted peer certificate

When a peer connects with an unknown certificate, Apache passes it to the handler, which writes it to purgatory:

```bash
PORT=$(cat /path/to/data/apache/port)
curl -sS --cacert /path/to/data/certs/certs/server.crt \
  --cert /path/to/unknown-peer.crt --key /path/to/unknown-peer.key \
  "https://localhost:${PORT}/hello"
# Response: 401 Unauthorized

# List the captured certificate
ls /path/to/data/purgatory/
```

## Promote a captured certificate to trusted

```bash
captured=$(ls /path/to/data/purgatory/*.crt | head -1)
bash scripts/trust-host.sh unknown-peer "$captured"
```

## Verify discovery and sync still work

Start a second instance on a different data directory and port. The two instances should discover each other via multicast, capture each other’s certificates, and trigger the `on-discover.sh` callback.

```bash
# Terminal 1
bash scripts/install.sh --data-dir /tmp/mtls-a --port 18501
systemctl --user start mtls-hello

# Terminal 2
bash scripts/install.sh --data-dir /tmp/mtls-b --port 18502
systemctl --user start mtls-hello

# Wait a few seconds, then check purgatory on each side
ls /tmp/mtls-a/purgatory/
ls /tmp/mtls-b/purgatory/
```

## Stop the service

```bash
systemctl --user stop mtls-hello
```

## Files created by this feature

- `<data-dir>/apache/site.conf` — Apache site configuration.
- `<data-dir>/apache/port` — OS-assigned port when using random port.
- `<data-dir>/apache/error.log` — Apache error log.
- `<data-dir>/apache/access.log` — Apache access log.
