# frozen_string_literal: true

require 'pathname'
require 'fileutils'
require 'net/http'

class Rettle
  module TaskExtract
    class UndefinedError < StandardError; end

    def after_download(pathname)
      case `file #{pathname.to_s}`
      when /Zip archive data/io
        ret = `unzip -o #{pathname.to_s}`
        ret.lines.select{|v|v.match?(/inflating:/)}.map{|v|v.strip.split(':')[-1].strip}
      else
        pathname.to_s
      end
    end

    def downloader(**args)
      raise UndefinedError
    end

    def download(url: nil, dir: nil, cleanup: true)
      raise if dir&.nil?

      FileUtils.rm_rf(dir) if cleanup
      FileUtils.mkdir_p(dir)

      download_files = nil
      Dir.chdir(dir) do
        begin
          pathname = downloader(url: url, dir: dir)
        rescue UndefinedError
          raise if url.nil?
          pathname = default_downloader(url: url, dir: dir)
        end
         download_files = after_download(pathname)
      end

      case download_files
      when Array
        download_files.map{|f| File.join(dir, f)}
      when String
        File.join(dir, download_files)
      else
        nil
      end
    end

    private

    def default_downloader(url:, dir:)
      file_name = url.split('/').last
      uri = URI(url)
      data = Net::HTTP.get(uri)
      File.open(file_name, 'w+b'){|f|f.write(data)}
      Pathname.new(file_name)
    end
  end
end
