# frozen_string_literal: true

module LegalChatbot
  # When the new Criminal Code took effect, in one place (Sol 2026-11-25 12:43:15Z). Books I and II (the laws of
  # 29 February 2024, NUMAC 2024002052 and 2024002088) took effect generally on 1 September 2026: art. 38 of the Book I
  # act and art. 119 of the Book II act, as amended by the law of 30 March 2026 (arts 252 and 253, in force on 3 April
  # 2026; both read in full in the corpus on 2026-11-25). The date first planned, 8 April 2026, never applied, and the app
  # assumed it until 1.1.106. Art. 38 of the Book I act also defers Code arts 42 (behandeling onder vrijheidsberoving)
  # and 46 (verlengde opvolging) to 1 January 2035 unless the King sets an earlier date, and the power of the sentence
  # execution court to modify the penalties of arts 47, 48, 49 and 57 to a royal date, by 30 June 2029 at the latest.
  #
  # The prompts' transition rule, the label of the 1867 Code and LegislationSearch's date patterns read this date; the
  # patterns are built from it.
  module CriminalCodeCommencement
    EFFECTIVE = Date.new(2026, 9, 1)
    DATE_TEXT = { 'nl' => '1 september 2026', 'fr' => '1er septembre 2026', 'de' => '1. September 2026',
                  'en' => '1 September 2026' }.freeze
    # The penalties art. 38 of the Book I act defers, under the names Code arts 42 and 46 give them (Dutch and French
    # rows read on 2026-11-25)
    DEFERRED_PENALTIES = {
      'nl' => 'de behandeling onder vrijheidsberoving en de verlengde opvolging (art. 42 en 46) pas op 1 januari 2035, ' \
              'tenzij de Koning een eerdere datum bepaalt',
      'fr' => 'le traitement sous privation de liberté et le suivi prolongé (art. 42 et 46) seulement le 1er janvier 2035, ' \
              'sauf si le Roi fixe une date antérieure'
    }.freeze
    # The Code articles that name a penalty art. 38 of the Book I act defers (art. 36 lists the treatment at every level
    # from 2): their source block carries the note (Sol 12:43:15Z: a pin of art. 36 must not make all its sanctions sound
    # available now). Titles as the Dutch and French rows hold them.
    DEFERRED_NOTE_ARTICLES = { '2024002052' => %w[art36 art42 art46] }.freeze
    DEFERRED_NOTE = {
      'nl' => 'het Strafwetboek is in het algemeen in werking sinds %<date>s; %<deferred>s (art. 38 van de wet van ' \
              '29 februari 2024 tot invoering van boek I)',
      'fr' => 'le Code pénal est en vigueur de manière générale depuis le %<date>s; %<deferred>s (art. 38 de la loi du ' \
              '29 février 2024 introduisant le livre Ier)'
    }.freeze
    # Art. 1 of the law of 5 March 1952 (1952030505, read in full on 2026-11-25), as amended by art. 2 of the law of
    # 16 March 2026 (2026002190), whose art. 64 puts it in force with Books I and II: a fine a court imposes under the
    # Criminal Code or a special law is increased by 2.5 opdecimes, i.e. by a quarter (Sol verified it in Justel,
    # 2026-11-25 12:37:07Z); for a special law that sets no penalty level, art. 78, § 1, second paragraph of the Code
    # applies. The law's own words: "opdecimes" (Dutch), "décimes" (French). Sol 2026-11-25 23:00:07Z (#1556, #1557 on
    # live 1.1.106): both answers named the 2.5 opdecimes and the law but never what they add, so the rule says 25% too.
    FINE_SURCHARGE = {
      'en' => 'a criminal fine that a court imposes is increased by the opdecimes of art. 1 of the law of 5 March 1952: since ' \
              '%<date>s by 2.5 opdecimes, that is by 25%% (x1.25), under the Criminal Code and the special laws that set a ' \
              'penalty level; for a special law that sets no level, art. 78, § 1, second paragraph of the Criminal Code ' \
              'applies. When you name the opdecimes, also give the increase as 25%%. Say whether an amount is the statutory ' \
              'base or the amount payable, and keep a settlement offer apart from a fine a court imposes',
      'fr' => "une amende pénale prononcée par un tribunal est majorée des décimes de l'article 1er de la loi du 5 mars 1952: depuis " \
              'le %<date>s de 2,5 décimes, soit de 25 %% (x1,25), en vertu du Code pénal et des lois particulières qui ' \
              "déterminent un niveau de peine; pour une loi particulière qui ne détermine pas de niveau de peine, l'article 78, " \
              '§ 1er, alinéa 2, du Code pénal est applicable. Lorsque vous citez les décimes, donnez aussi la majoration de 25 %%. ' \
              'Indiquez si un montant est le montant légal de base ou le montant à payer, et distinguez une proposition de ' \
              "transaction d'une amende prononcée par un tribunal"
    }.freeze
    # A month's names in the four languages a question may be written in
    MONTH_NAMES = {
      1 => %w[januari janvier january januar], 2 => %w[februari février fevrier february februar],
      3 => %w[maart mars march märz maerz], 4 => %w[april avril], 5 => %w[mei mai may], 6 => %w[juni juin june],
      7 => %w[juli juillet july], 8 => %w[augustus août aout august], 9 => %w[september septembre],
      10 => %w[oktober octobre october], 11 => %w[november novembre], 12 => %w[december décembre decembre dezember]
    }.freeze
    ENGLISH_MONTHS = %w[january february march april may june july august september october november december].freeze
    DAY = '(?:0?[1-9]|[12]\d|3[01])'
    # An amount, not a year: "diefstal van 2025 euro"
    NOT_AN_AMOUNT = '(?!\d)(?!\s*(?:€|eur(?:o)?s?\b|dollars?\b|usd\b|gbp\b))'

    module_function

    def date_text(language) = DATE_TEXT.fetch(language.to_s, DATE_TEXT.fetch('nl'))

    # The note for a Code article that names a deferred penalty, in the answer's language, or nil
    def deferred_note(numac, article_title, language)
      return nil unless DEFERRED_NOTE_ARTICLES.fetch(numac.to_s, []).include?(article_title.to_s.delete(' .').downcase)

      key = language.to_s == 'fr' ? 'fr' : 'nl'
      format(DEFERRED_NOTE.fetch(key), date: date_text(key), deferred: DEFERRED_PENALTIES.fetch(key))
    end

    # The prompts' rule for criminal fines (English for the Dutch prompt's instructions, French for the French prompt)
    def fine_surcharge_text(language)
      key = language.to_s == 'fr' ? 'fr' : 'en'
      format(FINE_SURCHARGE.fetch(key), date: date_text(key))
    end

    # The opening of the prompts' transition rule: the general date, and what it does not cover yet
    def transition_text(language)
      if language.to_s == 'fr'
        "le nouveau Code pénal (Livres Ier et II) est entré en vigueur de manière générale le #{date_text('fr')}; " \
          "#{DEFERRED_PENALTIES.fetch('fr')}"
      else
        "het nieuwe Strafwetboek (Boeken I en II) is in het algemeen in werking getreden op #{date_text('nl')}; " \
          "#{DEFERRED_PENALTIES.fetch('nl')}"
      end
    end

    # A date before EFFECTIVE as a question writes it: a year before its year, alone or ending a date ("12 maart 2025",
    # "12/03/2025", "March 12, 2025"; a date that starts with such a year is one already), or a day or a month of its
    # year before its month, with the month as a number or a name. Built for a commencement on the first of a month.
    def legacy_date_source
      raise ArgumentError, 'the date patterns assume a commencement on the first of a month' unless EFFECTIVE.day == 1

      year = EFFECTIVE.year
      earlier = "(?:#{earlier_years_source(year)})"
      months = (1...EFFECTIVE.month).to_a
      numbers = months.map { |month| "0?#{month}" }.join('|')
      names = months.flat_map { |month| MONTH_NAMES.fetch(month) }.uniq.join('|')
      english = months.map { |month| ENGLISH_MONTHS[month - 1] }.join('|')
      all_names = MONTH_NAMES.values.flatten.uniq.join('|')
      ["(?:#{DAY}(?:st|nd|rd|th|er|e|\\.)?\\s+)?(?:#{all_names})\\s+#{earlier}(?!\\d)",
       "(?:#{ENGLISH_MONTHS.join('|')})\\s+#{DAY}(?:st|nd|rd|th)?,?\\s+#{earlier}(?!\\d)",
       "#{DAY}[-/.](?:0?[1-9]|1[0-2])[-/.]#{earlier}(?!\\d)",
       "#{earlier}#{NOT_AN_AMOUNT}",
       "#{year}[-/.](?:#{numbers})[-/.]#{DAY}(?!\\d)",
       "#{DAY}[-/.](?:#{numbers})[-/.]#{year}(?!\\d)",
       "(?:#{DAY}(?:st|nd|rd|th|er|e|\\.)?\\s+)?(?:#{names})\\s+#{year}(?!\\d)",
       "(?:#{english})\\s+#{DAY}(?:st|nd|rd|th)?,?\\s+#{year}(?!\\d)"].join('|')
    end

    # The day itself as a question names it ("vóór 1 september 2026", "before September 1, 2026"), or the entry into
    # force of the new Code
    def cutover_reference_source
      day = EFFECTIVE.day
      month = EFFECTIVE.month
      year = EFFECTIVE.year
      names = MONTH_NAMES.fetch(month).join('|')
      english = ENGLISH_MONTHS[month - 1]
      # Sol 16:22:46Z: the whole date is bounded, so "2026-09-15" or "11 september 2026" is not read as the day itself
      ["(?:de\\s+|le\\s+|dem\\s+|the\\s+)?(?:(?<!\\d)0?#{day}(?:st|nd|rd|th|e|er|\\.)?\\s+(?:#{names})\\s+#{year}(?!\\d)|" \
       "#{english}\\s+0?#{day}(?:st|nd|rd|th)?,?\\s+#{year}(?!\\d)|(?<!\\d)0?#{day}[-/.]0?#{month}[-/.]#{year}(?!\\d)|" \
       "(?<![\\d-])#{year}[-/.]0?#{month}[-/.]0?#{day}(?!\\d))",
       '(?:de\\s+|du\\s+|the\\s+|des\\s+)?(?:inwerkingtreding|entrée\\s+en\\s+vigueur|entry\\s+into\\s+force|inkrafttreten)\\s+' \
       '(?:van\\s+|du\\s+|of\\s+|des\\s+)?(?:het\\s+|le\\s+|the\\s+|des\\s+)?(?:nieuwe?\\s+|nouveau\\s+|new\\s+|neuen?\\s+)?' \
       '(?:strafwetboek|code\\s+pénal|criminal\\s+code|strafgesetzbuch)'].join('|')
    end

    # The years from 1900 to the one before year: for 2026, 19xx and 2000 to 2025
    def earlier_years_source(year)
      last = year - 1
      raise ArgumentError, "no year pattern for #{year}" unless (2001..2099).cover?(last)

      tens = (last % 100) / 10
      ones = last % 10
      full_decades = tens.positive? ? "[0-#{tens - 1}]\\d|" : ''
      "19\\d{2}|20(?:#{full_decades}#{tens}[0-#{ones}])"
    end
  end
end
