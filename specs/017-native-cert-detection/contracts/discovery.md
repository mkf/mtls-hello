# Contract: Discovery and Certificate Capture

**Feature**: specs/017-native-cert-detection

## Multicast Announcement

The existing announcement format is unchanged. Each peer broadcasts a JSON object:

```json
{
  "service": "mtls-hello",
  "port": 8443,
  "host": "peer-hostname"
}
```

## Discovery Response

When a peer receives an announcement, the server MUST perform the following steps in order:

1. **Identify peer**: record the sender IP address and the announced port.
2. **Ignore self**: skip announcements whose port matches the listening port and whose source address is local.
3. **Capture certificate**: open an outbound mTLS connection to `https://<sender-ip>:<port>` using the configured client certificate (`OUR_CERT` / `OUR_KEY`). Capture the server certificate presented during the handshake.
4. **Extract identity**: derive the peer hostname from the certificate CN and compute the SHA-256 fingerprint.
5. **Store in purgatory**: write the PEM-encoded certificate to `<purgatoryDir>/<hostname>.<fingerprint>.crt`. If the file already exists, overwrite it (idempotent).
6. **Invoke callback**: spawn the configured callback script with the following environment variables:
   - `HOST_NAME` — the local hostname advertised to peers.
   - `PEER_NETLOC` — `<sender-ip>:<port>`.
   - `PEER_CERT_FILE` — the purgatory path from step 5.
   - `OUR_CERT`, `OUR_KEY`, `REPOS_ROOT` — passed through from the server environment.

## Error Handling

- If the peer is unreachable or the handshake fails, the server MUST log the failure and still invoke the callback with `PEER_CERT_FILE` unset or empty. The callback MUST handle the missing file gracefully.
- If the certificate has no hostname-derived CN, the server MUST log the rejection and skip the capture step.
- If the purgatory directory cannot be created or written, the server MUST log the error and proceed with the callback using the empty `PEER_CERT_FILE`.
