# CLI Contract: Data Directory Consolidation

## New Flag

### `--data-dir=PATH`

| Property | Value |
|---|---|
| Type | string |
| Required | No |
| Default | `""` (empty — no derivation, backward compatible) |
| Description | Base directory for all runtime data files |

**Behavior**:

When `--data-dir` is set to a non-empty path:

1. `--handlers-dir` defaults to `<data-dir>/handlers` (can be overridden)
2. `CALLBACK_SCRIPT` defaults to `<data-dir>/scripts/on-discover.sh` (can be overridden)
3. `--trust-dir` and `--purgatory-dir` are NOT affected (remain independent)

When `--data-dir` is empty or not provided:

- All existing defaults apply (zero behavior change)

## Precedence Rules

```
Handlers path resolution:
  1. --handlers-dir=PATH  (explicit, wins)
  2. --data-dir=PATH set? → <data-dir>/handlers
  3. "handlers"           (existing default)

Callback path resolution:
  1. CALLBACK_SCRIPT=PATH  (explicit, wins)
  2. --data-dir=PATH set? → <data-dir>/scripts/on-discover.sh
  3. ""                    (disabled)
```

## Usage Examples

```bash
# Production (via systemd):
mtls-hello --data-dir=%h/.local/share/mtls-hello --no-multicast

# Production (direct):
mtls-hello --data-dir="$HOME/.local/share/mtls-hello"

# Dev with data-dir (all paths derived):
mtls-hello --data-dir=./data

# Dev with individual paths (backward compatible, no regression):
mtls-hello --handlers-dir=handlers
CALLBACK_SCRIPT=scripts/on-discover.sh mtls-hello

# Mixed: data-dir base, override one sub-path:
mtls-hello --data-dir=./data --handlers-dir=./custom-handlers
```
