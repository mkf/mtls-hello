# Data Model: Mutual-TLS Echo Endpoint with LAN Discovery

**Branch**: `001-mtls-echo-discovery` | **Date**: 2026-08-05 | **Feature**: [spec.md](./spec.md)

The feature has no persistent storage. Two transient conceptual entities model runtime state.

## Service Instance

The running service process.

| Field | Type | Notes |
|---|---|---|
| port | number (1–65535) | HTTPS listen port; default 8443, configurable at startup |
| server identity | certificate (X.509) | Presented to clients during the TLS handshake |
| client trust | CA certificate pool | Used to verify incoming client certificates |
| discovery | DiscoverySettings | Group, port, interval, enabled (see below) |

**Validation rules**: port in 1–65535; certificate files must exist and parse at startup.

## Peer

Another service instance discovered on the LAN.

| Field | Type | Notes |
|---|---|---|
| address | IPv4 | Source address of the received multicast announcement |
| port | number (1–65535) | The peer's HTTPS port, from the announcement payload |
| service | string | Must equal `mtls-hello` to be accepted as a peer |

**Validation rules**: announcement must be valid JSON containing `service == "mtls-hello"` and a numeric `port`; otherwise ignored. Announcements matching the local instance's own port are filtered out (loopback is enabled).

## Relationships

- A **Service Instance** discovers zero or more **Peers** over time.
- Peers are ephemeral: no state is persisted; the set is implicit (re-announced every interval, never tracked beyond logging).

## State Transitions (discovery)

```text
starting → announcing (every interval) ─┐
        → listening (500ms receive timeout) ─┴→ peer announced → log peer
```
