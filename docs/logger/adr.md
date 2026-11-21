# Architecture Decision Record (ADR) - Rettle Logger Subsystem

[日本語 (Japanese)](adr.ja.md)

* **Status**: Accepted
* **Date**: 2026-11-21
* **Deciders**: Rettle Engineering
* **Related Documents**: [Product Requirements Document (PRD)](prd.md)

---

## 1. Context and Problem Statement

Rettle is a lightweight, concurrent ETL framework in Ruby that runs tasks across independent threads. Historically, execution diagnostics, task monitoring, and uncaught exceptions relied on ad-hoc standard output prints (`puts`, `p`).

This presented several operational limitations:
1. **Lack of Centralized Integration**: Modern Ruby and Rails batch applications (e.g., ActiveJob / Solid Queue runners) rely on unified logging infrastructure (`Rails.logger`, Syslog, Logstash, Datadog). Hardcoded stdout outputs cannot be captured, routed, or silenced by the host application.
2. **Missing Concurrency Context**: Because tasks execute concurrently across threads, interleaved log messages lacked task identifiers, making debugging and tracing task-specific failures difficult.
3. **No Log Level Control**: Diagnostic outputs could not be suppressed in production or elevated to debug mode without modifying framework source code.

Rettle requires a formal, thread-safe, and framework-agnostic logging subsystem that standardizes internal framework diagnostics and exposes an ergonomic API for task authors.

---

## 2. Decision Drivers

* **Zero External Dependencies**: Must operate using only the Ruby standard library (`logger`) without adding gem dependencies (e.g., ActiveSupport).
* **Framework Agnosticism & Interoperability**: Must work out of the box in standalone Ruby scripts while integrating seamlessly with host application loggers such as `Rails.logger`.
* **Ergonomic Task Authoring**: Task definitions should have direct, intuitive access to logging without manual logger injection or tedious string formatting.
* **Contextual Observability**: Log lines emitted from tasks must automatically capture task metadata (`type` and `name`) to simplify log analysis across concurrent threads.
* **Thread Safety & Performance**: Logging operations must not corrupt log output or degrade pipeline throughput under concurrent load.

---

## 3. Considered Options

* **Option 1: Require `ActiveSupport::TaggedLogging`**
  * *Pros*: Native tagging mechanisms, standard in the Rails ecosystem.
  * *Cons*: Adds a hard dependency on ActiveSupport, violating Rettle's zero-external-dependency principle.
* **Option 2: Direct Logger Pass-Through without Context Wrapping**
  * *Pros*: Minimal implementation complexity.
  * *Cons*: Task authors must manually format messages with task names and types; logs from concurrent tasks remain ambiguous and hard to trace.
* **Option 3: Contextual Proxy Wrapper (`TaskLoggerProxy`) with Dual-Mode Interface**
  * *Pros*: Zero gem dependencies, automatic context tagging (`[Rettle][<type>:<name>]`), supports both concise shorthand (`task.logger("msg")`) and method chaining (`task.logger.info("msg")`), thread-safe, and transparently duck-types against any standard `Logger` compliant instance.
  * *Cons*: Introduces a lightweight wrapper object per task.

---

## 4. Decision Outcome

Chosen Option: **Option 3: Contextual Proxy Wrapper (`TaskLoggerProxy`) with Dual-Mode Interface**.

### 4.1 Configuration Hierarchy and Resolution

Logger configuration is resolved through a three-tier hierarchy:
1. **Instance Override**: Passed via `Rettle.new(logger: custom_logger)`.
2. **Global Default**: Set on the top-level module via `Rettle.logger = custom_logger`.
3. **Fallback Default**: A lazily initialized standard Ruby `Logger` writing to `$stdout` at `Logger::INFO`.

```ruby
module Rettle
  class << self
    attr_accessor :logger

    def default_logger
      @default_logger ||= Logger.new($stdout).tap do |l|
        l.level = Logger::INFO
      end
    end
  end
end
```

