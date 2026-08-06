# Quickstart: Battery-Efficient Discovery

## Verify the Fix

1. Build the daemon:
   ```bash
   just build
   ```

2. Start the daemon on a quiet LAN segment (no peers):
   ```bash
   ./mtls-hello --data-dir /tmp/mtls-battery-test
   ```

3. Measure baseline CPU usage for 60 seconds before the fix (or on a checkout without the fix), then again after the fix:
   ```bash
   pidstat -p $(pgrep -f mtls-hello) 1 60
   ```

4. Expected result: CPU usage drops from a noticeable fraction (due to 100 ms polling) to near 0% when no peers are present.

## Test Peer Responsiveness

1. Start the daemon:
   ```bash
   ./mtls-hello --data-dir /tmp/mtls-battery-test
   ```

2. From another host or container, send a multicast announcement to the same group/port.

3. Observe that the daemon captures the peer certificate and invokes the callback within a few seconds.

## Run the Automated Tests

```bash
just test-d          # D unit tests for the capture queue/condition logic
just robot           # Robot Framework end-to-end tests (including idle behavior if added)
```
