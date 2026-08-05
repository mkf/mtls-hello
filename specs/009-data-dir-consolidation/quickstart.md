# Quickstart: Data Directory Consolidation

## Verify baseline

```bash
just test
# All 37 tests pass before any changes
```

## Manual verification

### 1. Data-dir derives handler path

```bash
# Create a data dir with a handler
DATA_DIR="/tmp/mtls-data-$$"
mkdir -p "$DATA_DIR/handlers"
cat > "$DATA_DIR/handlers/hello.get.sh" <<'EOF'
#!/bin/bash
echo "hello from data-dir"
EOF
chmod +x "$DATA_DIR/handlers/hello.get.sh"

# Start server with data-dir (no --handlers-dir)
./mtls-hello 18443 certs/certs/server.crt certs/private/server.key \
  --trust-dir certs/certs \
  --purgatory-dir /tmp/purg \
  --data-dir "$DATA_DIR"

# In another terminal:
curl -sS --cacert certs/certs/ca.crt \
  --cert certs/certs/client.crt --key certs/private/client.key \
  https://localhost:18443/hello
# → "hello from data-dir"
```

### 2. Data-dir derives callback path

```bash
DATA_DIR="/tmp/mtls-data-$$"
mkdir -p "$DATA_DIR/scripts"
cp scripts/on-discover.sh "$DATA_DIR/scripts/on-discover.sh"

./mtls-hello 18443 certs/certs/server.crt certs/private/server.key \
  --trust-dir certs/certs \
  --purgatory-dir /tmp/purg \
  --data-dir "$DATA_DIR"
# Server log should show no warning about missing callback script
```

### 3. Explicit override wins

```bash
DATA_DIR="/tmp/mtls-data-$$"
mkdir -p "$DATA_DIR/handlers" /tmp/custom-handlers

cat > /tmp/custom-handlers/echo.get.sh <<'EOF'
#!/bin/bash
echo "custom"
EOF
chmod +x /tmp/custom-handlers/echo.get.sh

./mtls-hello 18443 certs/certs/server.crt certs/private/server.key \
  --trust-dir certs/certs \
  --purgatory-dir /tmp/purg \
  --data-dir "$DATA_DIR" \
  --handlers-dir /tmp/custom-handlers

curl ... https://localhost:18443/echo
# → "custom" (not from data-dir/handlers)
```

### 4. install.sh creates expected tree

```bash
HOME=/tmp/mtls-home-$$ just install

ls -R ~/.local/share/mtls-hello/
# handlers/
#   bundle.post.sh
# scripts/
#   on-discover.sh
#   (any .new stub files)

# systemd unit uses --data-dir
HOME=/tmp/mtls-home-$$ just install-service
grep 'data-dir' ~/.config/systemd/user/mtls-hello.service
# → --data-dir=%h/.local/share/mtls-hello
```

### 5. Backward compatibility

```bash
# Without --data-dir, existing flags work as before
./mtls-hello 18443 certs/certs/server.crt certs/private/server.key \
  --handlers-dir /tmp/handlers --no-multicast
# → handlers loaded from /tmp/handlers

CALLBACK_SCRIPT=/tmp/my-callback.sh ./mtls-hello ...
# → callback uses /tmp/my-callback.sh
```
