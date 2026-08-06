# Quickstart: Native Peer Certificate Detection

## What changes

After this feature, `mtls-hello` automatically learns the certificate of every peer it discovers. You no longer need to run `openssl s_client` by hand or copy certificates into the trust directory before the first sync.

## How it works

1. Start your server as usual.
2. When another `mtls-hello` peer appears on the LAN, your server connects back to it, captures its certificate, and stores it in the purgatory directory (`<data-dir>/purgatory/` by default).
3. The discovery callback (`on-discover.sh`) receives the captured certificate path in `PEER_CERT_FILE` and uses it to verify the peer during git sync.
4. You review the purgatory entry and move it to the trust directory when you are ready to trust that host:

   ```bash
   mv ~/.local/share/mtls-hello/purgatory/peer-01.abcdef.crt \
      ~/.local/share/mtls-hello/hosts/peer-01.crt
   ```

## Default paths

When using `--data-dir ~/.local/share/mtls-hello`:

- Purgatory: `~/.local/share/mtls-hello/purgatory/`
- Trust store: `~/.local/share/mtls-hello/hosts/`
- Callback script: `~/.local/share/mtls-hello/scripts/on-discover.sh`

## Verifying capture

After discovery, list purgatory entries:

```bash
ls ~/.local/share/mtls-hello/purgatory/
```

You should see one file per peer hostname, named like `<hostname>.<sha256-fingerprint>.crt`.

## Notes

- The purgatory directory will not fill with duplicates. Capturing the same peer again overwrites the same file because the filename includes the fingerprint.
- If a peer presents a new certificate, a new file appears. The old file remains as a record until you delete it.
- No manual certificate extraction is required for discovery to work.
