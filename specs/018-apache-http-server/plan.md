# Implementation Plan: Apache HTTP Server Backend

**Branch**: `018-apache-http-server` | **Date**: 2026-08-06 | **Spec**: `specs/018-apache-http-server/spec.md`

**Input**: Feature specification from `/specs/018-apache-http-server/spec.md`

## Summary

Replace the vibe.d HTTP server with Apache httpd. Apache requests client certificates using `SSLVerifyClient optional_no_ca` and exports the full PEM-encoded client certificate to CGI via `SSLOptions +StdEnvVars +ExportCertData`. The application layer evaluates trust against the project's trust directory and captures unknown certificates into purgatory. No fork of Apache or mod_ssl is required; a no-op informational patch is kept in `patches/` for future reference.

## Technical Context

**Language/Version**: D (discovery/cert helpers), shell (handlers/install), Apache 2.4 configuration.

**Primary Dependencies**: Apache httpd 2.4.x, OpenSSL, `curl`, `openssl`, the existing D build (LDC + dub), shell scripts.

**Storage**: Filesystem directories under `--data-dir`: `hosts/` (trust), `purgatory/` (untrusted), `spool/`, `apache/` (runtime config).

**Testing**: BATS (host tests), Docker-based Debian/Arch package builds.

**Target Platform**: Linux (Debian 12, Arch Linux, openSUSE Tumbleweed for development). Native Debian and Arch packages produced via Docker.

**Project Type**: Systems tool with a shell-script application layer, a D discovery daemon, and Apache as the HTTP server.

**Performance Goals**: Same as prior features: discovery and HTTP handling must keep up with LAN multicast; bundle spooling must handle 50MB bundles.

**Constraints**: No CA infrastructure; ad-hoc self-signed peer certificates only; no system-wide changes by default; user service support; maintainable code.

**Scale/Scope**: Single repository; small codebase; no C module development.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The project constitution template is currently empty/unratified. No explicit constraints are in force beyond the feature spec and `AGENTS.md` guidance. Proceed with planning, documenting the simplified Apache configuration approach.

## Project Structure

### Documentation (this feature)

```text
specs/018-apache-http-server/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
└── tasks.md             # Phase 2 output
```

### Source Code (repository root)

```text
source/                  # D code (no longer an HTTP server)
├── trust.d              # Certificate fingerprint, hostname, purgatory helpers
├── multicast.d          # Discovery worker
└── app.d                # Entry point (discovery + optional Apache lifecycle)

scripts/                 # Shell helpers
├── apache-config.sh     # Generate Apache httpd.conf/site.conf
├── apache-port-helper.sh
├── install.sh           # Install Apache + generate config
├── install-service.sh
└── package-common.sh    # Stage project files into package tree

handlers/                # CGI handlers
├── cert-echo.get.sh
├── hello.get.sh
├── bundle.post.sh
├── spool.get.sh
└── head.get.sh

config/                  # Apache templates
├── apache-site.conf.in
└── apache-httpd.conf.in

patches/                 # Informational patches (no-op for this feature)
└── apache-mod_ssl-optional_no_ca-cert.patch

tests/                   # BATS tests
├── smoke.bats           # Existing tests (migrate to Apache)
└── apache.bats          # Apache-specific tests
```

**Structure Decision**: Apache is the sole HTTP server. The D source remains responsible for discovery and certificate helpers; the shell handlers remain the application layer. Apache ties them together via CGI. No forked C module is required.

## Complexity Tracking

No unjustified complexity. The feature replaces one HTTP server with another standard server and keeps the existing handler model.

## Notes

- Apache is configured with `SSLVerifyClient optional_no_ca` so the handshake always completes, and `SSLOptions +StdEnvVars +ExportCertData` so the full PEM client certificate is exposed to CGI.
- The D binary is no longer an HTTP server. It remains for the multicast discovery thread and certificate helpers.
- The `handlers/` directory scripts remain shell scripts but now read from CGI environment variables instead of being invoked by the D HTTP router.
- A no-op informational patch is kept in `patches/apache-mod_ssl-optional_no_ca-cert.patch` documenting the upstream location where the export behavior could be changed if a fork is ever needed.
