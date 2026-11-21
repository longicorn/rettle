# frozen_string_literal: true

class Rettle
  class Network
    QUEUE_SIZE = 256
    ProtocolError = Class.new(StandardError)
    ClosedChannelError = Class.new(StandardError)

    def initialize(type: :queue)
      @type = type
      setup_channel
    end

    def setup_channel
      case @type
      when :pipe
        @channel = IO.pipe
      when :queue
        @channel = SizedQueue.new(QUEUE_SIZE)
      else
        raise ArgumentError, "unsupported transport: #{@type.inspect}"
      end
    end

    def read
      case @type
      when :pipe
        fd = @channel[0]
        return nil if fd.closed?
        header = fd.gets
        unless header
          fd.close
          return nil
        end
        raise ProtocolError, "invalid frame header" unless header.match?(/\A[0-9]+\n\z/)
        size = header.to_i
        payload = fd.read(size)
        raise ProtocolError, "truncated frame" unless payload && payload.bytesize == size
        raise ProtocolError, "invalid frame payload" unless payload.match?(/\A(?:[0-9a-f]{2})+\z/)
        begin
          Marshal.load([payload].pack("h*"))
        rescue StandardError => e
          raise ProtocolError, "invalid serialized payload: #{e.message}"
        end
      when :queue
        @channel.pop
      end
    rescue ProtocolError
      close_reader
      raise
    end

    def write(data)
      raise ArgumentError, "nil is reserved for end of stream" if data.nil?
      case @type
      when :pipe
        mdata = Marshal.dump(data).unpack("h*")[0]
        fd = @channel[1]
        fd.write mdata.size
        fd.write "\n"
        fd.flush
        fd.write mdata
        fd.flush
      when :queue
        @channel.push(data)
      end
    rescue Errno::EPIPE, IOError, ClosedQueueError => e
      raise ClosedChannelError, e.message
    end

    def close_reader
      return unless @type == :pipe

      @channel[0].close unless @channel[0].closed?
    end

    def close
      case @type
      when :pipe
        @channel[1].close unless @channel[1].closed?
      when :queue
        @channel.close
      end
    end
  end
end
