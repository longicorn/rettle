# frozen_string_literal: true

require "logger"
require "securerandom"
require_relative "rettle/reporter"
require_relative "rettle/version"
require_relative "rettle/task"

class Rettle
  class << self
    attr_accessor :logger

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    def default_logger
      @default_logger ||= Logger.new($stdout, level: Logger::INFO)
    end
  end

  attr_reader :logger, :results

  def initialize(network: :queue, logger: nil, reporter: nil, config: nil, context: {})
    @logger = logger || Rettle.logger || Rettle.default_logger
    config ||= Rettle.configuration
    @reporter = reporter || config.reporter || (config.report_model ? Reporter::ActiveRecordReporter.new(config.report_model, async: config.report_async, max_queue_size: config.max_queue_size, logger: @logger) : Reporter::LoggerReporter.new(@logger))
    @context = context
    @tasks = {}
    @results = []
    @network = network
    @startup_lock = Mutex.new
    @error_lock = Mutex.new
    @results_lock = Mutex.new
    @first_error = nil
    setup_watchdog
  end

  def setup
    if block_given?
      @setup_proc = lambda do
        yield
      end
    end
  end

  def define_task(type, name, params: {})
    task = Task.new(type: type, name: name, params: params, network: @network, watchdog_fd: @wdw, on_failure: method(:record_failure), logger: @logger, report_dispatch: method(:dispatch_report), execution_id: -> { @execution_id })
    raise "Task #{name} already exists" if @tasks.key?(name)
    @tasks[name] = task

    if block_given?
      task.proc = lambda do
        yield task
      end
    else
      task
    end
  end

  def connect(task_names)
    @logger.debug { "[Rettle] Connecting tasks: #{Array(task_names).join(", ")}" }
    tasks = Array(task_names).each_with_object({}){|name, hash| hash[name] = @tasks[name]}
    if block_given?
      begin
        yield tasks
      ensure
        tasks.values.each(&:close)
      end
    end
  end

  def send(name, data)
    task = @tasks[name]
    task.write(data)
  end

  def run
    @results = []
    @execution_id = SecureRandom.uuid
    dispatch_report(:report_pipeline_start, @execution_id, @context)
    @logger.info { "[Rettle] Pipeline started" }
    @setup_proc&.call
    collectors = @tasks.values.map do |task|
      Thread.new do
        while (item = task.result_network.read)
          @results_lock.synchronize { @results << Marshal.load(item[0]) }
        end
      end
    end
    @startup_lock.synchronize do
      @tasks.values.each do |task|
        @logger.debug { "[Rettle] Starting task #{task.name}" }
        task.run
      end
    end
    @tasks.values.each(&:join)
    @tasks.values.each { |task| task.result_network.close }
    collectors.each(&:join)
    error = @error_lock.synchronize { @first_error }
    raise error if error
    @logger.info { "[Rettle] Pipeline completed" }
    dispatch_report(:report_pipeline_finish, @execution_id, :success)
  rescue Exception => e
    dispatch_report(:report_pipeline_finish, @execution_id, :failed, error: e)
    raise
  ensure
    if collectors
      @tasks.values.each { |task| task.result_network.close }
      collectors.each(&:join)
    end
    dispatch_report(:flush, timeout: 5)
    @watchdog.kill if @watchdog&.alive?
    @watchdog&.join
    @wdr&.close unless @wdr&.closed?
    @wdw&.close unless @wdw&.closed?
  end

  private

  def dispatch_report(method, *args, **kwargs)
    @reporter.public_send(method, *args, **kwargs)
  rescue StandardError => e
    @logger.error { "[Rettle][Report] #{e.class}: #{e.message}" }
    nil
  end

  def record_failure(error)
    @error_lock.synchronize { @first_error ||= error }
  end

  def setup_watchdog
    @wdr, @wdw = IO.pipe
    @watchdog = Thread.new do
      rs, _, = IO.select([@wdr])
      if r = rs[0]
        @logger.warn { "[Rettle] Watchdog stopping tasks after failure" }
        @startup_lock.synchronize { @tasks.values.each(&:kill) }
      end
    end
  end
end
