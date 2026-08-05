# Data Model: Self-Extracting Portable Installer

## Output file

| Field | Source | Example |
|---|---|---|
| File name | `mtls-hello-installer-<hash>-<date>[-dirty].sh` | `mtls-hello-installer-abc1234-20260805-dirty.sh` |
| File permissions | `chmod +x` | `-rwxr-xr-x` |
| Approximate size | 37-40 MB | — |

## Filename components

| Component | Derivation | Example |
|---|---|---|
| `<hash>` | `git rev-parse --short HEAD` (7 chars) | `abc1234` |
| `<date>` | `date +%Y%m%d` | `20260805` |
| `[-dirty]` | Appended if `git status --porcelain` is non-empty | `-dirty` |

## Internal payload (tar.gz)

```
bin/mtls-hello                          # Compiled D binary
lib/mtls-hello/libssl.so.3              # Vendored from Guix environment
lib/mtls-hello/libcrypto.so.3
lib/mtls-hello/libz.so.1
lib/mtls-hello/libphobos2-ldc-shared.so.97
lib/mtls-hello/libdruntime-ldc-shared.so.97
share/mtls-hello/handlers/bundle.post.sh
share/mtls-hello/scripts/on-discover.sh
share/mtls-hello/scripts/pre-push.sh.new
```

## Target install layout (after `bash installer.sh install`)

Same as `just install`:

```
~/.local/bin/mtls-hello
~/.local/lib/mtls-hello/{libssl,libcrypto,libz,libphobos,libdruntime}*.so*
~/.local/share/mtls-hello/handlers/bundle.post.sh
~/.local/share/mtls-hello/scripts/on-discover.sh
~/.local/share/mtls-hello/scripts/pre-push.sh.new
~/.local/share/mtls-hello/certs/certs/server.crt     # Generated on install
~/.local/share/mtls-hello/certs/private/server.key   # Mode 0600
```

## Systemd unit (after `bash installer.sh install-service`)

```
~/.config/systemd/user/mtls-hello.service
```

Unit content is identical to `scripts/install-service.sh` output.
