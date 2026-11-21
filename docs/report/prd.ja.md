# 製品要求仕様書 (PRD) - Rettle Report サブシステム

[English](prd.md)

## 1. 概要と目的

### 1.1 概要
Report サブシステムは、Rettle パイプラインのための構造化されたプラガブルなレポートおよび監査（Auditability）フレームワークを提供します。Reporter パターンに基づき、ライフサイクルイベント、処理マイルストーン、実行証跡（Provenance）、およびタスクメトリクスを収集し、外部データベース（Rails 環境における ActiveRecord など）への永続化、または `Rettle::Logger` を通じた構造化ログ出力（フォールバック）を行います。

### 1.2 目的と背景
Rails アプリケーション内の自動バッチ処理基盤（ActiveJob や Solid Queue ワークフローなど）では、データパイプラインの正確な実行証跡と履歴の追跡が極めて重要です。本サブシステムの導入前は、以下を一元的に観測・記録する標準機能がありませんでした：
* パイプラインおよび構成タスクがいつ開始され、いつ終了したか。
* どのデータソース（URL、ETag、ファイルサイズ、ハッシュ値など）から取得されたか。
* 処理件数、スループットメトリクス、または失敗時のエラー詳細。

高頻度かつ詳細なテキストログを扱う `Logger` サブシステムとは異なり、`Report` サブシステムは **「ETL としての証拠取り（データ証跡、実行証拠、監査可能性）」** に主眼を置きます。生ログを解析することなく、運用者や後続システムがパイプラインの実行結果を照会・検証できるよう、マイルストーン単位のメタデータとライフサイクル状態を記録します。

---

## 2. 対象ユーザーとスコープ

### 2.1 対象ユーザー
* **バッチ・データエンジニア**: 正式な監査ログ、実行履歴、運用監視を必要とする高信頼な ETL パイプラインを構築する開発者。
* **Rails アプリケーション開発者**: ActiveJob / Solid Queue でバックグラウンドジョブを実行し、ETL の実行履歴をカスタムテーブルに自動永続化したい開発者。

### 2.2 スコープ内（In Scope）
* **Reporter パターンと切り替え可能なバックエンド**:
  * `Rettle::Reporter::Base`: レポート通知契約を定義する抽象インターフェース。
  * `Rettle::Reporter::ActiveRecordReporter`: 設定された ActiveRecord モデル/テーブルへ実行レポートを永続化。
  * `Rettle::Reporter::LoggerReporter`: DB モデル未設定時に、構造化されたライフサイクルイベントとメトリクスを `Rettle.logger` に出力するデフォルトフォールバック。
* **設定レイヤー (`Rettle::Configuration`)**:
  * グローバルおよびインスタンス単位の設定（`Rettle.configure` ブロック、`Rettle::Configuration.new`、または `Rettle.new(config: ...)`）。
  * レポート対象モデルの柔軟な指定（例: `config.report_model = JobExecutionHistory`）。
* **フレームワークによる自動レポート（ライフサイクルフック）**:
  * パイプラインライフサイクル: `pipeline_started`, `pipeline_finished`, `pipeline_failed`。
  * タスクライフサイクル: `task_started`, `task_finished`, `task_failed`。
  * タスク所要時間、タイムスタンプ、ステータス、例外情報の自動収集。
  * 組み込みルーチンとの連携（例: ダウンロード処理時に取得元 URI、ETag、ファイルサイズを自動記録）。
* **ユーザー向け明示的レポート API (`task.report`)**:
  * タスク内からマイルストーンデータ、処理件数、ドメイン固有の証拠を記録できる直感的なインターフェース（`task.report(metrics = {}, **metadata)`）。
* **実行識別子とコンテキストの伝播**:
  * パイプライン実行ごとに一意な `execution_id` を自動採番。
  * 呼び出し元から任意の外部コンテキスト（例: `job_id`, `queue_name`, パラメータ）を渡し、レポートレコードへ紐付け。

### 2.3 スコープ外（Out of Scope）
* 1行ごとの高頻度ストリーミングログ出力（`Logger` サブシステムまたはインメモリ集計に委譲）。
* Rettle コアにおける `activerecord` gem へのハードな依存（ダックタイピングとオプショナルなアダプタ設計によりフレームワーク非依存を維持）。
* 固定のデータベースマイグレーションやテーブルスキーマの強制（ホストアプリケーション側の要件に柔軟にマッピング可能とする）。

---

## 3. 主要機能と機能マップ

