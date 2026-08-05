# Contract: HTTP Endpoint

**Branch**: `001-mtls-echo-discovery` | **Date**: 2026-08-05 | **Feature**: [spec.md](../spec.md)

## Transport

- HTTPS (TLS 1.2/1.3) with **mutual authentication**:
  - Server presents a certificate whose chain is signed by the configured CA.
  - Client MUST present a certificate; the server requires it (`requireCert`).
  - The client certificate MUST chain to the configured CA pool (`checkTrust`) and be valid (`checkCert`).
- Bind addresses: `127.0.0.1` and `::1` by default.

## Request

| Field | Value |
|---|---|
| Method | `GET` |
| Path | any single path segment: `/:whatever` |
| Client auth | certificate, verified as above |

## Response

| Field | Value |
|---|---|
| Status | `200 OK` |
| Content-Type | `text/plain; charset=utf-8` |
| Body | the literal path segment (URL-decoded by the router), e.g. `GET /hello%20world` → body `hello world` |

## Failure modes

| Case | Result |
|---|---|
| No client certificate | TLS handshake fails; no HTTP response |
| Client cert from untrusted CA | TLS handshake fails; no HTTP response |
| Expired/invalid client cert | TLS handshake fails; no HTTP response |
| Non-GET or multi-segment path | Not routed (vibe router default 404/405 behavior) |
| Missing server cert/key at startup | Process exits with error before listening |
