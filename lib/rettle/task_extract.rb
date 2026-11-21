# frozen_string_literal: true

require 'pathname'
require 'fileutils'
require 'net/http'
require 'open3'
require 'tempfile'
require 'digest'
require 'zlib'
require 'rubygems/package'

class Rettle
  module TaskExtract
    class UndefinedError < StandardError; end
    class TransientHTTPError < StandardError; end

    attr_reader :download_metadata

    def after_download(pathname, dir: nil)
      dir ||= '.'
      path = pathname.to_s
      path = File.join(dir, path) unless Pathname.new(path).absolute?
      type = Open3.capture2('file', '--', path).first
      if type.match?(/Zip archive data/i)
        listing, status = Open3.capture2('unzip', '-Z1', path)
        raise 'unzip listing failed' unless status.success?
        details, status = Open3.capture2('zipinfo', '-l', path)
        raise 'zip inspection failed' unless status.success?
        raise 'archive symlinks are unsupported' if details.lines.any? { |line| line.start_with?('l') }
        entries = listing.lines.map(&:chomp)
        entries.each { |entry| safe_archive_path(dir, entry) }
        _out, status = Open3.capture2('unzip', '-o', File.expand_path(path), '-d', dir)
        raise 'unzip failed' unless status.success?
        entries.reject { |entry| entry.end_with?('/') }
      elsif path.end_with?('.tar.gz', '.tgz')
        entries = []
        Zlib::GzipReader.open(path) do |gzip|
          Gem::Package::TarReader.new(gzip) do |tar|
            tar.each do |entry|
              target = safe_archive_path(dir, entry.full_name)
              if entry.directory?
                FileUtils.mkdir_p(target)
              elsif entry.file?
                FileUtils.mkdir_p(File.dirname(target))
                File.open(target, 'wb') { |file| IO.copy_stream(entry, file) }
                entries << entry.full_name
              else
                raise "unsupported archive entry: #{entry.full_name}"
              end
            end
          end
        end
        entries
      elsif path.end_with?('.gz')
        name = File.basename(path).sub(/\.gz\z/, '')
        target = safe_archive_path(dir, name)
        Zlib::GzipReader.open(path) { |gzip| File.open(target, 'wb') { |file| IO.copy_stream(gzip, file) } }
        [name]
      else
        path
      end
    end

    def downloader(**args)
      raise UndefinedError
    end

    def download(url: nil, dir: nil, cleanup: true, max_redirects: 5, open_timeout: 10, read_timeout: 60, retries: 2, etag: nil, last_modified: nil)
      raise ArgumentError, 'dir must not be nil' if dir.nil?
      dir = File.expand_path(dir)
      FileUtils.rm_rf(dir) if cleanup && !etag && !last_modified
      FileUtils.mkdir_p(dir)
      @download_metadata = nil
      begin
        pathnames = downloader(url: url, dir: dir)
      rescue UndefinedError
        raise if url.nil?
        pathnames = default_downloader(url: url, dir: dir, max_redirects: max_redirects, open_timeout: open_timeout, read_timeout: read_timeout, retries: retries, etag: etag, last_modified: last_modified)
      end
      pathnames.flat_map do |pathname|
        Array(after_download(pathname, dir: dir)).map do |file|
          Pathname.new(file).absolute? ? file.to_s : File.join(dir, file.to_s)
        end
      end
    end

    def git_clone(url:, dir: nil)
      url = File.expand_path(url) if File.exist?(url)
      FileUtils.mkdir_p(dir)
      repo = url.split('/').last.sub(/\.git\z/, '')
      path = File.join(dir, repo)
      system('git', '-C', dir, 'clone', '--', url, out: File::NULL, err: File::NULL) || raise('git clone failed') unless Dir.exist?(path)
      system('git', '-C', path, 'pull', out: File::NULL, err: File::NULL) || raise('git pull failed')
      Pathname.new(path)
    end

    private

    def safe_archive_path(dir, name)
      root = File.expand_path(dir)
      target = File.expand_path(name, root)
      raise "unsafe archive entry: #{name}" unless target.start_with?(root + File::SEPARATOR)
      relative = target.delete_prefix(root + File::SEPARATOR)
      current = root
      relative.split(File::SEPARATOR).each do |component|
        current = File.join(current, component)
        raise "unsafe archive entry: #{name}" if File.symlink?(current)
      end
      target
    end

    def default_downloader(url:, dir:, max_redirects:, open_timeout:, read_timeout:, retries:, etag:, last_modified:)
      uri = URI(url)
      name = File.basename(uri.path)
      raise ArgumentError, 'URL must identify a file' if name.empty? || name == '/' || name == '.' || name == '..'
      target = File.join(dir, name)
      attempts = 0
      begin
        current = uri
        redirects = 0
        loop do
          raise ArgumentError, 'unsupported URL scheme' unless %w[http https].include?(current.scheme)
          request = Net::HTTP::Get.new(current)
          request['If-None-Match'] = etag if etag
          request['If-Modified-Since'] = last_modified if last_modified
          http = Net::HTTP.new(current.host, current.port)
          http.use_ssl = current.scheme == 'https'
          http.open_timeout = open_timeout
          http.read_timeout = read_timeout
          result = nil
          http.start do |client|
            client.request(request) do |response|
              case response
              when Net::HTTPNotModified
                @download_metadata = { etag: response['etag'] || etag, last_modified: response['last-modified'] || last_modified, cached: true }
                result = []
              when Net::HTTPRedirection
                raise 'redirect limit exceeded' if redirects >= max_redirects
                current = URI.join(current, response.fetch('location'))
                redirects += 1
                result = :redirect
              when Net::HTTPSuccess
                Tempfile.create(['rettle-', '.download'], dir) do |temp|
                  temp.binmode
                  digest = Digest::SHA256.new
                  length = 0
                  response.read_body { |chunk| temp.write(chunk); digest.update(chunk); length += chunk.bytesize }
                  temp.flush
                  File.rename(temp.path, target)
                  @download_metadata = { etag: response['etag'], last_modified: response['last-modified'], content_length: length, sha256: digest.hexdigest, cached: false }
                end
                result = [Pathname.new(target)]
              else
                raise TransientHTTPError, "HTTP #{response.code}" if %w[500 502 503 504].include?(response.code)
                response.value
              end
            end
          end
          return result unless result == :redirect
        end
      rescue IOError, EOFError, SystemCallError, Timeout::Error, TransientHTTPError
        attempts += 1
        retry if attempts <= retries
        raise
      end
    end
  end
end
