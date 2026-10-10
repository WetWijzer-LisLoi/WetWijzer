# frozen_string_literal: true

# WW-ABUSE-01 (ABUSE-06): content-free aggregate counters for the signup
# defence and the abuse suspensions. An event is one code from EVENTS,
# counted per UTC day in Rails.cache; nothing else is recorded, in the key or
# the value: no account id, email, address, network, user agent, proof or
# token. Each event also writes one log line with the code only (the request
# id comes from the log tags).
#
# The metrics never change an outcome: a counter that cannot be written is
# skipped, and the log line still records the event. A cache outage is
# itself the signup_counter_unavailable event, so on those days the log is
# the record and the counters undercount.
module AbuseDefenceMetrics
  EVENTS = %w[
    signup_challenge_required
    signup_challenge_passed
    signup_challenge_failed
    signup_address_denied
    signup_network_ceiling_denied
    signup_email_denied
    signup_counter_unavailable
    admin_suspension
    admin_reason_change
    admin_lift
  ].freeze
  # The admin console's labels.
  LABELS = {
    'signup_challenge_required' => 'Sign-up: proof of work asked',
    'signup_challenge_passed' => 'Sign-up: proof of work passed',
    'signup_challenge_failed' => 'Sign-up: proof of work refused',
    'signup_address_denied' => 'Sign-up refused: address limit',
    'signup_network_ceiling_denied' => 'Sign-up refused: network ceiling',
    'signup_email_denied' => 'Sign-up refused: email limit',
    'signup_counter_unavailable' => 'Sign-up refused: counters unavailable',
    'admin_suspension' => 'Abuse suspensions',
    'admin_reason_change' => 'Suspension reasons changed',
    'admin_lift' => 'Suspensions lifted'
  }.freeze
  KEY_PREFIX = 'abuse-defence-metrics:v1'
  RETENTION = 35.days
  DEFAULT_DAYS = 14

  module_function

  def record(event, now: Time.current)
    event = event.to_s
    raise ArgumentError, 'unknown abuse defence metric' unless EVENTS.include?(event)

    Rails.logger.info("[ABUSE-DEFENCE] event=#{event}")
    AtomicCacheCounter.increment!(key(event, now.utc.to_date), expires_in: RETENTION)
    true
  rescue AtomicCacheCounter::Unavailable
    false
  end

  # { date => { event => count } } for the last +days+ UTC days, newest
  # first; nil when the cache cannot be read.
  def daily(days: DEFAULT_DAYS, today: Time.current.utc.to_date)
    dates = (0...days).map { |offset| today - offset }
    keys = dates.product(EVENTS).map { |date, event| key(event, date) }
    values = Rails.cache.read_multi(*keys)
    dates.to_h do |date|
      [date, EVENTS.to_h { |event| [event, values[key(event, date)].to_i] }]
    end
  rescue StandardError => e
    Rails.logger.warn("[ABUSE-DEFENCE] counters unreadable: #{e.class}")
    nil
  end

  # Per event, the sums over the newest 1, 7 and +days+ days of +daily+.
  def totals(daily)
    return nil if daily.nil?

    rows = daily.values
    EVENTS.to_h do |event|
      [event, { today: rows.first.to_h[event].to_i,
                week: rows.first(7).sum { |row| row[event].to_i },
                period: rows.sum { |row| row[event].to_i } }]
    end
  end

  def key(event, date)
    "#{KEY_PREFIX}:#{event}:#{date.iso8601}"
  end
end
