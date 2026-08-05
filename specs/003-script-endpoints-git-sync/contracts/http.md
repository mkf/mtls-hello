# Contract: Script Endpoint Protocol (HTTP)

**Branch**: `003-script-endpoints-git-sync` | **Date**: 2026-03-19 | **Feature**: [spec.md](../spec.md)

> Applies to this feature's HTTP surface. The transport (mutual TLS, server bind, client-cert verification) remains as specified in `specs/001-mtls-echo-discovery/contracts/http.md` — every endpoint below is only reachable by authenticated peers.

## Routes

| Method | Path | Behavior when script exists | Behavior when script missing |
|---|---|---|---|
| GET | `/<name>` | Execute `handlers/<name>.get.*`; stdout → body | Echo `<name>` as text/plain (feature 001 fallback) |
| POST | `/<name>` | Execute `handlers/<name>.post.*`; stdout → body | 404 Not Found |

`<name>` is a single URL path segment, URL-decoded by the server.

## Handler script resolution

- Root: `--handlers-dir` (default `handlers/`), relative to the server working directory.
- Path: `<handlers-dir>/<name>.<method>.<extension>`, where `<method>` is lowercase (`get`/`post`) and `<extension>` is free-form (e.g. `sh`, `py`, or absent). Resolution order:
  1. exact file `<name>.<method>` (no extension)
  2. any file whose name starts with `<name>.<method>.` in the directory; if several variants exist, the lexicographically first is used — keep exactly one file per name+method.
- The file must exist and be executable; its shebang determines the interpreter. The server never reads or interprets file contents.

## Request → script inputs

The script is spawned with the following environment variables:

| Variable | Always | Source |
|---|---|---|
| `REQUEST_METHOD` | yes | `GET` or `POST` |
| `SCRIPT_NAME` | yes | The `<name>` path segment (decoded) |
| `QUERY_STRING` | yes | Raw query string (e.g. `repo=alpha&fmt=sha`) |
| `QUERY_<NAME>` | per param | Decoded query parameter; `<NAME>` = param name with non-alphanumerics → `_` |
| `CONTENT_LENGTH` | POST only | Body byte length |
| `CONTENT_TYPE` | POST only | Request content type |

Standard input: for POST, the request body (via temp file redirect). For GET, empty.

The child inherits the server's environment in addition to the variables above.

## Script → response mapping

| Condition | HTTP status | Response body |
|---|---|---|
| Exit code 0 | 200 | Script stdout (text/plain; charset=utf-8) |
| Exit code non-zero | 500 | Generic error body (e.g., "Internal Server Error"); server logs stderr; no partial body |
| Timeout exceeded (`--script-timeout`, default 10 s) | 500 | Generic error body; child killed; no partial body |
| Script file missing | GET: 200 (echo) / POST: 404 | GET: `<name>` text/plain |

Script stderr is captured to a temp file and logged by the server for operator debugging; it is never sent to the client.

## Sanitization

- `<name>` must be non-empty, contain no `/`, `\`, or `.` (dots are structural separators in handler file names), must not be `.` or `..`, and must not start with `.`. Violations → 400 Bad Request.
- Query parameter names in `QUERY_<NAME>` have every non-`[A-Za-z0-9_]` character replaced with `_` (environment-variable safety).

## Example

```sh
# handlers/head.get.sh  (executable, shebang #!/bin/bash)
#!/bin/bash
git -C "$REPOS_ROOT/$QUERY_REPO" rev-parse HEAD

# Request: GET /head?repo=alpha  →  env: QUERY_STRING=repo=alpha, QUERY_REPO=alpha
# Response: 200 text/plain "<sha of alpha's HEAD>"
```

```sh
# handlers/bundle.post.sh  (executable, shebang #!/bin/bash)
#!/bin/bash
set -euo pipefail
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp"
git -C "$REPOS_ROOT/$QUERY_REPO" fetch "$tmp" HEAD
git -C "$REPOS_ROOT/$QUERY_REPO" merge --ff-only FETCH_HEAD
echo "ok"

# Request: POST /bundle?repo=alpha  with git bundle on stdin
# Response: 200 text/plain "ok"
```
