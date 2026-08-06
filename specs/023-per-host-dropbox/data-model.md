# Data Model: Per-Host Drop-Box

**Feature**: `023-per-host-dropbox`
**Date**: 2026-08-06 (mod_dav-first revision; supersedes the bash-handler model)

This data model is intentionally short because `mod_dav_filesystem` *is* the data layer. There are only three entities; everything else is delegated to `mod_dav` and the existing project trust store.

## Entities

### TrustEntry (existing — unchanged)

A per-CN fingerprint registration record under `<data-dir>/.../hosts/`.

| Field | Source | Store |
|---|---|---|
| `cn` | certificate subject CN (RFC 2253) | `<trust_dir>/hosts/<cn>.crt` |
| `fingerprint` | SHA-256 of the cert's DER bytes | inside the cert file (`openssl x509 -fingerprint`) |
| `source` | the cert file itself | `<trust_dir>/hosts/<cn>.crt` |

Established by feature 004. Drop-box **inherits** this; no new store is added.

### BoxFile (a file inside a host's box)

A file under `<data-dir>/drop/<cn>/<rest>` reachable via the URL `/drop/<cn>/<rest>`. Filesystem-native.

| Field | Source | Store |
|---|---|---|
| `name` | URL's `PathInfo` (basename + optional deeper path) | the filesystem path itself |
| `cn` | URL's first segment AND the verified CN at proxy time | derived; not stored separately |
| `mtime` | filesystem mtime | the filesystem |
| `size` | filesystem size | the filesystem |
| `content_type` | Apache `TypesConfig` mapping from filename extension | Apache MIME map (per Apache 2.4 default) |
| `etag` | header reply (Apache `FileETag`) | recomputed per request |

Apache's `mod_mime` provides `Content-Type` resolution; `FileETag` provides ETag resolution; Apache core handles `If-Match`/`If-None-Match`/`If-Modified-Since`/`If-Unmodified-Since` and `Range` requests. We don't store separate metadata files.

### BoxDirectory (a directory inside a host's box)

Likewise filesystem-native.

| Field | Store |
|---|---|
| `name` | the filesystem path |
| `cn` | derived from URL's first segment |
| `children` | nested filesystem tree |

`MKCOL` (FR-009) creates a directory; mod_dav creates parent directories on `PUT`; recursive `MKCOL` is **not** in scope (FR-014 keeps Depth 0 only; mkcol is single-level).

## On-disk layout

```text
<data-dir>/
├── (existing layout — unchanged) ...
├── drop/                       # NEW top-level dir for this feature
│   └── <cn>/                   # one per trusted peer; lazily created
│       └── <rest>              # files / directories from mkcol/put/copy/move
└── apache/                     # existing Apache layout
    └── (site config, logs)
```

`<data-dir>/drop/` is also the **DocumentRoot of the loopback VH**, which means mod_dav's path ↔ URL mapping is 1:1 with no translation. The proxy edge guarantees the URL prefix `/<cn>/` matches the verified CN before this happens, so the contents of `<data-dir>/drop/<cn>/...` are always that caller's box (and the URL prefix matches the host).

### Trusts store (for the proxy edge)

```text
<data-dir>/.../hosts/<cn>.crt    # one cert per trusted host
<data-dir>/.../purgatory/<cn>.<fp>.crt
```

Already existing from feature 004. Read by `scripts/trust-check.sh`.

## Validation rules

Each rule is enforced at the level stated; the rule is **not** a separate logic layer.

| # | Rule | Enforced by | Behavior on violation |
|---|---|---|---|
| 1 | URL prefix `/drop/<cn>/` constant part | Apache config (`<Location /drop>`) | n/a — enforced by routing |
| 2 | `<cn>` equals verified CN | `RewriteCond` at the proxy edge | `403 Forbidden` |
| 3 | Verified CN matches `<trust_dir>/<cn>.crt` fingerprint | `scripts/trust-check.sh` (RewriteMap) | `401 Unauthorized` (Apache wraps the REJECT) |
| 4 | Path traversal (`..` segments) | mod_dav (canonicalizes; refuses to leave DocumentRoot) | `400 Bad Request` (mod_dav) or rejecting the encoded sequence entirely in `AllowEncodedSlashes NoDecode` |
| 5 | Record sizes / partial bodies / partial uploads | Apache core (`LimitRequestBody`) | configurable; documented in `install.sh` |
| 6 | Concurrent writes (PUT race) | mod_dav filesystem provider | last-writer wins (filesystem POSIX guarantee) |

Unlike the prior bash-handler plan, **no canonicalisation or sanitization code lives in our code paths** — all of it is Apache + mod_dav doing its own thing.

## State transitions

```text
                ┌───────────────────────┐
                │     file absent       │
                └─────────▲─────────────┘
                          │
        PUT  ──► exists ──┴──► DELETE ──► absent
                  │
                  └──► ETag/Last-Modified change (mtime+size)
                  
                ┌───────────────────────┐
                │   directory absent    │
                └─────────▲─────────────┘
                          │
       MKCOL ──► exists ─ ┴──► empty-Dir DELETE ──► absent
                  │
                  ├──► COPY (target+here exist) ──► both present
                  ├──► MOVE (source gone; dest present)
                  └──► non-empty Dir DELETE ──► 409 Conflict
```

The `409` for non-empty-directory DELETE is emitted by mod_dav natively. The wrapper `cli/mtls-del.sh` prints `(409)` clearly. Note that *recursive* `DELETE` is **not** supported and would also return `409`.

## Relationship to existing feature state

Drop-box reuses:

- **feature 004 / 022 trust** — `<data-dir>/.../hosts/<cn>.crt`. The drop-box uses the same trust decision; the trust store is **not** duplicated.
- **feature 021 custom cert capture log** — `scripts/log-capture.sh` continues to run; trust gate logic now in `trust-check.sh` is in addition, not replacement.
- **feature 018 Apache front** — the loopback VH is registered in the same `scripts/apache-config.sh` content generation pipeline. Existing `apache-port-helper.sh` doesn't care that the loopback VH has no mTLS.

## What is **not** in this data model

- **`Range` state, `If-Match` state**: stateless in Apache. No new store.
- **Quota / 507**: out of scope (per spec's wishlist deferral).
- **TTL / auto-expiration**: out of scope (cron-style cleanup, not a per-request mechanic).
- **Per-host `etag` namespace collision**: mod_dav/mtime+size produces ETags that are stable per-file and non-collision-prone between hosts because the URL prefix is unique per host.
- **`xattr` / file-sidecar metadata for `user.mime`, `user.name`**: Apache's `mod_mime` + URL basename suffice. Dropped from the prior model's `scripts/cgi-dropbox.sh` helpers.
