# Architecture Decision Record (ADR) - Rettle Task Subsystem

[日本語 (Japanese)](adr.ja.md)

* **Status**: Accepted
* **Date**: 2026-11-21
* **Deciders**: Rettle Core Contributors
* **Consulted**: `docs/task/prd.md`, `lib/rettle/task*.rb`, `lib/rettle/network.rb`

---

## 1. Context & Problem Statement

Rettle is a code-first ETL framework in Ruby. An ETL pipeline consists of discrete data ingestion, transformation, and export steps arranged as a directed acyclic graph.

In defining and refining the `Rettle::Task` subsystem, we must address key architectural requirements:
1. **Concurrency and Extensibility**: How can task execution remain decoupled from the underlying concurrency mechanism (threads, processes, or actors) while preserving a clean, uniform DSL for pipeline developers?
2. **Backpressure and Streaming Communication**: How should tasks transfer streaming data records without risking unbounded memory growth or complex synchronization protocols?
3. **Supervision and Library-Friendly Error Semantics**: How should failures in concurrently running tasks be detected and propagated to enclosing application frameworks (e.g., ActiveJob, Solid Queue, Rake) without process abortion?
4. **Thread Safety and Process-Global State Hygiene**: How can task helpers perform file, network, and archive operations concurrently without mutating process-wide state (such as `Dir.pwd`)?
5. **Streaming Downloader and Cache Strategy**: How should large data sources be fetched reliably without unbounded memory usage or redundant network transfers?

---

## 2. Decision Summary

| Decision Area | Chosen Approach | Primary Rationale |
| :--- | :--- | :--- |
| **Execution Model** | Abstract Processing Unit with Pluggable Backend (Current: `Thread`) | Decouples task logic from concurrency; enables future multi-process (`fork`) or `Ractor` execution without changing pipeline DSL. |
| **Data Flow & Backpressure** | Bounded Channel via `Rettle::Network` (`SizedQueue` / `IO.pipe`) | Enforces backpressure naturally by blocking upstream senders; prevents out-of-memory errors on high-throughput streams. |
| **Pipeline Supervision & Errors** | Fail-Fast IPC Watchdog Pipe with Re-raised Exceptions | Immediate abort of peer tasks upon failure and propagation of the original exception to caller without invoking `Kernel.exit`. |
| **Thread Safety & State Hygiene** | Complete Elimination of `Dir.chdir` and Class Mutation | Avoids process-global race conditions in multi-threaded workers (Solid Queue); attaches helpers via instance `extend`. |
| **Downloader & Ingestion** | Chunked Disk Streaming with Redirects, Retries & Conditional Cache | Prevents OOM crashes on multi-gigabyte downloads; handles network flakiness; skips redundant processing via 304 Not Modified. |

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
1. **Bounded Buffer**: By default, in-memory channels utilize Ruby's `SizedQueue` with a fixed buffer size (`QUEUE_SIZE = 256`, configurable).
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

### 3.3 Decision 3: Fail-Fast Supervision via IPC Watchdog Pipe with Library Exception Propagation

#### Context
In a distributed or concurrent ETL pipeline, if an individual task fails while peer tasks continue running, downstream tasks may receive partial data, or upstream tasks may run indefinitely, leaving external data stores in an inconsistent state. Furthermore, when Rettle is embedded inside application background workers (such as ActiveJob or Solid Queue), terminating via `exit` kills the entire worker process and prevents retry mechanisms or error tracking from functioning.

#### Decision
Rettle implements a fail-fast supervision model mediated by an IPC watchdog pipe with full exception propagation:
1. **Watchdog File Descriptor**: A dedicated IPC pipe (`@watchdog_fd`) is passed to all tasks upon pipeline initialization.
2. **Immediate Alerting**: When an unhandled exception occurs inside any task's execution block, the task catches the error, writes an alert flag (`"1"`) to the watchdog pipe, and retains the exception instance.
3. **Fail-Fast Termination & Re-raising**: The main supervisor monitors the watchdog pipe. Upon receiving an alert signal, it immediately halts peer tasks (killing active threads/processes) and re-raises the original exception to the caller of `Rettle#run` / `run!`.
4. **No Library `exit`**: The library avoids invoking `Kernel.exit`, behaving as a well-disciplined Ruby library that yields failure control to the enclosing application.

