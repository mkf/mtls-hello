# Feature Specification: Script-Executing Endpoints and Multi-Repo Git Sync Demo

**Feature Branch**: `003-script-endpoints-git-sync`

**Created**: 2026-03-19

**Status**: Draft

**Input**: User description: "I will also want a BATS test to exemplify the script containing a command, and a custom GET / POST endpoint being present (i want the program to execute custom shell scripts per the name in /:name-of-the-script/, as either GET or POST (thats going to be two separate shell scripts?) with query parameters passed to the script), so that upon detection of one another they will, for two example git repos made for the purpose of the test in /tmp, get their HEAD with GET and POST themselves a git bundle to the newer HEAD. You dont have to run both sides, okay. Keep it simple and only simulate the contract of the other side. I also meant for there to be multiple repos because i want host to sync multiple independent repos."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Method-Specific Script Endpoints (Priority: P1)

The operator places executable scripts in a handlers directory. When an authenticated peer requests `/<name>` via GET or POST, the server executes the method-specific script for `<name>` — two separate script files, one per method. Query parameters are passed to the script, and for POST the request body is passed as well. The script's standard output becomes the response body. This turns the service into a generic, mutually authenticated remote-command channel for trusted LAN peers.

**Why this priority**: This is the core mechanism — without script endpoints, neither the demo nor any peer-to-peer automation is possible. It is independently valuable: any operator-defined behavior can be exposed to authenticated peers.

**Independent Test**: Start the server with a handlers directory containing a GET script and a POST script for the same name; issue authenticated GET and POST requests with query parameters and a body; verify each script ran, received its inputs, and its output was returned. Delivers value by letting peers invoke operator-defined behavior.

**Acceptance Scenarios**:

1. **Given** a GET script exists for name `status`, **When** an authenticated peer requests `GET /status`, **Then** the script executes and its standard output is returned as the response body.
2. **Given** a GET script exists for name `status`, **When** an authenticated peer requests `GET /status?repo=alpha`, **Then** the script receives the query parameter `repo=alpha`.
3. **Given** a POST script exists for name `submit`, **When** an authenticated peer requests `POST /submit` with a request body, **Then** the script receives the body as input.
4. **Given** GET and POST scripts both exist for name `data`, **When** each method is requested, **Then** the corresponding method-specific script executes (GET script for GET, POST script for POST).
5. **Given** no script exists for name `hello`, **When** an authenticated peer requests `GET /hello`, **Then** the existing echo behavior returns `hello` (backward compatibility).
6. **Given** no POST script exists for name `hello`, **When** an authenticated peer requests `POST /hello`, **Then** the request fails with a not-found error.
7. **Given** a script that exits non-zero, **When** it is requested, **Then** the response indicates a server-side execution error and no partial output is returned.
8. **Given** a request path containing directory traversal sequences (e.g., `/../evil`), **When** it is requested, **Then** the request is rejected and no script outside the handlers directory can execute.

---

### User Story 2 - Multi-Repo Git Synchronization Demo (Priority: P2)

An automated end-to-end test demonstrates the intended use of script endpoints together with peer discovery: hosts keep multiple independent version-control repositories synchronized. The test sets up several independent repositories in a temporary directory on each of two sides, runs **one** live server instance that plays the peer's side of the contract (exposing repository HEAD lookup and bundle-receiving endpoints), and simulates the local side's discovery callback. For each repository, the callback reads the peer's HEAD via GET, compares it with the local HEAD, and — when the local side is ahead — sends a repository bundle via POST so the peer advances to the newer HEAD. The test verifies every lagging repository on the peer side is synchronized and already-synchronized repositories are left untouched.

**Why this priority**: This is the exemplar proving the composed system (discovery callback from the previous feature + script endpoints + per-host credentials) achieves the real goal: multi-repo state synchronization between mutually authenticated peers. It also serves as living documentation for operators writing their own callback scripts.

**Independent Test**: Run the automated test suite; it creates the repositories, starts one server instance, invokes the simulated callback, and asserts final repository states. No second server instance is required.

**Acceptance Scenarios**:

