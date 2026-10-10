# frozen_string_literal: true

# WW-ABUSE-01 (ABUSE-08): the owner's fail-closed procedure for accounts a
# review found to be automated registrations (lib/tasks/abuse.rake). It
# suspends each for automated_registration through User#suspend_for_abuse!,
# which keeps it inactive and clears its session and every link token, with
# one abuse_suspended_by_admin activity written in the same transaction. It
# deletes nothing: the unconfirmed sweep erases the accounts on its schedule.
#
# The ids come from the operator at run time, never from source or a
# migration. Every account is checked under its row lock inside one
# transaction, and if any one fails a check nothing changes. Reports carry
# ids, codes and action counts only: never an email, address or token. A
# second run finds the accounts done and changes nothing.
class AuditedRegistrationSuspension
  REASON = 'automated_registration'
  ACTIVITY = 'abuse_suspended_by_admin'
  EXPECTED_ACTIONS = %w[registered deactivated_by_admin].freeze
  ACTOR = 'operator procedure WW-ABUSE-01 ABUSE-08'

  class Refused < StandardError; end

  Report = Struct.new(:id, :state, :problems, :actions, keyword_init: true) do
    def to_s
      detail = problems.empty? ? '' : " (#{problems.join(', ')})"
      "account #{id}: #{state}#{detail}; actions #{actions.map { |action, n| "#{action}=#{n}" }.join(' ')}"
    end
  end

  def initialize(ids)
    @ids = Array(ids).map { |id| Integer(id.to_s, 10) }.uniq.sort
    raise ArgumentError, 'no account ids given' if @ids.empty?
  end

  # One report per id: :ready, :done or :refused. Reads only.
  def check
    @ids.map { |id| report(id, User.find_by(id: id)) }
  end

  # All or nothing: suspends every :ready account, or raises Refused and
  # changes nothing. Returns the reports read back after the commit.
  def apply!
    AccountRecord.transaction do
      @ids.each do |id|
        user = User.lock.find_by(id: id)
        found = report(id, user)
        raise Refused, found.to_s if found.state == :refused
        next if found.state == :done

        user.suspend_for_abuse!(reason: REASON) do
          AccountActivity.log(user, ACTIVITY, nil, { admin: ACTOR, reason: REASON })
        end
      end
    end
    check.tap do |after|
      unfinished = after.reject { |found| found.state == :done }
      raise Refused, "not done after the run: #{unfinished.join('; ')}" if unfinished.any?
    end
  end

  private

  def report(id, user)
    return Report.new(id: id, state: :refused, problems: %w[missing], actions: {}) if user.nil?

    actions = AccountActivity.where(user_id: id).group(:action).count.sort.to_h
    problems = account_problems(user) + activity_problems(user, actions) + linked_record_problems(user)
    state = if problems.any? then :refused
            elsif user.abuse_suspended? then :done
            else :ready
            end
    Report.new(id: id, state: state, problems: problems, actions: actions)
  end

  def account_problems(user)
    problems = []
    problems << 'confirmed' if user.confirmed?
    problems << 'active' unless user.active == false
    problems << 'admin' if user.admin?
    problems << 'signed_in' if user.last_sign_in_at.present?
    problems << 'last_activity' if user.last_activity_at.present?
    problems << 'suspended_for_another_reason' if user.abuse_suspended? && user.abuse_suspension_reason != REASON
    problems
  end

  # Before the run: registration and the temporary deactivation only. After
  # it: those plus exactly one suspension activity.
  def activity_problems(user, actions)
    problems = []
    problems << 'unexpected_activity' if (actions.keys - EXPECTED_ACTIONS - [ACTIVITY]).any?
    expected = user.abuse_suspended? ? 1 : 0
    problems << 'suspension_audit_mismatch' unless actions.fetch(ACTIVITY, 0) == expected
    problems
  end

  def linked_record_problems(user)
    problems = []
    problems << 'chatbot_usage' if [ChatbotAnalytic, UsageLog, ChatbotReport, ChatbotFeedback].any? { |m| rows?(m, user) }
    problems << 'conversations' if rows?(ChatbotConversation, user)
    problems << 'purchases' if [CreditPurchase, MolliePayment, CryptoPayment, PlatformInvoice].any? { |m| rows?(m, user) }
    problems << 'paid_subscription' if user.subscription && user.subscription.tier != 'free'
    problems << 'saved_answers' if rows?(SavedAnswer, user)
    problems << 'bookmarks' if rows?(Bookmark, user)
    problems << 'pending_work' if [BillingReservation, AccountRequestLease].any? { |m| rows?(m, user) }
    problems << 'pending_financial_work' if pending_financial_work?(user)
    problems
  end

  # A table this database does not have holds no rows for the account; any
  # other read failure refuses.
  def rows?(model, user)
    return false unless model.table_exists?

    model.where(user_id: user.id).exists?
  end

  def pending_financial_work?(user)
    AccountErasureService.ensure_financial_work_settled!(user)
    false
  rescue AccountErasureService::PendingFinancialWork
    true
  end
end
