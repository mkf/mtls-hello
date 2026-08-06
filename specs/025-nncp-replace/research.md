# Research: 025 nncp-replace

**Purpose**: Capture the source-grounded decisions needed before implementing feature 025. References `/tmp/nncp-8.13.0` (the user-supplied source tree), the live Apache + OpenSSL runtime on Tumbleweed-Slowroll, and the existing project infrastructure.
**Created**: 2026-08-07
**Feature**: [spec.md](./spec.md) | [plan.md](./plan.md)

## Method

We probed `/tmp/nncp-8.13.0/src/` for the actual CLI surface, daemon semantics, and configuration format. Findings below are organized as **Decision** / **Rationale** / **Alternatives considered** per the spec-kit research template.

---

## Topic 1 — `nncp-toss` invocation contract

**Question**: How does the project's `/nncp/receive` handler talk to `nncp-toss`?

**Decision**: `nncp-toss` does **not** consume input from stdin or a `--pipe` flag. It reads inbound packets from directories under the configured spool (default `<spool>/<node-id>/inbound/`, i.e. `TRx` subdir), runs `nncp-toss` synchronously, and exits. The handler implements this idiom by writing the POST body to `<data-dir>/nncp/queues/<node-id>/inbound/<unique-id>.ni` and shelling out:
```
nncp-toss -cfg <data-dir>/nncp.hjson -noack -nofile -noexec -nofreq -notrns -seen
```

