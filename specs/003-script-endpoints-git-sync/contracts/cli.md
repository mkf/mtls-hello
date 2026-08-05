# Contract: Startup Configuration (CLI) — Updated

**Branch**: `003-script-endpoints-git-sync` | **Date**: 2026-03-19 | **Feature**: [spec.md](../spec.md)

> This contract extends the CLI defined in `specs/001-mtls-echo-discovery/contracts/cli.md` and `specs/002-per-host-cert-hook/contracts/cli.md`. Only additions are documented here; existing positional arguments and options remain as specified.

## Usage

```text
mtls-hello [port] [serverCert] [serverKey] [options]
```

## New Options

| Option | Default | Effect |
|---|---|---|
| `--handlers-dir=DIR` | `handlers` | Root directory of the script endpoint tree (`DIR/<name>.get.*`, `DIR/<name>.post.*`) |
| `--script-timeout=SECS` | `10` | Per-script execution timeout in seconds; exceeded → 500 and child killed |

## Option Details

### `--handlers-dir=DIR`

- Resolved relative to the server's working directory (absolute paths also accepted).
- If a directory does not exist or is empty, all script lookups miss: GET falls back to echo, POST returns 404 — identical to feature 001 behavior.
- Handler files are located at `DIR/<name>.get.<ext>` and `DIR/<name>.post.<ext>` (lowercase method infix; extension free-form, e.g. `sh`, or absent).

### `--script-timeout=SECS`

- Integer seconds; must be ≥ 1.
- Applies per script invocation (not per request lifetime).
- On timeout the child process is killed and the response is 500.

## Exit behavior (unchanged)

- Invalid port value or missing certificate files → error at startup, non-zero exit.
- A `--handlers-dir` that does not exist is NOT a startup error (empty handler set is valid; see above).
- `--script-timeout` with a value < 1 → error at startup, non-zero exit.
