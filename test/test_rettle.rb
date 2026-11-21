# frozen_string_literal: true
require "test_helper"
require "timeout"
require "tmpdir"

class TestRettle < Minitest::Test
  def test_pipeline_and_role_isolation
    etl = Rettle.new
    received = []
    extract = etl.define_task(:extract, 'extract') do
      etl.connect('load') { |tasks| tasks['load'].send('item') }
    end
    load = etl.define_task(:load, 'load') { |task| task.each_recv { |item| received << item } }
    # define_task with a block returns its assignment, so inspect via a separate blockless task.
    other = etl.define_task(:extract, 'other')
    refute_respond_to other, :export
    Timeout.timeout(3) { etl.run }
    assert_equal ['item'], received
  end

  def test_failure_propagates_and_stops_blocked_tasks
    etl = Rettle.new
    etl.define_task(:load, 'blocked') { |task| task.each_recv {} }
    etl.define_task(:extract, 'failure') { raise 'failure' }
    error = assert_raises(RuntimeError) { Timeout.timeout(3) { etl.run } }
    assert_equal 'failure', error.message
  end

  def test_encoding_and_default_exporter
    etl = Rettle.new
    task = etl.define_task(:load, 'load')
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'text')
      File.write(path, 'hello')
      task.encoding!(path, encoding: 'UTF-16LE')
      assert_equal 'hello'.encode('UTF-16LE').b, File.binread(path)
    end
    assert_raises(NotImplementedError) { task.export(data: 1, flush: true) }
  end
  def test_first_reported_failure_is_not_selected_by_definition_order
    etl = Rettle.new
    first = RuntimeError.new('first reported')
    later = RuntimeError.new('later')
    etl.define_task(:extract, 'defined_first') { sleep 0.2; raise later }
    etl.define_task(:extract, 'defined_second') { raise first }
    assert_same first, assert_raises(RuntimeError) { Timeout.timeout(3) { etl.run } }
  end

end
