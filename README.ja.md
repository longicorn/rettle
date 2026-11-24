# Rettle

[English](README.md)

Rettle は小さく実験的な個人用 ETL フレームワークです。

## インストール

Gemfile に以下を追加します:

```ruby
gem 'rettle', git: 'git@github.com:longicorn/rettle.git', branch: 'master'
```

```shell
$ bundle install
```

## 使い方

### 基本的な例 1

```mermaid
flowchart LR
    ExtractTask --> TransformTask --> LoadTask
```

```ruby
etl = Rettle.new

etl.define_task(:extract, 'extract_task') do
  csv_path = '/path/to/csv/file'
  etl.connect('transform_task') do |senders|
    CSV.foreach(csv_path) do |row|
      senders['transform_task'].send(row)
    end
  end
end

etl.define_task(:transform, 'transform_task') do
  etl.connect('load_task') do |senders|
    task.each_recv do |row|
      row[:id] = row[:id].to_i
      senders['load_task'].send(row)
    end
  end
end

etl.define_task(:load, 'load_task') do
  task.each_recv do |row|
    puts row
  end
end

etl.run
```

### 基本的な例 2

```mermaid
flowchart LR
    ExtractTask --> TransformTask
    TransformTask --> LoadTask0
    TransformTask --> LoadTask1
    TransformTask --> LoadTask2
```

```ruby
etl = Rettle.new

etl.define_task(:extract, 'extract_task') do
  csv_path = '/path/to/csv/file'
  etl.connect('transform_task') do |senders|
    CSV.foreach(csv_path) do |row|
      senders['transform_task'].send(row)
    end
  end
end

etl.define_task(:transform, 'transform_task') do
  tasks = ['load_task0', 'load_task1', 'load_task2']
  etl.connect(tasks) do |senders|
    task.each_recv do |row|
      row[:id] = row[:id].to_i
      case row[:id] % 3
      when 0
        senders['load_task0'].send(row)
      when 1
        senders['load_task1'].send(row)
      when 2
        senders['load_task2'].send(row)
      end
    end
  end
end

etl.define_task(:load, 'load_task0') do
  task.each_recv do |row|
    puts row
  end
end

etl.define_task(:load, 'load_task1') do
  task.each_recv do |row|
    puts row
  end
end

etl.define_task(:load, 'load_task2') do
  task.each_recv do |row|
    puts row
  end
end

etl.run
```

### パラメータ渡しと結果収集

タスク間の独立性を保ち、競合状態を防ぐ（特にプロセス分離実行時）ため、外部スコープのクロージャを経由した変数共有は避けてください。`define_task` の `params:` オプションで初期パラメータを渡し、`task.emit` で結果を送信します：

```ruby
etl = Rettle.new

etl.define_task(:extract, 'extract_task', params: { source_path: 'data.csv' }) do |task|
  etl.connect('load_task') do |senders|
    # 初期パラメータを安全に参照（独立したコピーが渡されます）
    path = task.params[:source_path]
    senders['load_task'].send("record from #{path}")
  end
end

etl.define_task(:load, 'load_task') do |task|
  task.each_recv do |row|
    # 外部変数を変更することなく、パイプラインのコレクターへ結果を送信
    task.emit("processed: #{row}")
  end
end

etl.run

# パイプライン実行完了後、集約された全結果を取得
puts etl.results
# => ["processed: record from data.csv"]
```

## Rettle ヘルパー

### setup

`setup` は、全タスクを開始する前に事前実行されます。

```ruby
etl = Rettle.new
etl.setup do
  FileUtils.mkdir_p('dir/path')
end
```

## Task ヘルパー

### Extract

#### download

シンプルなファイルのダウンロード

```ruby
etl = Rettle.new

etl.define_task(:extract, 'extract_task') do |task|
  csv_url = '/url/to/csv/file.csv'
  csv_paths = task.download(url: csv_url, dir: '/save/to/dir')
  CSV.foreach(csv_paths[0]) do |row|
    p row
  end
end
```

#### download 2

ZIP ファイルのダウンロード

```ruby
etl = Rettle.new

etl.define_task(:extract, 'extract_task') do |task|
  # file.zip => ['hoge.csv', 'hoge.asc']
  zip_url = '/url/to/csv/file.zip'

  # files => ['hoge.csv', 'hoge.asc']
  files = task.download(url: zip_url, dir: '/save/to/dir')
  csv_paths = files.detect(/.*\.csv/)
  CSV.foreach(csv_paths[0]) do |row|
    p row
  end
end
```

#### download 3

スクレイピングを伴うダウンロード

```ruby
etl = Rettle.new

etl.define_task(:extract, 'extract_task') do |task|
  def task.downloader
    # スクレイピング処理
    # ...
    return [file_path]
  end

  file_path = task.download(url: zip_url, dir: '/save/to/dir')[0]
  # ...
end
```

### Load

#### export

`export` はデータをキャッシュし、一定量に達したときに `exporter` を呼び出してファイルなどへ出力します。
`exporter` はユーザー側で定義する必要があります。

```ruby
etl = Rettle.new

# 書き換え前
etl.define_task(:load, 'load_task') do |task|
  array = []
  task.each_recv do |row|
    array << row

    if array.size > 1000
      ActiveRecord::Base.transaction do
        array.each(&:save!)
      end
      array = []
   end
  end
  ActiveRecord::Base.transaction do
    array.each(&:save!)
  end if array.size > 0
end

# 書き換え後
etl.define_task(:load, 'load_task') do |task|
  # 'data' はキャッシュされたデータ
  def task.exporter(data)
    ActiveRecord::Base.transaction do
      data.each(&:save!)
    end
  end

  array = []
  task.each_recv do |row|
    # size はバッファサイズ（デフォルト: 1000）
    task.export(data: row, size: 2000)
  end
  task.export(flush: true)
end
```
