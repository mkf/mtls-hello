# Quickstart: 025 nncp-replace

**Purpose**: Two-host end-to-end demo for the per-host drop-box + NNCP integration. End-to-end coverage: discovery registers a peer → mTLS POST → `nncp-toss` consumes archive → srv-side file is laid down under `<data-dir>/nncp/area/.../` (full-subscriber) or the archive is forwarded onward (relay-only).
**Created**: 2026-08-07
**Feature**: [spec.md](./spec.md) | [plan.md](./plan.md) | [research.md](./research.md) | [data-model.md](./data-model.md)

---

## Pre-requisites

- Two Linux hosts (any recent Tumbleweed / Ubuntu / Debian) with Apache 2.4.66+ and OpenSSL 3.0+ installed (verified live on Tumbleweed-Slowroll 2.4.67 / OpenSSL 3.5.3).
- Go 1.21+ on the host that runs `scripts/install.sh` (via `nix-shell -p go …` or system Go).
- The NNCP 8.13.0 source tree at `/tmp/nncp-8.13.0/` on the install host (the project does **not** depend on a system NNCP package — we build from source).
- Pre-existing `mtls-hello` install from feature 023 is not strictly required but the discovery smoke tests described below assume the regular mTLS surface also works.

## Step 1 — install + build NNCP

On each host (`alice` and `bob`), run:

```bash
cd /path/to/laptops
nix-shell --run 'bash scripts/install.sh --host $(hostname)'
```

What this does (in order):
1. Verify Go + `/tmp/nncp-8.13.0` on disk → fail fast if either missing.
2. Call `scripts/gen-certs.sh --cn $(hostname) --existing-key skip-if-self` → produces `<data-dir>/identity/{hostname}.{crt,key}`.
3. Call `scripts/gen-certs.sh --emit-nncp-hjson --input <data-dir>/identity --output <data-dir>/nncp.hjson` → produces the NNCP-format `self:` block (id / exchpub / exchprv / signpub / signprv=64-bytes / noisepub / noiseprv), base32-encoded without padding.
4. Call `scripts/build-nncp.sh --dir <data-dir>/bin --src /tmp/nncp-8.13.0` → runs `go build -o <data-dir>/bin/nncp ./cmd/nncp` and symlinks `nncp-toss nncp-call nncp-stat nncp-cfgnew nncp-cfgmin nncp-cfgenc nncp-check` (driven by `/tmp/nncp-8.13.0/cmd.list`).
5. Call `scripts/apache-config.sh <data-dir> 8443 <data-dir>/identity/$(hostname).crt <data-dir>/identity/$(hostname).key > <data-dir>/apache/httpd.conf` → renders httpd.conf with `ScriptAlias /nncp/receive/ handlers/nncp-receive.post.sh/`, `LoadModule dav_fs_module`, `LoadModule dav_module`, `DAVLockDB <data-dir>/apache/dav-lockdb`, `<VirtualHost 127.0.0.1:$((PORT+1))> DocumentRoot <data-dir>/drop`.

## Step 2 — start the server

```bash
sudo httpd -f $DATA_DIR/apache/httpd.conf  # foreground; bg via & in real deployments
```

