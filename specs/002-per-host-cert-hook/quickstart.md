# Quickstart: Per-Hostname Credential Store and Discovery Callback

**Branch**: `002-per-host-cert-hook` | **Date**: 2026-03-19 | **Feature**: [spec.md](./spec.md)

## Prerequisites

- Feature 001 (`001-mtls-echo-discovery`) built and working (this feature extends it).
- GNU Guix with the daemon running.
- Git checkout of this branch.

## 1. Generate test PKI + per-host certs

```sh
just gen-certs
```

Creates the shared PKI (CA, server, client) from feature 001.

To prepare a peer's certificate for the per-hostname store, copy that peer's server certificate to `certs/hosts/`:

```sh
mkdir -p certs/hosts
cp certs/certs/server.crt certs/hosts/$(hostname).crt
```

When testing with a second peer (e.g., `beta.local`), copy that peer's server certificate:

```sh
# On beta.local, generate its PKI and copy its server cert back:
scp beta.local:certs/certs/server.crt certs/hosts/beta.local.crt
```

## 2. Build

```sh
just build
```

## 3. Run with the discovery callback

```sh
just run -- 8443 --on-discovery scripts/on-discover.sh
```

The server logs the HTTPS listener, multicast discovery settings, and that the callback script is configured.

## 4. Verify the callback on peer discovery

When a peer announces itself, the callback script executes. Output from the default `scripts/on-discover.sh`:

```text
[on-discover] peer alpha at alpha:8443 (cert: certs/hosts/alpha.crt)
```

To test manually (without a peer), source the default script and call the helper with simulated env vars:

```sh
export HOST_NAME=alpha PEER_CERT_FILE=certs/hosts/alpha.crt PEER_NETLOC=alpha:8443
export OUR_CERT=certs/certs/client.crt OUR_KEY=certs/private/client.key
source scripts/on-discover.sh
# → logs the peer
# → mtls_curl "/" would run curl against https://alpha:8443/
```

## 5. Use the mtls_curl helper

From within the callback script (or manually after sourcing it):

```sh
mtls_curl "/hello%20world"
# → issues authenticated GET https://$PEER_NETLOC/hello%20world
# → uses $OUR_CERT/$OUR_KEY for client auth
# → verifies server against $PEER_CERT_FILE (certificate pinning)
```

## 6. Disable the callback

To run without the callback (same behavior as feature 001):

```sh
just run -- 8443
```

Or disable discovery entirely:

```sh
just run -- 8443 --no-multicast
```

## Troubleshooting

- **"on-discovery script not found"**: ensure `--on-discovery` points to a valid path. The default `scripts/on-discover.sh` should exist.
- **"credential file not found" for peer X**: place the peer's server certificate at `certs/hosts/X.crt` (using the exact hostname the peer announces).
- **Callback doesn't fire**: the peer must announce with a `host` field (feature 002 protocol). Older 001 peers without `host` are logged but don't trigger callbacks.
- **Multicast not working (loopback)**: same limitation as feature 001 — the loopback interface lacks MULTICAST. Test with `source scripts/on-discover.sh` + mock env vars for the callback logic.
