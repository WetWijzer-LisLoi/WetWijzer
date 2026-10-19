# frozen_string_literal: true

# One-time, auditable credit grant for accounts that already existed when a
# campaign was started. This deliberately lives outside signup: changing the
# signup allowance would grant the bonus to future accounts as well.
class ExistingUserCreditBonusService
  BONUS_AMOUNT = 5
  CAMPAIGN = 'existing_user_bonus_2026_10_11_v1'
  ACTIVITY_ACTION = 'credits_added'

  class InvalidSnapshot < ArgumentError; end
  class SnapshotChanged < StandardError; end

  def self.snapshot(campaign: CAMPAIGN, now: Time.current.utc)
    new(campaign: campaign, cutoff: now.utc).snapshot
  end

  def initialize(campaign:, cutoff:, upper_id: nil, expected_count: nil, apply: false)
    @campaign = campaign.to_s
    @cutoff = parse_time(cutoff)
    @upper_id = validate_optional_integer(upper_id, 'upper_id')
    @expected_count = validate_optional_integer(expected_count, 'expected_count', allow_zero: true)
    @apply = apply ? true : false
    validate_campaign!
    raise InvalidSnapshot, 'apply requires upper_id and expected_count' if @apply && (@upper_id.nil? || @expected_count.nil?)
  end

  def snapshot
    upper_id = @upper_id || User.where('created_at <= ?', @cutoff).maximum(:id).to_i
    relation = target_relation(upper_id)
    status_counts = relation.group(:active, :admin).count
    {
      campaign: @campaign,
      cutoff: @cutoff.iso8601(6),
      upper_id: upper_id,
      expected_count: relation.count,
      active_count: status_counts.select { |(active, _admin), _| active }.values.sum,
      inactive_count: status_counts.reject { |(active, _admin), _| active }.values.sum,
      suspended_count: relation.where.not(abuse_suspended_at: nil).count,
      admin_count: relation.where(admin: true).count
    }
  end

  def run!
    snap = snapshot
    verify_snapshot!(snap) if @apply

    result = {
      campaign: @campaign,
      cutoff: snap[:cutoff],
      upper_id: snap[:upper_id],
      expected_count: snap[:expected_count],
      dry_run: !@apply,
      inspected: 0,
      would_grant: 0,
      granted: 0,
      already_granted: 0,
      failures: 0,
      failure_classes: Hash.new(0),
      verification_ok: !@apply
    }

    target_relation(snap[:upper_id]).find_each(batch_size: 250) do |user|
      result[:inspected] += 1
      if @apply
        process_user!(user, result)
      elsif campaign_granted?(user)
        result[:already_granted] += 1
      else
        result[:would_grant] += 1
      end
    end

    verify_result!(result, snap) if @apply
    result[:failure_classes] = result[:failure_classes].sort.to_h
    result
  end

  private

  def target_relation(upper_id)
    User.where('id <= ? AND created_at <= ?', upper_id, @cutoff)
  end

  def verify_snapshot!(snap)
    return if snap[:upper_id] == @upper_id && snap[:expected_count] == @expected_count

    raise SnapshotChanged,
          "snapshot changed (expected count=#{@expected_count}, upper_id=#{@upper_id}; " \
          "current count=#{snap[:expected_count]}, upper_id=#{snap[:upper_id]})"
  end

  def process_user!(user, result)
    outcome = AccountRecord.transaction(requires_new: true) do
      locked_user = User.lock.find(user.id)
      if campaign_granted?(locked_user)
        :already_granted
      else
        locked_user.add_credits!(BONUS_AMOUNT)
        AccountActivity.log(
          locked_user,
          ACTIVITY_ACTION,
          nil,
          {
            amount: BONUS_AMOUNT,
            reason: 'existing_user_bonus',
            campaign: @campaign,
            cutoff: @cutoff.iso8601(6),
            operator: self.class.name
          }
        )
        :granted
      end
    end
    result[outcome] += 1
  rescue StandardError => e
    result[:failures] += 1
    result[:failure_classes][e.class.name] += 1
  end

  def campaign_granted?(user)
    campaign_entries(user).any?
  end

  def campaign_entries(user)
    user.account_activities.where(action: ACTIVITY_ACTION).select do |activity|
      metadata = activity.metadata
      metadata.is_a?(Hash) && metadata['campaign'] == @campaign &&
        metadata['amount'].to_i == BONUS_AMOUNT &&
        metadata['reason'] == 'existing_user_bonus'
    end
  end

  def verify_result!(result, snap)
    target_count_after = target_relation(snap[:upper_id]).count
    missing = 0
    duplicates = 0
    target_relation(snap[:upper_id]).find_each(batch_size: 250) do |user|
      count = campaign_entries(user).length
      missing += 1 if count.zero?
      duplicates += 1 if count > 1
    end
    result[:target_count_after] = target_count_after
    result[:audit_missing] = missing
    result[:audit_duplicates] = duplicates
    result[:verification_ok] = target_count_after == snap[:expected_count] && missing.zero? && duplicates.zero?
    result[:failure_classes]['SnapshotChanged'] += 1 if target_count_after != snap[:expected_count]
    result[:failure_classes]['AuditMissing'] += missing if missing.positive?
    result[:failure_classes]['AuditDuplicate'] += duplicates if duplicates.positive?
  end

  def parse_time(value)
    time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
    time.utc
  rescue ArgumentError, TypeError
    raise InvalidSnapshot, 'cutoff must be an ISO-8601 timestamp'
  end

  def validate_optional_integer(value, name, allow_zero: false)
    return nil if value.nil?

    integer = Integer(value)
    minimum = allow_zero ? 0 : 1
    raise InvalidSnapshot, "#{name} must be >= #{minimum}" if integer < minimum

    integer
  rescue ArgumentError, TypeError
    raise InvalidSnapshot, "#{name} must be an integer"
  end

  def validate_campaign!
    raise InvalidSnapshot, 'campaign must be a stable lowercase identifier' unless @campaign.match?(/\A[a-z0-9][a-z0-9_-]{2,99}\z/)
  end
end
