# Data Model: Script-Executing Endpoints and Multi-Repo Git Sync Demo

**Branch**: `003-script-endpoints-git-sync` | **Date**: 2026-03-19 | **Feature**: [spec.md](./spec.md)

## Entities

### ScriptEndpoint

A URL path name mapped to up to two executable scripts (one per HTTP method).

| Field | Type | Source | Description |
|---|---|---|---|
| `name` | string | URL path segment (decoded) | Handler name, e.g. `head`, `bundle` |
| `method` | enum {GET, POST} | HTTP request method | Selects which variant runs |
| `scriptPath` | string | `handlersDir/<name>.<method>.*` | Resolved executable path |

Validation: `name` non-empty, no `/`, `\`, or `.` (dots are structural in handler file names), not `.`/`..`, not starting with `.`; `scriptPath` must exist and be a regular executable file.

### ScriptInvocation

A single execution of a handler script.

| Field | Type | Description |
|---|---|---|
| `requestMethod` | string | `GET` or `POST` (env `REQUEST_METHOD`) |
| `scriptName` | string | Handler name (env `SCRIPT_NAME`) |
| `queryString` | string | Raw query string (env `QUERY_STRING`) |
| `queryParams` | string→string | Decoded params (env `QUERY_<NAME>` per param) |
| `contentLength` | string (nullable) | POST body size (env `CONTENT_LENGTH`) |
| `contentType` | string (nullable) | POST content type (env `CONTENT_TYPE`) |
| `bodyFile` | File (nullable) | Temp file with POST body → child stdin |
| `stdoutFile` | File | Temp file capturing child stdout |
| `stderrFile` | File | Temp file capturing child stderr |
| `exitCode` | int | Child exit status |
| `timedOut` | bool | Whether the timeout was exceeded |

Transitions: `created → running (runWorkerTask) → exited | timedOut`.

### HandlerConfig

Server configuration for the script endpoint subsystem.

| Field | Type | Default | Description |
|---|---|---|---|
| `handlersDir` | string | `"handlers"` | Root of the handler script tree |
| `scriptTimeout` | Duration | 10 s | Per-invocation timeout before kill |

### HandlerResponse

Result of a script invocation mapped to HTTP.

| Field | Type | Description |
|---|---|---|
| `statusCode` | int | 200 (exit 0) / 500 (non-zero or timeout) / 404 (no script for POST) |
| `body` | string | Script stdout (200) or empty/error note |
| `contentType` | string | `text/plain; charset=utf-8` |

### DemoFixture (test-only)

State for the multi-repo git sync BATS test.

| Field | Type | Description |
|---|---|---|
| `originRepo` | path | Shared base history (both sides clone from it) |
| `localRepos` | map name→path | Simulated local side repos (`alpha`, `beta`, `gamma`) |
| `peerRepos` | map name→path | Repos served by the one live instance |
| `syncState` | enum {equal, localAhead, peerAhead, diverged} | Per-repo HEAD relationship |

### SyncDecision (callback logic)

The callback script's per-repo determination.

| State | Action |
|---|---|
| equal | no bundle |
| localAhead (peer HEAD ancestor of local HEAD, unequal) | create bundle, POST to `/bundle?repo=<name>` |
| peerAhead | no bundle (peer's own callback pushes in real deployments) |
| diverged | no bundle, log |

## State Transitions

**Request → response** (per request):
`HTTP request (GET/POST /:name)` → validate name → resolve `handlers/<name>.<method>.*` → (exists?) → spawn child in worker thread → collect stdout/stderr/exit → map to `HandlerResponse` → (not exists?) → GET: echo name; POST: 404.

**Demo test flow**:
`build fixtures (origin, local, peer)` → `start one server (peer contract)` → `invoke callback directly (simulated local side)` → per repo: GET head → compare → bundle+POST if localAhead → assert peer repos updated, in-sync repo untouched.
