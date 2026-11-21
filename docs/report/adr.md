# Architecture Decision Record (ADR) - Rettle Report Subsystem

[日本語 (Japanese)](adr.ja.md)

* **Status**: Accepted
* **Date**: 2026-11-21
* **Deciders**: Rettle Engineering
* **Related Documents**: [Product Requirements Document (PRD)](prd.md)

---

## 1. Context and Problem Statement

Rettle is a concurrent, multi-threaded ETL framework in Ruby. When running pipelines in automated environments (such as Rails applications powered by ActiveJob / Solid Queue), engineering teams need structured execution evidence, operational metrics, and audit trails.

Previously, Rettle provided:
1. High-frequency textual logging via `Rettle.logger` (introduced in the Logger subsystem).
2. Ad-hoc inspection of task state in memory.

However, standard loggers are not designed for structured execution queries, job-level provenance, or persistence into relational databases. Operating without a formal reporting layer presented several limitations:
* **No Unified Execution Audit**: Lack of standardized records showing when pipelines and individual tasks started, succeeded, or failed, along with their duration and error backtraces.
* **Missing Data Provenance**: No automatic capture of data extraction origins (e.g., source URLs, ETags, download file sizes, checksums).
* **Database Contention & Coupling Risks**: Directly writing audit records from task worker threads into a relational database creates tight coupling to `ActiveRecord`, exhausts connection pools, and introduces I/O latency that stalls concurrent ETL tasks.

Rettle requires an architecturally sound, pluggable reporting framework that decouples task execution from database persistence while maintaining zero external gem dependencies in Rettle core.

---

## 2. Decision Drivers

* **Zero Mandatory Dependencies**: Core Rettle must not require `activerecord`, `activesupport`, or Rails gems. Integration with database persistence must be opt-in and schema-flexible.
* **Pluggable Reporter Pattern**: Support multiple sinks—defaulting to structured output via `Rettle.logger`, enabling persistence to ActiveRecord models when configured, and supporting user-defined custom reporters.
* **I/O Decoupling & Non-Blocking Persistence**: Database writes must never stall concurrent ETL worker threads. Persistence should be offloaded to a dedicated background writer thread.
* **Connection Pool Optimization**: Avoid per-task connection acquisition by channeling database persistence through a single dedicated worker thread within `ActiveRecord::Base.connection_pool.with_connection`.
* **Fail-Safe Reliability**: Reporter exceptions (database network timeouts, validation failures) must be trapped and logged without aborting core ETL pipeline execution.
* **Guaranteed Flush on Completion**: All queued report events must be flushed to the database before pipeline completion or process termination.
* **Ergonomic Task API & Lifecycle Hooks**: Automatic capture of pipeline/task lifecycles and downloader provenance, complemented by an intuitive `task.report(metrics = {}, **metadata)` interface.

---

## 3. Considered Options

* **Option 1: Synchronous Direct Persistence within Task Threads**
  * *Pros*: Simple implementation; events are written immediately at the moment they occur.
  * *Cons*: Every task worker thread acquires database connections from the pool, increasing contention and pool exhaustion risks. Database write latency directly degrades ETL task throughput.
* **Option 2: External Event Bus / PubSub Middleware (e.g., ActiveSupport::Notifications / dry-events)**
  * *Pros*: Highly decoupled pub/sub architecture.
  * *Cons*: Requires external gems or heavyweight subscription machinery. Still requires a dedicated persistence consumer to prevent synchronous I/O blocking.
* **Option 3: Pluggable Reporter Pattern with Dedicated Async Writer Thread (`Thread::Queue`)**
  * *Pros*:
    * Pure Ruby standard library implementation (`Thread::Queue`, `Thread`) with zero external gems.
    * Completely isolates ETL processing threads from database I/O latency.
    * Restricts ActiveRecord connection usage to a single managed worker thread.
    * Controlled flush protocol (`reporter.flush`) guarantees zero data loss upon pipeline termination.
    * Configurable mode (`config.report_async = true/false`) supports both asynchronous production execution and deterministic synchronous test environments.
  * *Cons*: Requires thread lifecycle and graceful queue drain management.

