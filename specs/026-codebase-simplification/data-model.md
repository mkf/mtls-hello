# Data Model: Codebase Simplification

**Date**: 2026-08-07
**Feature**: 026-codebase-simplification

This feature has no runtime data entities — it is a codebase refactoring.
The "data model" is the file structure before and after.

## Before (Current State)

### Shell Libraries (sourced by multiple consumers)

| File | Lines | Functions | Sourced by |
|------|-------|-----------|------------|
| `scripts/cgi-common.sh` | 145 | `cgi_parse_query`, `cgi_header`, `cgi_error`, `data_dir_resolve`, `nncp_hjson_set_neigh` | 6 handlers, 20-nncp-register |
| `scripts/cgi-trust.sh` | 152 | `cgi_client_hostname`, `cgi_client_fingerprint`, `is_trusted`, `peer_extract`, `peer_extract_stage` | 7 handlers, _run-parts, 20-nncp-register |
| `scripts/sync-common.sh` | 89 | `mtls_curl`, `mtls_curl_post`, `ensure_peer_host`, `apply_bundle_to_repo`, `query_spool_coverage` | install.sh, merge-spool.sh, package-common.sh, 50-bundle-push.sh |
| `scripts/sync-state.sh` | 104 | `sync_state_base`, `sync_state_dir`, `compute_refs_hash`, `get_synced_hash`, `set_synced_hash`, `clear_synced_hash` | 50-bundle-push.sh |
| `scripts/sync-test.sh` | 109 | `cleanup_tmpdir` | sync-common.sh |
| `scripts/cleanup-common.sh` | 90 | `cleanup_tmpdir`, `cleanup_dir` | 6 files |
| `cli/_common-cname.sh` | 116 | `_mtls_parse_args`, `_mtls_url`, `_mtls_curl`, `_mtls_exit_for_status`, `_mtls_cleanup` | 9 CLI wrappers |

### Dead Files

| File | Lines | Status |
|------|-------|--------|
| `scripts/docker-discovery-test.sh` | 88 | Orphan — never sourced/called |

## After (Target State)

### Shell Libraries (consolidated)

| File | Lines (est.) | Functions | Sourced by |
|------|-------------|-----------|------------|
| `scripts/cgi-lib.sh` | ~250 | All functions from cgi-common.sh + cgi-trust.sh + new `cgi_require_trusted()`, `extract_cn()`, `resolve_data_dir()` | All handlers, on-discovery.d scripts |
| `scripts/sync-lib.sh` | ~220 | All functions from sync-common.sh + sync-state.sh + cleanup_tmpdir | install.sh, merge-spool.sh, package-common.sh, 50-bundle-push.sh |
| `scripts/cleanup-common.sh` | 90 | (unchanged) | (unchanged) |
| `cli/_common-cname.sh` | 116 | (unchanged) | (unchanged) |

### Removed Files

| File | Reason |
|------|--------|
| `scripts/cgi-common.sh` | Merged into cgi-lib.sh |
| `scripts/cgi-trust.sh` | Merged into cgi-lib.sh |
| `scripts/sync-common.sh` | Merged into sync-lib.sh |
| `scripts/sync-state.sh` | Merged into sync-lib.sh |
| `scripts/sync-test.sh` | Merged into sync-lib.sh |
| `scripts/docker-discovery-test.sh` | Dead code |

## Impact Metrics (Estimated)

| Metric | Before | After (est.) | Reduction |
|--------|--------|-------------|-----------|
| Shell library lines | 805 | ~676 | ~16% |
| Handler lines | 489 | ~360 | ~26% |
| Dead files | 1 (88L) | 0 | 100% |
| Source-the-library boilerplate per handler | 2 lines × 7 | 1 line × 7 | 50% |
| DATA_DIR resolution bugs | 1 (90-log.sh) | 0 | 100% |
| CN extraction implementations | 4 | 1 | 75% |
