# Drop-Box HTTP Contract

**Feature**: `023-per-host-dropbox`
**Date**: 2026-08-06 (mod_dav-first revision; supersedes the bash-handler contract at `a163fc1`)

Wire-level contract for the per-host drop-box exposed at `/drop/<cn>/<rest>`. This document is the **public** surface — what an external client (a wrapper, a curl invocation, a future script) sees.

## Authentication

- **Required**: mutual TLS, verified by Apache `mod_ssl` with `SSLVerifyClient optional_no_ca`.
- **Caller identity**: the verified client's certificate CN (`SSL_CLIENT_S_DN_CN`).
- **Trust check**: invoked at the public VH via `RewriteMap trust_check prg:...` calling `scripts/trust-check.sh`. If `<trust_dir>/<cn>.crt` exists **and** its SHA-256 fingerprint matches the live TLS handshake's cert, the trust check returns the CN; otherwise `REJECT`.
- **URL prefix check**: at the public VH, a `RewriteCond` compares the URL's first segment (`<cn>`) to the trusted CN. Mismatch → `403 Forbidden`. This is FR-002.
- **Final 401 path**: `REJECT` from the trust check → `401 Unauthorized`.
- **Final 403 path**: cross-host URL segment → `403 Forbidden`.

## URL namespace

The URL on the public VH is `/drop/<cn>/<rest>`. The proxy forwards to the loopback VH with the same URL body (no rewrite from `<cn>`; mod_dav_fs sees the literal path).

| Public URL | Behavior (alice = trusted CN) | Behavior |
|---|---|---|
| `PUT  /drop/alice/notes.txt`           | forwarded to mod_dav → PUT `<data-dir>/drop/alice/notes.txt` (auto-creates alice/) | trusted alice |
| `GET  /drop/alice/notes.txt`           | forwarded → GET (ETag/Range/If-None-Match honored by mod_dav) | trusted alice |
| `PUT  /drop/alice/archive/x`           | forwarded → PUT, mod_dav auto-creates `archive/` | trusted alice |
| `MKCOL /drop/alice/archive`            | forwarded → MKCOL creates `<data-dir>/drop/alice/archive` | trusted alice |
| `COPY /drop/alice/x`                   | forwarded with `Destination: /drop/alice/x.copy` (via [P]) → COPY | trusted alice |
| `PROPFIND /drop/alice` (Depth: 1)      | forwarded → recurses alice's box | trusted alice |
| `GET  /drop/bob/notes.txt`             | 403 Forbidden — verified CN (alice) ≠ URL prefix (bob) | any trusted |
| `PUT  /drop/` (or `/drop` no trailing) | 400 Bad Request — no `<cn>` segment to validate | any trusted |
| any /drop request with untrusted cert  | 401 Unauthorized — trust-check returned REJECT | untrusted |

## Trust-vs-prefix decision precedence

At the public VH, the order is: **trust first, then prefix-match**. This is the natural Apache `RewriteCond` chain order: an untrusted cert cannot escape prefix validation because both errors map deterministically:

- `REJECT` from trust-check → Apache returns `401 Unauthorized` via a `RewriteRule - [F=L]` step.
- `REJECT`-by-prefix (URL segment ≠ verified CN) → Apache returns `403 Forbidden` via a `RewriteRule - [F]` step further down the chain.

