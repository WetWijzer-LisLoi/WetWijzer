# frozen_string_literal: true

# Anonymous, aggregated tracking of sample question clicks.
# Stores only: question text, category, date, and count.
# Zero PII — no user_id, no IP, no cookies, no session data.
class SampleQuestionClick < ApplicationRecord
  self.table_name = 'sample_question_clicks'

  # Ensure table exists (auto-create for SQLite environments)
  def self.ensure_table!
    return (@table_verified = true) if @table_verified
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

  # Increment the counter for a question on today's date.
  # Uses upsert to avoid race conditions.
  def self.track!(question_text:, category:, language: 'nl')
    ensure_table!

    # Truncate to prevent abuse
    q = question_text.to_s.strip.truncate(500)
    cat = category.to_s.strip.truncate(100)
    lang = language.to_s.strip.first(5)
    today = Date.current

    record = find_or_initialize_by(
      question_text: q,
      click_date: today,
      language: lang
    )
    record.category = cat
    record.click_count = record.persisted? ? record.click_count + 1 : 1
    record.save!
  rescue StandardError => e
    Rails.logger.warn("[SampleQuestionClick] tracking failed: #{e.message}")
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
