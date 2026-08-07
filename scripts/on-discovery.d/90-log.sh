#!/usr/bin/env bash
# scripts/on-discovery.d/90-log.sh — append an ISO-8601 entry to
# <data-dir>/discoveries.log summarising this discovery event.
#
# Format (one record per line):
#   <ISO-8601-timestamp> \t <peer-CN> \t <peer-NNCP-id> \t <stage> \t <which-subscripts-ran>
#
# Append-only — no truncation. Existing entries remain untouched.

set -euo pipefail

DATA_DIR="${DATA_DIR:-$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)}"
LOG="$DATA_DIR/discoveries.log"

ts="$(date -Iseconds)"
cn="${HOST_NAME:-unknown}"
nncp_id="${PEER_NNCP_ID:-}"
stage="${STAGE:-new}"

# The _run-parts.sh launcher does not currently propagate "which scripts ran"
# per launcher's $0. We default an empty markers list; 025's follow-up can
# tighten the contract via a `RESULT_BASENAMES` env var if needed.
ran="${SUBSCRIPTS_RAN:-}"

# Sanitize tabs in cn (replace with space) to keep the record one-line.
cn_safe="${cn//	/ }"
nncp_safe="${nncp_id//	/ }"

# Append; lock=none because <data-dir> is single-process on the host.
printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$cn_safe" "$nncp_safe" "$stage" "$ran" >> "$LOG"
exit 0
