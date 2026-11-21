# Architecture Decision Records (ADR) - Rettle Network Subsystem

[日本語 (Japanese)](adr.ja.md)

This document records the architectural and design decisions established for the `Rettle::Network` communication subsystem within the Rettle ETL framework.

---

## ADR-NET-001: Transport-Agnostic Channel Abstraction

### Status
Accepted

### Context
ETL pipeline tasks (`extract`, `transform`, `load`) need to stream data across various execution boundaries—such as threads within a single Ruby process, separate child processes, or potentially distributed remote nodes. If task implementations were tightly coupled to specific concurrency primitives (e.g., directly calling `Thread::Queue#push` or reading from file descriptors), swapping concurrency models or introducing remote worker capabilities would require extensive refactoring of user-facing task definitions and pipeline orchestration logic.

### Decision
* Encapsulate all low-level transmission, buffering, and serialization logic inside the `Rettle::Network` class.
* Expose a uniform, synchronous channel interface:
  * `read`: Consumes and returns the next object from the channel, returning `nil` on stream closure/EOF.
  * `write(data)`: Serializes (if required) and transmits data into the channel, blocking if buffer capacity is saturated.
  * `close`: Closes the transmission end of the channel, signaling completion to downstream consumers.
* Tasks interact with the network exclusively through `Task#send` (which calls `Network#write`) and `Task#each_recv` (which iterates over `Network#read` until `nil`).

### Consequences
* **Positive**:
  * Complete decoupling of ETL business logic from data transport mechanisms.
  * Pipeline concurrency mode can be switched between threads, processes, or future network sockets by simply specifying the transport type on initialization.
  * Simplified unit testing using mock transports.
* **Negative**:
  * Minor indirection overhead compared to direct in-memory variable passing.

---

## ADR-NET-002: Dual Concurrency Transport Strategy (`:queue` and `:pipe`)

### Status
Accepted

### Context
Rettle pipelines support both multi-threaded and multi-process execution models:
1. Multi-threaded execution benefits from shared process memory, low latency, and zero object copying.
2. Multi-process execution isolates tasks into dedicated OS processes, bypassing Ruby GVL limitations on CPU-bound workloads and providing process crash isolation.

A single transport mechanism cannot optimally serve both scenarios: in-memory queues cannot bridge separate processes, while inter-process pipes introduce serialization overhead unnecessary for threads.

### Decision
* Provide two first-class transport implementations selectable via `type`:
  1. **Thread Transport (`type: :queue`)**:
     * Backed by `Thread::SizedQueue.new(256)`.
     * Operates purely in-memory with zero serialization or copy overhead.
     * Enforces backpressure by suspending the calling thread when the queue reaches 256 items.
  2. **Process Transport (`type: :pipe`)**:
     * Backed by `IO.pipe` (anonymous unidirectional Unix pipe).
     * Provides clean process separation suitable for forked child processes.
     * Enforces OS-level backpressure through kernel pipe buffer blocking when the downstream reader is slow.

### Consequences
* **Positive**:
  * Optimal performance for thread-based pipelines without serialization penalties.
  * Safe, memory-isolated streaming for multi-process pipelines.
  * Consistent backpressure behavior across both concurrency modes, strictly preventing out-of-memory errors.
* **Negative**:
  * Developers must ensure data passed across `:pipe` is serializable via `Marshal`.

---

## ADR-NET-003: Length-Prefixed Hex-Encoded Marshal Wire Protocol

### Status
Accepted

### Context
When streaming arbitrary Ruby objects over stream-oriented transports (such as `IO.pipe` or future TCP sockets), the transport operates on a continuous stream of bytes without inherent message boundaries. The protocol must:
1. Reliably delineate distinct message frames without risking data loss or packet fragmentation.
2. Safely serialize complex Ruby objects (hashes, custom models, arrays) without delimiter collision.
3. Handle graceful termination when the writer closes the stream.

### Decision
* Adopt an explicit length-prefixed framing protocol with hexadecimal-encoded `Marshal` serialization for stream transports:
  1. **Serialization**: Convert object to bytes using `Marshal.dump(data)`, then encode as hex string using `.unpack("h*")[0]`.
  2. **Framing Header**: Transmit the payload byte length as an ASCII integer string followed by a newline delimiter (`\n`).
  3. **Payload Transmission**: Transmit the exact hex payload string.
  4. **Reading**: Read the length header via `IO#readline`, read exactly `size` bytes via `IO#read(size)`, decode hex using `[mstr].pack("h*")`, and deserialize via `Marshal.load`.
  5. **Termination**: Return `nil` when `IO#readline` raises `EOFError`.

### Consequences
* **Positive**:
  * Completely immune to payload delimiter collisions.
  * Stream reading is robust against partial reads and fragmentation.
  * Hex representation simplifies stream inspection and debugging.
* **Negative**:
  * Hex encoding doubles payload size on the wire and adds conversion CPU cycles.
  * Architectural roadmap includes transitioning to raw binary 4-byte big-endian length prefixing for performance optimization in high-throughput environments.

---

## ADR-NET-004: Lifecycle Management, EOF Propagation, and Single-Direction Teardown

### Status
Accepted

### Context
In streaming ETL pipelines, downstream tasks must terminate cleanly when upstream stages complete processing. Lingering worker threads or processes holding open file descriptors can cause deadlocks, resource exhaustion, or hanging pipelines.

### Decision
* Enforce a strictly unidirectional streaming lifecycle:
  * Upstream tasks act exclusively as writers to downstream channels.
  * Downstream tasks (`:transform`, `:load`) initialize and own their receiving channel.
  * Upstream tasks receive receiver task network instances during `Rettle#connect`.
* **Graceful Teardown**:
  * Upon exiting the task execution block, `Rettle#connect` automatically calls `close` on all connected downstream task networks.
  * Closing `:pipe` shuts down `@fds[1]` (the write end), causing the reader `@fds[0]` to encounter `EOFError` once buffered data is exhausted.
  * Closing `:queue` invokes `SizedQueue#close`, allowing remaining queued items to be drained before `pop` returns `nil`.
* Downstream tasks process items via `each_recv`, which naturally exits when `read` evaluates to `nil`.

### Consequences
* **Positive**:
  * Elimination of custom termination sentinel tokens (e.g., `:eof` symbols) that could collide with valid pipeline payloads.
  * Automatic, predictable resource cleanup without hanging threads or abandoned pipes.
* **Negative**:
  * Requires strict adherence to the Single Input Principle (one writer connection per channel) to prevent premature channel closure before all upstream producers complete.
