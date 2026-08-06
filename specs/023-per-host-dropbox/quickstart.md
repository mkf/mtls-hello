# Quickstart: Per-Host Drop-Box

**Feature**: `023-per-host-dropbox`
**Date**: 2026-08-06 (mod_dav-first revision)

## What this feature does

A `/drop/<cn>/<rest>` endpoint served by Apache `mod_dav` on a loopback VirtualHost, fronted by an mTLS VH on the public port that enforces URL-prefix-vs-verified-CN. Each trusted host (alice, bob) auto-derives their box prefix from their cert's CN and gets isolated access to `/drop/<cn>/`. Cross-host access returns 403 Forbidden.

Architecture:
```text
client --HTTPS+mTLS--> public VH :8443 (mod_ssl + mod_rewrite + [P] proxy)
                              │
                              ▼
                   loopback VH :8444 127.0.0.1-only (mod_dav, DAV On,
                                                    DocumentRoot <data-dir>/drop)
                              │
                              ▼
                   <data-dir>/drop/<cn>/<rest>     # filesystem
```

Setup of the mTLS / trust gate is the same as feature 018 / 021. The wrappers auto-derive `<cn>` from the client's own cert, no manual entry.

## Verify the apache modules are enabled

```bash
# Debian — required
sudo a2enmod dav dav_fs dav_lock proxy proxy_http ssl headers rewrite setenvif

# Arch — mod_dav ships in apache; ensure proxy and proxy_http are loaded
# Nix — verify `mod_dav`, `mod_dav_fs`, `mod_dav_lock`, `mod_proxy`,
#      `mod_proxy_http` are in the pinned Apache derivation
```

Confirm Apache is running with the new modules installed (graceful reload after enabling):

```bash
apache2ctl -M 2>/dev/null | grep -E 'dav(_fs|_lock)? |proxy_http |headers '
# expect:  dav_module, dav_fs_module, dav_lock_module, proxy_http_module,
#          headers_module, ...
```

`just install` already does this together with config regeneration; running `apachectl -M` is the visible post-condition.

## Verify the two VHs come up

Restart Apache with the new config:

```bash
sudo systemctl restart mtls-hello.service    # the systemd unit installed by feature 007
# OR (development):
apachectl -k graceful
```

The new site config (in `<data-dir>/apache/site.conf`) is rendered by `scripts/install.sh` from `config/apache-site.conf.in`. After install, expect two `<VirtualHost>` entries:

```bash
grep '<VirtualHost' <data-dir>/apache/site.conf
# expect:
# <VirtualHost *:8443>           (public, mTLS)
# <VirtualHost 127.0.0.1:8444>   (loopback, mod_dav)
```

## Smoke: alice and bob drop into their boxes

Two test identities are generated as part of `tests/apache.bats`'s setup. We reuse them:

```bash
CERT_DIR="$(mktemp -d)"
CLIENT_HOST="$(hostname)"                # the local peer (we drop TO ourselves, then bob drops to us)
# Generate alice and bob with self-signed certs.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$CERT_DIR/alice.key" \
    -out    "$CERT_DIR/alice.crt" \
    -subj "/CN=alice"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$CERT_DIR/bob.key" \
    -out    "$CERT_DIR/bob.crt" \
    -subj "/CN=bob"

# Trust them at <data-dir>/hosts/
cp "$CERT_DIR/alice.crt" "<data-dir>/hosts/alice.crt"
cp "$CERT_DIR/bob.crt"   "<data-dir>/hosts/bob.crt"
```

Drop from alice:

```bash
echo "from alice" > /tmp/alice-note.txt
./cli/mtls-drop.sh --cert "$CERT_DIR/alice.crt" --key "$CERT_DIR/alice.key" \
   --cacert "$CERTS_DIR/server.crt" \
   --server https://localhost:8443 --source /tmp/alice-note.txt --name notes.txt
# expect: (201 created drop/alice/notes.txt)
```

alice reads her own:

