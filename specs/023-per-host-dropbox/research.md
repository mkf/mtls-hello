# Research: Per-Host Drop-Box (`023-per-host-dropbox`)

**Date**: 2026-08-06 (mod_dav-first revision; supersedes the bash-handler design)

This document captures the technical decisions and their rationale for the mod_dav-based per-host drop-box. Each **Decision** entry follows the *what was chosen / why chosen / rejected alternatives* pattern.

The plan pivots away from the bash CGI handlers in commit `f668d12`. The spec clarification at `6bce43d` decoupled the per-host identity from the URL — when `/drop/<cn>/<rest>` is explicit, mod_dav's static DocumentRoot at `<data-dir>/drop/` maps URLs 1:1 to filesystem paths **with zero translation**, making the bash helpers and per-handler trust-gate logic redundant.

---

## Decision R1 — `mod_dav` + `mod_dav_fs` is the storage engine

**What was chosen**: `Dav On` on a loopback VirtualHost with `DocumentRoot = <data-dir>/drop/`. mod_dav's filesystem provider maps URLs 1:1 to filesystem paths under DocumentRoot.

**Why chosen**:
- mod_dav implements all the heavyweight HTTP/DAV behaviour natively: ETag (Apache's `FileETag`), `If-Match`/`If-None-Match`/`If-Modified-Since`/`If-Unmodified-Since`, `Range` -> 206 Partial Content, MKCOL, COPY, MOVE, PROPFIND (multistatus), OPTIONS / `Allow:`. Each is a standards-track RFC behaviour with thousands of interoperability-tested implementations behind it.
- Strict path-safety by construction: mod_dav canonicalises `..` segments and serves resources only under the configured DocumentRoot. The path-traversal defence (FR-006) is therefore handled by Apache, not by our code.
- No new runtime dependency: `mod_dav` + `mod_dav_fs` + `mod_dav_lock` ship in the same Apache binary as `mod_ssl` and `mod_rewrite`.
- Removes ~700 lines of bash (handlers + helpers + bats unit tests) — replaced by an off-the-shelf module providing identical RFC-correct behaviour.

**Rejected alternatives**:
- **Bash CGI handlers** (committed at `f668d12`): duplicates RFC-correct behaviour that mod_dav already provides, and requires per-handler trust/path/ETag/Range/Conditional/PROPFIND parsing.
- **`mod_lua` / Python CGI handlers** with custom DAV protocol: status quo violates the user's "use ready-made libraries to keep things tidy" instruction.
- **`mod_proxy` only, no DAV**: doesn't speak MKCOL/COPY/MOVE/PROPFIND on a plain proxy pass.

---

## Decision R2 — Two VirtualHosts: public mTLS edge + loopback mod_dav backend

**What was chosen**:
- VH `:8443` (public): mTLS terminates via `mod_ssl`; `mod_rewrite` enforces URL-prefix-vs-CN; `[P]` proxies to `http://127.0.0.1:8444`.
- VH `:8444` (loopback, **`127.0.0.1` only**): `mod_dav On`, `DocumentRoot = <data-dir>/drop/`.

**Why chosen**:
- The proxy-on-loopback pattern is the canonical Apache way to do "front-door authentication + back-door DAV" while keeping the storage layer identity-blind. It is the same layout as ubiquitous Apache+DAV+SSO deployments.
- Loopback binding (`<VirtualHost 127.0.0.1:8444>`) is OS-level isolation: only the public VH can reach the mod_dav backend.
- mod_dav_fs's DocumentRoot gives path-prefix partitioning by construction — the URL prefix the proxy just validated is the same prefix mod_dav sees, then mapped deterministically to `<data-dir>/drop/<cn>/<rest>`.

**Rejected alternative**: a single VH doing both mTLS and DAV. Without a CN-matches-prefix gauge inside mod_dav, we'd have to bolt it on via `mod_rewrite` plus another mod_dav gate — net result is two concerns interleaved rather than cleanly split.

---

## Decision R3 — Trust gate is `RewriteMap prg:` calling `scripts/trust-check.sh`

**What was chosen**: a small bash program invoked by Apache's `RewriteMap`. Input: a CN. Output: the same CN if `<trust_dir>/<cn>.crt` exists and its SHA-256 fingerprint matches the just-verified mTLS cert; otherwise `REJECT`. Apache uses the result in a `RewriteCond` to forward or 401/403.

**Why chosen**:
- `RewriteMap prg:` is the canonical Apache mechanism for in-process gate decisions; sub-millisecond latency.
- The fingerprint-match logic is the same as `cgi-trust.sh`'s `is_trusted()`, but packaged as a 30-line entrypoint suitable for `RewriteMap`.
- Single source of truth: `<trust_dir>/hosts/<cn>.crt` fingerprints come unchanged from feature 004.

**Rejected alternatives**:
- **`SSLVerifyClient require` with dynamic CA bundle**: rejected because we don't ship CA infrastructure (per feature 010). Self-signed certs cannot be validated as part of any CA chain.
- **`mod_authnz_external`**: heavier (Apache module load, init overhead) than `RewriteMap prg:`.
- **Trust check inside mod_dav via `mod_lua`**: rejected because it inverts the clean proxy/storage separation.

---

## Decision R4 — URL-prefix = identity-of-caller (FR-002 re-confirmed)

**What was chosen**: the URL is `/drop/<cn>/<rest>` where `<cn>` must equal the verified CN. A mismatch produces `403 Forbidden` *at the proxy edge*, before `[P]`.

**Why chosen**:
- The spec is explicit about this (see `## Clarifications > Session 2026-08-06`).
- Single `RewriteCond` at the proxy comparing `%{ENV:trust_check:<cn>}` against `%{ENV:SSL_CLIENT_S_DN_CN}`. Single Apache line.
- The "to none other" requirement is expressed in pure rewrite-spaces, no shell logic.
- Mod_dav itself never sees a cross-host request.

**Rejected alternative**: deny inside the storage layer via `mod_lua` + `mod_dav`'s `<Location>` guards. Rejected because it inverts the clean proxy/storage separation.

---

## Decision R5 — DocumentRoot-aligned path partitioning

**What was chosen**: `DocumentRoot = <data-dir>/drop/` on the loopback VH. mod_dav_fs maps URL `/alice/x.txt` exactly to filesystem `<data-dir>/drop/alice/x.txt`. No per-handler CN->path translation needed.

**Why chosen**:
- The spec's URL prefix is now identical to the filesystem prefix — mod_dav needs no path rewrite to align.
- Apache's `mod_dav` creates parent directories on PUT (`Dav On` parent-of behaviour); no extra `mkdir`.

**Rejected alternative**: per-host `AliasMatch` regex on the loopback VH. Rejected because each new trusted peer would require regenerating Apache config + reloading. The DocumentRoot path-style is static and serves all current and future peers equally.

---

## Decision R6 — Client wrappers are pure bash + curl + openssl

**What was chosen**: 9 small bash wrappers under `cli/`, one per HTTP method. Each calls `curl --cert ... --key ... --cacert ... --request <METHOD>` (the same mTLS pattern used by `scripts/on-discover.sh`) and reads the cert's CN via `openssl x509 -noout -subject -nameopt RFC2253` to build `/drop/<cn>/<rest>`.

**Why chosen**:
- No new runtime dependencies: bash, curl (already shipped), openssl (already shipped).
- One wrapper per method matches the project's existing convention (`hello.get.sh`, `bundle.post.sh`, etc. in `handlers/`).
- The HttpMethod mapping is straightforward: PUT -> `mtls-drop`, GET -> `mtls-fetch`, HEAD -> `mtls-head`, DELETE -> `mtls-del`, MKCOL -> `mtls-mkcol`, COPY -> `mtls-cp`, MOVE -> `mtls-mv`, PROPFIND -> `mtls-props`/`mtls-ls`. No "smart wrapper that does everything".
- `cli/mtls-*` outputs are line-oriented and human-readable so users can pipe to `awk`/`jq`/`grep` cleanly.

**Rejected alternatives**:
- **Python CLI with `requests` / `lxml`**: adds a runtime dep; project already commits to bash for `cli/*`-style wrappers.
- **Single heavy CLI with subcommands** (à la `git`/`hg`): each method already has natural client semantics (range is GET, conditional is a header). One-method-per-file is consistency with the existing project.

---

## Decision R7 — Content-Disposition via `mod_headers` (static)

**What was chosen**: `Header set Content-Disposition "attachment"` on the loopback VH's `<Directory>` block, applied to all GET responses. We **do not preserve an "original filename" attribute**.

**Why chosen**:
- Apache's `mod_mime` natively sends `Content-Type` from filename extension; mod_dav does not produce `Content-Disposition`.
- `mod_headers` ships with stock Apache; no new module needed.
- mod_dav can't tell "original filename" apart from URL basename anyway: the user constructed the URL and the URL is the intended download name. A browser will download the file with the URL basename as filename, which is what most users want.

**Rejected alternative**: a small bash CGI-handler swap that intercepts mod_dav's GET to inject `Content-Disposition: attachment; filename=...`. Rejected because (a) it would amount to duplicating mod_dav's GET in a parallel shell pipeline, (b) it would require a per-request `xattr` or sidecar `user.name` to recall the "original", which the previous bash design had. The architectural pivot is precisely to escape that loop.

**Implication on the spec**: FR-013's `filename="..."` clause becomes "implementation-fidelity is whatever the URL basename is". This is documented in `contracts/client-cli.md`.

---

## Decision R8 — ETag format = Apache's `FileETag`

**What was chosen**: rely on Apache's default `FileETag INode MTime Size` output. Acknowledge moving away from the bash-plan's `sha256:<hex>` proposal.

**Why chosen**:
- The spec FR-010 doesn't pin a specific format, only that an entity tag be returned and that `If-Match`/`If-None-Match` work correctly on it. mod_dav+`FileETag` produces stable ETags; semantics work correctly per RFC 7232.
- Computing sha256 per request would be expensive; this gives us lost-update-protect for free.

**Rejected alternative**: `Header set ETag` from a `mod_lua`-computed SHA-256 each request. Rejected because it adds a Lua runtime dep and CPU per request.

---

## Decision R9 — Client wrapper CN derivation is file-system-based

**What was chosen**: `cli/mtls-drop.sh` (and friends) calls `openssl x509 -noout -subject -nameopt RFC2253 --nameopt oneline` on the wrapper's own `--cert` file to read the CN locally, then constructs `/drop/<cn>/<rest>` deterministically from that.

**Why chosen**:
- The CN derivation is deterministic given `--cert`, so we pre-compute it once at wrapper entry. The HTTP request just goes out with the right URL.
- The URL is **explicit** per the spec — there is no auto-prepending by the server. The wrapper is the place that builds the URL.

**Rejected alternatives**:
- **URL auto-construction by the server based on the verified CN**: rejected — explicitly violates FR-001 / FR-003 ("caller declares `<hostname>` as the first URL segment").
- **`curl --data-urlencode host=<cn>` headers**: rejected because CN belongs in the URL path, not in the request content.

---

## Rejected: bash CGI handlers in `cgi-dropbox.sh` (the previous design)

The earlier plan shipped (at `f668d12`) the following files, which this plan obsoletes:

- 9 bash CGI handlers under `handlers/drop.{put,get,head,delete,mkcol,copy,move,propfind,options}.sh`.
- `scripts/cgi-dropbox.sh` (~445 lines of helpers: CN sanitization, path validation, ETag compute/cache, Range parse, If-Match/If-None-Match/If-Modified-Since parsing, header emission).
- `tests/dropbox.bats` (~340 lines of unit tests for those helpers).

These deletions are intentional and load-bearing: continuing them would mean re-implementing what mod_dav already does, doubling the surface area for spec drift and bugs.

---

## Schema-level summary

| # | Topic | Decision | Where implemented |
|---|---|---|---|
| R1 | Storage engine | mod_dav + mod_dav_fs | loopback VH `<VirtualHost 127.0.0.1:8444>` |
| R2 | Architecture | 2 VHs: public mTLS + loopback mod_dav | `config/apache-site.conf.in` |
| R3 | Trust gate | `RewriteMap prg:` -> `scripts/trust-check.sh` | public VH `<Location /drop>` |
| R4 | URL-prefix-vs-CN | `RewriteCond` + `RewriteRule - [F]` on mismatch | public VH config |
| R5 | DocumentRoot | `<data-dir>/drop/` | loopback VH config |
| R6 | Client wrappers | pure bash + curl + openssl | `cli/mtls-*.sh` (9 wrappers) |
| R7 | Content-Disposition | static `attachment` via mod_headers | loopback VH `<Directory>` |
| R8 | ETag | Apache `FileETag INode MTime Size` | Apache core, no extra config |
| R9 | CN derivation | local cert-subject parse | shared helper `cli/_common-cname.sh` |

---

## Risks (re-apprised under mod_dav-first architecture)

| Concern | Mitigation |
|---|---|
| `mod_dav` not enabled in the project's Apache build (Debian: `a2enmod dav dav_fs`; Arch: shipped; Nix: must explicitly pin) | `scripts/install.sh` and packaging steps explicitly enable `mod_dav`. `tests/apache.bats` asserts presence of `*.load` lines for mod_dav and mod_proxy_http after install. |
| `mod_proxy_http` not enabled by default in Debian minimum Apache config | install script enables it; tests assert. |
| Bad wrapper generated URL like `/drop/foo.txt` (no hostname prefix) | The proxy edge rejects with 403; client is told explicitly to use the cert's CN. |
| Client installs the wrong cert (CN ≠ their hostname) | trust-check fails 401; user-visible. |
| DocumentRoot not provisioned at install time | `scripts/install.sh` runs `mkdir -p <data_dir>/drop`. |
| Path traversal (FR-006) | mod_dav + DocumentRoot gives canonicalization + static-root boundary for free. |

---

## Open implementation items

No remaining spec ambiguity. The following become implementation tasks under `/speckit.tasks`:

- [ ] Enable `mod_dav`, `mod_dav_fs`, `mod_dav_lock`, `mod_proxy`, `mod_proxy_http`, `mod_headers` in the project's Apache profile.
- [ ] Write `scripts/trust-check.sh` (30-line RewriteMap contract; behaviourally covered by `tests/trust-check.bats`).
- [ ] Rewrite `config/apache-site.conf.in` with two VHs (public + loopback) and the `<Location /drop>/drop<rewrite logic>/Directory>` blocks described in `plan.md`.
- [ ] Write `cli/mtls-{drop,fetch,head,del,ls,props,mkcol,cp,mv}.sh` (9 wrappers).
- [ ] Write `tests/trust-check.bats` (small) and `robot/dropbox.robot` (or extend `robot/mtls_hello.robot`).
- [ ] Update `scripts/install.sh`, `scripts/install-service.sh`, `scripts/package-{common,debian,arch}.sh`, `docker/Dockerfile.{debian,arch,test}` to ship and enable these modules + new scripts.

No `NEEDS CLARIFICATION` items remain.
