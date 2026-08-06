# Data Model: 025 nncp-replace

**Purpose**: Inventory the on-disk and in-memory entities that feature 025 introduces or modifies.
**Created**: 2026-08-07
**Feature**: [spec.md](./spec.md) | [plan.md](./plan.md) | [research.md](./research.md)

## Entities

### 1. Identity cert + raw keys

| Path | Shape | Source | Notes |
|---|---|---|---|
| `<data-dir>/identity/<cn>.crt` | X.509v3 self-signed (RFC 8422 / RFC 8446) | `scripts/gen-certs.sh` | Ed25519 sign + X25519 ECDH in `SubjectPublicKeyInfo`; CN=`<cn>`, EKU=`serverAuth,clientAuth` |
| `<data-dir>/identity/<cn>.key` | PKCS#8 PEM, ed25519+x25519 scalars concatenated with sensible ordering | `scripts/gen-certs.sh` | Same three keypairs as in `.crt`, exposed in raw form for `nncp.hjson` extraction |
| `<data-dir>/identity-legacy-<timestamp>/<cn>.{crt,key}` | copy of existing RSA-based material | `--import-legacy-rsa` flag in `scripts/install.sh` (US5) | Preserved for one release; rotation ceremony moves new material to `<data-dir>/identity/`, leaves legacy here |

Validation rules:
- `<cn>.crt` Ed25519 signature verifies against itself (self-signed) and the file at `<cn>.key`.
- `<cn>.key` decodes via `PKCS#8`; we extract `Ed25519 privkey(32) || pub(32) = 64 bytes` for NNCP's `signprv`.
- `<cn>.crt` and `<cn>.key` must share the same `id = BLAKE2b-256(signpub)`; this is enforced by `scripts/gen-certs.sh`.

State transitions: none — these are write-once at install. US5's backup-and-rotate path is the only mutation.

### 2. NNCP hjson config (`<data-dir>/nncp.hjson`)

Hjson-compatible. Three top-level keys: `self`, `neigh`, `areas`.

#### 2.1 `self` block

```hjson
self: {
    id:       "<base32-32>"     # BLAKE2b-256(signpub)
    exchpub:  "<base32-32>"     # X25519 (32 bytes ECDH)
    exchprv:  "<base32-32>"     # same scalar as `exchpub` reversed to priv
    signpub:  "<base32-32>"     # Ed25519 (32 bytes)
    signprv:  "<base32-64>"     # Ed25519 (seed 32 || pub 32) — NNCP `ed25519.PrivateKeySize = 64`
    noisepub: "<base32-32>"     # second X25519 — separate scalar from `exchpub`
    noiseprv: "<base32-32>"     # second X25519 priv
}
```

Validation rules (`/tmp/nncp-8.13.0/src/cfg.go:388-425`):
- `len(decoded(exchprv))` must be 32.
- `len(decoded(signprv))` must be 64.
- `len(decoded(noiseprv))` must be 32.
- `len(decoded(id))` must be 32 (`blake2b.Size256`).
- `id` must equal `BLAKE2b-256(decoded(signpub))` with `digest_size=32`.

State transitions: `self` block is write-once on install; rotation replaces it in place via tempfile + atomic `rename(2)`.

#### 2.2 `neigh` block (per-peer entries)

```hjson
neigh: {
    "<peer-cn-or-hostname>": {
        id:       "<base32-32>"  # BLAKE2b-256 of peer's signpub
        exchpub:  "<base32-32>"  # X25519 peer ECDH pub
        signpub:  "<base32-32>"  # Ed25519 peer sign pub
        noisepub: "<base32-32>"  # optional; only if peer provided
        addr:     "tcp:1.2.3.4:8443"   # default transport; alt: "http:..."
    }
}
```

Validation rules (per `cfg.go` Go-side):
- Each entry's `id` matches `BLAKE2b-256(signpub)` byte-for-byte.
- Decoded scalars match expected X25519 (32) and Ed25519 (32) sizes.

State transitions:
- **Insert**: `scripts/on-discovery.d/20-nncp-register.sh` on first discovery of a peer.
- **Update**: same script on subsequent discoveries of the same peer (replace, not append).
- **Delete**: not automatic; user-edited.

#### 2.3 `areas` block (per-area entries; new for v1)

```hjson
areas: {
    "<area-id-b32-32>": {
        id:  "<base32-32>"          # = KeyEncryptionKey32: BLAKE2b-256-area-seed
        pub: "<base32-32>"          # area X25519 exch pub (3rd X25519, distinct from exchpub/noisepub)
        # prv is optional. omit for relay-only mode.
        # prv: "<base32-32>"
        subs: [
            "<subscriber-id-1>",  # 32-byte BLAKE2b IDs of subscribers
            "<subscriber-id-2>",
            ...
        ]
        mcd: false  # whether to wrap area packets in MCD encryption
    }
}
```

