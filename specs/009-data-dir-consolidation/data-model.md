# Data Model: Data Directory Consolidation

## ServerConfig (modified)

| Field | Type | Default | Description |
|---|---|---|---|
| port | ushort | `8443` | HTTPS listen port |
| certFile | string | `"certs/certs/server.crt"` | Server certificate path |
| keyFile | string | `"certs/private/server.key"` | Server key path |
| portFile | string | `""` | Path to write chosen port number |
| **dataDir** | string | **`""`** | **NEW** — Base directory for runtime data (`handlers/`, `scripts/`, future) |
| multicast | MulticastConfig | (existing) | Multicast announcement config |
| handlers | HandlerConfig | (existing) | Handler script configuration |
| trust | TrustConfig | (existing) | Certificate trust configuration |

### Path Resolution Rules

When `dataDir` is non-empty:

```
handlers.handlersDir ← --handlers-dir? → --handlers-dir : dataDir ~ "/handlers"
multicast.callbackScript ← CALLBACK_SCRIPT? → CALLBACK_SCRIPT : dataDir ~ "/scripts/on-discover.sh"
```

When `dataDir` is empty: existing defaults apply (unchanged behavior).

## Install Tree Layout

After `just install`, `~/.local/share/mtls-hello/`:

```
~/.local/share/mtls-hello/
├── handlers/
│   └── bundle.post.sh          # Real handler (existing)
├── scripts/
│   ├── on-discover.sh           # Real script (existing)
│   └── pre-push.sh.new          # Stub (NEW — optional future hook)
```

## Systemd Unit

After `just install-service`:

```ini
ExecStart=%h/.local/bin/mtls-hello \
  --port=0 --port-file=%t/mtls-hello.port \
  --data-dir=%h/.local/share/mtls-hello \
  --no-multicast
```

No `--handlers-dir` or `CALLBACK_SCRIPT` entries — derived from `--data-dir`.
