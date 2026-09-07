# frozen_string_literal: true

class ChatbotAnalytic < AnalyticsRecord
  MONTHLY_BUDGET_EUR = 150.0 # Total across 3 providers (€50 × 3)

  belongs_to :user, optional: true

  validates :billing_reservation_token, uniqueness: true, allow_nil: true

  # GDPR by design: NO question/answer text stored - metadata only

  scope :recent, -> { order(created_at: :desc) }
  scope :positive, -> { where(feedback_type: 'positive') }
  scope :negative, -> { where(feedback_type: 'negative') }
  # LEGACY binary feedback. Deliberately left alone: `rated` still means
  # "has a Good/Bad value" for the one caller below (stats). The star feature
  # uses star_rated, and the two are never mixed - a historical positive is
  # not a 10 (RAT-002/RAT-008).
  scope :rated, -> { where.not(feedback_type: nil) }
  scope :by_language, ->(lang) { where(language: lang) }
  scope :today, -> { where('created_at >= ?', Time.current.beginning_of_day) }
  scope :this_week, -> { where('created_at >= ?', Time.current.beginning_of_week) }
  scope :this_month, -> { where('created_at >= ?', Time.current.beginning_of_month) }
  scope :web_queries, -> { where(request_source: [nil, 'web']) }
  scope :partner_queries, -> { where(request_source: 'partner') }

  # --- 10-star ratings (RAT-002) --------------------------------------------
  #
  # rating_ui_version is stamped ONLY when a rating token was successfully
  # issued into the response, so rating_eligible is the honest denominator for
  # the response rate: rows that never offered a control cannot drag it down.
  #
  # WARNING for whoever maintains this next: `web_queries` here is NOT the
  # HMAC/service exclusion, and must never be presented as one.
  # Api::ChatbotAnalytics#log_analytic writes the literal request_source: 'web'
  # for EVERY ask, signed service requests included, so a request_source filter
  # can never exclude anything. It is kept only as a cheap guard against a
  # future writer that does set 'partner'. The real exclusion is @service_bypass
  # at token-issuance time, enforced again in the rating endpoint (RAT-004);
  # rows that never receive a token never get rating_ui_version, which is what
  # actually keeps service traffic out of this scope.
  scope :rating_eligible, lambda {
    web_queries.where(rating_ui_version: ChatbotRating::Configuration::UI_VERSION, has_error: false)
  }
  scope :star_rated, -> { rating_eligible.where.not(rating_score: nil) }

  # Shared with the migration so the fresh-SQLite fallback and the migrated
  # schema name the same constraint.
  RATING_SCORE_CONSTRAINT = 'chk_chatbot_analytics_rating_score_range'

  validates :rating_score,
            numericality: { only_integer: true,
                            greater_than_or_equal_to: ChatbotRating::Configuration::MINIMUM_SCORE,
                            less_than_or_equal_to: ChatbotRating::Configuration::MAXIMUM_SCORE },
            allow_nil: true
  validate :rating_reason_codes_must_be_allowlisted

  # Reason codes are stored as a canonical JSON array of strings. JSON, never
  # YAML or Ruby marshalling: this column is written from a request path, and
  # a deserializer that can instantiate objects is a remote-code-execution
  # surface. A malformed value reads as [] rather than raising, so one bad row
  # cannot break an admin page.
  def rating_reason_codes
    raw = rating_reason_codes_json
    return [] if raw.blank?

    parsed = JSON.parse(raw)
    parsed.is_a?(Array) ? parsed.grep(String) : []
  rescue JSON::ParserError
    []
  end

  def rating_reason_codes=(codes)
    list = Array(codes).grep(String)
    self.rating_reason_codes_json = list.empty? ? nil : JSON.generate(list)
  end

  def star_rated?
    rating_score.present?
  end

  def rating_reason_codes_must_be_allowlisted
    raw = rating_reason_codes_json
    return if raw.blank?

    parsed = parsed_reason_codes(raw)
    if parsed == :unparseable
      errors.add(:rating_reason_codes_json, 'is not valid JSON')
      return
    end

    return if ChatbotRating::Configuration.valid_reason_codes?(parsed)

    errors.add(:rating_reason_codes_json, 'must be up to three unique allowlisted reason codes')
  end
  private :rating_reason_codes_must_be_allowlisted

  # A sentinel rather than nil, because JSON.parse('null') legitimately
  # returns nil and the two cases deserve different messages.
  def parsed_reason_codes(raw)
    JSON.parse(raw)
  rescue JSON::ParserError
    :unparseable
  end
  private :parsed_reason_codes

  # FBL-052: canonical conversion for the integer micro-euro estimate.
  # Half-up rounding at the sixth decimal; nil stays nil so an unknown cost
  # never masquerades as zero.
  MICROEUR_PER_EUR = 1_000_000

  def self.to_microeur(eur)
    return nil if eur.nil?

    (eur.to_d * MICROEUR_PER_EUR).round.to_i
  end

  # Extracted from the create_table block above purely for readability; these
  # columns are part of the SAME fresh-table definition and are never applied
  # to an existing table (no ensure_rating_columns! - see FBL-051).
  def self.add_metadata_and_rating_columns(table)
    # Pre-existing gap closed here (RAT-002): both live in the structure
    # files, but domain was only ever bolted on by ensure_cost_columns! and
    # free_used reached a fresh SQLite table by no path at all.
    table.string :domain, limit: 60
    table.integer :free_used, default: 0
    # RAT-002 ratings. Present here so a genuinely FRESH SQLite database is
    # complete; there is deliberately no ensure_rating_columns! - altering an
    # existing table at request time is what the FBL-051 drain removed, and
    # PostgreSQL is migration-managed with no DDL privilege.
    table.integer :rating_score
    table.text :rating_reason_codes_json
    table.datetime :rated_at
    table.string :rating_ui_version, limit: 24
    # Effective generation snapshot: what the provider request ACTUALLY was.
    table.string :provider_used, limit: 24
    table.string :provider_model_used, limit: 160
    table.string :reasoning_effort_requested, limit: 12
    table.string :reasoning_effort_used, limit: 12
    table.string :provider_reasoning_value, limit: 16
    table.string :reasoning_mode, limit: 24
    table.integer :reasoning_token_budget
    table.integer :reasoning_tokens
    table.string :profile_used, limit: 40
    table.boolean :concise_mode
    table.float :temperature_used
    table.integer :output_token_limit
    table.boolean :follow_up, default: false
    table.string :prompt_version, limit: 40
    table.string :retrieval_version, limit: 40
    table.integer :generation_trace_version
    table.string :generation_config_fingerprint, limit: 64
    # Provider generations for one answer: greater than 1 when the citation
    # guard rejected and regenerated.
    table.integer :provider_calls
    # What the guard decided, and how many generations IT caused - which is not
    # the same as provider_calls, since a quote-repair pass also increments
    # that.
    table.string :citation_guard_outcome, limit: 32
    table.integer :citation_guard_retries
  end
  private_class_method :add_metadata_and_rating_columns

  def self.ensure_table_exists
    return if @table_verified
    # FBL-051 drain: never DDL at request time on PostgreSQL (migration-
    # managed schema, app role cannot DDL). SQLite path unchanged.
    return (@table_verified = true) if connection.adapter_name.match?(/postgresql/i)
    return (@table_verified = true) if connection.table_exists?(:chatbot_analytics)

    connection.create_table :chatbot_analytics do |t|
      # question column intentionally omitted - GDPR by design
      t.string :language, limit: 10
      t.string :source                   # 'legislation', 'jurisprudence', 'parliamentary', 'custom'
      t.string :sources_list             # comma-separated list when multiple selected
      t.string :model_used               # 'gpt-5-mini', 'gpt-5', etc.
      t.float :response_time             # seconds
      t.integer :sources_count, default: 0
      t.string :feedback_type            # 'positive', 'negative', or nil (not yet rated)
      t.references :user, foreign_key: false, null: true
      t.string :ip_hash, limit: 64       # SHA-256 of IP + salt for privacy
      t.string :conversation_token       # link to ChatbotConversation
      t.boolean :has_error, default: false
      # Cost tracking columns (added May 2026)
      t.integer :input_tokens, default: 0
      t.integer :output_tokens, default: 0
      t.float :estimated_cost_eur # estimated cost in EUR for this query
      t.integer :estimated_cost_microeur # FBL-052: integer micro-euro twin; float drops later
      t.string :intelligence_level, limit: 20 # 'smart', 'genius', 'mastermind', 'omniscient'
      t.integer :credits_deducted, default: 0 # credits deducted for this query
      t.string :billing_reservation_token    # durable accounts-ledger idempotency key
      t.string :request_source, limit: 20, default: 'web' # 'web' or 'partner'
      add_metadata_and_rating_columns(t)
      t.timestamps
    end
    # NOTE: t.references already creates index_chatbot_analytics_on_user_id
    connection.add_index :chatbot_analytics, :created_at unless connection.index_exists?(:chatbot_analytics, :created_at)
    connection.add_index :chatbot_analytics, :feedback_type unless connection.index_exists?(:chatbot_analytics, :feedback_type)
    connection.add_index :chatbot_analytics, :language unless connection.index_exists?(:chatbot_analytics, :language)
    connection.add_index :chatbot_analytics, :source unless connection.index_exists?(:chatbot_analytics, :source)
    unless connection.index_exists?(:chatbot_analytics, :billing_reservation_token, unique: true)
      connection.add_index :chatbot_analytics,
                           :billing_reservation_token,
                           unique: true,
                           name: 'idx_chatbot_analytics_billing_token'
    end
    unless connection.index_exists?(:chatbot_analytics, %i[rating_ui_version created_at])
      connection.add_index :chatbot_analytics, %i[rating_ui_version created_at],
                           name: 'idx_chatbot_analytics_rating_eligible'
    end
    unless connection.index_exists?(:chatbot_analytics, %i[generation_config_fingerprint created_at])
      connection.add_index :chatbot_analytics, %i[generation_config_fingerprint created_at],
                           name: 'idx_chatbot_analytics_config_fp'
    end
    # Same guarantee as the migration: a raw write path cannot store a score
    # the UI never offers.
    unless connection.check_constraints(:chatbot_analytics).any? { |c| c.name == RATING_SCORE_CONSTRAINT }
      connection.add_check_constraint :chatbot_analytics,
                                      'rating_score IS NULL OR (rating_score >= 1 AND rating_score <= 10)',
                                      name: RATING_SCORE_CONSTRAINT
    end
    @table_verified = true
  rescue ActiveRecord::StatementInvalid => e
    raise unless e.message.include?('already exists')

    @table_verified = true
  end

  # Auto-add cost tracking columns to existing tables
  # Deploy-order guard for the retry counter.
  #
  # The deploy hook runs db:migrate:analytics as the application role, which
  # does not own the table - so an analytics migration has to be applied by
  # hand as the owner role, and code that writes this column can reach
  # production before the column does. Passing an
  # unknown attribute raises inside create, and the caller rescues everything
  # to keep analytics from breaking an answer - so the whole row would be
  # dropped silently, not just the counter. column_names is cached per class,
  # so this costs nothing per request.
  def self.provider_calls_supported?
    column_names.include?('provider_calls')
  rescue StandardError
    false
  end

  def self.ensure_cost_columns!
    return if @cost_columns_verified
    # FBL-051 drain: never DDL at request time on PostgreSQL (migration-
    # managed schema, app role cannot DDL). SQLite path unchanged.
    return (@cost_columns_verified = true) if connection.adapter_name.match?(/postgresql/i)

    conn = connection
    # Cost & token columns
    %w[input_tokens output_tokens estimated_cost_eur].each do |col|
      next if conn.column_exists?(:chatbot_analytics, col)

      case col
      when 'input_tokens', 'output_tokens'
        conn.add_column :chatbot_analytics, col, :integer, default: 0
      when 'estimated_cost_eur'
        conn.add_column :chatbot_analytics, col, :float
      end
    end
    # Intelligence slider columns (May 2026)
    conn.add_column(:chatbot_analytics, :intelligence_level, :string, limit: 20) unless conn.column_exists?(:chatbot_analytics, :intelligence_level)
    conn.add_column(:chatbot_analytics, :credits_deducted, :integer, default: 0) unless conn.column_exists?(:chatbot_analytics, :credits_deducted)
    # Request source: 'web' or 'partner' (May 2026)
    conn.add_column(:chatbot_analytics, :request_source, :string, limit: 20, default: 'web') unless conn.column_exists?(:chatbot_analytics, :request_source)
    # Domain tracking (June 2026) - which brand domain the query came from
    conn.add_column(:chatbot_analytics, :domain, :string, limit: 60) unless conn.column_exists?(:chatbot_analytics, :domain)
    # FBL-052: integer micro-euro cost estimate (dual-written; see migration
    # 20260818090000 - the float is retired only after backfill + reconcile).
    unless conn.column_exists?(:chatbot_analytics, :estimated_cost_microeur)
      conn.add_column(:chatbot_analytics, :estimated_cost_microeur, :integer)
      reset_column_information
    end
    @cost_columns_verified = true
  rescue StandardError => e
    Rails.logger.warn("ChatbotAnalytic cost columns migration skipped: #{e.message}")
    @cost_columns_verified = true
  end

  # Analytics is an idempotent projection, never the billing authority. The
  # amount/status come exclusively from a settled accounts-ledger reservation.
  # If the original zero-credit telemetry write was unavailable, create a
  # minimal metadata-free row so revenue remains reconstructible.
  def self.project_settled_billing_reservation!(reservation, analytic: nil)
    unless reservation&.credit? && reservation.settled?
      raise ArgumentError, 'only settled credit reservations can be projected'
    end

    token = reservation.reservation_token.to_s
    raise ArgumentError, 'billing reservation token is required' if token.blank?

    record = find_by(billing_reservation_token: token)
    record ||= analytic if analytic&.persisted?
    record ||= new
    record.billing_reservation_token = token
    record.credits_deducted = reservation.amount
    record.model_used ||= reservation.model
    record.intelligence_level ||= reservation.intelligence_level
    record.request_source ||= 'web'
    record.has_error = false if record.has_error.nil?
    record.created_at ||= reservation.settled_at || reservation.created_at
    record.save!
    record
  rescue ActiveRecord::RecordNotUnique
    where(billing_reservation_token: token).update_all(
      credits_deducted: reservation.amount,
      updated_at: Time.current
    )
    find_by!(billing_reservation_token: token)
  rescue ActiveRecord::RecordInvalid => e
    raise unless e.record.errors.added?(:billing_reservation_token, :taken)

    where(billing_reservation_token: token).update_all(
      credits_deducted: reservation.amount,
      updated_at: Time.current
    )
    find_by!(billing_reservation_token: token)
  end

  # Aggregate stats for dashboard
  def self.stats(period: :all_time, request_source: nil)
    ensure_cost_columns!
    scope = case period
            when :today then today
            when :week then this_week
            when :month then this_month
            else all
            end
    scope = scope.partner_queries if request_source == :partner
    scope = scope.web_queries if request_source == :web

    total = scope.count
    rated_count = scope.rated.count
    positive_count = scope.positive.count
    negative_count = scope.negative.count

    {
      total_queries: total,
      rated_count: rated_count,
      positive_count: positive_count,
      negative_count: negative_count,
      satisfaction_rate: rated_count.positive? ? (positive_count.to_f / rated_count * 100).round(1) : nil,
      by_source: scope.group(:source).count,
      # The breakdown of `custom` rows, from the SAME scope as by_source above.
      # The dashboard used to run this query itself with 7.days.ago and
      # 30.days.ago while by_source used beginning_of_week and
      # beginning_of_month - two different populations in one panel, so the
      # combinations could out-count the total they were expanding.
      custom_source_combinations: scope.where(source: 'custom')
                                       .where.not(sources_list: [nil, ''])
                                       .group(:sources_list).count,
      by_language: scope.group(:language).count,
      by_model: scope.group(:model_used).count,
      by_intelligence: scope.group(:intelligence_level).count,
      avg_response_time: scope.where.not(response_time: nil).average(:response_time)&.round(2),
      error_rate: total.positive? ? (scope.where(has_error: true).count.to_f / total * 100).round(1) : 0,
      by_domain: scope.where.not(domain: [nil, '']).group(:domain).count
    }
  end

  CREDIT_VALUE_EUR_FALLBACK = 0.14 # Fallback if no purchase data exists

  # Exact per-credit value from actual purchase data + Pro subscriptions.
  # No privacy concern - aggregates only, no user-level data.
  def self.computed_credit_value_eur
    # Credit packs: exact revenue per credit from actual purchases
    pack_revenue_cents = CreditPurchase.completed.sum(:amount_cents)
    pack_credits = CreditPurchase.completed.sum(:credits_granted)

    # Pro subscriptions: €2.99/month → PRO_MONTHLY_CREDITS free credits/month (40 since 2026-08-18)
    pro_count = Subscription.where(tier: 'pro', status: 'active').count
    pro_revenue_cents = pro_count * 299 # monthly revenue in cents
    pro_credits = pro_count * Subscription::PRO_MONTHLY_CREDITS # monthly credits granted

    total_revenue_cents = pack_revenue_cents + pro_revenue_cents
    total_credits = pack_credits + pro_credits

    return CREDIT_VALUE_EUR_FALLBACK if total_credits.zero?

    (total_revenue_cents / 100.0 / total_credits).round(4)
  rescue StandardError => e
    Rails.logger.warn("[ChatbotAnalytic] Operation failed: #{e.message}")
    CREDIT_VALUE_EUR_FALLBACK
  end

  # Breakdown for admin dashboard: separate pack vs Pro rates
  def self.credit_value_breakdown
    pack_revenue_cents = CreditPurchase.completed.sum(:amount_cents)
    pack_credits = CreditPurchase.completed.sum(:credits_granted)
    pack_rate = pack_credits.positive? ? (pack_revenue_cents / 100.0 / pack_credits).round(4) : 0

    pro_count = Subscription.where(tier: 'pro', status: 'active').count
    pro_rate = (2.99 / Subscription::PRO_MONTHLY_CREDITS.to_f).round(4) # per-credit rate from Pro subscription

    blended = computed_credit_value_eur

    {
      purchased: { rate: pack_rate, credits: pack_credits, revenue_eur: (pack_revenue_cents / 100.0).round(2) },
      pro: { rate: pro_rate, count: pro_count, credits_per_month: pro_count * Subscription::PRO_MONTHLY_CREDITS },
      blended_rate: blended
    }
  rescue StandardError => e
    Rails.logger.warn("[ChatbotAnalytic] Operation failed: #{e.message}")
    { purchased: { rate: 0, credits: 0, revenue_eur: 0 }, pro: { rate: (2.99 / Subscription::PRO_MONTHLY_CREDITS.to_f).round(4), count: 0, credits_per_month: 0 }, blended_rate: CREDIT_VALUE_EUR_FALLBACK }
  end

  def self.cost_stats(period: :month, request_source: nil)
    ensure_cost_columns!

    scope = case period
            when :today then today
            when :week then this_week
            when :month then this_month
            else all
            end
    scope = scope.partner_queries if request_source == :partner
    scope = scope.web_queries if request_source == :web

    total_cost = scope.where.not(estimated_cost_eur: nil).sum(:estimated_cost_eur)
    total_input = scope.sum(:input_tokens)
    total_output = scope.sum(:output_tokens)
    total_credits_deducted = authoritative_credit_total(
      scope: scope,
      period: period,
      request_source: request_source
    )
    credit_rate = computed_credit_value_eur
    total_revenue = total_credits_deducted * credit_rate
    total_profit = total_revenue - total_cost

    authoritative_by_model = authoritative_credit_breakdown(
      scope: scope,
      analytics_field: :model_used,
      ledger_field: :model,
      from: period_start(period),
      request_source: request_source
    )
    by_model = scope.group(:model_used).select(
      'model_used',
      'COUNT(*) as query_count',
      'SUM(input_tokens) as total_input_tokens',
      'SUM(output_tokens) as total_output_tokens',
      'SUM(estimated_cost_eur) as total_cost'
    ).map do |row|
      model_credits = authoritative_by_model[row.model_used].to_i
      model_revenue = model_credits * credit_rate
      model_cost = row.total_cost&.round(4) || 0
      {
        model: row.model_used,
        queries: row.query_count,
        # Per-query cost, kept at six decimals because the cheapest model runs
        # at EUR 0.004 a question: at two decimals it reads as free, and
        # adjacent price tiers collapse into the same figure. The Cost column
        # beside it is PERIOD SPEND - the two are easy to confuse, and a total
        # that happens to look like a per-question price has already caused
        # exactly that confusion.
        cost_per_query_eur: row.query_count.to_i.positive? ? (model_cost / row.query_count).round(6) : nil,
        input_tokens: row.total_input_tokens.to_i,
        output_tokens: row.total_output_tokens.to_i,
        cost_eur: model_cost,
        credits_deducted: model_credits,
        revenue_eur: model_revenue.round(4),
        profit_eur: (model_revenue - model_cost).round(4),
        margin_pct: model_revenue.positive? ? ((model_revenue - model_cost) / model_revenue * 100).round(1) : 0
      }
    end

    # Per-provider cost breakdown (inferred from model_used → provider mapping)
    by_provider = cost_by_provider(scope)

    {
      period: period,
      billing_source: 'settled_reservations_plus_legacy_analytics',
      total_queries: scope.count,
      total_cost_eur: total_cost.round(4),
      total_revenue_eur: total_revenue.round(2),
      total_profit_eur: total_profit.round(2),
      profit_margin_pct: total_revenue.positive? ? ((total_profit / total_revenue) * 100).round(1) : 0,
      total_credits_deducted: total_credits_deducted,
      total_input_tokens: total_input,
      total_output_tokens: total_output,
      avg_cost_per_query: scope.any? ? (total_cost / scope.count).round(6) : 0,
      avg_revenue_per_query: scope.any? ? (total_revenue / scope.count).round(4) : 0,
      by_model: by_model.sort_by { |m| -(m[:profit_eur] || 0) },
      by_provider: by_provider,
      budget_remaining_eur: (MONTHLY_BUDGET_EUR - total_cost).round(2),
      budget_utilization_pct: (total_cost / MONTHLY_BUDGET_EUR * 100).round(1)
    }
  end

  # Browser billing introduced a durable accounts ledger. Correlated analytics
  # rows are projections and are deliberately excluded from the revenue sum;
  # their exact amount comes from settled reservations. Token-less rows retain
  # pre-ledger browser history and partner/included-quota reporting.
  def self.authoritative_credit_total(
    scope:,
    period: nil,
    request_source: nil,
    from: nil,
    to: nil,
    user: nil
  )
    legacy_total = scope.where(billing_reservation_token: nil).sum(:credits_deducted)
    return legacy_total if request_source == :partner

    from ||= period_start(period)
    legacy_total + BillingReservation.settled_credit_total(
      from: from,
      to: to,
      user: user,
      browser_only: true
    )
  end

  # Grouped credit reporting follows the same cutover rule: token-less
  # analytics are explicit historical fallback; every correlated browser amount
  # comes from the settled ledger. `ledger_field` avoids depending on projection
  # availability for fields that are already recorded with the reservation.
  def self.authoritative_credit_breakdown(
    scope:,
    analytics_field:,
    from: nil,
    to: nil,
    ledger_field: nil,
    request_source: nil
  )
    totals = scope.where(billing_reservation_token: nil)
                  .group(analytics_field)
                  .sum(:credits_deducted)
                  .transform_values(&:to_i)
    return totals if request_source == :partner

    ledger = BillingReservation.settled_credits.browser_chat
    ledger = ledger.where(settled_at: from...) if from
    ledger = ledger.where(settled_at: ...to) if to

    if ledger_field
      ledger.group(ledger_field).sum(:amount).each do |key, amount|
        totals[key] = totals.fetch(key, 0) + amount.to_i
      end
    else
      metadata_by_token = scope.where.not(billing_reservation_token: nil)
                               .pluck(:billing_reservation_token, analytics_field)
                               .to_h
      ledger.pluck(:reservation_token, :amount).each do |token, amount|
        key = metadata_by_token[token]
        totals[key] = totals.fetch(key, 0) + amount.to_i
      end
    end

    totals
  end

  def self.period_start(period)
    case period
    when :today then Time.current.beginning_of_day
    when :week then Time.current.beginning_of_week
    when :month then Time.current.beginning_of_month
    end
  end

  # Daily profit trend for charts (last 30 days)
  def self.daily_profit_trend(days: 30)
    ensure_cost_columns!
    cutoff = days.days.ago
    rows = where('created_at >= ?', cutoff)
           .group('date(created_at)')
           .select(
             'date(created_at) as day',
             'SUM(estimated_cost_eur) as cost',
             'COUNT(*) as queries'
           )
           .order('day')
    rows_by_day = rows.index_by { |row| row.day.to_s }
    legacy_credits = where('created_at >= ?', cutoff)
                     .where(billing_reservation_token: nil)
                     .group('date(created_at)')
                     .sum(:credits_deducted)
                     .transform_keys(&:to_s)
    ledger_credits = BillingReservation.settled_credits.browser_chat
                                              .where(settled_at: cutoff...)
                                              .group('date(settled_at)')
                                              .sum(:amount)
                                              .transform_keys(&:to_s)
    credit_days = legacy_credits.merge(ledger_credits) do |_day, legacy, ledger|
      legacy.to_i + ledger.to_i
    end

    (rows_by_day.keys | credit_days.keys).sort.map do |day|
      row = rows_by_day[day]
      revenue = credit_days.fetch(day, 0).to_i * computed_credit_value_eur
      cost = row&.cost || 0
      {
        date: day,
        queries: row&.queries.to_i,
        cost_eur: cost.round(4),
        revenue_eur: revenue.round(4),
        profit_eur: (revenue - cost).round(4)
      }
    end
  end

  # Per-provider cost breakdown inferred from model → provider mapping
  # Returns: { openai: { cost: 1.23, queries: 45, budget: 50.0, pct: 2.5 }, ... }
  def self.cost_by_provider(scope = this_month)
    # Map model names → provider symbols
    provider_map = begin
      LegalChatbot::ModelsConfig::AVAILABLE_MODELS.each_with_object({}) do |(model, cfg), h|
        h[model] = cfg[:provider].to_s
      end
    rescue StandardError => e
      Rails.logger.warn("[ChatbotAnalytic] Operation failed: #{e.message}")
      {}
    end

    budgets = begin
      LegalChatbot::ModelsConfig::PROVIDER_MONTHLY_BUDGET_EUR
    rescue StandardError => e
      Rails.logger.warn("[ChatbotAnalytic] Operation failed: #{e.message}")
      { openai: 50.0, mistral: 50.0, bedrock: 50.0 }
    end

    # Labels for display
    provider_labels = {
      'openai' => { name: 'Azure OpenAI', flag: '🇪🇺', region: 'EU Data Zone' },
      'mistral' => { name: 'Mistral AI', flag: '🇪🇺', region: 'EU/EFTA regional endpoint' },
      'bedrock' => { name: 'AWS Bedrock', flag: '🇪🇺', region: 'EU geographic profile' }
    }

    # Query grouped by model, then aggregate to provider level
    model_rows = scope.group(:model_used).select(
      'model_used',
      'COUNT(*) as query_count',
      'COALESCE(SUM(estimated_cost_eur), 0) as total_cost'
    )

    result = {}
    model_rows.each do |row|
      provider = provider_map[row.model_used] || 'unknown'
      result[provider] ||= { cost: 0.0, queries: 0 }
      result[provider][:cost] += row.total_cost.to_f
      result[provider][:queries] += row.query_count.to_i
    end

    # Ensure all known providers appear even with 0 usage
    budgets.each do |provider_sym, budget|
      provider = provider_sym.to_s
      result[provider] ||= { cost: 0.0, queries: 0 }
      meta = provider_labels[provider] || { name: provider.titleize, flag: '🌐', region: 'Unknown' }
      result[provider].merge!(
        budget: budget,
        pct: budget.positive? ? (result[provider][:cost] / budget * 100).round(1) : 0,
        name: meta[:name],
        flag: meta[:flag],
        region: meta[:region]
      )
      result[provider][:cost] = result[provider][:cost].round(4)
    end

    # Sort: highest cost first
    result.sort_by { |_, v| -(v[:cost] || 0) }.to_h
  end

  # Real daily model usage from the database (replaces cache-based counters)
  def self.daily_model_usage_from_db
    ensure_cost_columns!

    caps = begin
      LegalChatbot::ModelsConfig::MODEL_DAILY_CAPS
    rescue StandardError => e
      Rails.logger.warn("[ChatbotAnalytic] Operation failed: #{e.message}")
      {}
    end
    models = begin
      LegalChatbot::ModelsConfig::AVAILABLE_MODELS
    rescue StandardError => e
      Rails.logger.warn("[ChatbotAnalytic] Operation failed: #{e.message}")
      {}
    end

    # Query today's usage grouped by model
    today_usage = today.group(:model_used).select(
      'model_used',
      'COUNT(*) as query_count',
      'COALESCE(SUM(input_tokens), 0) as total_input',
      'COALESCE(SUM(output_tokens), 0) as total_output',
      'COALESCE(SUM(estimated_cost_eur), 0) as total_cost'
    ).index_by(&:model_used)

    # Build result for all known models + any extras seen today
    result = {}

    # All known models from config
    models.each_key do |model|
      row = today_usage[model.to_s]
      result[model.to_s] = {
        count: row&.query_count.to_i,
        cap: caps[model],
        cost_estimate: row&.total_cost.to_f,
        input_tokens: row&.total_input.to_i,
        output_tokens: row&.total_output.to_i
      }
    end

    # Any models used today that aren't in config.
    #
    # A NULL model_used skips the whole entry rather than calling to_sym on
    # nil: this ran inside the admin dashboard, whose BaseController turns any
    # exception into a rendered error page, so one legacy row with no model
    # took down every panel on the page - the same shape as the nil source
    # that took it down in August.
    today_usage.each do |model_name, row|
      next if model_name.blank? || result.key?(model_name)

      result[model_name] = {
        count: row.query_count.to_i,
        cap: caps[model_name.to_sym],
        cost_estimate: row.total_cost.to_f,
        input_tokens: row.total_input.to_i,
        output_tokens: row.total_output.to_i
      }
    end

    # Sort: models with usage first, then alphabetically
    result.sort_by { |name, info| [-info[:count], name] }.to_h
  end
end
