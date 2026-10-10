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

      units = split_units(text)
      terms = question_terms(question)
      return text[0, max_chars] if units.size < 2 || terms.empty?

      matches = scored_matches(units, terms, head_indexes(units))
      return text[0, max_chars] if matches.empty?

      selected = matched_head_indexes(units)
      budget = max_chars - joined_length(units, selected) - ELISION.length
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
      words = question.to_s.downcase.scan(/[[:alpha:]][[:alpha:]'-]*/)
                      .flat_map { |word| word.split(/['-]/) }
                      .reject { |word| word.length < MIN_TERM_LENGTH || STOPWORDS.include?(word) }
                      .uniq
      words.map do |word|
        stem = word[0, [word.length - STEM_TRIM, MIN_STEM_LENGTH].max]
        { stem: stem, weight: stem.length >= SPECIFIC_STEM_LENGTH ? 2 : 1 }
      end
    end

    def score(unit, terms)
      haystack = unit.downcase
      terms.sum { |term| haystack.include?(term[:stem]) ? term[:weight] : 0 }
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

        indexes << index
        used += unit.length + 1
      end
      indexes
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
