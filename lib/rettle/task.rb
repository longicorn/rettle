require_relative "network"

class Rettle
  class Task
    def initialize(type:, name:)
      @type = type
      @name = name
      # extract task is not recv
      @network = Network.new(type: :pipe) if type != :extract
    end
    attr_reader :name, :network
    attr_accessor :proc

    # read from file descriptor
    def read
      fd = @network.read_fd
      size = fd.readline.chomp.to_i
      mstr = fd.read(size)
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
      fd = @network.write_fd
      fd.write mdata.size
      fd.write "\n"
      fd.flush
      fd.write mdata
      fd.flush
    end

    def send(data)
      write(data)
    end

    def close
      @network.write_fd.close
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
