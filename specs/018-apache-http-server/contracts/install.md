# Contract: Apache Installation and Service Setup

**Feature**: Apache HTTP Server Backend
**Date**: 2026-08-06

## Overview

The project install scripts and native packages are responsible for installing Apache, enabling the required modules, and generating a site configuration that routes requests to the project handlers. The operator must end up with a running Apache instance without manual configuration.

## Install script contract

### Inputs

- `--data-dir PATH`: project data directory. Defaults to `~/.local/share/mtls-hello` if not provided.
- Environment variables: `HOST_NAME`, `OUR_CERT`, `OUR_KEY`, `REPOS_ROOT` (optional).

### Outputs

- Apache installed on the system (if not already present).
- Required Apache modules enabled: `ssl`, `cgi` or `cgid`, `alias` (if needed).
- No Apache development headers or module compilation are required; the project uses the system `mod_ssl` with `SSLOptions +ExportCertData`.
- Generated files:
  - `<data-dir>/certs/certs/server.crt`
  - `<data-dir>/certs/private/server.key`
  - `<data-dir>/apache/site.conf` and `<data-dir>/apache/httpd.conf`
  - `<data-dir>/handlers/*.sh` (default handlers)
  - `<data-dir>/scripts/on-discover.sh` and other helpers
- A systemd user service file installed at `~/.config/systemd/user/mtls-hello.service` (or updated to reference Apache).
- The service is not started automatically; the operator runs `systemctl --user start mtls-hello`.

### Idempotency

- Re-running the install script must not overwrite existing certificates.
- Re-running the install script must regenerate the Apache site config if settings changed.
- Re-running the install script must not duplicate handler files if they already exist.

## Package contract

### Debian package

- Declares `Depends: apache2, openssl`.
- Post-install script (if used) invokes the project install script or documents the manual install step.

### Arch package

- Declares `depends=(apache openssl)`.
- `.install` script (if used) invokes the project install script or documents the manual install step.

## Service contract

- The systemd user unit starts Apache with the generated site config.
- Apache runs as the installing user.
- Logs are written to `<data-dir>/apache/error.log` and `<data-dir>/apache/access.log`.
- If `--data-dir` is not provided and port is 0, the assigned port is written to `<data-dir>/apache/port`.
- Stopping the service stops Apache gracefully.

## Port contract

- The install script may default to a fixed port (e.g., 8443) or support `--port=0` for random.
- For random port, the helper script reads the Apache error log or port file to determine the assigned port and writes it to a user-specified `--port-file` path.
- The generated `httpd.conf` uses the system `mod_ssl` module.
