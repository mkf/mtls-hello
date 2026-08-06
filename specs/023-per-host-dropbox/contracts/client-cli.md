# Drop-Box Client CLI Contract

**Feature**: `023-per-host-dropbox`
**Date**: 2026-08-06 (mod_dav-first revision)

Wire-level contract for the `cli/mtls-*` bash wrapper family that operates against `/drop`. Each wrapper is a thin (≤80 line) bash script over `curl` with mutual TLS, following the same mTLS-curl invocation pattern already used by `scripts/on-discover.sh`.

Wrapper convention:
- **`<method-name>.sh` enforces exactly one HTTP method.**
- The path is constructed from `--cert`: the wrapper reads the cert at startup to extract `CN` and stitches `/drop/<cn>/<rest>` deterministically.

## Common options

Every command accepts these flags or, equivalently, env vars.

| Flag | Env | Notes |
|---|---|---|
| `--server H` | `MTLS_SERVER`        | `https://host:port` (no trailing `/drop` — the wrappers add the path) |
| `--cert F`   | `MTLS_CLIENT_CERT`   | client cert — also used to derive the caller's CN |
| `--key  F`   | `MTLS_CLIENT_KEY`    | client key |
| `--cacert F` | `MTLS_CACERT`        | trusted server cert (self-signed; no CA chain per feature 010) |
| `--cn CN`    | (none)               | **Override** of the auto-derived CN; mostly for tests |

Defaults:
- `MTLS_SERVER` falls back to the previously-set `MTLS_HELLO_URL` if present.
- `MTLS_CLIENT_CERT`, `MTLS_CLIENT_KEY`, `MTLS_CACERT` fall back to env. If unset, the wrapper errors with a non-zero exit (`2 — usage`).
- If `--server` does not begin with `https://` the wrapper errors out (`2 — usage`).

Exit status (uniform across all wrappers):

| Status | Meaning |
|---|---|
| `0` | success |
| `1` | generic error (curl exits non-zero, e.g. TLS handshake, DNS, network) |
| `2` | usage error (missing/invalid flag, bad URL, missing cert/key) |
| `3` | trust gate rejected (server returned `401`) — the wrapper's cert is not in the trust store |
| `4` | server returned `5xx` |
| `5` | prefix-mismatch (server returned `403`) — the wrapper's CN does not match the URL's first segment |

## Subcommands

### `cli/mtls-drop.sh`  (PUT)

```sh
mtls-drop [opts] --source <LOCAL> --name <REMOTE> [--content-type <CT>]
```

| Flag | Notes |
|---|---|
| `--source FILE`     | local file to upload (required) |
| `--name NAME`       | remote basename within caller's box; default = basename of `--source` |
| `--content-type CT` | explicit `Content-Type:`; default = `file -b --mime-type <local>` |
| `--if-none-match`   | sends `If-None-Match: *` to refuse overwrite if already present |
| `--etag SHA`        | sends `If-Match: "<sha256:hex>"` (overwrite only if version matches) |

Output on success: `(201 created <remote>)` or `(204 overwritten <remote>)`.
Output on conflict: `(412 precondition failed)`.

### `cli/mtls-fetch.sh`  (GET)

```sh
mtls-fetch [opts] --name <REMOTE> [--out PATH] [--range A-B] [--if-none-match SHA]
```

| Flag | Notes |
|---|---|
| `--name NAME`     | remote file under `/drop/<cn>/<NAME>` (required) |
| `--out PATH`      | local destination for body; default = `<NAME>` in current dir |
| `--range A-B`     | single-range `bytes=A-B` (also accepts `bytes=-N` for last N bytes) |
| `--if-none-match SHA` | sends `If-None-Match: "<sha256:hex>"`; expect 304 on match |

Output:
- `(200 ok <size> <etag> <lastmod>)` — body written to `--out`
- `(304 not modified <etag>)` — no body
- `(206 partial <a-b>/<size>)` — partial body to `--out`

### `cli/mtls-head.sh`  (HEAD)

```sh
mtls-head [opts] --name <REMOTE>
```

Output: prints headers line by line:

```
Status: 200 OK
ETag: "<sha>"
Last-Modified: <HTTP-date>
Content-Type: <CT>
Content-Length: <n>
```

### `cli/mtls-del.sh`  (DELETE)

```sh
mtls-del [opts] --name <REMOTE> [--if-match SHA]
```

| Flag | Notes |
|---|---|
| `--name NAME`     | remote file/dir (required) |
| `--if-match SHA`  | send `If-Match: "<sha256:hex>"`; refuse delete on stale |

