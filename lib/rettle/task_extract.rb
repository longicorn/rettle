# frozen_string_literal: true

require 'fileutils'
require 'net/http'

class Rettle
  module TaskExtract
    def after_download(file_name)
      case `file #{file_name}`
      when /Zip archive data/io
        ret = `unzip -uo #{file_name}`
        ret.lines.select{|v|v.match?(/inflating:/)}.map{|v|v.strip.split(':')[-1].strip}
      else
        file_name
      end
    end

    def download(url:, dir:, cleanup: true)
      raise if url.nil?

      FileUtils.rm_rf(dir) if cleanup
      FileUtils.mkdir_p(dir)
      file_name = url.split('/').last

      download_files = nil
      Dir.chdir(dir) do
        uri = URI(url)
        data = Net::HTTP.get(uri)
        File.open(file_name, 'w+b'){|f|f.write(data)}

        download_files = after_download(file_name)
      end
      if download_files.is_a?(Array)
        download_files.map{|f| File.join(dir, f)}
      elsif download_files.is_a?(String)
        File.join(dir, download_files)
      else
        nil
      end
    end
  end
end
