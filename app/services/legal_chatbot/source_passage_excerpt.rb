# frozen_string_literal: true

module LegalChatbot
  # Context for a retrieved judgment/report, not a new summary of it. Every
  # passage is an unmodified span of the stored body. Omission markers and the
  # separately labelled catalogue summary are never quotation evidence.
  module SourcePassageExcerpt
    ELISION = "\n[...]\n"
    LITERAL_LABEL = "LITERAL SOURCE PASSAGES (partial document; [...] marks omissions; do not infer a complete holding from an excerpt):\n"
    SUMMARY_LABEL = "RETRIEVED SUMMARY (not literal source text; never quote as the judgment/report):\n"
    NO_BODY_LABEL = "NO LITERAL SOURCE BODY AVAILABLE.\n"
    SENTENCE_BOUNDARY = /(?<=[.!?;])[[:space:]]+(?=[[:upper:]\d§])/
    PAGE_LABEL = %r{\A[[:space:]]*(?:(?:p(?:age|agina|agina's|agina’s)?|blz|seite|pagina)\.?[[:space:]]*\d+(?:[[:space:]]*(?:/|of|van|sur|von)[[:space:]]*\d+)?|[-–—][[:space:]]*\d+[[:space:]]*[-–—])[[:space:]]*\z}i
    OPERATIVE_LABEL = /\A[[:space:]]*(?:(?:om|par|for|aus|pour)[[:space:]]+(?:die|deze|ces|these|diesen|ces)[[:space:]]+(?:redenen|motifs|reasons|gründen)|(?:het[[:space:]]+hof,[[:space:]]*)?besluit|dispositif|tenor|conclusions?|conclusies?)[[:space:]:.,-]*\z/i

    module_function

    def excerpt(text, question, max_chars:, summary: nil)
      budget = max_chars.to_i
      return '' unless budget.positive?

      body = text.to_s
      summary = summary.to_s.strip
      # A catalogue summary can help explain a source but is never silently
      # substituted for a missing body or merged into literal passages.
      summary_block = if summary.empty?
                        ''
                      else
                        summary_budget = body.strip.empty? ? budget : [400, budget / 5].min
                        labelled_summary(summary, summary_budget)
                      end
      return (NO_BODY_LABEL + labelled_summary(summary, budget - NO_BODY_LABEL.length))[0, budget] if body.strip.empty?

      literal_budget = budget - LITERAL_LABEL.length - summary_block.length
      return (LITERAL_LABEL + literal_passages(body, question, [budget - LITERAL_LABEL.length, 0].max))[0, budget] if literal_budget < 160

      LITERAL_LABEL + literal_passages(body, question, literal_budget) + summary_block
    end

    def labelled_summary(summary, budget)
      return '' if summary.empty? || budget <= SUMMARY_LABEL.length + ELISION.length

      room = budget - SUMMARY_LABEL.length - 2
      text = summary.length <= room ? summary : summary[0, room - ELISION.length].rstrip + ELISION
      "\n#{SUMMARY_LABEL}#{text}\n"
    end

    def literal_passages(text, question, budget)
      return '' unless budget.positive?
      return text if text.length <= budget
      return text[0, budget] if budget <= ELISION.length * 2

      units = source_units(text, budget)
      terms = ArticleExcerpt.question_terms(question)
      scores = units.map { |unit| ArticleExcerpt.score(text[unit[:start]...unit[:finish]], terms) }
      ranked = units.each_index.select { |index| scores[index].positive? }
                    .sort_by { |index| [-scores[index], index] }
      # With no literal lexical match retain opening context and any actual
      # dispositive section, rather than inventing a translated matching term.
      ranked = [0] if ranked.empty?

      selected = []
      main_passage_selected = false
      operative = (units.length - 1).downto(0).find do |index|
        units[index][:start] >= text.length / 2 &&
          text[units[index][:start]...units[index][:finish]].strip.match?(OPERATIVE_LABEL)
      end
      if operative
        # Preserve the outcome as well as reasoning when it fits. It is a
        # separate literal passage, not evidence that every reasoning sentence
        # states the holding. No outcome is synthesized from the summary.
        last = [operative + 3, units.length - 1].min
        outcome = [units[operative][:start], units[last][:finish]]
        selected << outcome if range_cost(text, [outcome]) <= budget / 3
      end

      ranked.each do |index|
        remaining = budget - range_cost(text, selected) - (ELISION.length * 2)
        break if remaining < 80
        next if selected.any? { |start, finish| units[index][:start] >= start && units[index][:finish] <= finish }

        # Do not spend all remaining space on the matching sentence alone:
        # grow a contiguous window on both sides, so qualifications in the
        # next paragraph and the paragraph's real number survive together.
        span = context_window(text, units, index, remaining)
        next unless span

        candidate = merge_ranges(selected + [span])
        if range_cost(text, candidate) <= budget
          selected = candidate
          main_passage_selected = true
        end
      end

      unless main_passage_selected
        # A single unbroken OCR paragraph can exceed any context budget.
        # Keep an exact word-boundary window around the best actual match,
        # clearly elided on both sides, rather than reverting to its opening.
        index = ranked.first
        remaining = budget - range_cost(text, selected) - (ELISION.length * 2)
        if remaining < 80
          selected = []
          remaining = budget - (ELISION.length * 2)
        end
        selected = merge_ranges(selected + [bounded_span(text, units[index], terms, remaining)])
      end
      render(text, selected)
    end

    # Keep original offsets, punctuation, paragraph numbers and page labels.
    # Long OCR lines are split only on existing sentence whitespace; a normal
    # paragraph is never reworded or reconstructed.
    def source_units(text, budget)
      units = []
      text.to_enum(:scan, /[^\n]+(?:\n|\z)/).each do
        line = Regexp.last_match
        start = line.begin(0)
        finish = line.end(0)
        if finish - start > [budget / 2, 240].max
          cursor = start
          line[0].to_enum(:scan, SENTENCE_BOUNDARY).each do
            boundary = Regexp.last_match
            edge = start + boundary.end(0)
            units << { start: cursor, finish: edge }
            cursor = edge
          end
          units << { start: cursor, finish: finish } if cursor < finish
        else
          units << { start: start, finish: finish }
        end
      end
      units
    end

    def context_window(text, units, index, budget)
      return nil if units[index][:finish] - units[index][:start] > budget

      left = right = index
      # The next paragraph often supplies "however/unless"; the previous one
      # supplies the premise and real paragraph/page label. Keep both before
      # expanding farther, under a single contiguous source-span budget.
      [-1, 1, -2, 2, -3, 3].each do |offset|
        candidate = index + offset
        next unless candidate.between?(0, units.length - 1)

        new_left = [left, candidate].min
        new_right = [right, candidate].max
        next if units[new_right][:finish] - units[new_left][:start] > budget

        left = new_left
        right = new_right
      end
      # A short source page label just above the window is useful provenance;
      # preserve it only when the intervening literal text also fits.
      ([left - 4, 0].max...left).to_a.reverse_each do |candidate|
        next unless text[units[candidate][:start]...units[candidate][:finish]].strip.match?(PAGE_LABEL)

        left = candidate if units[right][:finish] - units[candidate][:start] <= budget
        break
      end
      [units[left][:start], units[right][:finish]]
    end

    def bounded_span(text, unit, terms, budget)
      chunk = text[unit[:start]...unit[:finish]]
      first = terms.filter_map { |term| chunk.downcase.index(term[:stem]) }.min || 0
      start = [unit[:start] + first - (budget / 3), unit[:start]].max
      start += 1 while start < unit[:start] + first && !text[start - 1].match?(/[[:space:]]/)
      finish = [start + budget, unit[:finish]].min
      finish -= 1 while finish > unit[:start] + first && finish < text.length && !text[finish].match?(/[[:space:]]/)
      [start, finish]
    end

    def merge_ranges(ranges)
      ranges.sort.each_with_object([]) do |span, merged|
        if merged.any? && span[0] <= merged.last[1]
          merged.last[1] = [merged.last[1], span[1]].max
        else
          merged << span.dup
        end
      end
    end

    def range_cost(text, ranges)
      return 0 if ranges.empty?

      render(text, merge_ranges(ranges)).length
    end

    def render(text, ranges)
      ranges = merge_ranges(ranges)
      result = ranges.map { |start, finish| text[start...finish] }.join(ELISION)
      result = ELISION + result if ranges.first[0].positive?
      result += ELISION if ranges.last[1] < text.length
      result
    end
  end
end
