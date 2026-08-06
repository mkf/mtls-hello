# Implementation Plan: Flatten Directory Layout

**Branch**: `022-flatten-dir-layout` | **Date**: 2026-08-06 | **Spec**: spec.md

**Input**: Feature specification from `specs/022-flatten-dir-layout/spec.md`

## Summary

Flatten the runtime layout: trust (`hosts/`) and purgatory (`purgatory/`) move to
the data-dir root; our own cert/key move to `identity/<hostname>.crt|.key`
(replacing `certs/certs` + `certs/private`); a non-interactive, idempotent
migration helper (`scripts/migrate-layout.sh`) moves legacy installs and removes
empty dirs, run by install/package/self-extract and best-effort by the daemon at
startup.

## Technical Context

**Language/Version**: D2 (LDC) + Bash 4+

**Primary Dependencies**: `std.file` (rename/rmdir), `openssl`, shell install tooling

**Storage**: Filesystem layout under the data directory (no data format changes)

**Testing**: BATS (migration helper), Robot Framework (existing suites must stay green)

**Target Platform**: Linux (Debian/Arch/SUSE), Nix dev shell

**Project Type**: mTLS daemon + install/package tooling

**Performance Goals**: N/A (layout/migration only)

**Constraints**: No CA changes; cert CN stays `$(hostname)`; explicit
`--trust-dir`/`--purgatory-dir` keep overriding; migration never prompts,
never overwrites, is idempotent.

**Scale/Scope**: One migration helper + default-string changes + install/package
path updates + README.

## Constitution Check

The constitution is a template with no active gates. Principles observed:

1. **No system-wide changes**: new paths stay under the data directory; no `/etc` changes.
2. **No hardcoded defaults**: hostname-driven filenames; paths derive from `--data-dir`.
3. **Maintainable code**: one migration helper shared by all callers (no duplication).
4. **No CA / self-signed**: unchanged.
5. **Safety-first migration**: never overwrite, never prompt, idempotent.

No gate violations.

## Project Structure

### Documentation (this feature)

```text
specs/022-flatten-dir-layout/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/layout.md
├── contracts/migrate-layout.md
└── tasks.md            # /speckit.tasks
```

### Source Code (repository root)

```text
source/trust.d                 # defaults: "certs/hosts"→"hosts", "certs/purgatory"→"purgatory"
source/app.d                   # (data-dir derivation already DIR/hosts|purgatory) + best-effort migration spawn
scripts/migrate-layout.sh      # NEW migration helper
scripts/install.sh             # generate identity/<hostname>.crt|.key; call migration; pass new cert paths to apache-config.sh
scripts/install-service.sh     # OUR_CERT/OUR_KEY env → identity paths
scripts/package-common.sh      # env lines + cert gen + postinst migration (user + /var/lib layouts)
scripts/self-extract.in        # cert gen + migration
README.md                      # layout section, example, defaults
tests/migrate-layout.bats      # NEW migration tests
```

**Structure Decision**: One shared shell helper; all callers invoke it. The D
daemon triggers it best-effort at startup (resolved beside the callback script).

## Research (Phase 0)

See `specs/022-flatten-dir-layout/research.md`.

### Key decisions

- **D001**: new layout — `hosts/`, `purgatory/`, `identity/<hostname>.crt|.key`, no `certs/`.
- **D002**: one shell helper `scripts/migrate-layout.sh <data-dir> [hostname]`; callers: install, package postinst, self-extract, daemon startup (best-effort).
- **D003**: explicit `--trust-dir`/`--purgatory-dir` keep winning; migration only touches the default data-dir layout.
- **D004**: hostname sanitized to `[A-Za-z0-9._-]` for the identity filename.
- **D005**: `trust.d` defaults become `hosts`/`purgatory` (relative).

## Design (Phase 1)

See `data-model.md`, `contracts/layout.md`, `contracts/migrate-layout.md`, `quickstart.md`.

### Implementation details

1. **`source/trust.d`**: change default strings to `"hosts"` and `"purgatory"`.
2. **`source/app.d`**: after resolving dirs, if `<data-dir>/certs` exists and a
   migration script is found (beside the callback script, or `scripts/migrate-layout.sh`
   relative to CWD), spawn `bash <migrate-layout.sh> <data-dir> <hostname>` best-effort
   (failures logged, ignored). Keep `mkdirRecurse` on the resolved dirs.
3. **`scripts/migrate-layout.sh`** (new): per `contracts/migrate-layout.md`.
4. **`scripts/install.sh`**:
   - `mkdir -p identity/`; generate `identity/<hostname>.crt` + `identity/<hostname>.key` (CN = hostname, key 600) when missing.
   - Call `scripts/migrate-layout.sh "$DATA_DIR" "$HOST"`.
   - Pass `$DATA_DIR/identity/<hostname>.crt` + `.key` to `apache-config.sh` (was `certs/certs/server.crt` + `certs/private/server.key`).
5. **`scripts/install-service.sh`**: `OUR_CERT`/`OUR_KEY` → `%h/.local/share/mtls-hello/identity/<hostname>.crt|.key`.
6. **`scripts/package-common.sh`**: update env lines, cert gen (user + `/var/lib/mtls-hello/identity/`), call migration in postinst.
7. **`scripts/self-extract.in`**: cert gen at `identity/`; call migration.
8. **`README.md`**: update Directory Resolution section, start example, certs section, CLI defaults (drop `certs/` fallbacks).
9. **Tests**: `tests/migrate-layout.bats` (fresh no-op, move, partial, no-overwrite, idempotent, non-empty-leftover).

### Edge cases

- Legacy dir absent → no-op.
- Target exists → keep target, warn on difference.
- Non-empty leftover dir → warn, keep.
- Partial legacy layout (cert only, no key) → move what exists, no failure.
- Unsafe hostname → sanitized filename.
- Explicit `--trust-dir`/`--purgatory-dir` → never migrated.

## Complexity Tracking

No constitution violations. Net change is one small helper + default strings +
path updates (removal of `certs/` nesting).

## Risks & Mitigations

- **Orphaned legacy data** if migration is skipped → daemon best-effort + install always migrates; README documents.
- **Overwrite of user files** → migration never overwrites; warns.
- **Sanitization collision** (rare) → last write wins; documented.
- **Test fixture paths** (robot) → uses ephemeral temp dirs; unaffected.

## Research Links

- `specs/022-flatten-dir-layout/research.md`
- `specs/022-flatten-dir-layout/data-model.md`
- `specs/022-flatten-dir-layout/contracts/layout.md`
- `specs/022-flatten-dir-layout/contracts/migrate-layout.md`
- `specs/022-flatten-dir-layout/quickstart.md`
