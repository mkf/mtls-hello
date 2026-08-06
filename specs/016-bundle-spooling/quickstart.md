# Quickstart: Bundle Spooling

## Sender side (automatic via discovery)

When `on-discover.sh` runs:
1. Queries `GET /spool?repo=name` on the peer
2. Computes uncovered commit ranges
3. Creates bundles with `git bundle create`
4. POSTs each bundle with `from`/`to` SHA params
5. Peer spools the bundle (doesn't apply immediately)

## Receiver side (automatic)

The server's `bundle.post.sh` handler:
1. Receives the POST
2. Writes bundle to `<data-dir>/spool/<repo>/<from>-<to>.bundle.tmp`
3. Renames to `.bundle` (atomic)
4. Returns `200 spooled`

## Operator: merge spooled bundles

```bash
# Merge all repos
bash scripts/merge-spool.sh

# Merge specific repo only
bash scripts/merge-spool.sh laptops

# Check what's in the spool
ls ~/.local/share/mtls-hello/spool/
```

## Verify

```bash
# After merge, check the bare repo
git -C ~/.local/state/REPOS_ROOT/laptops.git for-each-ref refs/heads/

# Spool should be empty after successful merge
ls ~/.local/share/mtls-hello/spool/laptops/
```

## Backward compatibility

- Old server + new sender: old server applies immediately, sender gets 200
- New server + old sender: new server spools, old sender gets 200
- Mixed: no breakage, just different apply timing
