# frozen_string_literal: true

module LegalChatbot
  # Numbers written as words, read as the numbers they stand for, for the
  # number checks of German answers v4 (to-do 7.5): a translation, in either
  # direction, must state the same figures, and a figure keeps its value
  # whether it is written "5", "cinq" or "fünf".
  #
  # The graded v3 run (docs/ops/german-answers-v3-eval-2026-09-29.md) found
  # the digits-only tally blind in both directions:
  #
  # - The question "Ich habe drei Kinder. Über welchen Teil ...?" became a
  #   statement without the three children (q20), and no check saw it,
  #   because "drei" is not a digit.
  # - "ich bin seit 2016 in der Firma" became "depuis deux mille seize" (q03),
  #   refused for the digit it lost although the year was still there.
  # - The incident's German answer was faithful and correct, and was refused
  #   because "5ᵉ année" became "fünfte" and "4 premières années" became
  #   "ersten vier" (incident t1 and t2).
  #
  # So cardinal and ordinal number words, and years spelled out, count as
  # their value, next to the digit runs (GermanAnswerTranslation.numbers).
  # Left out on purpose, because they are articles or other words far more
  # often than figures: "un", "une" and "ein" (any ending) on their own,
  # "neuf" meaning new, and "cent" in "pour cent". "beide" (both)
  # counts as two, as "les deux" does. A German ordinal counts before a
  # noun, a number or a range word, so "gegenüber Dritten" (third parties)
  # and the verb "achten" (to heed) are not figures.
  #
  # A German ordinal counts in lower case or capitalised ("Gericht Erster
  # Instanz", "Der Erste Präsident", "Erste Voraussetzung" opening a list
  # item), as French "première" and "premier" always do: counted in lower
  # case only, a faithful "tribunal de première instance" was a numbers
  # mismatch the retry could not repair. It also counts across one or two
  # adjectives after an article ("der erste volle Kalendermonat", as "le
  # premier mois civil complet"). Left out on both sides, because they
  # name no figure: "Premier ministre" (Premierminister), "en premier
  # lieu", "in erster Linie", "an erster Stelle", and "dritte Person",
  # "dritte Partei" or "dritter Staat" (tierce personne, État tiers).
  # French "second" and "seconde" count as two after an article and before
  # a word ("le second alinéa", "la seconde fois", as "der zweite Absatz"),
  # never as the unit of time ("une seconde", "30 secondes") nor in "en
  # second lieu" ("in zweiter Linie", "an zweiter Stelle" are left out too).
  module NumberWords
    FRENCH_UNITS = {
      'un' => 1, 'une' => 1, 'deux' => 2, 'trois' => 3, 'quatre' => 4, 'cinq' => 5, 'six' => 6, 'sept' => 7,
      'huit' => 8, 'neuf' => 9, 'dix' => 10, 'onze' => 11, 'douze' => 12, 'treize' => 13, 'quatorze' => 14,
      'quinze' => 15, 'seize' => 16
    }.freeze
    FRENCH_TENS = {
      'vingt' => 20, 'vingts' => 20, 'trente' => 30, 'quarante' => 40, 'cinquante' => 50, 'soixante' => 60,
      'septante' => 70, 'octante' => 80, 'huitante' => 80, 'nonante' => 90
    }.freeze
    FRENCH_HUNDREDS = %w[cent cents].freeze
    # "mil" is the spelling of a thousand in dates ("mil neuf cent
    # soixante-deux"), the way the v4 run's model wrote birth years.
    FRENCH_THOUSANDS = %w[mille mil].freeze
    FRENCH_CARDINALS = FRENCH_UNITS.merge(FRENCH_TENS).merge('cent' => 100, 'cents' => 100, 'mille' => 1000, 'mil' => 1000).freeze
    FRENCH_FIRST = %w[premier premiers première premières].freeze
    FRENCH_SECOND = %w[second seconds seconde secondes].freeze
    # The words before which "second" counts, and the words after which it
    # does not ("la seconde de retard", "le second est").
    FRENCH_SECOND_DETERMINERS = %w[le la les l du au aux des son sa ses ce cet cette leur leurs mon ma mes ton ta tes
                                   notre nos votre vos].freeze
    FRENCH_SECOND_NOT_BEFORE = %w[de d du des à au aux en et ou qui que qu est sont a ont été par pour sur dans avec
                                  n ne se s y].freeze
    FRENCH_ARTICLE_JOINER = /\A(?:[ \t\u00a0]|['’])\z/
    FRENCH_ARTICLES = %w[un une].freeze
    # "cinquième", "neuvième", "quatrième": the cardinal an ordinal is built on.
    FRENCH_ORDINAL = /\A(?<stem>[[:alpha:]]+?)ièmes?\z/
    FRENCH_ORDINAL_STEMS = { 'cinqu' => 'cinq', 'neuv' => 'neuf', 'un' => 'un' }.freeze
    # "neuf" is "new" far more often than nine: a figure only inside a
    # compound ("dix-neuf") or before what it counts.
    FRENCH_NEUF_COUNTED = /\A(?:ans|années|mois|semaines|jours|heures|minutes|euros|fois|enfants|personnes|
                              travailleurs|membres|points|cents?|mille)\z/xi
    FRENCH_JOINER = /\A[ \t\u00a0-]\z/
    # "Premier ministre" is a title, "en premier lieu" is "first of all".
    FRENCH_FIRST_TITLE_NOUN = /\Aministres?\z/i
    FRENCH_FIRST_IDIOM_NOUN = /\Alieu\z/i

    GERMAN_UNITS = {
      'ein' => 1, 'eins' => 1, 'zwei' => 2, 'zwo' => 2, 'drei' => 3, 'vier' => 4, 'fünf' => 5, 'sechs' => 6,
      'sieben' => 7, 'acht' => 8, 'neun' => 9
    }.freeze
    GERMAN_TEENS = {
      'zehn' => 10, 'elf' => 11, 'zwölf' => 12, 'dreizehn' => 13, 'vierzehn' => 14, 'fünfzehn' => 15,
      'sechzehn' => 16, 'siebzehn' => 17, 'achtzehn' => 18, 'neunzehn' => 19
    }.freeze
    GERMAN_TENS = {
      'zwanzig' => 20, 'dreißig' => 30, 'dreissig' => 30, 'vierzig' => 40, 'fünfzig' => 50, 'sechzig' => 60,
      'siebzig' => 70, 'achtzig' => 80, 'neunzig' => 90
    }.freeze
    GERMAN_COMPOUND_TENS = /\A(?<unit>ein|zwei|drei|vier|fünf|sechs|sieben|acht|neun)und
                            (?<tens>#{GERMAN_TENS.keys.join('|')})\z/x
    GERMAN_ARTICLE_FORMS = %w[ein eine einen einem einer eines eins].freeze
    GERMAN_BOTH = /\Abeide[mnrs]?\z/
    # "dreijährig", "zweimal", "vierwöchig": the number and what it counts;
    # and the compounds "Zehnjahresfrist", "Dreimonatsfrist", "Vierzehntagefrist".
    GERMAN_SUFFIXED = /\A(?<number>[[:alpha:]]+?)(?:mal(?:ig[[:alpha:]]*)?|fach[[:alpha:]]*|jährig[[:alpha:]]*|
                        monatig[[:alpha:]]*|wöchig[[:alpha:]]*|tägig[[:alpha:]]*|stündig[[:alpha:]]*|
                        teilig[[:alpha:]]*|jahres?[[:alpha:]]+|monats?[[:alpha:]]+|wochen[[:alpha:]]+|
                        tages?[[:alpha:]]+|stunden[[:alpha:]]+)\z/x
    # "zweieinhalb", "dreieinhalb": the integer part, which is what the
    # French "deux ans et demi" counts too ("et demi" is no figure there).
    GERMAN_AND_A_HALF = /\A(?<number>[[:alpha:]]+?)einhalb\z/
    GERMAN_ORDINAL_ENDING = /(?:te|ten|ter|tes|tem)\z/
    # The ordinals not built on their cardinal: erste, dritte, siebte, achte.
    GERMAN_ORDINAL_STEMS = { 'ers' => 1, 'drit' => 3, 'sieb' => 7, 'ach' => 8 }.freeze
    GERMAN_RANGE_WORDS = %w[bis und oder bzw].freeze
    # "in erster Linie", "an erster Stelle", "in zweiter Linie": "above all",
    # "secondly", no figure.
    GERMAN_FIRST_IDIOM_NOUNS = %w[Linie Stelle].freeze
    GERMAN_IDIOM_ORDINALS = %w[erster zweiter].freeze
    # "dritte Person", "dritte Partei", "dritter Staat", "dritte Länder":
    # the third party of French "tiers", no figure.
    GERMAN_THIRD_PARTY_NOUN = /\A(?:Person|Personen|Partei|Parteien|Staat|Staaten|Staates|Land|Landes|Länder|Ländern)\z/
    # An ordinal may stand before one or two adjectives when an article or
    # a contraction introduces it: "der erste volle Kalendermonat".
    GERMAN_DETERMINERS = %w[der die das den dem des im am vom zum zur beim ihr ihre ihrem ihren ihrer sein seine
                            seinem seinen seiner mein meine meinem meinen meiner jeder jede jedes jedem jeden].to_set.freeze
    GERMAN_ADJECTIVE = /\A[[:lower:]]{3,}(?:e|en|er|es|em)\z/
    GERMAN_NOT_ADJECTIVES = %w[
      eine einen einem einer eines keine keinen keinem keiner keines diese diesen diesem dieser dieses jene jenen
      jenem jener jenes welche welchen welchem welcher welches seine seinen seinem seiner seines ihre ihren ihrem
      ihrer ihres meine meinen meinem meiner meines unsere unseren unserem unserer unseres alle allen allem aller
      alles beiden oder aber wenn dann denn gegen unter über hier sehr mehr eben haben werden sollen müssen können
      dürfen wollen wieder immer sonst also daher
    ].to_set.freeze
    GERMAN_MAX_ADJECTIVES = 2
    GERMAN_SPACE = /\A[ \t\u00a0]\z/

    Token = Struct.new(:text, :from, :to)
    WORD = /[[:alpha:]]+/

    module_function

    # v5 q0039: "un quart d'heure" against "15 Minuten", the quarter and the
    # half hour read as their minutes on both sides, their article included.
    FRENCH_CLOCK_PHRASES = {
      /(?<![[:alpha:]])(?:un\s+)?quarts?\s+d['’]heure(?![[:alpha:]])/i => '15',
      /(?<![[:alpha:]])(?:une\s+)?demi-?heures?(?![[:alpha:]])/i => '30'
    }.freeze
    GERMAN_CLOCK_PHRASES = {
      /(?<![[:alpha:]])(?:eine[rn]?\s+)?Viertelstunden?(?![[:alpha:]])/i => '15',
      /(?<![[:alpha:]])(?:eine[rn]?\s+)?halbe[nrs]?\s+Stunden?(?![[:alpha:]])/i => '30'
    }.freeze

    # The figures a French text writes in words: value (String) => count.
    def french(text)
      tally = Hash.new(0)
      text = clock_phrases(text.to_s, FRENCH_CLOCK_PHRASES, tally)
      tokens = tokens(text)
      index = 0
      while index < tokens.length
        run = french_run(text, tokens, index)
        if run
          value = french_value(text, tokens, run)
          tally[value.to_s] += 1 if value
          index = run.last + 1
        else
          index += 1
        end
      end
      tally
    end

    # The figures a German text writes in words: value (String) => count.
    def german(text)
      tally = Hash.new(0)
      text = clock_phrases(text.to_s, GERMAN_CLOCK_PHRASES, tally)
      tokens = tokens(text)
      tokens.each_index do |index|
        value = german_value(text, tokens, index)
        tally[value.to_s] += 1 if value
      end
      tally
    end

    # Counts the clock phrases and blanks them, so their article is not a
    # figure of its own.
    def clock_phrases(text, phrases, tally)
      phrases.reduce(text) do |rest, (pattern, value)|
        rest.gsub(pattern) do
          tally[value] += 1
          ' '
        end
      end
    end

    def tokens(text)
      text.to_enum(:scan, WORD).map do
        match = Regexp.last_match
        Token.new(match[0], match.begin(0), match.end(0))
      end
    end

    def between(text, tokens, index)
      following = tokens[index + 1]
      following ? text[tokens[index].to...following.from].to_s : ''
    end

    # ---------------------------------------------------------------------
    # French
    # ---------------------------------------------------------------------

    # The indexes of the words of one French figure from `start`, or nil:
    # cardinals joined by a hyphen or a space ("deux mille seize",
    # "dix-huit"), "et" between tens and "un" or "onze" ("vingt et un"), and
    # an ordinal as the last word ("vingt-et-unième"). "premier" stands alone.
    def french_run(text, tokens, start)
      first = tokens[start].text.downcase
      return [start] if FRENCH_FIRST.include?(first) || (french_ordinal_value(first) && !FRENCH_CARDINALS.key?(first))
      return [start] if FRENCH_SECOND.include?(first) && french_second_counted?(text, tokens, start)
      return nil unless FRENCH_CARDINALS.key?(first)

      run = [start]
      index = start
      loop do
        break unless tokens[index + 1] && between(text, tokens, index).match?(FRENCH_JOINER)

        current = tokens[index].text.downcase
        following = tokens[index + 1].text.downcase
        if following == 'et' && FRENCH_TENS.key?(current) && tokens[index + 2] &&
           between(text, tokens, index + 1).match?(FRENCH_JOINER) &&
           %w[un une onze unième].include?(tokens[index + 2].text.downcase)
          run.push(index + 1, index + 2)
          index += 2
          break if tokens[index].text.downcase == 'unième'
        elsif FRENCH_CARDINALS.key?(following) && !FRENCH_ARTICLES.include?(following)
          run << (index + 1)
          index += 1
        elsif french_ordinal_value(following) && !FRENCH_FIRST.include?(following)
          run << (index + 1)
          break
        else
          break
        end
      end
      run
    end

    def french_ordinal_value(lower)
      match = lower.match(FRENCH_ORDINAL)
      return nil unless match

      stem = match[:stem]
      base = FRENCH_ORDINAL_STEMS[stem] || [stem, "#{stem}e"].find { |candidate| FRENCH_CARDINALS.key?(candidate) }
      base && FRENCH_CARDINALS[base]
    end

    def french_value(text, tokens, run)
      words = run.map { |index| tokens[index].text.downcase }.reject { |word| word == 'et' }
      return nil if words.length == 1 && !french_single_counted?(text, tokens, run.first)
      return nil if words.length == 1 && FRENCH_FIRST.include?(words.first) && french_first_idiom?(text, tokens, run.first)
      return 1 if words.length == 1 && FRENCH_FIRST.include?(words.first)
      return 2 if words.length == 1 && FRENCH_SECOND.include?(words.first)

      total = 0
      current = 0
      previous = nil
      words.each do |word|
        cardinal = FRENCH_CARDINALS.key?(word) ? word : french_ordinal_base(word)
        return nil unless cardinal

        if FRENCH_HUNDREDS.include?(cardinal)
          current = (current.zero? ? 1 : current) * 100
        elsif FRENCH_THOUSANDS.include?(cardinal)
          total += (current.zero? ? 1 : current) * 1000
          current = 0
        elsif %w[vingt vingts].include?(cardinal) && previous == 'quatre'
          current += 76
        else
          current += FRENCH_CARDINALS.fetch(cardinal)
        end
        previous = cardinal
      end
      total + current
    end

    def french_ordinal_base(word)
      match = word.match(FRENCH_ORDINAL)
      return nil unless match

      stem = match[:stem]
      FRENCH_ORDINAL_STEMS[stem] || [stem, "#{stem}e"].find { |candidate| FRENCH_CARDINALS.key?(candidate) }
    end

    # "le second alinéa", "la seconde fois": after an article, before a word
    # that is no preposition, conjunction or verb.
    def french_second_counted?(text, tokens, index)
      previous = index.positive? ? tokens[index - 1] : nil
      following = tokens[index + 1]
      return false unless previous && following
      return false unless FRENCH_SECOND_DETERMINERS.include?(previous.text.downcase)
      return false unless text[previous.to...tokens[index].from].to_s.match?(FRENCH_ARTICLE_JOINER)
      return false unless between(text, tokens, index).match?(FRENCH_JOINER)

      !FRENCH_SECOND_NOT_BEFORE.include?(following.text.downcase)
    end

    # "Premier ministre", "en premier lieu": no figure.
    def french_first_idiom?(text, tokens, index)
      following = tokens[index + 1]
      return false unless following && between(text, tokens, index).match?(FRENCH_JOINER)
      return true if following.text.match?(FRENCH_FIRST_TITLE_NOUN)

      following.text.match?(FRENCH_FIRST_IDIOM_NOUN) && index.positive? && tokens[index - 1].text.casecmp?('en')
    end

    def french_single_counted?(text, tokens, index)
      word = tokens[index].text.downcase
      return false if FRENCH_ARTICLES.include?(word)
      return tokens[index + 1]&.text.to_s.match?(FRENCH_NEUF_COUNTED) if word == 'neuf'
      return false if FRENCH_HUNDREDS.include?(word) && index.positive? && tokens[index - 1].text.casecmp?('pour') &&
                      between(text, tokens, index - 1).match?(FRENCH_JOINER)

      true
    end

    # ---------------------------------------------------------------------
    # German
    # ---------------------------------------------------------------------

    def german_value(text, tokens, index)
      word = tokens[index].text
      lower = word.downcase
      return 2 if lower.match?(GERMAN_BOTH)
      return nil if GERMAN_ARTICLE_FORMS.include?(lower)

      cardinal = german_cardinal(lower)
      return (heed?(tokens, index) ? nil : cardinal) if cardinal

      suffixed = lower.match(GERMAN_SUFFIXED)
      if suffixed
        value = german_cardinal(suffixed[:number])
        return value if value && value > 1
      end
      half = lower.match(GERMAN_AND_A_HALF)
      if half
        value = german_cardinal(half[:number])
        return value if value && value > 1
      end

      german_ordinal(text, tokens, index)
    end

    # "außer Acht lassen", "in Acht nehmen": a noun, not a figure.
    def heed?(tokens, index)
      tokens[index].text == 'Acht' && index.positive? && %w[außer ausser in].include?(tokens[index - 1].text.downcase)
    end

    # "zwei", "achtzehn", "einundzwanzig", "zweitausendsechzehn",
    # "neunzehnhundertzweiundsechzig"; nil for any other word.
    def german_cardinal(word)
      return nil if word.nil? || word.empty?

      thousand = word.index('tausend')
      return german_scaled(word, thousand, 'tausend', 1000) { |part| german_below_thousand(part) } if thousand

      german_below_thousand(word)
    end

    def german_below_thousand(word)
      hundred = word.index('hundert')
      return german_scaled(word, hundred, 'hundert', 100) { |part| german_below_hundred(part) } if hundred

      german_below_hundred(word)
    end

    def german_scaled(word, position, scale_word, scale)
      head = word[0...position]
      tail = word[(position + scale_word.length)..]
      multiplier = head.empty? ? 1 : yield(head)
      rest = tail.empty? ? 0 : yield(tail)
      multiplier && rest ? (multiplier * scale) + rest : nil
    end

    def german_below_hundred(word)
      return GERMAN_TEENS[word] if GERMAN_TEENS.key?(word)
      return GERMAN_TENS[word] if GERMAN_TENS.key?(word)
      return GERMAN_UNITS[word] if GERMAN_UNITS.key?(word)

      match = word.match(GERMAN_COMPOUND_TENS)
      match ? GERMAN_UNITS[match[:unit]] + GERMAN_TENS[match[:tens]] : nil
    end

    # "fünfte", "ersten", "zwanzigsten", "dritter", and capitalised "Erster",
    # "Zweite": before a noun, a number or a range word ("im fünften Jahr",
    # "die ersten vier", "vom zweiten bis", "Gericht Erster Instanz"), or
    # across one or two adjectives after an article ("der erste volle
    # Kalendermonat"). An all-capitals word is a heading, never a figure.
    def german_ordinal(text, tokens, index)
      word = tokens[index].text
      return nil unless word == word.downcase || word == word.capitalize

      lower = word.downcase
      ending = lower.match(GERMAN_ORDINAL_ENDING)
      return nil unless ending

      value = german_ordinal_stem_value(lower[0...ending.begin(0)])
      return nil unless value&.positive?

      counted = counted_word(text, tokens, index)
      return nil unless counted
      return nil if GERMAN_IDIOM_ORDINALS.include?(lower) && GERMAN_FIRST_IDIOM_NOUNS.include?(counted.text)
      return nil if value == 3 && counted.text.match?(GERMAN_THIRD_PARTY_NOUN)
      return nil if third_party_noun?(text, tokens, index, word, value)

      value
    end

    # Capitalised "Dritte", "Dritter", "Dritten" is the noun for a third party
    # (French "tiers") anywhere inside a sentence: "wenn Dritte Rechte geltend
    # machen", "ein Dritter Einspruch erheben kann". It is the ordinal only
    # where a title or a heading puts it: opening a sentence or a list item
    # ("Dritte Kammer") or after another capitalised word.
    def third_party_noun?(text, tokens, index, word, value)
      return false unless value == 3 && word != word.downcase
      return false if index.zero?

      previous = tokens[index - 1]
      return false if previous.text.match?(/\A[[:upper:]]/)
      return false if previous.text.match?(/[.!?:;]\z|\A(?:[-•*]|\d+[.)])\z/)

      !between(text, tokens, index - 1).match?(/[.!?:;\n]/)
    end

    # The word an ordinal at `index` counts: the next one when it is a noun,
    # a number or a range word, or the noun after one or two adjectives when
    # an article introduces the ordinal. nil when there is none.
    def counted_word(text, tokens, index)
      return tokens[index + 1] if before_noun_or_number?(text, tokens, index)
      return nil unless index.positive? && GERMAN_DETERMINERS.include?(tokens[index - 1].text.downcase)

      position = index
      GERMAN_MAX_ADJECTIVES.times do
        adjective = tokens[position + 1]
        return nil unless adjective && between(text, tokens, position).match?(GERMAN_SPACE)
        return nil unless adjective.text.match?(GERMAN_ADJECTIVE) && !GERMAN_NOT_ADJECTIVES.include?(adjective.text)

        position += 1
        noun = tokens[position + 1]
        return nil unless noun && between(text, tokens, position).match?(GERMAN_SPACE)
        return noun if noun.text.match?(/\A[[:upper:]]/) && noun.text != 'Sie'
      end
      nil
    end

    def german_ordinal_stem_value(stem)
      return GERMAN_ORDINAL_STEMS[stem] if GERMAN_ORDINAL_STEMS.key?(stem)

      # "zwanzigste", "hundertste": the "s" of the ordinals from twenty on.
      if stem.end_with?('s')
        value = german_cardinal(stem.delete_suffix('s'))
        return value if value && value >= 20
      end
      german_cardinal(stem)
    end

    def before_noun_or_number?(text, tokens, index)
      following = tokens[index + 1]
      # "die ersten 7 Tage": digits are no tokens, so the ordinal before a
      # digit run is read from the text between the ordinal and the next word.
      return true if between(text, tokens, index).match?(/\A[ \t\u00a0]+\d/)
      return false unless following && between(text, tokens, index).match?(/\A[ \t\u00a0]\z/)
      return false if following.text == 'Sie'

      following.text.match?(/\A[[:upper:]]/) || GERMAN_RANGE_WORDS.include?(following.text.downcase) ||
        !german_cardinal(following.text.downcase).nil?
    end
  end
end
