# アーキテクチャ決定記録 (ADR) - Rettle Report サブシステム

[English](adr.md)

* **ステータス**: 承認済み (Accepted)
* **日付**: 2026-11-21
* **決定者**: Rettle Engineering
* **関連ドキュメント**: [要求仕様書 (PRD)](prd.ja.md)

---

## 1. 背景と課題 (Context and Problem Statement)

Rettle は Ruby で構築された並行マルチスレッド ETL フレームワークです。Rails アプリケーション（ActiveJob や Solid Queue など）をはじめとする自動実行環境でパイプラインを運用する際、エンジニアリングチームには構造化された実行エビデンス、運用メトリクス、監査証跡が不可欠となります。

従来の Rettle では以下の機能を提供していました：
1. `Rettle.logger` による高頻度なテキストログ出力（Logger サブシステムにて導入）。
2. メモリ上でのアドホックなタスク状態の確認。

しかし、標準ロガーは構造化された実行履歴のクエリ、ジョブ単位のデータ出所（Provenance）管理、リレーショナルデータベースへの永続化を想定して設計されていません。公式なレポーティング層が存在しないことには、以下の課題がありました：
* **統一された実行監査の欠落**: パイプラインおよび各タスクがいつ開始・成功・失敗したか、所要時間や例外バックトレースを含む標準化された記録がない。
* **データ出所（Provenance）の喪失**: データ取得元（ダウンロード URL、ETag、ファイルサイズ、チェックサムなど）の自動収集手段がない。
* **DB 競合と密結合のリスク**: 各タスクのワーカースレッドから直接リレーショナルデータベースへ書き込むと、`ActiveRecord` との密結合を招き、コネクションプールを逼迫させ、I/O レイテンシによって並行 ETL タスクが遅延・停止する。

Rettle には、コア gem への外部依存ゼロを維持しつつ、タスクの実行とデータベースへの永続化を分離した、アーキテクチャとして堅牢でプラガブルなレポーティングフレームワークが求められています。

---

## 2. 判断基準 (Decision Drivers)

* **コアの外部依存ゼロ (Zero Mandatory Dependencies)**: Rettle コアは `activerecord`、`activesupport`、および Rails 関連 gem を必須依存としないこと。DB 永続化の連携はオプトインであり、柔軟なスキーマ対応を行うこと。
* **プラガブルなレポーターパターン (Pluggable Reporter Pattern)**: 複数の出力先をサポートすること。未指定時は `Rettle.logger` への構造化ログ出力をデフォルトとし、設定時は ActiveRecord モデルへの永続化、さらにはユーザー独自のカスタムレポーターの注入に対応すること。
* **I/O 分離と非ブロッキング永続化 (I/O Decoupling & Non-Blocking Persistence)**: データベース書き込み処理が並行 ETL ワーカースレッドを絶対にブロッキング（遅延）させないこと。書き込み処理は専用のバックグラウンドワーカースレッドに委譲すること。
* **コネクションプールの最適化 (Connection Pool Optimization)**: タスクごとの個別コネクション取得を避け、単一の専用ワーカースレッドから `ActiveRecord::Base.connection_pool.with_connection` 内で安全に永続化を行うこと。
* **フェイルセーフな信頼性 (Fail-Safe Reliability)**: データベースのネットワークタイムアウトやバリデーションエラー等の例外が発生しても、それを捕捉・ログ記録し、コア ETL パイプラインを中断・停止させないこと。
* **完了時の確実なドレイン (Guaranteed Flush on Completion)**: パイプライン完了時やプロセス終了前に、キューに残った全レポートイベントを確実にデータベースへ書き切る（flush）こと。
* **使いやすいタスク API とライフサイクルフック (Ergonomic Task API & Lifecycle Hooks)**: パイプライン/タスクのライフサイクルおよびダウンローダー出所情報の自動収集に加え、直感的な `task.report(metrics = {}, **metadata)` インターフェースを提供すること。

---

## 3. 検討した選択肢 (Considered Options)

* **Option 1: タスクスレッド内での同期直接書き込み**
  * *メリット*: 実装が単純であり、イベント発生と同時に記録される。
  * *デメリット*: すべてのタスクスレッドがコネクションプールから接続を取得するため、競合およびプール枯渇のリスクが高まる。DB 書き込みのレイテンシが ETL 処理速度を直接低下させる。