| 機能領域 | 機能 | 動作仕様 | 優先度 |
| :--- | :--- | :--- | :--- |
| **Reporter 抽象インターフェース** | `Rettle::Reporter::Base` | レポートイベント配信のための基底インターフェース | 高 |
| **デフォルト Log Reporter** | `Rettle::Reporter::LoggerReporter` | DB モデル未指定時に `Rettle.logger` 経由で構造化イベントを出力 | 高 |
| **ActiveRecord Reporter** | `Rettle::Reporter::ActiveRecordReporter` | 指定された ActiveRecord モデルへレポートを永続化 | 高 |
| **設定管理の統合** | `Rettle.configure` / `Rettle::Configuration` | `report_model` を含む全体・個別インスタンス設定を管理 | 高 |
| **自動ライフサイクルレポート** | パイプライン・タスクライフサイクルフック | 開始、終了、失敗イベントをタイムスタンプやエラーと共に自動記録 | 高 |
| **データ取得証跡の自動収集** | ダウンローダー連携 | 取得元 URL、ファイルサイズ、ETag などのメタデータを自動レポート | 高 |
| **明示的タスクレポート** | `task.report(data)` | カスタムメトリクス、処理件数、マイルストーン証拠の記録 | 高 |
| **実行コンテキスト伝播** | `Rettle.new(context: {...})` | 外部識別子（`job_id` 等）を全タスクレポートへ引き継ぎ | 中 |
| **カスタム Reporter 注入** | `config.reporter = CustomReporter.new` | Webhook や StatsD などの独自 Reporter への差し替え | 中 |

---

## 4. アーキテクチャと設計方針

### 4.1 Reporter パターンアーキテクチャ
* 設定に基づき、フレームワークはアクティブな Reporter インスタンス（`@reporter`）を保持：
  * `report_model` が指定されている場合、`ActiveRecordReporter` を初期化。
  * 明示的な `reporter` インスタンスが渡された場合、それを使用。
  * いずれも指定されていない場合、デフォルトで `LoggerReporter` を使用。
* Reporter が受け取る主要イベント:
  * `#report_pipeline_start(execution_id, context)`
  * `#report_pipeline_finish(execution_id, status, error: nil)`
  * `#report_task_start(execution_id, task_type, task_name, started_at)`
  * `#report_task_finish(execution_id, task_name, status, finished_at, duration, metrics: {}, error: nil)`
  * `#report_task_event(execution_id, task_name, event_data)`

### 4.2 `task.report` による明示的レポート
* `task.report` は **証拠・メトリクス収集** を目的として設計されています：
  * 呼び出し時（例: `task.report(fetched_count: 1500, source_etag: "abc")`）、タスク内部のメトリクス状態を更新。
  * タスク終了時に蓄積されたメトリクスが自動的に `#report_task_finish` に統合されて永続化。
  * 必要に応じて中間イベントを即時に Reporter に送ることも可能。

### 4.3 データベーススキーマの柔軟性
* 密結合を防ぐため、`ActiveRecordReporter` は固定スキーマを強制せず、ダックタイピングを用いて属性をマッピングします：
  * 標準属性: `execution_id`, `task_name`, `task_type`, `status` (`running`, `success`, `failed`), `started_at`, `finished_at`, `duration_seconds`, `error_message`, `error_backtrace`, `metrics` (JSON/JSONB カラム等)。
  * モデル側に定義されていない属性は安全にスキップされるか、柔軟なメタデータ属性へ格納。

---

## 5. 非機能要件と運用上の考慮事項

### 5.1 スレッドセーフと DB コネクションプール管理
* Rettle はパイプラインタスクを別スレッドで並行実行します。
* `ActiveRecordReporter` は、各スレッドで DB 操作を行う際に `ActiveRecord::Base.connection_pool.with_connection { ... }` を使用し、コネクション枯渇やリークを確実に防止します。

### 5.2 フェイルセーフ設計（主処理の保護）
* レポート操作の失敗によって ETL パイプライン本体がクラッシュしてはなりません。
* DB タイムアウトやバリデーションエラー等の例外が発生した場合、例外を捕捉して `Rettle.logger` にエラーを出力し、デフォルトではパイプラインの実行を中断させません。

### 5.3 軽量性とフレームワーク非依存
* Rettle コアは Rails や ActiveRecord への必須依存を持ちません。
* ActiveRecord が存在しないプレーンな Ruby 環境でも、`LoggerReporter` によりオーバーヘッドなしで動作します。

---

## 6. 主な利用シナリオ

### シナリオ 1: 単体 Ruby スクリプト（デフォルト LoggerReporter）
```ruby
etl = Rettle.new

etl.define_task(:extract, 'fetch_data') do |task|
  task.report(records: 50)
end

etl.run
# Rettle.logger を通じて構造化されたライフサイクルログが出力される
```

### シナリオ 2: Rails バッチ環境と ActiveRecord モデル連携
```ruby
# config/initializers/rettle.rb
Rettle.configure do |config|
  config.report_model = BatchJobExecution
end

# ActiveJob / Solid Queue 内での実行
class DailySyncJob < ApplicationJob
  def perform
    etl = Rettle.new(context: { job_id: job_id, queue: queue_name })
    
    etl.define_task(:extract, 'download_catalog') do |task|
      # download メソッドにより URL, ETag, バイト数などが自動レポートされる
      task.download(url: "https://example.com/catalog.zip")
      task.report(imported_rows: 12_000)
    end
    
    etl.run
  end
end
# batch_job_executions テーブルへ開始・完了・メトリクス・エラー状態が自動永続化される
```
