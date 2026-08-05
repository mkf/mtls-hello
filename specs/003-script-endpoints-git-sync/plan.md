# Implementation Plan: Script-Executing Endpoints and Multi-Repo Git Sync Demo

**Branch**: `003-script-endpoints-git-sync` | **Date**: 2026-03-19 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/003-script-endpoints-git-sync/spec.md`

## Summary

Turn the mTLS echo server into a generic mutually-authenticated remote-command channel: `GET /<name>` and `POST /<name>` execute operator-provided scripts from a configurable handlers directory (two separate scripts per name — one per method). Query parameters are passed to the script via CGI-style environment variables; the POST body is passed on standard input; script stdout becomes the response body. When no script matches, GET falls back to the existing echo behavior and POST returns 404 — preserving feature 001's contract. A BATS end-to-end test demonstrates the intended use: one live server plays the peer's contract (HEAD lookup + bundle receipt over mTLS), and a simulated local-side callback (per feature 002's contract) synchronizes multiple independent git repositories in `/tmp` by GETting the peer's HEAD and POSTing a git bundle when the local side is ahead.

## Technical Context

**Language/Version**: D — LDC 1.27.1 (frontend 2.097) via Guix; host also has DMD 2.112.1 / LDC 1.42.0 (host link fails on LibreSSL, so Guix is the build target).

**Primary Dependencies**: vibe-d 0.10.3 (vibe-http 1.5.1, vibe-core 2.14.0), deimos `openssl` bindings 3.4.0, std.socket (phobos), std.process (phobos — `spawnProcess`, `waitNoHang`), std.stdio (phobos — temp files for stdin/stdout/stderr redirection), vibe.core.task `runWorkerTask` (off-event-loop execution), git CLI (test-only, for the demo).

**Storage**: Filesystem — handlers directory (`handlers/` by default), per-hostname cert store and discovery callback from feature 002 unchanged. No database. Demo test uses temporary git repositories under `/tmp`.

**Testing**: BATS (`tests/smoke.bats`) for end-to-end HTTPS/mTLS/script-execution behavior; git CLI to build the multi-repo demo fixture. Discovery callback is simulated by direct script invocation (loopback-only hosts cannot join multicast — same environmental constraint as features 001/002).

**Target Platform**: Linux (x86_64), LAN-connected hosts. Deployed via `guix shell -f guix.scm`.

**Project Type**: web-service (HTTPS server, single binary) with operator-provided script endpoints and shell callbacks.

**Performance Goals**: LAN-scale — a handful of instances, low request rate. Script execution must not block the event loop (worker thread + timeout). Default script timeout 10 seconds.

**Constraints**: Same Guix/LDC/OpenSSL build constraints as features 001/002 (see `specs/001-mtls-echo-discovery/research.md`). `spawnProcess` blocks the calling thread — must run inside `runWorkerTask` to keep vibe.d's event loop responsive. Script names and query parameter names must be sanitized (path traversal / env-var injection). `git` is NOT currently in `guix.scm` — must be added for the demo test.

**Scale/Scope**: Replaces the single echo route with script-aware GET/POST dispatch in `source/app.d`; new `source/handlers.d` module (script resolution + execution); new `handlers/` directory with example scripts; extended `scripts/on-discover.sh` (POST helper + multi-repo sync); extended BATS suite. ~150 additional lines of D, ~80 lines of bash.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- `.specify/memory/constitution.md` is an unfilled template — no named principles or binding gates exist.
- **Result: PASS** (no gate violations possible). Re-checked after Phase 1: no new gates introduced; still PASS.

## Project Structure

### Documentation (this feature)

```text
specs/003-script-endpoints-git-sync/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── http.md          # Script endpoint contract (GET/POST, env, stdin/stdout)
│   ├── cli.md           # New CLI options (--handlers-dir, --script-timeout)
│   └── callback.md      # Extended discovery callback (mtls_curl_post, multi-repo sync)
└── tasks.md             # Phase 2 output (/speckit.tasks — NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
source/
├── app.d               # wiring; router: GET/POST /:name script-aware dispatch + echo fallback
├── multicast.d         # discovery: unchanged (features 001/002)
└── handlers.d          # NEW: script resolution, sanitization, execution (worker + timeout)

scripts/
├── gen_certs.sh        # PKI generation (existing)
└── on-discover.sh      # discovery callback (002): extended with mtls_curl_post + multi-repo example

handlers/                # NEW default handlers directory (operator scripts)
├── head.get.sh         # example: git rev-parse for a repo selected by ?repo=
└── bundle.post.sh      # example: apply a git bundle from stdin to a repo selected by ?repo=

tests/
└── smoke.bats          # extended: script endpoint tests + multi-repo git sync demo
```

**Structure Decision**: Same single-binary layout as features 001/002. New `source/handlers.d` module keeps script logic out of `app.d`. `handlers/` ships example scripts that double as documentation. `guix.scm` gains `git`.

## Complexity Tracking

> No constitution violations. No complexity justifications required.
