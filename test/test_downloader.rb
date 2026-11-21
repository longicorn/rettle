require 'minitest/autorun'
require 'tmpdir'
require 'socket'
require 'stringio'
require 'rettle/task'

class DownloaderTest < Minitest::Test
  def task
    Rettle::Task.new(type: :extract, name: 'download', watchdog_fd: StringIO.new)
  end

  def server(responses)
    listener = TCPServer.new('127.0.0.1', 0)
    port = listener.addr[1]
    requests = []
    thread = Thread.new do
      responses.each do |response|
        socket = listener.accept
        request = +''
        while (line = socket.gets) && line != "\r\n"
          request << line
        end
        requests << request
        socket.write(response)
        socket.close
      end
    ensure
      listener.close
    end
    yield "http://127.0.0.1:#{port}", requests
  ensure
    listener&.close rescue nil
    thread&.kill
    thread&.join
  end

  def test_redirect_stream_and_conditional_response
    responses = ["HTTP/1.1 302 Found\r\nLocation: /data\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", "HTTP/1.1 200 OK\r\nETag: \"v1\"\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello", "HTTP/1.1 304 Not Modified\r\nConnection: close\r\n\r\n"]
    server(responses) do |base, requests|
      Dir.mktmpdir do |dir|
        t = task
        files = t.download(url: "#{base}/file", dir: dir)
        assert_equal 'hello', File.binread(files.first)
        assert_equal Digest::SHA256.hexdigest('hello'), t.download_metadata[:sha256]
        assert_equal [], t.download(url: "#{base}/file", dir: dir, etag: '"v1"')
        assert t.download_metadata[:cached]
        assert_equal 'hello', File.binread(files.first)
        assert_match(/If-None-Match: "v1"/i, requests.last)
      end
    end
  end

  def test_gzip_extraction_and_pwd
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'data.gz')
      Zlib::GzipWriter.open(path) { |gz| gz.write('hello') }
      before = Dir.pwd
      assert_equal ['data'], task.after_download(path, dir: dir)
      assert_equal 'hello', File.read(File.join(dir, 'data'))
      assert_equal before, Dir.pwd
    end
  end
  def test_tar_gzip_extracts_nested_files
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'data.tar.gz')
      Zlib::GzipWriter.open(path) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          tar.mkdir('nested', 0755)
          tar.add_file_simple('nested/data', 0644, 5) { |file| file.write('hello') }
        end
      end
      assert_equal ['nested/data'], task.after_download(path, dir: dir)
      assert_equal 'hello', File.read(File.join(dir, 'nested/data'))
    end
  end

  def test_redirect_limit
    response = "HTTP/1.1 302 Found\r\nLocation: /again\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    server([response]) do |base, _requests|
      Dir.mktmpdir do |dir|
        error = assert_raises(RuntimeError) { task.download(url: "#{base}/file", dir: dir, max_redirects: 0) }
        assert_match(/redirect limit/, error.message)
      end
    end
  end

  def test_parallel_custom_downloads_do_not_change_working_directory
    Dir.mktmpdir do |root|
      original = Dir.pwd
      ready = Queue.new
      release = Queue.new
      threads = 2.times.map do |i|
        Thread.new do
          t = task
          t.define_singleton_method(:downloader) do |url:, dir:|
            ready << true
            release.pop
            File.write(File.join(dir, 'result'), i.to_s)
            [Pathname.new('result')]
          end
          t.download(dir: File.join(root, i.to_s))
        end
      end
      2.times { ready.pop }
      assert_equal original, Dir.pwd
      2.times { release << true }
      assert_equal %w[0 1], threads.map { |thread| File.read(thread.value.first) }
      assert_equal original, Dir.pwd
    ensure
      threads&.each(&:kill)
    end
  end

  def test_retry_after_connection_close
    responses = ['', "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"]
    server(responses) do |base, _requests|
      Dir.mktmpdir do |dir|
        assert_equal 'ok', File.read(task.download(url: "#{base}/file", dir: dir, retries: 1).first)
      end
    end
  end

  def test_tar_rejects_parent_traversal_and_symlink_destination
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'bad.tar.gz')
      Zlib::GzipWriter.open(path) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          tar.add_file_simple('../escape', 0644, 1) { |file| file.write('x') }
        end
      end
      assert_raises(RuntimeError) { task.after_download(path, dir: dir) }
      refute File.exist?(File.join(File.dirname(dir), 'escape'))
    end
  end

  def test_archive_rejects_existing_symlink
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |outside|
        File.symlink(outside, File.join(dir, 'nested'))
        path = File.join(dir, 'data.tar.gz')
        Zlib::GzipWriter.open(path) do |gzip|
          Gem::Package::TarWriter.new(gzip) do |tar|
            tar.add_file_simple('nested/escape', 0644, 1) { |file| file.write('x') }
          end
        end
        assert_raises(RuntimeError) { task.after_download(path, dir: dir) }
        refute File.exist?(File.join(outside, 'escape'))
      end
    end
  end

  def test_retry_transient_http_error
    responses = ["HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"]
    server(responses) do |base, requests|
      Dir.mktmpdir do |dir|
        assert_equal 'ok', File.read(task.download(url: "#{base}/file", dir: dir, retries: 1).first)
        assert_equal 2, requests.length
      end
    end
  end

  def test_download_reports_each_attempt_without_url_credentials
    t = task
    captured = []
    t.define_singleton_method(:report) { |data| captured << data }
    t.define_singleton_method(:downloader) do |url:, dir:|
      File.write(File.join(dir, 'data'), 'hello')
      [Pathname.new('data')]
    end
    Dir.mktmpdir do |dir|
      2.times { t.download(url: 'https://user:secret@example.com/data?token=secret', dir: dir) }
    end
    assert_equal 2, captured.last[:downloads].length
    assert_equal 'https://example.com/data', captured.last[:downloads].last[:url]
    assert_equal 'success', captured.last[:downloads].last[:status]
  end

  def test_git_clone_reports_revision
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'source')
      system('git', 'init', '-q', source, exception: true)
      system('git', '-C', source, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '--allow-empty', '-qm', 'initial', exception: true)
      t = task
      captured = []
      t.define_singleton_method(:report) { |data| captured << data }
      destination = File.join(dir, 'destination')
      2.times { t.git_clone(url: source, dir: destination) }
      records = captured.last[:git_repositories]
      assert_equal %w[clone pull], records.map { |entry| entry[:operation] }
      assert_match(/\A[0-9a-f]{40,64}\z/, records.first[:revision])
    end
  end

end