Output on success: `(204 deleted <remote>)`.
Output on conflict: `(409 conflict — directory not empty)` or `(412 precondition failed)`.

### `cli/mtls-mkcol.sh`  (MKCOL)

```sh
mtls-mkcol [opts] --dir <DIR>
```

`--dir` is the directory name relative to the caller's box root. Single-level only — caller must create any missing parent explicitly.

Output: `(201 created dir/<DIR>)`.

### `cli/mtls-cp.sh` / `cli/mtls-mv.sh`  (COPY / MOVE)

```sh
mtls-cp [opts] --source <SRC> --dest <DEST> [--overwrite]
mtls-mv [opts] --source <SRC> --dest <DEST> [--overwrite]
```

Both names are interpreted **inside the caller's box**, not as another URL.

| Flag | Notes |
|---|---|
| `--source SRC` | source path inside the box |
| `--dest DEST`   | destination path inside the box |
| `--overwrite`   | send `Overwrite: T` header (default off) |

Output: `(201 copied <SRC> -> <DEST>)` / `(201 moved ...)`.

### `cli/mtls-ls.sh`  (PROPFIND, human-readable)

```sh
mtls-ls [opts] [--dir <DIR>]
```

Sends `PROPFIND` with `Depth: 1` from the box root (or from `--dir`). Renders each property as a tab-separated line:

```
notes.txt    1234    text/plain    "sha256:..."    2026-08-06T12:34:56Z
archive/     -       httpd/unix-directory    "sha256:..."   2026-08-06T12:34:56Z
```

### `cli/mtls-props.sh`  (PROPFIND, structured)

```sh
mtls-props [opts] --name <NAME>
```

Sends `PROPFIND` with `Depth: 0`. Parses the multistatus XML (via `xmllint --xpath` if available, else via a small awk script — fallback). Outputs one key per line:

```
resourcetype: regular
getcontentlength: 1234
getcontenttype: text/plain
getlastmodified: Mon, 06 Aug 2026 12:34:56 GMT
getetag: "sha256:<hex>"
```

## Authentication setup

The project already provides identity artifacts elsewhere (feature 010: self-signed client cert + key per peer). The drop-box wrappers use the same files.

- `<cn>.crt`, `<cn>.key` — client identity.
- `ca/<peer>.crt` — the trusted peer (server) cert, e.g. its `<hostname>.crt` directly. Self-signed means curl expects it via `--cacert` rather than via a CA chain.

Example invocation (alice, talking to bob):

```sh
cli/mtls-drop.sh \
   --cert ./clients/alice.crt \
   --key  ./clients/alice.key \
   --cacert ./ca/bob.crt \
   --server https://bob.example:8443 \
   --source ./local-notes.txt \
   --name notes.txt
```

The wrapper reads the CN from `./clients/alice.crt` (alice) and builds the URL `https://bob.example:8443/drop/alice/notes.txt` automatically.

## Output conventions

- All output goes to **stdout**.
- Errors go to **stderr** (per bash convention).
- Exit status per the table above; no "warnings" emitted as errors.

## Edge cases handled by wrappers

- **CN not in cert**: `cli/mtls-drop.sh` reads CN before sending; if extraction fails (no CN, CN with non-`[A-Za-z0-9._-]+`), exits `2`.
- **No `--source`**: exits `2`.
- **Server unreachable**: curl exits non-zero; wrapper exits `1`.
- **Server returns `401`**: wrapper exits `3`.
- **Server returns `403`**: wrapper exits `5`.
- **Server returns `5xx`**: wrapper exits `4`.

## Backwards compatibility

This feature introduces new commands; it does not change any existing CLI. The `MTLS_*` env vars are reused. No other script changes are required for the wrappers to function.

## Reference one-liners

```sh
# Drop a file
cli/mtls-drop.sh --cert ./c --key ./k --cacert ./ca \
   --server https://peer:8443 --source ./local.txt --name notes.txt

# List contents of your box
cli/mtls-ls.sh --cert ./c --key ./k --cacert ./ca --server https://peer:8443

# Conditional-range fetch
cli/mtls-fetch.sh --cert ./c --key ./k --cacert ./ca \
   --server https://peer:8443 --name big.bin --range 104857600-209715199 --out chunk.bin

# Copy inside your own box
cli/mtls-cp.sh --cert ./c --key ./k --cacert ./ca \
   --server https://peer:8443 --source photo.jpg --dest archive/photo.jpg
```
