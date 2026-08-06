# Feature Specification: Replace nncp-caller with our mTLS Endpoint

**Feature Branch**: `025-nncp-replace`

**Created**: 2026-08-07

**Status**: Draft

**Input**: User description:
> after considering the following, please devise a feature where we, with our server and discovery, essentially replace nncp-caller — and also we make our keys, after switching away from RSA for our keys, secondarily double-used as nncp keypairs. You have the whole nncp source tarball extracted at /tmp/nncp-8.13.0

Follow-up refinement (same turn):
> it would be a special new endpoint and auto-discovery feature. BTW, we would also transform the on-discovery.sh into an on-discovery.d/ for easier management of that script.

## Architectural Summary

Four intertwined changes, all building on features 010 (self-signed certs), 017 (native cert detection), 022 (flat layout), 023 (drop-box + per-host trust), 008 (wire discovery callback), and 016 (bundle spooling) as foundations:

1. **Keypair unification**: mtls-hello's identity cert generation drops RSA-2048 in favour of **Ed25519** for signing + **X25519** for ECDH. The same three keypairs (signpub, exchpub, and a second X25519 for noise) are **also** written out in NNCP's raw key format (`<data-dir>/nncp.hjson`, `self:` block). One rotation, two systems.
2. **NNCP-tosser replacement endpoint**: a new Apache endpoint at `/nncp/receive` accepts NNCP-format outer-encrypted packets over the same mTLS + per-host trust gate as feature 023, and pipes them to the existing `nncp-toss` binary (from the NNCP 8.13.0 source tree at `/tmp/nncp-8.13.0`). No `nncp-caller` daemon needs to be running.
3. **Auto-discovery integration**: extending feature 008, every newly-discovered peer is auto-registered as both an mTLS host **and** an NNCP neighbor (if their NNCP public keys can be exchanged). Peer's BLAKE2b-256(signpub) becomes the bridge: an mTLS-trusted host whose NNCP keys map to that ID gets full integration; otherwise mTLS-only or NNCP-only.
4. **`on-discovery.sh` → `on-discovery.d/`**: the single callback script in `scripts/on-discovery.sh` is replaced by a directory of numbered scripts in `scripts/on-discovery.d/` invoked in lexicographic order. Per-script timeout, drop-in extensibility, no central coordinating logic.

**Why replace `nncp-caller`**: `nncp-caller` runs a TCP/UDP loop expecting many concurrent encrypted sessions; on the LAN/multicast use cases mtls-hello already serves, it's a wasted standalone process. Routing NNCP packets through our existing mTLS tunnel (which we already have open, authed, and trust-gated per-host) gives us the same end-to-end confidentiality with one fewer daemon.

**Why double-use the keys**: NNCP's `id` is `BLAKE2b-256(signpub)`. Our mTLS cert contains an Ed25519 signpub. Same key → same identity → no awkward key-bridging layer, no fingerprint-mapping table; the trust gate naturally cooperates with the NNCP ID.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Auto-discovered peer gets NNCP receive enabled (Priority: P1)

A peer that we discover over multicast is now automatically both mTLS-trusted *and* registered as an NNCP neighbor. From the moment discovery fires, the peer can send us NNCP packets via `/nncp/receive` — no manual config editing.

**Why this priority**: This is the core "replace nncp-caller" promise. Without auto-registration the user has to maintain the equivalent of an `nncp.hjson` neigh: block by hand, defeating the point.

**Independent Test**: With two paired hosts (A and B), both running feature 023 + this feature: kill all curl daemons, restart discovery on A. Within 5 s of A's `on-discovery.d/20-nncp-register.sh` returning, B can fire `nncp-call --http https://<A's FQDN>:8443/nncp/receive <A's NNCP id> file.bin` and have the file land in A's `nncp` spool.

**Acceptance Scenarios**:

1. **Given** host A is configured and running, **When** multicast discovery picks up B's announcement for the first time, **Then** within 2 s A's `<trust_dir>/<B's cn>.crt` exists AND A's `<data-dir>/nncp.hjson` includes a `neigh:` entry referencing B's id, exchpub, signpub and (optionally) noisepub.
2. **Given** A has just auto-registered B, **When** B issues `nncp-call --http https://<A>:8443/nncp/receive <A-id> test.bin`, **Then** `test.bin` lands in A's NNCP spool within 5 s and `nncp-toss` exits 0.
3. **Given** A has B already auto-registered, **When** a second multicast announcement from B arrives, **Then** A's neighbor list is unchanged (idempotent) and the file system timestamp on `<trust_dir>/<B>.crt` is unchanged.

