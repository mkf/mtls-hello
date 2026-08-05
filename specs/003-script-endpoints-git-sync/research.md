# Research: Script-Executing Endpoints and Multi-Repo Git Sync Demo

**Branch**: `003-script-endpoints-git-sync` | **Date**: 2026-03-19 | **Feature**: [spec.md](./spec.md)

## Decision: Script resolution convention

**Decision**: Handler scripts live in a flat directory as `<name>.get.<extension>` and `<name>.post.<extension>` — one executable file per method, named after the URL path segment with a lowercase method infix and a free-form extension (e.g. `head.get.sh`, `bundle.post.sh`, or extensionless `head.get`). The handlers directory is configurable via `--handlers-dir=DIR` (default `handlers/`).

Resolution order: (1) exact file `<name>.<method>` with no extension, (2) any file whose name starts with `<name>.<method>.` in the directory; if several variants exist, the lexicographically first is used — operators should keep exactly one file per name+method.

**Rationale**:
- Two separate files per endpoint name answers the user's open question ("thats going to be two separate shell scripts?") affirmatively, and the flat `<name>.<method>.<ext>` shape is exactly what was requested.
- The extension is free-form because the server never inspects file contents — the shebang (`#!/bin/bash`, `#!/bin/sh`, `#!/usr/bin/env python3`, ...) decides the interpreter.
- The method infix stays lowercase for filesystem friendliness; the HTTP method name is unambiguous (`get`/`post`).

**Alternatives considered**:
- `handlers/GET/<name>` / `handlers/POST/<name>` method-as-directory — explicit but the user preferred flat `<name>.<method>.<ext>` naming.
- One script per name dispatching on `REQUEST_METHOD` — fewer files but forces every handler to implement dispatch; contradicts the user's two-script framing.
- Scripts stored in the binary — operator-uneditable, rejected.

## Decision: Script name sanitization

**Decision**: Before path construction, the requested name is validated: it must be non-empty, contain no `/`, `\`, or `.` (dots are structural separators in handler file names), must not be `.` or `..`, and must not start with `.`. Otherwise the request is rejected with 400.

**Rationale**:
- vibe.d URL-decodes route parameters; a path like `/%2E%2E/secret` would decode `..` into the segment. Validation must happen on the decoded value.
- Because the file name is built as `<name>.<method>.<ext>`, forbidding dots in `<name>` keeps the lookup unambiguous (`foo.bar.get.sh` would otherwise be indistinguishable from two names).
- The rule is conservative: legitimate handler names are short alphanumeric slugs.

**Alternatives considered**: `buildNormalizedPath` from std.path — normalizes but also resolves `..`, which would silently allow traversal to unexpected directories. Explicit rejection is clearer and safer.

## Decision: Query parameters passed to the script

**Decision**: CGI-style environment variables: `QUERY_STRING` holds the raw query string; each decoded query parameter is also exposed as `QUERY_<NAME>=<value>`, where `<NAME>` is the parameter name with non-alphanumeric characters replaced by `_`. Additionally `REQUEST_METHOD`, `SCRIPT_NAME`, `CONTENT_LENGTH`, and `CONTENT_TYPE` are set.

**Rationale**:
- Raw `QUERY_STRING` keeps parity with the CGI convention and lets sophisticated scripts parse themselves.
- `QUERY_<NAME>` gives simple scripts zero-effort access: the demo's `head` handler reads `$QUERY_REPO` directly.
- Sanitizing parameter names to `[A-Za-z0-9_]` prevents environment variable injection through hostile parameter names.

**Alternatives considered**:
- Pass query params as argv to the script — ordering and escaping get messy for shells.
- Only `QUERY_STRING` — forces trivial scripts to implement parsing.

## Decision: POST body passed via standard input

**Decision**: The POST request body is written to a temporary file, which is redirected as the child's stdin. `CONTENT_LENGTH` and `CONTENT_TYPE` are passed as environment variables.

**Rationale**:
- `std.process.spawnProcess` accepts a `File` for stdin; a temp file avoids pipe-deadlock concerns with the event loop and keeps memory bounded for larger bodies.
- Handlers read the body with `cat`/`read` — the demo's `bundle` handler writes stdin to a temp file for `git fetch`.

**Alternatives considered**: A `pipe()` between the event loop and the child — requires concurrent writers and risks blocking the fiber if the child doesn't drain. Temp file is simpler and matches LAN-scale body sizes (git bundles are small).

## Decision: Script execution off the event loop with a timeout

**Decision**: Each invocation runs inside `vibe.core.task.runWorkerTask` (worker thread pool). The child is spawned with `std.process.spawnProcess`, stdout/stderr redirected to temp files, then polled with `waitNoHang` until exit or a timeout (default 10 s, `--script-timeout=SECS`), after which the process is killed. Exit code 0 → 200 with stdout as the body; non-zero → 500; timeout → 500.

**Rationale**:
- `spawnProcess` blocks its calling thread; running it on the event loop would stall all requests during a slow or hung script. `runWorkerTask` moves the blocking wait off the loop while keeping the response fiber simple.
- Temp files for stdout/stderr avoid pipe buffer deadlock (a chatty script can't wedge the worker).
- A hard timeout bounds the damage of a stuck handler, and the response is deterministic (500, no partial body).

**Alternatives considered**:
- `std.process.execute` (blocking, collects output) — blocks the event loop; rejected.
- vibe.d's async process handling (`vibe.core.process`) — more machinery than needed for short-lived scripts.
- No timeout — a hung script would leak worker threads; rejected.

## Decision: Router design — script-aware dispatch with echo fallback

**Decision**: The router gains `GET /:name` and `POST /:name` routes. GET: if `handlers/<name>.get.*` exists → execute; else echo `<name>` as text/plain (feature 001 behavior). POST: if `handlers/<name>.post.*` exists → execute; else 404.

**Rationale**:
- Single-segment paths (`/:name`) preserve feature 001's echo semantics exactly (its route was already `/:whatever`).
- Script-precedence-then-fallback keeps every existing 001/002 BATS test green: `GET /hello%20world` still echoes "hello world" because no handler named "hello world" exists.
- POST with no script has no echo to fall back to, so 404 is the only sensible answer.

**Alternatives considered**: Multi-segment wildcard routes — unnecessary scope; the echo contract is single-segment.

## Decision: Demo topology — one live server, simulated local side

**Decision**: The BATS demo runs exactly one server instance, playing the peer's contract. The local side is simulated by invoking the feature-002 callback script directly with the peer's context (env vars per `contracts/callback.md`), exactly as the server would spawn it after a discovery event.

```
/tmp/<test>/origin/          → bare-ish shared history (not strictly needed; see below)
/tmp/<test>/local/{alpha,beta,gamma}   ← simulated local side (callback acts here)
/tmp/<test>/peer/{alpha,beta,gamma}    ← served by the ONE live server (handlers/head.get.sh, handlers/bundle.post.sh)
```

For each repo: the callback GETs `https://<server>/head?repo=<name>` (via `mtls_curl`), compares with the local HEAD; if the local HEAD strictly advances the peer HEAD (peer HEAD is an ancestor), it creates a git bundle and POSTs it to `/bundle?repo=<name>` (via `mtls_curl_post`). The server's `bundle` handler applies the bundle to the peer repo (fetch + fast-forward). The test asserts: `alpha` and `beta` peer repos now match local HEADs; `gamma` (already in sync) received no bundle.