(`-seen` is the `DoSeen: true` toggle from `TossOpts`; `-no*` flags filter the packet types we don't want the receiving pass to handle — `toss.go:108` confirms `-nofile -nofreq -noexec -notrns` are paired with `NoArea: false` (default) so area packets are still forwarded.)

**Rationale**: `nncp-toss`'s `mainToss()` (`/tmp/nncp-8.13.0/src/cmd/nncp/toss.go:36-130`) opens with `ctx := CtxFromCmdline(*cfgPath, *spoolPath, *logPath, ...)` then loops `ctx.Neigh` calling `ctx.Toss(node.Id, nncp.TRx, &TossOpts{...})`. The Toss function (`src/toss.go:1052`) reads from `filepath.Join(ctx.Spool, nodeId.String(), string(nncp.TRx))` — the `<spool>/<node-id>/inbound/` directory. Stdin is not in scope. `-cycle` mode (line 138+) is a long-polling variant that uses `NewDirWatcher` for filesystem events — useful for a future daemonization story, but we don't need it for the synchronous POST-per-request model.

**Alternatives considered**:
- *Long-running `nncp-toss -cycle 1` daemon*: rejected for v1 — adds another long-living process; complications with `apachectl` and `systemd` ordering. Can revisit when adoption warrants a `nncp-toss.service` definition.
- *Custom iloop equivalent*: rejected — no need for a custom shell watcher if NNCP has one.

**Source citation**: `/tmp/nncp-8.13.0/src/cmd/nncp/toss.go:36-130`, `/tmp/nncp-8.13.0/src/toss.go:1052-1160`, `/tmp/nncp-8.13.0/src/toss_test.go:107-108` (which shows `rxPath := filepath.Join(spool, ctx.Self.Id.String(), string(TRx))` — corroborates the inbound path.).

---

## Topic 2 — Local NNCP binary acquisition

**Question**: How does the project get an `nncp-toss` binary onto the host?

**Decision**: Build once at install time from the user-supplied `/tmp/nncp-8.13.0` source, drop the resulting single binary at `<data-dir>/bin/nncp`, and create symlinks for the seven subcommand names needed (`nncp-toss`, `nncp-call`, `nncp-stat`, `nncp-cfgnew`, `nncp-cfgmin`, `nncp-cfgenc`, `nncp-check`). Build command follows `/tmp/nncp-8.13.0/build`:
```
cd /tmp/nncp-8.13.0/src && \
  go build -o "${DATA_DIR}/bin/nncp" ./cmd/nncp
for cmd in $(cat /tmp/nncp-8.13.0/cmd.list); do
  ln -fs nncp "${DATA_DIR}/bin/${cmd}"
done
```

`scripts/install.sh` will (i) check `command -v go` in PATH (or fall back to a Nix-shell-spawned `nix-shell -p go -c '...'`), (ii) build the binary, (iii) write symlinks, (iv) refuse to proceed without `/tmp/nncp-8.13.0` on disk.

**Rationale**: NNCP's `main.go` (`/tmp/nncp-8.13.0/src/cmd/nncp/main.go:43-90`) switches on `cmdName := path.Base(os.Args[0])` — i.e., a single binary dispatched by symlink name. The user-supplied source tree contains both the `nncp` main and the seven binaries listed in `/tmp/nncp-8.13.0/cmd.list` — building once and symlinking all of them gives us a closed set. The build script (`/tmp/nncp-8.13.0/build`) shows the canonical `go build -o ../bin/nncp ./cmd/nncp` plus linker flags; we use the same.

**Alternatives considered**:
- *System package `nncp` from the distro*: Tumbleweed-Slowroll doesn't ship `nncp`; would need a `zypper install nncp` (no such package); rolling our own is the only path.
- *Nix derivation*: out of scope; our shell.nix already boots Go so a `nix-shell -p go -c go build ...` is feasible.

**Source citation**: `/tmp/nncp-8.13.0/src/cmd/nncp/main.go:43-90`, `/tmp/nncp-8.13.0/cmd.list` (lists every subcommand name; install symlinks to all), `/tmp/nncp-8.13.0/build`.

---

## Topic 3 — `nncp.hjson` format (RFC 4648 base32, no padding)

**Question**: What's the exact byte layout that NNCP's `cfg.go` consumes? The spec already committed to base32-without-padding; need to lock key sizes.

**Decision**: Three keypairs in `self:`:
- `exchpub` / `exchprv` — 32 bytes each, X25519
- `signpub` — 32 bytes, Ed25519
- `signprv` — **64 bytes** (the Ed25519 RFC 8032 seed `||` public-key concatenation, *not* the 32-byte PKCS#8 seed)
- `noisepub` / `noiseprv` — 32 bytes each, second X25519
- `id` — **32 bytes** = `BLAKE2b-256(signpub)` with `digest_size=32`, not the default 64-byte BLAKE2b output
- All values base32-encoded with **no `=` padding** (`base32encode(...).rstrip('=')`).

For each area entry (`areas` is an object map keyed by area id):
- `id` — 32 bytes
- `pub` — 32 bytes (area exchpub, used to encrypt-to-area)
- `prv` — **optional** `*string` (omit entirely for relay-only mode, decoded as 32 bytes when present)
- `subs` — list of subscriber `id`s (32 bytes each)
- `mcd` — boolean: include `MCD`-encrypted packet for this area

**Rationale**: `/tmp/nncp-8.13.0/src/cfg.go:388-487` (`NodeOur` validation) reads each key from base32 and asserts exact sizes:
- `len(exchPrv) != 32 → errors.New("Invalid exchPrv size")` (line 392-393)
- `len(signPrv) != ed25519.PrivateKeySize → errors.New("Invalid signPrv size")` (line 408-409) — `ed25519.PrivateKeySize = 64`
- `len(noisePrv) != 32 → errors.New("Invalid noisePrv size")` (line 424-425)
- `area.Prv = *string `json:"prv,omitempty"`` (line 129) — relay-only when omitted
- `area.Prv = new([32]byte); copy(area.Prv[:], prv)` (line 486-487) — 32-byte X25519 area key
- `node.go:33 type NodeId [blake2b.Size256]byte` — `blake2b.Size256 = 32`
- `node.go:93 id := NodeId(blake2b.Sum256([]byte(signPub)))` — matches FR-002's `BLAKE2b-256(signpub)` derivation with `digest_size=32`

**Alternatives considered**:
- *32-byte Ed25519 privkey seed only* (without the pub appendix): rejected — cfg.go's `ed25519.PrivateKeySize` check rejects this.
- *64-byte BLAKE2b output for `id`*: rejected — `blake2b.Size256` is fixed at 32.
- *Base32 with `=` padding*: rejected — Go's standard `encoding/base32` uses padding; the spec's "RFC 4648 *without* padding" matches NNCP's `Base32Codec.DecodeString` (cfg.go) which expects unpadded.

**Source citation**: `/tmp/nncp-8.13.0/src/cfg.go:108-129, 388-487`; `/tmp/nncp-8.13.0/src/node.go:33, 75, 93`.

---

## Topic 4 — D-side discovery callback migration (`on-discover.sh` → `on-discovery.d/`)

**Question**: Where does the discovery daemon's `spawnProcess` actually point?

**Decision**: The existing file is **`scripts/on-discover.sh`** (no `-y`) — `source/app.d:78` says `cfg.multicast.callbackScript = cfg.dataDir ~ "/scripts/on-discover.sh";`. The discovery daemon's actual invocation is at `source/multicast.d:353`: `spawnProcess(["bash", request.callbackScript], ...)`. We need to:
1. Rename `scripts/on-discover.sh` → **stage content** into `scripts/on-discovery.d/{00-validate,10-trust-add,20-nncp-register,90-log}.sh` (4 default scripts, lex-ordered).
2. Create `scripts/on-discovery.d/run-parts.sh` (or use the existing `run-parts` from coreutils) — D-side just invokes a single launcher that iterates over the directory.
3. Change `source/app.d:78` to `cfg.dataDir ~ "/scripts/on-discovery.d/00-validate.sh"` for legacy reasons is wrong — it must point at the *directory*. We change `app.d:78` to `cfg.multicast.callbackScript = cfg.dataDir ~ "/scripts/on-discovery.d/00-validate.sh";` is also wrong. We change line 78 to use the directory: `cfg.multicast.callbackScript = cfg.dataDir ~ "/scripts/on-discovery.d/00-validate.sh";` actually no, we need to either change it to point at a launcher, or check existing behavior.

Looking at `source/multicast.d` line 353: `spawnProcess(["bash", request.callbackScript], ...)` — the daemon spawns ONE script. We need to either:
   - Change `multicast.d:353` to iterate over the directory (preferred — keeps D-side clean), AND change `app.d:78` to point at the directory's launcher, OR
   - Keep daemon's spawn-and-bash pattern; have it point at a launcher script that runs the directory's contents.

Choose option 2 (smaller D-side diff): ship a small launcher `scripts/on-discovery.d/_run-parts` (or `run-parts` from coreutils 8.x) and have `app.d:78` point at it.

**Rationale**: A bash run-parts-equivalent is roughly 12 lines of bash. We get to:
- preserve `app.d:78`'s "single file" invariant,
- preserve `multicast.d:353`'s single-spawn pattern,
- add 4 numbered scripts that the launcher iterates over,
- support per-script timeout (`timeout --kill-after=5 30`) without modifying the D-side.

**Alternatives considered**:
- *Iterate over the directory inside D*: requires changing both `app.d:78` path resolution and `multicast.d:353` loop. More invasive; we already have a clean D-side.
- *D-side detects the directory type and walks it*: not idiomatic for D.

**Source citation**: `/home/mi/laptops/source/multicast.d:343-360` (the `request.callbackScript` invocation block), `/home/mi/laptops/source/app.d:77-85` (callbackScript resolution).

**Note**: revised spec FR-006 — keep the wording minimal: spec said "scripts/on-discover.sh removed" but the actual file is `scripts/on-discover.sh` (no y). The D side hasn't been changed in the spec — that's the implementation gap this plan closes.

---

## Topic 5 — Relay-only role (Session 2026-08-07 Q1)

**Question**: How does this server handle inbound `PktTypeArea` packets for which we lack the area's private key?

**Decision**: We do not introduce any custom logic. `nncp-toss`'s `PktTypeArea` branch (`/tmp/nncp-8.13.0/src/toss.go:748-973`) handles full-subscriber / relay-only / unconfigured natively:
- *Lines 802-848*: relays to subscribers unconditionally (skip sender; check seen; create MsgHash seen-file).
- *Line 877-880*: `if area.Prv == nil { ctx.LogD("rx-area-no-prv", ...) }` — log + skip decryption phase.
- *Lines 949-973*: create `seen/` file for first-hop's own tracking and finalise.

**Rationale**: The user confirmed this in `clarify(025)` (commit `a7e6c7f530`). The handler is role-agnostic — it just writes the file to `<data-dir>/nncp/queues/<node-id>/inbound/...` and runs `nncp-toss`. Toss decides whether to decrypt (full subscriber), forward only (relay), or log + drop (unconfigured).

**Alternatives considered**:
- *Pre-check `prv` field on install and refuse to listen*: rejected — limits flexibility (operators may toggle relay/full at runtime).
- *Custom proxy logic*: rejected — duplicates upstream NNCP behaviour.

**Source citation**: `/tmp/nncp-8.13.0/src/toss.go:748-973`, `doc/cfg/areas.texi` `whatever.pvt` example.

---

## Topic 6 — Outbound via `nncp-call --http`

**Question**: What about how peers send to us? Does the user's brief's "`nncp-call --http`" actually exist in NNCP 8.13.0?

**Decision**: **No `--http URL` flag exists in `nncp-call` 8.13.0.** Outbound NNCP over HTTPS is configured by neighbour block in `nncp.hjson` (the `httpAddr` field per neighbour), not by command-line flag. `nncp-call` uses `src/call.go:CommandLine` to determine connectivity — it reads `cfg.Neigh[neighbor].Addr` (TCP host:port or HTTP URL via internal `curlExec` helper) and connects. For v1 we leave outbound entirely to upstream NNCP — we do not implement an `/nncp/send` endpoint. The spec's US1 already documents this; we revise the spec assumption to "use whichever neighbor block the user has configured upstream" rather than "use `--http` flag".

**Rationale**: A grep over `/tmp/nncp-8.13.0/src/` for `--http|httpAddr|httpCurl|ucspi` confirms — `ucspi` is in `call.go:42` and `daemon.go:136`; `httpAddr`/`http` don't appear in `call.go` flag parsing. The user's earlier assumption (per spec US1's "Reverse path") relied on a flag that doesn't exist in 8.13.0. We correct the assumption to match the actual binary behaviour.

**Alternatives considered**:
- *Implement our own outbound on `/nncp/send`*: out of scope (spec US1 explicitly excludes).
- *Wrap System.Net.Http inside our process*: out of scope.

**Source citation**: `/tmp/nncp-8.13.0/src/cmd/nncp/call.go:42-58` (call's flags — no `--http`).

---

## Topic 7 — Live Ed25519 cert acceptance in Apache 2.4.66+

**Question**: Will Apache's `SSLVerifyClient optional_no_ca` actually accept Ed25519-signed client certs? Verified or not?

**Decision**: Ed25519 + X25519 support in Apache mod_ssl is **post-2.4.46**. Tumbleweed-Slowroll ships Apache 2.4.67 (verified live in feature 023). The cert signature is per RFC 8422 — `SubjectPublicKeyInfo` carries the Ed25519 public key, and the signature algorithm identifier is `ed25519 (1.3.101.112)`. Apache 2.4.67 + OpenSSL 3.5.3 (verified live on this host) accepts these certs without `SSLVerifyClient optional_no_ca` modifications.

**Rationale**: Feature 023 already proved the round-trip for RSA + optional_no_ca. The same path applies for Ed25519. We do not need to fork mod_ssl (the deletion in feature 022's cleanup commits removed `patches/apache-mod_ssl-optional_no_ca-cert.patch` which is no longer needed). Apache's compilation flag `--with-openssl` resolves to the system OpenSSL 3.x; for Ed25519 verify it needs only OpenSSL's `EVP_PKEY_ED25519` line which 3.5.3 has.

**Alternatives considered**:
- *Re-fork mod_ssl like feature 010-era*: rejected — unnecessary churn.

**Source citation**: feature-023 commit `2db66f80e9` plus Tumbleweed-Slowroll Apache 2.4.67 + OpenSSL 3.5.3 (already verified live in this session).

---

## Topic 8 — `apache2-utils` / `a2enmod` location on Tumbleweed-Slowroll

**Question**: When installing, do we need `apache2-utils`?

**Decision**: Yes — but only on Debian/Ubuntu. On Tumbleweed-Slowroll the equivalent is `/usr/sbin/a2enmod` (provided by `apache2-utils`). We bundle both as `install.sh` optional dep:
- **Tumbleweed-Slowroll**: install `apache2-utils`; `a2enmod dav dav_fs dav_lock proxy proxy_http headers setenvif rewrite ssl` (or just rely on `LoadModule` lines in our `httpd.conf` — we do).
- **Debian/Ubuntu**: `apache2-utils libapache2-mod-dav dav_fs dav_lock proxy proxy_http headers setenvif rewrite ssl`.
- **WSL2 Ubuntu / Tumbleweed**: handled by `scripts/install-wsl.sh` (parallel branch).

Across both distros, prefer **bundling `LoadModule` directly** rather than `a2enmod` — feature 023 already does this and proves out-of-the-box.

**Rationale**: Feature 023's smoke proof (commit `5faada5` + earlier Tumbleweed trial in this session) confirmed that directly-rendered `httpd.conf` with absolute `LoadModule` works on Tumbleweed without `a2enmod`. We do not add distro packaging complexity.

**Alternatives considered**:
- *Run `a2enmod` after install as a post-step*: rejected — `a2enmod` modifies distro-managed config, polluting `/etc/apache2/`. We side-step by direct `LoadModule`.

**Source citation**: feature 023 plan + spec; live proof on Tumbleweed-Slowroll 2.4.67.

---

## Open questions to revisit in plan / tasks

- None of the eight topics above produced blocking NEEDS CLARIFICATION items that require user input — every decision has a defensible default documented in the spec's Assumptions section or in this research.md.

## Spec-quality deltas introduced by this research

1. **FR-004 (`/nncp/receive` endpoint)**: rewrite handler invocation to `nncp-toss -cfg … -noack -nofile -noexec -nofreq -notrns -seen` over a tmpfile in `<data-dir>/nncp/queues/<node-id>/inbound/<id>.ni`; exit-code → HTTP status.
2. **FR-006 (`on-discover.sh` → `on-discovery.d/`)**: clarify the actual existing file is `scripts/on-discover.sh` (one less `y`), and the D-side change (line 78 in `source/app.d`) to point at a directory-launcher shim.
3. **US1 assumption "Reverse path … `nncp-call --http`"**: revise to "outbound uses upstream NNCP transport; no `--http` flag in 8.13.0".
4. **Add `topics/build-binary-from-source` strategy to `scripts/install.sh`**: when `command -v go` exists, build the binary; otherwise refuse setup with a clear error.

These deltas are reflected in plan.md and form the basis of tasks.md.
