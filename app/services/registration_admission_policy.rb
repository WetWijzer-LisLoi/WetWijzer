# frozen_string_literal: true

# WW-ABUSE-01 (ABUSE-05): the one admission policy for registration
# submissions; it replaced the non-atomic AuthRateLimiting registration
# limiter. Every limit is an atomic AtomicCacheCounter reservation, keyed by
# keyed digests only (never an address or an email in a cache key), and any
# cache failure denies: a submission the policy cannot count creates nothing.
#
# For each POST /signup that passes CSRF, in this order:
#
# 1. exact address: at most EXACT_ADDRESS_LIMIT per clock hour;
# 2. network (/24 or /64, SignupNetworkDiscriminator): at most
#    network_hourly_ceiling per clock hour, the emergency stop for sustained
#    abuse that keeps solving proofs. The default is deliberately high: a
#    campus, an office or a carrier puts many people behind one shared range,
#    and each of them must still be able to sign up with one proof. The
#    SIGNUP_NETWORK_HOURLY_CEILING variable tunes it; a value that is not an
#    integer in NETWORK_CEILING_RANGE is ignored;
# 3. soft gate: once a network has made NETWORK_FREE_SUBMISSIONS submissions
#    in the current and previous NETWORK_WINDOW (a look-back of 10 to 20
#    minutes, so a burst cannot straddle a window boundary), every further
#    submission needs a one-time proof of work (SignupProofOfWork) bound to
#    this network and this email. The third person behind a shared network
#    gets bounded friction, never a refusal; rotated-address bursts get no
#    account without solving. SIGNUP_NETWORK_GATE=off is the rollback switch:
#    no proof is asked, and every other limit stays;
# 4. normalized email: at most EMAIL_LIMIT per clock hour, counted only for
#    submissions past the gate, the only ones that can send mail. The answer
#    is the same whether or not the address has an account.
#
# The gate never looks at whether the email has an account, so the duplicate
# and the fresh paths meet the same challenge and the same answers. Every
# outcome but a plain admission is counted in AbuseDefenceMetrics, by its
# event code only.
# Rack::Attack keeps a coarser per-address shield in front of all of this
# (config/initializers/rack_attack.rb).
class RegistrationAdmissionPolicy
  EXACT_ADDRESS_LIMIT = 5
  EMAIL_LIMIT = 3
  NETWORK_FREE_SUBMISSIONS = 2
  NETWORK_WINDOW = 10.minutes
  LIMIT_WINDOW = 1.hour
  DEFAULT_NETWORK_HOURLY_CEILING = 50
  NETWORK_CEILING_RANGE = (10..1_000)
  NETWORK_CEILING_ENV = 'SIGNUP_NETWORK_HOURLY_CEILING'
  NETWORK_GATE_ENV = 'SIGNUP_NETWORK_GATE'
  OUTCOME_METRICS = {
    address_limited: :signup_address_denied,
    network_limited: :signup_network_ceiling_denied,
    email_limited: :signup_email_denied,
    unavailable: :signup_counter_unavailable
  }.freeze
  EMAIL_DIGEST_SALT = 'signup-email-digest v1'
  KEY_PREFIX = 'signup-admission:v1'

  Decision = Struct.new(:outcome, :gated, keyword_init: true) do
    def admitted?
      outcome == :admitted
    end
  end

  class << self
    def email_digest(email)
      @email_key ||= Rails.application.key_generator.generate_key(EMAIL_DIGEST_SALT, 32)
      OpenSSL::HMAC.hexdigest('SHA256', @email_key, "signup-email:v1:#{email.to_s.strip.downcase}")
    end

    # The soft gate's rollback switch: only the value off (any case) turns
    # it off. Puma reads its environment at start, so a change needs a
    # restart (docs/ops/ww-abuse-01-suspension-and-signup-defence.md).
    def network_gate_enabled?
      !ENV.fetch(NETWORK_GATE_ENV, '').strip.casecmp?('off')
    end

    # Parsed once per distinct raw value, so a rejected value warns once.
    def network_hourly_ceiling
      raw = ENV.fetch(NETWORK_CEILING_ENV, nil)
      (@network_hourly_ceilings ||= {})[raw] ||= parse_network_hourly_ceiling(raw)
    end

    private

    def parse_network_hourly_ceiling(raw)
      return DEFAULT_NETWORK_HOURLY_CEILING if raw.blank?

      value = Integer(raw, 10, exception: false)
      return value if value && NETWORK_CEILING_RANGE.cover?(value)

      Rails.logger.warn("[SIGNUP-ADMISSION] #{NETWORK_CEILING_ENV} ignored: not an integer in " \
                        "#{NETWORK_CEILING_RANGE}; using #{DEFAULT_NETWORK_HOURLY_CEILING}")
      DEFAULT_NETWORK_HOURLY_CEILING
    end
  end

  def initialize(remote_ip:, email:, now: Time.current)
    @now = now
    @address = SignupNetworkDiscriminator.exact_for(remote_ip)
    @network = SignupNetworkDiscriminator.for(remote_ip)
    @email_digest = self.class.email_digest(email)
  end

  # Outcomes: :admitted, :challenge, :address_limited, :network_limited,
  # :email_limited, :unavailable. gated is true when the network needed a
  # proof, so a form shown again after this submission carries a new one.
  def evaluate(proof)
    return decision(:address_limited) unless reserve(:address, @address, EXACT_ADDRESS_LIMIT, LIMIT_WINDOW)
    return decision(:network_limited) unless reserve(:network, @network, self.class.network_hourly_ceiling, LIMIT_WINDOW)

    gated = network_gated?
    if gated
      unless proof_accepted?(proof)
        AbuseDefenceMetrics.record(proof.blank? ? :signup_challenge_required : :signup_challenge_failed)
        return decision(:challenge, gated: true)
      end
      AbuseDefenceMetrics.record(:signup_challenge_passed)
    end
    return decision(:email_limited, gated: gated) unless reserve(:email, @email_digest, EMAIL_LIMIT, LIMIT_WINDOW)

    decision(:admitted, gated: gated)
  rescue AtomicCacheCounter::Unavailable
    decision(:unavailable)
  end

  # A fresh challenge bound to this submission's network and email.
  def challenge
    SignupProofOfWork.issue(network: @network, email_digest: @email_digest, now: @now)
  end

  private

  def decision(outcome, gated: false)
    Rails.logger.info("[SIGNUP-ADMISSION] outcome=#{outcome} gated=#{gated}") unless outcome == :admitted && !gated
    metric = OUTCOME_METRICS[outcome]
    AbuseDefenceMetrics.record(metric) if metric
    Decision.new(outcome: outcome, gated: gated)
  end

  # The look-back keeps counting while the switch is off, so turning the
  # gate back on needs no warm-up.
  def network_gated?
    submissions = recent_network_submissions
    self.class.network_gate_enabled? && submissions > NETWORK_FREE_SUBMISSIONS
  end

  def proof_accepted?(proof)
    SignupProofOfWork.consume!(proof, network: @network, email_digest: @email_digest, now: @now) == :ok
  end

  def reserve(scope, digest, limit, window)
    AtomicCacheCounter.try_reserve!(key(scope, digest, window, bucket(window)), limit: limit, expires_in: window)
  end

  def recent_network_submissions
    window = NETWORK_WINDOW
    current = AtomicCacheCounter.increment!(key(:network_recent, @network, window, bucket(window)),
                                            expires_in: window * 2)
    previous = Rails.cache.read(key(:network_recent, @network, window, bucket(window) - 1)).to_i
    current + previous
  rescue AtomicCacheCounter::Unavailable
    raise
  rescue StandardError
    raise AtomicCacheCounter::Unavailable, 'network window unavailable'
  end

  def bucket(window)
    @now.to_i / window.to_i
  end

  def key(scope, digest, window, bucket)
    "#{KEY_PREFIX}:#{scope}:#{window.to_i}:#{digest}:#{bucket}"
  end
end
