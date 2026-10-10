# frozen_string_literal: true

require 'net/smtp'

# Accounts-database outbox for transactional email (FBL-032).
#
# A row is created in the SAME accounts transaction that commits the token
# it announces, so delivery work can never reference token state that was
# rolled back - the atomicity a cross-database queue enqueue cannot offer.
# The drain job turns pending rows into deliveries with bounded exponential
# retry; a row that exhausts its attempts is marked permanently failed and
# surfaced in logs by user id and kind, never by address or token.
class EmailOutboxEntry < AccountRecord
  MAIL_KINDS = %w[confirmation password_reset].freeze
  MAX_ATTEMPTS = 5

  # A PERMANENT rejection must not be retried at all.
  #
  # Migadu counts every rejected attempt as a session error and escalates to
  # "421 too many errors". In July that took ALL mail down for three days -
  # invoices, confirmations, and the ops alerts too, because this host has no
  # MTA and Rails SMTP is the only path to a human. Retrying a 550 five times
  # per message is how one bad sender address silences everything else.
  #
  # 5xx is final by definition (RFC 5321). Authentication failures are final
  # in the same practical sense: a wrong password does not become right on the
  # fourth attempt, and per-brand SMTP credentials make a single mistyped
  # brand password a realistic way to produce exactly that.
  PERMANENT_ERRORS = [
    Net::SMTPFatalError,
    Net::SMTPSyntaxError,
    Net::SMTPAuthenticationError
  ].freeze

  def self.permanent_failure?(error)
    PERMANENT_ERRORS.any? { |klass| error.is_a?(klass) }
  end

  belongs_to :user

  validates :mail_kind, inclusion: { in: MAIL_KINDS }

  scope :pending, lambda {
    where(delivered_at: nil, failed_at: nil)
      .where('next_attempt_at IS NULL OR next_attempt_at <= ?', Time.current)
  }
  scope :undelivered, -> { where(delivered_at: nil, failed_at: nil) }

  # DURABLE_TRANSACTIONAL_EMAIL=true switches the controllers from
  # synchronous deliver_now to outbox rows (FBL-032 rollout flag; stays off
  # until the operator proves Solid Queue supervision in production).
  def self.active_for_delivery?
    ENV['DURABLE_TRANSACTIONAL_EMAIL'] == 'true' && table_exists?
  end

  def self.enqueue!(user, kind)
    create!(user: user, mail_kind: kind)
  end

  # Age of the oldest undelivered row - the queue-lag instrument.
  def self.oldest_pending_age_seconds
    oldest = undelivered.minimum(:created_at)
    oldest ? (Time.current - oldest).to_i : 0
  end

  def build_mail
    case mail_kind
    when 'confirmation' then UserMailer.confirmation_email(user)
    when 'password_reset' then UserMailer.password_reset(user, user.reset_password_token)
    end
  end

  def deliverable?
    case mail_kind
    when 'confirmation' then user.confirmed_at.nil? && user.confirmation_token.present?
    when 'password_reset' then user.reset_password_token.present?
    else false
    end
  end

  def record_success!
    update!(delivered_at: Time.current)
  end

  def record_failure!(error)
    backoff = [30 * (2**attempts), 3600].min
    permanent = self.class.permanent_failure?(error)
    if permanent || attempts + 1 >= MAX_ATTEMPTS
      update!(attempts: attempts + 1, last_error_class: error.class.name,
              failed_at: Time.current)
      Rails.logger.error(
        "[EmailOutbox] permanent failure kind=#{mail_kind} user_id=#{user_id} " \
        "attempts=#{attempts + 1} error=#{error.class} " \
        "reason=#{permanent ? 'rejected' : 'attempts_exhausted'}"
      )
    else
      update!(attempts: attempts + 1, last_error_class: error.class.name,
              next_attempt_at: backoff.seconds.from_now)
    end
  end
end
