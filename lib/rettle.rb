# frozen_string_literal: true

require_relative "rettle/version"
require_relative "rettle/task"

class Rettle
  def initialize
    @tasks = {}
  end

  def process(type, name)
    task = Task.new(type: type, name: name)
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
    tasks = Array(task_names).each_with_object({}){|name, hash| hash[name] = @tasks[name]}
    if block_given?
      yield tasks
      tasks.values.each(&:close)
    end
  end

  def send(name, data)
    task = @tasks[name]
    task.connect
    task.write(data)
  end

  def run
    @tasks.values.each(&:run)
    @tasks.values.each(&:join)
  end
end