Inside an ETL pipeline instance (`Rettle#initialize`), the resolved logger is determined as:
```ruby
@logger = options[:logger] || Rettle.logger || Rettle.default_logger
```

### 4.2 Dual-Mode Task Logging Interface (`Task#logger`)

Within a task definition block, `task.logger` supports both a direct method call and standard level-based method chaining:

1. **Shorthand Invocation**:
   ```ruby
   task.logger("Processing record chunk", level: :info)
   # Defaults to :info if level is omitted:
   task.logger("Fetching remote records")
   ```
2. **Method Chaining Invocation**:
   ```ruby
   task.logger.debug("Received payload chunk of 1024 bytes")
   task.logger.info("Processed 500 items")
   task.logger.warn("Transient network retry attempted")
   task.logger.error("Failed to process record id=42")
   task.logger.fatal("Fatal unrecoverable condition")
   ```

#### Implementation Architecture: `TaskLoggerProxy`
The `Task` class delegates logging to a `TaskLoggerProxy`:
```ruby
class Task
  def logger(message = nil, level: :info, &block)
    @logger_proxy ||= TaskLoggerProxy.new(pipeline.logger, type: @type, name: @name)
    if message || block
      @logger_proxy.public_send(level, message, &block)
    else
      @logger_proxy
    end
  end
end
```

The `TaskLoggerProxy` prefixes every log message with `[Rettle][<type>:<name>]`:
```ruby
class TaskLoggerProxy
  LEVELS = %i[debug info warn error fatal unknown].freeze

  def initialize(target_logger, type:, name:)
    @target_logger = target_logger
    @prefix = "[Rettle][#{type}:#{name}]"
  end

  LEVELS.each do |level|
    define_method(level) do |progname_or_msg = nil, &block|
      if block
        @target_logger.public_send(level) { "#{@prefix} #{block.call}" }
      elsif progname_or_msg
        @target_logger.public_send(level) { "#{@prefix} #{progname_or_msg}" }
      end
    end
  end

  def level
    @target_logger.level
  end

  def level=(val)
    @target_logger.level = val
  end
end
```

### 4.3 Concurrency and Thread Safety

* **I/O Synchronization**: Ruby's standard `Logger` synchronizes log device writes using internal Mutex instances. Delegating directly to the underlying logger preserves thread safety.
* **Stateless Delegation**: `TaskLoggerProxy` maintains immutable references to the target logger and prefix string, introducing no mutable shared state across task threads.

### 4.4 Replacement of Framework Diagnostics

All existing instances of `puts` and `p` are replaced:
* **Task Failure (`Task#run`)**: Uncaught exceptions are logged at `ERROR` level with backtraces:
  ```ruby
  logger.error("Task failed: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
  ```
* **Pipeline Lifecycle**:
  * Pipeline start and completion logged at `INFO`.
  * Task thread spawning and channel connection logged at `DEBUG`.
  * Watchdog task abort notifications logged at `WARN`.

---

## 5. Consequences and Trade-offs

### Positive
* **Seamless Rails Integration**: Setting `Rettle.logger = Rails.logger` directs all ETL framework and task logs to standard Rails logging destinations without friction.
* **Unified Observability**: All logs generated by concurrent tasks are automatically tagged with task context (`[Rettle][<type>:<name>]`), clarifying multi-threaded trace outputs.
* **Zero Dependency Overhead**: Retains pure standard library compatibility with zero external gems.
* **Lazy Evaluation Support**: Passing blocks (`task.logger.debug { expensive_inspection }`) avoids string allocation overhead when debug logging is disabled.

### Negative / Considerations
* **Proxy Allocation**: Allocates a single `TaskLoggerProxy` instance per task. Given that tasks are long-lived throughout pipeline execution, memory overhead is negligible.
* **Logger Duck Typing**: Custom logger implementations must conform to standard Ruby `Logger` conventions (`debug`, `info`, `warn`, `error`, `fatal`). Non-standard loggers may require a minor adapter.
