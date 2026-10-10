# frozen_string_literal: true

# Durable running total of the estimated AI provider spend for one provider
# in one calendar month, in the micro-euro units of LegalChatbot::ModelsConfig
# (one unit is one millionth of a euro).
#
# The monthly provider ceiling used to keep this total only in Rails.cache.
# Production's cache is a FileStore that the weekly jurisprudence linkage job
# clears, so the "monthly" total started again from zero every week and after
# any other cache loss. A ceiling that forgets what was spent caps nothing.
#
# Every write is ONE upsert against the unique (provider, budget_month) index
# and returns the new total, so concurrent threads and Puma workers serialize
# in the database rather than behind a process-local lock. The row for a month
# is created by its first write; there is nothing to seed or roll over.
class AiProviderMonthlySpend < AnalyticsRecord
  self.table_name = 'ai_provider_monthly_spends'

  UNIQUE_INDEX = 'idx_ai_provider_monthly_spends_key'
  MONTH_PATTERN = /\A\d{4}(0[1-9]|1[0-2])\z/

  class << self
    # The month key used for a date: "YYYYMM".
    def budget_month_for(date = Date.current)
      date.strftime('%Y%m')
    end

    # Adds `amount` (negative for a refund) and returns the new total.
    # The total never goes below zero, including on a month's first write.
    def adjust!(provider:, budget_month:, amount:)
      delta = Integer(amount)
      summed = "#{spend_column} + #{delta}"
      write_returning_total!(
        provider, budget_month, [delta, 0].max,
        "CASE WHEN #{summed} < 0 THEN 0 ELSE #{summed} END"
      )
    end

    # Raises the total to at least `floor_units` and returns it. Never lowers
    # a total that is already higher. Used to mark a month as exhausted when
    # the exact spend could not be recorded.
    def saturate!(provider:, budget_month:, floor_units:)
      floor = Integer(floor_units)
      raise ArgumentError, 'floor_units must not be negative' if floor.negative?

      write_returning_total!(
        provider, budget_month, floor,
        "CASE WHEN #{spend_column} < #{floor} THEN #{floor} ELSE #{spend_column} END"
      )
    end

    # Current total, 0 when the month has no row yet.
    def units_for(provider:, budget_month:)
      where(provider: normalized_provider(provider), budget_month: normalized_month(budget_month))
        .pick(:spend_micro_eur).to_i
    end

    private

    # `new_total_sql` is built only from integers that went through Integer()
    # and from quoted identifiers, never from caller text.
    def write_returning_total!(provider, budget_month, insert_units, new_total_sql)
      now = Time.current
      result = upsert(
        {
          provider: normalized_provider(provider),
          budget_month: normalized_month(budget_month),
          spend_micro_eur: insert_units,
          created_at: now,
          updated_at: now
        },
        unique_by: UNIQUE_INDEX,
        # The existing-row reference must be table-qualified: PostgreSQL
        # rejects a bare column in DO UPDATE SET as ambiguous with `excluded`.
        on_duplicate: Arel.sql("spend_micro_eur = #{new_total_sql}, updated_at = excluded.updated_at"),
        returning: [:spend_micro_eur]
      )
      Integer(result.rows.fetch(0).fetch(0))
    end

    def spend_column
      "#{quoted_table_name}.#{connection.quote_column_name('spend_micro_eur')}"
    end

    def normalized_provider(provider)
      value = provider.to_s
      raise ArgumentError, 'provider must be present' if value.empty? || value.length > 24

      value
    end

    def normalized_month(budget_month)
      value = budget_month.to_s
      raise ArgumentError, "budget_month must be YYYYMM, got #{value.inspect}" unless value.match?(MONTH_PATTERN)

      value
    end
  end
end
