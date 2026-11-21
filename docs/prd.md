# Product Requirements Document (PRD) - Rettle

[日本語 (Japanese)](prd.ja.md)

## 1. Product Overview & Background

### 1.1. Overview
Rettle is a lightweight, personal ETL (Extract, Transform, Load) framework designed specifically for Ruby and Ruby on Rails environments. It emphasizes simplicity and speed, solving common concurrency and complexity bottlenecks found in traditional ETL tooling while offering an intuitive, native Ruby developer experience.

### 1.2. Background & Problem Statement
Individual developers and small engineering teams face significant friction when implementing data pipelines with existing tools:
* **Excessive Complexity & High Learning Curve**: Many enterprise ETL frameworks (e.g., Apache Airflow, Embulk) are feature-heavy, require complex configuration, and introduce overhead disproportionate to personal or small-to-medium project needs.
* **Concurrency & Parallel Processing Hurdles**: Implementing stable multi-threaded or multi-process execution across pipeline steps (Extract, Transform, Load) is error-prone and complex to configure manually.
* **Developer Experience in Ruby**: Viable options within the Ruby ecosystem are limited (e.g., Kiba is no longer actively maintained). Adopting Python-based or external tooling introduces language fragmentation and impedance mismatch with Ruby applications.
* **Auditability & Traceability**: Demonstrating when, where, and how data was extracted, transformed, and loaded often requires developers to implement custom logging mechanisms from scratch.

### 1.3. Solution Vision
Rettle addresses these challenges by providing:
* **Intuitive Ruby DSL**: An API concise and straightforward enough to grasp immediately, significantly cutting onboarding and development time.
* **Built-in Concurrency**: Multi-threaded and process-based parallel execution of pipeline stages to achieve high throughput on I/O-bound operations.
* **Built-in Routine Helpers**: Standardized helpers for recurring tasks, such as remote file downloading, decompression (e.g., ZIP), encoding normalization, and bulk database inserts.
* **Auditable Logging**: Native logging and execution tracking to verify data integrity and execution provenance.

---

## 2. Target Users & Scope

### 2.1. Target Users
* **Primary**: Individual developers building Ruby on Rails applications who need to implement reliable, high-speed data ingestion pipelines without managing complex external orchestrators.
* **Secondary**: Ruby developers seeking a lightweight, embeddable ETL framework with minimal external dependencies.

### 2.2. In Scope
* Ingestion and transformation of file-based data sources (e.g., CSV, TSV, JSON) into relational databases.
* Multi-threaded and multi-process pipeline execution with backpressure handling.
* Reusable helper modules for downloading, file extraction, encoding conversion, and database loading.
* Lightweight task interconnection and streaming over pipes (`IO.pipe`) or bounded queues (`SizedQueue`).

### 2.3. Out of Scope
* Large-scale distributed workflow orchestration (e.g., distributed cluster scheduling comparable to Apache Airflow).
* Graphical User Interfaces (GUI) for pipeline authoring and monitoring.
* Continuous real-time stream processing engines (e.g., Apache Kafka / Apache Flink equivalents).

---

## 3. Core Solutions & Feature Map

| Core Problem | Solution Feature | Priority |
| :--- | :--- | :--- |
| Large data processing under memory constraints | Streaming data processing with backpressure via pipes and bounded queues | High |
| Complex configuration and steep learning curve | Intuitive DSL centered around `Rettle` and `Rettle::Task` | High |
| Manual concurrency configuration | Parallel task execution engine (`Task#run`) utilizing threads and processes | High |
| Repetitive boilerplate code | Built-in helpers for download, archive extraction, encoding conversion, and batch export | Medium |
| Lack of pipeline auditability | Standardized logging covering execution states, throughput, and error reporting | Medium |

---

## 4. Primary User Scenarios

### Scenario 1: Import External CSV into Database
1. The developer defines an `extract` task specifying the remote download URL and extraction parameters.
2. The developer defines a `transform` task receiving each record from the upstream task, parsing fields, and normalizing schema attributes.
3. The developer defines a `load` task taking transformed records and performing bulk inserts into the destination database.
4. Rettle connects the tasks in a pipeline and executes them concurrently using separate threads.
5. Execution logs capture start times, record counts, and completion statuses.

### Scenario 2: Streaming Large Data Files
1. The developer configures a pipeline processing an exceptionally large CSV file that cannot fit entirely into system memory.
2. The `extract` task streams lines sequentially and transmits them across an `IO.pipe` communication channel.
3. Downstream `transform` and `load` tasks consume rows incrementally, maintaining constant memory overhead through backpressure.

---

## 5. Domain Model & Ubiquitous Language

| Concept | Code Name | Description |
| :--- | :--- | :--- |
| **Framework Engine** | `Rettle` | The core entry point that orchestrates task registration, connection, and execution. |
| **Task** | `Rettle::Task` | Fundamental execution unit representing an ETL phase, executed inside a dedicated thread or process. |
| **Extractor Task** | `Rettle::TaskExtract` / `:extract` | Task responsible for fetching and extracting data from external sources. |
| **Transformer Task** | `Rettle::TaskTransform` / `:transform` | Task responsible for receiving upstream data, applying business rules, and passing results downstream. |
| **Loader Task** | `Rettle::TaskLoad` / `:load` | Task responsible for writing transformed records into the target storage or database. |
| **Network Channel** | `Rettle::Network` | Communication channel between tasks, using `IO.pipe` or `SizedQueue`. |
| **Pipeline** | *(Conceptual)* | The directed data flow graph established by connecting multiple tasks via `connect`. |
