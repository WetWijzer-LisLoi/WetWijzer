# frozen_string_literal: true

module LegalChatbot
  # #221 (Sol 2026-11-24 20:05:56Z): Justel marks the words a later act inserted or replaced with numbered brackets,
  # "maximaal [4 650 uur]4", and the marker's digit touches the text: the model read "4 650 uur" and answered
  # 4,650 hours of student work where Art. 14, § 2, 1° of 2018014824 says 650. The model's text drops each balanced
  # pair (LegalChatbotService#article_context_text); the stored article, the source card and the quote guard's source
  # stay whole, and the guard reads a marker as a space (AnswerGuards, normalized quotation tokens), so a quotation of
  # the clean text still verifies.
  #
  # A balanced pair: "[N" followed by a space (or, written without one, by a letter), the words, then "]N" with the
  # same N and no digit after it; nested pairs go from the inside out. A space stays where a marker was glued to a word
  # ("Art. 1385/1[1 § 1." keeps "1385/1 § 1.", "gewezen]1kan" keeps "gewezen kan"), never after an opening bracket or
  # quote ("([1 Onder" gives "(Onder"). An unbalanced marker, a footnote "[1]", an item "[1°]", an article number
  # "[59.19." and the malformed "[ 5" stay as they are.
  #
  # Validated read-only on 396 amended articles of five laws, 276 Dutch and 120 French (2026-11-24 23:39-23:48Z): no
  # character but the markers lost, no words glued or split, no balanced pair left.
  #
  # Sol 2026-11-25 02:51:39Z: the opening marker may be followed by any space, a no-break space or a line break
  # included; a pair whose words hold markers that do not balance among themselves ("[1 a [2 b]1 c]2", a crossing) is
  # ambiguous and stays as stored.
  module AmendmentMarkers
    PAIR = /\[(?<n>\d{1,3})(?:[[:space:]]|(?=[[:alpha:]]))(?<words>(?:(?!\[\k<n>(?:[[:space:]]|[[:alpha:]])).)*?)\]\k<n>(?!\d)/m
    OPENING = /\[(\d{1,3})(?:[[:space:]]|(?=[[:alpha:]]))/
    CLOSING = /\](\d{1,3})(?!\d)/
    NO_SPACE_AFTER = /[[:space:](\[{"'«„“‘]/
    WORD_CHARACTER = /[[:alnum:]]/
    # Nesting deeper than this does not occur in the corpus; the loop also stops as soon as a pass changes nothing.
    MAX_PASSES = 20

    module_function

    def strip(text)
      current = text.to_s
      return current unless current.include?('[')

      MAX_PASSES.times do
        source = current
        stripped = source.gsub(PAIR) do
          match = Regexp.last_match
          next match[0] unless balanced?(match[:words])

          start = match.begin(0)
          lead = start.zero? || source[start - 1].match?(NO_SPACE_AFTER) ? '' : ' '
          tail = source[match.end(0)].to_s.match?(WORD_CHARACTER) ? ' ' : ''
          "#{lead}#{match[:words]}#{tail}"
        end
        return stripped if stripped == source

        current = stripped
      end
      current
    end

    # The markers inside a pair's words pair off among themselves, each closing marker after its own opening one (nested
    # pairs do; a crossing does not, nor a closing marker before its opening, "[1 650]2 x [2 y]1", Sol 04:13:27Z)
    def balanced?(words)
      open = []
      words.scan(/#{OPENING}|#{CLOSING}/) do |opening, closing|
        if opening
          open.push(opening)
        elsif open.pop != closing
          return false
        end
      end
      open.empty?
    end
  end
end
