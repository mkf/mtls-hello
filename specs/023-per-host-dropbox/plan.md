# Implementation Plan: Per-Host Drop-Box

**Branch**: `023-per-host-dropbox` | **Date**: 2026-08-06 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/023-per-host-dropbox/spec.md` (updated 2026-08-06 to **explicit-per-hostname** URL semantics after clarification).

**Note**: This plan **supersedes** the earlier plan from `a163fc121d` that relied on bash CGI handlers reading `SSL_CLIENT_S_DN_CN` themselves. The current architecture removes all 9 bash handlers and the helper module, in favor of Apache's own `mod_dav` engine.

## Summary

A per-host drop-box at `/drop/<hostname>/<rest>`, where each trusted client (identified by mTLS cert CN) accesses only its own prefix and is rejected (403) when it tries another's.

The architecture is **two Apache VirtualHosts + `mod_dav`**:

```text
       ┌─────────────────────────────────────────────────────────┐
       │ Public mTLS VH    :8443                                  │
       │   SSLVerifyClient optional_no_ca                        │
       │   <Location /drop>                                       │
       │     RewriteMap trust_check prg:.../scripts/trust-check.sh│
       │     RewriteRule ...  prefix-vs-CN guard                 │
       │     [P] proxy to http://127.0.0.1:8444                   │
       └───────────┬─────────────────────────────────────────────┘
                   │
                   ▼
       ┌─────────────────────────────────────────────────────────┐
       │ Loopback VH        127.0.0.1:8444 (only)                 │
       │   DocumentRoot = <data-dir>/drop/                        │
       │   Dav On                                                │
       │   <Directory> Require all granted                         │
       │   (mod_headers adds Content-Disposition on GET)         │
       └───────────┬─────────────────────────────────────────────┘
                   │
                   ▼
       <data-dir>/drop/<cn>/<rest>       # mod_dav_fs serves 1:1
