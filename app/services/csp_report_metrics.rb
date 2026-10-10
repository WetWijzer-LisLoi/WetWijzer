# frozen_string_literal: true

require 'date'
require 'fileutils'
require 'json'
require 'securerandom'
require 'uri'

# Compatibility evidence, NOT a security verdict. Reports are unauthenticated
# client claims; forged reports, extensions, missing browser support, busy locks
# and storage failures can all distort them. Zero reports never prove a clean
# traffic window. No resource/document URL, arbitrary hostname, address, user,
# session, source text or query reaches the state or its diagnostic output.
#
# This lives outside Rails.cache: routine fragment-cache cleanup must not erase
# the evidence window. One private bounded snapshot, a stable nonblocking flock
# and atomic rename serialize Puma workers without queuing public requests.
# Counts are daily marginals, not identifiable per-report tuples. Admission caps
# also bound write amplification; once a ceiling is reached the snapshot is
# marked saturated and further reports cause no write. Dropped counts are unknown.
class CspReportMetrics
  class Unavailable < StandardError; end

  DIRECTIVES = %w[
    default-src script-src script-src-elem script-src-attr style-src style-src-elem style-src-attr
    img-src font-src connect-src media-src object-src frame-src child-src worker-src manifest-src
    prefetch-src fenced-frame-src form-action frame-ancestors base-uri navigate-to sandbox
    report-to report-uri require-trusted-types-for trusted-types upgrade-insecure-requests
  ].freeze
  BLOCKED_KEYWORDS = %w[inline eval wasm-eval data blob self about trusted-types-policy trusted-types-sink].freeze
  BLOCKED_CLASSES = (BLOCKED_KEYWORDS + %w[first_party umami parliamentary_portrait other_host other]).freeze
  PAGE_BRANDS = (SiteBrand::KEYS + ['unknown']).freeze
  DIMENSIONS = { 'directives' => DIRECTIVES + ['other'], 'blocked' => BLOCKED_CLASSES, 'page_brands' => PAGE_BRANDS }.freeze
  RETENTION_DAYS = 35
  MAX_BYTES = 128 * 1024
  MAX_REPORTS_PER_MINUTE = 600
  MAX_REPORTS_PER_DAY = 10_000
  MAX_COUNT = MAX_REPORTS_PER_DAY
  MAX_URI_BYTES = 8 * 1024
  NOFOLLOW = File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0
  PROCESS_MUTEX = Mutex.new
  LIMITATIONS = [
    'Unauthenticated client-reported violations; not unique users, page views or confirmed defects.',
    'Counts are lower bounds: unsupported clients, busy locks, unavailable storage and ceilings can drop reports.',
    'Dropped count is unknown; saturated days cannot establish a clean evidence window.',
    'No reports or no recorded day does not prove traffic coverage or compatibility.',
    'Daily dimensions are marginals and must not be combined into per-report tuples.'
  ].freeze

  class << self
    def default_path
      ENV.fetch('CSP_METRICS_PATH') do
        Rails.env.production? ? '/var/lib/wetwijzer/csp-measurements/daily.json' : Rails.root.join('tmp', 'csp-measurements', 'daily.json').to_s
      end
    end

    def record(categories, now: Time.current)
      new.record(categories, now: now)
    end

    def classify(report)
      token = report['effective-directive'] || report['violated-directive']
      name = token.is_a?(String) ? token.split(' ', 2).first.to_s.downcase : ''
      {
        'directives' => DIRECTIVES.include?(name) ? name : 'other',
        'blocked' => blocked_class(report['blocked-uri']),
        'page_brands' => SiteBrand.resolve_host(url_host(report['document-uri'])) || 'unknown'
      }
    end

    private

    def blocked_class(value)
      keyword = value.is_a?(String) ? value.strip.downcase.split(':', 2).first : nil
      return keyword if BLOCKED_KEYWORDS.include?(keyword)

      host = url_host(value)
      return 'other' unless host
      return 'first_party' if SiteBrand.resolve_host(host)
      return 'umami' if host == 'analytics.wetwijzer.be'
      return 'parliamentary_portrait' if host == 'www.dekamer.be'

      'other_host'
    end

    def url_host(value)
      return nil unless value.is_a?(String) && value.bytesize <= MAX_URI_BYTES

      uri = URI.parse(value.strip)
      return nil unless %w[http https].include?(uri.scheme)

      host = uri.host.to_s.downcase
      host.match?(/\A[a-z0-9.-]{1,253}\z/) ? host : nil
    rescue URI::Error
      nil
    end
  end

  def initialize(path: self.class.default_path)
    @path = File.expand_path(path)
    @directory = File.dirname(@path)
    @lock_path = File.join(@directory, '.csp-measurements.lock')
  end

  # :recorded, :saturated or :unavailable. Invalid internal category codes are
  # a programming error; all external fields must first pass classify.
  def record(categories, now: Time.current)
    validate_categories!(categories)
    with_lock(create: true) do
      state = load_state || empty_state(now)
      prune_state!(state, now.utc.to_date)
      date = now.utc.to_date.iso8601
      day = state['days'][date] ||= empty_day
      minute = now.to_i / 60
      if state['minute'] != minute
        state['minute'] = minute
        state['minute_count'] = 0
      end
      next :saturated if day['accepted'] >= MAX_REPORTS_PER_DAY || state['minute_count'] >= MAX_REPORTS_PER_MINUTE

      day['accepted'] += 1
      state['minute_count'] += 1
      categories.each { |dimension, category| day[dimension][category] = day[dimension].fetch(category, 0) + 1 }
      # Set these on the final admitted report, not on a dropped request that
      # would otherwise cause unbounded writes after the cap.
      day['saturated'] = true if day['accepted'] == MAX_REPORTS_PER_DAY || state['minute_count'] == MAX_REPORTS_PER_MINUTE
      save_state!(state)
      :recorded
    end
  rescue Unavailable, SystemCallError, IOError, JSON::ParserError
    :unavailable
  end

  # Read only: no creation, cache mutation, secret output or silently replacing
  # damaged evidence with empty counts. An absent/corrupt file is unavailable.
  def snapshot(today: Time.current.utc.to_date)
    with_lock(create: false) do
      state = load_state
      raise Unavailable, 'no measurement evidence' unless state

      prune_state!(state, today)
      {
        'status' => state['days'].empty? ? 'no_recent_evidence' : 'recorded', 'schema' => 1, 'started_on' => state['started_on'],
        'retention_days' => RETENTION_DAYS, 'ceilings' => { 'per_minute' => MAX_REPORTS_PER_MINUTE, 'per_day' => MAX_REPORTS_PER_DAY },
        'dropped_count' => nil, 'limitations' => LIMITATIONS, 'days' => state['days'].sort.to_h
      }
    end
  rescue Unavailable, SystemCallError, IOError, JSON::ParserError
    { 'status' => 'unavailable', 'dropped_count' => nil, 'limitations' => LIMITATIONS, 'days' => nil }
  end

  private

  def with_lock(create:)
    raise Unavailable, 'measurements busy' unless PROCESS_MUTEX.try_lock

    begin
      FileUtils.mkdir_p(@directory, mode: 0o700) if create
      directory = File.lstat(@directory)
      raise Unavailable, 'unsafe measurement directory' unless directory.directory? && private_owned?(directory)
      raise Unavailable, 'unsafe measurement file' if File.symlink?(@lock_path) || File.symlink?(@path)

      flags = (create ? File::RDWR | File::CREAT : File::RDONLY) | NOFOLLOW
      File.open(@lock_path, flags, 0o600) do |lock|
        raise Unavailable, 'unsafe measurement lock' unless lock.stat.file? && private_owned?(lock.stat)
        raise Unavailable, 'measurements busy' unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        @directory_identity = [directory.dev, directory.ino]
        validate_directory!
        yield
      ensure
        lock&.flock(File::LOCK_UN)
      end
    ensure
      PROCESS_MUTEX.unlock
    end
  end

  def load_state
    return nil unless File.exist?(@path)

    validate_directory!
    File.open(@path, File::RDONLY | NOFOLLOW) do |file|
      stat = file.stat
      raise Unavailable, 'unsafe measurement state' unless stat.file? && private_owned?(stat) && stat.size <= MAX_BYTES

      data = file.read(MAX_BYTES + 1)
      raise Unavailable, 'oversized measurement state' if data.bytesize > MAX_BYTES

      state = JSON.parse(data)
      validate_state!(state)
      state
    end
  end

  def validate_state!(state)
    unless state.is_a?(Hash) && state.keys.sort == %w[days minute minute_count schema started_on] && state['schema'] == 1 &&
           valid_date?(state['started_on']) && state['minute'].is_a?(Integer) && state['minute'] >= 0 &&
           bounded_count?(state['minute_count'], MAX_REPORTS_PER_MINUTE) && state['days'].is_a?(Hash) && state['days'].size <= RETENTION_DAYS
      raise Unavailable, 'invalid measurement state'
    end

    state['days'].each do |date, day|
      unless valid_date?(date) && day.is_a?(Hash) && day.keys.sort == (%w[accepted saturated] + DIMENSIONS.keys).sort &&
             bounded_count?(day['accepted']) && [true, false].include?(day['saturated'])
        raise Unavailable, 'invalid measurement day'
      end

      DIMENSIONS.each do |dimension, codes|
        counters = day[dimension]
        unless counters.is_a?(Hash) && (counters.keys - codes).empty? && counters.values.all? { |count| bounded_count?(count) } &&
               counters.values.sum == day['accepted']
          raise Unavailable, 'invalid measurement counters'
        end
      end
    end
  end

  def save_state!(state)
    validate_state!(state)
    payload = JSON.generate(state)
    raise Unavailable, 'oversized measurement state' if payload.bytesize > MAX_BYTES

    temporary = File.join(@directory, ".daily-#{SecureRandom.hex(12)}.tmp")
    temporary_created = false
    validate_directory!
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | NOFOLLOW, 0o600) do |file|
      temporary_created = true
      file.write(payload)
      file.flush
      file.fsync
    end
    validate_directory!
    File.rename(temporary, @path)
    File.open(@directory, File::RDONLY | NOFOLLOW, &:fsync) unless Gem.win_platform?
  ensure
    File.unlink(temporary) if temporary_created && File.exist?(temporary)
  end

  def prune_state!(state, today)
    cutoff = (today - RETENTION_DAYS + 1).iso8601
    state['days'].delete_if { |date, _| date < cutoff || date > today.iso8601 }
  end

  def empty_state(now)
    { 'schema' => 1, 'started_on' => now.utc.to_date.iso8601, 'minute' => now.to_i / 60, 'minute_count' => 0, 'days' => {} }
  end

  def empty_day
    { 'accepted' => 0, 'saturated' => false }.merge(DIMENSIONS.to_h { |dimension, _| [dimension, {}] })
  end

  def validate_categories!(categories)
    return if categories.is_a?(Hash) && categories.keys.sort == DIMENSIONS.keys.sort &&
              categories.all? { |dimension, category| DIMENSIONS.fetch(dimension).include?(category) }

    raise ArgumentError, 'not canonical CSP categories'
  end

  def valid_date?(value)
    value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(value).iso8601 == value
  rescue Date::Error
    false
  end

  def bounded_count?(value, maximum = MAX_COUNT)
    value.is_a?(Integer) && value.between?(0, maximum)
  end

  def validate_directory!
    stat = File.lstat(@directory)
    return if stat.directory? && private_owned?(stat) && [stat.dev, stat.ino] == @directory_identity

    raise Unavailable, 'measurement directory changed'
  end

  def private_owned?(stat)
    # Windows cannot enforce POSIX modes; real Linux permissions are a release
    # gate. Unix never accepts a state/lock readable or writable by other users.
    Gem.win_platform? || (stat.mode.nobits?(0o077) && stat.uid == Process.euid)
  end
end
