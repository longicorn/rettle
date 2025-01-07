# frozen_string_literal: true

require_relative "rettle/version"
require_relative "rettle/task"

class Rettle
  attr_accessor :extract, :transforms, :load

  def setup
    # set pipeline
    @pipeline = []
    @pipeline << @extract
    @pipeline << @transforms
    @pipeline << @load
    @pipeline = @pipeline.flatten.compact

    # set next task
    @pipeline.each_cons(2) do |before, after|
      before.next_task = after
    end
  end

  def run
    setup
    @pipeline.each(&:run)
  end

  def join
    @pipeline.each(&:join)
  end
end
