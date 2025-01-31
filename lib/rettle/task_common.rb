# frozen_string_literal: true

require 'tempfile'
require 'kconv'

class Rettle
  module TaskCommon
    def encoding!(path, encoding: :utf8)
      tmppath = "#{path}_#{encoding}"
      tmp = Tempfile.open(tmppath) do |tf|
        File.open(path) do |f|
          f.each_line do |line|
            tf.write(line.toutf8)
          end
        end
        tf
      end
      FileUtils.mv(tmp.path, path)
    end
  end
end
