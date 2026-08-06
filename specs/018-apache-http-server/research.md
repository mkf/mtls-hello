# Research: Apache HTTP Server Backend

**Feature**: Apache HTTP Server Backend  
**Date**: 2026-08-06

## Decision: Use Apache with `SSLVerifyClient optional_no_ca`, `SSLOptions +StdEnvVars +ExportCertData`, and CGI backend scripts

**Rationale**:

- Apache's `mod_ssl` supports `SSLVerifyClient optional_no_ca`, which requests a client certificate but does not terminate the handshake for a self-signed or otherwise unverifiable certificate.
- The full PEM-encoded client certificate is exported to CGI only when `SSLOptions +ExportCertData` is set. With `+StdEnvVars` alone, `SSL_CLIENT_CERT` is not populated; only metadata such as `SSL_CLIENT_S_DN_CN`, `SSL_CLIENT_VERIFY`, and `SSL_CLIENT_CERT_RFC4523_CEA` are available.
- Adding `+ExportCertData` exposes `SSL_CLIENT_CERT` (and `SSL_CLIENT_CERT_CHAIN_*`) even when verification fails. The handler can then compute the fingerprint, check the trust directory, and capture the certificate to purgatory if needed.
- This avoids the need to fork or patch `mod_ssl`, which would introduce C build complexity, distro-specific packaging, and ongoing maintenance burden.

## Finding: `SSL_CLIENT_CERT` is available without patching mod_ssl

- In `modules/ssl/ssl_engine_kernel.c` of Apache 2.4, the `ssl_hook_Fixup` function exports `SSL_CLIENT_CERT` only under the `SSL_OPT_EXPORTCERTDATA` option (`+ExportCertData`).
- The lookup path (`ssl_var_lookup` → `ssl_var_lookup_ssl` → `SSL_get_peer_certificate`) returns the certificate regardless of whether verification succeeded, so `+ExportCertData` is sufficient for self-signed/untrusted certificates.
- Verified on openSUSE Tumbleweed (Apache 2.4.67 + OpenSSL 3.5.3) and Arch Linux (Apache 2.4.68 + OpenSSL 3.6.3): the handshake completes, `SSL_CLIENT_VERIFY` reports `FAILED:self-signed certificate`, and `SSL_CLIENT_CERT` contains the full PEM.

## Alternatives considered

- **Fork/patch Apache `mod_ssl`**: Rejected after the above finding. The fork was briefly imported and then reverted because it adds build, packaging, and maintenance complexity without changing behavior. A no-op informational patch is kept in `patches/` for future reference.
- **Keep vibe.d with custom TLS verification**: Rejected because the project is moving to a more standard server that operators already understand.
- **Use nginx with `ssl_verify_client optional_no_ca`**: nginx also exposes `$ssl_client_cert` for self-signed certs, but the user explicitly chose Apache, and the existing handler model maps cleanly to Apache CGI.
- **Use a reverse proxy + Unix socket to a small D server**: Rejected because it adds a process and socket path to manage without gaining significant functionality over Apache CGI.
- **Use Apache `SSLVerifyClient require`**: Rejected because it terminates the handshake for untrusted certificates, preventing the handler from capturing the PEM.

## Apache configuration notes

- A minimal site config needs:
  - `Listen <port>` and `VirtualHost *:<port>`
  - `SSLEngine on`, `SSLCertificateFile`, `SSLCertificateKeyFile`
  - `SSLVerifyClient optional_no_ca`
  - `SSLOptions +StdEnvVars +ExportCertData`
  - `ScriptAlias / /path/to/handlers/` or per-endpoint `ScriptAlias` mappings
  - `Directory` block granting `+ExecCGI` for the handlers directory
- Handlers are shell scripts named `<name>.<method>.sh` (e.g., `hello.get.sh`). The URL `/hello` maps to the `hello` handler with GET method.
- Apache's `mod_cgid` is preferred for threaded MPMs; `mod_cgi` works for prefork. The install script should enable whichever is available.
- Client certificate size is typically small (< 4KB), well within Apache header/environment limits.

## Package dependencies

- Debian: `apache2` package provides `apache2`, `a2enmod`, `a2ensite`. `openssl` is already used by the project.
- Arch: `apache` package provides `httpd`, `apachectl`. `mod_ssl` is included in the Arch `apache` package.
- Both distributions require the `ssl` and `cgi/cgid` modules to be enabled. No development headers are needed for the project itself.

## User service notes

- Apache can run as a user service with a custom configuration directory (`~/.config/mtls-hello/apache/`) and state directory (`~/.local/share/mtls-hello/`).
- The install script will generate a systemd user unit that starts Apache with the project-generated site config.
- Port 0 (random) is supported by Apache via `Listen 0` and reading the assigned port from the error log or a dedicated status file.

## CGI environment contract

- `SSL_CLIENT_CERT`: full PEM-encoded client certificate (empty only if no certificate was presented). Available because `+ExportCertData` is enabled.
- `SSL_CLIENT_VERIFY`: `SUCCESS`, `GENEROUS`, `NONE`, or `FAILED`. With `optional_no_ca` and self-signed certificates, the observed value is `FAILED` followed by the OpenSSL reason, while `SSL_CLIENT_CERT` still contains the full PEM.
- `SSL_CLIENT_S_DN_CN`: certificate common name, available as metadata.

## No-op patch

- `patches/apache-mod_ssl-optional_no_ca-cert.patch` documents the upstream location (`modules/ssl/ssl_engine_kernel.c`) where `SSL_CLIENT_CERT` export is controlled. It adds only a comment and is not applied. It is kept so that if a future Apache version changes this behavior, the project has a documented starting point for a real patch.
