# Research: Cert Capture via Logging Pipeline

**Date**: 2026-08-06
**Feature**: specs/021-cert-capture-via-log/spec.md

## Open questions from the spec

1. Does `%{SSL_CLIENT_CERT}e` actually populate inside a piped Apache `CustomLog`?
2. How is the multi-line PEM certificate handled on a line-oriented log pipe?
3. Can the capture path distinguish a certificate that *fails the project's custom trust check*?
4. Can unknown/untrusted hosts be *rejected at the connection level* (US4)?

## Method

A throwaway Apache 2.4.67 instance was booted with `SSLVerifyClient optional_no_ca`
and `SSLOptions +StdEnvVars +ExportCertData`, plus a piped logger:

```
LogFormat "%{SSL_CLIENT_S_DN}e\t%{SSL_CLIENT_VERIFY}e\t%{SSL_CLIENT_CERT}e\tCERTEND" certfmt
CustomLog "|/tmp/captest/capture.sh" certfmt
```

A request was made with a self-signed client cert (`CN=testclient`). The piped
script wrote each stdin line to a file.

## Findings

### 1. `%{SSL_CLIENT_CERT}e` populates in a piped CustomLog — CONFIRMED

The full PEM certificate reached the piped script. Also useful in the same line:
`%{SSL_CLIENT_S_DN}e` (`CN=testclient`) and `%{SSL_CLIENT_VERIFY}e`
(`FAILED:self-signed certificate`).

Captured bytes for one request: 1188, including the complete escaped PEM.

### 2. Newlines are escaped — one line per request — CONFIRMED (better than expected)

Apache's `mod_log_config` writes the PEM's newlines as the **literal two
characters `\n`** (backslash + n), and appends a single real newline to terminate
the entry. So each request is exactly one line on the pipe, e.g.:

```
CN=testclient\tFAILED:self-signed certificate\t-----BEGIN CERTIFICATE-----\nMIID...\n-----END CERTIFICATE-----\n\tCERTEND
```

**Implication**: the capture script receives one well-formed line per request.
It only needs to unescape `\n` (→ real newline) when writing the `.crt` file.
The multi-line-framing problem I assumed would need a sentinel delimiter does
**not** exist. A trailing `CERTEND` field is still kept as a cheap integrity
marker but is not strictly required for framing.

### 3. Distinguishing trust-failing certs — FEASIBLE

Project trust is a *custom* notion: a cert file exists in the trust directory
under `<hostname>.crt` and its SHA-256 fingerprint matches (this is what
`cgi-trust.sh` does). It is **not** Apache's TLS verification (`%{SSL_CLIENT_VERIFY}e`
reports Apache's CA check, which is irrelevant under `optional_no_ca`).

The piped capture script receives the full PEM, so it can:
- unescape and parse the cert,
- compute the SHA-256 fingerprint,
- derive the hostname from the subject DN (fallback `unknown`),
- check the trust directory exactly like `cgi-trust.sh`.

Therefore the capture path **can** identify and selectively record trust-failing
certs (and simply no-op for already-trusted ones). The premise of the user's
conditional ("if apache lets us log a cert that fails the trust") is **satisfied**.

### 4. Connection-level rejection of unknown hosts (US4) — INFEASIBLE as stated

Two independent reasons:

- **Piped logs run after the response.** The logger records but cannot *cause* a
  rejection; by the time it sees a request, the TLS handshake is already done and
  the response is already being/has been sent.
- **TLS-layer rejection needs a CA.** Rejecting at handshake time requires
  `SSLVerifyClient require` with a trust anchor. The project deliberately uses
  ad-hoc self-signed certs (feature 010) with **no CA**, so `require` cannot
  accept any cert. `optional_no_ca` accepts every cert by design.

The only feasible form of "reject unknown hosts" is **handler-level**: every
endpoint returns an error status for an untrusted client. This largely already
exists (protected endpoints already `cgi_error 401` for untrusted clients);
capturing still happens via the log pipeline so no evidence is lost.

## Decisions

- **D001 — Adopt the piped-log capture as the capture mechanism.**
  Rationale: experimentally confirmed to deliver the full PEM, one line per
  request, with built-in newline escaping. Removes per-handler capture code.
  Alternatives considered: keep per-handler `cgi-capture.sh` (rejected — the
  "ugly" duplication the user wants gone); a custom Apache module (rejected —
  overkill); `mod_security` (rejected — not present, heavy).

- **D002 — Log format includes DN, verify-result, and cert.**
  `LogFormat "%{SSL_CLIENT_S_DN}e\t%{SSL_CLIENT_VERIFY}e\t%{SSL_CLIENT_CERT}e\tCERTEND"`.
  Rationale: DN gives a hostname candidate and a human label; verify-result is a
  free diagnostic; the cert is the payload; `CERTEND` is a cheap integrity marker.

- **D003 — The capture script filters on the project trust state.**
  It computes fingerprint + hostname and checks the trust dir. It writes to
  purgatory only for *untrusted* certs (trusted certs are a no-op), matching the
  user's "log a cert that fails the trust". Dedup is automatic via the
  `<hostname>.<fingerprint>.crt` filename.

- **D004 — US4 connection-level rejection is dropped (treated as "nvm" for the
  rejection half).** The capture-of-failing-certs premise is feasible, but actual
  connection refusal is impossible with self-signed/no-CA certs + stock Apache
  and a post-response logger. Handler-level 401 for untrusted clients is the
  feasible equivalent and is already in place. The spec's US4/FR-008/SC-006
  should be re-scoped to: *untrusted clients are never served (all endpoints
  reject), while their certs are still recorded via the log pipeline.* This keeps
  the spirit (unknown hosts get nothing) without claiming an impossible TLS-level
  refusal.

- **D005 — Remove `cgi-capture.sh` sourcing and `capture_client_cert` calls from
  all handlers.** The handlers keep only their trust check + business logic.
  `cgi-capture.sh` is retired (kept in tree until tasks confirm removal, then
  deleted).

## Risks

- **Logger process lifecycle**: Apache spawns the piped logger once and restarts
  it if it dies, so capture is resilient. A crash pauses capture but never breaks
  serving (FR-004/US3 satisfied by construction).
- **Empty cert (`SSL_CLIENT_VERIFY=NONE`)**: `%{SSL_CLIENT_CERT}e` is empty; the
  script skips. Covered.
- **Escaped backslashes inside PEM**: PEM body is base64 (no backslashes), so
  only `\n` sequences appear; `printf '%b'`-style unescaping is safe.
- **Concurrent identical certs**: dedup by filename; last writer wins, content
  identical — safe.
