# Tasks: Per-Host Drop-Box via mod_dav

**Input**: Design documents from `specs/023-per-host-dropbox/`

**Prerequisites**: `plan.md` (mod_dav-first architecture), `spec.md` (explicit-per-hostname URLs), `research.md` (R1–R9 decisions), `data-model.md`, `contracts/`

**Tests**: This feature ships with both BATS unit tests (`tests/trust-check.bats`) and Robot Framework live-Apache tests (`robot/dropbox.robot`). Tests are co-located with the implementation tasks they exercise; the existing project convention is "ship tests in the same commit".

**Organization**: Tasks are grouped by user story so each story is independently implementable and testable. Phases 0–2 are pre-story setup; Phases 3–6 cover user stories (US1–US4 from `spec.md`) in priority order; Phase 7 is polish.

## Format: `[ID] [P?] [Story?] Description with file path`

- **[P]**: parallelizable — different files, no dependency on incomplete tasks
- **[Story]**: which user story from `spec.md` this task belongs to (US1, US2, US3, US4); required for Phase 3–6 only, absent in Phases 0, 1, 2, 7
- Include exact file paths in descriptions

## Path Conventions

This is a single-project extension of an existing web service. Source changes:

- `config/apache-site.conf.in` — Apache config template
- `scripts/` — bash producer scripts (install, package, trust gate)
- `cli/` — NEW: client wrappers (one per HTTP method, plus shared helper)
- `robot/MtlsLibrary.py` — Robot Python keywords
- `tests/` — BATS unit tests
- `robot/` — Robot Framework scenarios
- `justfile` — local task recipes

The Apache document root for the loopback VH is `<data-dir>/drop/`.

---

## Phase 0 — Cleanup (obsolete bash-handler WIP from `f668d12`)

**Purpose**: Remove the bash-handler code from `f668d12` that the mod_dav-first plan explicitly drops in its "Files DELETED" section; reset the sticky working-tree changes; revert `config/apache-site.conf.in`.

