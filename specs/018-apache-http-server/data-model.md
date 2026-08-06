# Data Model: Apache HTTP Server Backend

**Feature**: Apache HTTP Server Backend
**Date**: 2026-08-06

## Overview

The Apache backend feature introduces no new user data entities. It reuses the existing trust/purgatory/handler filesystem model and adds an Apache site configuration artifact that is generated from the project settings. The primary data flow change is that the HTTP request context is now represented as CGI environment variables and stdin/stdout instead of vibe.d request/response objects.

## Existing entities (unchanged semantics)

### Trust Directory

- **Path**: `<data-dir>/hosts/`
- **Contents**: Files named `<hostname>.crt` containing trusted PEM-encoded certificates.
- **Validation**: A client is trusted only if its certificate’s SHA-256 fingerprint matches the file content for the hostname derived from the certificate CN.

### Purgatory Directory

- **Path**: `<data-dir>/purgatory/`
- **Contents**: Files named `<hostname>.<fingerprint>.crt` containing captured untrusted certificates.
- **Deduplication**: Same hostname + fingerprint always maps to the same file.

### Handlers Directory

- **Path**: `<data-dir>/handlers/`
- **Contents**: Shell scripts named `<name>.<method>.sh` invoked by Apache as CGI.
- **Execution**: Apache maps URL paths to scripts and passes HTTP method and client certificate data via CGI environment variables.

### Data Directory

- **Path**: `<data-dir>/` (operator-provided or default).
- **Subdirectories**: `hosts`, `purgatory`, `handlers`, `scripts`, `spool`.

## New entities

### Apache Site Configuration

- **Purpose**: Describes how Apache should listen, terminate TLS, request client certificates, and route requests to handlers.
- **Location**: Generated at `<data-dir>/apache/site.conf` or similar; referenced by the Apache command line or systemd unit.
- **Key fields**:
  - `Listen` directive (port or `0` for random)
  - `VirtualHost` port
  - `SSLCertificateFile` and `SSLCertificateKeyFile` paths
  - `SSLVerifyClient optional_no_ca`
  - `SSLOptions +StdEnvVars`
  - `ScriptAlias` mappings for handler paths
  - `Directory` block for handlers with `+ExecCGI`
  - `SetEnv` directives for `MTLS_DATA_DIR`, `MTLS_TRUST_DIR`, `MTLS_PURGATORY_DIR`

### CGI Request Context

- **Purpose**: Represents the HTTP request and TLS client data passed to a handler script.
- **Source**: Apache environment variables.
- **Fields**:
  - `REQUEST_METHOD`: HTTP verb
  - `PATH_INFO`: URL path
  - `QUERY_STRING`: URL query string
  - `CONTENT_LENGTH`: POST body length
  - `CONTENT_TYPE`: POST body content type
  - `SSL_CLIENT_CERT`: full PEM client certificate. Empty only if no certificate was presented. Available because the Apache site config uses `SSLOptions +StdEnvVars +ExportCertData`; the full PEM is populated even when verification fails.
  - `SSL_CLIENT_VERIFY`: verification status (`SUCCESS`, `GENEROUS`, `NONE`, `FAILED`)
  - `SSL_CLIENT_S_DN_CN`: certificate common name
- **Validation**: Handlers must treat `SSL_CLIENT_VERIFY` values other than `SUCCESS` as untrusted unless the certificate is found in the trust directory.

### Apache Port File

- **Purpose**: Records the OS-assigned port when `Listen 0` is used.
- **Location**: `<data-dir>/apache/port` or path specified by the install script.
- **Lifecycle**: Written by a helper after Apache starts; read by the operator and by tests.

## State transitions

1. **Install**: The install script creates the Apache site config and enables required modules.
2. **Start**: Apache loads the site config and listens on the configured port.
3. **Request**: Apache terminates TLS, populates CGI environment variables, and invokes the handler script.
4. **Trust evaluation**: The handler checks `SSL_CLIENT_VERIFY` and the trust directory.
5. **Capture**: If untrusted and a certificate is present, the handler may capture it to purgatory. `+ExportCertData` provides the full PEM needed for this capture.
6. **Response**: The handler writes the response body and status to stdout.

## Relationships

- One Apache site configuration is generated per project instance (one per `--data-dir`).
- The site configuration references the trust, purgatory, and handlers directories under the same `--data-dir`.
- Multiple peers connect to the same Apache instance; each request has its own CGI request context.
