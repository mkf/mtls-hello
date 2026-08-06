# Contract: Piped-Log Capture Script

## Purpose

Define the piped `CustomLog` configuration and the capture script's behavior that
replaces the per-handler `cgi-capture.sh` mechanism.

## Apache configuration

A new `LogFormat` and piped `CustomLog` are added to the generated site config
(`config/apache-site.conf.in` / `scripts/apache-config.sh`):

```
LogFormat "%{SSL_CLIENT_S_DN}e\t%{SSL_CLIENT_VERIFY}e\t%{SSL_CLIENT_CERT}e\tCERTEND" mtls_cert_fmt
CustomLog "|<data-dir>/scripts/log-capture.sh <trust-dir> <purgatory-dir>" mtls_cert_fmt env=MTLS_HAS_CLIENT_CERT
```

- `env=MTLS_HAS_CLIENT_CERT` (recommended) gates the log so entries are emitted
  only when a client cert was presented, avoiding empty lines. If the `SetEnv`
  gating is not added, the script must tolerate empty `cert_pem_escaped`.
- Requires `SSLOptions +StdEnvVars +ExportCertData` (already present) so that
  `SSL_CLIENT_CERT`, `SSL_CLIENT_S_DN`, and `SSL_CLIENT_VERIFY` are in the
  request env table that `mod_log_config` reads.

## Script: `scripts/log-capture.sh`

A long-lived process. Apache spawns it once and pipes log lines to its stdin; it
is restarted automatically if it exits.

### Invocation

```
log-capture.sh <trust-dir> <purgatory-dir>
```

Reads request lines from stdin until EOF. One line per request, tab-separated:
`<subject_dn>\t<ssl_verify>\t<cert_pem_escaped>\tCERTEND`.

### Per-line behavior

1. Split on tab into the four fields.
2. If `cert_pem_escaped` is empty → skip (no client cert).
3. Unescape `\n` → real newline to recover the PEM.
4. Compute SHA-256 fingerprint of the DER (`openssl x509 -fingerprint -sha256`).
5. Derive hostname from `<subject_dn>` (`CN=...`); fallback `unknown`.
6. If a matching trusted cert exists in `<trust-dir>` (same fingerprint for the
   hostname, per existing trust rules) → no-op.
7. Else write/overwrite `<purgatory-dir>/<hostname>.<fingerprint>.crt` with the
   PEM. (Dedup is automatic via filename.)

### Non-functional guarantees

- **Never exits on a bad line**: log a warning to stderr and continue.
- **Never blocks serving**: it only writes a small file; a slow disk at worst
  delays that one capture, not the HTTP response (which already completed).
- **Idempotent**: rewriting an identical file is a no-op effect.
- **Shellcheck-clean**, `set -euo pipefail` inside the read loop guarded so a
  single bad line cannot kill the logger.

## Installation

`scripts/install.sh` copies `log-capture.sh` into the data-dir scripts directory
alongside the other scripts, and the generated `httpd.conf` references it via the
`CustomLog "|..."` pipe with absolute paths.

## Handler contract change

CGI handlers (`hello.get.sh`, `head.get.sh`, `spool.get.sh`, `bundle.post.sh`,
`cert-echo.get.sh`):
- **Remove**: `source cgi-capture.sh` and the `capture_client_cert` call.
- **Keep**: the trust check (`cgi-trust.sh`) and business logic.

`scripts/cgi-capture.sh` is deleted once all handlers are updated.
