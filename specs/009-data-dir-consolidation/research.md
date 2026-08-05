# Research: Data Directory Consolidation

## Decision: `--data-dir` flag name and semantics

**Decision**: Use `--data-dir` as the CLI flag name. No default value (empty string). When set, derive `handlers/` and `scripts/on-discover.sh` from it. Individual overrides take precedence.

**Rationale**:
- Follows XDG Base Directory convention (`XDG_DATA_HOME` → `~/.local/share/`)
- Matches existing flag naming pattern (`--handlers-dir`, `--trust-dir`, `--purgatory-dir`)
- No default in binary avoids hardcoding any filesystem layout assumption
- Individual overrides preserve backward compatibility with existing scripts and tests

**Alternatives considered**:
- `--home-dir` — ambiguous; could mean user HOME. Rejected.
- `--app-dir` — vague. Rejected.
- `--prefix` — conflicts with common install-prefix convention. Rejected.
- `MTLS_DATA_DIR` env var — inconsistent with the recent move away from env-vars-as-config (CALLBACK_SCRIPT is the exception, kept for backward compat). CLI flag is more discoverable.

## Decision: Path derivation precedence

**Decision**: Three-tier priority: explicit flag/env var > data-dir derivation > hard default (if any)

| Path | Tier 1 (explicit) | Tier 2 (derived) | Tier 3 (default) |
|------|-------------------|------------------|------------------|
| Handlers | `--handlers-dir=PATH` | `<data-dir>/handlers` | `"handlers"` |
| Callback | `CALLBACK_SCRIPT=PATH` | `<data-dir>/scripts/on-discover.sh` | `""` (disabled) |
| Trust | `--trust-dir=PATH` | *(not derived)* | `"certs/certs"` |
| Purgatory | `--purgatory-dir=PATH` | *(not derived)* | `"certs/purgatory"` |

**Rationale**: Explicit overrides must always win. Trust/purgatory are excluded from derivation because they contain security-sensitive certificate material with different lifecycle requirements.

## Decision: `.new` stub files

**Decision**: Use `.new` suffix for placeholder files (e.g., `pre-push.sh.new`). These are installed by `just install` to document future extension points without deploying active scripts.

**Rationale**:
- Self-documenting: operators can see what hooks are available
- Harmless: `.new` files are not executable scripts; just documentation
- Easy to activate: `cp pre-push.sh.new pre-push.sh && chmod +x pre-push.sh`
- Distinguishable from real scripts that would have `.get.sh`/`.post.sh` suffixes

**Alternatives considered**:
- `README.md` per directory — more verbose, less actionable. Rejected.
- `.example` suffix — less clear that it's a template for new scripts. `.new` is more explicit.
- No stubs — operators discover extension points only through docs. Less discoverable.

## Decision: Systemd unit migration

**Decision**: Change `ExecStart` from `--handlers-dir=%h/.local/share/mtls-hello/handlers` to `--data-dir=%h/.local/share/mtls-hello`. Remove any `CALLBACK_SCRIPT` environment entry. Existing `--no-multicast` remains.

**Rationale**: One flag to customize instead of three. The data-dir derivation handles handlers and callback paths automatically. Operators can still override via drop-in if needed.

## Decision: Backward compatibility

**Decision**: All existing flags (`--handlers-dir`) and env vars (`CALLBACK_SCRIPT`) continue to work. When `--data-dir` is not set, behavior is identical to current state. No migration required.

**Rationale**: Zero-breakage policy. Existing BATS tests, justfile recipes, and operator scripts continue to work unmodified.
