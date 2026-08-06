# Contract: Canonical Directory Layout

## Purpose

Define the single source of truth for directory locations after the flattening.
Applies to the daemon, Apache config generation, install/package tooling, and
the README. All paths are relative to the resolved data directory `DIR`.

## Layout

```text
DIR/
├── hosts/            # trust store — peer certs <hostname>.crt
├── purgatory/        # captured unknown certs <hostname>.<fingerprint>.crt
├── identity/
│   ├── <hostname>.crt    # our certificate (CN = hostname), shared for trust
│   └── <hostname>.key    # our private key (mode 600)
├── handlers/         # Apache CGI endpoints (5 scripts)
├── scripts/          # helpers, capture, callbacks, migration
├── apache/           # httpd.conf, site.conf, error.log, access.log, httpd.pid, mime/
├── spool/<repo>/     # incoming bundles awaiting merge
├── repos/            # bare git repos (REPOS_ROOT overrides)
└── ffdc/             # first-failure data capture
```

## Resolution order per directory

| Directory | Resolution order |
|---|---|
| `hosts/` | `--trust-dir` → `DIR/hosts` → `hosts` (relative) |
| `purgatory/` | `--purgatory-dir` → `DIR/purgatory` → `purgatory` (relative) |
| `identity/` | `DIR/identity` (no flag; install/Apache only) |
| `scripts/` | `DIR/scripts` (installed layout `~/.local/share/mtls-hello/scripts`) |
| `handlers/` | `DIR/handlers` |
| `apache/` | `DIR/apache` |
| `spool/` | `DIR/spool/<repo>` |
| `repos/` | `REPOS_ROOT` env → `DIR/repos` |
| `ffdc/` | `DIR/ffdc` |

## Callback script

1. `CALLBACK_SCRIPT` env.
2. `DIR/scripts/on-discover.sh`.

## Forbidden paths

- No default resolves under a `certs/` directory.
- `certs/certs`, `certs/private`, `certs/hosts`, `certs/purgatory` are legacy
  and must only be referenced by the migration helper.
