# アーキテクチャ決定記録 (ADR) - Rettle ロガーサブシステム

[English](adr.md)

* **ステータス**: 承認済み (Accepted)
* **日付**: 2026-11-21
* **決定者**: Rettle 開発チーム
* **関連ドキュメント**: [要求仕様書 (PRD)](prd.ja.md)

---

## 1. 背景と課題

Rettle は、独立したスレッド上でタスクを実行する Ruby 製の軽量並行 ETL フレームワークです。これまで、実行時の診断、タスクの監視、および捕捉されなかった例外の出力には、アドホックな標準出力（`puts`, `p`）が使用されていました。

これにより、運用上以下の課題が生じていました：
1. **一元管理基盤との統合の欠如**: Rails のバッチ実行基盤（ActiveJob や Solid Queue など）をはじめとする現代的な Ruby アプリケーションでは、一元的なログ基盤（`Rails.logger`, Syslog, Logstash, Datadog など）に依存しています。ハードコードされた標準出力は、ホストアプリケーションによる収集、ルーティング、制御（抑制）が困難でした。
2. **並行処理コンテキストの欠如**: 各タスクはスレッド上で並行実行されるため、混ざり合って出力されるログメッセージにタスクの識別情報が含まれず、タスク固有の障害の追跡やデバッグが困難でした。
3. **ログレベル制御の不能**: フレームワークのソースコードを変更しない限り、本番環境で診断出力を抑制したり、デバッグモードで詳細化したりすることができませんでした。

Rettle には、フレームワーク内部の診断を標準化し、タスク実装者にとって扱いやすい API を提供する、スレッドセーフかつフレームワーク非依存の正式なロギングサブシステムが必要です。

---

## 2. 決定要因

* **外部依存ゼロ**: gem の依存（ActiveSupport など）を追加せず、Ruby 標準ライブラリ（`logger`）のみで動作すること。
* **フレームワーク非依存と相互運用性**: 単体の Ruby スクリプトでそのまま動作しつつ、ホストアプリケーションの `Rails.logger` などともスムーズに統合できること。
* **直感的なタスク記述体験**: タスク定義内から、手動でのロガー受け渡しや定型的な文字列フォーマットなしに直接ログを出力できること。
* **コンテキスト付きの可観測性**: タスクから出力されるログ行には、並行スレッド間でのログ解析を容易にするため、タスクのメタデータ（`type` と `name`）が自動的に付与されること。
* **スレッドセーフ性と性能**: 並行実行下でもログ出力の破壊が起こらず、スループットを低下させないこと。

---

## 3. 検討した選択肢

* **選択肢 1: `ActiveSupport::TaggedLogging` を必須要件とする**
  * *メリット*: Rails エコシステムにおける標準的なタギング機構を利用可能。
  * *デメリット*: ActiveSupport へのハード依存が発生し、Rettle の「外部依存ゼロ」の基本原則に反する。
* **選択肢 2: コンテキストのラッピングを行わない直接のロガー受け渡し**
  * *メリット*: 実装が最もシンプル。
  * *デメリット*: タスク実装者がタスク名や種別を手動でフォーマットする必要があり、並行タスクからのログが混在して追跡が困難になる。
* **選択肢 3: デュアルインターフェースを備えたコンテキストプロキシラッパー (`TaskLoggerProxy`)**
  * *メリット*: gem 依存ゼロ、自動コンテキストタグ付け（`[Rettle][<type>:<name>]`）、簡潔なショートハンド（`task.logger("msg")`）とメソッドチェーン（`task.logger.info("msg")`）の両方をサポート、スレッドセーフ、標準的な `Logger` 互換インスタンスに対する透過的なダックタイピング。
  * *デメリット*: タスクごとに軽量なラッパーオブジェクトが生成される。

---

## 4. 決定内容

採用された選択肢: **選択肢 3: デュアルインターフェースを備えたコンテキストプロキシラッパー (`TaskLoggerProxy`)**。

### 4.1 設定階層と解決ロジック

