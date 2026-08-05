# Contract: LAN Discovery Protocol

**Branch**: `001-mtls-echo-discovery` | **Date**: 2026-08-05 | **Feature**: [spec.md](../spec.md)

## Transport

- UDP multicast, IPv4 group `239.255.42.42`, port `4242` (defaults).
- TTL = 1 (link-local scope — announcements do not cross routers).
- Loopback enabled (same-host instances discover each other).
- Socket options: `SO_REUSEADDR` so multiple instances can bind the same port on one host.

## Announcement (sent every interval, default 5 s)

```json
{"service":"mtls-hello","port":8443}
```

| Field | Type | Description |
|---|---|---|
| service | string | Fixed value `mtls-hello`; used to filter foreign traffic |
| port | number | Sender's HTTPS port |

## Receive behavior

- Payloads are stripped, parsed as JSON.
- Non-JSON, malformed, or `service != "mtls-hello"` payloads are silently ignored (no effect on service operation).
- Announcements whose `port` equals the receiver's own HTTP port are ignored (loopback self-hearing).
- Valid peer announcements are logged as `[discovery] peer at <addr>:<srcport> -> mtls-hello on port <peerport>`.

## Failure tolerance

- Multicast setup failure (join group, TTL, loopback) logs to stderr and ends the discovery thread only; the HTTP server continues running.