1. **Given** two sides each holding the same set of multiple independent repositories with differing HEADs, **When** the simulated discovery callback runs for each repository, **Then** every repository where the local side is ahead results in the peer's repository advancing to the local HEAD.
2. **Given** a repository where both sides already share the same HEAD, **When** the simulated callback runs, **Then** no bundle is sent for that repository.
3. **Given** a repository where the peer side is ahead, **When** the simulated callback runs, **Then** the local side takes no destructive action (the peer's own callback is responsible for pushing in that direction).
4. **Given** the peer's HEAD endpoint, **When** the callback queries it with a repository identifier as a query parameter, **Then** the response identifies that repository's HEAD — demonstrating query-parameter-driven selection among multiple repositories on one endpoint name.
5. **Given** the full demo, **When** the test runs, **Then** it completes using exactly one server instance (the peer contract is simulated locally).

---

### Edge Cases

- Requested script name has no matching script for that method → GET falls back to echo; POST returns not-found.
- Script file exists but is not executable → server-side execution error response.
- Script runs longer than a bounded timeout → terminated; error response.
- POST with an empty body → script receives empty input; behavior is script-defined.
- Query parameter names/values with special characters → passed through in a decodable, unambiguous form; script name sanitization prevents path traversal.
- Repositories with unrelated or diverged histories (neither HEAD is an ancestor of the other) → no bundle is sent; the situation is logged for the operator.
- Bundle transmission fails or is rejected by the receiving side → receiving repository is left unchanged (no partial application).
- Multiple repositories with mixed states (some ahead, some in sync, some behind) → each is handled independently; one failing repository does not block the others.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The server MUST execute an operator-provided script when an authenticated peer requests `GET /<name>` and a GET-variant script for `<name>` exists.
- **FR-002**: The server MUST execute an operator-provided script when an authenticated peer requests `POST /<name>` and a POST-variant script for `<name>` exists.
- **FR-003**: GET and POST variants of an endpoint MUST be separate script files, resolved by a documented naming/location convention.
- **FR-004**: Query parameters MUST be passed to the executed script in a decodable form.
- **FR-005**: For POST requests, the request body MUST be passed to the executed script as input.
- **FR-006**: On successful script execution, the script's standard output MUST be returned as the response body.
- **FR-007**: A script that exits non-zero or times out MUST produce an error response and MUST NOT return partial output.
- **FR-008**: Script names MUST be sanitized so that no file outside the handlers directory can be executed (path traversal prevention).
- **FR-009**: The handlers directory MUST be configurable at startup, with a documented default.
- **FR-010**: All endpoints MUST remain behind mutual TLS (unchanged from prior features).
- **FR-011**: When no script matches a GET request, the server MUST fall back to the existing echo behavior. When no script matches a POST request, the server MUST return a not-found error.
- **FR-012**: The demonstration test MUST exercise HEAD lookup (GET) and bundle submission (POST) for multiple independent repositories, selecting the repository via a query parameter.
- **FR-013**: The demonstration test MUST use exactly one live server instance; the local side's callback is simulated by direct invocation with the peer's context (consistent with the callback contract from the previous feature).
- **FR-014**: The demonstration callback MUST send a bundle for a repository only when the local side's HEAD strictly advances the peer's HEAD (peer HEAD is an ancestor); equal, behind, and diverged states MUST NOT produce a bundle submission.

### Key Entities

- **Script Endpoint**: A URL path name mapped to up to two executable scripts (one per method). Attributes: name, method variants present, handlers directory location.
- **Script Invocation**: A single execution. Inputs: query parameters, request body (POST only). Outputs: standard output (response body), exit status (success vs. error).
- **Repository (per side)**: An independent version-controlled repository tracked for synchronization. Identified by a repository identifier passed as a query parameter.
- **Repository State Comparison**: The relationship between local and peer HEADs: equal, local-ahead, peer-ahead, or diverged.
- **Bundle**: A self-contained transfer artifact carrying repository objects from the ahead side to the behind side.
- **Demo Topology**: One live server (peer contract) + one simulated local side (callback + repositories), both rooted in a temporary directory.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In 100% of test runs, an authenticated GET to a script-backed endpoint returns exactly the script's standard output.
- **SC-002**: In 100% of test runs, query parameters issued in the request are observable by the executed script.
- **SC-003**: In 100% of test runs, a POST body is delivered intact to the executed script.
- **SC-004**: In 100% of test runs, requests to names without scripts behave exactly as before (GET echoes the path segment; POST is rejected as not found).
- **SC-005**: In 100% of test runs, a failing script yields an error response with no partial output.
- **SC-006**: In 100% of demo test runs, every repository where the local side is ahead ends with the peer side at the local HEAD, and repositories already in sync receive no bundle submission.
- **SC-007**: The demo test completes in under 60 seconds using one server instance.

## Assumptions

- GET and POST variants are indeed two separate script files (answering the open musing in the feature description affirmatively); the exact naming/location convention is a planning detail.
- Script input/output conventions (how query parameters and bodies are passed, e.g., environment variables and standard input) follow established common-gateway conventions; exact mechanics are a planning detail.
- The default handlers directory is a top-level `handlers/` directory, overridable at startup.
- Script execution is bounded by a default timeout (planning detail; ~10 seconds).
- The demo uses exactly one live server instance to play the peer's contract; the local side is simulated by invoking the callback script directly with the peer's context. This sidesteps the loopback-multicast limitation and halves the moving parts.
- In the demo, both sides hold the same set of repository identifiers; "multiple independent repos" means each repository has its own unrelated history and is synced independently of the others.
- Synchronization is push-based: the side that detects it is ahead sends a bundle. The opposite direction is handled by the peer's own callback in real deployments and is not simulated in the test (the contract is symmetric).
- Repositories in the demo are pre-created in a temporary directory; production repository provisioning is out of scope.
- Diverged repositories are logged, not auto-merged; conflict resolution is out of scope.
- The existing echo endpoint behavior remains for GET requests without a matching script, preserving backward compatibility with the first feature's contract.
