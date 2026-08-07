# Quickstart: Codebase Simplification

**Date**: 2026-08-07
**Feature**: 026-codebase-simplification

## Prerequisites

```bash
nix-shell --run 'bats tests/'   # baseline: all tests green BEFORE changes
```

Record the baseline line count:
```bash
find source scripts handlers cli -name '*.d' -o -name '*.sh' | xargs wc -l | tail -1
```

## Execution Order (by priority)

### Phase 1: Script Consolidation (P1)

```bash
# 1. Create cgi-lib.sh (merge cgi-common.sh + cgi-trust.sh + new helpers)
#    Add: cgi_require_trusted(), extract_cn(), resolve_data_dir()
#    Test: bash -n + shellcheck on cgi-lib.sh

# 2. Update all handlers to source cgi-lib.sh (1 line instead of 2)
#    Replace boilerplate cert-check + is_trusted with cgi_require_trusted()
#    Test: nix-shell --run 'bats tests/smoke.bats'

# 3. Update on-discovery.d scripts to use resolve_data_dir()
#    Fixes 90-log.sh DATA_DIR bug as side effect
#    Test: nix-shell --run 'bats tests/nncp-replace.bats'

# 4. Update log-capture.sh, trust-host.sh, sync-common.sh to use extract_cn()
#    Test: nix-shell --run 'bats tests/smoke.bats'

# 5. Remove docker-discovery-test.sh (dead code)
#    Verify: grep -r docker-discovery-test . (zero hits outside specs/)
```

### Phase 2: Sync Library Merge (P2)

```bash
# 6. Create sync-lib.sh (merge sync-common.sh + sync-state.sh + sync-test.sh)
# 7. Update all consumers (install.sh, merge-spool.sh, package-common.sh, 50-bundle-push.sh)
# 8. Remove old files: sync-common.sh, sync-state.sh, sync-test.sh
#    Test: nix-shell --run 'bats tests/sync-state.bats tests/smoke.bats'
```

### Phase 3: Test Cleanup (P3, optional)

```bash
# 9. Extract tests/helpers.bash with shared setup
# 10. Refactor smoke.bats to use helpers
#     Test: nix-shell --run 'bats tests/'  (full suite)
```

## Validation Checklist

After each phase:
- [ ] `shellcheck --severity=warning` clean on all modified scripts
- [ ] `bash -n` clean on all modified scripts
- [ ] Relevant BATS tests pass
- [ ] No file removed without grep verification (FR-005)
- [ ] No `rm -rf` / `rm -f` / `find -delete` introduced (G1)

After all phases:
- [ ] Full test suite green (`nix-shell --run 'bats tests/'`)
- [ ] Robot Framework green (if available)
- [ ] Line count reduced ≥15% (SC-001)
- [ ] File count reduced ≥10% (SC-002)
- [ ] One authoritative definition per shared concern (SC-004)

## Safety Rules

- **NEVER** `rm -rf`, `rm -f`, `rm -r`, or `find -delete` — only plain `rm` on known files + `rmdir` on empty dirs
- **NEVER** change handler filenames (Apache `ScriptAlias` references them)
- **NEVER** change externally observable HTTP status codes or CGI env var names
- **ALWAYS** run tests after each consolidation step
