# frozen_string_literal: true

require 'tempfile'
require 'fileutils'

class Rettle
  module TaskCommon
    def encoding!(path, encoding: "UTF-8", source_encoding: Encoding.default_external)
      target = Encoding.find(encoding.to_s)
      Tempfile.create(['rettle-encoding', '.tmp'], File.dirname(File.expand_path(path))) do |tmp|
        tmp.binmode
        File.open(path, "r:#{Encoding.find(source_encoding.to_s).name}") { |file| file.each_line { |line| tmp.write(line.encode(target)) } }
        tmp.flush
        FileUtils.cp(tmp.path, path)
      end
    end
  end
end
