# Data Model: Battery-Efficient Discovery

## Entities

### CaptureRequest

Already defined in `source/multicast.d`. Represents a request to capture a peer's certificate.

| Field | Type | Purpose |
|-------|------|---------|
| peerHost | string | Peer IP address |
| peerPort | ushort | Peer HTTPS port |
| ourCert | string | Path to our client certificate |
| ourKey | string | Path to our client key |
| purgatoryDir | string | Directory for captured certificates |
| callbackScript | string | Path to the discovery callback script |
| hostName | string | Our advertised hostname |
| peerNetloc | string | Peer network location string |
| reposRoot | string | Root directory for bare git repos |

### CaptureQueue

The capture queue is an in-memory, thread-safe queue owned by the multicast module.

| Field | Type | Purpose |
|-------|------|---------|
| requests | CaptureRequest[] | Pending capture requests |
| mutex | Mutex | Protects the queue from concurrent access |
| condition | Condition | Wakes the worker when a request arrives |

### WorkerState

Runtime state of the capture worker task.

| State | Description |
|-------|-------------|
| idle | Worker is blocked waiting for a request or shutdown |
| running | Worker is processing a queued request |
| shutting down | Worker has observed the shutdown flag and is exiting |

## State Transitions

1. `idle` → `running`: Condition variable signaled with a non-empty queue; worker wakes and dequeues a request.
2. `running` → `idle`: Request processed and queue empty; worker waits on the condition variable again.
3. `running` → `running`: Request processed and queue still has items; worker immediately processes the next item without sleeping.
4. `idle` → `shutting down`: Shutdown flag set and condition wait times out or is signaled; worker exits.

## Validation Rules

- The condition variable must be signaled while holding the queue mutex.
- The worker must re-check the queue length after waking to avoid spurious-wakeup issues.
- The worker must not lose a signal if it is not yet waiting: the request remains in the queue and the next wait will see it immediately.
- No new threads are created; the existing vibe.d worker task is reused.
