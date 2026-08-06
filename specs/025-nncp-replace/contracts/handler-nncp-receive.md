# Contract: `handlers/nncp-receive.post.sh` (POST /nncp/receive)

**Purpose**: Define the wire shape, env vars, output format, and subprocess contract of the `/nncp/receive` handler.
**Created**: 2026-08-07
**Feature**: [spec.md](../spec.md) | [plan.md](../plan.md) | [research.md](../research.md) | [data-model.md](../data-model.md)

---

## HTTP surface

### Request

| Header | Value | Source |
|---|---|---|
| Method | `POST` | Apache config |
| Path | `/nncp/receive/` (trailing slash due to `ScriptAlias` convention) | Apache config |
| `SSL_CLIENT_VERIFY` | `SUCCESS` | Apache `mod_ssl` |
| `SSL_CLIENT_S_DN_CN` | peer hostname (matches `<data-dir>/hosts/<cn>.crt`) | Apache `mod_ssl` |
| `SSL_CLIENT_I_DN_CN` | issuer CN (this server) | Apache `mod_ssl` |
| Body | arbitrary bytes — an NNCP-encoded outer packet (RFC-4648 base32 wrapped delivery in `nncp-call`'s transport, but on Apache `/nncp/receive` we receive raw bytes since Apache is the transport) | client |

Maximum body size: `LimitRequestBody 1000000000` (1 GiB) in the public VH; configurably tightened via `MaxRequestSize` per the existing spec.

### Response

| HTTP Status | Trigger | Body |
|---|---|---|
| `202 Accepted` | `nncp-toss` exited 0, packet landed in `<data-dir>/nncp/queues/<self-id>/inbound/<id>.ni` and was forwarded/decrypted per toss's policy | empty body |
| `401 Unauthorized` | mTLS gate failed (no client cert presented) | `text/plain` — `nncp-receive: client certificate missing or untrusted` |
| `403 Forbidden` | CN vs URL-prefix mismatch (rare; URL is just `/nncp/receive/`, no per-CN inner routing) | `text/plain` — `nncp-receive: cross-host access denied` |
| `409 Conflict` | file write to inbound failed (`<self-id>/inbound/` directory permissions, etc.) | `text/plain` — stderr from handler up to 4096 bytes |
| `413 Payload Too Large` | body exceeds configured `MaxRequestSize` | Apache-generated |
| `500 Internal Server Error` | handler bug or `nncp-toss` non-zero exit *and* body/header inconsistency | `text/plain` — `nncp-receive: nncp-toss exited N — <stderr>` |
| `501 Not Implemented` | `<data-dir>/bin/nncp-toss` symlink missing or `nncp-toss` not executable | `text/plain` — `nncp-receive: nncp-toss not found; feature disabled` |
| `502 Bad Gateway` | `nncp-toss` exited non-zero (transport valid but upstream rejected) | `text/plain` — stderr up to 4096 bytes |

Note: 202 (not 200) is the canonical "we accepted your packet, processing is async" answer; toss goes synchronously inside the request so we report 202 only after toss's exit-0.

## Trust gate (inherited from feature 023)

The handler currently runs **after** Apache's TLS handshake, but Apache's existing `SSLVerifyClient optional_no_ca` lets the connection through even if the cert is untrusted; the per-vhost `<Location>` block has trust checking enabled by Apache module order, but we'll also do an explicit CN match in the handler. Pattern (preserved from `handlers/drop-proxy.sh`):

```bash
match_fingerprint "$(openssl x509 -in $PEER_CERT_FILE -noout -fingerprint -sha256 | sed 's/.*=//;s/://g')" \
    $(openssl x509 -in "$dir/$cn.crt" -noout -fingerprint -sha256 | sed 's/.*=//;s/://g')
```

Where `match_fingerprint()` is from `scripts/cgi-trust.sh` (feature 023).

If `dir/$cn.crt` is missing (peer not in trust store) → 401 with body `untrusted peer — peer is /hello-triggered cert capturable on /etc/...; please run scripts/trust-host.sh <cn> <cert>` (link to feature 021's trust-host script).

## Subprocess contract: `nncp-toss`

Invocation:
```
nncp-toss -cfg <DATA_DIR>/nncp.hjson \
           -spool <DATA_DIR>/nncp/queues \
           -seen \
           -noack \
           -nofile \
           -nofreq \
           -noexec \
           -notrns
```

Notes:
- `-cfg <DATA_DIR>/nncp.hjson` is mandatory; `nncp-toss` exits non-zero if config is absent or malformed (clear stderr).
- `-spool <DATA_DIR>/nncp/queues` (override) — defaults to `/var/spool/nncp`; we override so `<data-dir>` is self-contained.
- `-seen` writes `<BLAKE2b-256(MsgHash)>` files under `seen/<self-id>/` to dedupe first-hop's own re-forwarding.
- `-noack -nofile -nofreq -noexec -notrns` filters which packet types the receiving pass processes. We don't process inbound `file`/`exec`/`freq` packets directly via `/nncp/receive` — those come over TCP via `nncp-call`. We do process `area` (forwarding to subscribers); `nncp-toss`'s default includes `area` unless `-noarea` is set.

(Why exclude these): `/nncp/receive` accepts packets that would otherwise go via TCP/listener; we don't want spam to be mistaken for file uploads. Also, `nofile/noexec/nofreq/notrns` keep the inbound surface narrow.

Exit codes:
- `0` — tossed successfully (forwarded/subscriber-decrypted/seen-marked); return 202.
- `1` — packet error (e.g., corrupted data, unexpected length); return 502.
- `2` — storage error (e.g., disk full); return 502.

## Concurrent invocations

Apache's `<Files>` MPM launches one CGI handler per concurrent request — we accept the race. Inbound queue filenames are derived from a `mktemp(1)`-equivalent `printf '%d_%d_%s.ni' "$(date +%s)" "$$" "$(openssl rand -hex 8)"` — collision is negligible. `nncp-toss` itself is itself concurrency-aware (`flock` over `cfg.lock` and `seen/`-per-receiver), so two parallel POSTs cannot race on the same MsgHash.

## Configuration flags (from `scripts/on-discovery.d/20-nncp-register.sh`-controlled `nncp.hjson`)

| Flag | Effect on /nncp/receive behaviour |
|---|---|
| `areas.<id>.prv` absent | Forward-only delivery for that area; toss logs `rx-area-no-prv` for each inbound PktTypeArea |
| `areas.<id>.pub + prv` | Full-subscriber delivery; toss decrypts inner area layer; user sees files in `<data-dir>/nncp/area/<id>/<self-id>/` |
| `neigh.<id>` populated | Hop-by-hop is wired; toss wraps/encrypts outbound to that neighbour's `exchpub` |
| `self.id` defined | Toss knows it's not just another peer's address; without it toss refuses to start (`Config lacks private keys`) |

## Authentication

mTLS + per-host fingerprint match, **inherited unchanged from feature 023**. We do not introduce a new auth layer; the existing `cgi-common.sh`'s `cgi_error` helper is reused.

## Disable / uninstall

Symlinking `nncp-toss` away (or moving `<data-dir>/bin/nncp` aside) immediately disables `/nncp/receive`, which then sends `501 Not Implemented`. The rest of mtls-hello (drop-box, cert-echo, head, spool, etc.) is unaffected.

## Encrypted-on-the-wire assumption

Packet body is **not encrypted** at the HTTP layer (we are carrying an NNCP-format outer packet that is encrypted via NNCP's content envelope). TLS terminates at Apache. The confidentiality boundary is: our mTLS tunnel (Apache-side) wraps a content payload that's separately NNCP-encrypted.

Anyone reading the spec for this handler in isolation must understand there's two layers of protection stacked here — the order from inside out is:

1. **NNCP content envelope** — the packet body is encrypted to first-hop's `exchpub` (in `<cert>.X25519 pub` derived from the peer's cert). We do not change this; it is the contract from feature 023's drop-box design extended.
2. **mTLS tunnel** — TLS handshake with client cert; second-degree authentication. This protects the channel itself.

So at any hop, the packet is either inside an mTLS tunnel (this server is the first-hop for the client) or a deep NNCP envelope (this server is the second-hop peer). Both layers are *additive*, not redundant.
