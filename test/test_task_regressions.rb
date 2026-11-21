require 'minitest/autorun'
require 'tmpdir'
require 'timeout'
require 'rettle/task'

class TaskRegressionsTest < Minitest::Test
  def task(type = :extract, watchdog = StringIO.new)
    Rettle::Task.new(type: type, name: 'test', watchdog_fd: watchdog)
  end

  def test_encoding_with_explicit_source_and_default_target
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'input')
      File.binwrite(path, '日本'.encode('Windows-31J'))
      task.encoding!(path, source_encoding: 'Windows-31J')
      assert_equal '日本', File.read(path, encoding: 'UTF-8')
    end
  end

  def test_non_standard_exception_notifies_watchdog
    reader, writer = IO.pipe
    t = task(:extract, writer)
    t.proc = proc { raise ScriptError, 'failure' }
    t.run
    assert_equal '1', Timeout.timeout(2) { reader.read(1) }
    t.join
    assert_instance_of ScriptError, t.error
  ensure
    reader&.close
    writer&.close
  end

  def test_download_requires_directory
    assert_raises(ArgumentError) { task.download }
  end

  def test_false_is_exported
    t = task(:load)
    batches = []
    t.define_singleton_method(:exporter) { |data| batches << data }
    t.export(data: false, flush: true)
    assert_equal [[false]], batches
  end

  def test_stored_zip_entry_with_colon
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a:b'), 'hello')
      system('zip', '-q', '-0', 'archive.zip', 'a:b', chdir: dir) or skip 'zip unavailable'
      File.delete(File.join(dir, 'a:b'))
      Dir.chdir(dir) { assert_equal ['a:b'], task.after_download('archive.zip') }
    end
  end

  def test_dotted_git_repository
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'my.project')
      system('git', 'init', '-q', source) or skip 'git unavailable'
      system('git', '-C', source, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-q', '--allow-empty', '-m', 'initial') or flunk
      result = task.git_clone(url: source, dir: File.join(dir, 'clones'))
      assert_equal 'my.project', result.basename.to_s
    end
  end
end
