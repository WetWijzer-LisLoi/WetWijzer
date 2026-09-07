# frozen_string_literal: true

# Anonymous, aggregated tracking of sample question clicks.
# Stores only: question text, category, date, and count.
# Zero PII - no user_id, no IP, no cookies, no session data.
# W7 (FBL-070): moved out of the legal corpus to the analytics database so
# the corpus can go read-only; production data copy is a rehearsal step in
# docs/ops/postgres-staging-rehearsal-runbook.md.
class SampleQuestionClick < AnalyticsRecord
  self.table_name = 'sample_question_clicks'

  # Ensure table exists (auto-create for SQLite environments)
  def self.ensure_table!
    return (@table_verified = true) if @table_verified
    # FBL-051 drain: never DDL at request time on PostgreSQL (migration-
    # managed schema, app role cannot DDL). SQLite path unchanged.
    return (@table_verified = true) if connection.adapter_name.match?(/postgresql/i)
    return (@table_verified = true) if connection.table_exists?(:sample_question_clicks)

    connection.create_table :sample_question_clicks do |t|
      t.string  :question_text, null: false, limit: 500
      t.string  :category,      null: false, limit: 100
      t.string  :language,      null: false, limit: 5, default: 'nl'
      t.date    :click_date,    null: false
      t.integer :click_count,   null: false, default: 1
      t.timestamps
    end

    # Composite unique index for upsert (one row per question per day)
    connection.add_index :sample_question_clicks,
                         %i[question_text click_date language],
                         unique: true,
                         name: 'idx_sq_clicks_question_date_lang'
    connection.add_index :sample_question_clicks, :click_date
    connection.add_index :sample_question_clicks, :category

    @table_verified = true
  end

  # FBL-043: hard vocabulary. The categories are the curated sample-pill
  # slugs from the chatbot UI; anything else is rejected, not stored.
  CATEGORIES = [
    'arbeidsrecht', 'huurrecht', 'familierecht', 'erfrecht', 'strafrecht',
    'fiscaal', 'vennootschapsrecht', 'consumentenrecht', 'vreemdelingenrecht',
    'sociale zekerheid', 'bestuursrecht', 'privacy', 'all', 'general', 'smart'
  ].freeze
  LANGUAGES = %w[nl fr de en].freeze
  MAX_QUESTION_CHARS = 500
  MAX_QUESTION_BYTES = 1_000

  class InvalidClick < ArgumentError; end

  # Increment the counter for a question on today's date.
  #
  # FBL-043: the increment is a single SQLite UPSERT against the unique
  # (question, date, language) index - atomic under concurrency, unlike the
  # old find-then-save which lost counts and could raise on the unique
  # index. Invalid input raises InvalidClick instead of being stored
  # truncated. Stored data stays aggregate-only: no IP, session or user id.
  def self.track!(question_text:, category:, language: 'nl')
    ensure_table!

    q = question_text.to_s.strip
    cat = category.to_s.strip
    lang = language.to_s.strip.presence || 'nl'

    raise InvalidClick, 'question_blank' if q.blank?
    raise InvalidClick, 'question_too_long' if q.length > MAX_QUESTION_CHARS || q.bytesize > MAX_QUESTION_BYTES
    raise InvalidClick, 'unknown_category' unless CATEGORIES.include?(cat)
    raise InvalidClick, 'unknown_language' unless LANGUAGES.include?(lang)

    now = Time.current
    upsert_all(
      [{ question_text: q, category: cat, language: lang,
         click_date: Date.current, click_count: 1,
         created_at: now, updated_at: now }],
      unique_by: 'idx_sq_clicks_question_date_lang',
      on_duplicate: Arel.sql(
        # The existing-row reference must be table-qualified: PostgreSQL
        # rejects a bare click_count in DO UPDATE SET as ambiguous with
        # `excluded`; SQLite accepts either spelling.
        'click_count = sample_question_clicks.click_count + 1, category = excluded.category, ' \
        'updated_at = excluded.updated_at'
      )
    )
  end

  # Summary: total clicks per question (all time)
  def self.top_questions(limit: 50)
    ensure_table!
    group(:question_text, :category)
      .select('question_text, category, SUM(click_count) as total_clicks')
      .order(Arel.sql('SUM(click_count) DESC'))
      .limit(limit)
  end

  # Daily breakdown for a specific question
  def self.daily_for(question_text, days: 30)
    ensure_table!
    where(question_text: question_text)
      .where('click_date >= ?', days.days.ago.to_date)
      .order(click_date: :desc)
  end
end
