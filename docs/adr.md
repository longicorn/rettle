# Architecture Decision Records (ADR) - Rettle

[日本語 (Japanese)](adr.ja.md)

This document records the architectural and design decisions established for the Rettle ETL framework.

---

## ADR-001: Pipeline Architecture & Concurrent Task Execution

### Status
Accepted

### Context
Data ingestion and ETL workflows naturally divide into distinct phases: data retrieval (Extract), data normalization/enrichment (Transform), and persistence (Load). Monolithic or sequential ETL scripts suffer from tight coupling, high execution latency on I/O-bound operations (such as HTTP downloads or database queries), and difficulties in managing error boundaries between stages.

### Decision
* Adopt a **Pipeline Architecture** where ETL workflows are decomposed into discrete, single-responsibility tasks (`Extractor`, `Transformer`, `Loader`).
* Execute each task concurrently within its own execution context—primarily using Ruby threads (`Thread`), with optional support for forked child processes (`Process`).
* Encapsulate low-level concurrent synchronization (channel initialization, thread joining, termination detection, and socket/pipe cleanup) inside the `Rettle` engine so users only need to define pipeline tasks and their linkages via an intuitive DSL.

### Consequences
* **Positive**: High throughput for I/O-bound workflows; clear separation of concerns; highly readable and testable ETL logic.
* **Negative**: Introduces concurrency complexities under the hood (e.g., race conditions, deadlocks, stream closure handling), which the framework must robustly isolate and manage internally.

---

## ADR-002: Streaming Inter-Task Communication and Backpressure

### Status
Accepted

### Context
Processing large datasets (ranging from hundreds of megabytes to tens of gigabytes) often leads to out-of-memory (OOM) errors if all data is read and held in memory simultaneously. In an unconstrained producer-consumer model, an extractor can easily overwhelm a slower downstream transformer or database loader.

### Decision
* Implement inter-task communication via `Rettle::Network`, leveraging Ruby's native streaming primitives: `IO.pipe` (UNIX pipe semantics) and bounded queues (`SizedQueue` with a default `QUEUE_SIZE = 256`).
* Rely on native OS/runtime blocking: when downstream buffers fill up, the upstream producer's write call blocks until capacity becomes available (automatic backpressure).

### Consequences
* **Positive**: Consistent, minimal memory footprint regardless of total dataset size; robust protection against OOM; natural streaming behavior.
* **Negative**: Requires careful handling of EOF (End-of-File) signals and graceful pipe closure to prevent deadlocks when an error terminates a task prematurely.

---

## ADR-003: Single Input Principle (Disallowing Fan-In / Merging)

### Status
Accepted

### Context
In data pipeline design, directed acyclic graphs (DAGs) can theoretically support both branching (one-to-many fan-out) and merging (many-to-one fan-in). However, supporting multi-input merges introduces severe complexity in termination synchronization (knowing when *all* upstream producers have completed), deadlock resolution, and buffering multiple upstream channels.

### Decision
* Enforce the **Single Input Principle**: each task (especially `Loader`) accepts data from exactly one upstream task.
* **Supported Flow Patterns**:
  * Linear: `Extractor -> Transformer -> Loader` (or `Extractor -> Loader`)
  * Chaining: `Extractor -> Transformer 1 -> Transformer 2 -> Loader`
  * Fan-Out / Branching: `Extractor -> Transformer 1` and `Extractor -> Transformer 2`
* **Prohibited Flow Patterns**:
  * Fan-In / Merging: `(Transformer 1, Transformer 2) -> Loader` is explicitly disallowed.
* If multiple branches need to be loaded, each branch must connect to its own dedicated `Loader`.

### Consequences
* **Positive**: Pipeline lifecycle, termination detection, and resource cleanup remain predictable, robust, and mathematically simple.
* **Negative**: Workflows requiring join/merge operations across parallel streams must perform the merge inside a single transformer or coordinate across distinct pipelines.

---

## ADR-004: Ruby Native Stack, Testing Policy, and Engineering Conventions

### Status
Accepted

### Context
To maintain Rettle as a lightweight, embeddable personal framework suitable for Ruby on Rails integration, external dependencies must be minimized. Consistent coding style, rigorous typing support, and comprehensive test coverage are essential for maintainability.

### Decision
1. **Technology Stack**:
   * Target Ruby 3.x using the Ruby Standard Library (`csv`, `io/wait`, `socket`, `etc`).
   * Avoid heavyweight external dependencies in core runtime.
2. **Testing Standards**:
   * Utilize `Minitest` as the primary testing framework.
   * Adhere to a **Test-First Policy**: write failing tests verifying behavior before implementing new features or bug fixes.
   * Test files reside under `test/` following the `test_{src_file}.rb` naming convention.
3. **Code Style & Documentation**:
   * Use `# frozen_string_literal: true` at the top of all Ruby source files.
   * Maintain 2-space indentation and standard Ruby naming conventions (`snake_case` for methods/variables, `PascalCase` for classes/modules).
   * Document public APIs using YARD annotations.
   * Provide RBS type signatures under `sig/` (e.g., `sig/rettle.rbs`) to support static type checking.

### Consequences
* **Positive**: Zero dependency bloat; frictionless integration into Rails applications; high long-term code quality and stability.
* **Negative**: Core helper functionalities (such as decompression or HTTP fetching) must be implemented using standard libraries or carefully selected lightweight components.