### User Story 2 — Cross-host NNCP packet via mTLS (Priority: P1)

A peer that knows our mTLS+HTTPS posture and our NNCP id sends an NNCP packet directly to `/nncp/receive`. The packet is enveloped in our mTLS session, decrypted, and handed to `nncp-toss` exactly as if it had arrived via `nncp-caller`.

**Why this priority**: This is the second half of "replace nncp-caller". Without it, the system still needs `nncp-caller`.

**Independent Test**: With both A and B's `nncp.hjson` configured, run on B: `nncp-call --http https://<A>:8443/nncp/receive <A-id> file.bin --pipe <(head -c 1024 /dev/urandom)`. After 10 s, `file.bin` should exist in A's spool. Run the same call via the alternate path `nncp-call --tcp <A>:5400` (with `nncp-caller` running) on a fresh A — both paths must produce identical spool contents and identical MsgHash.

**Acceptance Scenarios**:

1. **Given** A's `/nncp/receive` is reachable over mTLS, **When** B POSTs an NNCP-encrypted packet to it, **Then** the inner packet is tossed and A's NNCP spool gains the file within 5 s.
2. **Given** an NNCP packet is addressed to A (inner), **When** the outer is encrypted to B as first-hop, **Then** B (`nncp-toss`) can re-route and our `<receiver>` gets the file as expected (verified by the standard 2-hop test from the NNCP test suite).
3. **Given** an unknown peer X (not in A's trust list) POSTs to `/nncp/receive`, **When** the request reaches Apache, **Then** A returns 401 (existing per-host trust gate from feature 023 applies unchanged).

### User Story 3 — One keygen, two identities (Priority: P1)

A single key generation operation produces THREE keypairs that simultaneously satisfy (a) mtls-hello's mTLS identity and (b) NNCP's three-keypair node format.

**Why this priority**: The user explicitly wants key reuse. Without it we have two unrelated identity stores (one for mtls-hello, one for NNCP), and the cross-validation in US1's "trust ↔ neighbor" linkage is not cryptographic.

**Independent Test**: On a fresh install, run `scripts/gen-keys.sh` and capture the three keypairs. Pass the same files through both `openssl x509 -in <cert> -noout -text` (should list Ed25519 + X25519 in the cert and use them for signing/ECDH) and through `bin/nncp-node-show --self <data-dir>/nncp.hjson` (should show exchpub/signpub matching the cert's keys and id matching BLAKE2b-256 of the cert's Ed25519 signpub).

**Acceptance Scenarios**:

1. **Given** a fresh `scripts/gen-certs.sh` run, **When** keys are produced, **Then** `<data-dir>/identity/<cn>.{crt,key}` contains an Ed25519-signed X.509 cert with X25519 ECDH capability, *and* `<data-dir>/nncp.hjson` containing the same three NNCP-format keys (id/exchpub/signpub/(noisepub)).
2. **Given** the cert's Ed25519 signpub, **When** we compute `id = BLAKE2b-256(signpub)` (32-byte digest), **Then** it matches the `self.id` field in `<data-dir>/nncp.hjson` exactly.
3. **Given** the cert's X25519 ECDH public key, **When** the same X25519 scalar is exposed as NNCP `exchpub`, **Then** a peer encrypting a packet to that `exchpub` and posting the inner packet to `/nncp/receive` will be decryptable by us.

### User Story 4 — `on-discovery.sh` becomes `on-discovery.d/` (Priority: P2)

Existing `scripts/on-discovery.sh` (a single script, currently runs a comprehensive flow) is replaced by a directory of numbered scripts under `scripts/on-discovery.d/`. Each is invoked in lexicographic order, with a per-script timeout. Adding/removing/replacing hooks is "drop a file in".

**Why this priority**: Auto-discovery runs every time we find a peer; with feature 023's strict trust gate and feature 008's existing on-discovery, that flow is now multiple discrete concerns (trust validation, NNCP registration, logging, alerting). A single script with `if/then` chains does not scale; a directory of well-named scripts does.

**Independent Test**: Start with the four default scripts `00-validate.sh`, `10-trust-add.sh`, `20-nncp-register.sh`, `90-log.sh`. Drop a fifth script `15-trust-notify.sh` that sends a toast notification. Re-run discovery against a fresh peer; assert the new script fires *after* `10-*` and *before* `20-*` and *before* `90-*`.

**Acceptance Scenarios**:

1. **Given** `scripts/on-discovery.sh` has been removed and `scripts/on-discovery.d/` exists with the four default scripts, **When** a peer is newly discovered, **Then** each numbered sub-script runs in lex order, each receives the same env vars as the old `on-discovery.sh`, and each terminates within 30 s.
2. **Given** a hung `on-discovery.d/15-*.sh`, **When** its 30 s timeout fires, **Then** the outer discovery process logs `timeout` and continues to `20-*.sh` and `90-*.sh` (one script cannot block the others).
3. **Given** a user wants to add their own hook, **When** they drop `scripts/on-discovery.d/50-my-custom.sh`, **Then** the next discovery event invokes it without any other change.

### User Story 5 — Backward compat with RSA-based legacy installs (Priority: P3)

An existing mtls-hello install with an RSA-2048 identity cert (from features 010..022) is not broken by this feature. New certs use Ed25519/X25519; existing certs keep working until rotated.

**Why this priority**: Avoid breaking 24+ feature's existing trust stores when the project switch fires. Important but not the headline.

**Independent Test**: Take a backup of an existing RSA-based `<data-dir>/identity/<cn>.{crt,key}`; install this feature on a fresh host with the same layout; verify the legacy RSA cert still validates via `openssl verify` and accepts an mTLS client connection (`curl --cert ... --cacert ... https://<host>:8443/` returns 200). New files `<data-dir>/nncp.hjson` is empty (because legacy RSA key has no NNCP equivalents) and `/nncp/receive` returns 501 with a clear "key rotation required" message.

**Acceptance Scenarios**:

1. **Given** an existing RSA-2048 identity cert, **When** this feature is installed, **Then** mTLS / drop-box / discovery continue to function without code changes (feature 023 already runs against RSA).
2. **Given** an existing RSA-2048 identity cert, **When** the user opts into key rotation, **Then** a backup of the old key material is written to `<data-dir>/identity-legacy-<timestamp>/`, the new Ed25519/X25519 material is generated, and the new `<data-dir>/nncp.hjson` is populated.

### Edge Cases

- **NNCP binary missing**: `/nncp/receive` exists in Apache config but returns 501 with body "nncp-toss binary not found at /path/to/nncp-toss". The rest of mtls-hello runs unaffected; spec **does not** fail.
- **Peer has only an mTLS cert, no NNCP public keys**: discovery adds them to `<trust_dir>/<cn>.crt` (file 10-trust-add.sh) but `20-nncp-register.sh` exits silently with no NNCP neighbor registration (we don't have the keys). `/nncp/receive` rejects their NNCP packets with 401 (no neigh: entry) but their mTLS PUTs/file transfers work as before.
- **Peer has only NNCP public keys, no mTLS cert**: discovery gracefully fails to migrate them — discovery requires an mTLS cert (the trust gate is mTLS-only).
- **Restore from a backup with stale `<data-dir>/nncp.hjson` counters**: stale `neigh:` entries pointing to peers that have rotated their NNCP keys are flagged in `90-log.sh` with a warning at discovery; not auto-removed (user decision).
- **Multiple concurrent discoveries of the same peer**: the per-peer discovery callback is idempotent — `<trust_dir>/<cn>.crt` is `cp`-replace, `nncp.hjson neigh:` is updated atomically (write-temp + rename).
- **Discovery is for our own identity**: skip; `00-validate.sh` exits 0 without doing anything.
- **Script timeout**: per-script timeout defaults to 30 s. `on-discovery.d/listener` only runs scripts that haven't timed out already.
- **NNCP version mismatch**: if installed `nncp-toss` is < 8.13.0, surface a warning toast on first use and proceed with best-effort. If it's incompatible (e.g., preamble mismatch), `/nncp/receive` returns 501.
- **The new endpoint probes before mTLS auth**: Apache's SSLVerifyClient happens during the TLS handshake; NNCP-endpoint trust gate happens *after* TLS — meaning a non-trusted peer gets 401 (not via Apache `Require` but via the proxy handler we already use in feature 023). To avoid leaking, we do NOT add a `<Location /nncp/receive>` marker that would respond with 403 before TLS handshake; instead, Apache `SSLVerifyClient optional_no_ca` (feature 018) accepts the handshake, and the handler returns 401.
- **Ed25519/X25519 availability on the host**: OpenSSL < 1.1.0 doesn't support them; the install script refuses to proceed if the local OpenSSL doesn't report them in `openssl list -public-key-algorithms`.

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001 (cert keypair unification)**: `scripts/gen-certs.sh` (or its replacement, used by `scripts/install.sh` and `scripts/install-wsl.sh`) is updated to generate identity material using Ed25519 (signing, RFC 8422) + X25519 (ECDH, RFC 8446 named_group) instead of RSA-2048. The cert structure remains X.509v3 self-signed (per feature 010) with `CN=<hostname>`, `extendedKeyUsage = serverAuth, clientAuth`, and the cert's signing key is Ed25519 (the cert is signed by Ed25519 and includes the Ed25519 public key in `SubjectPublicKeyInfo`).
- **FR-002 (NNCP-compatible raw keys)**: From the same three keypairs as FR-001 (sign Ed25519 + exch X25519 + a dedicated second X25519 for noise), extract the raw 32-byte scalars/pubs in NNCP format and write `<data-dir>/nncp.hjson` (`self:` block). Encoding: **RFC 4648 base32 *without* padding** (`base32encode(...).rstrip('=')`). Ed25519 private key in NNCP format is `seed(32) || public(32) = 64 bytes`, not the PKCS#8 DER/PEM seed alone. Id format: `BLAKE2b-256(signpub)` with `digest_size=32`, not the default BLAKE2b digest size.
- **FR-003 (`<data-dir>/nncp.hjson`)**: At install time, write `<data-dir>/nncp.hjson` containing at minimum the `self:` block with `id`, `exchpub`, `signpub`, `signprv`, `exchprv`, `noisepub`, `noiseprv`. The file is hjson-compatible (the same parser NNCP uses), and matches the format exposed by `bin/nncp-node-show`. Empty `neigh:` block by default; populated by `20-nncp-register.sh`.
- **FR-004 (`/nncp/receive` endpoint)**: A new Apache endpoint registered alongside `/bundle`, `/spool`, `/hello` etc. via `scripts/apache-config.sh` site.conf includes. Method: POST. Body: NNCP-encrypted outer packet bytes. Trust gate: existing per-host mTLS gate from feature 023 (`SSL_CLIENT_CERT` fingerprint match against `<trust_dir>/<cn>.crt`). Handler (`handlers/nncp-receive.post.sh`): writes the body to a temp file, invokes `nncp-toss --pipe --id <our_id> <tmpfile>`, and returns the bytes from `nncp-toss`'s stdout.
- **FR-005 (cross-validation via peer CN = NNCP id)**: When `nncp-receive.post.sh` processes a packet, it inspects the URL prefix against `SSL_CLIENT_S_DN_CN` — the URL prefix must equal the verified CN. If a peer puts one CN in their cert and a different "first-hop id" in the URL, the handler returns 403. This enforces the same per-host namespace rule feature 023 enforces for `/drop/<cn>/<rest>`, applied here to `/nncp/receive/<cn-id>/<rest>` format if the packet-side ever wants URL-encoded dispatch (default is just `/nncp/receive` with the whole packet body).
- **FR-006 (`on-discovery.sh` → `on-discovery.d/`)**: `scripts/on-discovery.sh` is removed. `scripts/on-discovery.d/` is created as a directory. The discovery daemon invokes `run-parts <data-dir>/on-discovery.d/` (or equivalent) with the same env vars input as the old `on-discovery.sh`: peer CN, peer address, peer cert fingerprints (sign/exch/noise), peer NNCP public keys (signpub, exchpub, id), peer state (`new`/`updated`). Each numbered script runs in lex order; per-script timeout 30 s.
- **FR-007 (`on-discovery.d/00-validate.sh`)**: Sanity checks — refuse to fire rest of the chain if any of: peer CN is empty, peer's mTLS cert fingerprint is empty, peer equals self. Exits non-zero on validation failure; scripts after it do not run.
- **FR-008 (`on-discovery.d/10-trust-add.sh`)**: Adds (or replaces) `<trust_dir>/<cn>.crt` with the peer's mTLS certificate. Idempotent — replace, not append.
- **FR-009 (`on-discovery.d/20-nncp-register.sh`)**: Adds (or updates) a `neigh:` entry for the peer in `<data-dir>/nncp.hjson`, including the peer's `id` (BLAKE2b-256 of their signpub), `exchpub`, `signpub`, and (if provided by the peer) `noisepub`. Idempotent.
- **FR-010 (`on-discovery.d/90-log.sh`)**: Writes a one-line summary of the discovery event to `<data-dir>/discoveries.log` with timestamp, peer CN, NNCP id, and which sub-scripts ran.
- **FR-011 (backward compat with RSA)**: The key-rotation script preserves any existing RSA-based `<data-dir>/identity/<cn>.{crt,key}` files; they remain valid for mTLS via the existing OpenSSL RSA verifier. New installs use Ed25519/X25519 by default.
- **FR-012 (graceful degradation when NNCP tooling is absent)**: If `nncp-toss` (or its designated path via `<data-dir>/config.toml` `nncp-toss-path`) is not on disk or fails to launch, `/nncp/receive` returns 501 with body `nncp integration disabled: nncp-toss not found at <path>`. Other endpoints (mTLS, drop-box, discovery) continue to function.
- **FR-013 (auto-fetch peer's NNCP metadata via mTLS)**: New endpoint `GET /nncp/info` (same mTLS trust gate) returns the peer's view of *our* NNCP keys, plus, if the peer's `nncp.hjson` is reachable, theirs too. Pure metadata — no packet content goes through this endpoint.
- **FR-014 (no outbound NNCP via mtls-hello)**: The `nncp-call` outbound path remains NNCP's own transports. We do not implement an outbound `/nncp/send` endpoint. (Out of scope; documented for clarity.)
- **FR-015 (per-script timeout in on-discovery.d/)**: `run-parts` (or equivalent wrapper) enforces a 30 s timeout per script. Scripts that exceed it are killed, the failure logged, and the chain continues.

### Key Entities

- **Identity cert + raw keys**: `<data-dir>/identity/<cn>.crt` (X.509 with Ed25519 signpub + X25519 ECDH pub) + `<data-dir>/identity/<cn>.key` (PKCS#8 PEM). Three logically-distinct keypairs: Ed25519 (signing) + X25519 (ECDH, reused as NNCP `exchpub`) + X25519 (NNCP `noiseprv`/`noisepub`).
- **NNCP hjson**: `<data-dir>/nncp.hjson` — hjson-compatible, contains `self:` (id + raw keys + cert fingerprint) and `neigh:` (per-peer entries from discovery).
- **NNCP id**: `BLAKE2b-256(signpub)` with `digest_size=32`. Encoding for human-readable: RFC 4648 base32 without padding.
- **`on-discovery.d/` directory**: lex-ordered numbered scripts, each receiving the standard env. Runs on every discovery event.
- **Trust store** (unchanged from feature 023): `<trust_dir>/<cn>.crt`. Fingerprint match remains the mTLS gate.
- **NNCP-toss pipe contract**: stdin/stdout, expected exit codes (0 = tossed; 1 = packet error; 2 = storage error).

---

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001 (keypair unification)**: A fresh `scripts/install.sh` produces a `<data-dir>/nncp.hjson` whose `self.id` equals the BLAKE2b-256-32 of the Ed25519 public key inside the cert. The same install produces a working mTLS cert usable with `curl --cert ... https://<host>:8443/drop/<cn>/x`. One install — two working identities.
- **SC-002 (NNCP packet receive)**: A peer with a known id can `nncp-call --http https://<host>:8443/nncp/receive <id> file.bin` (file.bin ≥ 256 bytes content) and the same 256 bytes appear in our `<data-dir>/nncp/spool/.../` within 5 s of the call returning. **Cert path and TCP path** (with `nncp-caller` running) deliver byte-identical contents.
- **SC-003 (auto-registration on discovery)**: When a peer advertises itself via multicast for the first time, our discovery daemon calls `on-discovery.d/00-validate.sh` then `10-trust-add.sh` then `20-nncp-register.sh` then `90-log.sh` in that order, each within 30 s, total discovery-to-spool-ready time ≤ 2 s. Subsequent discoveries of the same peer are idempotent (no duplicate `neigh:` entries, no redundant `<trust_dir>` writes).
- **SC-004 (on-discovery.d/ extensibility)**: Adding a new hook (`scripts/on-discovery.d/50-my-hook.sh`) requires zero changes to existing scripts; the new hook fires on the next discovery event in the right lexicographic position. Removing a hook is "drop the file".
- **SC-005 (legacy RSA survive)**: Existing installs with RSA-2048 identity certs continue to operate end-to-end (mTLS PUT/GET, discovery, drop-box) without any code change. New `<data-dir>/nncp.hjson` is empty for legacy installs; `/nncp/receive` returns 501 with a "rotation required" message until rotation.
- **SC-006 (graceful NNCP absence)**: With `nncp-toss` removed from PATH after install, `/nncp/receive` returns 501, mTLS endpoints unaffected, drop-box unaffected, discovery unaffected.

---

## Assumptions

- **NNCP source available**: `/tmp/nncp-8.13.0` contains the NNCP 8.13.0 source tree. We will build/reference `nncp-toss` from it. If a system NNCP package is available (`zypper install nncp` or apt equivalent), we use that instead; both produce a binary that speaks the wire protocol.
- **OpenSSL 3.0+** with Ed25519 + X25519 enabled in the local OpenSSL. We verify via `openssl list -public-key-algorithms | grep -E '(ED25519|X25519)'`.
- **Apache mod_ssl 2.4.66+** accepts Ed25519-signed client/server certs. The TLS handshake still negotiates ECDHE_X25519 for key exchange.
- **NNCP wire protocol unchanged**: NNCP 8.13.0 is the reference; we don't fork NNCP. We may invoke `nncp-toss` via its CLI; if the binary's CLI changes in a future NNCP version, we adapt.
- **Discovery env vars backward compatible**: `on-discovery.d/` scripts receive the same env vars as the old `on-discovery.sh`. Existing extension authors can drop their hooks in with no changes other than to URL.
- **Hash separation**: The exchanger-cert (mTLS) and nncp exchanger (NNCP) can be the *same* X25519 keypair. We assign the same scalar to both `<cert>.X25519 pub` and `<nncp.hjson>.exchpub`. This is explicitly OK per NNCP — `NewNode` and `NewNodeOur` do not validate `id` against `signpub`, so other peers deriving our `id` from our `signpub` and our `exchpub` from the same scalar will line up.
- **Reverse path**: peers with `nncp-call --http https://<us>:8443/nncp/receive` already work in NNCP's default build (NNCP 8+ supports HTTP/HTTPS via curl pipeline or `--http` flag, no extra code from us).
- **Server-name canonicalisation**: `<cn>` in our cert matches the hostname we're advertising via mDNS / DHCP reservation. Discovery beacon carries that `<cn>`. Peers use `<cn>` to address us; our NNCP id (BLAKE2b of signpub) is the cryptographic anchor.

---

## Out of Scope

- **Outbound NNCP via our infrastructure**: `nncp-call` continues to use its own transports. We do not implement a `/nncp/send` endpoint or replace `nncp-call`.
- **NNCP exec delivery semantics**: We don't replicate `nncp-exec`; users with NNCP-exec needs run vanilla nncp-toss as their existing workflow.
- **NNCP transports other than HTTPS**: TCP listener / UDP / ZMODEM / mail — we cover only the HTTPS / mTLS path.
- **Forking NNCP**: We use NNCP upstream unchanged.
- **Key rotation ceremony**: out of scope for v1; we leave a transition window where RSA legacy certs and Ed25519/X25519 new certs coexist.
- **NNCP protocol upgrades**: if a future NNCP version changes the wire format, that's a separate feature.
- **Cross-architecture compilation**: handled by feature 024 (one inside-WSL binary suffices).

---

## Dependencies

- **NNCP 8.13.0 source at `/tmp/nncp-8.13.0`** — used as the reference for wire format, key-format, and `nncp-toss` invocation semantics. Building or installing the resulting binary is a separate concern (system package, Nix derivation, or `go install`).
- **OpenSSL ≥ 3.0.0** with Ed25519 + X25519 — already on the host (verified on Tumbleweed-Slowroll 20260504; `openssl 3.5.3`).
- **Apache httpd ≥ 2.4.66** with mod_ssl + mod_cgi — already validated live for feature 023.
- **Existing mtls-hello foundations**: feature 010 (self-signed certs), 017 (native cert detection), 022 (flat layout), 023 (drop-box + per-host trust), 008 (wire discovery callback), 016 (bundle spooling).
- **Existing `scripts/on-discovery.sh`** — to be replaced with `scripts/on-discovery.d/`. Default scripts in the directory must replicate the old behaviour for users who haven't customised `on-discovery.sh`.
- **`/tmp/nncp-8.13.0`**: the user has this on the local filesystem; this spec will reference it but not modify it (it's a vendored source, not part of the mtls-hello codebase).