- [ ] T001 [P] Delete the bash-handler file group `handlers/drop.{put,get,head,delete,mkcol,copy,move,propfind,options}.sh` (use anchored glob and `scripts/cleanup-common.sh` `remove_file_safe` — never `rm -rf` / `rm -f`; `scripts/cleanup-common.sh` is `source`-able and enforces the safety rule).
- [ ] T002 [P] Delete `scripts/cgi-dropbox.sh` (the 445-line bash helper module — superseded by `scripts/trust-check.sh` plus mod_dav's native behaviour).
- [ ] T003 [P] Delete `tests/dropbox.bats` (the 340-line bats unit-test file for `cgi-dropbox.sh` — superseded by the live-Apache Robot tests in Phase 3).
- [ ] T004 [P] Revert `config/apache-site.conf.in` to its pre-feature state (drop the 9-method-dispatch RewriteRules added at `f668d12`; `git show HEAD:config/apache-site.conf.in` then overwrite the working tree).

**Checkpoint**: `git status` clean of obsolete WIP, was `--`.

---

## Phase 1 — Setup (validated baseline)

**Purpose**: Confirm green baseline before any drop-box work; create the new `cli/` directory.

- [ ] T005 [P] Run `just robot` in `nix-shell` — confirm 5/5 existing robot scenarios pass (baseline, no regression from branch `023-per-host-dropbox`).
- [ ] T006 [P] Run `bats tests/apache.bats tests/smoke.bats tests/sync-state.bats tests/migrate-layout.bats` — confirm all existing bats tests pass (22/22 baseline).
- [ ] T007 [P] Create empty `cli/` directory at repo root with a placeholder `cli/README.md` describing the per-method wrapper family (link to `specs/023-per-host-dropbox/contracts/client-cli.md`).

**Checkpoint**: Baseline green; `cli/` placeholder exists for the wrappers coming in Phase 6.

---

## Phase 2 — Foundational (mod_dav + trust-check + helpers; blocking prerequisites for all user stories)

**Purpose**: Stand up the mod_dav-first storage engine, the trust gate, and the Apache routing. **Every user-story phase depends on this.**

- [ ] T008 [P] In `scripts/install.sh`, after Apache is configured, run `sudo a2enmod dav dav_fs dav_lock proxy proxy_http headers setenvif ssl rewrite setenvif` on Debian/Ubuntu; the standard Arch `apache` package already ships these as loadable — verify they're enabled by checking `httpd -M`; for Nix, ensure the pinned `apacheHttpd` derivation's modules list includes `dav dav_fs dav_lock proxy proxy_http headers setenvif rewrite ssl`.
- [ ] T009 [P] In `scripts/install.sh`, after identity generation and Apache config rendering, add `mkdir -p "${DATA_DIR}/drop"` (idempotent; noop if exists; 0750 mode recommended).
- [ ] T010 Implement `scripts/trust-check.sh` as a `RewriteMap prg:` program. The header documents the prg: contract. Behaviour: read a CN from stdin → look up `<MTLS_TRUST_DIR>/<cn>.crt` → compare its SHA-256 fingerprint against the live `SSL_CLIENT_CERT` env via `openssl x509 -fingerprint -sha256` → print the same CN on match, print `REJECT` and exit 0 on any failure (missing cert, mismatched fingerprint, malformed CN, missing `SSL_CLIENT_CERT`). Reuse the same fingerprint-compare logic already in `scripts/cgi-trust.sh` `is_trusted()`.
- [ ] T011 [P] Implement BATS unit tests `tests/trust-check.bats`: positive fingerprint-match path returns the CN; missing-cert (`<cn>.crt` not in trust dir) returns `REJECT`; fingerprint-mismatch path returns `REJECT`; malformed CN (`..` in CN, contains `;`, >128 chars) returns `REJECT`; missing `SSL_CLIENT_CERT` env returns `REJECT`. Each case uses a temp cert dir with `openssl req -x509 -newkey rsa:2048 -subj "/CN=alice"` (and variants).
- [ ] T012 [P] Rewrite `config/apache-site.conf.in`. Keep the public mTLS `<VirtualHost *:8443>` shape, **but** extend it with: `SSLUserName SSL_CLIENT_S_DN_CN` so `SSL_USER_NAME` env is set; `RewriteEngine On`; `RewriteMap trust_check prg:.../scripts/trust-check.sh .../hosts`; `<Location /drop>` block — for every `/drop/...` request, evaluate `trust_check:${cn-of-url}`; if `REJECT`, return `401` (default); also compare the URL's first segment to `SSL_USER_NAME`; if mismatch, return `403`; on match, `[P]` proxy to `http://127.0.0.1:8444/drop/<cn>/<rest>` with `nocanon`. Also define a new `<VirtualHost 127.0.0.1:8444>` listening only on loopback, with `DocumentRoot = "${DATA_DIR}/drop"` (substituted by `scripts/apache-config.sh` as today), `Dav On`, `<Directory "${DATA_DIR}/drop">` with `Require all granted` + `AllowEncodedSlashes NoDecode` + `Header set Content-Disposition "attachment" env=!IS_DAV_PROPFIND` (via `mod_headers`).
- [ ] T013 [P] Extend `robot/MtlsLibrary.py`:
  - `generate_alternate_identities([(name, cn), ...])` — mints extra self-signed certs with `openssl req -x509 … -subj "/CN=<cn>"`;
  - `trust_identity(name)` — copies a generated cert into `<data-dir>/hosts/<cn>.crt`;
  - `mtls_cert_for(name)` / `mtls_key_for(name)` accessors;
  - `setup_two_identities()` — generates alice + bob and trusts both at `/drop/` (calls the two helpers above);
  - generalise `_curl` to a richer `_curl_full(path, *, method, cert, body_file, extra_headers, fail)` returning `_HttpResponse(status, headers, body, stderr)`; add high-level keywords `mtls_drop`, `mtls_get(headers=...)`, `mtls_head`, `mtls_delete`, `mtls_mkcol`, `mtls_copy(src, dest, overwrite)`, `mtls_move(src, dest, overwrite)`, `mtls_propfind(path, depth)`, `mtls_options(path)`, `mtls_get_etag(path)`, `mtls_get_status(path)`. `mtls_propfind_properties(path, depth)` parses the multistatus into a list of dicts via `xml.etree.ElementTree`.

**Checkpoint**: All existing tests still pass; trust-check.sh + bats are green; the new apache config renders and starts cleanly; `MtlsLibrary.py` loads.

---

## Phase 3 — User Story 1 (P1) — Drop + Retrieve, per-host isolated (MVP)

**Goal**: The defining acceptance scenario. Trusted host `alice` PUTs `notes.txt` to `/drop/alice/notes.txt` and reads it back identically. Trusted host `bob` PUTs `notes.txt` to `/drop/bob/notes.txt` (a different path) and reads back only their own. **Cross-host**: alice's GET to `/drop/bob/...` returns `403 Forbidden` with no leak. **Untrusted**: an untrusted cert returns `401 Unauthorized` from the trust-check.

**Independent Test**: With `MtlsLibrary.setup_two_identities()` providing alice + bob, run a live Apache exercise of the four scenarios above and assert the file contents / status codes.

### Tests for US1

- [ ] T014 [P] [US1] Add Robot scenario in `robot/dropbox.robot` `*** Test Cases ***`: `Drop And Fetch Roundtrip Across Two Hosts` — alice PUTs 32-byte file (first byte `A`) to `/drop/alice/notes.txt`; bob PUTs 32-byte file (first byte `B`) to `/drop/bob/notes.txt`; alice GETs `/drop/alice/notes.txt` and asserts first byte `A`; bob GETs `/drop/bob/notes.txt` and asserts first byte `B`. (Verifies cross-host isolation via mod_dav's per-host namespace.)
- [ ] T015 [P] [US1] Same file: `Cross-Host 403 Isolation` — alice PUTs `/drop/alice/x`; bob PUTs `/drop/bob/x`; alice GETs `/drop/bob/x` via `mtls_get_status()`; assert status `403`.
- [ ] T016 [P] [US1] Same file: `Untrusted Client 401` — generate an `evil` cert CN `evil.test`; do NOT call `trust_identity("evil")`; alice PUTs an evil-cert request to `/drop/evil/anything`; assert status `401`.
- [ ] T017 [P] [US1] Same file: `Path Traversal Rejected` — alice sends GETs/PUTs to `/drop/alice/../../etc/passwd`, `/drop/alice/%2E%2E/passwd`, `/drop/alice/foo/../bar`; each must reject with status `<400` OR canonicalise inside `DocumentRoot` (so the URL resolves under alice's prefix); assert no `<data-dir>/etc/...` exists after the test; assert `/drop/alice/<legitimate-name>` is still readable.

**Checkpoint**: US1 (the MVP) is fully functional and independently testable — drop+get works for one caller, isolation works across two, untrusted is rejected, traversal cannot escape alice's prefix.

---

## Phase 4 — User Story 2 (P2) — List + Delete + PROPFIND + OPTIONS + HEAD

**Goal**: mod_dav serves PROPFIND / HEAD / DELETE / OPTIONS natively; tests confirm correctness of all those methods and that conditional requests (`If-Match`, `If-None-Match`) work end-to-end via the proxy edge.

**Independent Test**: After US1 setup, alice PROPFINDs her box and sees her items; alice DELETEs a file with `If-Match`; alice DELETEs an empty directory; alice hits OPTIONS.

### Tests for US2

- [ ] T018 [P] [US2] Add Robot scenario: `List via PROPFIND` — alice drops three files (`notes.txt`, `archive/x`, `archive/y`); alice `mtls_propfind_properties("/drop/alice", depth=1)` returns exactly three entries with non-null sizes; format no longer raw XML.
- [ ] T019 [P] [US2] Add Robot scenario: `HEAD no body` — alice drops `notes.txt`; alice `mtls_head(/drop/alice/notes.txt)`; assert `ETag`, `Last-Modified`, `Content-Type`, `Content-Length`, `Allow` are present; assert body is empty (assert `body == b""`).
- [ ] T020 [P] [US2] Add Robot scenario: `Conditional DELETE` — alice drops `notes.txt`; alice drops an updated `notes.txt` (bumps ETag); alice DELETEs with stale `If-Match: "<old-etag>"` → `412 Precondition Failed`; alice DELETEs without `If-Match` → `204 No Content`; subsequent read returns `404`.
- [ ] T021 [P] [US2] Add Robot scenario: `Empty-Dir DELETE works; non-empty returns 409` — alice MKCOLs `/drop/alice/empty/`; alice DELETEs `/drop/alice/empty/` → `204`. Then alice MKCOLs `/drop/alice/nonempty/`, PUTs `/drop/alice/nonempty/x`, alice DELETE `/drop/alice/nonempty/` → `409 Conflict`.

**Checkpoint**: US2 is fully functional — listing, conditional delete, empty/non-empty-dir delete, HEAD all work end-to-end.

---

## Phase 5 — User Story 3 (P3, conditional) — Directories + Copy + Move

**Goal**: mod_dav handles MKCOL / COPY / MOVE natively. Tests verify that they round-trip without leaving stale state, including copy/move destination-overwrite semantics.

**Independent Test**: alice MKCOL `archive/`, drop a file inside, COPY, MOVE, list — assert resulting layout.

### Tests for US3

- [ ] T022 [P] [US3] Add Robot scenario: `MKCOL + COPY + MOVE` — alice MKCOLs `/drop/alice/archive/`; alice PUTs 32-byte `/drop/alice/archive/x.bin`; alice COPYs `/drop/alice/archive/x.bin` → `/drop/alice/archive/x.copy.bin`; alice MOVEs `/drop/alice/archive/x.bin` → `/drop/alice/archive/x.moved.bin`. Alice PROPFINDs `/drop/alice/archive/` and asserts list contains exactly `x.copy.bin` and `x.moved.bin` (not `x.bin`).
- [ ] T023 [P] [US3] Add Robot scenario: `PROPFIND Depth 1` and `PROPFIND Depth 0` — alice drops three files; PROPFIND `/drop/alice/` with `Depth: 1` returns three `<response>` entries in the multistatus; PROPFIND a single file `/drop/alice/notes.txt` with `Depth: 0` returns exactly one `<response>`.
- [ ] T024 [P] [US3] Add Robot scenario: `COPY/MOVE Without Overwrite refused` — alice PUTs source and a destination; tries COPY without `Overwrite: T` → expect `412`; then with `Overwrite: T` → expect `201`.

**Checkpoint**: US3 (P3 paths) is functional; directory + copy + move + empty-dir DELETE all work end-to-end.

---

## Phase 6 — User Story 4 (P1) — Client wrappers

**Goal**: 9 small bash CLI wrappers under `cli/`, one per HTTP method, plus a shared helper. Each wrapper uses `curl` with mTLS (matching the existing `scripts/on-discover.sh` pattern) and derives `/drop/<cn>/<rest>` from the wrapper's own `--cert` file via `openssl x509 -subject -nameopt RFC2253`. Argument parsing, env-var fallback, exit codes, human-readable output.

**Independent Test**: For each `cli/mtls-*.sh`, invoke it against the live Apache and assert the corresponding side-effect.

### Implementation for US4

- [ ] T025 [P] [US4] Implement `cli/_common-cname.sh` — a shared bash helper. Given `--cert <F>` (or fallback `MTLS_CLIENT_CERT`), runs `openssl x509 -in "$cert" -noout -subject -nameopt RFC2253` and prints the CN (sanitized to `[A-Za-z0-9._-]+`, ≤128 chars). Falls back to env. Refuses (exit `2`) on failure with a clear stderr message. Sourceable.
- [ ] T026 [P] [US4] Implement `cli/mtls-drop.sh` (PUT) — args `--source`, `--name`, `--content-type`, `--etag`, `--if-none-match`, `--server`, `--cert`, `--key`, `--cacert`; sources `_common-cname.sh`, derives CN, builds `/drop/<cn>/<name>`; `curl --fail-with-body --cert ... --key ... --cacert ... -X PUT -T <local>`; emits `(201 created <name>)` / `(204 overwritten <name>)` / `(412 precondition failed)`. Default content-type via `file --mime-type`.
- [ ] T027 [P] [US4] Implement `cli/mtls-fetch.sh` (GET) — `--name`, `--out`, `--range <A-B>`, `--if-none-match <etag>`, `--server`, `--cert`, `--key`, `--cacert`. `curl -X GET --cert ... --cacert ... -D /tmp/h.XX -o <out>` with `Range:`/`If-None-Match:` headers passed via `--header`. Parse Status/ETag/Content-Range response. Emit `(200 ok <size> <etag> <lastmod>)` / `(304 not modified)` / `(206 partial <a-b>/<size>)` / `(416 range not satisfiable)`. Exit codes: 0 / 4 / 1 / 4.
- [ ] T028 [P] [US4] Implement `cli/mtls-head.sh` — `--name`, `--server`, `--cert`, `--key`, `--cacert`. `curl --cert ... --cacert ... -I`. Print `Status:`, `ETag:`, `Last-Modified:`, `Content-Type:`, `Content-Length:`, `Allow:` lines on stdout.
- [ ] T029 [P] [US4] Implement `cli/mtls-del.sh` (DELETE) — `--name`, `--etag`, `--server`, `--cert`, `--key`, `--cacert`. DELETE with optional `If-Match:`. Emit `(deleted <name>)` / `(precondition failed 412)` / `(skipped, conflict 409)`.
- [ ] T030 [P] [US4] Implement `cli/mtls-ls.sh` — `--dir` (default: box root), `--server`, `--cert`, `--key`, `--cacert`. PROPFIND `Depth: 1`. Format each child as `<name>\t<size>\t<content-type>\t<etag>\t<lastmod>`. Use `xmllint --xpath` if available, fall back to a 20-line awk-based parser. Exit `4` on non-2xx.
- [ ] T031 [P] [US4] Implement `cli/mtls-props.sh` — `--name`, `--server`, `--cert`, `--key`, `--cacert`. PROPFIND `Depth: 0`. Format `<prop> = <value>` lines (`resourcetype`, `getcontentlength`, `getcontenttype`, `getlastmodified`, `getetag`).
- [ ] T032 [P] [US4] Implement `cli/mtls-mkcol.sh` (MKCOL) — `--dir`, `--server`, `--cert`, `--key`, `--cacert`. MKCOL. Emit `(201 created dir/<dir>)` / `(409 conflict)`.
- [ ] T033 [P] [US4] Implement `cli/mtls-cp.sh` (COPY) — `--source`, `--dest`, `--overwrite`, `--server`, `--cert`, `--key`, `--cacert`. COPY with `Destination: /drop/<cn>/<dest>`; `Overwrite: T` only if `--overwrite` is given. Emit `(201 copied <src> -> <dest>)` or `(412 precondition failed)`.
- [ ] T034 [P] [US4] Implement `cli/mtls-mv.sh` (MOVE) — same flags as cp. MOVE with `Destination:` header.

### Tests for US4

- [ ] T035 [US4] Add Robot scenario in `robot/dropbox.robot`: `Client Wrapper Roundtrip` — exercise each `cli/mtls-drop`, `cli/mtls-fetch`, `cli/mtls-head`, `cli/mtls-del`, `cli/mtls-ls`, `cli/mtls-props`, `cli/mtls-mkcol`, `cli/mtls-cp`, `cli/mtls-mv` against the live Apache; assert the side-effects (file present, listing line count, copy/move target present, etc.). Logged as 9 distinct sub-tests on one scenario.

**Checkpoint**: US4 is fully functional. The feature is shippable end-to-end.

---

## Phase 7 — Polish & Cross-Cutting Concerns

- [ ] T036 [P] Update `README.md`: add a "Per-Host Drop-Box" section listing the 9 cli wrappers, the URL pattern `/drop/<cn>/<rest>`, the trust gate behaviour (401 vs 403), and the Range / conditional / PROPFIND semantics; update the "Directory Layout" section with the new `drop/` entry; document the mod_dav backend.
- [ ] T037 [P] Update `justfile`: add `robot-dropbox` (runs `robot/dropbox.robot` only) and `test-dropbox` (runs `bats tests/trust-check.bats` and the new drop-box robot); include the new tests in the `test` aggregate.
- [ ] T038 [P] Update `scripts/install-service.sh`: ensure the systemd unit's `Environment=` reaches the new loopback VH (no behavioural change for the public VH).
- [ ] T039 [P] Update `scripts/package-common.sh`, `scripts/package-debian.sh`, `scripts/package-arch.sh`: stage `cli/_common-cname.sh` and all `cli/mtls-*.sh` into the `mtls-hello/cli/` directory in the package tree before `stage_install_tree` runs, so the packaged install ships them with `.deb`/`.pkg.tar.zst`. Ensure `<MTLS_DATA_DIR>/drop` is `mkdir -p`-ed in postinst.
- [ ] T040 [P] Update `docker/Dockerfile.debian`, `docker/Dockerfile.arch`, `docker/Dockerfile.test`, `docker/docker-build.sh`: install `libapache2-mod-dav dav_fs dav_lock` and `apache2-utils` (Debian); pin `mod_dav` modules in Nix shell derivation. Verify `apache -M | grep -E 'dav.*|proxy_http'` succeeds in the test container.
- [ ] T041 [P] Run `shellcheck --severity=warning` on `scripts/trust-check.sh`, `cli/_common-cname.sh`, every `cli/mtls-*.sh`. Address any hits. Note: the wrappers use `set -euo pipefail`; shellcheck is strict about `$()` exit propagation.
- [ ] T042 [P] Run `grep -RnE "rm -rf|rm -f|find .* -delete" cli/ scripts/trust-check.sh` — confirm zero hits. Per the project's safety rule from feature 022.
- [ ] T043 [P] Run full green-check: `just test-d` (D unit tests — no new D modules added; should still pass unchanged), `just robot` (extended Robot suite incl. drop-box), `bats tests/trust-check.bats tests/apache.bats tests/smoke.bats tests/sync-state.bats tests/migrate-layout.bats`.
- [ ] T044 [P] Update `specs/023-per-host-dropbox/tasks.md` marking `[X]` on tasks as they land (this task occasionally).

**Checkpoint**: feature is fully integrated: shippable install, packages, README, tests, no shellcheck regressions, no rm-safety regressions.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 0 (Cleanup)**: no dependencies — can start immediately. Required before Phase 1 verifies baseline.
- **Phase 1 (Setup)**: depends on Phase 0 completion.
- **Phase 2 (Foundational)**: depends on Phase 1; **BLOCKS** every user-story phase.
- **Phase 3 (US1, P1, MVP)**: depends on Phase 2; the earliest stop-and-validate point.
- **Phase 4 (US2, P2)**: depends on Phase 2. Independent of US3, US4. Reuses US1 helpers (alice + bob) for setup.
- **Phase 5 (US3, P3)**: depends on Phase 2 + Phase 4 (reuses US2 helpers `mtls_mkcol`, `mtls_copy`, `mtls_move`). Independent of US4.
- **Phase 6 (US4, P1)**: depends on Phase 2 + US1 (handlers tested by US1 exercises the same `/drop/<cn>/<rest>` URL shape the wrappers build).
- **Phase 7 (Polish)**: depends on Phases 0–6.

### Within-Phase Dependencies

- `T008` (enable mod_dav) is independent.
- `T009` (mkdir drop/) is independent.
- `T010` (trust-check.sh) is independent.
- `T011` (bats for trust-check) depends on `T010`.
- `T012` (rewritten Apache config) consumes `T008` (modules available), `T009` (DocumentRoot exists), `T010` (RewriteMap program exists). Sequential.
- `T013` (MtlsLibrary.py extensions) is independent of T010/T012 — keywords built against the method handlers, not the trust logic.
- Within US4: `T025` (`_common-cname.sh`) is required by T026–T034. T026–T034 are otherwise independent.

### User Story Dependencies (the matrix)

| ↑ Dep / → Phase | US1 | US2 | US3 | US4 |
|---|---|---|---|---|
| Phase 0 | ✓ | ✓ | ✓ | ✓ |
| Phase 1 | ✓ | ✓ | ✓ | ✓ |
| Phase 2 | ✓ | ✓ | ✓ | ✓ |
| US1 (P1)       | —  | (no dep) | (no dep) | (uses `mtls_*` keywords redefined in T013, not US1-specific) |
| US2 (P2)       |     | —          | (no dep) | (no dep) |
| US3 (P3)       |     |            | —          | (no dep) |
| US4 (P1)       |     |            |            | —          |

US1 does not depend on US2/US3/US4. US2 uses Phase 2 helpers (MtlsLibrary keywords); it does not depend on US1's tests passing. US3 inherits US2's pytest-style flow. US4 is independent of US2/US3 (wrappers cover the full HTTP method set, and Phase 2 already covers PROPFIND/OPTIONS/MKCOL/COPY/MOVE in mod_dav).

### Within Each User Story

- Tests come before integration validates the Apache config end-to-end.
- mod_dav is the implementation: "implement" tasks in US1–US3 are mostly *test tasks* that verify the live Apache config from Phase 2 produces the expected behaviour (because there are no custom bash CGI handlers to write).
- US4 is the only story with substantial *implementation* tasks (the 9 wrappers + shared helper).

---

## Parallel Opportunities

- **Phase 0**: T001, T002, T003, T004 are all independent — all `[P]`.
- **Phase 1**: T005, T006, T007 are all `[P]`.
- **Phase 2**: T008, T009 are `[P]`. T011, T012, T013 are `[P]` after T010 lands. T010 must precede T011, T012 because they all reference it.
- **Phase 3 [US1]**: T014, T015, T016, T017 are `[P]` — independent Robot scenarios, different URLs.
- **Phase 4 [US2]**: T018, T019, T020, T021 are `[P]`.
- **Phase 5 [US3]**: T022, T023, T024 are `[P]`.
- **Phase 6 [US4]**: T026–T034 are `[P]` (9 wrappers — different files, no inter-dependency after `_common-cname.sh` lands). T025 is sequential (the shared helper). T035 is sequential after the wrappers.
- **Phase 7**: T036–T043 are `[P]`. T044 is sequential (it's the "tick the box on login" prettifier).

### Parallel Team Strategy

With multiple developers:

1. Team completes Phase 0 + Phase 1 together.
2. Once Phase 1 lands, Phase 2 splits: dev A on Apache config (T012), dev B on trust-check.sh (T010), dev C on MtlsLibrary.py (T013).
3. Once Phase 2 lands:
   - dev A: US1 (`T014–T017`) — Robot scenarios for the proxy+mod_dav loop.
   - dev B: US2 (`T018–T021`) — Robot scenarios for listing/conditional/empty-dir DELETE.
   - dev C: US3 (`T022–T024`) — Robot scenarios for MKCOL/COPY/MOVE/PROPFIND depth.
   - dev D: US4 (`T025–T035`) — 9 wrappers + shared helper + their Robot roundtrip.
4. Phase 7 polish is everyone's responsibility — file-isolated tasks can split.

---

## Implementation Strategy

### MVP First (US1 only)

1. Phase 0 (cleanup) → working tree clean.
2. Phase 1 (baseline + cli/ skeleton) → existing tests still green; `cli/` exists.
3. Phase 2 (mod_dav + trust-check + Apache config + helpers) → live Apache serves `/drop/<cn>/<rest>` for trusted callers; cross-host returns 403; untrusted returns 401.
4. Phase 3 [US1] (Robot scenarios) → drop+fetch+isolation+untrusted+traversal all green.
5. **STOP and VALIDATE**: this is the smallest shippable unit. Everything in `quickstart.md` "drop a file" and "verify per-host isolation" works here.
6. Optionally deploy or demo this MVP before continuing.

### Incremental Delivery

1. Phases 0–2 → foundation.
2. US1 (P1) → drop + fetch + 401/403 isolation. **MVP**.
3. US4 (P1) → 9 client wrappers; the operator can now use the feature from terminal (every primitive exposed).
4. US2 (P2) → PROPFIND listing, conditional delete, empty/non-empty-dir delete. The feature is feature-complete.
5. US3 (P3) → MKCOL/COPY/MOVE; directory organization is available. Feature is fully shipped.
6. Phase 7 → README/justfile/install-service/package/Dockerfile polish. feature is ready to ship.

### Test-First discipline

For each user story, write the Robot `*** Test Cases ***` block first (against the live Apache config from Phase 2), watch it fail (the test infrastructure catches the failure cleanly), then write any tweaks that are needed. Most stories in this plan *are* test-first by construction because the implementation is already in place (mod_dav) — the work is verifying the live Apache config has the expected behaviour.

For US4, the wrappers come with their `cli/_common-cname.sh` helper first, then each wrapper individually, then their Robot roundtrip test.

---

## Notes

- `[P]` tasks = different files, no dependencies.
- `[Story]` label maps the task to its user story for traceability.
- Each user story is independently completable and testable.
- Tests (BATS + Robot) ship alongside implementation in this project's actual pattern — strict TDD is *not* enforced, so testability tasks may execute in parallel with the impl tasks they exercise, but each user-story phase still requires both impl AND tests before the checkpoint.
- Commit after each task or logical group.
- Stop at any checkpoint to validate the story independently.
- The **safety rule** (per feature 022): never introduce `rm -rf` / `rm -f` / `find .* -delete` in new code; use anchored globs and bottom-up `rmdir`. The new wrappers in US4 and `scripts/trust-check.sh` use `rm -- <file>` (in cleanup paths only — most wrapper scripts produce files, never delete).
- The new `cli/` directory's permission on disk is 755 (executable wrappers). The wrappers use `set -euo pipefail`. They reference `cli/_common-cname.sh` via relative path so the install layout (which copies them into `<data-dir>/cli/`) keeps the helper colocated.
- At the loopback VH, `DocumentRoot = <data-dir>/drop/` identifies the storage root explicitly. mod_dav will refuse to serve anything outside that root by construction — this is the **FR-006 path-traversal** enforcement.
- The `DocumentRoot` substitution depends on `scripts/apache-config.sh` continuing to substitute `${DATA_DIR}` cleanly. We do not need to change `scripts/apache-config.sh` for feature 023; only the `.conf.in` template.

---

## Summary

| # | Phase | Tasks | Type |
|---|---|---|---|
| 0 | Cleanup | T001–T004 | non-story, mostly deletion |
| 1 | Setup | T005–T007 | non-story, baseline + cli/ skeleton |
| 2 | Foundational | T008–T013 | non-story, Apache config + trust-check + library |
| 3 | US1 (P1) | T014–T017 | story, all `[P]` |
| 4 | US2 (P2) | T018–T021 | story, all `[P]` |
| 5 | US3 (P3) | T022–T024 | story, all `[P]` |
| 6 | US4 (P1) | T025–T035 | story, 9 wrapper impls `[P]` + 1 robot |
| 7 | Polish | T036–T044 | non-story, all `[P]` except T044 |
| **Total** | | **44 tasks** | |

**Independent test criteria** (per story, concrete):

- **US1**: `robot/dropbox.robot` → "Drop And Fetch Roundtrip Across Two Hosts" + "Cross-Host 403 Isolation" + "Untrusted Client 401" + "Path Traversal Rejected" all green.
- **US2**: `robot/dropbox.robot` → "List via PROPFIND" + "HEAD no body" + "Conditional DELETE" + "Empty-Dir / Non-Empty DELETE" all green.
- **US3**: `robot/dropbox.robot` → "MKCOL + COPY + MOVE" + "PROPFIND Depth 1/0" + "COPY/MOVE Without Overwrite refused" all green.
- **US4**: `cli/mtls-*` roundtrip: each wrapper's invocation against the live Apache produces the matching observable effect.

**Suggested MVP scope**: US1 (Phase 0 + Phase 1 + Phase 2 + Phase 3 ⇒ drop+fetch + isolation against the live Apache config, no client wrappers yet). Validation: `robot/dropbox.robot` runs all 4 US1 scenarios green; `just test-d`, `just robot` non-dropbox tests, `bats tests/apache.bats tests/smoke.bats tests/sync-state.bats tests/migrate-layout.bats` all still green.
