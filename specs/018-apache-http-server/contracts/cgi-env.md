# Contract: CGI Environment Variables

**Feature**: Apache HTTP Server Backend
**Date**: 2026-08-06

## Overview

Apache invokes handler scripts as CGI processes. The following environment variables are available to every handler. Variables marked **required** are guaranteed to be present; variables marked **conditional** may be empty or absent depending on the request or TLS handshake outcome.

## Standard CGI variables

| Variable | Presence | Description |
|----------|----------|-------------|
| `REQUEST_METHOD` | required | HTTP verb: `GET`, `POST`, `HEAD`, etc. |
| `PATH_INFO` | required | URL path after the script alias (e.g., `/hello`). |
| `QUERY_STRING` | required | URL query string without the leading `?` (empty if none). |
| `CONTENT_LENGTH` | conditional | POST body length in bytes; empty for GET. |
| `CONTENT_TYPE` | conditional | POST body content type; empty for GET. |
| `REMOTE_ADDR` | required | Client IP address. |
| `REMOTE_PORT` | required | Client TCP port. |

## TLS / SSL variables

| Variable | Presence | Description |
|----------|----------|-------------|
| `SSL_CLIENT_CERT` | conditional | Full PEM-encoded client certificate. Empty **only** if no certificate was presented. Available because the Apache site config uses `SSLOptions +StdEnvVars +ExportCertData`; the full PEM is populated even when verification fails. |
| `SSL_CLIENT_VERIFY` | required | Verification status: `SUCCESS`, `GENEROUS`, `NONE`, or `FAILED`. |
| `SSL_CLIENT_S_DN` | conditional | Full subject DN of the client certificate. |
| `SSL_CLIENT_S_DN_CN` | conditional | Common Name from the subject DN. |
| `SSL_CLIENT_I_DN` | conditional | Issuer DN of the client certificate. |
| `SSL_PROTOCOL` | required | TLS protocol version (e.g., `TLSv1.3`). |
| `SSL_CIPHER` | required | TLS cipher suite. |
| `SSL_SERVER_CERT` | conditional | Full PEM-encoded server certificate. |

## Project-specific variables

| Variable | Presence | Description |
|----------|----------|-------------|
| `MTLS_DATA_DIR` | required | Project data directory (`--data-dir`). |
| `MTLS_TRUST_DIR` | required | Trust directory path. |
| `MTLS_PURGATORY_DIR` | required | Purgatory directory path. |
| `MTLS_HOST_NAME` | required | Hostname advertised by this instance. |
| `MTLS_REPOS_ROOT` | conditional | Directory containing bare repositories; may be empty if sync is disabled. |
| `MTLS_SCRIPT_TIMEOUT` | required | Maximum seconds a handler script may run. |

## Verification status semantics

- `SUCCESS`: The client certificate is valid and trusted by Apache’s configured CA. In this project, Apache is configured with `optional_no_ca`, so `SUCCESS` is rare; trust is instead checked by the handler against the project trust directory.
- `GENEROUS`: A client certificate was presented but was not verified against a CA. This is the normal case for self-signed peer certificates. The full PEM is available in `SSL_CLIENT_CERT`.
- `NONE`: No client certificate was presented. `SSL_CLIENT_CERT` is empty.
- `FAILED`: An error occurred during client certificate processing. With `SSLOptions +ExportCertData`, the full PEM is still exposed so the handler can capture it.

## Handler responsibilities

- Handlers must not trust a client solely based on `SSL_CLIENT_VERIFY`.
- Handlers must extract the certificate from `SSL_CLIENT_CERT`, compute its fingerprint, and check whether the trust directory contains a matching `<hostname>.crt` file. This works because `+ExportCertData` exposes the full certificate even for untrusted clients.
- If the client is untrusted, the handler may capture the certificate to the purgatory directory using the existing capture helpers.
- Handlers must return a non-zero exit code or write an error status to cause Apache to respond with a 500 error.
