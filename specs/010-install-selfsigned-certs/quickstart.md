# Quickstart: Install-Time Self-Signed Certificates

## Verify baseline

```bash
just test
# All 41 tests pass before any changes
```

## Manual verification

### 1. Install generates self-signed certs

```bash
HOME=/tmp/mtls-cert-test just install

ls -l ~/.local/share/mtls-hello/certs/certs/server.crt
# -rw-r--r-- ... server.crt

ls -l ~/.local/share/mtls-hello/certs/private/server.key
# -rw------- ... server.key   (mode 0600)

# CN matches hostname:
openssl x509 -in ~/.local/share/mtls-hello/certs/certs/server.crt -noout -subject
# subject=CN = <hostname>
```

### 2. Reinstall does not overwrite

```bash
sha256sum ~/.local/share/mtls-hello/certs/certs/server.crt > before.sha
HOME=/tmp/mtls-cert-test just install
sha256sum -c before.sha
# OK — fingerprint unchanged
```

### 3. Service starts with generated certs

```bash
HOME=/tmp/mtls-cert-test just install
HOME=/tmp/mtls-cert-test just install-service

systemctl --user daemon-reload
systemctl --user start mtls-hello
systemctl --user status mtls-hello
# Active: active (running)
```

### 4. Tests generate their own certs

```bash
just test
# All tests pass using per-test self-signed certs (no CA)
```

### 5. No CA anywhere

```bash
find . -name "*ca*" -o -name "*.crt" -o -name "*.key" | grep -v ".git/" | grep -v "/tmp/"
# No committed CA certs or test certs
```
