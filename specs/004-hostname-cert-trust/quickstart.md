# Onboarding: Trusting a Peer's Self-Signed Certificate

**Branch**: `004-hostname-cert-trust` | **Date**: 2026-08-05 | **Feature**: [spec.md](./spec.md)

This is the onboarding guide: how to take a self-signed certificate from another host and make it trusted on your side. The rule is simple — **a host is trusted only if its certificate is present locally under the host's name, and it matches.** There is no automatic trust just because a host connected.

## Prerequisites

- Features 001–003 built and working (`just build`).
- GNU Guix with the daemon running; git checkout of this branch.

## 1. Get the peer's self-signed certificate

The peer must export its public certificate (PEM). On the peer host, the certificate's **common name (CN)** must be the name you will use for it locally, e.g. `alpha.local`:

```sh
# On the peer host — generate once (keeps the same key/cert):
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout alpha.key -out alpha.crt -subj "/CN=alpha.local"
```

Copy the **certificate** (not the key) to your host, e.g.:

```sh
scp peer-host:alpha.crt .
```

## 2. Make it trusted locally

```sh
bash scripts/trust-host.sh alpha.local alpha.crt
```

The script checks that the certificate's name matches `alpha.local`, installs it as `certs/hosts/alpha.local.crt`, and prints a verification hint.

> Manual alternative: `cp alpha.crt certs/hosts/alpha.local.crt` — you are responsible for the name matching the CN.

## 3. Verify it took effect

Start the server and connect with the peer's certificate and key:

```sh
just run -- 8443 certs/certs/server.crt certs/private/server.key
# in another terminal:
curl --cacert certs/certs/server.crt \
     --cert alpha.crt --key alpha.key \
     https://alpha.local:8443/status
```

If it works, the server log shows a `trusted` decision for `alpha.local`. If the request fails, see the server log — the decision line tells you why (`unknown`, `mismatch`, `expired`, `invalid-name`).

## 4. What about hosts that tried to connect before you trusted them?

Their certificates land in **purgatory** (`certs/purgatory/`), named `<hostname>.<fingerprint>.crt` — they are NOT trusted by being there. To trust one:

```sh
bash scripts/trust-host.sh alpha.local certs/purgatory/alpha.local.<fingerprint>.crt
```

Then verify as in step 3.

## 5. Automation / tests

```sh
just test        # includes trust, purgatory, and promotion tests
```

## Troubleshooting

- **Connection rejected, log says `unknown`**: no entry in `certs/hosts/` for that hostname. Get the cert and run `trust-host.sh`.
- **Log says `mismatch`**: a different certificate is stored for that hostname than the one presented (key rotation or a different peer). Review carefully; update the store only if intended.
- **Log says `expired`**: the stored certificate is past its validity date; obtain a fresh cert and promote it.
- **Log says `invalid-name`**: the presented certificate has no CN/SAN to derive a hostname from; fix the certificate.
- **I get glibc errors running `./scripts/trust-host.sh` inside the Guix shell**: host `/bin/bash` loads the wrong libc under the Guix shell's `LD_LIBRARY_PATH`. Invoke the helper through the Guix shell's `bash` instead: `bash scripts/trust-host.sh ...`.
