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

    # Consolidated codes whose WHOLE text is enacted and published but applies
    # only from a later date, while their rows carry no marker, variant or
    # dated title (unlike Book 9, whose corpus title carries "(Inwerkingtreding
    # 1-1-2026)"). A sourced, dated fallback: each entry names its official
    # commencement and stops applying on that day by itself; nothing is
    # deleted from the corpus, and the website keeps showing the text.
    LAW_COMMENCEMENTS = {
      # Civil Code Book 7 "Bijzondere contracten" / "Les contrats spéciaux",
      # inserted by art. 2 of the Act of 22 July 2026 (B.S. 23 September 2026,
      # https://www.ejustice.just.fgov.be/eli/wet/2026/07/22/2026005775/justel).
      # Its art. 50: ordinary commencement on the first day of the twelfth month
      # after the publication month, 1 September 2027. Arts. 6, 8, 11, 14 and 15
      # of that Act take effect earlier; they amend other acts and are not Book 7
      # text, so they are not covered here. Found 2026-10-19: catalogue items
      # july-280 and july-284 were answered from Book 7 art. 7.3.23 and 7.3.18
      # as if in force.
      '2026A05775' => Date.new(2027, 9, 1)
    }.freeze

    # Justel's consolidation lags behind commencement, in both directions (measured read-only on the
    # production corpus, 2026-11-20). Of 3,102 rows filed as future law, 1,144 named only commencement
    # dates that had passed. For 652 of them the plain row is older (fewer footnotes, an earlier newest
    # commencement), so it still held the text the amendment replaced: the road traffic law's Art. 33,
    # "Inwerkingtreding : 01-09-2026", answered with the superseded penalties (Sol #2058). 362 have no
    # plain row at all. 70 carry the same footnotes as their plain row and 60 are older than it: those stay
    # future law. And 206 ordinary rows were inserted with an undetermined commencement: "Art. 65ter.
    # <Ingevoegd bij W 2003-02-07/38, art. 31; Inwerkingtreding : onbepaald >" (Sol #2231); a note such as
    # "indéterminée et au plus tard : 01-07-2007" counts its last day.
    COMMENCEMENT_NOTE = /(?:Inwerkingtreding|En[[:blank:]]+vigueur)[[:blank:]]*:[[:blank:]]*([^>;\n]*)/i
    COMMENCEMENT_DATE = /\A[[:blank:]]*(\d{1,2})-(\d{1,2})-(\d{4})/
    LATEST_DATE = /(?:uiterlijk(?:[[:blank:]]+op)?|au[[:blank:]]+plus[[:blank:]]+tard)[[:blank:]]*:?[[:blank:]]*(\d{1,2})-(\d{1,2})-(\d{4})/i
    # "(5)<W 2026-05-25/12, art. 13, 063; Inwerkingtreding : 01-09-2026>"
    FOOTNOTE = /^[[:blank:]]*\((\d+)\)[[:blank:]]*<([^>]*)>/
    # The note right after an article's heading: "Art. 65ter. <Ingevoegd bij ...>".
    HEAD_NOTE = /\A[[:space:]]*Art[^<\n]{0,40}<([^>]*)>/i
    INSERTION = /\A[[:blank:]]*(?:Ingevoegd[[:blank:]]+bij|Ins[ée]r[ée]e?[[:blank:]]+par)/i
    HEADING_MARKER = /\A([^\n]*?)[[:blank:]_]*(?:TOEKOMSTIG[[:blank:]_]+RECHT|DROIT[[:blank:]_]+FUTUR)(?![[:alpha:]])/
    # Every observed title shape: "Art.33 TOEKOMSTIG RECHT", "Art. 2/6 DROIT FUTUR.", "Art.2_33/11.DROIT_FUTUR",
    # "Art.12/3_REGION_FLAMANDE_ DROIT FUTUR".
    TITLE_SUFFIX = /[[:blank:]_]*(?:TOEKOMSTIG[[:blank:]_.\-]*RECHT|DROIT[[:blank:]_.\-]*FUTUR)(?![[:alpha:]]).*\z/i

    # A commenced version standing in for its plain row in the verified-fact channel.
    CommencedVersion = Struct.new(:article_title, :article_text, :content_numac, :commenced_on, keyword_init: true) do
      def article_variant = nil
    end

    module_function

    # The commencement of a whole consolidated code listed above, else nil.
    def law_commencement(numac)
      LAW_COMMENCEMENTS[numac.to_s]
    end

    def law_future?(numac, as_of: Date.current)
      commencement = law_commencement(numac)
      !commencement.nil? && as_of < commencement
    end

    def variant_future?(variant)
      FUTURE_VARIANTS.include?(variant.to_s.strip.upcase)
    end

    def title_future?(title)
      TITLE_MARKER.match?(title.to_s)
    end

    # The classifier. A row is future law when its whole code has not commenced
    # (LAW_COMMENCEMENTS), or its variant or title says so and, given its text,
    # its commencement has not passed (commenced_on). Without a text the variant
    # and title decide, as before.
    def row_future?(variant: nil, title: nil, numac: nil, text: nil, as_of: Date.current)
      return true if law_future?(numac, as_of: as_of)
      return false unless variant_future?(variant) || title_future?(title)

      text.nil? || commenced_on(text, as_of: as_of).nil?
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

    # Every commencement note in a text: a Date (the note's own date, or the last day of "uiterlijk op" /
    # "au plus tard"), or :undetermined when it names neither.
    def commencements(text)
      text.to_s.scan(COMMENCEMENT_NOTE).map do |(note)|
        match = COMMENCEMENT_DATE.match(note) || LATEST_DATE.match(note)
        next :undetermined unless match

        begin
          Date.new(match[3].to_i, match[2].to_i, match[1].to_i)
        rescue Date::Error
          :undetermined
        end
      end
    end

    # The highest-numbered footnote, [number, body], or nil.
    def newest_footnote(text)
      text.to_s.scan(FOOTNOTE).max_by { |number, _| number.to_i }
    end

    def newest_footnote_number(text)
      newest_footnote(text)&.first.to_i
    end

    # The day a row filed as future law took effect: every commencement it names has passed, none is
    # undetermined, its newest footnote is dated, and a date in its marker ("TOEKOMSTIG RECHT (vanaf
    # 01.01.2028)") has passed. Else nil: the row is still future law.
    def commenced_on(text, as_of: Date.current)
      notes = commencements(text)
      return nil if notes.empty? || notes.include?(:undetermined) || notes.any? { |day| day > as_of }

      newest = newest_footnote(text)
      return nil unless newest && commencements(newest.last).first.is_a?(Date)

      marker = marker_date(text)
      return nil if effective_date(text) && (marker.nil? || marker > as_of)

      notes.max
    end

    # The marker's own date as a Date, else nil.
    def marker_date(text)
      raw = effective_date(text)
      return nil unless raw

      day, month, year = raw.split(%r{[.\-/]}).map(&:to_i)
      year += 2000 if year < 100
      Date.new(year, month, day)
    rescue ArgumentError # Date::Error included
      nil
    end

    # A commenced version replaces its plain row only when it is newer: more footnotes, and a commencement
    # not older than the plain row's newest. Otherwise it is a stale copy and stays future law.
    def newer_than_plain?(future_text, plain_text, day)
      return false if newest_footnote_number(future_text) <= newest_footnote_number(plain_text)

      plain_days = commencements(plain_text).grep(Date)
      plain_days.empty? || day >= plain_days.max
    end

    # An ordinary row whose own head note inserts it with an undetermined commencement and no last day.
    def uncommenced_insertion?(text)
      note = HEAD_NOTE.match(text.to_s)&.captures&.first
      return false unless note&.match?(INSERTION)

      commencements(note) == [:undetermined]
    end

    # "Art.33 TOEKOMSTIG RECHT" -> "Art.33": the plain row's title.
    def base_title(title)
      title.to_s.sub(TITLE_SUFFIX, '').strip
    end

    # A title compared without its spaces, dots or case: "Art. 56" is the plain row "Art.56".
    def title_key(title)
      title.to_s.delete(' .').downcase
    end

    # The heading without its marker: "Art. 33 TOEKOMSTIG RECHT. " -> "Art. 33. "
    def without_heading_marker(text)
      text.to_s.sub(HEADING_MARKER, '\1')
    end

    # What a "rule today" answer uses from one body: [text, the day a commenced future block took effect,
    # the pending future block]. A future block whose commencement has passed is the text in force.
    def in_force_text(text, as_of: Date.current)
      in_force, future_block = split(text)
      return [in_force, nil, future_block] unless future_block

      day = commenced_on(future_block, as_of: as_of)
      return [in_force, nil, future_block] unless day

      current, = split(without_heading_marker(future_block))
      [current.to_s.strip, day, nil]
    end

    # The rows of one law and language a verified fact may use. A commenced future version newer than its
    # plain row takes that row's place, one without a plain row stands in its own; a future row that has not
    # commenced, an insertion without a commencement and a listed code before its day are left out.
    def in_force_versions(rows, as_of: Date.current)
      rows = Array(rows)
      future, plain = rows.partition { |row| variant_future?(row.try(:article_variant)) || title_future?(row.article_title) }
      plain_by_key = plain.to_h { |row| [title_key(row.article_title), row] }
      replacements = {}
      extra = []
      future.each do |row|
        next if law_future?(row.try(:content_numac), as_of: as_of)

        day = commenced_on(row.article_text, as_of: as_of)
        next unless day

        base = base_title(row.article_title)
        version = CommencedVersion.new(article_title: base, article_text: without_heading_marker(row.article_text),
                                       content_numac: row.try(:content_numac), commenced_on: day)
        own = plain_by_key[title_key(base)]
        if own.nil?
          extra << version
        elsif newer_than_plain?(row.article_text, own.article_text, day)
          replacements[own] = version
        end
      end
      kept = plain.filter_map do |row|
        next if law_future?(row.try(:content_numac), as_of: as_of) || uncommenced_insertion?(row.article_text)

        replacements.fetch(row, row)
      end
      kept + extra
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
