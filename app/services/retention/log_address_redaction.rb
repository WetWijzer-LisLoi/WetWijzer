# frozen_string_literal: true

require 'ipaddr'
require 'zlib'

module Retention
  # D12 follow-up (Codex inbox 2026-10-07 18:15 CEST): no full client address
  # stays in an application log file, however slowly the file grows.
  #
  # Since this follow-up, Rails' request line and Rack::Attack's notices
  # write the network only, in SecurityLog's format (RequestLogLine,
  # config/initializers/rack_attack.rb). This pass masks whatever older lines
  # or any other writer left, in the active files and in their archives. The
  # daily scrub runs it on the application's log directory
  # (Retention::PiiScrubService). The privacy notice's 30-day bound on
  # addresses therefore no longer depends on a size-based rotation that
  # turns over slowly when traffic is low.
  #
  # The host part becomes "x" in place: an IPv4 address keeps its /24 and an
  # IPv6 address its /48, the networks SecurityLog writes. A masked address
  # has the same length as the original, so an active file is rewritten
  # without being truncated, and a line a logger appends in the meantime is
  # neither lost nor moved. Compressed archives are rewritten whole, with
  # their mode, owner and times kept. Lookalikes that are not addresses stay:
  # gem versions (activerecord-8.1.3.1), constant paths (Admin::Base),
  # times (12:34:56) and networks already written as a range (/24).
  #
  # Plain Ruby, so scripts/ops/mask_log_addresses.rb can run the same code on
  # files the application user cannot write (Puma's output under
  # /var/log/wetwijzer).
  class LogAddressRedaction
    IPV4 = %r{(?<![\w.-])(?:\d{1,3}\.){3}\d{1,3}(?![\w./])}n
    IPV6 = %r{(?<![\w:.])[0-9A-Fa-f:]*:[0-9A-Fa-f]*:[0-9A-Fa-f:]*(?![\w:./])}n
    CANDIDATE = Regexp.union(IPV4, IPV6)

    # The application's own log files, in production only: elsewhere a pass
    # names its files explicitly.
    def self.default_paths
      return [] unless defined?(Rails) && Rails.env.production?

      directory = Rails.root.join('log').to_s
      (Dir.glob(File.join(directory, '*.log')) + Dir.glob(File.join(directory, '*.log.[0-9]*'))).sort
    end

    def self.mask(address)
      address.include?(':') ? mask_v6(address) : mask_v4(address)
    end

    def self.mask_v4(address)
      head, _dot, host = address.rpartition('.')
      "#{head}.#{'x' * host.length}"
    end

    # Everything after the third group, or after a "::" before it, is host.
    def self.mask_v6(address)
      colons = 0
      masking = false
      address.each_char.with_index.map do |char, index|
        next(masking ? 'x' : char) unless char == ':'

        masking ||= index.positive? && address[index - 1] == ':'
        colons += 1
        masking ||= colons >= 3
        char
      end.join
    end

    def self.address?(candidate)
      IPAddr.new(candidate)
      candidate.include?(':') ? candidate.count(':') >= 2 : true
    rescue IPAddr::Error
      false
    end

    def initialize(paths = self.class.default_paths)
      @paths = Array(paths)
    end

    # { files:, changed_files:, addresses:, failed_files: }. A file that cannot
    # be read or written is counted and left; the other files still pass.
    def call
      counts = []
      failed = 0
      @paths.select { |path| File.file?(path) }.each do |path|
        counts << redact(path)
      rescue SystemCallError, IOError, Zlib::Error => e
        failed += 1
        report_failure(path, e)
      end
      { files: counts.size + failed, changed_files: counts.count(&:positive?), addresses: counts.sum,
        failed_files: failed }
    end

    # [masked line, number of addresses masked]
    def mask_line(line)
      count = 0
      masked = line.gsub(CANDIDATE) do |candidate|
        next candidate unless self.class.address?(candidate)

        count += 1
        self.class.mask(candidate)
      end
      [masked, count]
    end

    private

    def redact(path)
      path.end_with?('.gz') ? redact_compressed(path) : redact_in_place(path)
    end

    def report_failure(path, error)
      message = "[LogAddressRedaction] #{File.basename(path)} left unmasked: #{error.class}"
      defined?(Rails) && Rails.logger ? Rails.logger.warn(message) : warn(message)
    end

    def redact_in_place(path)
      before = File.stat(path)
      masked = 0
      File.open(path, 'r+b') do |file|
        start = 0
        while (line = file.gets)
          finish = file.pos
          redacted, count = mask_line(line)
          if count.positive? && redacted.bytesize == line.bytesize
            file.seek(start)
            file.write(redacted)
            file.seek(finish)
            masked += count
          end
          start = finish
        end
      end
      # An archive keeps its age for rotation; an active file that grew in
      # the meantime keeps its newer time.
      File.utime(before.atime, before.mtime, path) if masked.positive? && File.size(path) == before.size
      masked
    end

    def redact_compressed(path)
      stat = File.stat(path)
      temporary = "#{path}.masking"
      masked = 0
      Zlib::GzipReader.open(path) do |reader|
        Zlib::GzipWriter.open(temporary) do |writer|
          reader.each_line do |line|
            redacted, count = mask_line(line.b)
            masked += count
            writer.write(redacted)
          end
        end
      end
      return masked unless masked.positive?

      File.chmod(stat.mode & 0o7777, temporary)
      File.chown(stat.uid, stat.gid, temporary)
      File.utime(stat.atime, stat.mtime, temporary)
      File.rename(temporary, path)
      masked
    ensure
      File.delete(temporary) if temporary && File.exist?(temporary)
    end
  end
end
