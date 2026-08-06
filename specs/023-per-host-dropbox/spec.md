# Feature Specification: Per-Host Drop-Box

**Feature Branch**: `023-per-host-dropbox`

**Created**: 2026-08-06

**Status**: Draft

**Input**: User description: "implement an endpoint (support several http methods, as one does for files), and a client wrapper for each http method, that transparently (under /drop, each host only sees theirs directly) allows each host to drop something into their drop-box directory /drop, and to access it. If its easy enough, you can even implement some of all WebDAV methods so that it can even create directories with MKCOL. Keep it simple and vanilla — maybe mod_dav will suit us very well? Note: if complexity grows, step back and ask us to give up and backtrack."

## Clarifications

### Session 2026-08-06

- Q: Should the URL namespace be transparent (same `/drop/<name>` resolves per CN) or explicit (each caller's URL must include their own hostname, and the server enforces it matches the verified CN)? → A: **Explicit-per-hostname.** The on-the-wire path is `/drop/<hostname>/<rest>`, where `<hostname>` is the verified CN. Each host sees and can only access content under its own `/drop/<hostname>/...`. A request whose first segment does not equal the verified CN is rejected with **403 Forbidden**; an unauthenticated or untrusted client still receives **401 Unauthorized** via the existing trust gate (FR-007). Replaces the earlier "transparent-per-caller" wording.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Drop a file and get it back, in your own isolated box (Priority: P1)

As a trusted host (with CN = `alice`, say), I want to drop a file into my drop-box at `/drop/alice/<name>` and later retrieve it from the same path, so that I can exchange ad-hoc artifacts with the server host without coupling to the git-sync workflow. The URL is **explicit-per-hostname**: each host's drop-box is rooted at `/drop/<hostname>/`, the host's `<hostname>` matches the verified CN, and a host can only access content under its own prefix.

**Why this priority**: This is the core value — a per-host, mutually-authenticated scratch space. Everything else (listing, deleting, directories) is layered on top.

**Independent Test**: Host `alice` PUTs a file to `/drop/alice/notes.txt` and reads it back identically; host `bob` PUTs to `/drop/bob/notes.txt` and reads back only bob's content (different paths, same first-segment behavior). Additionally, when alice tries `/drop/bob/<anything>`, the server rejects her with 403 Forbidden. Neither host can read or write the other's prefix.

**Acceptance Scenarios**:

1. **Given** a trusted host `alice`, **When** she PUTs a file to `/drop/alice/<name>`, **Then** a later GET of `/drop/alice/<name>` returns the exact bytes alice dropped.
2. **Given** two trusted hosts `alice` and `bob`, **When** alice PUTs `/drop/alice/<name>` and bob PUTs `/drop/bob/<name>` (each under their own prefix), **Then** each retrieves only the content they dropped under their own prefix; cross-host reads return 403 Forbidden.
3. **Given** trusted alice, **When** she attempts any operation under `/drop/bob/...`, **Then** the request is rejected with 403 Forbidden and no file in `/drop/bob/...` is read, written, listed, or deleted.
4. **Given** an untrusted or unauthenticated client, **When** it attempts any operation under `/drop`, **Then** it is rejected with 401 Unauthorized (existing trust gate) and never creates or reads anything.
5. **Given** alice, **When** the resolved path escapes her own prefix (e.g. `/drop/alice/foo/../bar/...` where `bar/...` leaves her prefix), **Then** the request is rejected (400 Bad Request or 403 Forbidden), and nothing outside `/drop/alice/...` is touched.

---

### User Story 2 - List and delete files in your box (Priority: P2)

As a host, I want to see what is currently in my drop-box at `/drop/<my-hostname>/` and remove items I no longer need, so the box stays manageable.

**Why this priority**: Lets a host operate the box as a real workspace rather than an append-only pile. Builds directly on US1.

**Independent Test**: A host (CN=`alice`) drops three files under `/drop/alice/`, lists the same path and sees exactly those three names, deletes one, and lists again to see the remaining two.

**Acceptance Scenarios**:

1. **Given** a host has dropped several files, **When** it lists `/drop/<my-hostname>/`, **Then** it sees only items under its own prefix; a listing that would otherwise cross hosts is disallowed.
2. **Given** a host owns a file in its box, **When** it deletes that file, **Then** the file is gone and subsequent reads report it as missing.
3. **Given** a host tries to delete a name that does not exist in its box, **Then** the request reports "not found" without error.

---

### User Story 3 - Organize with directories, copy, and move (Priority: P3, conditional on simplicity)

As a host, I want to create directories inside `/drop/<my-hostname>/`, copy items, and move/rename them, so I can structure what I drop. This is only in scope if it stays simple and vanilla; otherwise it is dropped (see Risks).

**Why this priority**: Nice-to-have that turns the box into a small filesystem; explicitly optional per the request.

**Independent Test**: Host `alice` creates `/drop/alice/archive/`, drops a file at `/drop/alice/archive/x.bin`, copies it to `/drop/alice/archive/x.copy.bin`, moves the original to `/drop/alice/archive/x.moved.bin`, and reads both back; the directory and structure appear in a listing.

**Acceptance Scenarios**:

1. **Given** host `alice`, **When** she creates a directory at `/drop/alice/<dir>`, **Then** the directory exists and files can be placed inside it.
2. **Given** alice owns an item, **When** she copies that item to a new name, **Then** both names exist with identical content.
3. **Given** alice owns an item, **When** she moves/renames that item, **Then** the old name is gone and the new name holds the content.
4. **Given** alice creates nested directories, **When** she lists `/drop/alice/`, **Then** the directory structure is visible.

---

### User Story 4 - Client wrappers for each operation (Priority: P1)

As an operator, I want a single client command per operation (drop, fetch, list, delete, and — if in scope — make-directory) that handles mutual TLS **and derives the caller's hostname prefix from the verified client certificate**, so I do not hand-write curl invocations and do not need to remember to spell out my own `<hostname>`.

**Why this priority**: Without wrappers the feature is unusable in practice; they are part of the MVP alongside US1.

**Independent Test**: Running the wrapper subcommands against a live server performs the corresponding operation over mTLS at the auto-derived hostname prefix, and returns the expected result.

**Acceptance Scenarios**:

1. **Given** a configured client whose cert CN is `alice`, **When** it runs `mtls-drop --source notes.txt --name notes.txt`, **Then** the wrapper derives `alice` from the cert and PUTs at `/drop/alice/notes.txt`; a later `mtls-fetch --name notes.txt` from the same client GETs exactly that path back.
2. **Given** the wrappers, **When** listing/deleting, **Then** each wrapper performs exactly its one operation under the derived prefix and reports clearly — never exposing another host's prefix.

---

### Edge Cases

- Path traversal (`..`, absolute paths, encoded separators) must never escape the caller's `/drop/<cn>/` box. With the explicit-per-hostname design and a static DocumentRoot at `<data-dir>/drop/`, traversal attempts that escape `<cn>/` would actually leave the configured document root entirely — a separate defense must reject them.
- Cross-host access (e.g. CN=`alice` requesting `/drop/bob/...`) is rejected with **403 Forbidden**; the existence of another host's directory MUST NOT be revealed.
- An untrusted client (cert not in trust store) is rejected with **401 Unauthorized** even before the URL prefix is checked.
- Dropping to a name that already exists overwrites it (documented; matches standard file PUT semantics) — or is rejected; the choice is fixed and documented.
- Reading/deleting a name that does not exist returns a clear "not found".
- An empty `/drop/<cn>/` lists as empty (not an error).
- A very large file is handled up to the server's configured request-size limit; exceeding it fails clearly.
- Concurrent writes to the same name from the same host: last writer wins (documented).
- The caller's `/drop/<cn>/` box is created on first use by `<mkdir -p>` (no setup step required).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST expose a drop-box namespace at `/drop/<hostname>/<rest>` for each trusted client, where `<hostname>` is the verified client certificate's CN sanitized to `[A-Za-z0-9._-]+`. The first URL segment and the verified CN MUST be equal; the URL MUST be declared by the caller (the server does not auto-prepend).
- **FR-002**: The server MUST enforce that an authenticated request is allowed only when the URL's first segment equals the verified CN. A request whose first segment does not equal the verified CN MUST be rejected as **403 Forbidden** without revealing any other host's directory contents. **Updated 2026-08-06 (clarification).**
- **FR-003**: The on-the-wire path includes the caller's own `<hostname>` as its first segment. The caller (or the caller wrapper) is responsible for declaring the hostname; the server uses it for partition selection and per-host enforcement. **Updated 2026-08-06 (clarification).**
- **FR-004**: A trusted caller MUST be able to store a file (drop) at `/drop/<cn>/<name>` and retrieve the identical bytes back from the same path (fetch).
- **FR-005**: A trusted caller MUST be able to list the names in its own box and delete a name it owns.
- **FR-006**: Any path that would escape the caller's box MUST be rejected.
- **FR-007**: Untrusted or unauthenticated clients MUST be rejected for every operation under `/drop`, exactly as for the other protected endpoints.
- **FR-008**: Each operation (drop, fetch, list, delete) MUST ship with a client wrapper that performs it over mutual TLS.
- **FR-009** *(conditional)*: If directory/organization support is implemented, a trusted caller MUST be able to create a directory, copy an item to a new name, and move/rename an item — all within its own box.
- **FR-010**: The server MUST return an entity tag (`ETag`) and a last-modified timestamp for each drop-box resource, and honor conditional-request headers: `If-None-Match` / `If-Modified-Since` on fetch (return "not modified" when unchanged) and `If-Match` / `If-Unmodified-Since` on drop **and delete** (reject a write or delete that would clobber a newer version). This provides cheap change-detection and lost-update safety without locking.
- **FR-011**: A fetch MUST support byte-range requests (`Range` / `206 Partial Content` / `Content-Range`) so large drops can be downloaded incrementally or resumed.
- **FR-012**: The `HEAD` method MUST be supported on every resource, returning the same headers as a fetch (size, type, `ETag`, `Last-Modified`) without the body.
- **FR-013**: The server MUST preserve the `Content-Type` supplied on drop and return it on fetch/head; on fetch it SHOULD also include `Content-Disposition: attachment; filename="..."` so the client wrapper can suggest a download name.
- **FR-014**: A `PROPFIND` (Depth: 0 only) MUST be supported — returning structured resource metadata (size, type, mtime, etag) without downloading the body. Recursive (Depth: 1+) PROPFIND is out of scope.
- **FR-015** *(conditional)*: If directories are in scope, a trusted caller MUST be able to remove an **empty** directory (non-recursive delete; a directory containing items is not removable — the caller must clear it first).

### Key Entities *(include if feature involves data)*

- **DropBox**: a per-caller storage area rooted at `<data-dir>/drop/<cn>/`; the on-the-wire path is `/drop/<cn>/<rest>` and the server requires literal-equality between `<cn>` (URL segment) and the verified CN.
- **DroppedItem**: a file (and, if in scope, a directory) at a path under some host's `<data-dir>/drop/<cn>/`, owned by exactly one caller.
- **CallerIdentity**: the trusted client identity (CN + fingerprint) used both for trust selection and for URL-prefix enforcement.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A trusted host can drop a file at `/drop/<cn>/<name>` and read back byte-identical content from the same path.
- **SC-002**: Two trusted hosts `alice` and `bob` each PUT and GET under their own prefixes; alice's attempt to access `/drop/bob/...` returns 403 Forbidden (cross-host isolation verified by a cross-host test). **Updated 2026-08-06 (clarification).**
- **SC-003**: An untrusted client cannot perform any `/drop` operation.
- **SC-004**: A traversal attempt (`..`) is rejected and touches nothing outside the caller's `/drop/<cn>/` box.
- **SC-005**: Listing under `/drop/<cn>/` shows only that host's items; deleting removes only that host's items.
- **SC-006**: The client wrappers perform drop/fetch/list/delete end-to-end over mTLS at the cert-derived hostname prefix.
- **SC-007** *(conditional)*: If directories/copy/move are in scope, a host can create a directory under `/drop/<cn>/`, store a file in it, copy/move within it, and see the structure in a listing.
- **SC-008**: A fetch includes an `ETag` and a last-modified timestamp; a subsequent fetch with `If-None-Match` / `If-Modified-Since` yields "not modified" when the resource is unchanged, and a drop with `If-Match` / `If-Unmodified-Since` against a stale identifier is rejected rather than silently overwriting.
- **SC-009**: A large drop can be fetched in byte ranges (partial content) and resumed after an interruption.
- **SC-010**: A HEAD request returns size, type, ETag, and last-modified identical to a fetch, with no body.
- **SC-011**: A drop with a `Content-Type` returns that type on subsequent fetch/head; `Content-Disposition: attachment` is present on fetch.
- **SC-012**: A Depth-0 PROPFIND returns metadata for a resource without transferring its body.
- **SC-013** *(conditional)*: An empty directory can be removed; a directory containing items cannot (the caller must delete contents first).

## Assumptions

- The drop-box inherits the existing trust gate: only trusted clients (those whose certificate is in the trust store) may use it; there is no separate drop-box auth.
- **The URL is explicit-per-hostname.** Each caller's URL includes their own `<hostname>` as the first path segment. The server enforces that the URL prefix equals the verified CN (FR-002); a mismatch is **403 Forbidden**. **Updated 2026-08-06 (clarification).**
- Drop-box storage lives at `<data-dir>/drop/<cn>/` for each trusted CN, consistent with the project's directory-resolution rules.
- Dropping to an existing name overwrites it (standard PUT semantics), unless a simpler "reject overwrite" rule is chosen at planning time; the choice will be documented.
- We lean on the host server's standard HTTP/WebDAV file handling to stay vanilla. **Complexity checkpoint**: if per-host URL-prefix enforcement proves too complex, the plan MUST stop and propose a simpler fallback (or recommend backtracking) rather than building bespoke machinery, per the user's explicit instruction.
- Full WebDAV (locking, dead properties, recursive PROPFIND depth > 0, DeltaV versioning, ACL, SEARCH) is **out of scope**. In scope are the file methods needed for drop/fetch/list/delete, optional directory creation (MKCOL) and removal (empty only), copy/move (COPY/MOVE), **HEAD**, **entity tags + date conditional requests** on drop/fetch/delete, **byte-range fetches** (`Range`), **Content-Type preservation + Content-Disposition**, and **Depth-0 PROPFIND** — each only insofar as it is simple and standard.
- Client wrappers reuse the same mTLS curl/identity setup already used by the sync callback; hostname-prefix is auto-derived from the cert CN, not type by the user. **Updated 2026-08-06 (clarification).**
- The mod_dav filesystem backend (or an equivalent low-cost server-level implementation) is acceptable as the storage engine where simple and standard; we keep the option open if the bid-price for hand-rolled bash handlers rises too high.

## Risks & Mitigations

- **Risk**: URL-prefix-vs-CN enforcement is bypassable — a misconfigured Apache rewrite passes the wrong `<cn>` through, opening one host's directory to another.
  - **Mitigation**: the prefix-match check sits at the mTLS-edge proxy where SSL_CLIENT_S_DN_CN is read freshly per request and compared to the URL's first segment via a `RewriteMap` program; the localhost backend is bound to 127.0.0.1 only and inherits identity purely from the URL. Verified by a cross-host negative test.
- **Risk**: Path traversal escapes a caller's box.
  - **Mitigation**: FR-006 (rejected escaping paths) and the explicit DocumentRoot + the prefix-enforced rewrite together; verified by a dedicated test.
- **Risk**: One host's large or rapid drops degrade service for others.
  - **Mitigation**: The server's existing request-size and per-request limits apply; documented if a new limit is needed.
- **Risk**: Scope creep into full WebDAV.
  - **Mitigation**: Assumptions pin scope to drop/fetch/list/delete, optional MKCOL/empty-DELETE/COPY/MOVE, HEAD, ETags + conditional requests, byte-range, Content-Type/Disposition, and Depth-0 PROPFIND — explicitly **excluding** locking, dead properties, recursive PROPFIND (Depth 1+), DeltaV versioning, ACL, and SEARCH.
