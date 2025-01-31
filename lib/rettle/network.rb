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
      end
    end

    def read_fd
      case @type
      when :pipe
        @fds[0]
      end
    end

    def write_fd
      case @type
      when :pipe
        @fds[1]
      end
    end
  end
end
