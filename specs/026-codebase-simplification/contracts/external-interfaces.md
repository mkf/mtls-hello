# Contract: External Interfaces Preserved

**Date**: 2026-08-07
**Feature**: 026-codebase-simplification

The simplification MUST NOT change any externally observable behavior.
This document enumerates every external interface and what must be preserved.

## HTTP Endpoints (Apache + CGI)

| Endpoint | Method | Handler | Status codes | Observable contract |
|----------|--------|---------|-------------|---------------------|
| `/hello/<path>` | GET | hello.get.sh | 200 text/plain, 401 | Echoes `<path>` as text/plain for trusted clients |
| `/head/<path>` | GET | head.get.sh | 200 text/plain, 401 | Returns headers only |
| `/cert-echo` | GET | cert-echo.get.sh | 200 text/plain, 401 | Echoes client cert info |
| `/bundle` | POST | bundle.post.sh | 200/204, 401, 400 | Accepts git bundle upload |
| `/spool` | GET | spool.get.sh | 200 text/plain, 401 | Reports spool coverage |
| `/drop/<hostname>/<rest>` | GET/PUT/HEAD/PROPFIND/etc | drop-proxy.sh + mod_dav | 200/201/204/207/403/401 | Per-host drop-box via WebDAV |
| `/nncp/receive` | POST | nncp-receive.post.sh | 202, 502, 501 | Accepts NNCP packet, runs nncp-toss |

**Preservation rule**: Same status codes, same Content-Type, same response body
shape. Handler filenames may NOT change (Apache `ScriptAlias` references them).

## CGI Environment Variables

These are set by Apache's `mod_ssl` + `mod_cgi` and consumed by handlers:

| Variable | Set by | Consumed by | Must be preserved? |
|----------|--------|-------------|---------------------|
| `SSL_CLIENT_CERT` | mod_ssl | All handlers (via cgi-lib) | Yes |
| `SSL_CLIENT_VERIFY` | mod_ssl | log-capture, _run-parts | Yes |
| `MTLS_DATA_DIR` | mod_cgi SetEnv | All handlers | Yes |
| `MTLS_TRUST_DIR` | mod_cgi SetEnv | cgi-trust is_trusted() | Yes |
| `MTLS_NNCP_DIR` | mod_cgi SetEnv | nncp-receive handler | Yes |
| `PATH_INFO` | mod_cgi | hello, head handlers | Yes |
| `QUERY_STRING` | mod_cgi | cgi_parse_query() | Yes |

**Preservation rule**: The library functions that read these env vars must keep
the same names. Internally, the library may use different local variable names.

## Multicast Discovery Protocol

| Aspect | Value | Must be preserved? |
|--------|-------|---------------------|
| Multicast group | 239.255.42.42 | Yes |
| Multicast port | 4242 | Yes |
| Payload format | JSON: `{"port": <int>, "host": "<hostname>"}` | Yes |
| Announcement interval | 5 seconds (default) | Yes |
| Capture callback path | `<data-dir>/scripts/on-discovery.d/_run-parts.sh` | Yes |

## Filesystem Layout (under `--data-dir`)

| Path | Purpose | Must be preserved? |
|------|---------|---------------------|
| `identity/<hostname>.crt` + `.key` | Self-signed mTLS identity | Yes |
| `hosts/<hostname>.crt` | Trusted peer certificates | Yes |
| `purgatory/<hostname>.<fingerprint>.crt` | Untrusted captured certs | Yes |
| `drop/<hostname>/<rest>` | mod_dav per-host drop-box | Yes |
| `nncp.hjson` | NNCP self + neigh config | Yes |
| `nncp/queues/<id>/inbound/` | NNCP packet spool | Yes |
| `scripts/on-discovery.d/*.sh` | Discovery callback chain | Yes (filenames) |
| `apache/httpd.conf` + `site.conf` | Rendered Apache config | Yes |

## CLI Wrappers (user-facing commands)

| Command | Verb | Must be preserved? |
|---------|------|---------------------|
| `mtls-cp` | COPY | Yes |
| `mtls-del` | DELETE | Yes |
| `mtls-drop` | PUT (upload) | Yes |
| `mtls-fetch` | GET (download) | Yes |
| `mtls-head` | HEAD | Yes |
| `mtls-ls` | PROPFIND (list) | Yes |
| `mtls-mkcol` | MKCOL | Yes |
| `mtls-mv` | MOVE | Yes |
| `mtls-props` | PROPFIND (props) | Yes |

**Preservation rule**: Same command names, same flags, same exit codes, same
stdout format.

## What MAY Change

These are internal implementation details that are NOT externally observable:

- Internal shell function names (e.g., `cgi_header` → renamed is OK as long as handlers still emit the same CGI headers)
- Which `.sh` file a function lives in (merge/split is OK)
- The number of `source` lines at the top of a handler (2 → 1 is OK)
- Internal variable names inside functions
- Error message wording (meaning must be equivalent; exact text may change)
- Test file internal structure (setup helpers, fixture creation)
