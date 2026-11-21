# frozen_string_literal: true

require "logger"

class Rettle
  class TaskLoggerProxy
    LEVELS = %i[debug info warn error fatal unknown].freeze

    def initialize(target, type:, name:)
      @target = target
      @prefix = "[Rettle][#{type}:#{name}]".freeze
    end

    LEVELS.each do |level|
      define_method(level) do |message = nil, &block|
        @target.public_send(level) { "#{@prefix} #{block ? block.call : message}" }
      end
    end

    def level
      @target.level
    end

    def level=(value)
      @target.level = value
    end
  end
end
