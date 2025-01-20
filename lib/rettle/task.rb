class Rettle
  class Task
    def initialize(type:, name:)
      @type = type
      @name = name
      @r, @w = IO.pipe
    end
    attr_reader :name
    attr_accessor :proc

    # read from file descriptor
    def read
      size = @r.readline.chomp.to_i
      mstr = @r.read(size)
      Marshal.load([mstr].pack("h*"))
    rescue EOFError
      # read was closed
      nil
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

    # write to file descriptor
    def write(data)
      mdata = Marshal.dump(data).unpack("h*")[0]
      @w.write mdata.size
      @w.write "\n"
      @w.flush
      @w.write mdata
      @w.flush
    end

    def send(data)
      write(data)
    end

    def close
      @w.close
    end

    def run
      @thread = Thread.new do
        @proc.call
      end if @proc
    end

    def join
      @thread&.join
    end
  end
end
