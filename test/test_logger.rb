require 'test_helper'
require 'stringio'
require 'logger'

class LoggerTest < Minitest::Test
  def test_configuration_context_and_lazy_blocks
    global_io = StringIO.new
    local_io = StringIO.new
    Rettle.logger = Logger.new(global_io)
    local = Logger.new(local_io, level: Logger::INFO)
    pipeline = Rettle.new(logger: local)
    pipeline.define_task(:extract, 'source') do |task|
      task.logger.debug { task.emit('debug evaluated'); 'hidden' }
      task.logger('hello')
      task.logger.warn('warning')
    end
    pipeline.run
    assert_empty pipeline.results
    assert_includes local_io.string, '[Rettle][extract:source] hello'
    assert_includes local_io.string, '[Rettle][extract:source] warning'
    assert_empty global_io.string
  ensure
    Rettle.logger = nil
  end

  def test_task_failure_is_logged_and_propagated
    output = StringIO.new
    pipeline = Rettle.new(logger: Logger.new(output))
    pipeline.define_task(:extract, 'broken') { raise 'oops' }
    assert_raises(RuntimeError) { pipeline.run }
    assert_includes output.string, '[Rettle][extract:broken] Task failed: RuntimeError: oops'
    assert_includes output.string, __FILE__
  end
end