* **Option 2: 外部イベントバス / PubSub ミドルウェアの導入 (ActiveSupport::Notifications や dry-events など)**
  * *メリット*: 高度に疎結合な Pub/Sub アーキテクチャを構築できる。
  * *デメリット*: 外部 gem や複雑な購読機構が必要となる。また同期 I/O ブロッキングを防ぐには、結局専用の永続化ワーカーが別途必要になる。
* **Option 3: 専用非同期ワーカースレッド（`Thread::Queue`）を備えた Pluggable Reporter パターン**
  * *メリット*:
    * 外部 gem なしで Ruby 標準ライブラリ（`Thread::Queue`, `Thread`）のみで完結。
    * ETL 処理スレッドをデータベース I/O 遅延から完全に隔離。
    * ActiveRecord コネクションの消費を管理された単一スレッドのみに限定。
    * 明示的な flush プロトコル（`reporter.flush`）により、パイプライン終了時のデータ欠損を防止。
    * 設定オプション（`config.report_async = true/false`）により、本番環境の非同期実行とテスト環境での確実な同期実行の両方に対応。
  * *デメリット*: スレッドのライフサイクル管理と終了時のキューフラッシュ機構の実装が必要。

---

## 4. 決定内容 (Decision Outcome)

採用方針: **Option 3: 専用非同期ワーカースレッドを備えた Pluggable Reporter パターン**。

### 4.1 サブシステムアーキテクチャと階層

本サブシステムは主に 3 つのコンポーネントで構成されます：
1. **レポーターインターフェース (`Rettle::Reporter::Base`)**: イベント通知の規約を定義。
2. **レポーター実装**:
   * `Rettle::Reporter::LoggerReporter`: `Rettle.logger` 経由で構造化ログを出力するデフォルト実装。
   * `Rettle::Reporter::ActiveRecordReporter`: 動的スキーママッピングを用いて ActiveRecord モデルへ永続化する実装。
   * `Rettle::Reporter::Base` に準拠したユーザー定義のカスタムレポーター。
3. **非同期書き込みエンジン (`Rettle::Reporter::AsyncWriter`)**: インメモリキューとバックグラウンドスレッドにより非同期書き込みと安全なフラッシュを制御。

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
         v (デフォルト)                                   v (report_model 指定時)
+-----------------------+                    +------------------------------------+
|  LoggerReporter       |                    | ActiveRecordReporter               |
|  (Rettle.logger)      |                    |  +------------------------------+  |
+-----------------------+                    |  | Thread::Queue (イベントバッファ)|  |
                                             |  +--------------+---------------+  |
                                             |                 |                  |
                                             |                 v                  |
                                             |  +------------------------------+  |
                                             |  | 専用書き込みワーカースレッド    |  |
                                             |  | (connection_pool.with_conn)  |  |
                                             |  +--------------+---------------+  |
                                             |                 |                  |
                                             +-----------------+------------------+
                                                               |
                                                               v
                                                    +---------------------+
                                                    | アプリケーション DB |
                                                    | (report_model テーブル)|
                                                    +---------------------+
```

### 4.2 専用非同期ワーカー (`AsyncWriter`) の設計

`report_async` が有効な場合（デフォルト: `true`）、`ActiveRecordReporter` は内部の `AsyncWriter` を通じて書き込みを実行します：

1. **キューによるバッファリング (`Thread::Queue`)**:
   * 発行されたイベント（`pipeline_start`, `task_finish` など）は正規化されたペイロード Hash に変換され、スレッドセーフな `Thread::Queue` にプッシュされます。
   * `Thread::Queue` へのプッシュは非ブロッキングであり、タスクスレッドにかかるオーバーヘッドはマイクロ秒未満です。
2. **専用のコンシューマースレッド**:
   * 単一のデーモンワーカースレッドがキューからイベントを取り出し、設定された ActiveRecord モデルへ保存します。
   * 保存処理は `ActiveRecord::Base.connection_pool.with_connection { ... }` 内で実行されるため、コネクションの占有を局所化し、即座に返却されます。
3. **安全なフラッシュプロトコル (`#flush(timeout: 5)`)**:
   * `pipeline_finished` または `pipeline_failed` の発生時、パイプラインは `reporter.flush(timeout: 5)` を呼び出します。
   * フラッシュ処理は同期用シグナルをキューに投入するか、キューが空になるまで指定タイムアウトを上限として待機し、全イベントが書き込まれることを保証します。
4. **キュー肥大化防止とバックプレッシャー**:
   * データベースの長時間障害時にメモリが肥大化するのを防ぐため、キューの上限件数（`max_queue_size: 1000`）を設定します。
   * 上限到達時は最古の非重要イベントを破棄し、`Rettle.logger` へ警告を出力します。
