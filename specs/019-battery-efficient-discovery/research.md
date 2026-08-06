# Research: Battery-Efficient Discovery

## Decision

Use D's `core.sync.condition.Condition` to make the capture worker event-driven. The multicast listener thread will hold the queue mutex, enqueue a request, and signal the condition variable. The worker task will wait on the condition variable while the queue is empty and the daemon is not shutting down, waking only when signaled or when a timeout elapses for shutdown checks.

## Rationale

- The D runtime provides `core.sync.condition.Condition`, which is a standard, well-tested primitive for producer/consumer signaling between threads.
- It integrates cleanly with the existing `Mutex` already protecting the capture queue in `source/multicast.d`.
- It allows the worker to block indefinitely (or with a shutdown timeout) without consuming CPU cycles.
- It avoids the need for vibe.d-specific abstractions or external event libraries, keeping the change minimal.

## Alternatives Considered

1. **Polling with a longer interval** (e.g., 1 second or 5 seconds)
   - Rejected because it still wastes CPU and increases peer capture latency.

2. **Busy-wait / spinlock on the queue**
   - Rejected because it would keep the CPU hot and worsen the problem.

3. **Eventcore / vibe.d event loop integration**
   - Rejected because the capture queue is consumed by a vibe.d task, but the producer is a `std.thread` thread. Crossing the event-loop boundary with custom events adds complexity for a single-threaded queue.

4. **Semaphore (`core.sync.semaphore.Semaphore`)**
   - Considered as a simpler alternative. Rejected because a semaphore alone does not let the worker atomically check the queue length and wait; it would require additional synchronization. A condition variable is the idiomatic fit.

## Implementation Notes

- The worker will wait on the condition variable with a bounded timeout (e.g., 1 second) so it can periodically check the shutdown flag even when no work arrives.
- The producer will signal the condition variable only when the queue transitions from empty to non-empty, preventing unnecessary wake-ups when the worker is already busy.
- The existing shutdown flag (`g_shutdown`) remains the authoritative exit signal.