**Rationale**:
- The user explicitly asked to keep it simple and simulate only the other side's contract.
- This also sidesteps the loopback-multicast limitation (the loopback interface lacks MULTICAST; discovery joins fail — documented in features 001/002).
- The callback contract is identical whether triggered by a real multicast event or invoked directly with the same env vars, so the test exercises the real integration surface.

**Alternatives considered**: Two live servers + real multicast — impossible on this loopback-only host (MULTICAST flag missing on `lo`). A mock HTTP server instead of `mtls-hello` — wouldn't exercise the real mTLS/script-endpoint stack.

## Decision: Repo fixture construction

**Decision**: The BATS test builds repositories with plain `git` commands in a fresh `/tmp` directory per run: init + commit a base commit in a shared origin (both sides clone from it), then advance local `alpha` (+1 commit) and `beta` (+2 commits) ahead of the peer copies; `gamma` stays in sync (no local commits). History is linear for fast-forward merges.

**Rationale**:
- Cloning from a shared origin guarantees the peer HEAD is an ancestor of the local HEAD for `alpha`/`beta` — the precondition for a fast-forward bundle application.
- `gamma` in sync exercises the "no bundle sent" branch (SC-006).
- Linear history keeps `git merge --ff-only` deterministic.

**Alternatives considered**: Unrelated histories + full bundle replace — more complex, and diverged-history handling is explicitly out of scope (logged, not merged).

## Decision: Bundle creation and application

**Decision**: Local side creates the bundle with `git bundle create <file> HEAD` (full reachable history of HEAD). The peer's `bundle` handler writes stdin to a temp file, runs `git fetch <file> HEAD`, then `git merge --ff-only FETCH_HEAD`; failures exit non-zero → 500.

**Rationale**:
- `git bundle create <file> HEAD` is self-contained: it includes all commits reachable from HEAD, so the peer can fast-forward from any ancestor.
- Fast-forward merge is safe for the demo's linear history and fails loudly on divergence (handler exits non-zero, repo unchanged — matching the spec's edge case).
- `git fetch` from a bundle file is a well-supported core operation.

**Alternatives considered**: Incremental bundles (`<peer>..<HEAD>`) — more efficient but requires knowing the peer HEAD at bundle time and complicates the handler; rejected for the demo.

## Decision: Test dependency — git in the Guix shell

**Decision**: Add `(specification->package "git")` to `guix.scm`.

**Rationale**: `git` is absent from the current shell but the demo test needs `git init`, `git clone`, `git commit`, `git bundle`, `git fetch`, `git merge`. Without it the BATS demo cannot run in the documented environment.

**Alternatives considered**: Shelling out to host git — breaks the "everything via guix shell" invariant of the project's dev environment.
