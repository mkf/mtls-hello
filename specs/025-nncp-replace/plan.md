# Implementation Plan: 025 nncp-replace

**Branch**: `main` | **Date**: 2026-08-07 | **Spec**: ../025-nncp-replace/spec.md

**Input**: Feature specification from `/home/mi/laptops/specs/025-nncp-replace/spec.md`

**Note**: This template was filled in by the `/speckit.plan` command.

## Summary

Replace the standalone `nncp-caller` daemon with a web-native flow on our existing Apache+mTLS infrastructure. Four intertwined changes (largely keeping the spec's wording):

1. **Keypair unification** — drop RSA-2048 for our identity cert in favour of Ed25519 (signing) + X25519 (ECDH) + a dedicated second X25519 (NNCP noise). The same three keypairs are written to `<data-dir>/nncp.hjson`'s `self:` block in NNCP's raw format (base32-32 / base32-64 / base32-32 / base32-32, with `id = BLAKE2b-256(signpub)` as the canonical 32-byte digest).
2. **`/nncp/receive` endpoint** — new Apache POST handler `handlers/nncp-receive.post.sh` writes the body to `<data-dir>/nncp/queues/<node-id>/inbound/<id>.ni` and shells out `nncp-toss -cfg <data-dir>/nncp.hjson -noack -nofile -noexec -nofreq -notrns`. nncp-toss's exit code is the HTTP response status; exit-0 → 202-Accepted, non-zero → 5xx with stderr as body.
3. **`on-discover.sh` → `on-discovery.d/`** — directory of numbered scripts invoked in lex order with the same env vars as the existing `scripts/on-discover.sh`. The D discovery daemon (`source/multicast.d:353`) is updated to spawn `bash ` + each phase, with `set -o pipefail` and a 30 s per-script timeout via `timeout --kill-after=5 30`.
4. **Auto-discovery integration** — `00-validate.sh` sanity-checks; `10-trust-add.sh` adds the peer's mTLS cert to `<data-dir>/hosts/`; `20-nncp-register.sh` adds a `neigh:` entry to `nncp.hjson`; `90-log.sh` writes one line to `<data-dir>/discoveries.log`. **Relay-only role (added per Q1, session 2026-08-07)** — `nncp-toss`'s `PktTypeArea` branch (`/tmp/nncp-8.13.0/src/toss.go:802-973`) natively distinguishes full-subscriber / relay-only / unconfigured; the handler stays role-agnostic.

Plus one install-side addition: build `nncp`'s single-binary output from `/tmp/nncp-8.13.0/src/cmd/nncp` (via `go build`) and symlink the seven subcommand names the project needs (nncp-toss, nncp-call, nncp-stat for sanity, nncp-cfgnew for keygen, and three more — `cmd.list` drives this).

## Technical Context

**Language/Version**:
- D 1.27.x (Nix-shell-pinned, for the discovery daemon in `source/app.d` + `source/multicast.d` + `source/trust.d`)
- bash 5.x (handlers/scripts)
- Apache httpd 2.4.66+ with mod_ssl + mod_dav + mod_cgi + mod_rewrite + mod_proxy_http + mod_headers + mod_setenvif (verified live on Tumbleweed-Slowroll 2.4.67; mod_dav, mod_ssl, mod_cgi all available — see feature 023's spec for migration history)
- OpenSSL 3.5.x with Ed25519 + X25519 (verified live: `openssl list -public-key-algorithms | grep -E 'ED25519|X25519'` returns both)
- Go 1.21+ (NNCP 8.13.0 build, source at `/tmp/nncp-8.13.0`)
- Python 3.x (in `scripts/version.py`, optionally used for tests; not a build dep)

**Primary Dependencies**:
- Apache httpd 2.4.x (live-validated Tumbleweed-Slowroll 2.4.67)
- `apache2-utils` for `a2enmod` (only needed for Apache 2.4 on Debian; on Tumbleweed-Slowroll `a2enmod` lives in `/usr/sbin/` not /usr/bin — need to find at install time)
- OpenSSL 3.0+ with Ed25519 + Curve25519 (`feature 010` cert shape)
- NNCP 8.13.0 source tree at `/tmp/nncp-8.13.0` — build pipeline: `cd /tmp/nncp-8.13.0/src && go build -o ../bin/nncp ./cmd/nncp && cd ../bin && for cmd in $(cat ../cmd.list); do ln -fs nncp $cmd; done`. Resulting binary is single, ~7 MB.
- existing project infrastructure: feature 010 (self-signed certs), 017 (native cert detection), 022 (flat layout), 023 (drop-box + per-host trust + Apache mod_dav VH), 008 (wire discovery callback via `scripts/on-discover.sh`)

**Storage**:
- `<data-dir>/identity/<cn>.crt` (X.509 Ed25519 cert) + `<data-dir>/identity/<cn>.key` (PKCS#8 PEM)
- `<data-dir>/nncp.hjson` (`self:` + `neigh:` + per-area entries; new). NNCP's base32-without-padding encoding; area `Prv:` is `*string`, optional, omitting it = relay-only mode per `/tmp/nncp-8.13.0/src/cfg.go:129`.
- `<data-dir>/hosts/<cn>.crt` (peer mTLS certs; existing; populated by `10-trust-add.sh`)
- `<data-dir>/bin/{nncp,nncp-toss,nncp-call,nncp-stat,nncp-cfgnew,...}` (symlinks to single NNCP binary; new)
- `<data-dir>/nncp/{queues,incoming,seen,ack,area}/` (NNCP's runtime directories; new)
- `<data-dir>/on-discovery.d/{00,10,20,90}-*.sh` (default scripts; new)
- `<data-dir>/apache/{httpd.conf,site.conf,dav-lockdb}` (modified to register `/nncp/receive` ScriptAlias)
- `<data-dir>/discoveries.log` (used by `90-log.sh`)
- `<data-dir>/run/discovery-paused` (existing, from feature 008/019)

**Testing**:
- bats 1.13.0 (existing) — new file `tests/nncp-replace.bats`
  - `gen-keys.sh` produces 32-byte X25519 scalars + 64-byte Ed25519 priv (per the spec's FR-002 fixed-width encoding rule)
  - `<data-dir>/nncp.hjson` round-trips through NNCP's `nncp-cfgnew` and `nncp-cfgmin` CLI
  - `on-discovery.d/{00,10,20,90}-*.sh` per-script behaviour; idempotency across reduced scripts
  - Lex-order invocation: dropping `50-my.sh` is honoured, without re-running others
- Robot Framework (existing) — new file `robot/nncp-replace.robot` (subset: discovery → mtls-receive → spool assertions; outbound via `nncp-call` is OUT OF SCOPE).
- Live two-host smoke — at least one curl PUT roundtrip + PROPFIND + GET, on the existing 'drop-box + new nncp-receive endpoint'.

**Target Platform**:
- Primary: Linux server (already running on Tumbleweed-Slowroll 20260504 in CI).
- WSL2 supported via feature 024 (parked); same project applies because WSL2's Linux VM abstracts the host ISA — one `linux-gnu` binary runs on both `x86_64-linux-gnu-wsl2` and `aarch64-linux-gnu-wsl2` (per spec FR-010).

**Project Type**:
- Web-service (Apache + CGI handlers) + standalone CLI for identity-gen helpers + standalone binary launcher (NNCP binary execution).

**Performance Goals**:
- SC-002: NNCP packet from `curl POST https://host:8443/nncp/receive` lands in `<data>/nncp/queues/<node-id>/inbound/` and is processed by `nncp-toss` within 5 s (return 202-202). Verified live before commit.
- SC-001 / SC-003 / SC-004: existing performance baseline for mTLS + discovery endpoints (unchanged).

**Constraints**:
- 30-second per-script timeout in `on-discovery.d/` (FR-015 from spec).
- Legacy RSA coexist for one release (US5 from spec); install script provides the `--import-legacy-rsa <path>` flag for upgrade path.
- **Safety rule**: never introduce `rm -rf` / `rm -f` / `rm -r` / `find -delete` — use anchored globs + `rmdir` only (feature 022 rule).
- **No system-wide changes by default** — install into `<data-dir>/` + user's `~/.local/bin/`.
- Apache config additions must respect existing `<Directory>` semantics (no inadvertent open scope).

**Scale/Scope**:
- ~6 modified files + 4 new default hook scripts + 1 new handler + 1 new storage layout under `<data-dir>/nncp/`, plus 1 new END-TO-END smoke test script. Roughly the same implementation footprint as feature 023.

## Constitution Check

*GATE: must pass before Phase 0 research. Re-check after Phase 1 design.*

The project's `.specify/memory/constitution.md` is **still the spec-kit placeholder template** — `[PRINCIPLE_1_NAME]`, `[SECTION_2_NAME]`, etc., are unrendered. No substantive principles have been ratified yet. The plan therefore applies these de-facto project gates inferred from features 010, 017, 018, 022, 023 history:

| # | Gate | Status |
|---|---|---|
| G1 | No `rm -rf` / `rm -f` / `rm -r` / `find -delete` in new code (feature 022 safety rule); anchored globs + `rmdir` only. | Pass — coding-style note (no install path does `rm -f $foo`; use plain `rm -- <file>` and `rmdir <empty-dir>`) |
| G2 | Idempotent install — `scripts/install.sh` and `scripts/install-wsl.sh` can run twice without breaking state. | Pass — `mkNNCPBinaries()` is idempotent (skip-if-symlink-present); `scripts/inNNCP.hjson` is rewrite-in-place via tempfile + atomic rename; `scripts/on-discovery.d/` accepts existing script drops |
| G3 | Self-signed identity, no CA infrastructure (feature 010). | Pass — Ed25519 self-signed certs are the new shape |
| G4 | No system-wide changes by default; `--all-users` opt-in flag. | Pass — `scripts/install.sh` keeps existing semantics |
| G5 | Cryptographic integrity on key rotation; legacy material preserved | Pass — RSA compat in US5; Ed25519+Curve25519 default for new installs; `--import-legacy-rsa` flag preserves old key material |
| G6 | Open-source Apache + `mod_dav` architecture (features 018/023). | Pass — new endpoint registered alongside `/drop`, etc. |
| G7 | CGI handler conventions per HTTP method (`handlers/<name>.<method-lowercase>.sh`) per feature 023. | Pass — `handlers/nncp-receive.post.sh` |
| G8 | Discovery env vars are backward-compatible between `on-discover.sh` and the new `on-discovery.d/`. | Pass — same `HOST_NAME`, `PEER_NETLOC`, `PEER_CERT_FILE`, `OUR_CERT`, `OUR_KEY`, `REPOS_ROOT` env (plus three NNCP-specific ones: `PEER_NNCP_ID`, `PEER_SIGNPUB`, `PEER_EXCHPUB`) |
| G9 | Template variable hardening (per feature-023's spec): all `{{...}}` placeholders in `config/apache-site.conf.in` must be substituted before Apache loads the file. | Pass — `scripts/apache-config.sh` already substitutes the existing set; we add `{{NNCP_DIR}}` substitution |
| G10 | No `apachectl -k graceful` calls in install scripts. | Pass — install invokes `apachectl -t` (test config) and never restarts live |

If a real constitution is ratified in the future, these de-facto gates should be migrated to `.specify/memory/constitution.md` proper. Until then this plan continues to respect them.

No constitution violations. Proceed to Phase 0.

## Project Structure

### Documentation (this feature)

```text
specs/025-nncp-replace/
├── plan.md              # this file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── handler-nncp-receive.md
│   ├── on-discovery-d-env.md
│   └── nncp-hjson-format.md
├── spec.md              # already produced
├── tasks.md             # /speckit.tasks output (will be produced next)
└── checklists/
    └── requirements.md  # already produced
```

### Source Code (repository root)

```text
handlers/
└── nncp-receive.post.sh   # NEW: POST /nncp/receive

scripts/
├── gen_certs.sh           # NEW: Ed25519+X25519 keygen + nncp.hjson-format output (with --import-legacy-rsa)
├── install.sh             # MODIFIED: invoke new keygen + write nncp.hjson + build/symlink NNCP binary + create on-discovery.d/
├── install-wsl.sh         # PARALLEL branch MOD: same as install.sh, for WSL
├── apache-config.sh       # MODIFIED: register /nncp/receive ScriptAlias; substitute {{NNCP_DIR}}
├── on-discover.sh         # DELETE: replaced by on-discovery.d/ + D source line 78 updated
├── on-discovery.d/        # NEW directory
│   ├── 00-validate.sh
│   ├── 10-trust-add.sh
│   ├── 20-nncp-register.sh
│   └── 90-log.sh
├── build-nncp.sh          # NEW: go build from /tmp/nncp-8.13.0
└── cleanup-common.sh      # (no change)

cli/
└── (no new CLI for 025)

robot/
├── MtlsLibrary.py         # EXTENDED: NNCP-aware keywords
└── nncp-replace.robot     # NEW

tests/
└── nncp-replace.bats      # NEW: keygen + hjson formatting + on-discovery.d scripts

source/
├── app.d                  # MODIFIED: line 78 — call `on-discovery.d/00-validate.sh` etc. (or single bash with run-parts)
├── multicast.d            # MODIFIED: line 353 invocation pattern — use run-parts with timeout
└── trust.d                # (no change; upstream Ed25519 detection already lives here)

config/
└── apache-site.conf.in    # MODIFIED: ScriptAlias /nncp/receive handlers/nncp-receive.post.sh/

.gitignore                # MODIFIED: ignore /tmp/nncp-* build artifacts (developer-machine only)
README.md                 # MODIFIED: add Per-Host Drop-Box / mTLS / NNCP cross-reference
```

**Structure Decision**: Single project (Option 1). The feature is web-service + bash scripts + test artifacts, fits the existing `laptops` repo structure. No new top-level directories.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| (none) | — | — |

No constitution violations.
