# frozen_string_literal: true

module LegalChatbot
  # Context for a retrieved judgment/report, not a new summary of it. Every
  # passage is an unmodified span of the stored body. Omission markers and the
  # separately labelled catalogue summary are never quotation evidence.
  module SourcePassageExcerpt
    ELISION = "\n[...]\n"
    # A matching window keeps growing to this size when the budget allows: OCR bodies hold a few words per
    # line, so three lines either side can be a few dozen characters (#0962).
    MIN_WINDOW_CHARS = 600
    LITERAL_LABEL = "LITERAL SOURCE PASSAGES (partial document; [...] marks omissions; do not infer a complete holding from an excerpt):\n"
    SUMMARY_LABEL = "RETRIEVED SUMMARY (not literal source text; never quote as the judgment/report):\n"
    NO_BODY_LABEL = "NO LITERAL SOURCE BODY AVAILABLE.\n"
    SENTENCE_BOUNDARY = /(?<=[.!?;])[[:space:]]+(?=[[:upper:]\d§])/
    PAGE_LABEL = %r{\A[[:space:]]*(?:(?:p(?:age|agina|agina's|agina’s)?|blz|seite|pagina)\.?[[:space:]]*\d+(?:[[:space:]]*(?:/|of|van|sur|von)[[:space:]]*\d+)?|[-–—][[:space:]]*\d+[[:space:]]*[-–—])[[:space:]]*\z}i
    # The operative part's heading. Cassation's recent judgments head it "Dictum" (13,839 judgment texts hold the
    # word, cases_fts, 2026-11-20; #1576 lost its outcome without it).
    OPERATIVE_LABEL = /\A[[:space:]]*(?:(?:om|par|for|aus|pour)[[:space:]]+(?:die|deze|ces|these|diesen|ces)[[:space:]]+(?:redenen|motifs|reasons|gründen)|(?:het[[:space:]]+hof,[[:space:]]*)?besluit|dispositif|tenor|dictum|conclusions?|conclusies?)[[:space:]:.,-]*\z/i
    # Where the court's own reasoning begins: "- B -" in the Constitutional Court's judgments, "Beoordeling" /
    # "Appréciation" in Cassation's. Before it stand the parties' arguments, which never outrank the court's reasoning
    # on an equal match (#2445).
    REASONING_LABEL = /\A[[:space:]]*(?:-[[:space:]]*B[[:space:]]*-|beoordeling|appréciation)[[:space:]:.,-]*\z/i
    # A numbered consideration, as the Constitutional Court numbers its judgments: the label that opens it at the
    # start of a line ("B.7. De keuze ...", "B.1.8. De voormelde ..."), and the same label named in a question
    # ("B.7", "B.1.7 en B.5.3"). Sol 2026-11-23 03:45:46Z: with the exact ECLI and "B.7" in the question, the reasons
    # quoted at B.7 of judgment 41/2009 were absent. A passage was chosen by the question's words alone, a label is
    # no word, and the window around a matching line (600 characters) stopped inside the quoted memorandum.
    CONSIDERATION_LABEL = /\A[[:space:]]*([AB]\.\d{1,2}(?:\.\d{1,2}){0,3})\.[[:space:]]/
    # "b.7" in a question reads as B.7 (Sol 2026-11-23 10:08:33Z)
    NAMED_CONSIDERATION = /(?<![[:alnum:].])([AaBb]\.\d{1,2}(?:\.\d{1,2}){0,3})(?![[:alnum:]]|\.\d)/
    # A page number on a line of its own, as the judgments' PDF text leaves them between two considerations
    BARE_PAGE_NUMBER = /\A[[:space:]]*\d{1,4}[[:space:]]*\z/
    MAX_NAMED_CONSIDERATIONS = 6

    module_function

    # court: the deciding court of a judgment, whose own name in the question selects the judgment, not a passage.
    # labels: the consideration labels that are this judgment's own when the question names several judgments
    # (JurisprudenceSearch.named_references); nil reads them from the question.
    def excerpt(text, question, max_chars:, summary: nil, court: nil, labels: nil)
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
      if literal_budget < 160
        room = [budget - LITERAL_LABEL.length, 0].max
        return (LITERAL_LABEL + literal_passages(body, question, room, court: court, labels: labels))[0, budget]
      end

      LITERAL_LABEL + literal_passages(body, question, literal_budget, court: court, labels: labels) + summary_block
    end

    def labelled_summary(summary, budget)
      return '' if summary.empty? || budget <= SUMMARY_LABEL.length + ELISION.length

      room = budget - SUMMARY_LABEL.length - 2
      text = summary.length <= room ? summary : summary[0, room - ELISION.length].rstrip + ELISION
      "\n#{SUMMARY_LABEL}#{text}\n"
    end

    def literal_passages(text, question, budget, court: nil, labels: nil)
      return '' unless budget.positive?
      return text if text.length <= budget
      return text[0, budget] if budget <= ELISION.length * 2

      units = source_units(text, budget)
      terms = passage_terms(question, court)
      scores = units.map { |unit| ArticleExcerpt.score(text[unit[:start]...unit[:finish]], terms) }
      # On an equal match the court's reasoning comes first, then the passage that uses the matched terms most often
      # (#2445: the admissibility points B.2-B.4 of GwH 41/2009 name discrimination once, B.6 and B.11 three times).
      reasoning = reasoning_start(text, units)
      ranked = units.each_index.select { |index| scores[index].positive? }
                    .sort_by do |index|
                      [-scores[index], reasoning && units[index][:start] >= reasoning ? 0 : 1,
                       -term_hits(text[units[index][:start]...units[index][:finish]], terms), index]
                    end
      # With no literal lexical match retain opening context and any actual
      # dispositive section, rather than inventing a translated matching term.
      no_match = ranked.empty?
      ranked = [0] if no_match

      selected = []
      main_passage_selected = false
      operative = (units.length - 1).downto(0).find do |index|
        units[index][:start] >= text.length / 2 &&
          text[units[index][:start]...units[index][:finish]].strip.match?(OPERATIVE_LABEL)
      end
      # The considerations the question names come first and whole, each from its label to the next one, so a
      # quotation inside it and the reasons after the quotation stay together. One that is longer than the room
      # left is cut at the end of a line, and the cut is marked. Sol 2026-11-23 11:08:38Z: a very long first one took
      # the room of the next. They share it: one that fits its share stands whole, the others share what it leaves.
      named = named_considerations(text, units, question, operative, named: labels)
      shares = fair_shares(named.map { |start, finish, _first| finish - start }, budget - (ELISION.length * 2 * named.size))
      named.zip(shares).each do |(start, finish, first), share|
        room = budget - range_cost(text, selected) - (ELISION.length * 2)
        next if room < 80

        remaining = [room, share].min

        span = finish - start <= remaining ? [start, finish] : leading_span(text, units, first, finish, remaining)
        selected = merge_ranges(selected + [span])
        main_passage_selected = true
      end
      if operative
        # Preserve the outcome as well as reasoning when it fits. It is a
        # separate literal passage, not evidence that every reasoning sentence
        # states the holding. No outcome is synthesized from the summary.
        last = [operative + 3, units.length - 1].min
        outcome = [units[operative][:start], units[last][:finish]]
        with_outcome = merge_ranges(selected + [outcome])
        selected = with_outcome if range_cost(text, [outcome]) <= budget / 3 && range_cost(text, with_outcome) <= budget
      end

      ranked.each do |index|
        remaining = budget - range_cost(text, selected) - (ELISION.length * 2)
        break if remaining < 80
        next if selected.any? { |start, finish| units[index][:start] >= start && units[index][:finish] <= finish }

        # Do not spend all remaining space on the matching sentence alone:
        # grow a contiguous window on both sides, so qualifications in the
        # next paragraph and the paragraph's real number survive together.
        # Without any match the opening context may use the whole budget: a reported judgment opens with its
        # headnote, which is what such a question needs (#0962).
        span = context_window(text, units, index, remaining,
                              target: no_match ? remaining : [MIN_WINDOW_CHARS, remaining].min)
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

    # [[start, finish, first unit], ...]: the considerations the question names that the text holds, in the order the
    # question names them. A consideration runs from its label, at the start of a line, to the next label or the
    # operative part; the page numbers left on their own line before that next label are not part of it. A label
    # with no line of its own ("B.5" where the judgment numbers B.5.1, B.5.2, ...) takes its sub-considerations.
    def named_considerations(text, units, question, operative, named: nil)
      names = (named || question.to_s.scan(NAMED_CONSIDERATION).flatten).map { |name| name.sub(/\A[ab]/, &:upcase) }
                                                                        .uniq.first(MAX_NAMED_CONSIDERATIONS)
      return [] if names.empty?

      labels = units.each_index.filter_map do |index|
        start = units[index][:start]
        next unless start.zero? || text[start - 1] == "\n"

        label = text[start...units[index][:finish]][CONSIDERATION_LABEL, 1]
        [index, label] if label
      end
      names.filter_map do |name|
        own = ->(label) { label == name }
        under = ->(label) { label.start_with?("#{name}.") }
        first = labels.find { |_index, label| own.call(label) } || labels.find { |_index, label| under.call(label) }
        next unless first

        part_of = own.call(first[1]) ? ->(_label) { false } : under
        following = labels.find { |index, label| index > first[0] && !part_of.call(label) }
        stop = [following&.first, operative && operative > first[0] ? operative : nil, units.length].compact.min
        last = stop - 1
        last -= 1 while last > first[0] && text[units[last][:start]...units[last][:finish]].match?(BARE_PAGE_NUMBER)
        [units[first[0]][:start], units[last][:finish], first[0]]
      end
    end

    # Each length's share of total: the shortest are given whole while they fit an equal share of what is left, and
    # the rest share it equally.
    def fair_shares(lengths, total)
      shares = Array.new(lengths.size, 0)
      left = [total, 0].max
      lengths.each_index.sort_by { |index| [lengths[index], index] }.each_with_index do |index, rank|
        shares[index] = [lengths[index], left / (lengths.size - rank)].min
        left -= shares[index]
      end
      shares
    end

    # The start of a consideration that does not fit: its lines while they fit, else the start of its first line
    # up to a word.
    def leading_span(text, units, first, finish, budget)
      start = units[first][:start]
      last = first
      last += 1 while last + 1 < units.length && units[last + 1][:finish] <= finish && units[last + 1][:finish] - start <= budget
      return [start, units[last][:finish]] if units[last][:finish] - start <= budget

      cut = start + budget
      cut -= 1 while cut > start + 1 && !text[cut].match?(/[[:space:]]/)
      [start, cut]
    end

    # The question's terms without the words of the deciding court's own name. "Wat zegt het Grondwettelijk Hof over
    # discriminatie?" names the judgment, not a passage of it: the parties' arguments that mention the Court's name
    # outranked its reasoning, and the caption "Het Grondwettelijk Hof," counted as a match (#2445).
    def passage_terms(question, court)
      terms = ArticleExcerpt.question_terms(question)
      return terms if court.to_s.strip.empty?

      court_stems = ArticleExcerpt.question_terms(court).map { |term| term[:stem] }
      terms.reject { |term| court_stems.include?(term[:stem]) }
    end

    # How often the matched terms occur in a passage.
    def term_hits(passage, terms)
      haystack = passage.downcase
      terms.sum { |term| haystack.scan(term[:stem]).size }
    end

    # The offset where the court's own reasoning begins, or nil when the text has no such heading.
    def reasoning_start(text, units)
      index = units.index { |unit| text[unit[:start]...unit[:finish]].strip.match?(REASONING_LABEL) }
      index && units[index][:start]
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

    def context_window(text, units, index, budget, target: budget)
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
      # Short units (OCR lines) leave the window far below its target: grow on, right then left, while it fits.
      loop do
        grown = false
        if right + 1 < units.length && units[right][:finish] - units[left][:start] < target &&
           units[right + 1][:finish] - units[left][:start] <= budget
          right += 1
          grown = true
        end
        if left.positive? && units[right][:finish] - units[left][:start] < target &&
           units[right][:finish] - units[left - 1][:start] <= budget
          left -= 1
          grown = true
        end
        break unless grown
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
