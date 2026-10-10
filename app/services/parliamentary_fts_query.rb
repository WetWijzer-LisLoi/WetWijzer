# frozen_string_literal: true

# The FTS5 MATCH expression for what a reader typed into a parliamentary search.
#
# Every parliamentary search stripped punctuation and matched the words left,
# so an opinion number of the Council of State, "59.802", became the two tokens
# 59 and 802, anywhere in a document: measured on production 2026-09-26
# (docs/ops/old-opinion-covers-2026-09-26.md, section 2), 334 to 5,000 documents
# per cited opinion instead of the 1 to 36 that cite it. documents_fts uses the
# default unicode61 tokenizer, so the number the documents print, "59.802/VR",
# is the tokens 59, 802, vr side by side: a phrase finds exactly that.
#
# A word shaped like an opinion number (digits, a dot, three digits, and
# optionally a chamber: "44.539/4", "59.802/VR", "67.109/1/V") becomes the
# phrase of its NUMBER. The chamber is dropped: the number alone names the
# opinion, and the chamber is written in each language's own letters, so one
# opinion is cited as "44.539/AG" in the French documents and "44.539/AV" in
# the Dutch ones (measured); a phrase that kept it would find only one side.
# Every other word is matched as before.
module ParliamentaryFtsQuery
  OPINION_NUMBER = %r{\A(\d{1,3})\.(\d{3})(?:/[\p{L}\p{N}]{1,3}){0,2}\z}
  # Brackets, quotes and sentence punctuation around a cited number:
  # "(59.802/VR)," is still that number.
  EDGE_PUNCTUATION = /\A[^\p{L}\p{N}]+|[^\p{L}\p{N}]+\z/
  WORD = /[\p{L}\p{N}]+/

  module_function

  # @param query [String] what the reader typed
  # @param word [Regexp] what counts as a word everywhere else, as the caller
  #   has always split it
  # @param quote_words [Boolean] wrap each other word in double quotes, so a
  #   word such as NOT or NEAR is text rather than an FTS5 operator
  # @return [String] the MATCH expression; '' when nothing searchable is left
  def build(query, word: WORD, quote_words: false)
    # [[:space:]] is Unicode-aware: a no-break space separates words too.
    query.to_s.split(/[[:space:]]+/).flat_map do |token|
      number = OPINION_NUMBER.match(token.gsub(EDGE_PUNCTUATION, ''))
      next [%("#{number[1]} #{number[2]}")] if number

      words = token.scan(word)
      quote_words ? words.map { |w| %("#{w}") } : words
    end.join(' ')
  end
end
