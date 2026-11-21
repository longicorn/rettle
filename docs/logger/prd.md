# Product Requirements Document (PRD) - Rettle Logger Subsystem

[日本語 (Japanese)](prd.ja.md)

## 1. Overview & Objectives

### 1.1 Overview
The Logger subsystem provides unified, configurable, and thread-safe logging for the Rettle ETL framework. It establishes a standard logging abstraction that integrates seamlessly with Ruby's standard `Logger` as well as application-level loggers (such as `Rails.logger`), replacing ad-hoc stdout/stderr outputs (`puts`, `p`) with structured and contextualized logging.

### 1.2 Purpose & Context
In batch and ETL workflows (e.g., Rails batch infrastructure with ActiveJob / Solid Queue as outlined in feature request #5), jobs require observable and controllable logging. Previously, internal exceptions and diagnostics were either printed directly to standard output or suppressed, making it difficult to integrate with centralized logging platforms, observe concurrent task execution, or adjust verbosity levels.

This subsystem accomplishes the following objectives:
* **Standardized Logging**: Replaces all hardcoded `puts` and `p` calls across Rettle with a configurable logger interface.
* **Framework Agnosticism**: Functions out of the box using Ruby's standard `Logger` without adding hard dependencies on Rails, while allowing simple injection of `Rails.logger` or custom logger instances.
* **Contextual Task Observability**: Automatically tags log entries with task metadata (`type` and `name`) so that concurrent multi-threaded task execution can be easily traced.
* **Developer-Friendly API**: Provides both an expressive shorthand (`task.logger("message")`) and standard level-based method access (`task.logger.info("message")`).

---

## 2. Target Users & Scope

### 2.1 Target Users
* **Ruby & Rails Developers**: Building background jobs and data pipelines that need unified logging matching application standards.
* **Operations & Reliability Engineers**: Monitoring concurrent batch runs, diagnosing task-level exceptions, and streaming structured logs to external aggregators.

### 2.2 In Scope
* **Configuration Layer**:
  * Class-level global configuration (`Rettle.logger = ...`).
  * Instance-level configuration override (`Rettle.new(logger: ...)`).
  * Safe default fallback to `Logger.new($stdout)`.
* **Task Logging Interface (`Task#logger`)**:
  * Shorthand method invocation: `task.logger(message, level: :info)`.
  * Object accessor invocation: `task.logger.info(...)`, `task.logger.warn(...)`, `task.logger.error(...)`, `task.logger.debug(...)`.
  * Automatic prefixing with task context: `[Rettle][<type>:<name>] <message>`.
* **Internal Framework Observability**:
  * Pipeline lifecycle logs (pipeline start, task thread dispatch, pipeline completion).
  * Error and failure logs (task exception reporting with backtrace, watchdog cancellation triggers).
* **Compatibility & Duck Typing**:
  * Compatible with any logger conforming to the standard Ruby `Logger` interface (`debug`, `info`, `warn`, `error`, `fatal`).

### 2.3 Out of Scope
* Direct runtime dependencies on `ActiveSupport::Logger` or Rails gems (must remain framework-agnostic).
* Log persistence to dedicated database tables or remote endpoints within Rettle core (handled by configuring appropriate logger sinks or custom Logger implementations).
* Complex log formatting DSLs or third-party log parsing protocols.

---

## 3. Core Capabilities & Feature Map

| Capability | Feature | Behavior | Priority |
| :--- | :--- | :--- | :--- |
| **Global Logger Configuration** | `Rettle.logger = logger` | Sets the process-wide default logger instance | High |
| **Instance Logger Override** | `Rettle.new(logger: custom)` | Overrides the logger for a specific pipeline instance | High |
| **Default Fallback** | `Logger.new($stdout)` | Provides immediate, zero-configuration out-of-the-box logging | High |
| **Task Direct Log Shorthand** | `task.logger(msg, [level])` | Emits a contextual log message directly (default: `:info`) | High |
| **Task Logger Object Access** | `task.logger.info(msg)` | Proxies to the underlying logger with automatic task context | High |
| **Context Tagging** | `[Rettle][<type>:<name>]` | Prefixes task-generated log messages with task type and name | High |
| **Internal Event Logging** | Lifecycle & error logging | Replaces ad-hoc stdout prints with leveled framework logs | High |

---

## 4. Technical Design & Interface Specifications

### 4.1 Configuration Hierarchy & Resolution
The active logger for an ETL pipeline execution resolves according to the following precedence:
1. **Instance level**: `logger` passed to `Rettle.new(logger: ...)` if provided.
2. **Class level**: `Rettle.logger` if explicitly configured.
3. **Default**: A Ruby standard `Logger.new($stdout)` with default level `Logger::INFO`.

```ruby
# Application initialization (e.g., config/initializers/rettle.rb in Rails)
Rettle.logger = Rails.logger

# Individual pipeline override
etl = Rettle.new(logger: custom_logger)
```

### 4.2 Task Context Logging (`Task#logger`)
Within a task definition block, `task.logger` serves as the primary logging entrypoint:

```ruby
etl.define_task(:extract, 'extract_users') do |task|
  # Shorthand style (defaults to :info)
  task.logger("Fetching user records from remote endpoint...")

  # Shorthand with level
  task.logger("Rate limit threshold nearing capacity", level: :warn)

  # Standard method chaining style
  task.logger.debug("Payload chunk received: 1024 bytes")
  task.logger.error("Failed to parse record id=42")
end
```

#### Context Formatting
When called from a task, the logger wrapper automatically prefixes the message with `[Rettle][<type>:<name>]`:
```text
I, [2026-11-21T16:30:00.000000 #12345]  INFO -- : [Rettle][extract:extract_users] Fetching user records from remote endpoint...
W, [2026-11-21T16:30:05.000000 #12345]  WARN -- : [Rettle][extract:extract_users] Rate limit threshold nearing capacity
```

#### Dual-Mode Invocation Contract
`Task#logger` supports both forms seamlessly:
* When arguments are provided (`task.logger(message, level: :info)` or `task.logger(message, level = :info)`), it logs the message at the specified level directly.
* When called without arguments (`task.logger`), it returns a contextual logger proxy responding to standard logging methods (`debug`, `info`, `warn`, `error`, `fatal`).

### 4.3 Internal Framework Logging
The Rettle pipeline runtime uses the configured logger for operational events:
* **`DEBUG`**: Internal task thread startup, channel creation, and reader/writer stream lifecycle.
* **`INFO`**: Pipeline execution start and normal completion.
* **`WARN`**: Watchdog activation and termination notices sent to sibling task threads.
* **`ERROR`**: Uncaught exceptions in task blocks, including exception class, message, and backtrace.

---

## 5. Non-Functional Requirements

### 5.1 Thread Safety
* Tasks run concurrently on independent Ruby `Thread` instances.
* All log writes must be thread-safe. Standard library `Logger` instances synchronize writes; when custom loggers are used, Rettle must ensure context wrapping does not introduce shared mutable state across threads.

### 5.2 Performance & Overhead
* Log formatting and string concatenation should be evaluated lazily or kept minimal to avoid performance penalties during high-throughput ETL stream processing.

### 5.3 Zero External Dependencies
* The subsystem must rely solely on Ruby standard library components (`logger`). No external gems or framework dependencies may be introduced.

---

## 6. Success Criteria & Verification

* [ ] `Rettle.logger = ...` allows setting a class-level logger.
* [ ] `Rettle.new(logger: ...)` allows overriding the logger per instance.
* [ ] Default execution runs with `Logger.new($stdout)` when unconfigured.
* [ ] `task.logger("msg")` logs with default `:info` level and `[Rettle][<type>:<name>]` prefix.
* [ ] `task.logger("msg", level: :warn)` and `task.logger.warn("msg")` output at the appropriate log levels with context.
* [ ] All framework-level `puts` and `p` calls are eliminated and replaced with logger calls.
* [ ] Multi-threaded concurrent task logging does not interleave corrupted log lines or raise synchronization errors.
