# frozen_string_literal: true

module LegalChatbot
  # A long article cut to size for the model's context, keeping the part the
  # question is about rather than whatever comes first.
  #
  # Art. 47bis of the Code of Criminal Procedure runs to 12,600 characters.
  # "Salduz-bijstand minderjarigen?" retrieved it, the context kept its first
  # 4,000 characters, and the two provisions on minors (§ 3, from character
  # 4,300 on) never reached the model, which then told the reader that the
  # sources name no rule for minors (2026-10-04). The head cut was blind to
  # the question; this excerpt is not.
  #
  # The article is split into its units: the lines Justel separates, which
  # are the paragraphs, the leden and the enumerated items. With a question
  # that names something in the article, the excerpt holds the article's
  # opening line (what the model cites it by), then the units that share
  # terms with the question, then the units next to those (a lid reads with
  # the lid before it), then whatever follows the head, all in text order
  # with an elision marker wherever units were skipped. The first version
  # kept a thousand characters of opening before the matches: for Art. 47bis
  # that was the whole list of § 1, the rights of a person who is no suspect,
  # and the model built its main rule on it while the minors' provisions sat
  # under "exceptions". A question that names nothing in the article gets the
  # old head cut, so an article the question is not specific about reads as
  # before.
  #
  # Quotes are verified against the full retrieved text, not against this
  # excerpt, so an elision can never fail a faithful quotation.
  module ArticleExcerpt
    HEAD_CHARS = 1_000
    # With matches, the head is the opening line alone, or the first lines up
    # to this length when the opening is a bare "Art. 5." style title.
    MATCHED_HEAD_CHARS = 120
    ELISION = "\n[...]\n"
    MIN_TERM_LENGTH = 4
    # A term matches a unit on its stem, so an inflection in the question
    # still finds the article's form: minderjarigen / minderjarige,
    # advocaten / advocaat, mineurs / mineur.
    MIN_STEM_LENGTH = 5
    STEM_TRIM = 2
    SPECIFIC_STEM_LENGTH = 8
    # Only source whitespace is replaced when a collapsed article is split:
    # a sentence ending before a capital, or an explicit statutory item.
    # A collapsed EU paragraph marker ("… Nutzers. (2) Absatz", "… service.
    # 2. Le paragraphe") starts a new unit, so the last list item does not
    # carry the next paragraph's number (DSA Art. 17, Codex 2026-10-18).
    SINGLE_LINE_BOUNDARY = /(?<=[.!?])[[:space:]]+(?=[[:upper:]])|[[:space:]]+(?=§[[:space:]]*\d|(?:\d+|[a-z])[°)][[:space:]])|(?<=[[:lower:]]{3}[.;:])[[:space:]]+(?=(?:\(\d{1,2}\)|\d{1,2}\.)[[:space:]])/
    # Selection aliases, never translated evidence. EN and DE questions can
    # be answered from binding NL/FR text: matching only the question's raw
    # words head-cut Art.47bis before its minors provision. Keep the source
    # literal while recognising these specific, equivalent legal concepts.
    CROSS_LANGUAGE_CONCEPTS = [
      %w[minderjarig minderjarige minderjarigen mineur mineurs minor minors minderjährig minderjährige minderjähriger minderjährigen],
      %w[advocaat advocaten avocat avocats lawyer lawyers anwalt anwälte anwalts anwältin],
      # A Dutch question about a blocked account must find the DE/FR scope
      # limbs of a platform article ("Aussetzung oder Schließung des Kontos",
      # "suspension ou suppression du compte"; DSA Art. 17, 2026-10-18).
      %w[account accounts gebruikersaccount konto kontos benutzerkonto compte comptes],
      %w[geblokkeerd geblokkeerde blokkering blokkeren geschorst schorsing opgeschort opschorting blocked suspended
         suspension suspendu suspendre suppression aussetzung ausgesetzt sperrung gesperrt schließung geschlossen
         closure fermeture],
      %w[motivering motiveren motivatie redenen reasons begründung begründen motifs motivation]
    ].map(&:freeze).freeze

    # Consumer remedies occur late in Art. 1649quinquies. An English question
    # about a warranty repair, exchange or refund must select those literal
    # NL/FR units too. These are selection hints, not translations or a rule
    # that refund, termination and replacement are interchangeable remedies.
    # Require consumer/conformity context: a tax refund or a contract quoted
    # in an unrelated question must not pull in the warranty remedy ladder.
    CONSUMER_REMEDY_CONTEXT = /\b(?:consumer\p{L}*|consument\p{L}*|consommateur\p{L}*|verbraucher\p{L}*|warrant\p{L}*|garanti\p{L}*|gewährleist\p{L}*|conformit\p{L}*)\b/
    CONSUMER_REMEDY_CONCEPTS = [
      %w[repair repairs repaired repairing reparatie reparaties herstel herstelling herstellingen réparation réparations réparer reparatur reparaturen nachbesserung],
      %w[replacement replacements replace replacing exchange exchanges vervanging vervangen omruiling omruilen remplacement remplacer échange échanger austausch ersatzlieferung ersetzen],
      %w[refund refunds refunded terugbetaling terugbetalen terugbetaald remboursement rembourser rückerstattung rückzahlung erstattung ontbinding ontbinden résolution rücktritt],
      %w[prijsvermindering prijskorting réduction reduction preisminderung minderung]
    ].map(&:freeze).freeze
    STATUTORY_PARAGRAPH = %r{\A(?:\[\d+\]?[[:space:]]*)?§[[:space:]]*\d+(?:/\d+)?\.}
    PRICE_REDUCTION = /prijsvermindering|réduction|preisminderung|price reduction/i
    CONTRACT_TERMINATION = /ontbinding|résolution|rücktritt|termination/i
    REMEDY_CASES = /volgende gevallen|cas suivants|folgenden fällen|following cases/i
    # An instrument's explicit applicability lead introduces the following
    # list as a unit. A later procedural "paragraph 1 applies provided ..."
    # is not such a lead. Some imported sources put numbering on its own
    # line and omit the colon, so the immediately linked item is the guard.
    APPLICABILITY_LEAD = %r{
      \A(?:(?:\[\d+\]?[[:space:]]*)?(?:§[[:space:]]*)?\d+(?:/\d+)?\.[[:space:]]*)?
      (?:
        (?:deze|dit)[[:space:]]+(?:wet|verordening|richtlijn|besluit|regeling|hoofdstuk|afdeling|artikel|titel)
          [[:space:]]+(?:is|zijn)[[:space:]]+van[[:space:]]+toepassing\b
        |(?:le|la)[[:space:]]+présente?[[:space:]]+(?:règlement|loi|directive|décision|chapitre|section|article|titre)
          [[:space:]]+s['’]applique\b
        |this[[:space:]]+(?:regulation|act|directive|decision|chapter|section|article|title)
          [[:space:]]+(?:shall[[:space:]]+apply|applies)\b
        |diese[rsnm]?[[:space:]]+(?:verordnung|gesetz|richtlinie|entscheidung|kapitel|abschnitt|artikel|titel)
          [[:space:]]+gilt\b
      )
    }ix
    APPLICABILITY_ITEM = /\A(?:[a-z]\)|\([a-z]\)|\d+[°)])(?:[[:space:]]|\z)/i
    NUMBERED_PARAGRAPH = %r{\A(?:\[\d+\]?[[:space:]]*)?(?:§[[:space:]]*)?\d+(?:/\d+)?\.(?:[[:space:]]|\z)}

    # Function words in the four languages the chatbot answers in. A question
    # is short, so one of these counted as a term would outvote its subject.
    STOPWORDS = %w[
      welke welk wat hoe wanneer waar wie waarom deze dit die dat een het van voor met over door naar
      zijn hebben heeft wordt worden kan kunnen moet moeten mag mogen geldt gelden ook niet geen als
      dan nog wel maar onder tussen volgens tijdens zonder binnen buiten omdat indien bijvoorbeeld
      quel quelle quels quelles comment quand pour avec dans sur sous entre selon est sont peut
      peuvent doit doivent cette cela ceci leur leurs vous nous elle elles ils aussi plus mais
      lorsque pendant sans dont faut
      welche welcher welches wann für mit über durch nach sind kann können muss müssen darf dürfen
      diese dieser dieses auch nicht kein keine dann noch aber unter zwischen während ohne wenn
      what which when where who whom how this that these those with from into about than then
      also have does been being shall should must could would will your their there here
    ].to_set.freeze

    module_function

    # @param text [String] the article text, already UTF-8 clean
    # @param question [String, nil] the reader's question
    # @param max_chars [Integer] the context budget for this article
    # @return [String] at most max_chars characters of the article
    def excerpt(text, question, max_chars:)
      text = text.to_s
      return text if max_chars.nil? || max_chars <= 0 || text.length <= max_chars

      units = split_units(text).flat_map do |unit|
        # A Justel paragraph can itself exceed the context budget. Split it
        # only at the same safe source boundaries used for collapsed text;
        # otherwise a late matching remedy is skipped as an oversized unit.
        unit.length > max_chars ? unit.split(SINGLE_LINE_BOUNDARY) : [unit]
      end
      terms = question_terms(question)
      return text[0, max_chars] if terms.empty?

      if units.size < 2
        units = text.split(SINGLE_LINE_BOUNDARY).map(&:strip).reject(&:empty?)
        return single_line_window(text, terms, max_chars) if units.size < 2
      end

      matches = scored_matches(units, terms, head_indexes(units))
      return text[0, max_chars] if matches.empty?

      selected = matched_head_indexes(units)
      budget = max_chars - joined_length(units, selected) - ELISION.length
      remedy_groups = consumer_remedy_groups(units, question)
      remedy_groups.each do |group|
        candidates = group - selected
        cost = candidates.sum { |index| units[index].length + ELISION.length }
        next if cost > budget

        selected.concat(candidates)
        budget -= cost
      end
      # Ancillary remedy paragraphs are also selected whole. Do not spend a
      # small remainder on a heading and its first numbered item while
      # dropping its remaining limitations, even if the cases do not fit.
      return render(units, selected.sort, {}, max_chars) unless remedy_groups.empty?

      applicability_groups(units).each do |group|
        candidates = group - selected
        cost = candidates.sum { |index| units[index].length + ELISION.length }
        next if cost > budget

        selected.concat(candidates)
        budget -= cost
      end

      matched = matches.map(&:last)
      budget = add_units(units, selected, budget, matched, reserve: ELISION.length)
      budget = add_units(units, selected, budget, neighbours(units, matched & selected), reserve: ELISION.length)
      partial = fill_forward(units, selected, budget)
      render(units, selected.sort, partial, max_chars)
    end

    # The lines of the article, whitespace trimmed, empty ones dropped.
    def split_units(text)
      text.split("\n").map { |line| line.gsub(/\A[[:space:]]+|[[:space:]]+\z/, '') }.reject(&:empty?)
    end

    # The question's content words as stems with a weight: a long word names
    # its subject more specifically than a short one.
    def question_terms(question)
      prose = question_prose(question).downcase
      words = prose.scan(/[[:alpha:]][[:alpha:]'-]*/)
                   .flat_map { |word| word.split(/['-]/) }
                   .reject { |word| word.length < MIN_TERM_LENGTH || STOPWORDS.include?(word) }
                   .uniq
      aliases = CROSS_LANGUAGE_CONCEPTS.select { |concept| concept.intersect?(words) }.flatten
      aliases += CONSUMER_REMEDY_CONCEPTS.select { |concept| concept.intersect?(words) }.flatten if prose.match?(CONSUMER_REMEDY_CONTEXT)
      (words + aliases).uniq.map do |word|
        stem = word[0, [word.length - STEM_TRIM, MIN_STEM_LENGTH].max]
        { stem: stem, weight: stem.length >= SPECIFIC_STEM_LENGTH ? 2 : 1 }
      end
    end

    def question_prose(question)
      question.to_s.gsub(/```.*?```/m, ' ')
              .gsub(/^\s*>.*$/, ' ')
              .gsub(/`[^`\n]*`/, ' ')
              .gsub(/"(?:\\.|[^"\\])*"|“[^”]*”|«[^»]*»/m, ' ')
              .gsub(%r{https?://\S+}, ' ')
    end

    # A refund/reduction question needs the grounds AND their exception, not
    # just a high-scoring entitlement heading. Keep a complete remedy-cases
    # paragraph as one selection group when it fits. The adjacent reduction
    # formula is another group. No article number or paragraph number is
    # assumed, and no partial group can displace its limiting conditions.
    def consumer_remedy_groups(units, question)
      prose = question_prose(question).downcase
      return [] unless prose.match?(CONSUMER_REMEDY_CONTEXT)

      words = prose.scan(/[[:alpha:]]+/)
      return [] unless CONSUMER_REMEDY_CONCEPTS.last(2).any? { |concept| concept.intersect?(words) }

      start = units.index do |unit|
        unit.match?(STATUTORY_PARAGRAPH) && unit.match?(PRICE_REDUCTION) &&
          unit.match?(CONTRACT_TERMINATION) && unit.match?(REMEDY_CASES)
      end
      return [] unless start

      finish = ((start + 1)...units.size).find { |index| units[index].match?(STATUTORY_PARAGRAPH) } || units.size
      groups = [(start...finish).to_a]
      groups << [finish] if finish < units.size && units[finish].match?(PRICE_REDUCTION)
      paragraph_starts = units.each_index.select { |index| units[index].match?(STATUTORY_PARAGRAPH) }
      terms = question_terms(question)
      other_groups = paragraph_starts.filter_map do |paragraph_start|
        next if groups.any? { |group| group.include?(paragraph_start) }

        paragraph_finish = paragraph_starts.find { |index| index > paragraph_start } || units.size
        group = (paragraph_start...paragraph_finish).to_a
        relevance = group.sum { |index| score(units[index], terms) }
        [relevance, paragraph_start, group] if relevance.positive?
      end
      groups.concat(other_groups.sort_by { |relevance, index, _group| [-relevance, index] }.map(&:last))
      groups
    end

    def score(unit, terms)
      haystack = unit.downcase
      terms.sum { |term| haystack.include?(term[:stem]) ? term[:weight] : 0 }
    end

    # Reserve a complete opening applicability list before its procedural
    # matches can consume the budget. Only explicit leads already inside
    # the ordinary head qualify: this must not become another global head
    # expansion that displaces a late, question-specific provision. The
    # next numbered paragraph bounds the list, including unnumbered closing
    # qualifications. Oversized groups leave ordinary selection unchanged.
    def applicability_groups(units)
      head_indexes(units).filter_map do |index|
        next unless units[index].match?(APPLICABILITY_LEAD) && units[index + 1]&.match?(APPLICABILITY_ITEM)

        start = index.positive? && units[index - 1].match?(/\A(?:§[[:space:]]*)?\d+\.\z/) ? index - 1 : index
        finish = ((index + 1)...units.size).find { |candidate| units[candidate].match?(NUMBERED_PARAGRAPH) } || units.size
        (start...finish).to_a
      end
    end

    # The head of the old head cut: the opening units up to HEAD_CHARS.
    def head_indexes(units)
      indexes = []
      used = 0
      units.each_with_index do |unit, index|
        break if index.positive? && used + unit.length > HEAD_CHARS

        indexes << index
        used += unit.length + 1
      end
      indexes
    end

    # The head when the question matches: the opening line, and the lines
    # after it only while the head is still shorter than a sentence.
    def matched_head_indexes(units)
      indexes = [0]
      used = units[0].length
      units.each_with_index do |unit, index|
        next if index.zero?
        break if used >= MATCHED_HEAD_CHARS
        break if used + unit.length + 1 > MATCHED_HEAD_CHARS

        indexes << index
        used += unit.length + 1
      end
      indexes
    end

    # A collapsed line without any safe sentence/item boundary still has
    # exact source spans. Keep a small opening and a bounded word-boundary
    # window around a late match, explicitly marking both omitted intervals.
    # No words or punctuation are reconstructed, and an unmatched question
    # retains the ordinary head cut.
    def single_line_window(text, terms, max_chars)
      head_length = [MATCHED_HEAD_CHARS, max_chars / 4].min
      window_length = max_chars - head_length - (ELISION.length * 2)
      return text[0, max_chars] unless window_length.positive?

      haystack = text.downcase
      positions = terms.filter_map { |term| haystack.index(term[:stem], max_chars) }
      return text[0, max_chars] if positions.empty?

      position = positions.max_by do |candidate|
        score(text[[candidate - (window_length / 3), head_length].max, window_length], terms)
      end
      start = [position - (window_length / 3), head_length].max
      start += 1 while start < position && !text[start - 1].match?(/[[:space:]]/)
      finish = [start + window_length, text.length].min
      finish -= 1 while finish > position && finish < text.length && !text[finish].match?(/[[:space:]]/)
      return text[0, max_chars] unless finish > position

      head = text[0, head_length].rstrip
      window = text[start...finish].strip
      tail = finish < text.length ? ELISION : ''
      "#{head}#{ELISION}#{window}#{tail}"
    end

    def joined_length(units, indexes)
      indexes.sum { |index| units[index].length + 1 }
    end

    # Matching units outside the head, best first, earliest first on a tie.
    # The head here is the old head cut's, so a match inside the opening
    # thousand characters still counts as a match (it is kept either way).
    def scored_matches(units, terms, head)
      units.each_index
           .reject { |index| head.include?(index) }
           .map { |index| [score(units[index], terms), index] }
           .select { |score, _index| score.positive? }
           .sort_by { |score, index| [-score, index] }
    end

    # The units on either side of the matched ones, nearest first, so a lid
    # arrives with the lid that introduces it. Neighbours of the matches only:
    # the opening line's neighbour is the list the matches were chosen over.
    def neighbours(units, matched)
      [-1, 1, -2, 2].flat_map do |offset|
        matched.sort.map { |index| index + offset }
      end.grep(0..(units.size - 1)).uniq - matched
    end

    # Adds the candidate units that fit, in the order given; each costs its
    # length plus the reserve for an elision marker beside it.
    def add_units(units, selected, budget, candidates, reserve:)
      candidates.each do |index|
        next if selected.include?(index)

        cost = units[index].length + reserve
        next if cost > budget

        selected << index
        budget -= cost
      end
      budget
    end

    # What the head cut would have shown next: the units after the head, in
    # order, until the budget runs out. The unit the budget ends in is kept in
    # part, as the head cut kept it, but only when it is the last unit of the
    # excerpt: a fragment cut mid-sentence belongs at the end, never between
    # two whole provisions.
    def fill_forward(units, selected, budget)
      partial = {}
      units.each_index do |index|
        next if selected.include?(index)

        cost = units[index].length + 1
        if cost <= budget
          selected << index
          budget -= cost
        elsif budget > ELISION.length * 2 && index > selected.max
          partial[index] = budget - 1
          selected << index
          break
        else
          break
        end
      end
      partial
    end

    def render(units, indexes, partial, max_chars)
      out = +''
      previous = nil
      indexes.each do |index|
        out << separator(previous, index)
        unit = units[index]
        out << (partial.key?(index) ? unit[0, partial[index]] : unit)
        previous = index
      end
      out << ELISION if previous && previous < units.size - 1
      out.length > max_chars ? out[0, max_chars] : out
    end

    def separator(previous, index)
      return '' if previous.nil?

      index == previous + 1 ? "\n" : ELISION
    end
  end
end
