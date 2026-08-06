# Specification: Battery-Efficient Discovery

**Feature Number**: 019
**Short Name**: battery-efficient-discovery
**Status**: Draft
**Date**: 2026-08-06

## Problem Statement

The mtls-hello discovery daemon keeps the CPU awake and causes the host to heat up even when it is idle. Code inspection suggests two related causes:

1. The outbound peer-certificate capture worker polls the capture queue every 100 milliseconds (`source/app.d`), which is a likely source of continuous CPU wake-ups.
2. Every peer announcement triggers a full TLS handshake to capture the peer certificate and then spawns the discovery callback (`on-discover.sh`), even when the peer is already known and captured. On a busy LAN this creates a continuous stream of expensive work in child processes.

The feature should first confirm the dominant cause with a measurement, then stop repeated work for already-known peers and replace the polling with an event-driven mechanism so the daemon does essentially no work when no peers are present.

## User Scenarios & Testing

### Scenario 1: Idle daemon stays cool

**Given** the daemon is running and no peers are on the network
**When** the daemon is observed for several minutes
**Then** its CPU usage stays near zero and the host does not warm up

### Scenario 2: New peer still triggers immediate capture

**Given** the daemon has been idle for a long time
**When** a peer announcement arrives on the multicast group
**Then** the daemon wakes up, captures the peer certificate, and invokes the callback within a few seconds

### Scenario 3: Multiple peers are handled without head-of-line blocking

**Given** several peer announcements arrive in quick succession
**When** the capture worker processes them
**Then** all requests are eventually captured and all callbacks are spawned without losing work

## Functional Requirements

1. The implementation shall first measure the baseline CPU usage of the discovery process when idle to confirm whether the 100 ms polling loop or repeated capture/callback for known peers is the dominant consumer.
2. The daemon shall not recapture or re-invoke the discovery callback for a peer that is already represented in the trust directory or the purgatory directory.
3. The capture worker shall not poll the queue on a fixed timer when the queue is empty.
4. The capture worker shall block or sleep until a capture request is enqueued, then wake immediately to process it.
4. The mechanism that wakes the worker shall be thread-safe and compatible with the multicast listener thread that enqueues requests.
5. A single worker task shall process queued requests sequentially, preserving the existing order of arrival.
6. The worker shall still shut down cleanly when the daemon receives SIGINT/SIGTERM.
7. The change shall not introduce a busy wait, spinlock, or fixed-interval sleep in the worker's idle path.

## Success Criteria

- With no peer announcements, the discovery process consumes less than 1% CPU on a modern laptop over a 5-minute window.
- A peer announcement is processed (certificate captured, callback spawned) within 2 seconds of arrival.
- After the fix, idle CPU usage of the discovery process is reduced by at least 80% compared to the baseline measurement, or remains near zero if it was already negligible.
- The number of outbound TLS handshakes and discovery callback invocations for already-known peers is reduced to zero.
- The daemon remains responsive to shutdown signals even when the worker is blocked waiting for work.
- The change does not alter the behavior of peer certificate capture, purgatory file naming, or the callback contract.

## Key Entities / Data

- **Capture queue**: the thread-safe queue used by the multicast listener to hand work to the worker.
- **Wake signal**: a condition variable, semaphore, or equivalent that transitions the worker from idle to active.
- **Worker task**: the vibe.d / D task that runs `processCaptureQueue` in `source/app.d`.
- **Shutdown flag**: the existing `g_shutdown` flag that requests worker termination.

## Scope

### In Scope

- Measuring baseline idle CPU usage and callback frequency to confirm the suspected cause.
- Skipping capture and callback for peers already present in the trust or purgatory directories.
- Replacing the 100 ms polling loop in the capture worker with an event-driven wake mechanism.
- Thread-safe signaling between the multicast listener thread and the capture worker.
- Unit tests for the wake/sleep behavior and shutdown path.
- Integration test that confirms the daemon stays idle until a peer appears and then processes the request promptly.

### Out of Scope

- Reducing multicast announcement frequency.
- Reading OS battery state or power profiles.
- Changing the multicast receive timeout, announcement interval, or network behavior.
- Modifying Apache, CGI handlers, certificate trust logic, or sync behavior.
- Pausing discovery when the lid is closed or the screen is locked.

## Assumptions

- The D runtime provides synchronization primitives (condition variable, semaphore, or event) that can wake a sleeping task from another thread.
- The existing capture queue and mutex can be extended with a wake signal without a major redesign.
- The worker currently runs as a single task; it does not need to become a thread pool.

## Dependencies

- Existing capture queue implementation in `source/multicast.d`.
- Existing worker loop in `source/app.d`.
- Existing shutdown flag and signal handling in `source/multicast.d` and `source/app.d`.

## Risks & Mitigations

- **Risk**: A blocking worker could delay shutdown if it is waiting for a signal that never arrives.
  - **Mitigation**: Use a timeout on the wait or signal the condition variable during shutdown so the worker can check the shutdown flag and exit.
- **Risk**: Signaling after every enqueue adds overhead when the queue is non-empty.
  - **Mitigation**: Only signal when the queue transitions from empty to non-empty; the worker will drain the queue before sleeping again.
- **Risk**: Spurious wakeups or missed signals cause the worker to sleep forever.
  - **Mitigation**: Always re-check the queue length after waking and before sleeping, and ensure the mutex is held during the condition check and signal.

## Notes

- The intended solution is a single, focused change: make the existing worker event-driven instead of polling. This avoids platform-specific power APIs and keeps the implementation lean.
- The 100 ms polling loop in `source/app.d` is the specific behavior to replace.
