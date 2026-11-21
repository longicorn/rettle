# Product Requirements Document (PRD) - Rettle Report Subsystem

[日本語 (Japanese)](prd.ja.md)

## 1. Overview & Objectives

### 1.1 Overview
The Report subsystem provides a structured, pluggable reporting and auditability framework for Rettle pipelines. Based on the Reporter pattern, it captures lifecycle events, operational milestones, execution provenance, and task metrics, persisting them to an external database (e.g., via ActiveRecord in Rails environments) or falling back to structured log output via `Rettle::Logger`.

### 1.2 Purpose & Context
In automated batch processing infrastructures (such as ActiveJob and Solid Queue workflows within Rails applications), tracking the exact provenance and execution history of data pipelines is critical. Prior to this subsystem, developers had no standardized mechanism to observe:
* When a pipeline and its constituent tasks started and finished.
* Where data was fetched from and with what metadata (e.g., source URL, ETag, file size, hash).
* Execution results, throughput metrics, or failure diagnostics.

Unlike the `Logger` subsystem—which handles high-frequency, granular text logging—the `Report` subsystem focuses on **data provenance, execution evidence, and auditability**. It records milestone-level metadata and lifecycle states so that operators and downstream systems can verify and query pipeline executions without wading through raw logs.

---

## 2. Target Users & Scope

### 2.1 Target Users
* **Batch & Data Engineers**: Building reliable ETL pipelines that require formal audit trails, execution histories, and operational monitoring.
* **Rails Application Developers**: Running background jobs with ActiveJob / Solid Queue who need seamless database persistence of ETL run histories into custom execution tables.

### 2.2 In Scope
* **Reporter Pattern & Pluggable Backends**:
  * `Rettle::Reporter::Base`: Abstract interface defining report notification contracts.
  * `Rettle::Reporter::ActiveRecordReporter`: Persists execution reports to an ActiveRecord model/table when configured.
  * `Rettle::Reporter::LoggerReporter`: Default fallback that outputs structured lifecycle events and metrics to `Rettle.logger`.
* **Configuration Layer (`Rettle::Configuration`)**:
  * Global and instance-level configuration (`Rettle.configure` block, `Rettle::Configuration.new`, or `Rettle.new(config: ...)`).
  * Flexible specification of reporting targets (e.g., `config.report_model = JobExecutionHistory`).
* **Automated Framework Reporting (Lifecycle Hooks)**:
  * Pipeline lifecycle: `pipeline_started`, `pipeline_finished`, `pipeline_failed`.
  * Task lifecycle: `task_started`, `task_finished`, `task_failed`.
  * Automatic capture of task duration, timestamps, status, and failure exceptions.
  * Integration with built-in routines (e.g., download operations automatically reporting source URI, ETag, and file size).
* **Explicit User Reporting API (`task.report`)**:
  * Intuitive interface (`task.report(metrics = {}, **metadata)`) for tasks to record milestone data, processed records, and domain-specific evidence.
* **Execution Identity & Context**:
  * Unique `execution_id` generated per pipeline run.
  * Passing custom context/metadata (e.g., `job_id`, `queue_name`, parameters) from callers to report records.

### 2.3 Out of Scope
* High-frequency per-row logging (delegated to the `Logger` subsystem or in-memory accumulation).
* Hard gem dependencies on `activerecord` in Rettle core (ActiveRecord integration relies on duck typing and optional adapters).
* Pre-packaged database migrations or fixed table schemas (Rettle provides schema-flexible mapping to accommodate host application requirements).

---

## 3. Core Capabilities & Feature Map

| Capability | Feature | Behavior | Priority |
| :--- | :--- | :--- | :--- |
| **Reporter Abstraction** | `Rettle::Reporter::Base` | Base interface for dispatching report events | High |
| **Default Log Reporter** | `Rettle::Reporter::LoggerReporter` | Emits structured lifecycle and metric events via `Rettle.logger` when no DB model is set | High |
| **ActiveRecord Reporter** | `Rettle::Reporter::ActiveRecordReporter` | Persists reports to the configured ActiveRecord model | High |
| **Configuration Integration** | `Rettle.configure` / `Rettle::Configuration` | Manages global/instance settings including `report_model` | High |
| **Automatic Lifecycle Reports** | Pipeline & Task lifecycle hooks | Automatically emits started, finished, and failed events with timestamps and errors | High |
| **Data Fetch Provenance** | Downloader integration | Automatically records download metadata (source URL, content length, ETag) | High |
| **Explicit Task Reporting** | `task.report(data)` | Allows user tasks to record custom metrics, processed counts, and milestone evidence | High |
| **Execution Context Propagation** | `Rettle.new(context: {...})` | Propagates external identifiers (e.g., `job_id`) to all task reports | Medium |
| **Custom Reporter Injection** | `config.reporter = CustomReporter.new` | Enables users to provide completely custom reporting sinks (e.g., Webhooks, StatsD) | Medium |