ロガーの設定は、3 段階の階層構造で解決されます：
1. **インスタンスレベルでのオーバーライド**: `Rettle.new(logger: custom_logger)` で指定されたロガー。
2. **グローバルデフォルト**: トップレベルモジュールで `Rettle.logger = custom_logger` として設定されたロガー。
3. **フォールバックデフォルト**: `$stdout` に `Logger::INFO` で出力する、遅延初期化された Ruby 標準の `Logger`。

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

パイプラインインスタンス内部（`Rettle#initialize`）では、次のようにロガーを決定します：
```ruby
@logger = options[:logger] || Rettle.logger || Rettle.default_logger
```

### 4.2 デュアルモードのタスクロギングインターフェース (`Task#logger`)

タスク定義ブロック内において、`task.logger` は直接呼び出しとログレベル指定のメソッドチェーンの両方をサポートします：

1. **ショートハンド呼び出し**:
   ```ruby
   task.logger("レコードチャンクを処理中", level: :info)
   # レベルを省略した場合はデフォルトで :info となります:
   task.logger("リモートレコードを取得中")
   ```
2. **メソッドチェーン呼び出し**:
   ```ruby
   task.logger.debug("1024バイトのペイロードを受信")
   task.logger.info("500件のアイテムを処理完了")
   task.logger.warn("ネットワーク再試行を実行")
   task.logger.error("レコード id=42 の処理に失敗")
   task.logger.fatal("復旧不能な致命的エラー")
   ```

#### 実装アーキテクチャ: `TaskLoggerProxy`
`Task` クラスは `TaskLoggerProxy` にロギングを委譲します：
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

`TaskLoggerProxy` は、すべてのログメッセージの先頭に `[Rettle][<type>:<name>]` を付与します：
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

### 4.3 並行処理とスレッドセーフ性

* **I/O 同期**: Ruby 標準の `Logger` は、内部の Mutex インスタンスを使用してログデバイスへの書き込みを同期します。基底のロガーへ直接委譲することでスレッドセーフ性が担保されます。
* **ステートレスな委譲**: `TaskLoggerProxy` は対象ロガーとプレフィックス文字列の不変参照のみを保持し、タスクスレッド間で共有される可変状態を持たない設計とします。

### 4.4 フレームワーク内部診断の置換

既存の `puts` および `p` はすべてロガー呼び出しに置き換えます：
* **タスクの失敗 (`Task#run`)**: 捕捉されなかった例外を、バックトレースとともに `ERROR` レベルで記録：
  ```ruby
  logger.error("Task failed: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
  ```
* **パイプラインのライフサイクル**:
  * パイプラインの開始・完了は `INFO` で記録。
  * タスクスレッドの起動やチャネル接続は `DEBUG` で記録。
  * Watchdog によるタスク中断通知は `WARN` で記録。

---

## 5. 結果とトレードオフ

### メリット
* **スムーズな Rails 統合**: `Rettle.logger = Rails.logger` を設定するだけで、フレームワークおよびタスクのすべてのログが標準の Rails ログ出力先にルーティングされます。
* **一元的な可観測性**: 並行タスクが出力する全ログにタスクコンテキスト（`[Rettle][<type>:<name>]`）が自動付与され、マルチスレッド環境でのトレース出力が明確になります。
* **依存関係のオーバーヘッドゼロ**: 外部 gem を一切追加せず、Ruby 標準ライブラリのみで完結します。
* **遅延評価のサポート**: ブロック渡し（`task.logger.debug { 重いインスペクション }`）に対応し、デバッグログが無効な場合の文字列生成コストを回避できます。

### 考慮点 / トレードオフ
* **プロキシインスタンスの生成**: タスクごとに 1 つの `TaskLoggerProxy` インスタンスを生成します。パイプライン実行中にタスクは常駐するため、メモリオーバーヘッドは極めて軽微です。
* **ロガーのダックタイピング**: カスタムロガーを渡す場合、Ruby 標準の `Logger` インターフェース（`debug`, `info`, `warn`, `error`, `fatal`）に準拠している必要があります。非標準なロガーの場合は軽量なアダプターが必要になる場合があります。
