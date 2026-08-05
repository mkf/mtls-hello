# Contract: Multicast Discovery Announcement (Updated)

**Branch**: `008-wire-discovery-callback` | **Date**: 2026-08-05 | **Feature**: [spec.md](../spec.md)

Supersedes the announcement format in `specs/001-mtls-echo-discovery/contracts/discovery.md`.

## Payload

UDP multicast packet containing a single JSON object terminated with a newline:

```json
{"service":"mtls-hello","port":8443,"host":"alpha"}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `service` | string | Yes | Always `"mtls-hello"` |
| `port` | number | Yes | Sender's HTTPS listen port |
| `host` | string | Yes | Sender's hostname (from `HOST_NAME` env var, defaults to `"localhost"`) |

## Backward Compatibility

- The `host` field is new in this feature. Older servers will ignore it (unknown JSON keys are silently skipped).
- When `host` is missing from a received announcement (old sender), the receiving server treats it as if the hostname were `"localhost"` — the callback will attempt `PEER_CERT_FILE=<trustDir>/localhost.crt`.

## Size Constraints

- Maximum payload: 1024 bytes (current receive buffer size).
- Typical payload with hostname: ~60 bytes. Well within limits.

## Send Behavior

- Sent every `--multicast-interval` seconds (default: 5).
- TTL = 1 (LAN-local only).
- Loopback enabled (same-host peers see each other).
- UDP port: configurable via `--multicast-port` (default: 4242).
