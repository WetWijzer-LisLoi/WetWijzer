# frozen_string_literal: true

# Aggregate star-rating analytics for the admin dashboard (RAT-006).
#
# A service rather than logic in the 1,200-line ERB, so the statistics can be
# tested directly - and because the interesting parts here are judgement
# calls, not arithmetic:
#
# * The denominator is answers that ACTUALLY OFFERED a control
#   (rating_ui_version = stars_v1), never every answer ever generated.
#   Historical rows predate the feature and would permanently depress the
#   response rate toward zero.
# * Nothing is ranked on a raw mean. Small groups win raw-mean contests by
#   luck, so ranking uses a shrunk average and groups below a floor are not
#   ranked at all.
# * Rows without a generation trace can still contribute to overall totals,
#   but never appear as a configuration: an unknown configuration is not a
#   configuration, and showing it as one would invite a false conclusion.
# * Comparisons here are OBSERVATIONAL. Users pick their own questions,
#   models and reasoning levels, so a difference between groups is an
#   association and the view says so.
class ChatbotRatingAnalytics
  # Below this a group is shown but never ranked or styled as a winner.
  MIN_RANKING_SAMPLE = 20
  # Below this a group is not shown individually at all: with a handful of
  # rows, a configuration row plus its metadata starts to describe individual
  # answers rather than a population.
  MIN_VISIBLE_SAMPLE = 5
  # Guard behaviour is a different question from rating quality, and it needs a
  # far larger sample before it can justify changing CITATION_GUARD_MAX_RETRIES.
  # Below this the panel reports the numbers and says plainly that they are not
  # enough to tune on.
  MIN_GUARD_SAMPLE = 50
  # Shrinkage prior. Twenty is deliberately the same as the ranking floor: a
  # group at the floor is pulled halfway to the period mean.
  PRIOR_WEIGHT = 20

  HIGH_RANGE = (8..10)
  MIDDLE_RANGE = (5..7)
  LOW_RANGE = (1..4)

  # Grouping is restricted to server-owned columns. A filter cannot name an
  # arbitrary column, so no admin input reaches SQL as an identifier.
  GROUPABLE = {
    model: :model_used,
    provider: :provider_used,
    reasoning: :reasoning_effort_used,
    profile: :profile_used,
    language: :language,
    source: :source,
    prompt_version: :prompt_version,
    retrieval_version: :retrieval_version
  }.freeze

  def initialize(period: :month, filters: {})
    @period = period
    @filters = (filters || {}).symbolize_keys
  end

  # --- populations ----------------------------------------------------------

  # Period semantics stay on created_at, matching every other card on this
  # dashboard: "answers from this period", not "ratings submitted this period".
  def eligible_scope
    scope = ChatbotAnalytic.rating_eligible
    scope = apply_period(scope)
    apply_filters(scope)
  end

  def rated_scope
    eligible_scope.where.not(rating_score: nil)
  end

  # One suppression rule for the whole service. MIN_VISIBLE_SAMPLE guarded the
  # configuration table from the start, but the overview, the untraced bucket
  # and the suppressed-group total had no floor at all: with one rated answer
  # in the period they printed its exact score, its distribution bucket and its
  # chosen reason codes.
  #
  # Zero rated answers is NOT suppression. "Nobody has rated anything" is a
  # measured fact about the period and reveals no one; it keeps its own empty
  # state, which the dashboard already renders as "No ratings yet".
  def statistics_suppressed?
    rated_scores.size.positive? && rated_scores.size < MIN_VISIBLE_SAMPLE
  end

  def overview
    eligible = eligible_scope.count
    scores = rated_scores

    return suppressed_overview if statistics_suppressed?

    {
      eligible: eligible,
      rated: scores.size,
      response_rate: percentage(scores.size, eligible),
      mean: mean(scores),
      median: median(scores),
      high_share: share_within(scores, HIGH_RANGE),
      middle_share: share_within(scores, MIDDLE_RANGE),
      low_share: share_within(scores, LOW_RANGE),
      distribution: distribution(scores),
      reasons: reason_counts(scores.size)
    }
  end

  # nil, never 0. A zero here would be read as a measured zero - no answers
  # scored 8-10, a mean of nothing - which is a different and false claim.
  #
  # The eligible denominator goes too. On an unfiltered dashboard it is only
  # traffic volume, but under a narrow filter "1 answer offered a control" plus
  # a suppression notice says that one answer exists AND was rated, which is
  # most of what suppression is meant to withhold.
  def suppressed_overview
    {
      eligible: nil,
      rated: nil,
      suppressed: true,
      minimum_sample: MIN_VISIBLE_SAMPLE,
      response_rate: nil,
      mean: nil,
      median: nil,
      high_share: nil,
      middle_share: nil,
      low_share: nil,
      distribution: [],
      reasons: []
    }
  end

  # --- configuration comparison --------------------------------------------

  # The exact-configuration table. Untraced rows are removed here and surfaced
  # separately by #unavailable_bucket.
  def configurations
    rows = traced_rows
    period_mean = mean(rows.map { |row| row[:score] }) || 0.0

    groups = rows.group_by { |row| row[:fingerprint] }.map do |fingerprint, group|
      build_group(fingerprint, group, period_mean)
    end

    visible, suppressed = groups.partition { |group| group[:n] >= MIN_VISIBLE_SAMPLE }
    {
      rows: rank(visible),
      suppressed: summarize_suppressed(suppressed),
      # The period mean is an aggregate like any other, and it is computed from
      # the TRACED rows only - so with one traced rating it published that
      # rating's exact score while every other number on the page was
      # suppressed. The floor is on the population it is actually built from,
      # which is not the same as the overall rated count.
      period_mean: traced_statistics_suppressed?(rows) || period_mean.zero? ? nil : period_mean.round(2),
      period_mean_suppressed: traced_statistics_suppressed?(rows)
    }
  end

  # Rated answers whose configuration was never captured. They count toward
  # overall and model-level totals, and are explicitly not rankable.
  # How often the provider ran more than once, over EVERY traced answer that
  # reached the guard - rated or not, delivered or refused.
  #
  # The retry column in the configuration table is computed from RATED rows,
  # because that is what that table is about. Using it to tune the citation
  # guard would be selection bias: people rate answers they have an opinion
  # about, and a regenerated answer is slower, which is exactly the kind of
  # thing that changes whether someone bothers to rate it.
  #
  # What this CANNOT tell you, and why the guard limit should not move on it
  # alone: provider_calls > 1 says a regeneration was ATTEMPTED. It does not
  # say whether the guard accepted the result, and it does not separate a
  # citation-repair pass from a guard rejection. Both increment the counter.
  # That is what guard_outcomes below supplies, and it is the half to tune on:
  # `recovery_by_attempt`, not this share.
  def regeneration
    return nil unless ChatbotAnalytic.provider_calls_supported?

    counts = traced_generation_scope.pluck(:provider_calls).compact
    return nil if counts.empty?

    regenerated = counts.count { |calls| calls.to_i > 1 }
    # The call-count half takes the same floor as the verdict half. A single
    # traced answer otherwise printed its exact provider-call count, which is
    # both an unreliable statistic and a description of one answer.
    suppressed = counts.size < MIN_VISIBLE_SAMPLE
    {
      answers: counts.size,
      regenerated: suppressed ? nil : regenerated,
      share: suppressed ? nil : (regenerated.to_f / counts.size).round(3),
      mean_calls: suppressed ? nil : (counts.sum.to_f / counts.size).round(2),
      max_calls: suppressed ? nil : counts.max,
      suppressed: suppressed,
      visible_minimum_sample: MIN_VISIBLE_SAMPLE,
      # Two different floors, deliberately. MIN_VISIBLE_SAMPLE is when a number
      # may be SHOWN; MIN_GUARD_SAMPLE is when it may be ACTED ON.
      sufficient: counts.size >= MIN_GUARD_SAMPLE,
      minimum_sample: MIN_GUARD_SAMPLE
    }.merge(guard_outcomes)
  end

  # What the guard DECIDED, which is the half provider_calls cannot supply.
  #
  # `analysis` means the generated analysis was delivered. Anything else means
  # it was withheld and the user got verified sources or a refusal instead - so
  # `delivered` here is the number that says whether retrying is working, and
  # `guard_retries` counts only the regenerations the GUARD asked for, never a
  # quote-repair pass.
  def guard_outcomes
    return { outcomes_recorded: 0 } unless guard_columns_supported?

    rows = traced_generation_scope
           .where.not(citation_guard_outcome: nil)
           .pluck(:citation_guard_outcome, :citation_guard_retries)
    return { outcomes_recorded: 0 } if rows.empty?

    return suppressed_guard_outcomes(rows.size) if rows.size < MIN_VISIBLE_SAMPLE

    outcomes = rows.map(&:first)
    retried = rows.select { |_outcome, retries| retries.to_i.positive? }
    {
      outcomes_recorded: rows.size,
      delivered: outcomes.count('analysis'),
      sources_fallback: outcomes.count('verified_sources_fallback'),
      refused: outcomes.count('refusal'),
      guard_retried: retried.size,
      # ANSWERS that recovered, not retries. An answer the guard sent back
      # twice and then delivered counts once here and contributes two
      # regenerations to mean_guard_retries - so this ratio must never be
      # described as a per-retry success rate.
      guard_retry_recovered: retried.count { |outcome, _retries| outcome == 'analysis' },
      mean_guard_retries: retried.empty? ? nil : (retried.sum { |_o, r| r.to_i }.to_f / retried.size).round(2),
      recovery_by_attempt: recovery_by_attempt(retried)
    }
  end

  # The combined ratio cannot move CITATION_GUARD_MAX_RETRIES on its own: it
  # answers "does retrying work", where the setting asks "is the LAST attempt
  # still worth a provider call". Those differ whenever recovery decays, which
  # is the case the constant was chosen on (2026-07-30: attempt one converted
  # most rejections, attempt two roughly half the remainder).
  #
  # Keyed on the retry count an answer FINISHED with, so each answer appears in
  # exactly one row: `retries: 2, answers: 6, recovered: 1` reads as "six
  # answers went to a second retry, one of them came back delivered".
  def recovery_by_attempt(retried_rows)
    retried_rows.group_by { |_outcome, retries| retries.to_i }
                .sort_by(&:first)
                .map do |retries, group|
      { retries: retries, answers: group.size,
        recovered: group.count { |outcome, _retries| outcome == 'analysis' } }
    end
  end

  # Same floor as every other statistic on this dashboard. The guard panel had
  # none, so a period holding a single recorded verdict printed that answer's
  # exact outcome and retry count.
  #
  # The sample SIZE survives, unlike the overview's: it is a count of the
  # system's own verdicts rather than of anyone's submitted rating, and it is
  # the number an operator needs to answer "is there enough to tune yet" -
  # which is the whole purpose of the panel. What it withholds is every derived
  # statistic computed from fewer than five answers.
  def suppressed_guard_outcomes(recorded)
    {
      outcomes_recorded: recorded,
      guard_suppressed: true,
      guard_minimum_sample: MIN_VISIBLE_SAMPLE,
      delivered: nil,
      sources_fallback: nil,
      refused: nil,
      guard_retried: nil,
      guard_retry_recovered: nil,
      mean_guard_retries: nil,
      recovery_by_attempt: []
    }
  end

  def guard_columns_supported?
    columns = ChatbotAnalytic.column_names
    columns.include?('citation_guard_outcome') && columns.include?('citation_guard_retries')
  rescue StandardError
    false
  end

  # Every answer that REACHED THE GUARD, traced and carrying a call count.
  # Deliberately NOT restricted to rated answers, and not to rating_eligible
  # either: an answer that never offered a control still exercised the guard.
  #
  # "Successful" was the wrong population and inverted the measurement. A guard
  # REFUSAL is persisted with has_error true - the request is an error from the
  # caller's side, and the controller refunds the credits - so filtering on
  # has_error dropped exactly the outcome this panel exists to count. What
  # survived was the answers the guard let through, which made the recovery
  # rate a ratio of successes to successes: one delivered analysis plus one
  # retried refusal reported 1 answer, 0 refused, 0 retried.
  #
  # A verified_sources_fallback lands on EITHER side of has_error, and the
  # difference is worth knowing when reading old numbers: the fallback branch
  # re-runs validate_unlinked_article_citations over the fallback text, so one
  # that cites nothing unsupported passes, stays billable, and was always
  # counted. Only the fallbacks that failed that re-check were dropped. Every
  # refusal was.
  #
  # The population is therefore "has a guard verdict, OR succeeded". The second
  # half keeps rows written before the outcome column existed. Errored rows
  # WITHOUT a verdict stay out: a provider timeout never reached the guard, and
  # its call count says nothing about retrying.
  def traced_generation_scope
    scope = apply_filters(apply_period(ChatbotAnalytic.all))
            .where.not(generation_trace_version: nil)
            .where.not(provider_calls: nil)
    scope.where(reached_guard_condition)
  end

  def reached_guard_condition
    table = ChatbotAnalytic.arel_table
    delivered = table[:has_error].eq(false).or(table[:has_error].eq(nil))
    return delivered unless guard_columns_supported?

    delivered.or(table[:citation_guard_outcome].not_eq(nil))
  end

  def unavailable_bucket
    scores = rated_scope.where(generation_trace_version: nil).pluck(:rating_score).compact
    return nil if scores.empty?
    # Same floor as everywhere else. This bucket is the easiest one to isolate:
    # untraced rows are rare, so a period often holds exactly one.
    if scores.size < MIN_VISIBLE_SAMPLE
      return { n: nil, suppressed: true, minimum_sample: MIN_VISIBLE_SAMPLE, mean: nil, median: nil, rankable: false }
    end

    { n: scores.size, mean: mean(scores), median: median(scores), rankable: false }
  end

  # One-dimension summaries. Never a combinatorial matrix: the fingerprint
  # table is the exact comparison, these only help explain it.
  def by_dimension(dimension)
    column = GROUPABLE[dimension.to_sym]
    return [] unless column

    grouped = rated_scope.pluck(column, :rating_score).group_by(&:first)
    grouped.filter_map do |value, pairs|
      scores = pairs.map(&:last).compact
      next if scores.size < MIN_VISIBLE_SAMPLE

      { value: value, n: scores.size, mean: mean(scores), median: median(scores),
        low_sample: scores.size < MIN_RANKING_SAMPLE }
    end.sort_by { |row| -row[:n] }
  end

  private

  def apply_period(scope)
    case @period.to_sym
    when :today then scope.today
    when :week then scope.this_week
    when :month then scope.this_month
    else scope
    end
  end

  # Only allowlisted keys reach the query, and each maps to a fixed column.
  def apply_filters(scope)
    GROUPABLE.each do |key, column|
      value = @filters[key]
      next if value.blank?

      scope = scope.where(column => value)
    end
    scope
  end

  def rated_scores
    @rated_scores ||= rated_scope.pluck(:rating_score).compact
  end

  def traced_rows
    rated_scope
      .where.not(generation_trace_version: nil)
      .where.not(generation_config_fingerprint: nil)
      .pluck(:generation_config_fingerprint, :rating_score, :provider_used, :model_used,
             :provider_model_used, :intelligence_level, :reasoning_effort_requested,
             :reasoning_effort_used, :provider_reasoning_value, :reasoning_mode,
             :reasoning_token_budget, :profile_used, :concise_mode, :temperature_used,
             :output_token_limit, :prompt_version, :retrieval_version, :response_time,
             :input_tokens, :output_tokens, :estimated_cost_eur, :credits_deducted,
             *optional_columns, :rating_reason_codes_json)
      .map { |values| row_hash(values) }
  end

  # The retry counter is read only where the column exists: the dashboard must
  # keep rendering on a database the analytics migration has not reached yet.
  def optional_columns
    ChatbotAnalytic.provider_calls_supported? ? [:provider_calls] : []
  end

  def row_hash(values)
    keys = %i[fingerprint score provider model provider_model intelligence
              reasoning_requested reasoning_used provider_reasoning reasoning_mode
              reasoning_budget profile concise temperature output_limit
              prompt_version retrieval_version response_time input_tokens
              output_tokens cost credits] + optional_columns + [:reason_json]
    keys.zip(values).to_h
  end

  def build_group(fingerprint, group, period_mean)
    scores = group.map { |row| row[:score] }.compact
    sample = group.first

    {
      fingerprint: fingerprint,
      n: scores.size,
      mean: mean(scores),
      median: median(scores),
      adjusted_mean: adjusted_mean(scores, period_mean),
      high_share: share_within(scores, HIGH_RANGE),
      low_share: share_within(scores, LOW_RANGE),
      low_sample: scores.size < MIN_RANKING_SAMPLE,
      rankable: scores.size >= MIN_RANKING_SAMPLE,
      provider: sample[:provider],
      model: sample[:model],
      provider_model: sample[:provider_model],
      intelligence: sample[:intelligence],
      reasoning_requested: sample[:reasoning_requested],
      reasoning_used: sample[:reasoning_used],
      provider_reasoning: sample[:provider_reasoning],
      reasoning_mode: sample[:reasoning_mode],
      reasoning_budget: sample[:reasoning_budget],
      profile: sample[:profile],
      concise: sample[:concise],
      # A traced row with a null temperature means the provider request
      # OMITTED it. Untraced rows never reach this table, so this label can
      # never mean "unknown".
      temperature: sample[:temperature],
      temperature_omitted: sample[:temperature].nil?,
      output_limit: sample[:output_limit],
      prompt_version: sample[:prompt_version],
      retrieval_version: sample[:retrieval_version],
      mean_response_time: average_of(group, :response_time),
      mean_input_tokens: average_of(group, :input_tokens),
      mean_output_tokens: average_of(group, :output_tokens),
      mean_cost: average_of(group, :cost, precision: 6),
      mean_credits: average_of(group, :credits),
      # How often this configuration needed a SECOND generation. A retry is
      # invisible to the reader and doubles both the cost and the wait, so a
      # configuration that scores well only because it regenerates constantly
      # has to be readable as such. Null on rows written before the counter
      # existed, so the share is over rows that actually carry it.
      mean_provider_calls: average_of(group, :provider_calls, precision: 2),
      retry_share: retry_share(group),
      reasons: group_reason_counts(group)
    }
  end

  def traced_statistics_suppressed?(rows)
    scored = rows.count { |row| row[:score].present? }
    scored.positive? && scored < MIN_VISIBLE_SAMPLE
  end

  # Share of COUNTED rows that needed more than one generation. Rows without
  # the counter are excluded rather than assumed clean: before the column
  # existed the retry was simply not recorded, and calling that 0%% would
  # invent a measurement.
  def retry_share(group)
    counted = group.map { |row| row[:provider_calls] }.compact
    return nil if counted.empty?

    (counted.count { |calls| calls.to_i > 1 }.to_f / counted.size).round(3)
  end

  # Shrinkage toward the period mean: a group of 3 tens does not outrank a
  # group of 200 eights.
  def adjusted_mean(scores, period_mean)
    return nil if scores.empty?

    n = scores.size
    group_mean = scores.sum.to_f / n
    (((n * group_mean) + (PRIOR_WEIGHT * period_mean)) / (n + PRIOR_WEIGHT)).round(2)
  end

  def rank(groups)
    groups.sort_by do |group|
      # Unrankable groups sink below every ranked one regardless of score.
      [group[:rankable] ? 0 : 1, -(group[:adjusted_mean] || 0), -group[:n]]
    end
  end

  # Suppressed groups collapse into ONE unlabeled total. This is an
  # anti-reidentification guard, not deletion: the ratings still count in the
  # overview.
  def summarize_suppressed(groups)
    return nil if groups.empty?

    ratings = groups.sum { |group| group[:n] }
    # The combined total is itself a population. Four groups of one collapse to
    # "4 ratings", which is still four individual answers.
    return { groups: groups.size, ratings: nil, suppressed: true, minimum_sample: MIN_VISIBLE_SAMPLE } if ratings < MIN_VISIBLE_SAMPLE

    { groups: groups.size, ratings: ratings }
  end

  # The most common reasons WITHIN one configuration, counted once per answer.
  def group_reason_counts(group)
    tally = Hash.new(0)
    group.each { |row| parse_codes(row[:reason_json]).uniq.each { |code| tally[code] += 1 } }
    tally.sort_by { |_code, count| -count }.first(3).map { |code, count| { code: code, count: count } }
  end

  # --- statistics -----------------------------------------------------------

  def mean(scores)
    return nil if scores.blank?

    (scores.sum.to_f / scores.size).round(2)
  end

  # Computed in Ruby, not SQL: SQLite and PostgreSQL disagree on median, and
  # the rated population per period is small enough that this is free.
  def median(scores)
    return nil if scores.blank?

    sorted = scores.sort
    middle = sorted.size / 2
    return sorted[middle].to_f if sorted.size.odd?

    ((sorted[middle - 1] + sorted[middle]) / 2.0).round(2)
  end

  def distribution(scores)
    counts = scores.tally
    (1..10).map do |score|
      count = counts[score] || 0
      { score: score, count: count, percentage: percentage(count, scores.size) }
    end
  end

  def share_within(scores, range)
    return nil if scores.blank?

    percentage(scores.count { |score| range.cover?(score) }, scores.size)
  end

  # Each code counts once per analytic, so a single answer cannot inflate a
  # reason by repeating it.
  def reason_counts(rated_total)
    tally = Hash.new(0)
    rated_scope.where.not(rating_reason_codes_json: nil)
               .pluck(:rating_reason_codes_json)
               .each do |raw|
      codes = parse_codes(raw)
      codes.uniq.each { |code| tally[code] += 1 }
    end

    tally.sort_by { |_code, count| -count }.map do |code, count|
      { code: code, count: count, share: percentage(count, rated_total) }
    end
  end

  def parse_codes(raw)
    parsed = JSON.parse(raw.to_s)
    parsed.is_a?(Array) ? parsed.grep(String) : []
  rescue JSON::ParserError
    []
  end

  # Precision is per-measure on purpose. Latency, tokens and credits are
  # readable at two decimals; MONEY IS NOT. Per-query costs are flat constants
  # between EUR 0.004 and EUR 0.165, so rounding money at two decimals renders
  # the free-tier default model as 0.0000 and collapses adjacent price tiers
  # into the same figure - and the cost column is precisely what makes this
  # table a routing decision rather than a curiosity.
  def average_of(group, key, precision: 2)
    values = group.filter_map { |row| row[key] }
    return nil if values.empty?

    (values.sum.to_f / values.size).round(precision)
  end

  def percentage(part, total)
    return nil if total.to_i.zero?

    ((part.to_f / total) * 100).round(1)
  end
end
