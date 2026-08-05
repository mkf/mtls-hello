# Quickstart: Mutual-TLS Echo Endpoint with LAN Discovery

**Branch**: `001-mtls-echo-discovery` | **Date**: 2026-08-05 | **Feature**: [spec.md](./spec.md)

## Prerequisites

- GNU Guix with the daemon running (`sudo systemctl enable --now guix-daemon` once).
- Git checkout of this branch.

## 1. Generate the test PKI

```sh
just gen-certs
# or: nix-shell --run "bash scripts/gen_certs.sh"
```

Creates `certs/ca.crt`, `certs/certs/server.crt`, `certs/private/server.key`, `certs/certs/client.crt`, `certs/private/client.key`, `certs/client.p12` (password `changeit`).

## 2. Build

```sh
just build
```

Builds with LDC 1.27.1 inside the Guix shell (real OpenSSL 3.0.7).

## 3. Run

```sh
just run -- 8443
```

Server logs the HTTPS listener and multicast discovery settings.

## 4. Verify mutual TLS

```sh
# Success — valid client cert:
curl --cacert certs/certs/ca.crt \
     --cert certs/certs/client.crt --key certs/private/client.key \
     https://localhost:8443/hello%20world
# → hello world

# Failure — no client cert:
curl --cacert certs/certs/ca.crt https://localhost:8443/hello
# → TLS handshake error

# Failure — cert from another CA:
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout /tmp/e.key \
  -out /tmp/e.crt -subj "/CN=evil"
curl --cacert certs/certs/ca.crt --cert /tmp/e.crt --key /tmp/e.key \
  https://localhost:8443/hello
# → TLS handshake error
```

## 5. Discovery

Start two instances on the same host (loopback multicast is enabled):

```sh
just run -- 8443 &        # instance A
just run -- 8543 &        # instance B
```

Within ~5 s each instance logs the other:

```text
[discovery] peer at 127.0.0.1:4242 -> mtls-hello on port 8543   (on A)
[discovery] peer at 127.0.0.1:4242 -> mtls-hello on port 8443   (on B)
```

To disable discovery: `just run -- 8443 --no-multicast`.

## 6. Automated tests

```sh
just test
```

BATS suite starts its own server on port 18443 and verifies all four contracts (no-cert rejected, untrusted rejected, echo, content type).

## Troubleshooting

- **Link errors about `ERR_new`/`ERR_set_error`**: you are linking against the host's LibreSSL. Use the Guix shell (`just build`).
- **`failed to locate cc` / gold linker**: inside Guix, LDC needs the `cc`→`gcc` shim and `--linker=bfd` (already handled by the documented commands in research.md; `just build` wraps this).
- **dub registry errors**: `code.dlang.org` may be unreachable from Guix's libcurl; dependencies are pinned in `dub.selections.json` and cached locally. Use `--skip-registry=standard`.
