# Internal Contract: Capture Queue

## Producer (multicast listener thread)

- Acquire the capture queue mutex.
- Append a `CaptureRequest` to the queue.
- If the queue was empty before the append, signal the condition variable.
- Release the mutex.

## Consumer (vibe.d worker task)

- Acquire the capture queue mutex.
- While the queue is empty and shutdown is not requested, wait on the condition variable with a bounded timeout.
- After waking, if the queue is non-empty, dequeue the first request.
- Release the mutex.
- Process the dequeued request outside the mutex.
- Loop back to the wait step.

## Shutdown

- The shutdown flag is set by the signal handler.
- The worker uses a bounded timeout on the condition wait so it can periodically check the flag and exit promptly.
- Alternatively, the shutdown path can signal the condition variable to wake the worker immediately.

## Invariants

- The queue mutex is held during all queue mutations and condition checks.
- The condition variable is signaled only when the queue transitions from empty to non-empty.
- Requests are processed in FIFO order.
- No request is dropped unless the daemon shuts down before processing it.