#### Consequences
* **Positive**:
  * Prevents corrupted or partial ETL runs from committing silent inconsistencies to external systems.
  * Integrates seamlessly with Rails / ActiveJob retry policies, error monitoring (Sentry, Honeybadger), and test suites.
  * Works uniformly across thread and process execution boundaries using standard Unix file descriptors.
* **Negative / Trade-offs**:
  * Does not support isolated in-flight task retry inside the running pipeline; a task failure aborts the pipeline run, delegating retry to the pipeline orchestration layer.

---

### 3.4 Decision 4: Thread Safety and Process-Global State Hygiene

#### Context
In concurrent Ruby environments—especially multi-threaded background job workers like Solid Queue or parallel test runners—the current working directory (`Dir.pwd`) is a process-global resource shared by all threads.
Previously, `TaskExtract#download` and `TaskExtract#git_clone` used `Dir.chdir(dir)`. When multiple jobs execute concurrently in different threads of the same process, altering `Dir.chdir` causes catastrophic race conditions, corrupting relative path resolution across independent jobs. Furthermore, including helper modules at the class level (`Task.include`) pollutes the `Task` class across instances.

#### Decision
1. **Elimination of `Dir.chdir`**: Completely remove all invocations of `Dir.chdir` across `TaskExtract#download`, `after_download`, and `git_clone`.
2. **Explicit Directory Targeting**:
   * File operations must compute full paths explicitly using `File.join(dir, ...)`.
   * Git operations must use the directory flag `git -C <dir>` rather than changing directories before running git commands.
   * Archive decompression (ZIP, `.tar.gz`) must extract directly into the target directory without modifying the process working directory.
3. **Instance-Level Module Attachment**: Attach type-specific behavior dynamically to individual task instances via `extend` in `Task#initialize`, ensuring zero class-level mutation or pollution.

#### Consequences
* **Positive**:
  * Full thread safety when running multiple concurrent pipelines within a single multi-threaded process.
  * Safe for integration into Solid Queue, Sidekiq, and parallel test runners.
  * Clean object model without class pollution.
* **Negative / Trade-offs**:
  * All external commands and path resolutions must be authored with explicit destination flags.

---

### 3.5 Decision 5: Robust Streaming Downloader and Cache Strategy

#### Context
The default downloader initially relied on `Net::HTTP.get(uri)`, which reads the entire response into an in-memory string. For large ETL datasets (hundreds of megabytes to gigabytes), this leads to high memory spikes and out-of-memory (OOM) process kills. Additionally, network instability, HTTP redirects (e.g., S3 pre-signed URLs returning 301/302), and redundant re-downloading of unchanged datasets posed reliability and performance issues.

#### Decision
1. **Disk Streaming**: Implement `default_downloader` using `Net::HTTP` chunked streaming (`request_get` + `read_body`) writing directly to temporary and target files, maintaining a near-zero memory footprint regardless of file size.
2. **Network Resilience**:
   * Automatically follow HTTP redirects (301, 302, 307, 308) up to a configurable maximum limit (e.g., 5 hops).
   * Support explicit open and read timeouts.
   * Provide simple retry logic for transient network glitches.
3. **Conditional Requests & Metadata Extraction**:
   * Collect and return download metadata (e.g., `etag`, `last_modified`, `content_length`, `sha256`).
   * Support conditional HTTP requests using `If-None-Match` and `If-Modified-Since`. When an HTTP 304 (Not Modified) response is received, the downloader signals that the target is current, enabling the pipeline to skip redundant downloading, extraction, and downstream processing.
4. **Archive Extensibility**:
   * Support standard archive formats (ZIP, `.tar.gz`, `.gz`) extracted cleanly to the target directory.

#### Consequences
* **Positive**:
  * Predictable, bounded memory consumption even when ingesting massive data files.
  * Resilience against common network and redirect scenarios.
  * Significant bandwidth and compute savings through HTTP 304 caching.
* **Negative / Trade-offs**:
  * Requires downstream tasks to support conditional execution or early-exit signals when a download is skipped via cache.

---

## 4. References

* **Requirements**: [docs/task/prd.md](prd.md)
* **Implementation**:
  * `lib/rettle/task.rb` (Task lifecycle and abstraction)
  * `lib/rettle/task_common.rb`, `lib/rettle/task_extract.rb`, `lib/rettle/task_transform.rb`, `lib/rettle/task_load.rb`
  * `lib/rettle/network.rb` (Channel abstractions and backpressure)
