# Data Model: Flatten Directory Layout

## Entity: Data Directory (`DIR`)

The single base value from which all runtime paths derive.

- Resolved from `--data-dir=DIR`; installed default `~/.local/share/mtls-hello`.
- All other paths below are relative to `DIR` unless overridden.

## Entity: Identity

Our own certificate + key.

| Field | Path | Description |
|-------|------|-------------|
| certificate | `DIR/identity/<hostname>.crt` | Self-signed cert, `CN = <hostname>`; the file shared with peers for trust. |
| key | `DIR/identity/<hostname>.key` | Private key; permissions 600. |

- `<hostname>` is sanitized to `[A-Za-z0-9._-]` (else `_`).
- Replaces legacy `certs/certs/server.crt` + `certs/private/server.key`.

## Entity: Trust Store

- Path: `DIR/hosts/` (default `hosts` relative; `--trust-dir` overrides).
- Files: `<hostname>.crt` per trusted peer.
- Replaces legacy `certs/hosts/`.

## Entity: Purgatory

- Path: `DIR/purgatory/` (default `purgatory` relative; `--purgatory-dir` overrides).
- Files: `<hostname>.<fingerprint>.crt` per captured unknown peer.
- Replaces legacy `certs/purgatory/`.

## Entity: Legacy Layout (migration source)

The old `certs/` tree, migrated away from:

```text
certs/
├── hosts/          → DIR/hosts/
├── purgatory/      → DIR/purgatory/
├── certs/          → DIR/identity/ (server.crt → <hostname>.crt)
└── private/        → DIR/identity/ (server.key → <hostname>.key)
```

### State transitions

```text
legacy certs/ tree exists ─▶ migration runs ─▶ new layout populated,
                                                empty legacy dirs removed
                                             ─▶ idempotent: next run is no-op
```

### Migration rules (per spec FR-005 / research D002)

- Non-interactive, idempotent.
- Move file only if target does not exist; if target exists, keep it and (if contents differ) warn.
- After moving, `rmdir` empty legacy dirs (`certs/certs`, `certs/private`, `certs/hosts`, `certs/purgatory`, `certs`).
- Non-empty leftover dirs are left with a warning; never a failure.
- Never touches explicitly-overridden trust/purgatory paths.