```

**Why this is dramatically simpler than the earlier plan**: with a static `DocumentRoot` rooted at `<data-dir>/drop/` and `mod_dav` enabled, the loopback VH satisfies the per-host partitioning **for free** — the URL `/alice/x.txt` maps to filesystem `<data-dir>/drop/alice/x.txt`. mod_dav does:

- PUT, GET, HEAD, DELETE (FR-004, FR-005, FR-012)
- ETag + Last-Modified headers (FR-010)
- `If-Match`/`If-None-Match`/`If-Modified-Since`/`If-Unmodified-Since` (FR-010)
- `Range` → 206 Partial Content (FR-011)
- MKCOL (FR-009), COPY/MOVE (FR-009), empty-Dir-DELETE (FR-015), PROPFIND (FR-014), OPTIONS
- Content-Type via mod_mime mapping (FR-013)

The public mTLS VH does the only part that requires identity-aware logic: ensure the URL's first segment equals the verified CN (FR-002 / FR-003), and gate by fingerprint (FR-007). Both are tiny pieces of `mod_rewrite` config plus a 30-line `scripts/trust-check.sh` `RewriteMap` program.

**No 9 bash handlers. No `scripts/cgi-dropbox.sh`.** Those files from the earlier plan (`f668d12531`) are deleted by this plan; Apache replaces them with off-the-shelf, well-tested behavior.

**Client wrappers**: 9 small bash CLIs (`cli/mtls-drop.sh`, `mtls-fetch.sh`, ..., `mtls-mv.sh`) over `curl --cert ... --key ... --cacert ...`. A tiny helper derives `/drop/<cn>/<rest>` from the cert's CN.

## Technical Context

**Language/Version**:
- Apache httpd 2.4 with: `mod_ssl` (mTLS), `mod_rewrite`, `mod_proxy`, `mod_proxy_http`, **`mod_dav`**, **`mod_dav_fs`**, `mod_headers`, `mod_mime`, `mod_setenvif`.
- D 2.x / LDC for the supervisor daemon (unchanged).
- bash 4+ for `scripts/trust-check.sh` and the client wrappers.
- openssl CLI (already a runtime dep).
- curl (already a runtime dep used by on-discover.sh).

**Primary Dependencies**:
- `mod_dav` + `mod_dav_fs`: the entire storage engine. Apache ships this in `apache2-bin`/`apache2-mod_dav` on Debian and Arch. The Nix shell's Apache must include it.
- `mod_proxy_http`: needed for the public→loopback proxy pass.
- `mod_rewrite` with `RewriteMap prg:`: the trust gate.
- `mod_headers`: adds `Content-Disposition: attachment` on `/drop` GET responses.
- `scripts/trust-check.sh` (NEW): a small bash program invoked by `mod_rewrite` as a `RewriteMap` prg.

**Storage**: filesystem under `<data-dir>/drop/<cn>/<rest>`. The loopback Apache has `DocumentRoot = <data-dir>/drop/`. mod_dav_fs maps URLs 1:1 to filesystem paths under that root. Each `<cn>/` directory is auto-created on first PUT/MKCOL (mod_dav creates parent directories on PUT). No xattrs, no sidecar files — mod_dav handles metadata natively via Apache's file metadata (mtime, size, inode).

**Testing**:
- bats: a small `tests/trust-check.bats` for `scripts/trust-check.sh` — fingerprint-match logic, REJECT path, certificate-replay, missing-cert paths.
- Robot Framework: live Apache test (new `robot/dropbox.robot` or extend `mtls_hello.robot`) exercises the full proxy→loopback stack:
  - Trusted alice PUTs `/drop/alice/x.txt`, GETs back identical bytes.
  - Trusted bob PUTs `/drop/bob/x.txt`, GETs back identical bytes.
  - alice attempts `/drop/bob/x.txt` → 403 Forbidden from proxy edge.
  - Untrusted client → 401 from proxy edge.
  - PROPFIND Depth 0 returns multistatus (mod_dav).
  - MKCOL/COPY/MOVE roundtrip.
  - Range fetch on a large file.
  - Conditional-GET 304 roundtrip via ETag.
  - Empty-directory DELETE works; non-empty returns 409.

**Target Platform**: Linux (Debian `.deb`, Arch `.pkg.tar.zst`, plain install — same as rest of project). Apache must include `mod_dav` (Debian: `a2enmod dav dav_fs dav_lock`; Arch: shipped in core Apache; Nix: pinned Apache config must include `mod_dav`, `mod_dav_fs`, `mod_dav_lock` modules).

**Project Type**: web-service (Apache + D daemon + bash) — extension of existing service.

**Performance Goals**: not throughput-bound. mod_dav is the right tool for ad-hoc drop-box use. Single-AVH proxy hop on `127.0.0.1` is sub-millisecond.

**Constraints**:
- Mutually-authenticated TLS only, no CA (per feature 010).
- **Per-host isolation enforced at the proxy edge** before `[P]` forward (single-line RewriteRule + trust-check).
- **DocumentRoot + mod_dav_fs** gives path-safety by construction: mod_dav canonicalizes `..` and refuses to leave the document root (FR-006); no separate path-traversal defense is required.
- `--data-dir` is the single base (per feature 022); drop-box lives at `<data-dir>/drop/`.
- The mTLS-edge VH boundary is `optional_no_ca` so untrusted certs come through and are explicitly rejected by the trust-check RewriteMap (`REJECT` ↦ 401). For trusted-but-wrong-prefix, Apache's own proxy returns 403 via the prefix-guard `RewriteRule`. We do not depend on per-handler trust logic.

**Scale/Scope**: LAN-sized set of trusted peers; tens of hosts typical; per-call file counts in the thousands at most; per-file size typical tens of KB, occasionally hundreds of MB (Range is configured).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The `.specify/memory/constitution.md` is the unfilled template; default spec-kit principles apply.

| Principle | Status | Note |
|---|---|---|
| Library-first | OK | mod_dav / mod_dav_fs are the libraries; we consume them, not reimplement them. |
| CLI Interface | OK | `cli/mtls-*` are the public CLI; Apache modules do the work. |
| Test-First | OK | BATS for trust-check.sh; Robot Framework for full Apache stack. |
| Integration Testing | OK | Robot stands up real Apache with two identities and exercises cross-host 403, mod_dav PROPFIND, Range, MKCOL/COPY/MOVE, conditional GET. |
| Observability | OK | Existing Apache access log + custom cert-capture log (feature 021) work unchanged. Trust-check.sh emits one-line status per request to Apache's error log. |
| Simplicity | OK | **Major** simplification vs. earlier plan: 9 bash handlers + ~11 kB helpers + ~12 kB bats suite deleted; replaced by Apache's own mod_dav behaviour and a 30-line trust-check.sh. No new dependency on mod_proxy (Apache ships it together with mod_ssl). |

**Re-check (post-design)**: No new principles introduced; the design is a consolidation on standard Apache modules + a tiny `RewriteMap` program.

No unjustified violations.

## Project Structure

### Documentation (`specs/023-per-host-dropbox/`)

```
specs/023-per-host-dropbox/
├── plan.md             # this file
├── research.md         # Phase 0 output
├── data-model.md       # Phase 1 output
├── contracts/
│   ├── dropbox-http.md # HTTP method contract (deferred to mod_dav behaviour)
│   └── client-cli.md   # client wrapper CLI contract
├── quickstart.md       # Phase 1 output
└── spec.md             # /speckit.specify output (explicit-per-hostname; already updated)
```

### Source Code (additions and changes only)

```
config/
└── apache-site.conf.in # REWRITTEN to two VHs (see "Apache VHost wiring" below)
tests/
└── trust-check.bats    # NEW: bats unit tests for scripts/trust-check.sh
robot/
└── dropbox.robot       # NEW: live Apache end-to-end (extends mtls_hello.robot harness)
scripts/
├── trust-check.sh      # NEW: ~30-line RewriteMap program (CN → CN|REJECT)
└── ci/                 # EXISTING: no change