Or `apachectl -f …` if you prefer the control script (we don't auto-restart Apache from `install.sh`, per spec G10).

Verify the server is up:

```bash
curl --cacert $DATA_DIR/identity/localhost.crt --cert $DATA_DIR/identity/localhost.crt --key $DATA_DIR/identity/localhost.key \
  https://localhost:8443/drop/localhost/hi -X PUT --data-binary 'hello' -i | head -3
# expected: HTTP/1.1 201 Created (or 422 if CN-mismatch with no other peers yet)
```

## Step 3 — start the discovery daemon

```bash
DATA_DIR=$DATA_DIR nix-shell --run 'bash source/app.d /path/to/app.d-bin'
```

(Discover via UDP multicast; in production, this is wrapped in `scripts/systemd/mtls-hello-discovery.service` per feature 007.)

## Step 4 — two-host handshake

With both hosts running, multicast discovery auto-registers each peer:

```bash
# On alice, after discovery lands:
ls $DATA_DIR/hosts/        # contains bob.crt
jq '.neigh' $DATA_DIR/nncp.hjson   # contains "bob" entry with id, exchpub, signpub
head -3 $DATA_DIR/discoveries.log  # log line with bob's NNCP-id
```

## Step 5 — receive-side: UDP POST that lands in `nncp-toss`

```bash
# On bob, after alice is trusted, generate an NNCP packet addressed to alice:
DATA_DIR=$B_DATA $B_DATA/bin/nncp-call -cfg $B_DATA/nncp.hjson alice https://bob-host:8443/nncp/receive \
    --autotoss --autotoss-nofile --autotoss-noexec --autotoss-nofreq --autotoss-noarea --autotoss-noack \
    $A_DATA/hello.txt
# alice's POST body is the NNCP-format outer packet
```

Wait — `nncp-call`'s `[NODE][:ADDR]` syntax needs the peer NODE as `alice`, but `--http` flag does NOT exist in 8.13.0 (see [research.md §6](../research.md)). Use the configured neighbour:

```bash
# Pre-req: in bob's nncp.hjson, under neigh.<alice-id>:
#   addr: "https://alice-host:8443/nncp/receive"

DATA_DIR=$B_DATA $B_DATA/bin/nncp-call -cfg $B_DATA/nncp.hjson alice \
    --autotoss --autotoss-nofile --autotoss-noexec --autotoss-nofreq --autotoss-noarea --autotoss-noack \
    $A_DATA/hello.txt
```

(We will fill in `<alice-id>` with the actual NNCP id we read from alice's `nncp.hjson self.id` field.)

## Step 6 — verify alice receives the packet

On alice:

```bash
ls $DATA_DIR/nncp/area/<area-id>/$(hostname)/     # if alice is a full-subscriber for an area
# OR
ls $DATA_DIR/nncp/seen/<peer-bob-id>/              # if alice is relay-only; MsgHash filenames here
```

For the **relay-only** path: alice's `nncp.hjson` lists `<area-id>` under `areas.<area-id>.subs` but **no `prv:`**. The inbound `PktTypeArea` is forwarded to each subscriber whose `seen/<MsgHash>` is empty. Confirm via:

```bash
journalctl -u $DATA_DIR -t nncp-toss --since -1m | grep rx-area-no-prv
# expected: at least one entry per inbound area packet, showing
# `[rx-area-no-prv] les=toss: rx-area-no-prv area=<area-id>`
```

For the **full-subscriber** path: alice's `nncp.hjson` lists `<area-id>` under `areas.<area-id>.subs` AND `prv:`. The inbound packet is decrypted and `toss` writes files to `<data-dir>/nncp/area/<area-id>/<self-id>/`. Confirm via:

```bash
find $DATA_DIR/nncp/area -type f -mmin -5 | head
# expected: at least one file from the just-arrived packet
```

## Step 7 — clean up

Stop httpd (or your service manager) and the discovery daemon. Remove `<data-dir>/bin/nncp-toss` symlink to verify graceful-degradation behaviour:

```bash
mv $DATA_DIR/bin/nncp-toss{,.disabled}
curl --cacert $DATA_DIR/identity/localhost.crt --cert $DATA_DIR/identity/localhost.crt --key $DATA_DIR/identity/localhost.key \
  https://localhost:8443/nncp/receive/ -X PUT --data-binary 'junk' -i | head -3
# expected: HTTP/1.1 501 Not Implemented with body "nncp-receive: nncp-toss not found; feature disabled"
```

Restore via `mv $DATA_DIR/bin/nncp-toss{.disabled,}`. The rest of mtls-hello (/drop, /head, /bundle, /spool, /cert-echo) is unaffected — feature 023's surface is guaranteed to keep working.

## Common gotchas

- **Body too large**: Apache `LimitRequestBody` defaults to 1 GiB; check with `LimitRequestBody 1000000` (1 MB) for stress-testing.
- **Wrong port**: Public VH is `*:8443`; loopback mod_dav VH is `127.0.0.1:$((PORT+1))` (default `8444`). The `/nncp/receive` ScriptAlias is on the public VH only; loopback VH `DocumentRoot <data-dir>/drop` does NOT register `/nncp`.
- **Trust dir missing**: If `mkdir -p <data-dir>/hosts` is missed, `10-trust-add.sh` errors out. The install.sh flow takes care of it; manually creating it is fine.
- **Headers**: `SSL_CLIENT_S_DN_CN` is at `SSLUseCN on` (default in Apache 2.4); if you've turned it off you must re-enable or pass CN differently.
- **Two-host CN predict**: if both hosts have hostname `localhost`, NNCP id conflict; both peers will see the same `id` and either will refuse the other's packets. Use distinct hostnames (`alice`, `bob`).
