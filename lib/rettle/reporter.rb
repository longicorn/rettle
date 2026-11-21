# frozen_string_literal: true

require 'thread'

class Rettle
  class Configuration
    attr_accessor :report_model, :report_async, :reporter, :max_queue_size

    def initialize
      @report_async = true
      @max_queue_size = 1000
    end
  end

  module Reporter
    class Base
      def report_pipeline_start(id, context = {}); end

      def report_pipeline_finish(id, status, error: nil); end

      def report_task_start(id, type, name, started_at); end

      def report_task_finish(id, name, status, finished_at, duration, metrics: {}, error: nil); end

      def report_task_event(id, name, data); end

      def flush(timeout: 5)
        true
      end
    end

    class EventReporter < Base
      def report_pipeline_start(id, context = {})
        emit(event: 'pipeline_start', execution_id: id, status: 'running', started_at: Time.now, metadata: context)
      end

      def report_pipeline_finish(id, status, error: nil)
        emit({ event: 'pipeline_finish', execution_id: id, status: status, finished_at: Time.now }.merge(error_data(error)))
      end

      def report_task_start(id, type, name, started_at)
        emit(event: 'task_start', execution_id: id, task_type: type, task_name: name, status: 'running', started_at: started_at)
      end

      def report_task_finish(id, name, status, finished_at, duration, metrics: {}, error: nil)
        emit({ event: 'task_finish', execution_id: id, task_name: name, status: status, finished_at: finished_at, duration_seconds: duration, metrics: metrics }.merge(error_data(error)))
      end

      def report_task_event(id, name, data)
        emit(event: 'task_event', execution_id: id, task_name: name, metadata: data)
      end

      private

      def error_data(error)
        error ? { error_message: "#{error.class}: #{error.message}", error_backtrace: error.backtrace } : {}
      end
    end

    class LoggerReporter < EventReporter
      def initialize(logger)
        @logger = logger
      end

      def emit(event)
        @logger.info { "[Rettle][Report] #{event.inspect}" }
      end
    end

    class AsyncWriter
      def initialize(max_queue_size:, logger:, &write)
        @queue = SizedQueue.new(max_queue_size)
        @logger = logger
        @lock = Mutex.new
        @pending = 0
        @condition = ConditionVariable.new
        @thread = Thread.new do
          loop do
            item = @queue.pop
            begin
              write.call(item)
            rescue StandardError => e
              @logger.error { "[Rettle][Report] #{e.class}: #{e.message}" }
            ensure
              @lock.synchronize do
                @pending -= 1
                @condition.broadcast
              end
            end
          end
        end
      end

      def push(item)
        @lock.synchronize do
          @pending += 1
          begin
            @queue.push(item, true)
          rescue ThreadError
            @pending -= 1
            @logger.warn { "[Rettle][Report] Queue full; event: #{item.inspect}" }
          end
        end
      end

      def flush(timeout: 5)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        @lock.synchronize do
          while @pending > 0
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return false if remaining <= 0
            @condition.wait(@lock, remaining)
          end
        end
        true
      end
    end

    class ActiveRecordReporter < EventReporter
      def initialize(model, async: true, max_queue_size: 1000, logger:)
        @model, @logger = model, logger
        @writer = AsyncWriter.new(max_queue_size: max_queue_size, logger: logger) { |event| persist(event) } if async
      end

      def emit(event)
        @writer ? @writer.push(event) : persist(event)
      end

      def flush(timeout: 5)
        result = @writer ? @writer.flush(timeout: timeout) : true
        @logger.warn { '[Rettle][Report] Flush timed out' } unless result
        result
      end

      private

      def persist(event)
        @model.connection_pool.with_connection do
          columns = @model.column_names
          attrs = event.select { |key, _| columns.include?(key.to_s) }
          remaining = event.reject { |key, _| columns.include?(key.to_s) }
          target = %w[payload metadata metrics].find { |name| columns.include?(name) && !attrs.key?(name.to_sym) }
          attrs[target.to_sym] = remaining if target && !remaining.empty?
          @model.create!(attrs)
        end
      rescue StandardError => e
        @logger.error { "[Rettle][Report] Failed to persist: #{e.class}: #{e.message}; event: #{event.inspect}" }
      end
    end
  end
end
