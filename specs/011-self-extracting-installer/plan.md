# Implementation Plan: Self-Extracting Portable Installer

**Branch**: `011-self-extracting-installer` | **Date**: 2026-08-05 | **Spec**: [spec.md](./spec.md)

## Summary

A `just self-extract` recipe that builds a self-extracting shell script. The script bundles the binary, vendored libraries, handlers, hook templates, and the install-service generator. It provides `install` and `install-service` subcommands for deployment to bare Debian/Ubuntu x86_64 systems without Guix.

## Technical Context

**Language/Version**: Bash (script template) + justfile recipe

**Primary Dependencies**: `base64`, `tar`, `gzip`, `cat`, `git`, `date`, `patchelf`

**Storage**: Single `.sh` file output in repo root

**Testing**: BATS — verify filename pattern, `--help`, file placement after install, unit file content. **Do not execute the installed binary in tests** — its execution is already covered by the 44 server tests, and running it inside the Guix/BATS environment triggers glibc-hwcaps conflicts.

**Target Platform**: Debian 11+ x86_64 (glibc ≥ 2.31), bash, openssl CLI, systemd user instance

**Project Type**: New script + justfile target + patchelf step

**Constraints**: Resulting file is ~40MB; must not pipe-to-bash; filename includes git commit, date, dirty flag

**Scale/Scope**: ~20 lines in justfile, ~90 lines in the script template, ~5 lines in build script for patchelf

## Constitution Check

Template — PASS by default.

## Project Structure

### Files changed

```text
justfile                    # + self-extract recipe
scripts/self-extract.in     # NEW: shell script template with payload placeholder
scripts/self-extract-build.sh  # NEW: assembles the installer (staging + patchelf + base64)
guix.scm                    # + patchelf package
```

### How it works

```
just self-extract:
  1. dub build (if ./mtls-hello missing)
  2. Stage install tree in temp dir:
     bin/mtls-hello          (patchelf'd: interpreter=/lib64/ld-linux-x86-64.so.2, rpath=$ORIGIN/../lib/mtls-hello)
     lib/mtls-hello/*.so*    (vendored from Guix, dereferenced to real files)
     share/mtls-hello/handlers/
     share/mtls-hello/scripts/*.new
  3. tar czf payload.tar.gz --directory=$stage .
  4. base64 payload.tar.gz
  5. Concatenate: scripts/self-extract.in + base64 data
  6. Name: mtls-hello-installer-<short-hash>-<YYYYMMDD>[-dirty].sh
  7. chmod +x

Target machine:
  bash installer.sh install         → unset LD_LIBRARY_PATH, decode+extract payload, copy to ~/.local, generate cert
  bash installer.sh install-service → create systemd unit with absolute paths
```

### Script template design (self-extract.in)

```bash
#!/usr/bin/env bash
set -euo pipefail
# Clear inherited library path — the script uses host utilities (sed, tar,
# openssl), not Guix-linked ones. The installed binary finds its libs via
# the patchelf rpath, not LD_LIBRARY_PATH.
unset LD_LIBRARY_PATH

usage() { echo "Usage: $0 {install|install-service}"; exit "${1:-0}"; }

extract_payload() {
  if [ -z "${_SE_PAYLOAD_DIR:-}" ]; then
    _SE_PAYLOAD_DIR=$(mktemp -d)
    trap 'rm -rf "$_SE_PAYLOAD_DIR"' EXIT
    sed '1,/^__PAYLOAD__$/d' "$0" | base64 -d | tar xz -C "$_SE_PAYLOAD_DIR"
  fi
}

do_install() {
  extract_payload
  # ... copy binary, libs, handlers, scripts to ~/.local/ ...
  # ... generate self-signed cert (same as install.sh) ...
  exit 0
}

do_install_service() {
  # ... check binary exists, write systemd unit ...
  exit 0
}

case "${1:-}" in
    install) do_install; exit 0 ;;
    install-service) do_install_service; exit 0 ;;
    --help|-h) usage 0 ;;
    "") usage 1 ;;
    *) usage 1 ;;
esac

__PAYLOAD__
```

## Design Decisions

### Why patchelf the binary

The binary compiled in Guix has a Guix-specific dynamic linker (`/gnu/store/.../ld-linux-x86-64.so.2`) hardcoded as its interpreter. On a Debian target, this path does not exist and the binary cannot start at all. `patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2` rewrites it to the standard Linux path. `patchelf --set-rpath '$ORIGIN/../lib/mtls-hello'` makes the binary find the vendored libraries relative to its own location, so neither `LD_LIBRARY_PATH` nor a wrapper script is needed.

This is the standard, minimal solution — one tool, two commands.

### Why `unset LD_LIBRARY_PATH` in the installer script

When the installer runs on the dev machine (inside `guix shell`), the environment has `LD_LIBRARY_PATH` pointing at Guix libs. The installer's own utilities (`sed`, `tar`, `openssl`) are host binaries that get linked against the wrong libc through this path, causing `GLIBC_2.38 not found` crashes. `unset LD_LIBRARY_PATH` at the top of the script ensures the script's utilities use the host's libraries. On a real Debian target, there is no Guix `LD_LIBRARY_PATH` to unset, so this is a no-op there.

### Why tests verify file placement, not binary execution

The installed binary runs correctly on a clean target (patchelf'd interpreter + rpath). But inside the BATS test environment, running the binary triggers glibc-hwcaps: the Guix dynamic linker loads optimized host libs from `/lib64/glibc-hwcaps/` that require a newer glibc than the Guix interpreter provides. This is a test-environment artifact, not a deployment problem. The binary's execution is already thoroughly tested by the 44 server tests that start it and make HTTPS requests. The installer tests should only verify that files are placed correctly.

### Why a template + concatenation, not a here-doc in justfile

The script template is ~90 lines with functions, subcommand dispatch, and cert generation logic. A here-doc in a justfile recipe would be unreadable. A standalone `scripts/self-extract.in` file is version-controlled, testable, and the justfile recipe only inserts the base64 payload.

### Why base64 + tar.gz, not individual base64 files

A single tar.gz payload is simpler: one extraction step. The payload is ~28MB raw, ~37MB base64-encoded — acceptable for a deployment script.

### Why no pipe-to-bash support

The script uses `$0` to refer to itself for payload extraction (`sed ... "$0"`), which works when the script is saved to a file. Piped scripts have `$0` set to `bash`, not a file path. The operator saves first: `curl -o installer.sh && bash installer.sh install`.

### Filename dirty detection

```bash
HASH=$(git rev-parse --short HEAD)
DATE=$(date +%Y%m%d)
DIRTY=""
if [ -n "$(git status --porcelain)" ]; then DIRTY="-dirty"; fi
OUT="mtls-hello-installer-${HASH}-${DATE}${DIRTY}.sh"
```