The user-visible behavior: an untrusted alice always sees `401` regardless of which prefix alice tries; a trusted alice sees `401` if she sends `/drop/bob/...` (because that's a prefix-mismatch on a verified-but-unauthorized-for-this-prefix request).

## Path validation (server-side)

Path safety is provided by mod_dav + `DocumentRoot`. Explicit rules:

1. **CN sanitization**: the verified CN must match `[A-Za-z0-9._-]+` and be ≤128 characters. (Apache already restricts Subject CN to ASCII; a CN with shell metacharacters triggers 400 from Apache's own validation.)
2. **URL-prefix-vs-CN**: see Trust-vs-prefix decision precedence above.
3. **No path can leave `<data-dir>/drop/<cn>/`**: mod_dav's filesystem provider is bound to `DocumentRoot` and refuses `..` segments that would escape.
4. **Encoded slashes**: `AllowEncodedSlashes NoDecode` is set on the loopback VH; the encoded form (`%2F`) is preserved into the filesystem path. Path traversal via encoded `..` -> disallowed because Apache canonicalizes before forwarding.

## Common response headers

On any successful response that touches an existing or newly-created file, mod_dav emits:

| Header | Source | Notes |
|---|---|---|
| `ETag`                | Apache `FileETag`           | typically `"<inode>-<mtime>-<size>"` hex |
| `Last-Modified`       | filesystem mtime            | RFC 7231 IMF-fixdate |
| `Content-Type`        | `mod_mime` from filename    | Apache's MIME-type map; falls back to `application/octet-stream` |
| `Content-Length`      | filesystem size              | absent on `200 OK` partial responses |
| `Content-Disposition` | `mod_headers` (static)      | `attachment` on GET (no `filename="…"` — see Decision R7) |
| `Accept-Ranges`       | Apache core                  | `bytes` on file GETs |

## Method semantics (delegated to mod_dav / Apache)

### `PUT /drop/<cn>/<name>` → 201 Created (new) / 204 No Content (overwrite)

mod_dav handles:
- Body: raw file contents from `curl -T <local>`.
- `Content-Type:` header preserved as a server hint (mod_mime may re-derive from extension; both apply).
- Conditional request headers: `If-Match`, `If-None-Match`, `If-Unmodified-Since` — RFC 7232 semantics; conflict returns `412 Precondition Failed`.
- Parent directories auto-created.
- Overwrite by default. `If-None-Match: *` refuses overwrite against existing.

### `GET /drop/<cn>/<name>` → 200 OK / 304 Not Modified / 206 Partial Content

mod_dav handles:
- Conditional headers: `If-None-Match`, `If-Modified-Since` (ETag and mtime based).
- Range: `Range: bytes=A-B` → `206 Partial Content` with `Content-Range: bytes A-B/<size>`. Multi-range returns `501 Not Implemented` (Apache core behavior).
- `HEAD` method is identical to GET with no body.

### `HEAD /drop/<cn>/<name>` → 200 OK (or 404)

Same headers as GET; no body; `Content-Length` matches the would-be GET.

### `DELETE /drop/<cn>/<name>`

- File present: mod_dav removes it; `204 No Content`.
- Empty directory: mod_dav removes it; `204`. (FR-015 conditional requirement.)
- Non-empty directory: mod_dav returns `409 Conflict`.
- Conditional: `If-Match` (FR-010).

### `MKCOL /drop/<cn>/<dir>` → 201 Created (or 405 if path exists)

mod_dav creates a directory at the URL path. Path must be of type "directory" (no implicit parents — see next bullet). If a file already exists at the URL, mod_dav returns `405`.

Note: mod_dav's MKCOL behavior is single-level — the caller must create parents as needed. `PUT` auto-creates parents.

### `COPY` / `MOVE /drop/<cn>/<src>` with `Destination: /drop/<cn>/<dst>`

mod_dav semantics:
- Source and destination must evaluate to paths under the same DocumentRoot on the loopback VH — satisfied because both go through the same proxy which validates the prefix.
- `Overwrite: T` is honored (overwrite allowed); default off → `412 Precondition Failed` on existing destination.
- COPY returns `201 Created`; MOVE: `201` if created, `204` if overwritten/remapped.

We refuse to proxy a `Destination:` whose prefix differs from the verified CN's prefix — single rule in the public VH's `mod_rewrite`.

### `PROPFIND /drop/<cn>/<path>` → 207 Multi-Status

mod_dav emits a multistatus XML response (`Content-Type: application/xml; charset="utf-8"`). We support any `Depth:`; mod_dav natively implements `Depth: 0`, `1`, and `infinity`. (Spec says recursive is in scope implicitly under mod_dav; we do not artificially restrict it.)

The body is RFC 4918 §14 multistatus with the standard property set (`getcontentlength`, `getlastmodified`, `getcontenttype`, `getetag`, `resourcetype`).

### `OPTIONS /drop/<cn>/<path>` → 200 OK

mod_dav's `DAV:` response header advertises `1, 2, 3<extensions>` (RFC 4918 §10.2) and Apache's native `Allow:` comes for free on collection resources.

## Status codes

| Code | Meaning |
|---|---|
| `200 OK`               | GET/HEAD/PROPFIND/OPTIONS successful |
| `201 Created`          | PUT (new) / COPY / MKCOL |
| `204 No Content`       | PUT (overwrite) / DELETE / MOVE (overwrite) |
| `206 Partial Content`  | Range GET (single-range) |
| `207 Multi-Status`     | PROPFIND |
| `304 Not Modified`     | Conditional GET |
| `400 Bad Request`      | malformed URL header |
| `401 Unauthorized`     | trust-check rejected the cert (no match in trust store) |
| `403 Forbidden`        | URL-prefix vs verified CN mismatch |
| `404 Not Found`        | resource does not exist |
| `409 Conflict`         | non-empty directory removed |
| `412 Precondition Failed` | `If-Match`/`If-None-Match` mismatch |
| `416 Requested Range Not Satisfiable` | out-of-range |
| `500 Internal Server Error` | unexpected (logged) |
| `501 Not Implemented` | multi-range |

## Limits

- File-size cap is governed by Apache's `LimitRequestBody` (configurable; default 0 = unlimited).
- Number of files per box is not enforced in this feature.
- Per-box storage quota is **not** enforced (future feature; `507 Insufficient Storage` is reserved).

## Audit log

Every drop-box request is appended to Apache's access log, with `<caller_cn>` recorded via the standard Apache `%{SSL_CLIENT_S_DN}e` directive. Existing audit log (feature 021) carries the cert capture lines via the custom apache `CustomLog "||"`.
