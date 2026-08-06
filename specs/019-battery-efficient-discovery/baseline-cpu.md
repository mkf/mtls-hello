# Baseline CPU Measurement

**Date**: 2026-08-06
**Command**: `top -b -d 1 -n 15 -p <pid>` on the discovery daemon

## Baseline Result

With the current 100 ms polling loop in `source/app.d`, the discovery process itself shows approximately 0% CPU when no peers are present on the network. This suggests the 100 ms loop is not the dominant battery drain on an idle system.

## Post-Fix Result

After replacing the polling loop with an event-driven condition variable and adding deduplication for already-known peers, the discovery process still shows approximately 0% CPU when no peers are present. The event-driven change is a defensive improvement that removes the fixed wake-up cycle.

## Implication

The likely source of continuous CPU heat is the repeated outbound peer capture and `on-discover.sh` callback for already-known peers. Every multicast announcement triggers a TLS handshake and callback execution, which can be expensive and runs in separate subprocesses not counted in the daemon's own CPU usage. The implementation therefore focuses on deduplicating discovery handling for known peers in addition to making the capture worker event-driven.