5. **同期モードへの切り替え**:
   * テストスイートやデバッグ時など、即座に DB 反映を確認したい場合は、`config.report_async = false` と設定することで同期書き込みに変更できます。

### 4.3 レポーターインターフェース規約

`Rettle::Reporter::Base` は以下の標準インターフェースを定義します：

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
        # 同期レポーター向けデフォルトは何もしない (no-op)
      end
    end
  end
end
```

### 4.4 明示的 API (`task.report`) とダウンローダー連携

* **タスクからの明示的レポート**:
  ```ruby
  etl.define_task(:extract, 'fetch_users') do |task|
    fetched_count = 1500
    task.report(records: fetched_count, source: "api_v2")
  end
  ```
  `task.report` はタスクインスタンス内のメトリクスを蓄積します。タスク完了時、蓄積されたデータは自動的に `#report_task_finish` にマージされます。
* **ダウンローダー出所情報の自動収集**:
  標準のダウンロード機能は以下のメタデータを自動記録します：
  * `download_url`: 対象 URI。
  * `download_etag`: HTTP ETag レスポンスヘッダ（取得可能な場合）。
  * `download_bytes`: ダウンロードしたファイルのバイトサイズ。

### 4.5 設定の解決階層

アクティブなレポーターは `Rettle#initialize` 時に以下の優先順序で解決されます：
1. `options[:reporter]`: パイプライン生成時に直接渡されたインスタンス。
2. `Rettle.configuration.reporter`: グローバルに設定されたカスタムレポーター。
3. `Rettle.configuration.report_model`: ActiveRecord モデルが設定されている場合、`Rettle::Reporter::ActiveRecordReporter.new(model, async: Rettle.configuration.report_async)` を初期化。
4. フォールバックデフォルト: `Rettle::Reporter::LoggerReporter.new(Rettle.logger)`。

```ruby
Rettle.configure do |config|
  config.report_model = BatchJobExecution
  config.report_async = true # デフォルトは true
end
```

### 4.6 柔軟なスキーマ対応（ダックタイピング）

`ActiveRecordReporter` は固定のマイグレーションを要求しません。リフレクション（`column_names` / `has_attribute?`）を用いて、モデルに存在するカラムへ動的にマッピングします：
* 標準対応カラム: `execution_id`, `task_name`, `task_type`, `status`, `started_at`, `finished_at`, `duration_seconds`, `error_message`, `error_backtrace`。
* その他の属性やカスタムメトリクスは、対象モデルに JSON/JSONB カラム（`metrics`, `payload`, `metadata` など）が存在する場合にそこへ格納されます。

### 4.7 フェイルセーフ設計

すべての永続化処理は例外ハンドリングで保護されます：
```ruby
def persist_record(attributes)
  ActiveRecord::Base.connection_pool.with_connection do
    @model.create!(attributes)
  end
rescue StandardError => e
  Rettle.logger.error("[Rettle][Report] Failed to persist report record: #{e.class}: #{e.message}")
end
```
レポーター内部のエラーはログに記録されますが、パイプラインの実行を中断・停止することはありません。

---

## 5. 影響とトレードオフ (Consequences and Trade-offs)

### メリット
* **ETL スループットの維持**: 専用非同期ワーカースレッドにより、並行データ処理タスクに DB I/O のレイテンシを一切与えません。
* **コネクション消費の節約**: パイプライン内の並行タスク数に関わらず、消費する DB コネクションは最大 1 つに抑えられます。
* **コアの外部依存ゼロ**: 純粋な Ruby 標準ライブラリのスレッドとキューのみで動作し、ActiveRecord は完全にオプショナルです。
* **監査性と出所管理の確立**: 実行履歴、所要時間、エラー情報、ダウンロード出所を一元的に追跡可能です。
* **テスト容易性**: `report_async = false` に設定することで、自動テスト等で同期的に即時検証できます。

### デメリット / 考慮点
* **プロセスの強制終了時のリスク**: `SIGKILL` などの捕捉不能なシグナルでプロセスが即死した場合、未書き込みのキュー内イベントが失われる可能性があります（`SIGTERM` や正常終了時は `#flush` プロトコルにより防止）。
* **リフレクションのオーバーヘッド**: スキーマ属性の確認は初期化時にキャッシュし、イベント永続化時のオーバーヘッドを最小化します。
