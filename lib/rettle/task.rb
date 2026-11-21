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

    def initialize(type:, name:, network: :queue, watchdog_fd:, on_failure: nil, logger: nil)
      logger ||= Rettle.respond_to?(:default_logger) ? Rettle.default_logger : Logger.new($stdout, level: Logger::INFO)
      @logger_proxy = TaskLoggerProxy.new(logger, type: type, name: name)
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
    attr_reader :name, :network, :error
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

    def run
      @thread = Thread.new do
        @proc.call
      rescue Exception => e # Notify the supervisor even for non-StandardError task failures.
        @error = e
        logger.error { "Task failed: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}" }
        @on_failure&.call(e)
        @watchdog_fd.write("1")
        @watchdog_fd.flush
      ensure
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
