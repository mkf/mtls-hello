# Implementation Plan: Install-Time Self-Signed Certificates

**Branch**: `010-install-selfsigned-certs` | **Date**: 2026-08-05 | **Spec**: [spec.md](./spec.md)

## Summary

Generate a self-signed server certificate during `just install` if none exists. Remove all CA infrastructure — `scripts/gen_certs.sh`, `certs/` committed fixtures, and all CA references in tests. BATS tests generate per-test self-signed certificates via a shared helper.

## Technical Context

**Language/Version**: D (LDC2 1.27+, vibe.d 0.10.x) + Bash

**Primary Dependencies**: `openssl` CLI for cert generation

**Storage**: Files under `~/.local/share/mtls-hello/certs/`

**Testing**: BATS — replace CA-based curl invocations with self-signed cert flags

**Target Platform**: Linux with openssl available

**Project Type**: Fix/enhancement — 3 files changed, 1 deleted

**Constraints**: Must not break existing 41 tests

**Scale/Scope**: ~20 lines in install.sh, ~50 lines of test refactoring, delete gen_certs.sh and certs/

## Constitution Check

Template — PASS by default.

## Project Structure

### Files changed

```text
scripts/install.sh           # +cert generation
tests/smoke.bats             # +mkfixture_certs helper, replace all CA refs
justfile                     # -gen-certs recipe
scripts/gen_certs.sh         # REMOVED
certs/                       # REMOVED (committed fixtures)
```

### Test helper design

```bash
# Generate a self-signed cert+key pair, return paths via globals.
# Sets SERVER_CERT, SERVER_KEY, CLIENT_CERT, CLIENT_KEY.
mkfixture_certs() {
  local dir="$1"
  mkdir -p "$dir"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$dir/server.key" -out "$dir/server.crt" \
    -subj "/CN=localhost" 2>/dev/null
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$dir/client.key" -out "$dir/client.crt" \
    -subj "/CN=test-client" 2>/dev/null
  SERVER_CERT="$dir/server.crt"
  SERVER_KEY="$dir/server.key"
  CLIENT_CERT="$dir/client.crt"
  CLIENT_KEY="$dir/client.key"
}
```

Curl invocations change from:
```bash
curl --cacert certs/certs/ca.crt --cert certs/certs/client.crt --key certs/private/client.key
```
to:
```bash
curl --cacert "$SERVER_CERT" --cert "$CLIENT_CERT" --key "$CLIENT_KEY"
```

## Design Decisions

### Why generate in install.sh, not in the binary

The binary doesn't know the install path (no defaults). The install script knows the target directory and can generate certs there. This avoids a hardcoded path in the binary.

### Why remove gen_certs.sh entirely

The script was a development convenience that created a CA-based PKI. With self-signed certs, there's no CA. The BATS helper replaces it for tests. For development, `openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -subj /CN=localhost` is a one-liner.

### Why not commit test fixture certs

Committed certs expire and create maintenance churn. Per-test generation with 1-day validity ensures tests never break due to expiration. The `openssl req` call adds ~100ms per test — negligible.
