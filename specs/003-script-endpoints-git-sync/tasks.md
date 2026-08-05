# Tasks: Script-Executing Endpoints and Multi-Repo Git Sync Demo

**Input**: Design documents from `/specs/003-script-endpoints-git-sync/`

**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: BATS end-to-end tests are this project's established verification convention (features 001/002) and the demo test was explicitly requested in the feature description. Tests are written before implementation and must FAIL initially.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- Single project: `source/`, `tests/`, `handlers/`, `scripts/` at repository root (per plan.md structure).

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and environment preparation

- [x] T001 Add `(specification->package "git")` to the package list in `guix.scm` (required by the demo test's git fixtures)
- [x] T002 [P] Verify baseline: run `just test` and confirm all existing 001/002 BATS tests still pass before any changes

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T003 Extend `ServerConfig` and `parseArgs` in `source/app.d` with `--handlers-dir` (default `handlers`, relative to working directory) and `--script-timeout` (default `10` seconds, integer ≥ 1; values < 1 are a startup error)
- [x] T004 Create `source/handlers.d`: `HandlerConfig` struct (`handlersDir`, `scriptTimeout`), plus `sanitizeName(string)` — rejects empty names, `/`, `\`, `.`, `..`, and leading `.` (dots are structural in handler file names per `contracts/http.md`)
- [x] T005 Implement `resolveScript(HandlerConfig, string method, string name)` in `source/handlers.d` — resolution order: exact file `<handlersDir>/<name>.<method>`, then any file starting with `<handlersDir>/<name>.<method>.` (lexicographically first if several); returns `string` path or `null`
- [x] T006 Implement `executeScript(HandlerConfig, string scriptPath, string[string] env, File bodyFile)` in `source/handlers.d` — spawns via `std.process.spawnProcess` inside `vibe.core.core.runWorkerTask`; child stdin from `bodyFile` (empty temp file for GET), stdout/stderr redirected to temp files; poll `Pid.waitNoHang` until exit or `scriptTimeout` (kill on timeout); returns a struct with `exitCode`, `timedOut`, `stdout`, `stderr` (research.md decisions: off-event-loop execution, temp-file redirection)
**Checkpoint**: Foundation ready — script resolution and execution primitives exist; user story implementation can now begin

---

## Phase 3: User Story 1 - Method-Specific Script Endpoints (Priority: P1) 🎯 MVP

**Goal**: `GET /<name>` and `POST /<name>` execute operator scripts from the handlers directory (`<name>.<method>.*`), passing query parameters as env vars and the POST body on stdin; stdout becomes the response. Without a matching script, GET echoes the path segment (feature 001) and POST returns 404.

**Independent Test**: Start the server with a handlers directory; `curl` (mTLS) a GET handler with `?repo=...` and assert its stdout is returned; POST a body and assert the handler saw it; assert echo fallback, POST 404, 400 on bad names, and 500 on failing/timeout scripts.

### Tests for User Story 1 (write FIRST — must fail) ⚠️

- [x] T007 [US1] Add script-endpoint BATS tests to `tests/smoke.bats`: (a) GET executes a handler and returns its stdout; (b) GET query params observable (handler echoes `$QUERY_REPO`); (c) POST body received on stdin (handler echoes `$(cat)`); (d) GET without script echoes the path segment; (e) POST without script → 404; (f) handler name with `.` or `/` → 400; (g) handler exiting non-zero → 500 with no partial body. Use a temp handlers dir (`mktemp -d`) so tests don't depend on committed handlers

### Implementation for User Story 1

- [x] T008 [P] [US1] Create example handler `handlers/head.get.sh` (executable, `#!/bin/bash`): `git -C "$REPOS_ROOT/$QUERY_REPO" rev-parse HEAD` (per `contracts/http.md` example)
- [x] T009 [P] [US1] Create example handler `handlers/bundle.post.sh` (executable, `#!/bin/bash`, `set -euo pipefail`): stdin → temp file → `git fetch` + `git merge --ff-only FETCH_HEAD` → echo `ok` (per `contracts/http.md` example)
- [x] T010 [US1] Implement env-var construction in `source/handlers.d`: `QUERY_STRING` (raw), `QUERY_<NAME>` per decoded query param (non-alphanumerics → `_`), `REQUEST_METHOD`, `SCRIPT_NAME`, `CONTENT_LENGTH`/`CONTENT_TYPE` for POST (per `contracts/http.md`); build the `string[string] env` argument for `executeScript`
- [x] T011 [US1] Implement router dispatch in `source/app.d` `buildRouter()`: replace the single GET echo route with `GET /:name` and `POST /:name` routes — sanitize name (400 on violation), resolve script (`resolveScript`), execute with env + body (`executeScript`); exit 0 → 200 text/plain with stdout, non-zero or timeout → 500; no script → GET echoes name (feature 001 fallback), POST → 404 (per `contracts/http.md`)
- [x] T012 [US1] Wire `HandlerConfig` into `main()` in `source/app.d`: read `--handlers-dir`/`--script-timeout` from `ServerConfig`, log the handlers dir at startup; for POST requests, stream `req.bodyReader` to the temp body file before execution
- [x] T013 [US1] Run `just build` then `just test`; verify all 001/002 tests AND the new US1 tests pass

**Checkpoint**: User Story 1 is fully functional and testable independently — script endpoints work with echo fallback preserved

---

## Phase 4: User Story 2 - Multi-Repo Git Synchronization Demo (Priority: P2)

**Goal**: An end-to-end BATS demo proving the composed system: one live server plays the peer contract (HEAD lookup + bundle receipt over mTLS); a simulated local-side callback (feature 002 contract) syncs multiple independent git repos in `/tmp`, GETting the peer HEAD and POSTing a git bundle only where the local side is ahead.

**Independent Test**: Run the BATS demo test — it builds git fixtures (`origin`, `local/{alpha,beta,gamma,delta}`, `peer/{...}`), starts ONE server serving the peer repos, invokes the callback script directly with the peer's env context, and asserts: peer `alpha`/`beta` reach local HEADs (bundle pushed), in-sync `gamma` receives no bundle, diverged `delta` receives no bundle.

### Tests for User Story 2 (write FIRST — must fail) ⚠️

- [x] T014 [US2] Add demo fixture helpers to `tests/smoke.bats`: `mkfixture()` creating a fresh `/tmp/mtls-demo-<pid>/` with `origin` (base commit), `local/` and `peer/` clones of `{alpha, beta, gamma, delta}`; advance local `alpha` +1 and `beta` +2 commits (linear), leave `gamma` in sync, give `delta` an unrelated diverged history (per `research.md` "Repo fixture construction")

### Implementation for User Story 2

- [x] T015 [P] [US2] Create `scripts/on-discover.sh` (executable): feature 002 callback extended per `contracts/callback.md` — `mtls_curl` (GET helper), `mtls_curl_post` (POST helper, `--data-binary @file`), and a multi-repo loop over `$REPOS_ROOT/*/`: GET `/head?repo=<name>` via `mtls_curl`, compare local HEAD; if local HEAD strictly advances the peer HEAD (`git merge-base --is-ancestor`), `git bundle create <file> HEAD` and `mtls_curl_post "/bundle?repo=<name>" <file>`; equal/behind/diverged → log and skip
- [x] T016 [US2] Add the demo BATS test to `tests/smoke.bats`: start ONE server on a scratch port with `REPOS_ROOT=<fixture>/peer` exported and `--handlers-dir handlers`; invoke `scripts/on-discover.sh` directly with the peer env context (`HOST_NAME=peer`, `PEER_NETLOC=localhost:<port>`, `PEER_CERT_FILE=certs/certs/server.crt`, `OUR_CERT=certs/certs/client.crt`, `OUR_KEY=certs/private/client.key`, `REPOS_ROOT=<fixture>/local`) — this simulates the local side exactly as the server would spawn it after a discovery event (per `contracts/callback.md` demo topology)
- [x] T017 [US2] Add demo assertions to `tests/smoke.bats`: after the callback, peer `alpha`/`beta` HEADs equal local HEADs (bundle applied via `bundle.post.sh` fast-forward); peer `gamma` unchanged (no bundle); peer `delta` unchanged (diverged → no bundle); callback exits 0
- [x] T018 [US2] Run `just build` then `just test`; verify the demo test passes and all prior tests remain green

**Checkpoint**: User Stories 1 AND 2 work — the git-sync demo proves the end-to-end integration

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [x] T019 [P] Validate `specs/003-script-endpoints-git-sync/quickstart.md` end-to-end: run the handler-writing, curl, and demo steps; fix any drift between docs and implementation
- [x] T020 Cross-check `contracts/http.md` (env vars, status mapping, sanitization), `contracts/cli.md` (option names/defaults), and `contracts/callback.md` (helper semantics) against the implementation in `source/app.d`, `source/handlers.d`, `scripts/on-discover.sh`
- [x] T021 Run the full suite `just test` one final time; confirm no leftover temp processes/files; confirm `git status` shows only intended changes
- [x] T022 [P] Update `specs/003-script-endpoints-git-sync/quickstart.md` Troubleshooting with any new failure modes discovered during implementation

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately (T001, T002 in parallel)
- **Foundational (Phase 2)**: Depends on Setup; BLOCKS both user stories
- **US1 (Phase 3)**: Depends on Foundational (T003–T006)
- **US2 (Phase 4)**: Depends on Foundational AND US1 (the demo requires script endpoints; the callback requires the `handlers/head.get.sh` + `handlers/bundle.post.sh` examples)
- **Polish (Phase 5)**: Depends on US1 + US2

### User Story Dependencies

- **US1 (P1)**: Independently testable after Foundational — no dependency on US2
- **US2 (P2)**: Depends on US1 (script endpoints) + committed handlers + `scripts/on-discover.sh` (created in US2 itself)

### Within Each User Story

- Tests FIRST (fail) → implementation → tests green
- Env construction (T010) before router dispatch (T011) — dispatch depends on it
- Fixture helpers (T014) before demo test (T016/T017)
- Example handlers (T008/T009) before the demo (US2 uses them)

### Parallel Opportunities

- T001 ∥ T002 (Setup)
- T008 ∥ T009 (handlers examples, different files)
- T015 (on-discover.sh) can be written in parallel with T016 fixture work (different files) once T014 lands
- T019 ∥ T022 (docs, different files)

---

## Parallel Example: User Story 1

```bash
# Launch all example-handler tasks together (different files, no deps):
Task: "T008 Create example handler handlers/head.get.sh"
Task: "T009 Create example handler handlers/bundle.post.sh"

# Sequential chain (same file / data dependency):
T007 (tests, must fail) → T010 (env construction) → T011 (dispatch) → T012 (wiring) → T013 (verify)
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001, T002)
2. Complete Phase 2: Foundational (T003–T006)
3. Complete Phase 3: User Story 1 (T007–T013)
4. **STOP and VALIDATE**: script endpoints work; echo fallback preserves feature 001; all BATS green
5. Deploy/demo if ready

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. US1 (script endpoints) → test → deploy (MVP!)
3. US2 (git sync demo) → test → demo the composed system
4. Polish (docs validation, cross-checks)

### Notes

- Feature 002's `scripts/on-discover.sh` was planned but not implemented on its branch; 003's demo requires the callback, so T015 creates the extended version (002's `mtls_curl` + 003's `mtls_curl_post` + multi-repo loop) — it will serve feature 002's needs when that branch resumes.
- The demo uses exactly one live server instance (the user's explicit simplification); the local side is simulated by direct callback invocation with the peer's env context.
- Commit after each task or logical group; stop at any checkpoint to validate independently.
