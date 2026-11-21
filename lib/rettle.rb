# frozen_string_literal: true

require_relative "rettle/version"
require_relative "rettle/task"

class Rettle
  def initialize(network: :queue)
    @tasks = {}
    @network = network
    @startup_lock = Mutex.new
    setup_watchdog
  end

  def setup
    if block_given?
      @setup_proc = lambda do
        yield
      end
    end
  end

  def define_task(type, name)
    task = Task.new(type: type, name: name, network: @network, watchdog_fd: @wdw)
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
    @setup_proc&.call
    @startup_lock.synchronize { @tasks.values.each(&:run) }
    @tasks.values.each(&:join)
    error = @tasks.values.filter_map(&:error).first
    raise error if error
  ensure
    @watchdog.kill if @watchdog&.alive?
    @watchdog&.join
    @wdr&.close unless @wdr&.closed?
    @wdw&.close unless @wdw&.closed?
  end

  private

  def setup_watchdog
    @wdr, @wdw = IO.pipe
    @watchdog = Thread.new do
      rs, _, = IO.select([@wdr])
      if r = rs[0]
        @startup_lock.synchronize { @tasks.values.each(&:kill) }
      end
    end
  end
end
