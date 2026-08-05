# Implementation Plan: Data Directory Consolidation

**Branch**: `009-data-dir-consolidation` | **Date**: 2026-08-05 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/009-data-dir-consolidation/spec.md`

## Summary

Add a `--data-dir=PATH` CLI flag that serves as the single base directory from which all runtime sub-paths are derived: `handlers/`, `scripts/on-discover.sh`, and any future extensions. Individual `--handlers-dir` and `CALLBACK_SCRIPT` overrides still take precedence. Update `install.sh` and `install-service.sh` to use the new flag.

## Technical Context

**Language/Version**: D (LDC2 1.27+, vibe.d 0.10.x)

**Primary Dependencies**: vibe.d (HTTP server, CLI argument parsing)

**Storage**: N/A — filesystem paths only

**Testing**: BATS — verify `--data-dir` derives correct sub-paths, verify `install.sh` creates expected tree, verify systemd unit format

**Target Platform**: Linux with systemd user services

**Project Type**: Enhancement — consolidates existing path flags under one umbrella

**Performance Goals**: Zero overhead — path resolution at startup only

**Constraints**: Must not break existing `--handlers-dir`, `CALLBACK_SCRIPT`, or `--trust-dir`/`--purgatory-dir` behavior

**Scale/Scope**: ~50 lines in `source/app.d`, ~10 in each install script; 3-4 new BATS tests

## Constitution Check

The project constitution is a template with no concrete principles. **PASS** by default.

## Project Structure

### Documentation

```text
specs/009-data-dir-consolidation/
├── plan.md, research.md, data-model.md, quickstart.md
├── contracts/ (cli.md)
└── checklists/requirements.md
```

### Source Changes

```text
source/app.d            # +--data-dir flag, path derivation logic
scripts/install.sh      # +create full tree, .new stubs
scripts/install-service.sh # --data-dir in ExecStart instead of --handlers-dir
tests/smoke.bats        # +3-4 new tests
```

## Complexity Tracking

No violations. No entries.

## Design Decisions

### Path derivation order

```
handlers:   --handlers-dir flag > data-dir/handlers > "handlers" (existing default)
callback:   CALLBACK_SCRIPT env > data-dir/scripts/on-discover.sh > "" (disabled)
trust:      --trust-dir flag > "certs/certs" (unchanged)
purgatory:  --purgatory-dir flag > "certs/purgatory" (unchanged)
```

### Why derive callback from data-dir instead of keeping separate env var

`CALLBACK_SCRIPT` remains as an override. But when `--data-dir` is set, a sensible default exists (`<data-dir>/scripts/on-discover.sh`), so the operator doesn't need to set both. This eliminates the configuration sprawl the user identified.