---

## 4. Architectural & Design Decisions

### 4.1 Reporter Pattern Architecture
* The framework maintains an active reporter instance (`@reporter`) derived from configuration:
  * If a `report_model` is specified, an `ActiveRecordReporter` instance is initialized.
  * If an explicit `reporter` instance is supplied, that instance is used.
  * Otherwise, a `LoggerReporter` instance is utilized by default.
* Events dispatched through the reporter:
  * `#report_pipeline_start(execution_id, context)`
  * `#report_pipeline_finish(execution_id, status, error: nil)`
  * `#report_task_start(execution_id, task_type, task_name, started_at)`
  * `#report_task_finish(execution_id, task_name, status, finished_at, duration, metrics: {}, error: nil)`
  * `#report_task_event(execution_id, task_name, event_data)`

### 4.2 Explicit Reporting via `task.report`
* `task.report` is designed for **evidence capture**, not streaming log output:
  * When invoked (e.g., `task.report(fetched_count: 1500, source_etag: "abc")`), it updates the internal metrics state of the task.
  * Upon task completion, accumulated metrics are automatically passed to `#report_task_finish`.
  * Direct intermediate events can also be forwarded to the reporter if immediate capture is desired.

### 4.3 Database Schema Flexibility
* To prevent tight coupling, `ActiveRecordReporter` does not mandate a rigid schema. It maps reported attributes using duck typing:
  * Standard attributes: `execution_id`, `task_name`, `task_type`, `status` (`running`, `success`, `failed`), `started_at`, `finished_at`, `duration_seconds`, `error_message`, `error_backtrace`, and `metrics` (stored in JSON/JSONB or serialized columns).
  * Missing columns on the model are skipped or absorbed into a flexible metadata payload if supported.

---

## 5. Non-Functional Requirements & Operational Considerations

### 5.1 Thread Safety & DB Connection Pool
* Rettle runs pipeline tasks concurrently in separate threads.
* `ActiveRecordReporter` must ensure that database interactions are executed within `ActiveRecord::Base.connection_pool.with_connection { ... }` blocks to prevent thread-safety hazards, connection pool exhaustion, or leaks.

### 5.2 Fail-Safe Execution (Non-Blocking Diagnostics)
* Reporting operations must never cause the core ETL pipeline to crash.
* Any exceptions raised within reporter persistence logic (e.g., database timeout or validation failure) must be caught, logged as errors via `Rettle.logger`, and suppressed from aborting the pipeline by default.

### 5.3 Low Overhead & Framework Independence
* Rettle core remains lightweight with zero mandatory runtime dependencies on Rails or ActiveRecord gems.
* In environments without ActiveRecord, `LoggerReporter` operates transparently with zero performance overhead.

---

## 6. Primary User Scenarios

### Scenario 1: Standalone Ruby Script (Default Logger Reporter)
```ruby
etl = Rettle.new

etl.define_task(:extract, 'fetch_data') do |task|
  task.report(records: 50)
end

etl.run
# Automatically emits structured JSON/text lifecycle logs via Rettle.logger
```

### Scenario 2: Rails Batch with ActiveRecord Model
```ruby
# config/initializers/rettle.rb
Rettle.configure do |config|
  config.report_model = BatchJobExecution
end

# In ActiveJob / Solid Queue job
class DailySyncJob < ApplicationJob
  def perform
    etl = Rettle.new(context: { job_id: job_id, queue: queue_name })
    
    etl.define_task(:extract, 'download_catalog') do |task|
      # default_downloader automatically reports: uri, etag, bytes
      task.download(url: "https://example.com/catalog.zip")
      task.report(imported_rows: 12_000)
    end
    
    etl.run
  end
end
# Automatically records start, completion, metrics, and error status to batch_job_executions table.
```