---

## 4. Decision Outcome

Chosen Option: **Option 3: Pluggable Reporter Pattern with Dedicated Async Writer Thread**.

### 4.1 Subsystem Architecture & Reporter Hierarchy

The subsystem consists of three primary components:
1. **Reporter Interface (`Rettle::Reporter::Base`)**: Defines the event dispatch contract.
2. **Reporter Implementations**:
   * `Rettle::Reporter::LoggerReporter`: Default fallback emitting structured log entries via `Rettle.logger`.
   * `Rettle::Reporter::ActiveRecordReporter`: Persists events to an ActiveRecord model using dynamic schema mapping.
   * Custom user reporters adhering to `Rettle::Reporter::Base`.
3. **Async Writer Engine (`Rettle::Reporter::AsyncWriter`)**: In-memory queue and background thread managing asynchronous execution and graceful flushing.

```
+-------------------------------------------------------------------+
|                        Rettle Pipeline                            |
|  [Extract Task]        [Transform Task]        [Load Task]        |
|    Thread 1                Thread 2               Thread 3        |
|        |                       |                      |           |
|        +-----------------------+----------------------+           |
|                                |                                  |
|                                v                                  |
|                     Rettle::Reporter::Base                        |
|                                |                                  |
+--------------------------------+----------------------------------+
                                 |
         +-----------------------+-----------------------+
         |                                               |
         v (default)                                     v (when report_model set)
+-----------------------+                    +------------------------------------+
|  LoggerReporter       |                    | ActiveRecordReporter               |
|  (Rettle.logger)      |                    |  +------------------------------+  |
+-----------------------+                    |  | Thread::Queue (Event Buffer) |  |
                                             |  +--------------+---------------+  |
                                             |                 |                  |
                                             |                 v                  |
                                             |  +------------------------------+  |
                                             |  | Dedicated Writer Thread      |  |
                                             |  | (connection_pool.with_conn)  |  |
                                             |  +--------------+---------------+  |
                                             |                 |                  |
                                             +-----------------+------------------+
                                                               |
                                                               v
                                                    +---------------------+
                                                    | Application DB      |
                                                    | (report_model table)|
                                                    +---------------------+
```

### 4.2 Dedicated Async Writer (`AsyncWriter`) Design

When `report_async` is enabled (default: `true`), `ActiveRecordReporter` delegates write operations through an internal `AsyncWriter`:

1. **Queue Buffering (`Thread::Queue`)**:
   * Emitted events (`pipeline_start`, `task_finish`, etc.) are converted into normalized payload hashes and pushed to a thread-safe `Thread::Queue`.
   * Pushing to `Thread::Queue` is non-blocking and incurs sub-microsecond overhead on task threads.
2. **Dedicated Consumer Thread**:
   * A single daemon worker thread pops events from the queue and persists them to the configured ActiveRecord model.
   * Persistence calls execute inside `ActiveRecord::Base.connection_pool.with_connection { ... }`, ensuring connection leases are localized and returned immediately.
3. **Graceful Flush Protocol (`#flush(timeout: 5)`)**:
   * When `pipeline_finished` or `pipeline_failed` triggers, the pipeline invokes `reporter.flush(timeout: 5)`.
   * The flush method pushes a synchronization sentinel or monitors queue emptiness, waiting up to the configured timeout for the worker thread to persist all remaining events.
4. **Queue Overflow & Backpressure**:
   * To prevent memory leaks during extended database outages, the queue enforces a configurable maximum capacity (`max_queue_size: 1000`).
   * When full, incoming events drop the oldest non-critical events and emit a warning to `Rettle.logger`.
5. **Synchronous Mode Toggle**:
   * In test suites or debugging environments where immediate database inspection is required, users can configure `config.report_async = false` to execute persistence synchronously.

### 4.3 Reporter Contract & Event Types

`Rettle::Reporter::Base` defines the following standard interface:

```ruby
module Rettle
  module Reporter
    class Base
      def report_pipeline_start(execution_id, context = {})
        raise NotImplementedError
      end

      def report_pipeline_finish(execution_id, status, error: nil)
        raise NotImplementedError
      end

      def report_task_start(execution_id, task_type, task_name, started_at)
        raise NotImplementedError
      end

      def report_task_finish(execution_id, task_name, status, finished_at, duration, metrics: {}, error: nil)
        raise NotImplementedError
      end

      def report_task_event(execution_id, task_name, event_data)
        raise NotImplementedError
      end

      def flush(timeout: 5)
        # Default no-op for synchronous reporters
      end
    end
  end
end
```

### 4.4 Explicit API (`task.report`) and Downloader Integration

* **Explicit Task Reporting**:
  ```ruby
  etl.define_task(:extract, 'fetch_users') do |task|
    fetched_count = 1500
    task.report(records: fetched_count, source: "api_v2")
  end
  ```
  `task.report` accumulates key-value metrics on the task instance. Upon task completion, accumulated metrics are merged into `#report_task_finish`.
* **Automated Downloader Provenance**:
  Built-in download routines automatically record:
  * `download_url`: Target URI.
  * `download_etag`: HTTP ETag response header if available.
  * `download_bytes`: Downloaded file byte size.

### 4.5 Configuration Resolution Hierarchy

The active reporter is resolved during `Rettle#initialize`:
1. `options[:reporter]`: Explicit instance supplied to pipeline constructor.
2. `Rettle.configuration.reporter`: Global custom reporter instance.
3. `Rettle.configuration.report_model`: When an ActiveRecord model class is configured, initializes `Rettle::Reporter::ActiveRecordReporter.new(model, async: Rettle.configuration.report_async)`.
4. Fallback Default: `Rettle::Reporter::LoggerReporter.new(Rettle.logger)`.

```ruby
Rettle.configure do |config|
  config.report_model = BatchJobExecution
  config.report_async = true # Default is true
end
```

### 4.6 Schema Flexibility & Duck Typing

`ActiveRecordReporter` does not mandate a rigid database migration. It maps reported data to attributes present on the configured model via reflection (`column_names` / `has_attribute?`):
* Standard mapped fields: `execution_id`, `task_name`, `task_type`, `status`, `started_at`, `finished_at`, `duration_seconds`, `error_message`, `error_backtrace`.
* Unmapped or domain-specific fields are saved to a flexible JSON/JSONB column (such as `metrics`, `payload`, or `metadata`) if present on the target model.

### 4.7 Fail-Safe Execution

All persistence actions are guarded by exception handling:
```ruby
def persist_record(attributes)
  ActiveRecord::Base.connection_pool.with_connection do
    @model.create!(attributes)
  end
rescue StandardError => e
  Rettle.logger.error("[Rettle][Report] Failed to persist report record: #{e.class}: #{e.message}")
end
```
Reporter failures are logged but never interrupt or abort pipeline execution.

---

## 5. Consequences and Trade-offs

### Positive
* **High ETL Throughput**: Dedicated async worker thread ensures database operations add zero latency to concurrent data processing tasks.
* **Connection Conservation**: Uses at most one database connection regardless of how many concurrent tasks execute in the pipeline.
* **Zero External Dependencies in Core**: Relies strictly on standard Ruby threads and queues. ActiveRecord integration is strictly optional.
* **Auditing & Provenance**: First-class tracking of execution history, durations, errors, and download origins.
* **Testability**: Easily switched to synchronous mode (`report_async = false`) for automated tests.

### Negative / Considerations
* **Process Abrupt Termination**: In the event of an uncatchable process kill (`SIGKILL`), unwritten queue items may be lost. The `#flush` protocol mitigates this for standard completions and caught exceptions (`SIGTERM`, `SIGINT`).
* **ActiveRecord Reflection Overhead**: Schema attribute checking is cached on initialization to minimize reflection overhead during event persistence.
