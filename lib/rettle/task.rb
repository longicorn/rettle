# frozen_string_literal: true

require_relative "network"
require_relative "task_common"
require_relative "task_extract"
require_relative "task_transform"
require_relative "task_load"
require 'forwardable'
require_relative "logger"

class Rettle
  class Task
    extend Forwardable

    def initialize(type:, name:, params: {}, network: :queue, watchdog_fd:, on_failure: nil, logger: nil, report_dispatch: nil, execution_id: nil)
      logger ||= Rettle.respond_to?(:default_logger) ? Rettle.default_logger : Logger.new($stdout, level: Logger::INFO)
      @logger_proxy = TaskLoggerProxy.new(logger, type: type, name: name)
      @report_dispatch, @execution_id = report_dispatch, execution_id
      @metrics = {}
      @params = Marshal.load(Marshal.dump(params))
      @result_network = Network.new(type: network)
      @type = type
      @name = name
      @watchdog_fd = watchdog_fd
      @on_failure = on_failure
      # extract task is not recv
      @network = Network.new(type: network) if type != :extract

      type_name = type.to_s[0].upcase + type.to_s[1..]
      class_name = Object.const_get("::Rettle::Task#{type_name}")
      extend class_name
      class_name = Object.const_get("::Rettle::TaskCommon")
      extend class_name
    end
    attr_reader :name, :network, :error, :params, :result_network
    attr_accessor :proc

    def logger(message = nil, positional_level = nil, level: :info, &block)
      return @logger_proxy if message.nil? && !block && positional_level.nil?

      @logger_proxy.public_send(positional_level || level, message, &block)
    end

    def each_recv
      if block_given?
        while true do
          data = read
          break if data.nil?
          yield data
        end
      end
    end

    def send(data)
      raise ArgumentError, "extract tasks have no input channel" unless @network
      write(data)
    end

    def emit(data)
      @result_network.write([Marshal.dump(data)])
    end

    def report(metrics = {}, **metadata)
      @metrics.merge!(metrics).merge!(metadata)
    end

    def run
      @thread = Thread.new do
        started = Time.now
        clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @report_dispatch&.call(:report_task_start, @execution_id.call, @type, @name, started)
        status = :failed
        @proc.call
        status = :success
      rescue Exception => e # Notify the supervisor even for non-StandardError task failures.
        status = :failed
        @error = e
        logger.error { "Task failed: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}" }
        @on_failure&.call(e)
        @watchdog_fd.write("1")
        @watchdog_fd.flush
      ensure
        if clock
          status ||= :failed
          duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - clock
          @report_dispatch&.call(:report_task_finish, @execution_id.call, @name, status, Time.now, duration, metrics: @metrics.dup, error: @error)
        end
        @network&.close_reader
      end if @proc
    end

    delegate read: :@network
    delegate write: :@network
    delegate close: :@network
    def join
      @thread&.join
    end

    def kill
      @thread&.kill
    end
  end
end