Validation rules (per `cfg.go` Go-side):
- `len(area.id) == 32`, `len(area.pub) == 32`, optional `len(area.prv) == 32`.
- `subs` is optional; when present, each entry must be `len == 32`.

State transitions:
- **Insert**: user handwritten `nncp.hjson`. Not auto-discovered.
- **Update**: user-edited.
- **Relay-only propagation**: when `prv` is absent AND `subs` is non-empty, this node forwards area-encrypted inbound packets without decrypt — see relay behaviour in `toss.go:802-973`.

### 3. NNCP runtime directories (under `<data-dir>/nncp/`)

| Path | Purpose | Source |
|---|---|---|
| `queues/<self-id>/inbound/` | inbound packets; `<handler>/nncp-receive.post.sh` writes files here | `nncp-toss` consumes via `ctx.Toss()` |
| `queues/<self-id>/outbound/` | staggered outbound; written by `nncp-toss -seen` etc. | n/a |
| `incoming/` | alias for "all inbound queues" (visible to `nncp-toss`'s `-cycle` watcher) | n/a |
| `seen/<peer-id>/` | per-peer MsgHash dedup; `nncp-toss -seen` writes `<BLAKE2b-256(MsgHash)>` per first-hop | generated by `nncp-toss` |
| `ack/<peer-id>/` | ACK packets per peer (when `-gen-ack` set) | generated by `nncp-toss` |
| `area/<area-id>/<self-id>/` | decrypted area payloads (`./file`, `./exec`, etc.) | generated by `nncp-toss` |
| `log/` | logfile; default `<data>/var/spool/nncp/log/nncp.log` | generated by `nncp-toss` |
| `cfg.lock` (under SPOOL) | OSSP-flock on `cfg.hjson` for safe multi-process read | maintained by `nncp-toss` |

Validation: `nncp-toss` enforces spool filesystem layout internally; we document the conventions here for the implementation to know where to write.

### 4. Trust store (`<data-dir>/hosts/<cn>.crt`)

| Path | Shape | Source |
|---|---|---|
| `<data-dir>/hosts/<cn>.crt` | PEM X.509 (Ed25519) cert of trusted peer | `scripts/on-discovery.d/10-trust-add.sh` writes from `$PEER_CERT_FILE` env var (existing pattern from feature 018) |

Validation rules:
- Cert verifies against the cert at `<cn>.key` of the *issuer* if available; otherwise we trust peer cert on its own (TOFU model — feature 004 semantics).
- Fingerprint match (`openssl x509 -noout -fingerprint -sha256`) is the existing Apache `SSLVerifyClient optional_no_ca` trust gate (feature 018, 023). Fingerprint computed and matched in `handlers/nncp-receive.post.sh` and the Apache `<Directory>` block.

State transitions:
- **Insert**: `on-discovery.d/10-trust-add.sh` on first discovery.
- **Update**: same, on subsequent discoveries (replace).
- **Delete**: `scripts/trust-host.sh --remove <cn>` (existing pattern).

### 5. Discovery callback hooks (`<data-dir>/on-discovery.d/`)

Directory of numbered scripts invoked in lex order via `scripts/on-discovery.d/_run-parts.sh` (a launcher the D-side `source/app.d:78` points at).

| Filename | Purpose | Source |
|---|---|---|
| `_run-parts.sh` | launcher; invokes `[0-9][0-9]-*.sh` in the directory in lex order with `timeout --kill-after=5 30` per script | new in 025 |
| `00-validate.sh` | sanity checks — refuse to fire rest of chain if any of: peer CN is empty, peer's mTLS cert fingerprint is empty, peer equals self | new in 025 |
| `10-trust-add.sh` | add/replace `<data-dir>/hosts/<cn>.crt` with the peer's mTLS cert (from `$PEER_CERT_FILE`) | new in 025 |
| `20-nncp-register.sh` | add/update `<data-dir>/nncp.hjson` `neigh:` entry for the peer; populates `id`, `exchpub`, `signpub`, optional `noisepub` from the peer's signature over mTLS | new in 025 |
| `50-bundle-push.sh` | (legacy-preserving) git-bundle-push per repo under `<data-dir>/repos/`, replicates the existing `scripts/on-discover.sh` logic but stripped of trust+nncp logic (since 10/20 cover those). Feeds `cli/mtls-curl` over `/bundle?repo=…&host=…&from=…&to=…` | preserved from on-discover.sh |
| `90-log.sh` | append one line to `<data-dir>/discoveries.log` with timestamp + peer CN + NNCP id + which subscripts out of `00/10/20/50/90` ran | new in 025 |

Discovery env vars (per the FFI-style `spawnProcess(["bash", request.callbackScript], …)` in `source/multicast.d:343-360`):
- `HOST_NAME` — friendly name of *this* host (used by `50-bundle-push.sh` for remote namespace and `90-log.sh`)
- `PEER_NETLOC` — peer host:port of peer's mTLS endpoint
- `PEER_CERT_FILE` — path to the peer's mTLS cert (existing convention)
- `OUR_CERT`, `OUR_KEY` — our mTLS client credentials
- `REPOS_ROOT` — `<data-dir>/repos/`
- `PEER_NNCP_ID` — BLAKE2b-256(signpub) of peer (new in 025)
- `PEER_SIGNPUB` — peer's Ed25519 sign public key (new in 025)
- `PEER_EXCHPUB` — peer's X25519 exch public key (new in 025)

Validation: env vars are present-since-bootstrap; the new NNCP env vars are additive (no existing script depends on them).

State transitions: only on discovery events.

### 6. `<data-dir>/discoveries.log`

Append-only log (no truncation). Format:
```
<ISO-8601-timestamp>\t<peer-CN>\t<peer-NNCP-id>\t<flags-ran-json-list>
```

### 7. Apache `httpd.conf` and `site.conf` (NOT my entity, but state we mutate)

- `scripts/apache-config.sh` extends the substitution set: adds `{{NNCP_DIR}}` → `<data-dir>/nncp/`. The template `config/apache-site.conf.in` adds:
    ```
    ScriptAlias /nncp/receive/ "{{HANDLERS_DIR}}/nncp-receive.post.sh/"
    <Directory "{{HANDLERS_DIR}}">
        Options +ExecCGI
        AllowOverride None
        Require all granted
    </Directory>
    ```
- Public mTLS VH (`:{{PORT}}`) inherits the existing directive set; no change. The `_run-parts.sh` launcher and inspect-on-listening is unchanged.

### 8. NNCP binary + symlinks (under `<data-dir>/bin/`)

| Path | Shape | Source |
|---|---|---|
| `<data-dir>/bin/nncp` | single Go-built ELF/Mach-O | `scripts/build-nncp.sh` invokes `go build -o … ./cmd/nncp` from `/tmp/nncp-8.13.0/src/` |
| `<data-dir>/bin/{nncp-toss,nncp-call,nncp-stat,nncp-cfgnew,nncp-cfgmin,nncp-cfgenc,nncp-check,…}` | symlinks to `nncp` | `scripts/build-nncp.sh` iterates `/tmp/nncp-8.13.0/cmd.list` |

State transitions: build at install; rebuilt on `--rebuild-nncp` flag.

## Relationships

```
<data-dir>/identity/<cn>.crt+.key       ─┐
                                          │ same key shape
                                          ▼
<data-dir>/nncp.hjson  self:           ◀──┘ (signprv, exchprv/exchpub, noiseprv/noisepub)

discovery event  ───────►  spawnProcess(bash, <data-dir>/scripts/on-discovery.d/_run-parts.sh)
                                          │
                                          ▼
                                  run-parts <data-dir>/on-discovery.d/[0-9][0-9]-*.sh
                                          │
              ┌──────────────┬──────────────┼──────────────┬──────────────┐
              ▼              ▼              ▼              ▼              ▼
          00-validate   10-trust-add   20-nncp-reg   50-bundle-push   90-log
                          │              │
                          ▼              ▼
              <data-dir>/hosts/   <data-dir>/nncp.hjson neigh:
                  <cn>.crt          <peer-cn>: {id, exchpub, signpub, …}

POST /nncp/receive  ─────►  handlers/nncp-receive.post.sh
                                          │
                   ┌──────────────────────┼──────────────────────┐
                   ▼                      ▼                      ▼
        trust-gate (existing)   write to <data-dir>/nncp/queues/   shell out
                                <self-id>/inbound/<id>.ni       
                                          │                      │
                                          └─────► nncp-toss  ◀────┘
                                                       -cfg <data-dir>/nncp.hjson
                                                           -seen -noack -nofile -noexec -nofreq -notrns
                                                       exit code → HTTP status
```

## Validation rules summary

| Entity | Rule |
|---|---|
| `<cn>.crt` | Ed25519 self-signed; `openssl verify` returns OK |
| `<cn>.key` | PKCS#8 parseable; Ed25519(len 64) + X25519(len 32) extractable |
| `nncp.hjson self.id` | byte-equal `BLAKE2b-256(signpub)` for `digest_size=32` |
| `nncp.hjson neigh.*.id` | matching peer's `BLAKE2b-256(signpub)` |
| `nncp.hjson areas.*.prv?` | optional; absent ⇒ relay-only behaviour in `toss.go:802-973` |
| `on-discovery.d` | scripts lex-ordered; per-script timeout 30 s; idempotent across repeat discoveries |
| `discoveries.log` | append-only ISO-8601 + escape-safe (no `\\t` in CN) |
| `<data-dir>/hosts/<cn>.crt` | PEM-encoded; fingerprint match in Apache `SSLVerifyClient optional_no_ca` |