```bash
./cli/mtls-fetch.sh --cert "$CERT_DIR/alice.crt" --key "$CERT_DIR/alice.key" \
   --cacert "$CERTS_DIR/server.crt" \
   --server https://localhost:8443 --name notes.txt --out /tmp/got.txt
cat /tmp/got.txt    # expect: from alice
```

Drop from bob (a different file under his own prefix):

```bash
echo "from bob" > /tmp/bob-note.txt
./cli/mtls-drop.sh --cert "$CERT_DIR/bob.crt" --key "$CERT_DIR/bob.key" \
   --cacert "$CERTS_DIR/server.crt" \
   --server https://localhost:8443 --source /tmp/bob-note.txt --name notes.txt
# expect: (201 created drop/bob/notes.txt)
```

## Verify per-host isolation

```bash
# alice reads bob's notes.txt — should be 403 (and the wrapper prints `prefix mismatch` and exits 5)
./cli/mtls-fetch.sh --cert "$CERT_DIR/alice.crt" --key "$CERT_DIR/alice.key" \
   --cacert "$CERTS_DIR/server.crt" \
   --server https://localhost:8443 --name /drop/bob/notes.txt --out /tmp/shouldfail.txt; \
   echo "exit=$?"
# expect: exit=5  (the wrapper's prefix-mismatch status)
```

Try via the raw URL:

```bash
curl -i --cert "$CERT_DIR/alice.crt" --key "$CERT_DIR/alice.key" \
     --cacert "$CERTS_DIR/server.crt" \
     https://localhost:8443/drop/bob/notes.txt | head -1
# expect:
# HTTP/1.1 403 Forbidden
```

## Listings via `mtls-ls`

```bash
# alice's box
./cli/mtls-ls.sh --cert "$CERT_DIR/alice.crt" --key "$CERT_DIR/alice.key" \
    --cacert "$CERTS_DIR/server.crt" --server https://localhost:8443
# expect (header line + tab-separated rows):
# <one tab-separated line per file in /drop/alice/>
# notes.txt    11    text/plain    "<sha>"   <lastmod>
```

## Conditional GET roundtrip through ETag

```bash
ETAG=$(./cli/mtls-head.sh --cert "$CERT_DIR/alice.crt" --key "$CERT_DIR/alice.key" \
        --cacert "$CERTS_DIR/server.crt" --server https://localhost:8443 \
        --name notes.txt | awk -F'"' '$1 ~ /ETag/ {print $2}')
echo "$ETAG"
# expect: "sha256:..."

./cli/mtls-fetch.sh --cert "$CERT_DIR/alice.crt" --key "$CERT_DIR/alice.key" \
   --cacert "$CERTS_DIR/server.crt" \
   --server https://localhost:8443 --name notes.txt --if-none-match "$ETAG"
# expect: (304 not modified <ETAG>)
```

## Range request for large file (resume)

```bash
# Generate a 32MB file
dd if=/dev/urandom of=/tmp/big.bin bs=1M count=32
./cli/mtls-drop.sh --cert "$CERT_DIR/alice.crt" --key "$CERT_DIR/alice.key" \
   --cacert "$CERTS_DIR/server.crt" \
   --server https://localhost:8443 --source /tmp/big.bin --name big.bin

# Range fetch — second 1 MB chunk
./cli/mtls-fetch.sh --cert "$CERT_DIR/alice.crt" --key "$CERT_DIR/alice.key" \
   --cacert "$CERTS_DIR/server.crt" --server https://localhost:8443 \
   --name big.bin --range 1048576-2097151 --out /tmp/chunk2.bin
ls -l /tmp/chunk2.bin
# expect: 1048576 bytes
```

## PROPFIND (mod_dav native)

```bash
# Depth: 1 — alice's full box
./cli/mtls-ls.sh --cert "$CERT_DIR/alice.crt" --key "$CERT_DIR/alice.key" \
    --cacert "$CERTS_DIR/server.crt" --server https://localhost:8443
# expect: one tab-separated line per child under /drop/alice/

# Depth: 0 — single resource metadata
./cli/mtls-props.sh --cert "$CERT_DIR/alice.crt" --key "$CERT_DIR/alice.key" \
    --cacert "$CERTS_DIR/server.crt" --server https://localhost:8443 --name notes.txt
# expect:
# resourcetype: regular
# getcontentlength: 11
# getcontenttype: text/plain
# getlastmodified: ...
# getetag: "..."
```