cli/                    # NEW directory
├── README.md           # lists the family
├── _common-cname.sh    # tiny helper: read CN from a client cert file (xml-libxml/awk-stripped)
├── mtls-drop.sh        # curl -X PUT  --cert ... --key ... --cacert ... -T <local>
├── mtls-fetch.sh       # curl -X GET, supports --range a-b and --if-none-match <sha>
├── mtls-head.sh        # curl -X HEAD, parses + prints headers
├── mtls-del.sh         # curl -X DELETE, supports --if-match <sha>
├── mtls-ls.sh          # curl -X PROPFIND -H 'Depth: 1', human-readable formatting
├── mtls-props.sh       # curl -X PROPFIND -H 'Depth: 0', structured info
├── mtls-mkcol.sh       # curl -X MKCOL
├── mtls-cp.sh          # curl -X COPY  -H 'Destination: /drop/<dest>'
└── mtls-mv.sh          # curl -X MOVE  -H 'Destination: /drop/<dest>'
```

### Files DELETED (vs. earlier plan from `f668d12531`)

```
handlers/drop.put.sh         # superseded by mod_dav PUT on the loopback VH
handlers/drop.get.sh         # superseded by mod_dav GET
handlers/drop.head.sh        # superseded by mod_dav HEAD
handlers/drop.delete.sh      # superseded by mod_dav DELETE
handlers/drop.mkcol.sh       # superseded by mod_dav MKCOL
handlers/drop.copy.sh        # superseded by mod_dav COPY
handlers/drop.move.sh        # superseded by mod_dav MOVE
handlers/drop.propfind.sh    # superseded by mod_dav PROPFIND
handlers/drop.options.sh     # superseded by Apache OPTIONS
scripts/cgi-dropbox.sh       # superseded by mod_dav (helpers not needed in handlers)
tests/dropbox.bats           # superseded (helpers no longer exist)
```

### Apache VirtualHost wiring

```apache
# VH :8443 (public mTLS edge)
<VirtualHost *:8443>
    ServerName localhost
    SSLEngine on
    SSLCertificateFile .../identity/<hostname>.crt
    SSLCertificateKeyFile .../identity/<hostname>.key
    SSLVerifyClient optional_no_ca
    SSLOptions +StdEnvVars +ExportCertData

    # Trust gate: a single RewriteMap program runs the fingerprint match.
    RewriteEngine On
    RewriteMap trust_check prg:/home/me/.local/share/mtls-hello/scripts/trust-check.sh \
                  /home/me/.local/share/mtls-hello/hosts

    # /drop per-host isolation:
    #   - /drop/        -> REJECT  (no host segment)
    #   - /drop/<cn>/... with cn != verified CN -> REJECT  (cross-host 403)
    #   - /drop/<cn>/... with cn == verified CN AND fingerprint matches -> P-proxied
    RewriteCond %{ENV:trustee_cn}        =^$              [OR]
    RewriteCond %{ENV:trustee_cn} "!=%{ENV:SSL_USER_NAME}"
    RewriteRule ^/drop/(.*)$             -               [F]
    # ... (mod_proxy pass to loopback VH)

    ProxyPass        /drop/  http://127.0.0.1:8444/ nocanon
    ProxyPassReverse /drop/  http://127.0.0.1:8444/

    ErrorLog   /var/log/mtls-hello/public-error.log
    CustomLog  /var/log/mtls-hello/public-access.log combined
</VirtualHost>

# VH :8444 (loopback mod_dav backend)
<VirtualHost 127.0.0.1:8444>
    ServerName localhost
    DocumentRoot "/var/lib/mtls-hello/drop"
    Dav On
    AllowEncodedSlashes NoDecode
    DirectoryIndex disabled

    <Directory "/var/lib/mtls-hello/drop">
        Options +Indexes           # not strictly needed; mod_dav handles everything
        Require all granted
        Header set Content-Disposition "attachment" env=!IS_DAV_PROPFIND
    </Directory>

    ErrorLog  /var/log/mtls-hello/backend-error.log
    CustomLog /var/log/mtls-hello/backend-access.log combined
</VirtualHost>
```

### Structure Decision

Web-service extension; reuse the project's existing top-level layout (handlers/, scripts/, config/, tests/, robot/, justfile). Add one new directory `cli/`. **No new top-level directories are introduced; no top-level modules are added.** mod_dav replaces ~700 lines of bash CGI handlers and helpers.

## Complexity Tracking

> **None required.** This plan is **strictly simpler** than the previously-committed bash-handler approach (`f668d12531`). It removes ~14 kB of bash (handlers + helpers + bats) and replaces them with Apache's off-the-shelf mod_dav behaviour plus a 30-line trust-check.sh.

If during implementation a specific concern forces us to step *back* into bash (e.g., we need a custom ETag format like `sha256:<hex>` and mod_dav's default `FileETag` doesn't give that), we will factor just that one piece into the minimum needed — and document the simplicity trade-off in the spec's `## Clarifications` section.
