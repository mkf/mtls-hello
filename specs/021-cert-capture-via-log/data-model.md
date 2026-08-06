# Data Model: Cert Capture via Logging Pipeline

## Entity: LogEntry (transient)

A single line emitted by the piped `CustomLog`, consumed by the capture script.
Not persisted as such; parsed on read.

### Fields

| Field | Source (LogFormat token) | Description |
|-------|--------------------------|-------------|
| `subject_dn` | `%{SSL_CLIENT_S_DN}e` | Client certificate subject, e.g. `CN=testclient`. Used to derive a hostname/filename hint. |
| `ssl_verify` | `%{SSL_CLIENT_VERIFY}e` | Apache's TLS verification result (`NONE`, `SUCCESS`, or `FAILED:...`). Diagnostic only; **not** the project trust state. |
| `cert_pem_escaped` | `%{SSL_CLIENT_CERT}e` | Full PEM with newlines escaped as literal `\n`. Empty when no cert was presented. |

### Framing

Each request is exactly one line terminated by a real newline. Fields are
tab-separated. The literal token `CERTEND` terminates the record as an integrity
marker (optional given Apache's newline escaping, but cheap).

### Validation

- An entry with an empty `cert_pem_escaped` is ignored (no client cert).
- Malformed lines (no `CERTEND` or unparseable PEM after unescaping) are skipped
  with a warning; capture never aborts the logger.

## Entity: Captured Certificate (persistent, unchanged)

| Field | Description | Example |
|-------|-------------|---------|
| `hostname` | Derived from the cert subject CN; fallback `unknown`. | `testclient` |
| `fingerprint` | SHA-256 of the DER (hex). | `a3b2c9...` |
| `path` | `<purgatory-dir>/<hostname>.<fingerprint>.crt` | `purgatory/testclient.a3b2c9....crt` |

Naming and dedup semantics are unchanged from the existing system
(`<hostname>.<fingerprint>.crt`), so `trust-host.sh` promotion is unaffected.

### State transition (per presented cert, per request)

```text
request presented ─▶ log entry on pipe
                   │
                   ▼
            unescape + parse cert
                   │
            compute fingerprint + hostname
                   │
            check trust dir ── trusted? ──▶ no-op (do not pollute purgatory)
                   │ no
                   ▼
            write/overwrite <hostname>.<fingerprint>.crt  (dedup by filename)
```