## Directories + copy + move (P3 — kept simple under mod_dav)

```bash
# mkcol, copy, move
./cli/mtls-mkcol.sh --cert "$CERT_DIR/alice.crt" --key "$CERT_DIR/alice.key" \
    --cacert "$CERTS_DIR/server.crt" --server https://localhost:8443 \
    --dir archive
# expect: (201 created archive)

./cli/mtls-cp.sh --cert "$CERT_DIR/alice.crt" --key "$CERT_DIR/alice.key" \
    --cacert "$CERTS_DIR/server.crt" --server https://localhost:8443 \
    --source notes.txt --dest archive/notes.txt
# expect: (201 copied)

./cli/mtls-mv.sh --cert "$CERT_DIR/alice.crt" --key "$CERT_DIR/alice.key" \
    --cacert "$CERTS_DIR/server.crt" --server https://localhost:8443 \
    --source notes.txt --dest renamed.txt
# expect: (201 moved)

./cli/mtls-ls.sh --cert "$CERT_DIR/alice.crt" --key "$CERT_DIR/alice.key" \
    --cacert "$CERTS_DIR/server.crt" --server https://localhost:8443
# expect: archive/  notes.txt (copied)  notes.txt.meta  + some metadata
```

## Delete + version check (FR-010)

```bash
ETAG=$(./cli/mtls-head.sh --cert "$CERT_DIR/alice.crt" --key "$CERT_DIR/alice.key" \
        --cacert "$CERTS_DIR/server.crt" --server https://localhost:8443 \
        --name archive/notes.txt | awk -F'"' '$1 ~ /ETag/ {print $2}')

./cli/mtls-drop.sh --cert "$CERT_DIR/alice.crt" --key "$CERT_DIR/alice.key" \
   --cacert "$CERTS_DIR/server.crt" --server https://localhost:8443 \
   --source /tmp/bigger-notes.txt --name archive/notes.txt
# expect: (204 overwritten)

./cli/mtls-del.sh --cert "$CERT_DIR/alice.crt" --key "$CERT_DIR/alice.key" \
   --cacert "$CERTS_DIR/server.crt" --server https://localhost:8443 \
   --name archive/notes.txt --if-match "$ETAG"
# expect: (412 precondition failed)
```

## Trust-gate error (untrusted)

```bash
DOM_HOST=$(openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout /tmp/evil.key -out /tmp/evil.crt -subj "/CN=evil")

./cli/mtls-drop.sh --cert /tmp/evil.crt --key /tmp/evil.key \
   --cacert "$CERTS_DIR/server.crt" \
   --server https://localhost:8443 --source /tmp/x --name notes.txt
# expect: (401 unauthorized); wrapper exit status 3
```

## What's left out

- **Locking / dead properties / `Content-Disposition` original-filename**: explicitly out of scope (mod_dav gives what it gives).
- **Recursive-deletes**: N/A. `DELETE` on a non-empty dir is `409 Conflict`.
- **Quotas, TTLs**: deferred features; not in this iteration.

## Run the test suite

```bash
just test-d                                  # D unit tests (no new D modules added — should be unaffected)
just robot                                   # Full Robot suite — extends mtls_hello.robot with drop-box scenarios
bats tests/trust-check.bats                  # trust-check.sh
bats tests/apache.bats                       # Apache baseline + drop-box wiring
```

All existing tests continue to pass; the new ones add the scenarios above.

## Operational notes

- The proxy edge **never** trusts pre-trust-check results; `RewriteMap prg` is the only decision path.
- The loopback VH's `Listen 127.0.0.1:8444` ensures no other interface can reach mod_dav; the public VH is the only forwarder.
- Apache's `LimitRequestBody` governs max file size; tune in `install.sh` if a default of "unlimited" is unwanted.
- Logs: `<data-dir>/apache/{public,backend}-access.log` carry `<caller_cn>` from the standard `%{SSL_CLIENT_S_DN}e` directive.
