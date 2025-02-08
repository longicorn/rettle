# frozen_string_literal: true

class Rettle
  class Network
    def initialize(type: :pipe)
      @type = type
      server_open
    end

    def server_open
      case @type
      when :pipe
        @fds = IO.pipe
      when :queue
        @fds = Queue.new
      end
    end

    def read
      case @type
      when :pipe
        fd = @fds[0]
        size = fd.readline.chomp.to_i
        mstr = fd.read(size)
        Marshal.load([mstr].pack("h*"))
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
      end
    end

    def close
      case @type
      when :pipe
        @fds[1].close
      end
    end
  end
end
