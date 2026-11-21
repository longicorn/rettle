# Architecture Decision Record (ADR) - Rettle Task Subsystem

[日本語 (Japanese)](adr.ja.md)

* **Status**: Accepted
* **Date**: 2026-11-21
* **Deciders**: Rettle Core Contributors
* **Consulted**: `docs/task/prd.md`, `lib/rettle/task*.rb`, `lib/rettle/network.rb`

---

## 1. Context & Problem Statement

Rettle is a code-first ETL framework in Ruby. An ETL pipeline consists of discrete data ingestion, transformation, and export steps arranged as a directed acyclic graph.

In defining the `Rettle::Task` subsystem, we must address three fundamental architectural challenges:
1. **Concurrency and Extensibility**: How can task execution remain decoupled from the underlying concurrency mechanism (threads, processes, or actors) while preserving a clean, uniform DSL for pipeline developers?
2. **Backpressure and Streaming Communication**: How should tasks transfer streaming data records without risking unbounded memory growth or complex synchronization protocols?
3. **Supervision and Error Semantics**: How should failures in concurrently running tasks be detected and handled to maintain data consistency across the pipeline?

---

## 2. Decision Summary

| Decision Area | Chosen Approach | Primary Rationale |
| :--- | :--- | :--- |
| **Execution Model** | Abstract Processing Unit with Pluggable Backend (Current: `Thread`) | Decouples task logic from concurrency; enables future multi-process (`fork`) or `Ractor` execution without changing pipeline DSL. |
| **Data Flow & Backpressure** | Bounded Channel via `Rettle::Network` (`SizedQueue` / `IO.pipe`) | Enforces backpressure naturally by blocking upstream senders; prevents out-of-memory errors on high-throughput streams. |
| **Pipeline Supervision** | Fail-Fast IPC Watchdog Pipe | Immediate, atomic abort of the entire pipeline upon any task failure to prevent corrupted or partial data ingestion. |

---

## 3. Architectural Decisions

### 3.1 Decision 1: Task as an Abstract Processing Unit Decoupled from Concurrency Backend

#### Context
A `Task` represents a logical stage in an ETL pipeline (`:extract`, `:transform`, or `:load`). Initially, Rettle executed tasks concurrently within standard Ruby threads. However, different ETL workloads exhibit different performance characteristics:
* I/O-bound pipelines benefit from lightweight threads.
* CPU-heavy transformations (e.g., intensive parsing, compression, cryptography) are constrained by Ruby's Global VM Lock (GVL) when running on threads, and benefit from multi-process (`fork`) or actor-based (`Ractor`) execution.

#### Decision
We decouple the **Task Definition** (processing block, streaming I/O API, and domain helper modules) from the **Execution Backend**:
1. **Interface Stability**: Developers define tasks using a unified DSL (`define_task`, `each_recv`, `send`) and type-specific helpers (`TaskCommon`, `TaskExtract`, `TaskTransform`, `TaskLoad`).
2. **Current Baseline**: Tasks run as independent Ruby `Thread` instances managed via `Task#run`.
3. **Pluggable Architecture**: The concurrency execution model is treated as a swappable execution strategy. Future concurrency backends (such as process-based `fork` or `Ractor`) can be introduced without altering pipeline task definitions or data processing logic.

#### Consequences
* **Positive**:
  * Clean separation of concerns between business ETL logic and execution mechanics.
  * Preserves API stability across current and future Rettle versions.
  * Allows scaling execution strategy based on workload characteristics (I/O-heavy vs. CPU-heavy).
* **Negative / Trade-offs**:
  * Task implementations must avoid assumptions specific to in-memory threading (e.g., mutating shared global state) to remain compatible with multi-process or actor backends.

---

### 3.2 Decision 2: Bounded Inter-Task Communication and Built-in Backpressure

#### Context
Pipelines stream data continuously from extract tasks through multiple transform stages to load targets. If upstream extract or transform tasks generate data faster than downstream consumers can process it, unbounded buffers would lead to memory bloat and potential process crashes (Out of Memory).

#### Decision
All inter-task communication is abstracted through the `Rettle::Network` channel layer:
1. **Bounded Buffer**: By default, in-memory channels utilize Ruby's `SizedQueue` with a fixed buffer size (`QUEUE_SIZE = 256`).
2. **Automatic Backpressure**: When a downstream queue reaches capacity, the destination task's `Task#send` call blocks automatically until space becomes available.
3. **IPC Channel Support**: For scenarios spanning process boundaries or file-descriptor-based communication, `Network` provides an alternative `:pipe` mode using Unix `IO.pipe` with hex-encoded `Marshal` serialization.
4. **Lifecycle Signaling**: Upstream tasks signal stream completion by closing downstream network channels upon exiting their execution block, which delivers an explicit end-of-stream signal (`nil`) to downstream `Task#each_recv` iterators.

#### Consequences
* **Positive**:
  * Constant, bounded memory footprint regardless of stream size or rate mismatches.
  * Backpressure is handled transparently by the runtime without explicit flow-control logic in user code.
  * Straightforward serialization model supporting both in-memory and inter-process channels.
* **Negative / Trade-offs**:
  * High-frequency small-object serialization over `:pipe` incurs CPU serialization overhead compared to in-memory queues.

---

### 3.3 Decision 3: Fail-Fast Supervision via IPC Watchdog Pipe

#### Context
In a distributed or concurrent ETL pipeline, if an individual task fails (e.g., due to an unhandled exception or parsing error) while other tasks continue running, downstream tasks may receive partial data, or upstream tasks may run indefinitely, leaving external data stores in an inconsistent or partially loaded state.

#### Decision
Rettle implements a fail-fast supervision model mediated by an IPC watchdog pipe:
1. **Watchdog File Descriptor**: A dedicated IPC pipe (`@watchdog_fd`) is initialized at pipeline startup and passed to all tasks.
2. **Immediate Alerting**: If an unhandled exception occurs inside any task's execution block, the task catches the error, writes an alert flag (`"1"`) to the watchdog pipe, and retains the exception.
3. **Fail-Fast Termination**: The main supervisor monitors the watchdog pipe. Upon receiving an alert signal, it immediately terminates the entire pipeline (killing active threads/processes) and re-raises the original exception to the caller, ensuring that no further partial data processing occurs.

#### Consequences
* **Positive**:
  * Prevents corrupted or partial ETL runs from committing silent inconsistencies to external systems.
  * Works uniformly across thread and process execution boundaries using standard Unix file descriptors.
  * Simple, deterministic failure semantics.
* **Negative / Trade-offs**:
  * Does not support isolated task retry inside the running pipeline; a task failure aborts the pipeline run, requiring pipeline-level orchestration/retry.

---

## 4. References

* **Requirements**: [docs/task/prd.md](prd.md)
* **Implementation**:
  * `lib/rettle/task.rb` (Task lifecycle and abstraction)
  * `lib/rettle/task_common.rb`, `lib/rettle/task_extract.rb`, `lib/rettle/task_transform.rb`, `lib/rettle/task_load.rb`
  * `lib/rettle/network.rb` (Channel abstractions and backpressure)
