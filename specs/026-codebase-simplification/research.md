# Research: Codebase Simplification

**Date**: 2026-08-07
**Feature**: 026-codebase-simplification

## Methodology

Systematic grep-based audit of the codebase for: (1) duplicated logic across files,
(2) dead/orphaned code, (3) inconsistent patterns for the same concern, and
(4) files with multiple responsibilities that could be split or merged.

## Findings

### R1: CGI library split into two files that nearly everyone sources together

**Observation**: `cgi-common.sh` (145L) and `cgi-trust.sh` (152L) are sourced
together by 6 of 7 handlers. Only `cert-echo.get.sh` sources `cgi-trust.sh`
alone. The on-discovery.d scripts source one or neither.

**Functions in cgi-common.sh**: `cgi_parse_query`, `cgi_header`, `cgi_error`,
`data_dir_resolve`, `nncp_hjson_set_neigh`.

**Functions in cgi-trust.sh**: `cgi_client_hostname`, `cgi_client_fingerprint`,
`is_trusted`, `peer_extract`, `peer_extract_stage`.

**Decision**: Merge into a single `cgi-lib.sh`. Handlers source one file.
The cert-echo handler that only needs trust functions pays a negligible cost
for also loading header/query helpers (~30 extra lines of function definitions
that bash doesn't execute unless called).

**Savings**: ~50 lines from removing duplicate `set -euo pipefail` blocks, file
headers, and the double-source boilerplate in each handler.

---

### R2: CN extraction duplicated in 4+ places with different sed patterns

**Observation**: Extracting the Common Name from an X.509 cert is reimplemented
independently:

| Location | Pattern |
|----------|---------|
| `cgi-trust.sh:14` | `openssl x509 -noout -subject -nameopt RFC2253 \| sed -n 's/^subject=.*CN=\([^,+\/]*\).*/\1/p'` |
| `trust-host.sh:22` | `openssl x509 -noout -subject \| sed -n 's/.*CN\s*=\s*\([^,]*\).*/\1/p'` |
| `sync-common.sh:40` | `openssl x509 -in "$f" -noout -subject \| …` (similar but different) |
| `log-capture.sh:30` | `openssl x509 -noout -subject -nameopt RFC2253 \| sed -n 's/^subject=.*CN=\([^,+\/]*\).*/\1/p'` |

The RFC2253 `-nameopt` variant (cgi-trust + log-capture) is the most robust.
The others use different regex that may break on certs with unusual DN ordering.

**Decision**: Single `extract_cn()` function in `cgi-lib.sh` using the RFC2253
pattern. All four callers source or call this function.

**Savings**: ~20 lines; also fixes a latent inconsistency bug.

---

### R3: DATA_DIR resolution has 5+ different patterns, two with bugs

**Observation**:

| Pattern | Where | Bug? |
|---------|-------|------|
| `DATA_DIR="$1"` (positional) | apache-config.sh, apache-port-helper.sh | No |
| `DATA_DIR="${DATA_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"` | _run-parts, 20-nncp | No |
| `DATA_DIR="${DATA_DIR:-$(cd "$(dirname …)/../../.." && pwd)}"` | 00-validate, 10-trust-add (fixed) | Was `}` trailing |
| `DATA_DIR="${DATA_DIR:-$(dirname …)}/../../../..}"` | **90-log.sh** | **YES: trailing `}`** |
| `DATA_DIR="${MTLS_DATA_DIR:-}"` + fallback | nncp-receive | No |

**90-log.sh still has the bug** I fixed in 10-trust-add.sh earlier today.

**Decision**: A single `resolve_data_dir()` function in `cgi-lib.sh` that all
on-discovery.d scripts call. Fixes 90-log.sh as a side effect.

---

### R4: Handler boilerplate (cert check + trust check) repeated in every handler

**Observation**: Every handler starts with:

```bash
cert="${SSL_CLIENT_CERT:-}"
if [ -z "$cert" ]; then
    cgi_error "401 Unauthorized" "No client certificate presented"
fi
if ! is_trusted; then
    cgi_error "401 Unauthorized" "Untrusted"
fi
```

This 6-line block appears in hello, head, bundle, spool, drop-proxy, nncp-receive.

**Decision**: Extract to `cgi_require_trusted()` in `cgi-lib.sh`. Each handler
replaces 6 lines with 1.

**Savings**: ~35 lines across handlers; also ensures the trust gate is
consistent (the spec's FR-002 "externally observable behavior must not change"
is easier to enforce when the gate lives in one place).

---

### R5: `docker-discovery-test.sh` is dead code

**Observation**: `scripts/docker-discovery-test.sh` (88L) is never sourced,
called, or referenced by any other file in the tree (verified by grep across
all `.sh`, `.d`, `.yml`, `.in`, `.conf` files). It was a one-off Docker-based
discovery test from an early feature.

**Decision**: Remove the file.

---

### R6: `sync-test.sh` has only `cleanup_tmpdir()` and is sourced only by `sync-common.sh`

**Observation**: `sync-test.sh` (109L) defines only `cleanup_tmpdir()`. It is
sourced exclusively by `sync-common.sh`. The "test" in the name is misleading
— it's a cleanup helper, not a test file.

**Decision**: Merge `cleanup_tmpdir()` into `sync-common.sh` (or its successor
`sync-lib.sh`). Remove `sync-test.sh`.

---

### R7: `sync-common.sh` + `sync-state.sh` serve complementary roles

**Observation**: `sync-common.sh` (89L) has curl helpers (`mtls_curl`,
`mtls_curl_post`, `ensure_peer_host`, `apply_bundle_to_repo`,
`query_spool_coverage`). `sync-state.sh` (104L) has the per-peer refs-hash
cache (`sync_state_base`, `sync_state_dir`, `compute_refs_hash`,
`get_synced_hash`, `set_synced_hash`, `clear_synced_hash`). Both are sourced by
`50-bundle-push.sh`.

**Decision**: Merge into `sync-lib.sh`. One file for all sync concerns.

**Savings**: ~40 lines from eliminating duplicate headers and the double-source
boilerplate.

---

### R8: `cert-echo.get.sh` doesn't use `cgi_header()` / `cgi_error()` from the library

**Observation**: `cert-echo.get.sh` emits headers inline (`echo "Status: …"`,
`echo "Content-Type: …"`) instead of calling `cgi_header()` / `cgi_error()`.
Same pattern in parts of `drop-proxy.sh`.

**Decision**: Switch to library calls during the cgi-lib.sh merge.

---

### R9: D code is already lean

**Observation**: The D daemon (app.d 233L + multicast.d 366L + trust.d 289L =
898L total) has clear single responsibilities. `trust.d` handles outbound
cert capture (separate from Apache's inbound `log-capture.sh`). No dead
imports or functions found. The architecture is already split correctly
between D (discovery + capture) and Apache (HTTP serving).

**Decision**: No D code changes needed.

---

### R10: `smoke.bats` is 1,814 lines / 58 tests with repeated setup

**Observation**: The largest test file has accumulated tests from features
001–012+. `LD_LIBRARY_PATH=""` appears in 22 places. Many tests repeat the same
sandbox-creation and cert-generation boilerplate.

**Decision**: Extract a `tests/helpers.bash` with shared setup/teardown and
cert-generation helpers. This is lower priority than the script consolidation
(P1) but contributes to SC-001 (line reduction).

**Risk**: Test refactoring is delicate. Only do this AFTER the script
consolidation is validated green. Keep test changes as a separate commit.

---

### R11: CLI wrappers are already well-factored

**Observation**: All 9 CLI wrappers (`mtls-cp`, `mtls-del`, `mtls-drop`,
`mtls-fetch`, `mtls-head`, `mtls-ls`, `mtls-mkcol`, `mtls-mv`, `mtls-props`)
source `_common-cname.sh` (116L) for shared CN extraction, curl wrapping, and
argument parsing. Each wrapper is 24–44 lines of verb-specific logic.

**Decision**: No consolidation needed. The wrappers are already DRY.

## Summary of Actions

| ID | Action | Type | Priority |
|----|--------|------|----------|
| R1 | Merge cgi-common.sh + cgi-trust.sh → cgi-lib.sh | Consolidate | P1 |
| R2 | Single `extract_cn()` function | Consolidate | P1 |
| R3 | Single `resolve_data_dir()` function; fix 90-log.sh bug | Consolidate + Fix | P1 |
| R4 | `cgi_require_trusted()` helper | Consolidate | P1 |
| R5 | Remove docker-discovery-test.sh | Dead code | P1 |
| R6 | Merge sync-test.sh → sync-lib.sh | Consolidate | P2 |
| R7 | Merge sync-common.sh + sync-state.sh → sync-lib.sh | Consolidate | P2 |
| R8 | Switch cert-echo/drop-proxy to library calls | Consistency | P2 |
| R9 | (no D changes) | N/A | — |
| R10 | Extract tests/helpers.bash | Test cleanup | P3 |
| R11 | (no CLI changes) | N/A | — |
