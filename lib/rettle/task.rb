class Rettle
  class Task
    def initialize
      @r, @w = IO.pipe
    end
    attr_accessor :next_task

    # read from file descriptor
    def read
      size = @r.readline.chomp.to_i
      mstr = @r.read(size)
      Marshal.load([mstr].pack("h*"))
    rescue EOFError
      # read was closed
      nil
    end

    # read from before task
    def recv
      read
    end

    # write to file descriptor
    def write(data)
      mdata = Marshal.dump(data).unpack("h*")[0]
      @w.write mdata.size
      @w.write "\n"
      @w.flush
      @w.write mdata
      @w.flush
    end

    # write from next task
    def send(data)
      next_task.write(data)
    end

    def close
      @w.close
    end

    def finish
      next_task&.close
    end

    def process
      @proc = lambda do
        yield self
        finish
      end
    end

    def run
      @thread = Thread.new do
        @proc.call
      end
    end

    def join
      @thread.join
    end
  end
end
