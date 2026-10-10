# frozen_string_literal: true

require 'open3'
require 'tempfile'

# Finish serialization while the authenticated controller still holds its
# account-erasure lease. A database/encoding/capacity failure therefore occurs
# BEFORE a successful response, never as silently missing data or broken JSON.
# The buffer is 0600 and anonymous: no readable pathname, retained export, or
# backup artifact, including when the worker is killed. Rack receives no
# to_path/to_ary interface that could retain a named file or collect the body.
class AccountExportDownload
  CHUNK_BYTES = 64 * 1024
  MIN_FREE_BYTES = 256 * 1024 * 1024
  SPACE_CHECK_INTERVAL = 4 * 1024 * 1024
  MAX_GENERATION_SECONDS = 90

  class CapacityUnavailable < StandardError; end
  class GenerationDeadlineExceeded < StandardError; end

  def self.prepare(user, on_complete: nil, free_bytes: FreeSpace.method(:available),
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    file = nil
    prepared = false
    directory = Dir.tmpdir
    guard = GenerationGuard.new(directory, free_bytes: free_bytes, clock: clock)
    guard.check!(0)
    # Ruby's anonymous Windows implementation already supplies File::BINARY;
    # passing binmode: true as well raises "binmode specified twice" there.
    file = Tempfile.create('ww-account-export-', directory, anonymous: true)
    file.binmode
    AccountExportService.new(user).each_json do |chunk|
      guard.check!(chunk.bytesize)
      file.write(chunk)
    end
    file.flush
    guard.check!(0, force_space_check: true)
    file.rewind
    body = new(file, on_complete: on_complete)
    prepared = true
    body
  ensure
    file&.close unless prepared
  end

  attr_reader :bytesize

  def initialize(file, on_complete: nil)
    @file = file
    @bytesize = file.size
    @on_complete = on_complete
  end

  def each
    return enum_for(:each) unless block_given?
    raise IOError, 'export body is closed' if closed?

    while (chunk = @file.read(CHUNK_BYTES))
      yield chunk
    end
    # This proves complete generation and handoff to Rack, not that the
    # browser persisted the bytes. An aborted iteration never records success.
    @on_complete&.call
  rescue StandardError => e
    Rails.logger.error("[AccountExport] transfer_failed #{e.class}")
    raise
  ensure
    close if block_given?
  end

  def close
    @file.close unless closed?
  end

  def closed?
    @file.closed?
  end

  class GenerationGuard
    def initialize(directory, free_bytes:, clock:)
      @directory = directory
      @free_bytes = free_bytes
      @clock = clock
      @deadline = clock.call + MAX_GENERATION_SECONDS
      @until_space_check = 0
    end

    def check!(bytes, force_space_check: false)
      raise GenerationDeadlineExceeded if @clock.call >= @deadline

      @until_space_check -= bytes
      return unless force_space_check || @until_space_check <= 0

      available = @free_bytes.call(@directory)
      raise CapacityUnavailable unless available.is_a?(Integer) && available >= MIN_FREE_BYTES + bytes

      @until_space_check = SPACE_CHECK_INTERVAL
    end
  end

  # No user-controlled interpolation, additional gem, or permission to proceed
  # on unknown capacity. Production uses df's available blocks. The Windows
  # development runtime asks PowerShell for the temporary drive's free bytes;
  # Fiddle is no longer a bundled standard-library gem in Ruby 4.
  class FreeSpace
    def self.available(directory)
      return windows_available(directory) if Gem.win_platform?

      output, status = Open3.capture2('df', '-Pk', '--', directory, err: File::NULL)
      return nil unless status.success?

      Integer(output.lines.last.split[3], 10) * 1024
    rescue StandardError
      nil
    end

    def self.windows_available(directory)
      drive = File.expand_path(directory)[/\A([a-z]):/i, 1]
      return nil unless drive

      script = "$ErrorActionPreference='Stop'; [Console]::Write((Get-PSDrive -PSProvider FileSystem -Name $env:WW_EXPORT_TMP_DRIVE).Free)"
      output, status = Open3.capture2({ 'WW_EXPORT_TMP_DRIVE' => drive }, 'powershell.exe',
                                      '-NoProfile', '-NonInteractive', '-Command', script, err: File::NULL)
      Integer(output.strip, 10) if status.success?
    end
  end
end
