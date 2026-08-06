# Implementation Plan: Cert Capture via Logging Pipeline

**Branch**: `021-cert-capture-via-log` | **Date**: 2026-08-06 | **Spec**: spec.md

**Input**: Feature specification from `specs/021-cert-capture-via-log/spec.md`

## Summary

Replace the per-CGI-handler certificate capture (`cgi-capture.sh` sourced and
called in every handler) with a single piped Apache `CustomLog` that captures
every presented client certificate into purgatory. An experiment confirmed
`%{SSL_CLIENT_CERT}e` reaches the piped logger as one line per request with the
PEM's newlines escaped as literal `\n`. The capture script unescapes the PEM,
dedups by `<hostname>.<fingerprint>.crt`, and skips already-trusted certs.

## Technical Context

**Language/Version**: Bash 4+, Apache httpd 2.4 (`mod_ssl`, `mod_log_config`), `openssl`

**Primary Dependencies**: Apache httpd, `mod_log_config` piped logs, `openssl x509`, existing `scripts/cgi-trust.sh` trust rules

**Storage**: Purgatory directory (existing); no new persistent stores

**Testing**: Robot Framework (Apache end-to-end), BATS where useful

**Target Platform**: Linux (Debian/Arch/SUSE), Nix dev shell

**Project Type**: mTLS daemon + Apache CGI backend

**Performance Goals**: Capture is post-response and non-blocking; per-request overhead is one small file write at most

**Constraints**: No CA infrastructure (self-signed certs); capture must never block or break serving; existing trust/promotion tooling and purgatory naming unchanged

**Scale/Scope**: One piped logger process per Apache instance; one capture per distinct untrusted cert

## Constitution Check

The project constitution is a template with no active gates. Principles observed:

1. **No system-wide changes**: the piped logger lives under the data-dir scripts directory; config is generated into the data dir.
2. **No hardcoded defaults**: paths are templated from `DATA_DIR`/`TRUST_DIR`/`PURGATORY_DIR` as today.
3. **Maintainable code**: capture logic centralized in one shellcheck-clean script; handlers shrink.
4. **No CA / self-signed certs**: unchanged; the design exploits `optional_no_ca` + `+ExportCertData`, no CA introduced.
5. **Separation of concerns**: Apache handles capture via its logging pipeline; handlers handle serving + trust.

No gate violations. (US4 connection-level rejection is dropped per research §4 — it is infeasible under the no-CA constraint.)

## Project Structure

### Documentation (this feature)

```text
specs/021-cert-capture-via-log/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/capture.md
└── tasks.md            # /speckit.tasks
```

### Source Code (repository root)

```text
config/apache-site.conf.in   # add LogFormat + piped CustomLog
scripts/apache-config.sh     # pass trust/purgatory dirs into the piped command
scripts/log-capture.sh       # NEW: piped-log capture script
scripts/cgi-capture.sh       # REMOVED after handlers are updated
scripts/install.sh           # install log-capture.sh
handlers/*.sh                # drop source cgi-capture.sh + capture_client_cert
robot/mtls_hello.robot       # existing capture tests must still pass
```

**Structure Decision**: A single new script (`scripts/log-capture.sh`) plus a
two-line Apache config change. Handlers are simplified by *removing* code.

## Research (Phase 0)

See `specs/021-cert-capture-via-log/research.md`.

### Key decisions

- **D001**: piped-log capture is the mechanism (experimentally confirmed).
- **D002**: log format = `SSL_CLIENT_S_DN`, `SSL_CLIENT_VERIFY`, `SSL_CLIENT_CERT`, `CERTEND`, tab-separated.
- **D003**: the script filters on project trust state (computes fingerprint, checks trust dir); trusted certs are a no-op, untrusted are written to purgatory — satisfying "log a cert that fails the trust".
- **D004**: US4 connection-level rejection is dropped (infeasible: post-response logger + no-CA/self-signed). Handler-level 401 remains; spec US4/FR-008/SC-006 to be re-scoped to "untrusted clients are never served; certs still recorded".
- **D005**: remove `cgi-capture.sh` from handlers; delete the file.

## Design (Phase 1)

See `data-model.md`, `contracts/capture.md`, `quickstart.md`.

### Implementation details

1. **`scripts/log-capture.sh`** (new)
   - Reads stdin line by line; splits on tab into 4 fields.
   - Skips empty cert; else unescapes `\n`, computes SHA-256 fingerprint, derives hostname from `CN=`.
   - If trusted (per existing trust rules) → no-op; else writes `<purgatory>/<hostname>.<fingerprint>.crt`.
   - `set -euo pipefail` scoped so one bad line never kills the logger; logs warnings to stderr.

2. **Apache config**
   - `config/apache-site.conf.in`: add `LogFormat ... mtls_cert_fmt` and `CustomLog "|{{...}}/log-capture.sh {{TRUST_DIR}} {{PURGATORY_DIR}}" mtls_cert_fmt`.
   - `scripts/apache-config.sh`: ensure the piped command uses absolute installed paths (the handlers-dir / scripts-dir under the data dir).

3. **Handlers**
   - Remove `source .../cgi-capture.sh` and `capture_client_cert` from `hello.get.sh`, `head.get.sh`, `spool.get.sh`, `bundle.post.sh`, `cert-echo.get.sh`.
   - Keep `cgi-trust.sh` sourcing and the trust gate.

4. **Install**
   - `scripts/install.sh`: copy `log-capture.sh` to the data-dir scripts directory; stop copying `cgi-capture.sh` (or leave it harmlessly; remove for cleanliness).

5. **US4 re-scope (feasible portion)**
   - Ensure all endpoints reject untrusted clients (handler-level 401). This is largely already true; verify `hello.get.sh`/`cert-echo.get.sh` and harden if any endpoint serves untrusted clients.

### Edge cases

- No client cert → empty field → skip.
- Already trusted → no-op (no purgatory pollution).
- Concurrent identical certs → filename dedup.
- Logger crash → Apache restarts it; serving unaffected.
- Bad/malformed line → warn + continue.

### Tests

- Existing Robot cases "Capture Untrusted Cert In Purgatory" and "Promote Captured Cert And Trust" must pass unchanged.
- Add a Robot/BATS case: a request to an endpoint whose handler has no capture code still results in a purgatory file.
- Add a check that a *trusted* client produces no new purgatory file.

## Complexity Tracking

No constitution violations. Net code change is a small script plus config lines and *removal* of duplicated handler code.

## Risks & Mitigations

- **Risk**: PEM unescaping corrupts data.
  - **Mitigation**: PEM body is base64 (no backslash); only `\n` appears; round-trip verified.
- **Risk**: Piped logger path differs between dev (repo) and installed layout.
  - **Mitigation**: config generator emits absolute installed paths; install copies the script.
- **Risk**: A handler still relies on `capture_client_cert` after refactor.
  - **Mitigation**: grep the tree; delete `cgi-capture.sh` once clean; tests assert capture still happens without handler code.

## Research Links

- `specs/021-cert-capture-via-log/research.md`
- `specs/021-cert-capture-via-log/data-model.md`
- `specs/021-cert-capture-via-log/contracts/capture.md`
- `specs/021-cert-capture-via-log/quickstart.md`
