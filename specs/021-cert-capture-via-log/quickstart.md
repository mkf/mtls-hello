# Quickstart: Cert Capture via Logging Pipeline

## What this feature does

Peer certificates are now captured into purgatory by a single piped Apache
`CustomLog` that runs for every request, instead of each CGI handler calling a
capture helper. Handlers no longer contain any capture code.

## Inspect the capture path

The piped logger is configured in the generated Apache config:

```
CustomLog "|<data-dir>/scripts/log-capture.sh <trust-dir> <purgatory-dir>" mtls_cert_fmt
```

Log format:

```
%{SSL_CLIENT_S_DN}e\t%{SSL_CLIENT_VERIFY}e\t%{SSL_CLIENT_CERT}e\tCERTEND
```

Apache escapes the PEM's newlines as literal `\n`, so each request is one line.

## Verify capture end-to-end

1. Boot the server against a scratch data dir.
2. Connect with an untrusted self-signed client cert to any endpoint.
3. Confirm the cert appears in `<data-dir>/purgatory/<hostname>.<fingerprint>.crt`.
4. Confirm the handler no longer references `cgi-capture.sh`.
5. Connect again with the same cert; confirm purgatory still holds exactly one
   file for it (dedup).
6. Promote it with `trust-host.sh`; reconnect; confirm no new purgatory file is
   written (trusted certs are a no-op).

## Verify the logger is resilient

- Send a request with **no** client cert → no capture, no error.
- Kill the logger process → Apache restarts it; serving is unaffected.

## Run the tests

```
just test-d
just robot
```

The existing "Capture Untrusted Cert In Purgatory" and "Promote Captured Cert
And Trust" Robot cases must still pass unchanged.

## Note on connection-level rejection (US4)

True TLS-level rejection of unknown self-signed peers is **not** feasible
(no CA + post-response logger; see `research.md` §4). Unknown clients are instead
rejected at the handler layer (401), exactly as before, while their certs are
still recorded by the log pipeline.
