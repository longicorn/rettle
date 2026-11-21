# frozen_string_literal: true

require 'pathname'
require 'fileutils'
require 'net/http'
require 'open3'

class Rettle
  module TaskExtract
    class UndefinedError < StandardError; end

    def after_download(pathname, dir: nil)
      case Open3.capture2("file", "--", pathname.to_s).first
      when /Zip archive data/io
        ret, status = Open3.capture2("unzip", "-o", pathname.to_s)
        raise "unzip failed" unless status.success?
        ret.lines.filter_map { |line| line.match(/^\s*(?:inflating|extracting):\s*(.*)$/)&.[](1)&.strip }
      else
        pathname.to_s
      end
    end

    def downloader(**args)
      raise UndefinedError
    end

    def download(url: nil, dir: nil, cleanup: true)
      raise ArgumentError, "dir must not be nil" if dir.nil?

      FileUtils.rm_rf(dir) if cleanup
      FileUtils.mkdir_p(dir)

      download_files = []
      Dir.chdir(dir) do
        begin
          pathnames = downloader(url: url, dir: dir)
        rescue UndefinedError
          raise if url.nil?
          pathnames = default_downloader(url: url, dir: dir)
        end

        pathnames.each do |pathname|
          download_files << after_download(pathname, dir: dir)
        end
        FileUtils.chmod_R('+w', './')
      end

      return download_files.flatten.compact.map{|f| File.join(dir, f)}
    end

    def git_clone(url:, dir: nil)
      FileUtils.mkdir_p(dir)
      repo = url.split('/').last.sub(/\.git\z/, '')
      Dir.chdir(dir) do
        system("git", "clone", "--", url, out: File::NULL, err: File::NULL) || raise("git clone failed") unless Dir.exist?(repo)
        Dir.chdir(repo) do
          system("git", "pull", out: File::NULL, err: File::NULL) || raise("git pull failed")
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
