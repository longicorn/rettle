# frozen_string_literal: true

require 'pathname'
require 'fileutils'
require 'net/http'

class Rettle
  module TaskExtract
    class UndefinedError < StandardError; end

    def after_download(pathname, dir: dir)
      case `file #{pathname.to_s}`
      when /Zip archive data/io
        ret = `unzip -o #{pathname.to_s} 2>/dev/null`
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
          pathnames = downloader(url: url, dir: dir)
        rescue UndefinedError
          raise if url.nil?
          pathnames = default_downloader(url: url, dir: dir)
        end

        download_files = []
        pathnames.each do |pathname|
          download_files += after_download(pathname, dir: dir)
        end
        FileUtils.chmod_R('+w', './')
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

    def git_clone(url: url, dir: nil)
      FileUtils.mkdir_p(dir)
      repo = url.split('/').last.split('.').first
      Dir.chdir(dir) do
        `git clone #{url} 1>/dev/null 2>&1` unless Dir.exist?(repo)
        Dir.chdir(repo) do
          `git pull 1>/dev/null 2>&1`
        end
      end

      path = File.join(dir, repo)
      Pathname.new(path)
    end

    private

    def default_downloader(url:, dir:)
      file_name = url.split('/').last
      uri = URI(url)
      data = Net::HTTP.get(uri)
      File.open(file_name, 'w+b'){|f|f.write(data)}
      [Pathname.new(file_name)]
    end
  end
end
