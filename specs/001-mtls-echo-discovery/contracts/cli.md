# Contract: Startup Configuration (CLI)

**Branch**: `001-mtls-echo-discovery` | **Date**: 2026-08-05 | **Feature**: [spec.md](../spec.md)

## Usage

```text
mtls-hello [port] [serverCert] [serverKey] [options]
```

## Positional arguments

| # | Argument | Default |
|---|---|---|
| 1 | port | `8443` |
| 2 | server certificate (chain) file | `certs/certs/server.crt` |
| 3 | server private key file | `certs/private/server.key` |

Positional parsing stops at the first token starting with `--`.

## Options

| Option | Default | Effect |
|---|---|---|
| `--multicast-group=ADDR` | `239.255.42.42` | Multicast group address |
| `--multicast-port=PORT` | `4242` | Multicast port |
| `--multicast-interval=SECS` | `5` | Announcement interval in seconds |
| `--no-multicast` | (enabled) | Disables announcements and listening entirely |

## Exit behavior

- Invalid port value or missing certificate files → error at startup, non-zero exit.
- Certificate setup or TLS context errors → logged, process exits before listening.
