# Research: Flatten Directory Layout

**Date**: 2026-08-06
**Feature**: specs/022-flatten-dir-layout/spec.md

## Questions to resolve

1. What is the canonical new layout?
2. Where must the old paths be changed (full inventory)?
3. What should the migration look like — where does it live, and who runs it?
4. How should the identity certificate be named, and is hostname sanitization needed?
5. How do explicit overrides interact with migration?

## Findings

### 1. Canonical new layout

```text
<data-dir>/
├── hosts/          trust store (peer certs as <hostname>.crt)
├── purgatory/      unknown peer certs (<hostname>.<fingerprint>.crt)
├── identity/
│   ├── <hostname>.crt     our own certificate (CN = hostname)
│   └── <hostname>.key     our own private key
├── handlers/       Apache CGI endpoints
├── scripts/        helpers, capture, callbacks
├── apache/         generated httpd.conf, logs, pid, mime
├── spool/<repo>/   incoming bundles
├── repos/          bare git repos (or REPOS_ROOT)
└── ffdc/           first-failure data capture
```

No `certs/` directory exists anymore.

**Decision D001**: adopt this layout. `identity/` replaces `certs/certs` + `certs/private`, flattened to one directory; trust/purgatory move to the data-dir root.

### 2. Full inventory of touch points (from grep)

| Area | File(s) | Change |
|---|---|---|
| D defaults | `source/trust.d:30-31` | `"certs/hosts"`→`"hosts"`, `"certs/purgatory"`→`"purgatory"` |
| D data-dir derive | `source/app.d` | already `DIR/hosts`/`DIR/purgatory` — no change; add identity path if needed |
| Install | `scripts/install.sh` | generate `identity/<hostname>.crt`/`.key`; pass them to apache-config.sh; call migration |
| systemd env | `scripts/install-service.sh:22-23` | `OUR_CERT`/`OUR_KEY` → identity paths |
| Package | `scripts/package-common.sh` | env lines + cert gen + postinst migration |
| Self-extract | `scripts/self-extract.in` | cert gen + migration |
| Apache config | `config/apache-site.conf.in` | unchanged (uses `{{SERVER_CERT}}`/`{{SERVER_KEY}}` vars) |
| README | several sections | update layout, example, defaults |
| Tests | `robot/MtlsLibrary.py` | uses ephemeral temp cert dir — unaffected |

Docker compose uses `/tmp/certs` (ephemeral test harness) — out of scope.

### 3. Migration design

Requirements: automatic, non-interactive, idempotent, moves files, removes empty dirs, never overwrites existing targets, never touches explicitly-overridden paths.

Options considered:

- **A: Inline D migration in the daemon.** Runs every startup. But the identity part belongs to install (the daemon doesn't know the cert path), and duplicating logic in D + shell is worse.
- **B: Single shell helper `scripts/migrate-layout.sh <data-dir> [hostname]` called from install/package/self-extract AND best-effort from the daemon at startup.** One implementation, all triggers covered, matches the project's bash-driven install style.
- **C: Migration only in install.** Misses "run from repo without install" (dev) where a legacy `certs/` may exist.

**Decision D002**: Option B. One shell script, called by install/package/self-extract, and spawned best-effort by the daemon at startup (resolved next to the callback script; failures ignored). The daemon then proceeds with the new defaults; the script is idempotent so concurrent/duplicate runs are harmless.

Migration rules (inside the script):

1. If `<data-dir>/certs` does not exist → exit 0 (fresh layout).
2. `certs/certs/server.crt` → `identity/<hostname>.crt` (if target missing; else leave target, drop source only if identical, else warn).
3. `certs/private/server.key` → `identity/<hostname>.key` (same rule).
4. `certs/hosts/*` → `hosts/` (move each file if target missing).
5. `certs/purgatory/*` → `purgatory/` (same).
6. `rmdir` empty `certs/certs`, `certs/private`, `certs/hosts`, `certs/purgatory`, then `certs`. Non-empty → warn, leave.
7. Exit 0. Never prompts.

**Decision D003**: explicit `--trust-dir`/`--purgatory-dir` are honored by the daemon after migration; the migration only ever operates on the default data-dir layout, so an explicit override pointing elsewhere is simply left alone. (The daemon only migrates when the resolved default paths would otherwise be used.)

### 4. Identity naming + hostname sanitization

The cert CN is already `$(hostname)` (install.sh), and peers store trusted certs as `<trust-dir>/<hostname>.crt` (trust-host.sh). So naming our cert `identity/<hostname>.crt` makes the file-to-share naturally `<hostname>.crt`.

Hostnames from `hostname(1)` are DNS-ish but can contain characters that are awkward in filenames. **Decision D004**: sanitize to `[A-Za-z0-9._-]`, replacing anything else with `_`, in both the identity filename and (consistently) the trust-host naming path. The sanitized name is what lands in `identity/` and what peers would copy.

### 5. Overrides vs migration

**Decision D005**: `trust.d` defaults become `hosts`/`purgatory` (relative). With `--data-dir`, app.d already sets `DIR/hosts`/`DIR/purgatory`. Explicit flags keep winning (unchanged logic). The migration never runs against an explicit override path.

## Risks

- **Orphaned legacy data**: if migration is skipped (script missing), old `certs/` stays but new dirs are used → data appears lost. Mitigation: daemon best-effort migration at startup + install always migrates + README notes.
- **Overwriting**: never overwrite existing target files; if both old and new exist with different content, keep new, warn.
- **Sanitization collision**: two hostnames sanitizing to the same name (rare) → last write wins; acceptable, documented.
- **Idempotency**: second run is a no-op by construction (nothing to move; empty dirs already gone).
