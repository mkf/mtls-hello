# Quickstart: Flatten Directory Layout

## What this feature does

The nested `certs/` layout is gone. Trust and purgatory live at the data-dir
root, our own certificate/key live in `identity/`, named after the hostname, and
a non-interactive migration moves existing installs automatically.

## Verify a fresh layout

```bash
just install
ls ~/.local/share/mtls-hello/
# → hosts/ purgatory/ identity/ handlers/ scripts/ apache/ spool/ repos/ ffdc/
ls ~/.local/share/mtls-hello/identity/
# → <hostname>.crt  <hostname>.key
```

No `certs/` directory exists.

## Verify the migration

Create a fake legacy layout and run the helper:

```bash
D=/tmp/mig-demo
mkdir -p "$D/certs/certs" "$D/certs/private" "$D/certs/hosts" "$D/certs/purgatory"
cp ~/.local/share/mtls-hello/identity/$(hostname).crt "$D/certs/certs/server.crt"
cp ~/.local/share/mtls-hello/identity/$(hostname).key "$D/certs/private/server.key"
echo x > "$D/certs/hosts/peer1.crt"
echo y > "$D/certs/purgatory/peer2.fp.crt"

bash scripts/migrate-layout.sh "$D" $(hostname)

# Expect:
ls "$D"          # hosts/ purgatory/ identity/  (no certs/)
ls "$D/identity" # <hostname>.crt  <hostname>.key
ls "$D/hosts"    # peer1.crt
ls "$D/purgatory"# peer2.fp.crt
[ ! -d "$D/certs" ] && echo "legacy removed"
```

Run it a second time — it must be a no-op (exit 0, no output).

## Verify idempotency and no-overwrite

1. Run migration twice → second run no-op.
2. Put a *different* file at `identity/<hostname>.crt` first → migration keeps it
   and warns, does not overwrite.

## Run the tests

```
just test-d
just robot
bats tests/migrate-layout.bats   # once added
```
