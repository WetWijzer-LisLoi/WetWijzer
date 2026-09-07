# frozen_string_literal: true

module LegalChatbot
  # Future law: text that is ENACTED BUT NOT YET IN FORCE. Belgian consolidated law
  # carries it inline, headed "TOEKOMSTIG RECHT" / "DROIT FUTUR".
  #
  # The website has always rendered it correctly. The chatbot never looked at it, and the
  # consequences compound rather than stay contained:
  #
  #   - 2,373 rows ARE future law outright (article_variant TOEKOMSTIG/FUTUR, all real
  #     articles, zero LNK). Nothing filtered them, so the chatbot could quote a rule that
  #     does not apply yet as the rule that does.
  #   - normalize_article_number (text_processing.rb) already strips the marker from an
  #     article number, so such a row collapses onto the IN-FORCE article's anchor and
  #     citation-repair key. The two are indistinguishable downstream.
  #   - validate_answer_quotes verifies a blockquote by verbatim presence in the source
  #     text, so a quote lifted from a future row ships stamped quotes_verified.
  #     The guard vouches for it.
  #   - 405 further rows are IN-FORCE articles with a future block concatenated onto the
  #     end of the same text (201 NL + 204 FR, measured text-level, not by FTS - 59 FTS
  #     hits carry no marker at all). Plus 87 NL / 88 FR in the tax corpus, which has no
  #     variant column, so there the text is the only signal there has ever been.
  #
  # Detection is deliberately split in two, because neither test alone is sufficient.
  # A row whose title lost its second word is invisible to the title rule but was stored
  # correctly by the ingester's variant detection; and a row titled
  # "Art.39_VLAAMS_GEWEST TOEKOMSTIG RECHT" is filed under VLAAMS_GEWEST, because the
  # ingester returns on the first marker it recognises, so the column call it future.
  # The classifier ORs them.
  #
  # Every pattern here matches the MARKER, never the bare word. "een toekomstig recht op
  # een onroerend goed", "de toekomstige echtgenoten" and "de tegenwoordige en toekomstige
  # roerende goederen" are ordinary legal prose and appear in the corpus.
  module FutureLaw
    # The values the ingester writes. Regional markers win over these when a title
    # carries both, which is why the body and title rules still have to run.
    FUTURE_VARIANTS = %w[TOEKOMSTIG FUTUR].freeze

    # NULL-safe ON PURPOSE. `where.not(article_variant: FUTURE_VARIANTS)` compiles to a
    # bare NOT IN, and in SQL `NULL NOT IN (...)` is NULL, not true - so it would discard
    # every row with no variant, which is 2.83 million of the 2.84 million we want to keep.
    SQL_NOT_FUTURE =
      "(articles.article_variant IS NULL OR articles.article_variant NOT IN ('TOEKOMSTIG', 'FUTUR'))"

    # `article_title` is a designation field, never prose, so this may be case-insensitive
    # and unanchored. No leading \b: it fails between "63_" and "TOEKOMSTIG" because both
    # are word characters. The separator class earns its keep by rejecting inflections for
    # free - "TOEKOMSTIGE RECHTEN" fails on the E, "DROITS FUTURS" on the S.
    TITLE_MARKER = /
      (?:\A|[^[:alpha:]])
      (?: toekomstig[[:blank:]_.\-]*recht | droit[[:blank:]_.\-]*futur )
      (?![[:alpha:]])
    /xi

    # Body text IS prose, so this one is case-SENSITIVE, line-anchored and heading-shaped.
    # In Ruby ^ is always a line anchor (/m only changes what . matches), so no flag.
    #
    # [[:blank:]] rather than \s throughout: Ruby's \s is ASCII-only and Justel emits
    # NBSP (U+00A0) and narrow NBSP (U+202F) around these markers, so \s misses them
    # outright. [[:blank:]] also excludes \n, which is what stops the two marker words
    # matching across a line break.
    #
    # The no-lowercase run makes it heading-only and covers "AFDELING II. - TOEKOMSTIG
    # RECHT" and "[TOEKOMSTIG RECHT]"; the optional article prefix covers
    # "Art. 3. TOEKOMSTIG RECHT", which the no-lowercase rule alone would reject on "rt".
    BLOCK_MARKER = /
      ^
      (?:[[:blank:]]*(?i:art(?:ikel|icle)?s?)\.?[[:blank:]]*[[:alnum:]][\w.\/:\-]{0,24}[.,]?)?
      [^\n[:lower:]]{0,60}?
      (?: TOEKOMSTIG[[:blank:]_]+RECHT | DROIT[[:blank:]_]+FUTUR )
      (?![[:alpha:]])
    /x

    # About a third of markers name the day the text takes effect, as
    # "TOEKOMSTIG RECHT (vanaf 01.01.2028)". Worth keeping: "in force from 01.01.2028" is
    # a materially better answer than "not yet in force", and it is already on the page.
    EFFECTIVE_DATE = /
      (?: TOEKOMSTIG[[:blank:]_]+RECHT | DROIT[[:blank:]_]+FUTUR )
      [[:blank:]]*\(
      [^)\n]*?
      (\d{1,2}[.\-\/]\d{1,2}[.\-\/]\d{2,4})
      [^)\n]*
      \)
    /x

    module_function

    def variant_future?(variant)
      FUTURE_VARIANTS.include?(variant.to_s.strip.upcase)
    end

    def title_future?(title)
      TITLE_MARKER.match?(title.to_s)
    end

    # The classifier. A row is future law when EITHER signal says so.
    def row_future?(variant: nil, title: nil)
      variant_future?(variant) || title_future?(title)
    end

    # Does this body carry a future-law block at all?
    def marker?(text)
      BLOCK_MARKER.match?(text.to_s)
    end

    # Cut a body into [in_force, future]. Splits at the FIRST marker: everything from it
    # onward is the not-yet-applicable text, and Justel emits current-then-future in
    # document order.
    #
    # in_force is nil when the marker opens the text, i.e. the whole row is future law.
    # future is nil when there is no marker, i.e. the row is entirely in force.
    #
    # It splits at the first marker even when several are present (22 of 200 NL rows).
    # Those turned out to be triplicated blobs where the same content repeats behind each
    # marker, so taking the first cut loses nothing a later one would have kept.
    def split(text)
      body = text.to_s
      match = BLOCK_MARKER.match(body)
      return [body, nil] unless match

      before = trim_dangling_brackets(body[0...match.begin(0)])
      [before.empty? ? nil : before, body[match.begin(0)..].strip]
    end

    # The part a "what is the rule today" answer is allowed to see.
    def in_force(text)
      split(text).first
    end

    # One real shape opens the future block with a bare "[" on the line ABOVE the marker,
    # so cutting at the marker alone leaves an orphan bracket hanging off the in-force
    # text. A line holding nothing but brackets carries no legal content, so dropping it
    # cannot lose a rule.
    def trim_dangling_brackets(text)
      # rstrip FIRST: the cut lands at the start of the marker's line, so what precedes it
      # ends in a newline and an end-anchored pattern would never fire.
      text.rstrip.sub(/(?:\n[[:blank:]]*[\[\]]+[[:blank:]]*)+\z/, '').rstrip
    end

    # "01.01.2028" when the marker names its own commencement, else nil.
    def effective_date(text)
      EFFECTIVE_DATE.match(text.to_s)&.captures&.first
    end

    # Same defensive shape as fisconet_region_columns?: a database predating the column is
    # a legitimate state, and naming a missing column would raise inside the retrieval
    # path, where the rescue turns any error into a silent no-facts answer.
    def variant_column?
      return @variant_column unless @variant_column.nil?

      @variant_column = begin
        defined?(::Article) && ::Article.column_names.include?('article_variant')
      rescue StandardError
        false
      end
    end

    # Degrades to a no-op predicate rather than raising when the column is absent.
    def sql_not_future
      variant_column? ? SQL_NOT_FUTURE : '1=1'
    end

    def reset_column_probe!
      @variant_column = nil
    end
  end
end
