# Contract: LAN Discovery Protocol (Updated)

**Branch**: `002-per-host-cert-hook` | **Date**: 2026-03-19 | **Feature**: [spec.md](../spec.md)

> This contract extends the protocol defined in `specs/001-mtls-echo-discovery/contracts/discovery.md`. Only additions and changes are documented here; the base transport, failure tolerance, and existing fields remain as specified in 001.

## Announcement (updated)

```json
{"service":"mtls-hello","port":8443,"host":"myhost.local"}
```

| Field | Type | Description | Since |
|---|---|---|---|
| service | string | Fixed value `mtls-hello` | 001 |
| port | number | Sender's HTTPS port | 001 |
| host | string | Sender's hostname (from `gethostname`) | 002 |

The `host` field is REQUIRED for 002 peers. A 002 server announces its hostname in every message.

## Backward compatibility

- 001 peers omit `host`. A 002 receiver treats the `host` field as optional during parse.
- Messages without a `host` field are logged as peer announcements but do NOT trigger the callback script (credential lookup requires a hostname).
- Messages from any peer (001 or 002) that match the local hostname AND local HTTP port are filtered as self-announcements and do not trigger callbacks.

## Receive behavior (updated)

| Condition | Behavior |
|---|---|
| Valid message, `host` present, not self | Log peer → resolve credential → spawn callback script |
| Valid message, `host` missing (001 peer) | Log peer → no callback (no hostname for cert lookup) |
| Valid message, `host` present, self | Log self-announcement → no callback (self-filter) |
| Invalid JSON / wrong service | Silently ignored |

## Callback trigger

When a peer announcement triggers the callback, the server spawns the configured `--on-discovery` script with environment variables defined in [callback.md](./callback.md). The spawn is non-blocking; the server continues processing announcements immediately.
