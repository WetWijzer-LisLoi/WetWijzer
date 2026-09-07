# frozen_string_literal: true

# Versioned GDPR account export (FBL-031, Art. 20 data portability).
#
# Replaces the inline hash in AccountController#export_data, which silently
# exported an empty usage section (it asked ChatbotAnalytic for columns that
# never existed and rescued the error away) and crashed on credit purchases
# (:credits is not a column; :credits_granted is).
#
# Contract:
# - schema_version 2; version 1 was the legacy inline hash. Additive changes
#   only within a version; breaking changes bump it.
# - Every query is scoped to the given user; analytics/chatbot databases are
#   queried by user id with table-existence guards (separate connections).
# - Zero-knowledge conversations are exported as ciphertext WITH explicit
#   metadata; the server cannot decrypt them and this export never implies
#   otherwise. Key material (encrypted_master_key, key_derivation_salt) is
#   NEVER included: it is wrapped-key secret, not user content.
# - Legally retained financial records (issued invoices, provider payment
#   ledgers) are included read-only with a documented retention note; they
#   survive account erasure unlinked under statutory retention.
# - Memory is bounded with find_each batches; callers must log only THAT an
#   export occurred, never its contents.
class AccountExportService
  SCHEMA_VERSION = 2
  BATCH_SIZE = 500

  RETAINED_FINANCIAL_NOTE =
    'Issued invoices and provider payment records are retained for the ' \
    'statutory accounting period even after account deletion; they are ' \
    'then unlinked from any account. Amounts are in euro cents.'

  ZERO_KNOWLEDGE_NOTE =
    'This conversation is end-to-end encrypted. The payload below is the ' \
    'ciphertext exactly as stored; the server holds no key that can ' \
    'decrypt it.'

  def self.call(user)
    new(user).call
  end

  def initialize(user)
    @user = user
  end

  def call
    {
      schema_version: SCHEMA_VERSION,
      exported_at: Time.current.iso8601,
      profile: profile,
      subscription: subscription,
      credit_purchases: credit_purchases,
      payments: payments,
      invoices: invoices,
      retained_financial_records_note: RETAINED_FINANCIAL_NOTE,
      saved_answers: saved_answers,
      bookmarks: bookmarks,
      activity_log: activity_log,
      usage: usage,
      usage_logs: usage_logs,
      chatbot_reports: chatbot_reports,
      conversations: conversations
    }
  end

  private

  attr_reader :user

  def profile
    {
      email: user.email,
      name: user.name,
      locale: user.locale,
      preferred_language: user.try(:preferred_language),
      preferred_theme: user.try(:preferred_theme),
      invoice_locale: user.try(:invoice_locale),
      created_at: user.created_at,
      confirmed_at: user.confirmed_at,
      # ABA-007: canonical brand codes or null. Historical absence serializes
      # as null - never a default brand, never an invented placeholder code.
      registration_brand: user.try(:registration_brand),
      last_sign_in_brand: user.try(:last_sign_in_brand),
      credits: user.credits,
      ui_preferences: user.respond_to?(:ui_prefs) ? user.ui_prefs : {},
      conversation_storage_consent: user.try(:conversation_storage_consent),
      conversation_storage_consented_at: user.try(:conversation_storage_consented_at),
      two_factor_enabled: user.try(:otp_enabled),
      deletion_requested_at: user.try(:deletion_requested_at),
      deletion_scheduled_for: user.try(:deletion_scheduled_for)
    }
  end

  def subscription
    safe_slice(user.subscription,
               %i[tier status monthly_price_cents current_period_start
                  current_period_end trial_ends_at canceled_at
                  cancellation_reason payment_method customer_type
                  company_name vat_number billing_address_line1
                  billing_address_line2 billing_city billing_postal_code
                  billing_country created_at])
  end

  def credit_purchases
    collect(user.credit_purchases) do |purchase|
      safe_slice(purchase, %i[package credits_granted amount_cents currency status payment_method created_at])
    end
  end

  def payments
    collect(MolliePayment.where(user_id: user.id)) do |payment|
      safe_slice(payment, %i[payment_type status amount_cents currency paid_at refunded_amount_cents refunded_at credits_granted service_period_start service_period_end created_at])
    end
  end

  def invoices
    collect(PlatformInvoice.for_user(user)) do |invoice|
      safe_slice(invoice, %i[invoice_number invoice_type subtotal_cents vat_cents total_cents currency customer_name customer_email customer_address customer_country invoice_locale status sent_at created_at])
    end
  end

  def saved_answers
    collect(user.saved_answers) do |answer|
      safe_slice(answer, %i[title question answer category sources language created_at])
    end
  end

  def bookmarks
    return [] unless user.respond_to?(:bookmarks)

    collect(user.bookmarks) { |bookmark| safe_slice(bookmark, %i[created_at]).merge(reference: bookmark.try(:numac) || bookmark.try(:reference)) }
  rescue ActiveRecord::StatementInvalid
    []
  end

  def activity_log
    collect(user.account_activities) do |activity|
      # site_brand: ABA-007. An explicit slice field beside the existing ones,
      # never the metadata hash. A scrubbed or pre-rollout event simply
      # carries null - additive under the schema-version-2 contract.
      safe_slice(activity, %i[action ip_address user_agent created_at site_brand])
    end
  end

  # Article 20 covers what this account's answers actually recorded, which is
  # more than the eight fields this used to slice. A rating the user gave is
  # THEIR data, and the configuration it describes is what makes it meaningful:
  # a 3 out of 10 says nothing without the model and settings that produced the
  # answer.
  #
  # Content is still excluded here and always will be. The row itself has never
  # held a question or an answer, and the security fields that would let two
  # records be correlated - ip_hash, conversation_token, the billing
  # reservation token, the signed rating token - are deliberately absent. The
  # rating token is not even a column; it is derived and never stored.
  USAGE_FIELDS = %i[
    created_at language model_used intelligence_level credits_deducted request_source domain
    response_time input_tokens output_tokens estimated_cost_eur has_error feedback_type
    rating_score rated_at rating_ui_version
    provider_used provider_model_used reasoning_effort_requested reasoning_effort_used
    provider_reasoning_value reasoning_mode reasoning_token_budget reasoning_tokens
    profile_used concise_mode temperature_used output_token_limit follow_up
    prompt_version retrieval_version generation_trace_version generation_config_fingerprint
    provider_calls citation_guard_outcome citation_guard_retries sources_count
  ].freeze

  # Analytics columns that are NOT in the list above, each for a stated reason.
  # A column in neither set is an oversight, and the export test fails on it -
  # which is how citation_guard_outcome, citation_guard_retries and
  # sources_count were found missing after they were added to the table.
  #
  #   id, user_id, updated_at    internal keys and bookkeeping
  #   ip_hash, conversation_token, billing_reservation_token
  #                              correlation handles - the security fields whose
  #                              absence is what keeps this table content-free
  #   source, sources_list, rating_reason_codes_json
  #                              exported under friendlier names and shapes
  #                              (source, sources, rating_reasons)
  #   estimated_cost_microeur    the integer twin of estimated_cost_eur, same
  #                              value in another unit
  #   free_used                  vestigial: the schema defines it, nothing in
  #                              the application has ever written it
  EXCLUDED_USAGE_COLUMNS = %w[
    id user_id updated_at ip_hash conversation_token billing_reservation_token
    source sources_list rating_reason_codes_json estimated_cost_microeur free_used
  ].freeze

  def usage
    return [] unless analytics_table?(ChatbotAnalytic)

    collect(ChatbotAnalytic.where(user_id: user.id)) do |row|
      # safe_slice intersects with the row's real attributes, so a database
      # that predates one of these columns exports the rest rather than failing.
      safe_slice(row, USAGE_FIELDS)
        .merge(source: ChatbotSourceCategories.exported_source(row.try(:source)),
               rating_reasons: exported_reason_codes(row),
               # Split first: the column stores one comma-joined string, and a
               # legacy row can hold values the allowlist rejects.
               sources: ChatbotSourceCategories.storage_value(row.try(:sources_list).to_s.split(',')))
    end
  end

  # An array, not the raw JSON column. The storage shape is an implementation
  # detail, and a legacy row can hold something that is not a list of codes at
  # all - which must not become a malformed string in someone's export.
  def exported_reason_codes(row)
    raw = row.try(:rating_reason_codes_json)
    return nil if raw.blank?

    parsed = JSON.parse(raw)
    return nil unless parsed.is_a?(Array)

    codes = parsed.select { |code| code.is_a?(String) && ChatbotRating::Configuration.reason_codes.include?(code) }
    codes.presence
  rescue JSON::ParserError
    nil
  end

  def usage_logs
    return [] unless analytics_table?(UsageLog)

    collect(UsageLog.where(user_id: user.id)) do |row|
      safe_slice(row, %i[app question answer credits_used created_at])
    end
  end

  def chatbot_reports
    return [] unless analytics_table?(ChatbotReport)

    collect(ChatbotReport.where(user_id: user.id)) do |report|
      safe_slice(report, %i[question answer language source intelligence status created_at])
    end
  end

  def conversations
    return [] unless ChatbotConversation.table_exists?

    # Raw scope on purpose: for_user hides expired rows, and an export must
    # include everything that still exists. user_id is a string column.
    collect(ChatbotConversation.where(user_id: user.id.to_s)) do |conversation|
      base = {
        token: conversation.token,
        language: conversation.language,
        message_count: conversation.message_count,
        pinned: conversation.try(:pinned),
        archived: conversation.try(:archived),
        created_at: conversation.created_at,
        updated_at: conversation.updated_at
      }
      if conversation.zero_knowledge?
        base.merge(
          zero_knowledge: true,
          zk_key_generation: conversation.try(:zk_key_generation),
          note: ZERO_KNOWLEDGE_NOTE,
          # Raw columns: messages_array deliberately returns [] for ZK rows,
          # which would silently export empty conversations.
          encrypted_title: conversation[:title],
          encrypted_messages: conversation[:messages]
        )
      else
        base.merge(
          zero_knowledge: false,
          title: conversation.title,
          messages: conversation.messages_array
        )
      end
    end
  rescue ActiveRecord::StatementInvalid
    []
  end

  def collect(scope, &)
    rows = []
    scope.find_each(batch_size: BATCH_SIZE) { |record| rows << yield(record) }
    rows
  end

  # slice raises on a column the local database predates; the export contract
  # is additive, so absent columns are simply absent from the payload.
  def safe_slice(record, keys)
    return nil if record.nil?

    record.attributes.slice(*keys.map(&:to_s)).symbolize_keys
  end

  def analytics_table?(model)
    model.table_exists?
  rescue StandardError
    false
  end
end
