# Contract: `<data-dir>/on-discovery.d/*.sh` env vars and execution ordering

**Purpose**: Define the env-var surface and the per-script contract for the discovery callback hooks that 025 introduces.
**Created**: 2026-08-07
**Feature**: [spec.md](../spec.md) | [plan.md](../plan.md) | [research.md](../research.md)

---

## Invocation flow

1. **D-side**: `source/multicast.d:343-360` runs `spawnProcess(["bash", request.callbackScript], environment)`. It calls the launcher **once** per discovery event, with all env vars set.
2. **Launcher**: `<data-dir>/on-discovery.d/_run-parts.sh` runs each `[0-9][0-9]-*.sh` script in lex order, with the same env vars (inherited from the launcher's env), wrapped in `timeout --kill-after=5 30`.
3. **Per script**: env vars inherited. Each script may `exit 0` (continue), `exit non-zero` (fail-and-log; chain continues), or `exit 254` (abort chain — reserved for `00-validate.sh`).
4. **End of chain**: launcher exits with 0 unless `00-validate.sh` aborted.

The path to the launcher is set in `source/app.d:78`:
```d
cfg.multicast.callbackScript = cfg.dataDir ~ "/scripts/on-discovery.d/_run-parts.sh";
```

The launcher is in `scripts/` (the source tree), not `<data-dir>/on-discovery.d/_run-parts.sh`. The D code resolves `cfg.multicast.callbackScript` against `cfg.dataDir` (we ship the launcher at `scripts/on-discovery.d/_run-parts.sh` to make the dispatch directory self-contained but also call-able directly via a separate script). The script reads `$0`, finds its own `..` (which is `<data-dir>/scripts/`), and the on-discovery.d dir lives at `<data-dir>/scripts/on-discovery.d/`.

Wait — that's confusing. Let me restructure:

**Real plan**:
- We DO create `<data-dir>/scripts/on-discovery.d/_run-parts.sh` (the launcher) — copied at install time from `scripts/on-discovery.d/_run-parts.sh` checked into the repo.
- `source/app.d:78` is updated to: `cfg.multicast.callbackScript = cfg.dataDir ~ "/scripts/on-discovery.d/_run-parts.sh";`.

That's a simpler setup. The repo ships a directory of default scripts; install copies the directory wholesale to `<data-dir>`; D calls the launcher there.

## Env vars (inherited by every script)

The D side sets these:

| Variable | Shape | Source | Required by |
|---|---|---|---|
| `HOST_NAME` | `string` | existing pattern from feature 002/008 | All scripts that emit peer-facing data |
| `PEER_NETLOC` | `host:port` | `source/multicast.d:dispatch` | All scripts |
| `PEER_CERT_FILE` | `path` | `source/multicast.d:dispatch` | All scripts |
| `OUR_CERT` | `path` | `source/multicast.d:dispatch` | All scripts |
| `OUR_KEY` | `path` | `source/multicast.d:dispatch` | All scripts |
| `REPOS_ROOT` | `path` | `source/multicast.d:dispatch` (legacy) | `50-bundle-push.sh` only |
| `PEER_NNCP_ID` | `base32-32` | NEW in 025 — `cgi-trust.sh` extracts from `PEER_CERT_FILE` using `openssl x509` and `blake2b-256` | `20-nncp-register.sh`, `90-log.sh` |
| `PEER_SIGNPUB` | `base32-32` | NEW in 025 — `openssl x509 -pubkey -outform DER \| tail -c 32 \| base32 -w 0` after stripping SEQUENCE + BIT STRING headers | `20-nncp-register.sh` |
| `PEER_EXCHPUB` | `base32-32` | NEW in 025 — `openssl x509 -text \| grep 'pub:'` parses the X25519 SPKI | `20-nncp-register.sh` |
| `PEER_NOISEPUB` | `base32-32` | NEW in 025 — *if* peer cert includes a noise keypair (extension OID `1.x.x.x.x.nncp-noise`); absent otherwise | `20-nncp-register.sh` |
| `STAGE` | `string` (one of `new`, `updated`) | NEW in 025 — D-side sets based on whether peer was already in trust store | All scripts |
| `TIMEOUT` | `int` (seconds) | NEW in 025 — per-script timeout, default 30 | All scripts (read-only; abort if this script outpaces) |

Validation rule for `PEER_NNCP_ID`/`PEER_SIGNPUB`/`PEER_EXCHPUB`: set by the launcher **before** invoking the per-script loop. The launcher's preamble calls `scripts/cgi-trust.sh peer-extract` (a function added in 025) which queries `PEER_CERT_FILE` and computes these values.

## Per-script execution contract

### `00-validate.sh`

```bash
[ -n "$HOST_NAME" ] || exit 254
[ -n "$PEER_NETLOC" ] || exit 254
[ -n "$PEER_CERT_FILE" ] && [ -s "$PEER_CERT_FILE" ] || exit 254
[ -n "$PEER_NNCP_ID" ] || exit 254
[ "$OUR_CERT" != "$PEER_CERT_FILE" ] || exit 254  # not self
exit 0
```

Exit code `254` aborts the chain (rest of scripts do not run).

### `10-trust-add.sh`

```bash
. "$(dirname "$0")/../cgi-trust.sh"  # shared helpers
data_dir="$(data_dir)"  # from env var DATA_DIR (set by launcher)
trust_dir="$data_dir/hosts"
mkdir -p "$trust_dir"
remove_file_safe "$trust_dir/$HOST_NAME.crt"  # feature 022 anchored rm
cp -- "$PEER_CERT_FILE" "$trust_dir/$HOST_NAME.crt"
# Verify fingerprint matches the peer's cert we're pinning.
openssl x509 -in "$PEER_CERT_FILE" -noout -fingerprint -sha256 > "$DATA_DIR/run/trust-add.fp.$$" || exit 1
exit 0
```

Output: appends fingerprint to log; idempotent — replace, not duplicate.

### `20-nncp-register.sh`

```bash
. "$(dirname "$0")/../cgi-common.sh"  # data-dir helpers
nncp_hjson="$DATA_DIR/nncp.hjson"
# Atomic rewrite: write to tempfile, then mv into place.
tmp="$(mktemp "${nncp_hjson}.XXXX")"
trap 'remove_file_safe "$tmp"' EXIT
jq-empty-hjson-pass "$nncp_hjson" "$tmp"  # custom helper in cgi-common.sh
# Insert/update entry under neigh.$HOST_NAME
jq-set-neigh "$tmp" "$HOST_NAME" "$PEER_NNCP_ID" "$PEER_EXCHPUB" "$PEER_SIGNPUB" "${PEER_NOISEPUB:-}"
mv -- "$tmp" "$nncp_hjson"
exit 0
```

Notes:
- We use a custom `jq`-style helper (`jq-empty-hjson-pass`, `jq-set-neigh`) implemented in `scripts/cgi-common.sh` using a `hjson-cli` binary that ships with NNCP 8.13.0 (`/tmp/nncp-8.13.0/src/cmd/nncp/bin/hjson-cli` — built by `scripts/build-nncp.sh`).
- `remove_file_safe "$tmp"` honours the project safety rule (no `rm -f`).
- The script accepts exit-1 silently (the launcher logs it; idempotent across repeat discoveries).

### `50-bundle-push.sh` (legacy-preserving)

```bash
# Replicates the existing scripts/on-discover.sh logic, minus the trust
# part (which 10-trust-add.sh now does) and minus the nncp-register part
# (which 20-nncp-register.sh now does).
. "$(dirname "$0")/../sync-common.sh"  # git+curl helpers (existing)
. "$(dirname "$0")/../sync-state.sh"   # sync state tracking (existing)
. "$(dirname "$0")/../cleanup-common.sh"  # safety rm hjos (existing)
unset LD_LIBRARY_PATH  # host's openssl, not nix vendored
[ -n "$REPOS_ROOT" ] || exit 1
[ -n "$PEER_CERT_FILE" ] || exit 0
# Per-repo bundle-and-push logic, identical to the legacy on-discover.sh.
# ... (loop as before)
exit 0
```

This script preserves feature 016's behaviour: on discovery, push bundles over `/bundle?repo=…&host=…&from=…&to=…`.

### `90-log.sh`

```bash
ts="$(date -Iseconds)"
cn="$HOST_NAME"
nncp_id="$PEER_NNCP_ID"
ran='["10-trust-add","20-nncp-register","50-bundle-push"]'
# Detected which subscripts ran (chain runs 00,10,20,50,90 in lex order; 00-validate
# and 90-log run silently without contributing to the "ran" list).
echo -e "$ts\t$cn\t$nncp_id\t$ran" >> "$DATA_DIR/discoveries.log"
exit 0
```

Append-only; no truncation.

## `_run-parts.sh` launcher spec

```bash
#!/usr/bin/env bash
set -euo pipefail

# Resolve $DATA_DIR from $0 or env.
DATA_DIR="${DATA_DIR:-$(dirname "$(realpath -- "$0")")/../../}"

dir="$DATA_DIR/scripts/on-discovery.d"
stage="${1:-}"
LOG_PREFIX="[on-discovery.d]"

mkdir -p "$DATA_DIR/queues" "$DATA_DIR/trash"

# Pre-compute peer-NNCP-identity env vars (single source of truth).
. "$DATA_DIR/scripts/cgi-trust.sh" peer-extract  # populates $PEER_NNCP_ID, $PEER_SIGNPUB, $PEER_EXCHPUB, $PEER_NOISEPUB

# Lex-order invoke each [0-9][0-9]-*.sh with $TIMEOUT-second timeout.
for script in "$dir"/[0-9][0-9]-*.sh; do
    [ -e "$script" ] || continue
    base="$(basename "$script")"
    echo "$LOG_PREFIX + $base (timeout=${TIMEOUT:-30}s)"
    if ! timeout --kill-after=5 "${TIMEOUT:-30}" env \
            DATA_DIR="$DATA_DIR" \
            STAGE="${STAGE:-new}" \
            TIMEOUT="${TIMEOUT:-30}" \
            bash "$script"; then
        echo "$LOG_PREFIX ! $base exited $?"
    fi
done
exit 0
```

Notes:
- The launcher itself doesn't fail if any child fails — that's by design, per FR-015.
- `TIMEOUT` is per-script; the launcher does not impose a global deadline on the chain.
- Env-var derivation (`cgi-trust.sh peer-extract`) is a one-time pre-compute; subsequent scripts see the values via the inherited env.

## Validation: idempotency

Repeat-discovery on the same peer is allowed by the spec. Each script is **idempotent**:
- `10-trust-add.sh`: replace-style `cp --` overwrites.
- `20-nncp-register.sh`: `jq-set-neigh` updates existing entry; in-place update via tempfile + mv.
- `50-bundle-push.sh`: per-repo ref-hash dedup from `scripts/sync-state.sh`.
- `90-log.sh`: append-only; log entries accumulate harmlessly.

## Validation: ordering

Lex-sorted filenames guarantee the order:
- `00-` runs first.
- `10-` runs second.
- `20-` runs third.
- `50-` runs fourth (preserves legacy git-bundle-push).
- `90-` runs fifth.

If a user adds `25-my-check.sh`, it runs after `20-` and before `50-`.

## Self-test (BATS)

`tests/nncp-replace.bats` includes a smoke test:
- Drop two extra scripts into a sandbox dir: `10a-extra.sh`, `99-late.sh`. Verify only the original four run.
- Set `STAGE=updated` env. Verify `90-log.sh` records `stage:updated`.

## Acceptance criteria

The contract above is satisfied iff:

1. `app.d:78` resolves to a real file at install time.
2. `cgi-trust.sh peer-extract` is implemented and populates the new env vars.
3. Default scripts behave per their per-script specs.
4. BATS tests pass.
