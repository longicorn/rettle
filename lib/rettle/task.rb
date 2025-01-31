# frozen_string_literal: true

require_relative "network"
require_relative "task_common"
require_relative "task_extract"
require_relative "task_transform"
require_relative "task_load"
require 'forwardable'

class Rettle
  class Task
    extend Forwardable

    def initialize(type:, name:, watchdog_fd:)
      @type = type
      @name = name
      @watchdog_fd = watchdog_fd
      # extract task is not recv
      @network = Network.new(type: :pipe) if type != :extract

      type_name = type.to_s[0].upcase + type.to_s[1..]
      class_name = Object.const_get("::Rettle::Task#{type_name}")
      self.class.send(:include, class_name)
      class_name = Object.const_get("::Rettle::TaskCommon")
      self.class.send(:include, class_name)
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
      rescue => e
        p e
        puts e.backtrace.join("\n")
        @watchdog_fd.write("1")
        @watchdog_fd.flush
      end if @proc
    end

    delegate join: :@thread
    delegate kill: :@thread
  end
end
