# Contract: Migration Helper (`scripts/migrate-layout.sh`)

## Purpose

Automatically move a legacy `certs/` layout to the flat layout. Non-interactive,
idempotent, never overwrites, removes empty legacy directories.

## Invocation

```
migrate-layout.sh <data-dir> [hostname]
```

- `<data-dir>`: the resolved data directory.
- `[hostname]`: optional; defaults to `$(hostname)`. Used for the identity
  filename and sanitized to `[A-Za-z0-9._-]` (other chars → `_`).

## Behavior

1. If `<data-dir>/certs` does not exist → exit 0 immediately (nothing to do).
2. **Identity**
   - `certs/certs/server.crt` → `identity/<hostname>.crt`
   - `certs/private/server.key` → `identity/<hostname>.key`
   - Move only if the target is missing; if the target exists, keep it and warn
     when contents differ.
3. **Trust**
   - Move each file in `certs/hosts/` → `hosts/` (skip if target exists).
4. **Purgatory**
   - Move each file in `certs/purgatory/` → `purgatory/` (skip if target exists).
5. **Cleanup**
   - `rmdir` empty `certs/certs`, `certs/private`, `certs/hosts`,
     `certs/purgatory`, then `certs`. Non-empty dirs are left with a warning.
6. Exit 0. Never prompts. Never fails on partial legacy layouts.

## Rules

- Never overwrite an existing file in the new layout.
- Never remove a non-empty directory.
- Idempotent: a second run finds nothing to move and exits 0.
- Must be safe to run concurrently (move-then-rmdir ordering makes this
  effectively atomic per file).

## Callers

- `scripts/install.sh` (after cert generation; before apache-config.sh)
- `scripts/package-common.sh` (postinst)
- `scripts/self-extract.in`
- Daemon startup (best-effort; see plan)
