# frozen_string_literal: true

require 'thread'

class Rettle
  class Network
    QUEUE_SIZE = 256

    def initialize(type: :queue)
      @type = type
      server_open
    end

    def server_open
      case @type
      when :pipe
        @fds = IO.pipe
      when :queue
        @fds = SizedQueue.new(QUEUE_SIZE)
      end
    end

    def read
      case @type
      when :pipe
        fd = @fds[0]
        size = fd.readline.chomp.to_i
        mstr = fd.read(size)
        Marshal.load([mstr].pack("h*"))
      when :queue
        @fds.pop
      end
    rescue EOFError
      nil
    end

    def write(data)
      case @type
      when :pipe
        mdata = Marshal.dump(data).unpack("h*")[0]
        fd = @fds[1]
        fd.write mdata.size
        fd.write "\n"
        fd.flush
        fd.write mdata
        fd.flush
      when :queue
        @fds.push(data)
      end
    end

    def close
      case @type
      when :pipe
        @fds[1].close
      when :queue
        @fds.close
      end
    end
  end
end
