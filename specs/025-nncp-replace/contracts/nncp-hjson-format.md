# Contract: `<data-dir>/nncp.hjson` format

**Purpose**: Pin the byte-level shape of the NNCP config file that 025 introduces. Neuralgic to en/decoding, keypair reuse, and relay behaviour.
**Created**: 2026-08-07
**Feature**: [spec.md](../spec.md) | [plan.md](../plan.md) | [research.md](../research.md) | [data-model.md](../data-model.md)

---

## File format

Hjson (Human JSON) — `nncp`'s `cfg.go` consumes hjson via the `hjson-go/v4` module shipped at `/tmp/nncp-8.13.0/src/vendor/github.com/hjson/hjson-go`. Our installer uses `nncp-cfgnew` (or direct hjson write) and the resulting file is parseable by `nncp-cfgmin` and `nncp-cfgdump` round-trips.

Encoding: **RFC 4648 base32 without padding** (`rstrip('=')`). All key scalars, ids, and shared secrets go through this encoding. NB: do NOT use base64, do NOT add `=` padding.

## Top-level structure

```hjson
self: {
    id:       "<base32-32>"
    exchpub:  "<base32-32>"
    exchprv:  "<base32-32>"
    signpub:  "<base32-32>"
    signprv:  "<base32-64>"  // key NNCP-specific: seed||pub, 64 bytes decoded
    noisepub: "<base32-32>"
    noiseprv: "<base32-32>"
}

neigh: {
    "<peer-key>": {
        id:       "<base32-32>"
        exchpub:  "<base32-32>"
        signpub:  "<base32-32>"
        noisepub: "<base32-32>"  // optional
        addr:     "tcp:1.2.3.4:8443"  // default transport; alternates:
                                      // "http://host:port/path" or
                                      // "https://..." for nncp-call's curls
        notbefore: "2026-01-01T00:00:00Z"  // optional; post-handshake time
        mcd:      false  // optional; encrypt-on-MCD for nh
    }
}

areas: {
    "<area-id>": {
        id:      "<base32-32>"  // = BLAKE2b-256(area-exchpub), 32-byte digest
        pub:     "<base32-32>"  // X25519 area-exchange public (32 bytes)
        // prv is OPTIONAL. omit entirely (omit-empty in hjson) for relay-only mode.
        // prv: "<base32-32>"
        subs:    [
            "<subscriber-id-1>",
            "<subscriber-id-2>",
            ...
        ]
        mcd:     false  // optional; default false
    }
}
```

## Key-shape validation matrix

| Field | Expected decoded byte length | Algorithm | Validation source |
|---|---|---|---|
| `self.id` | 32 | BLAKE2b-256 | `blake2b.Size256` |
| `self.exchpub` | 32 | X25519 | RFC 7748 |
| `self.exchprv` | 32 | X25519 (scalar) | RFC 7748; MUST be the X25519 private scalar |
| `self.signpub` | 32 | Ed25519 | RFC 8032 |
| `self.signprv` | **64** | Ed25519 (`seed_32 \|\| pub_32`) | NNCP `ed25519.PrivateKeySize = 64` |
| `self.noisepub` | 32 | X25519 (separate keypair from exchpub) | RFC 7748 |
| `self.noiseprv` | 32 | X25519 (scalar) | RFC 7748 |
| `neigh.<id>` | 32 | BLAKE2b-256 | matches `BLAKE2b-256(signpub)` for the peer |
| `neigh.<exchpub>` | 32 | X25519 | peer's pub |
| `neigh.<signpub>` | 32 | Ed25519 | peer's pub |
| `areas.<id>.id` | 32 | BLAKE2b-256 | not actually used by NNCP; OK per `cfg.go` |
| `areas.<id>.pub` | 32 | X25519 | area exch pub |
| `areas.<id>.prv?` | 32 (optional) | X25519 (scalar) | area exch priv; absence ⇒ relay-only |
| `subs[].<subscriber-id>` | 32 | BLAKE2b-256 | per-subscriber |

The full validation rule set is in `/tmp/nncp-8.13.0/src/cfg.go:388-487`:
- `len(decoded(exchPrv)) != 32 → errors.New("Invalid exchPrv size")` (line 392-393).
- `len(decoded(signPrv)) != ed25519.PrivateKeySize → errors.New("Invalid signPrv size")` (line 408-409).
- `len(decoded(noisePrv)) != 32 → errors.New("Invalid noisePrv size")` (line 424-425).
- The decoded `id` (32 bytes) is matched against `BLAKE2b-256(signpub)` (line 93 in `node.go`).

## Round-trip properties

| Operation | Source | Sink | Round-trip-equivalent |
|---|---|---|---|
| `gen-certs.sh` writes nNCP.hjson | raw bytes → base32 → hjson | `nncp-cfgmin` → `cfg.go` | bytes byte-equivalent |
| `nncp-cfgnew` invocation | random | raw bytes | bytes byte-equivalent |
| `nncp-cfgmin` consumption | hjson-with-padding | byte-checked | byte-equivalent by definition of base32-without-padding |
| `nncp-cfgdump` output | bytes | base32 lines | byte-equivalent |

## Cross-validation with mTLS identity

The `<cn>.crt`'s Ed25519 signpub equals `self.signpub`'s decoded value (32 bytes). Computed at `scripts/gen-certs.sh` time. Verified by:
```bash
cert_signpub=$(openssl x509 -in "$DATA_DIR/identity/$cn.crt" -pubkey -noout | tail -c 32)
hjson_signpub=$(grep '"signpub"' "$DATA_DIR/nncp.hjson" | sed 's/.*"\([^"]*\)".*/\1/' | base32 -d)
[ "$cert_signpub" = "$hjson_signpub" ] || fatal "cert/hjson signpub mismatch"
```

The `id` from `self.id` equals `BLAKE2b-256(hjson_signpub)`:
```bash
id_computed=$(printf '%s' "$hjson_signpub" | blake2b -l 32 | base32 -w 0)
```

## Round-trip tests in BATS

`tests/nncp-replace.bats` includes:
- `gen-certs.sh` produces key shapes that round-trip through `nncp-cfgmin` without error.
- `id` matches `BLAKE2b-256(signpub)`.
- `exchpub` / `exchprv` is a valid X25519 keypair (`python3 -c "import nacl.bindings;…"`).
- `signpub` / `signprv` is a valid Ed25519 keypair (the most reliable check is in NNCP itself, which throws on bad pairs).
- `areas.foo.id` length-32, `areas.foo.pub` length-32, `areas.foo.subs[0]` length-32.
- Absence of `areas.foo.prv` ⇒ `nncp-cfgmin` succeeds; presence ⇒ also succeeds.
- The file is `hjson-cli`-round-trippable (use the bundled `nncp-cfgmin` tool).
