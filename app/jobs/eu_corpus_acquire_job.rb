# frozen_string_literal: true

require 'json'
require 'open3'

# Acquires only sanitized public legal identifiers/topics. It cannot accept an
# arbitrary network URL or a raw user's question. The Python helper owns public
# HTTP routing, parsers, storage locking/budgets and immutable publication.
class EuCorpusAcquireJob < ApplicationJob
  queue_as :eu_corpus
  # Wait durably behind the shared acquisition budget instead of spending
  # filesystem-lock retries while another bounded helper is still running.
  # Keep the filesystem/kernel leases too: manual helpers are outside this queue.
  limits_concurrency to: 1, key: 'shared-public-eu-acquisition', duration: 3.minutes, on_conflict: :block

  MAX_SECONDS = 60
  MAX_REQUESTS = 40
  MAX_DOWNLOAD_BYTES = 40 * 1024 * 1024
  MAX_STDOUT_BYTES = 65_536
  MAX_STDERR_BYTES = 4096
  class AcquisitionFailure < StandardError; end

  def perform(payload)
    return unless LegalChatbot::EuDiscovery.valid_payload?(payload)

    key = LegalChatbot::EuDiscovery.cache_key(payload)
    response = with_acquisition_lock { run_helper(payload) }
    return record_busy_acquisition(key) if response == :busy

    raise AcquisitionFailure unless response.is_a?(Hash) && %w[ready partial unavailable pending].include?(response['status'])

    Rails.cache.write(key, cache_state_for(response['status']), expires_in: LegalChatbot::EuDiscovery::DEDUP_SECONDS)
    # Response rows/artifacts never become answer evidence here. On the next
    # search EuLiveCorpus independently resolves their published manifest/hash.
    response['status']
  rescue StandardError => e
    Rails.cache.write(key, 'unavailable', expires_in: LegalChatbot::EuDiscovery::DEDUP_SECONDS) if key
    Rails.logger.warn("[EuCorpusAcquireJob] bounded acquisition unavailable: #{e.class}")
    nil
  end

  private

  # Another helper holds the lease: the first two attempts retry 30 seconds
  # later and leave the discovery key 'pending'; the third marks it
  # 'unavailable'. The caller is told 'pending' either way.
  def record_busy_acquisition(key)
    retry_job(wait: 30.seconds) if executions < 3
    Rails.cache.write(key, executions < 3 ? 'pending' : 'unavailable', expires_in: LegalChatbot::EuDiscovery::DEDUP_SECONDS)
    'pending'
  end

  # The helper's status as the discovery cache records it: ready and partial
  # are complete acquisitions, pending and unavailable stay as they are.
  def cache_state_for(status)
    case status
    when 'pending' then 'pending'
    when 'unavailable' then 'unavailable'
    else 'complete'
    end
  end

  def with_acquisition_lock
    root = ENV['EURLEX_LIVE_CACHE_ROOT'].presence ||
           (Rails.env.production? ? '/var/lib/wetwijzer/eu-corpus/live' : Rails.root.join('storage/eu-corpus/live').to_s)
    raise AcquisitionFailure unless File.directory?(root) &&
                                    File.realpath(root).tr('\\', '/').casecmp?(File.expand_path(root).tr('\\', '/'))

    path = File.join(root, '.acquire-job.lock')
    raise AcquisitionFailure if File.symlink?(path)

    flags = File::RDWR | File::CREAT
    flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
    File.open(path, flags, 0o600) do |lock|
      return :busy unless lock.flock(File::LOCK_EX | File::LOCK_NB)

      begin
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    end
  end

  def run_helper(payload)
    script = helper_script
    raise AcquisitionFailure unless File.file?(script) && !File.symlink?(script)

    python = helper_python
    options = Gem.win_platform? ? { new_pgroup: true } : { pgroup: true }
    input, output, errors, child = Open3.popen3(python, '-B', script,
                                                '--seconds', MAX_SECONDS.to_s,
                                                '--max-requests', MAX_REQUESTS.to_s,
                                                '--max-response-bytes', MAX_DOWNLOAD_BYTES.to_s, **options)
    input.write(JSON.generate(payload))
    input.close
    buffers = collect_helper_output(child, output, errors, deadline: monotonic_now + MAX_SECONDS + 2)
    raise AcquisitionFailure unless child.value.success?

    JSON.parse(buffers[output])
  ensure
    # Thread cancellation from shutdown must not leave a helper or socket alive.
    if child&.alive?
      signal_child('TERM', child.pid)
      unless child.join(0.2)
        signal_child('KILL', child.pid)
        child.join(0.5)
      end
    end
    [input, output, errors].compact.each { |stream| stream.close unless stream.closed? }
  end

  def helper_script
    Rails.root.join('scripts/eurlex/live_cache.py').to_s
  end

  # The interpreter the helper runs with: the configured one, else the
  # platform default; a value carrying a CR, LF or NUL is refused. Never
  # spawns anything.
  def helper_python
    python = ENV['EURLEX_PYTHON'].presence || (Gem.win_platform? ? 'python.exe' : '/usr/bin/python3')
    raise AcquisitionFailure if python.match?(/[\r\n\x00]/)

    python
  end

  # Reads the helper's stdout and stderr until both have closed and the
  # process has ended, within the monotonic deadline, each stream capped at
  # its byte limit (stdout MAX_STDOUT_BYTES, stderr MAX_STDERR_BYTES). Any
  # failure raises AcquisitionFailure; run_helper's ensure then terminates
  # the child it still owns.
  def collect_helper_output(child, output, errors, deadline:)
    buffers = { output => +'', errors => +'' }
    active = buffers.keys.dup
    until active.empty? && !child.alive?
      raise AcquisitionFailure if monotonic_now >= deadline

      ready = IO.select(active, nil, nil, [deadline - monotonic_now, 0.2].min)&.first || []
      ready.each do |stream|
        consume_helper_stream(stream, buffers, active, limit: stream == output ? MAX_STDOUT_BYTES : MAX_STDERR_BYTES)
      end
      child.join(0.01) if active.empty?
    end
    buffers
  end

  # One non-blocking read of a helper stream: end of stream retires it from
  # the active set, data is kept up to the stream's cap, over which the
  # acquisition fails.
  def consume_helper_stream(stream, buffers, active, limit:)
    data = stream.read_nonblock(4096, exception: false)
    if data.nil?
      active.delete(stream)
    elsif data != :wait_readable
      buffers[stream] << data
      raise AcquisitionFailure if buffers[stream].bytesize > limit
    end
  end

  def signal_child(signal, pid)
    Process.kill(signal, Gem.win_platform? ? pid : -pid)
  rescue Errno::ESRCH, Errno::EINVAL, NotImplementedError
    begin
      Process.kill('KILL', pid)
    rescue SystemCallError, NotImplementedError
      nil
    end
  rescue Errno::EPERM
    nil
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
