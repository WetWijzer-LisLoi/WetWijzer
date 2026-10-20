# frozen_string_literal: true

require 'date'

module LegalChatbot
  # Shared reading for the r47 semantic checks (root 2026-10-19 23:27:12 and
  # 23:36:18). Three rules:
  # - the governing unit is a RETAINED Belgian legislation row (the admitted
  #   pool the guard chain receives, never a search union, never a guidance,
  #   EU, tax or regional record that copies a NUMAC) whose own text carries
  #   every evidence string a check relies on;
  # - a claim is read in its own main clause: a semicolon or a contrastive
  #   coordinator starts a new one, a comma or a colon never cuts a governing
  #   negation or condition away;
  # - a historical reading needs an explicit as-of frame (a month and year, a
  #   full date, a closed period), never a stray year or "vanaf 2022".
  # Nothing here logs answer text.
  module GroundingScope
    module_function

    BLOCKQUOTE_LINE = /\A\s*(?:(?:[-*+]|\d{1,2}[.)])\s+)?>/
    BLOCKQUOTE_PREFIX = /\A\s*(?:(?:[-*+]|\d{1,2}[.)])\s+)?>\s?/
    HEADING_LINE = /\A\s*(?:\#{1,6}\s+\S.*|\*\*[^*\n]+\*\*\s*:?|__[^_\n]+__\s*:?)\s*\z/
    EMPHASIS = /(\*\*|__|\*|_)(?=\S)(.+?)(?<=\S)\1/
    SENTENCE_SPLIT = /(?<=[.!?])\s+(?=[[:upper:]"'“«(\[])/
    MAIN_CLAUSE_BOUNDARY = /;|\s(?:maar|doch|echter|mais|cependant|toutefois|but|however|aber|jedoch)\s/i
    # A correction at the start of a sentence governs the whole sentence.
    CORRECTION_PREFIX = /\A\s*(?:[-*+]\s+)?(?:niet\s+juist|onjuist|fout|incorrect|faux|pas\s+exact|not\s+true|untrue|false|wrong|falsch|nicht\s+richtig)\s*[:!]/i
    # A denial inside the claim's own clause.
    CLAUSE_DENIAL = /\b(?:het\s+is\s+niet\s+(?:juist|waar|zo|correct)\s+dat|het\s+klopt\s+niet\s+dat|il\s+n['’]est\s+pas\s+(?:vrai|exact|correct|juste)\s+que|ce\s+n['’]est\s+pas\s+(?:vrai|exact)\s+que|it\s+is\s+not\s+(?:true|correct|the\s+case)\s+that|es\s+ist\s+nicht\s+(?:richtig|wahr|zutreffend),?\s+dass|is\s+niet\s+(?:juist|correct|waar)|klopt\s+niet|is\s+onjuist|n['’]est\s+pas\s+(?:exact|correct|vrai)|est\s+faux|is\s+(?:not\s+(?:true|correct)|incorrect|wrong)|ist\s+(?:nicht\s+richtig|falsch))\b/i

    MONTHS = {
      'januari' => 1, 'janvier' => 1, 'january' => 1, 'januar' => 1,
      'februari' => 2, 'février' => 2, 'fevrier' => 2, 'february' => 2, 'februar' => 2,
      'maart' => 3, 'mars' => 3, 'march' => 3, 'märz' => 3, 'maerz' => 3,
      'april' => 4, 'avril' => 4,
      'mei' => 5, 'mai' => 5, 'may' => 5,
      'juni' => 6, 'juin' => 6, 'june' => 6,
      'juli' => 7, 'juillet' => 7, 'july' => 7,
      'augustus' => 8, 'août' => 8, 'aout' => 8, 'august' => 8,
      'september' => 9, 'septembre' => 9,
      'oktober' => 10, 'octobre' => 10, 'october' => 10,
      'november' => 11, 'novembre' => 11,
      'december' => 12, 'décembre' => 12, 'decembre' => 12, 'dezember' => 12
    }.freeze
    MONTH_ALTERNATION = MONTHS.keys.sort_by { |name| -name.length }.map { |name| Regexp.escape(name) }.join('|')
    # Temporal prepositions of an as-of frame. Open starts (vanaf, sinds,
    # depuis, since, seit, from) are no frame: "vanaf 2022 geldt nog steeds".
    BEFORE_PREPOSITIONS = %w[vóór voor tot avant jusqu'au jusqu’au before until till vor bis].freeze
    FRAME_PREPOSITIONS = '(?:in|op|per|tijdens|rond|vóór|voor|tot|en|au|le|début|fin|avant|jusqu[\'’]au|on|as\s+of|during|before|until|till|im|am|zum|vor|bis(?:\s+zum)?)'
    TEXT_FRAME = /(?<!\p{L})(#{FRAME_PREPOSITIONS})\s+(?:(\d{1,2})(?:er|e|\.)?\s+)?(#{MONTH_ALTERNATION})\s+(\d{4})\b/i
    NUMERIC_FRAME = %r{(?<!\p{L})(#{FRAME_PREPOSITIONS})\s+(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})\b}i
    # A date that only says when a document was signed or issued is no
    # as-of frame of the question: "in november 2022 getekend".
    SIGNING = /\b(?:getekend|ondertekend|gesloten|afgesloten|afgegeven|uitgereikt|aangegaan|sign[ée]\p{L}*|conclu\p{L}*|délivr\p{L}*|signed|concluded|entered\s+into|issued|unterschrieben|abgeschlossen|ausgestellt)\b/i
    PRESENT = /\b(?:nu|vandaag|momenteel|actueel|thans|tegenwoordig|maintenant|aujourd['’]hui|actuellement|now|today|currently|at\s+present|jetzt|heute|derzeit|aktuell)\b/i
    HISTORICAL_HEADING = /\b(?:historisch\p{L}*|vroeger\p{L}*|voorheen|destijds|voormalig\p{L}*|oude\s+regel\p{L}*|historique\p{L}*|ancien\p{L}*|antérieur\p{L}*|historical|former|previous|earlier\s+rule|früher\p{L}*|ehemalig\p{L}*|bisherig\p{L}*)\b/i
    EARLIEST = Date.new(1900, 1, 1)
    LATEST = Date.new(9999, 12, 31)

    def normalize(text)
      text.to_s.unicode_normalize(:nfkc).tr('’‘`', "'").tr('“”«»„', '"').gsub(/[[:space:]]+/, ' ').strip
    end

    def unit_number(title)
      title.to_s.sub(/\A\s*art(?:ikel|icle)?\s*\.?\s*/i, '').delete(' ').sub(/\.\z/, '').downcase
    end

    # Retained Belgian legislation rows of one unit whose own text carries
    # every evidence string of its language (normalized spacing and quotes).
    def evidenced_units(sources, numac:, article:, evidence:)
      Array(sources).select do |row|
        legislation_row?(row) && row[:numac].to_s == numac &&
          unit_number(row[:article_title]) == unit_number(article) && evidence?(row, evidence)
      end
    end

    # LegislationSearch rows carry no :source; a guidance, EU, tax or regional
    # record does, or carries its own identity keys.
    def legislation_row?(row)
      row.is_a?(Hash) && row[:source].nil? && !row.key?(:celex) && !row.key?(:authority) &&
        !row.key?(:document_type) && row[:numac].is_a?(String) && row[:article_text].is_a?(String) &&
        [1, 2].include?(row[:language_id]) && row[:article_variant].to_s.empty? && row[:is_abolished] != true
    end

    def evidence?(row, evidence)
      needles = evidence[row[:language_id] == 2 ? :fr : :nl]
      return false if needles.nil? || needles.empty?

      text = normalize(row[:article_text]).downcase
      needles.all? { |needle| text.include?(normalize(needle).downcase) }
    end

    # The answer as sections in order: { heading:, lines: [{ text:, quote: }] }.
    # A heading is a markdown heading or a line that is bold as a whole.
    def sections(text)
      text.to_s.each_line.with_object([{ heading: '', lines: [] }]) do |raw, result|
        line = raw.chomp
        next if line.strip.empty?

        quote = line.match?(BLOCKQUOTE_LINE)
        if !quote && line.match?(HEADING_LINE)
          result << { heading: plain(line), lines: [] }
        else
          result.last[:lines] << { text: plain(quote ? line.sub(BLOCKQUOTE_PREFIX, '') : line), quote: quote }
        end
      end
    end

    def plain(line)
      normalize(line.gsub(EMPHASIS, '\2'))
    end

    def sentences(line)
      line.split(SENTENCE_SPLIT).map(&:strip).reject(&:empty?)
    end

    # [start, stop) of the main clause around a character index.
    def main_clause_bounds(sentence, index)
      start = 0
      sentence.to_enum(:scan, MAIN_CLAUSE_BOUNDARY).each do
        match = Regexp.last_match
        return [start, match.begin(0)] if match.begin(0) >= index

        start = match.end(0)
      end
      [start, sentence.length]
    end

    def main_clause(sentence, index)
      start, stop = main_clause_bounds(sentence, index)
      sentence[start...stop]
    end

    # The comma or colon segment around an index, inside its main clause:
    # used only to keep a neighbouring claim out of the match, never to cut
    # a negation away.
    def segment(sentence, index)
      start, stop = main_clause_bounds(sentence, index)
      clause = sentence[start...stop]
      local = index - start
      left = clause.rindex(/[,:]/, [local - 1, 0].max)
      right = clause.index(/[,:]/, local)
      clause[(left ? left + 1 : 0)...(right || clause.length)]
    end

    def denied?(sentence, clause)
      sentence.match?(CORRECTION_PREFIX) || clause.match?(CLAUSE_DENIAL)
    end

    # A quote is exempt only when every fragment of at least 15 characters is
    # the retained unit's own wording: an unsupported claim put between
    # quotation marks is still read.
    def verbatim_quote?(line, units)
      body = normalize(line).sub(/\s+[—–-]+\s+\[?(?:art(?:ikel|icle)?\.?|§).*\z/i, '').delete('"').downcase
      fragments = body.split(/\[?(?:\.\.\.|…)\]?/).map(&:strip).select { |fragment| fragment.length >= 15 }
      return false if fragments.empty?

      texts = units.map { |unit| normalize(unit[:article_text]).downcase }
      fragments.all? { |fragment| texts.any? { |text| text.include?(fragment) } }
    end

    # Explicit as-of frames of a text as [from, to] date ranges. A frame next
    # to a signing or issuing verb only dates a document, not the question.
    def frames(text)
      text = normalize(text)
      found = []
      [TEXT_FRAME, NUMERIC_FRAME].each do |pattern|
        text.to_enum(:scan, pattern).each do
          match = Regexp.last_match
          window = text[[match.begin(0) - 50, 0].max...[match.end(0) + 50, text.length].min]
          next if window.match?(SIGNING)

          range = frame_range(match, pattern == NUMERIC_FRAME)
          found << range if range
        end
      end
      found
    end

    # The question's own frames; a question about now ("nu", "today") has none.
    def question_frames(question)
      text = normalize(question)
      text.match?(PRESENT) ? [] : frames(text)
    end

    def frame_range(match, numeric)
      preposition = match[1].downcase.sub(/\s+zum\z/, '')
      if numeric
        day = match[2].to_i
        month = match[3].to_i
        year = match[4].to_i
      else
        day = match[2]&.to_i
        month = MONTHS.fetch(match[3].downcase)
        year = match[4].to_i
      end
      from = Date.new(year, month, day || 1)
      to = day ? from : Date.new(year, month, -1)
      BEFORE_PREPOSITIONS.include?(preposition) ? [EARLIEST, from - 1] : [from, to]
    rescue ArgumentError, KeyError
      nil
    end

    def overlaps?(range, from, to)
      range[0] <= to && range[1] >= from
    end

    # Section headings that frame their lines in the past: a historical word,
    # or a frame that ends before the given date.
    def historical_heading?(heading, before:)
      heading.match?(HISTORICAL_HEADING) || frames(heading).any? { |range| range[1] < before }
    end
  end
end
