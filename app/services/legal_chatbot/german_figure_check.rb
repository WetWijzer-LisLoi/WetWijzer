# frozen_string_literal: true

module LegalChatbot
  # German answers v4 (to-do 7.5): an answer whose headline figure
  # contradicts the verified source appended under it is flagged on
  # gesetzguide, with either German switch on.
  #
  # The graded v3 run (docs/ops/german-answers-v3-eval-2026-09-29.md) found
  # it on the incident question itself: asked for the notice after five years,
  # the French path gave "**15 semaines**" in bold, from a made-up "12 + 3",
  # while the verified-source line the topic rules append under the answer
  # (TopicCitations, "Source vérifiée complémentaire") said 18 weeks (incident
  # t1 and q01). The reader acts on the headline figure, and nothing told
  # them the two disagree.
  #
  # The check reads the French answer the reasoning produced (the one a
  # German answer was translated from) and the question it was reasoned on.
  # A verified line is compared only when it is one of RULES: a topic answer
  # of TopicCitations whose rule figure is declared here, with the case that
  # figure covers. TopicCitations appends its line whenever the question
  # matches a broad topic pattern, whoever gives notice and whatever the
  # birth, so a line is compared only when the question is that case: notice
  # given by the employer after five years of seniority (18 weeks), not a
  # resignation (9 weeks) nor another seniority; the duration of the standard
  # maternity leave (15 weeks), not a multiple birth, an extension or one
  # part of the leave. Only the rule figure is compared, never a condition
  # the line states ("après cinq ans d'ancienneté").
  #
  # The headline figures are the figures in bold in the answer above the
  # verified lines, outside quotations and links; a rate ("trois semaines par
  # année") and an increment ("+ 3 semaines") are not a headline. When the
  # answer states a headline figure in the rule's unit, none of them is the
  # rule figure, and the answer's own prose does not state the rule figure
  # either, the answer is flagged: a fixed German note on top names both
  # figures, and the record (figure_check) says so. The answer itself is
  # not changed, and history replay keeps the French answer without the
  # note (CONTEXT_KEY).
  #
  # Measured on the stored v2 and v3 answers (every variant, 270 French
  # answers, 15 with a verified line): it flags incident t1 and q01 of v3's
  # de_qt_french, the two the report names, and nothing else; v2's q0041 t1
  # agrees twice; the drink-driving lines (q21) are no rule here and are not
  # compared. The review of v4 found the first version flagging correct
  # answers on questions the line does not cover (a resignation after five
  # years, a multiple birth, six years of seniority); each is a test now.
  class GermanFigureCheck
    RECORD_KEY = :figure_check
    STATUS_CONFLICT = 'conflict'
    STATUS_AGREES = 'agrees'

    WORD_START = '(?<![[:alpha:]])'
    WORD_END = '(?![[:alpha:]])'
    # Years in a question, in the languages a question on gesetzguide can
    # reach the answer path in: "5 ans", "cinq années", "fünf Jahren".
    # (a number written in words with hyphens is read whole, as NUMBER_TOKEN
    # reads it: "quarante-trois années" read as its last word, 3, made the
    # line of the question's own 43-year career another case, and two
    # German answers served a 60 with no note; the weekly run of 2026-10-05)
    QUESTION_YEARS = /#{WORD_START}(?<value>\d+|[[:alpha:]]+(?:-[[:alpha:]]+){0,2})[ \t\u00a0]+(?:ans?|années?|Jahren?|jaar|jaren|years?)#{WORD_END}/i
    # Notice given by the worker (a resignation, a counter-notice) or a
    # dismissal for serious cause: another rule than the employer's notice.
    NOTICE_OTHER_CASES = /
      démission|contre[-\s]?préavis|à\s+l['’]initiative\s+du\s+travailleur|par\s+le\s+travailleur|
      #{WORD_START}(?:je|il|elle)\s+(?:quitte|pars)#{WORD_END}|quitter\s+(?:mon|son|l['’])|motif\s+grave|faute\s+grave|
      kündige\s+ich|selbst\s+kündig|Eigenkündigung|Kündigung\s+durch\s+den\s+Arbeitnehmer|dringende[nr]?\s+Grund|
      ontslag\s+nem|zelf\s+ontslag|dringende\s+reden
    /xi
    # A question that asks how long the leave lasts.
    DURATION_ASKED = /
      combien\s+de\s+(?:temps|semaines)|#{WORD_START}(?:durée|dure|dure-t-il)#{WORD_END}|
      wie\s+lange|#{WORD_START}(?:Dauer|dauert)#{WORD_END}|wie\s+viele\s+Wochen|hoe\s+lang|#{WORD_START}duur#{WORD_END}
    /xi
    # Every case whose figure is not the standard leave of an employee after
    # a single birth, and every part of the leave.
    MATERNITY_OTHER_CASES = /
      multiple|jume|triplé|plusieurs\s+(?:enfants|bébés)|indépendant|prénatal|postnatal|
      avant\s+l['’]accouchement|après\s+l['’]accouchement|prolong|hospitalis|prématur|écartement|allaitement|adoption|
      paternité|naissance|sans\s+vie|co-?parent|#{WORD_START}père#{WORD_END}|conver|
      Mehrling|Zwilling|Drilling|selbst(?:st)?ändig|vorgeburtlich|nachgeburtlich|Verlänger|Krankenhaus|Frühgeburt|
      Totgeburt|#{WORD_START}Still(?:en|zeit)#{WORD_END}|Adoption|Vater|Geburtsurlaub|
      meerling|tweeling|zelfstandig|prenata|postnata|verleng
    /xi

    # The verified lines the check compares: the topic's French answer line
    # (TopicCitations::TOPIC_ANSWERS), the one figure it states as the rule,
    # and the case the rule covers (#rule_applies?).
    # value_for: the class method that gives the rule figure for the
    # question's own case (nil when the question does not name it);
    # not_followed_by: figures of the unit that are another quantity.
    # components: bold figures that are the parts of the verified figure
    # (v7 grader 1: the maternity leave written as its 6 prenatal and 9
    # postnatal weeks, the notice period as its 15-week base and 3-week
    # increment) and so agree with it when the whole is not written.
    Rule = Struct.new(:topic, :line, :unit, :value, :value_for, :not_followed_by, :components, keyword_init: true)
    # "43 ans de carrière", "42 années civiles": a career, not an age.
    CAREER_YEARS_AFTER = /
      \A[ \t\u00a0]*(?:de\s+(?:carrière|service|cotisations?|travail)|d['’](?:ancienneté|activité|assurance)|civiles|
      comme\s+(?:salari[eé]e?s?|travailleu(?:r|se)s?|employ[eé]e?s?|ouvri(?:er|ère)s?|ind[eé]pendante?s?|fonctionnaire)|
      (?:ou|et)\s+plus|oder\s+mehr|of\s+meer|or\s+more|
      als\s+(?:Arbeitnehmer|Angestellte|Arbeiter|Beamt|Selbst|werknemer|bediende|arbeider|zelfstandige|ambtenaar)|
      as\s+(?:an?\s+)?(?:employee|worker|civil\s+servant))
    /xi
    RULES = [
      Rule.new(topic: :notice_period_five_years, unit: 'week', value: 18.0, components: [15.0, 3.0],
               line: TopicCitations::TOPIC_ANSWERS.fetch(:notice_period_five_years).fetch('fr')),
      Rule.new(topic: :maternity_leave, unit: 'week', value: 15.0, components: [6.0, 9.0],
               line: TopicCitations::TOPIC_ANSWERS.fetch(:maternity_leave).fetch('fr')),
      # 20 days for births from 2023; a question about an earlier birth, an
      # adoption, the co-parent's or a self-employed parent's leave, the pay
      # (3 days by the employer, 17 by the insurer) or the mother's leave is
      # another case.
      Rule.new(topic: :birth_leave, unit: 'day', value: 20.0,
               line: TopicCitations::TOPIC_ANSWERS.fetch(:birth_leave).fetch('fr')),
      # German answers v5, grader 1 (the dangerous class). Art. 70 of the
      # Employment Contracts Act: 30 days of normal pay for an employee; a
      # worker (Art. 52), an accident at work, an occupational disease, a
      # relapse, a contract under three months, the insurer's benefit after
      # the first month or a self-employed person is another case.
      Rule.new(topic: :guaranteed_pay_employee, unit: 'day', value: 30.0,
               line: TopicCitations::TOPIC_ANSWERS.fetch(:guaranteed_pay_employee).fetch('fr')),
      # Art. 4 of 1997022010: the early pension age follows the career the
      # question names (42 years: 63, 43: 61, 44 or more: 60); a question
      # without a career length, or with a shorter one, is not compared.
      Rule.new(topic: :early_retirement, unit: 'year', value_for: :early_retirement_age,
               not_followed_by: CAREER_YEARS_AFTER,
               line: TopicCitations::TOPIC_ANSWERS.fetch(:early_retirement).fetch('fr')),
      # Art. 2: 65 for a reader born before 1960, 66 for 1960 to 1963, 67
      # from 1964 (the pension starts the month after the age is reached).
      Rule.new(topic: :pension_age, unit: 'year', value_for: :pension_age,
               not_followed_by: CAREER_YEARS_AFTER,
               line: TopicCitations::TOPIC_ANSWERS.fetch(:pension_age).fetch('fr')),
      # The alcohol limit of Art. 34 of the road traffic act: 0,5 g/l of
      # blood for a driver (v10 grader 1: an "0,8" headline stood over the
      # 0,5 line on the same row in two runs with no rule to compare them);
      # a professional driver (0,2), a novice or a question about the
      # breath value is another case.
      # The appended alcohol line is the promille sentence, not the topic
      # answer (TopicCitations#localized_promille_equivalence).
      Rule.new(topic: :alcohol_driving, unit: 'g_per_l', value: 0.5, not_followed_by: :alcohol_other_figure,
               line: 'La limite de 0,5 g/l de sang correspond usuellement à 0,5 promille.')
    ].map(&:freeze).freeze
    # An alcohol figure that names another threshold than the limit: the
    # heavier sanction from 0,8, the professional driver's 0,2, a breath
    # value; read on the text after the unit (the fine every band names is
    # no cue: the v3 answers state "0,5 g/l et < 0,8 g/l, amende" on one
    # line, and the 0,5 must still count).
    # ("à partir de" introduces the next figure, not this one, so it is no
    # cue on the text after a figure.)
    ALCOHOL_OTHER_FIGURE = /
      \A[^\n]{0,60}?(?:plus\s+(?:lourde?|s[ée]v[èe]re|grave)|aggrav|professionnel|chauffeur|
                      camion|autobus|autocar|novice|jeune|d[ée]butant)
    /xi
    # The weekly run of 2026-10-05 (q0409 run 2, q21 run 1): the professional
    # band labelled before its figure, on its line ("- Pour les conducteurs de
    # véhicules des catégories C1, C, ... : abaissées à **0,2 g/l**") or on the
    # first line of its list item ("1. **Pour les conducteurs de véhicules
    # nécessitant un permis de catégorie C1, ...**", the figure on a line of
    # the item below: "**→ La limite est donc de 0,2 g/L de sang pour ces
    # conducteurs.**"), which the 60 characters after the figure do not reach.
    ALCOHOL_OTHER_LABEL = /
      cat[ée]gories?\s+[CD]1?(?:\+?E)?#{WORD_END}|permis\s+(?:de\s+)?(?:cat[ée]gorie\s+)?[CD]1?(?:\+?E)?#{WORD_END}|
      (?:conducteurs?|chauffeurs?)\s+professionnels?|poids\s+lourds|camions?|autobus|autocars?|
      Berufs(?:kraft)?fahrer|Klassen?\s+[CD]1?#{WORD_END}|LKW|Lastwagen
    /xi
    ALCOHOL_OTHER_CASES = /
      professionnel|chauffeur|camion|autobus|autocar|#{WORD_START}bus#{WORD_END}|permis\s+[CD]|
      Berufs(?:kraft)?fahrer|LKW|Lastwagen|beroeps|vrachtwagen|vrachtauto|
      jeune\s+conducteur|novice|d[ée]butant|Fahranf[äa]nger|beginnend|
      0[.,]2#{WORD_END}|0[.,]09|#{WORD_START}mg#{WORD_END}|air\s+expir|haleine|Atem|adem
    /xi
    EMPLOYEE_STATUS = /#{WORD_START}(?:employ[eé]e?s?|bediendes?|bedienden|Angestellte[rnms]?|white[-\s]collar)#{WORD_END}/i
    GUARANTEED_PAY_OTHER_CASES = /
      ouvri(?:er|ère)s?|arbeiders?|arbeidsters?|#{WORD_START}Arbeiter(?:in|innen|n|s)?#{WORD_END}|blue[-\s]collar|
      accident\s+(?:du|de)\s+travail|maladie\s+professionnelle|arbeidsongeval|beroepsziekte|Arbeitsunfall|Berufskrankheit|
      work(?:place)?\s+accident|occupational\s+disease|rechute|herval|R[uü]ckfall|relapse|
      p[eé]riode\s+d['’]essai|proefperiode|Probezeit|moins\s+de\s+trois\s+mois|minder\s+dan\s+drie\s+maanden|weniger\s+als\s+drei\s+Monate|
      ind[eé]pendant|zelfstandig|selbst(?:st)?[aä]ndig|self-employed|
      mutuelle|mutualit[eé]|ziekenfonds|Krankenkasse|apr[eè]s\s+(?:30|trente)\s+jours|na\s+(?:30|dertig)\s+dagen|nach\s+(?:30|dreißig)\s+Tagen|
      deuxi[eè]me\s+mois|tweede\s+maand|zweite[nr]?\s+Monat|longue\s+dur[eé]e|langdurig|Langzeit
    /xi
    CAREER_WORDS = 'carri[eè]re|loopbaan|Laufbahn|Berufsjahren?|Dienstjahren?|career|cotis[[:alpha:]]*|gewerkt|gearbeitet|travaill[eé]'
    # "43 ans de carrière", "43 années de cotisation", "43 Berufsjahre", "43 jaar gewerkt".
    # The number as digits or as a word ("quarante-trois", "dreiundvierzig"),
    # resolved by NumberWords (v6 grader 1: the question translation wrote
    # the career out in words, and the digits-only reader saw no career).
    NUMBER_TOKEN = '(?<value>\d{1,2}|[[:alpha:]]+(?:-[[:alpha:]]+){0,2})'
    CAREER_AFTER_VALUE = /#{WORD_START}#{NUMBER_TOKEN}[ \t\u00a0]*(?:(?:ans|années|jaar|jaren|Jahren?|years?)[ \t\u00a0]+(?:(?:de|d['’]|van|als|of)[ \t\u00a0]+)?)?(?:#{CAREER_WORDS})/i
    # "une carrière de 43 ans", "een loopbaan van 43 jaar", "eine Laufbahn von 43 Jahren".
    CAREER_BEFORE_VALUE = /(?:#{CAREER_WORDS})[ \t\u00a0]+(?:de|van|von|of)[ \t\u00a0]+#{NUMBER_TOKEN}#{WORD_END}/i
    # "né en 1962", "geboren in 1962", "born in 1962"; "1962 geboren".
    BIRTH_YEAR_AFTER = /(?:n[eé]e?s?|geboren|born)#{WORD_END}[^.?!\d]{0,30}(?<year>19\d\d|20\d\d)/i
    BIRTH_YEAR_BEFORE = /(?<year>19\d\d|20\d\d)[^.?!\d]{0,12}geboren/i
    BIRTH_LEAVE_OTHER_CASES = /
      \b20(?:0\d|1\d|20|21|22)\b|avant\s+2023|vor\s+2023|voor\s+2023|before\s+2023|
      adopt|accueil|pleeg|Pflege|indépendant|selbst(?:st)?ändig|zelfstandig|co-?parent|meeouder|Mitelternteil|
      #{WORD_START}(?:mère|moeder|Mutter|mother)#{WORD_END}|maternit|Mutterschaft|
      rémun|salaire|pay[eé]|paie|indemnit|mutuelle|mutualit|#{WORD_START}loon|betaal|uitkering|Lohn|bezahlt|Entgelt|
      Krankenkasse|#{WORD_START}paid#{WORD_END}|#{WORD_START}pay#{WORD_END}|
      3\s+(?:jours|dagen|Tage|days)|trois\s+jours|drie\s+dagen|drei\s+Tage|three\s+days
    /xi

    VERIFIED_HEADING = /^[ \t]*\*\*Source vérifiée complémentaire[ \u00a0]?:\*\*[ \t]*$/
    VERIFIED_ANSWER_HEADING = /\A\s*\*\*Réponse vérifiée[ \u00a0]?:\*\*/
    VERIFIED_LINE = /^[ \t]*[-*][ \t]+(?<note>.+)$/
    BOLD = /\*\*(?<inner>[^*\n]+?)\*\*/
    LINK = GermanAnswerTranslation::LINK_PATTERN

    # French units, by the key the two sides are compared on.
    # promille: read as g/l (the same scale for blood alcohol; v10 grader
    # 1: an "0,8 gramme" and an "0,8 ‰" headline stood over the 0,5 line
    # with no rule to compare them).
    UNITS = {
      'week' => 'semaines?', 'day' => 'jours?', 'month' => 'mois', 'year' => 'ans?|années?', 'hour' => 'heures?',
      'euro' => 'euros?|EUR|€', 'percent' => '%|pour\s+cent', 'g_per_l' => 'g/l|grammes?(?:\s+par\s+litre)?',
      'mg_per_l' => 'mg/l', 'kmh' => 'km/h', 'promille' => '‰|promille|pour\s+mille'
    }.freeze
    UNIT_ALIASES = { 'promille' => 'g_per_l' }.freeze
    UNIT_PATTERN = Regexp.new(
      "(?<![[:alpha:]])(?:#{UNITS.map { |key, source| "(?<#{key}>#{source})" }.join('|')})(?![[:alpha:]])", Regexp::IGNORECASE
    )
    DIGIT_VALUE = /(?<![\d.,])(?<value>\d{1,3}(?:\.\d{3})+(?:,\d+)?|\d+(?:[.,]\d+)?)[ \t\u00a0]*\z/
    WORD_VALUE = /(?<words>(?:[[:alpha:]]+[ \-\u00a0]){0,4}[[:alpha:]]+)[ \t\u00a0]+\z/
    RATE = /\A[ \t\u00a0*]*(?:par|per|chaque)(?![[:alpha:]])/i
    INCREMENT = /\+[ \t\u00a0]*\z/

    # [singular, plural, dative plural when it differs]: the note's first
    # figure follows "von" (dative), the second is the object of "nennt".
    GERMAN_UNITS = {
      'week' => %w[Woche Wochen], 'day' => %w[Tag Tage Tagen], 'month' => %w[Monat Monate Monaten],
      'year' => %w[Jahr Jahre Jahren], 'hour' => %w[Stunde Stunden], 'euro' => %w[Euro Euro], 'percent' => %w[% %],
      'g_per_l' => %w[g/l g/l], 'mg_per_l' => %w[mg/l mg/l], 'kmh' => %w[km/h km/h], 'promille' => %w[‰ ‰]
    }.freeze
    FRENCH_UNITS = {
      'week' => %w[semaine semaines], 'day' => %w[jour jours], 'month' => %w[mois mois], 'year' => %w[an ans],
      'hour' => %w[heure heures], 'euro' => %w[euro euros], 'percent' => %w[% %], 'g_per_l' => %w[g/l g/l],
      'mg_per_l' => %w[mg/l mg/l], 'kmh' => %w[km/h km/h], 'promille' => %w[‰ ‰]
    }.freeze
    NOTE = '**Achtung:** Die hervorgehobene Angabe von %<headline>s weicht von der ergänzenden geprüften Quelle ' \
           'am Ende dieser Antwort ab, die %<verified>s nennt. Bitte prüfen Sie die verlinkte Bestimmung.'
    # The French twin (the v4 report, "Before the next run" 2): the same check
    # on the French answers themselves, lisloi first.
    NOTE_FR = '**Attention :** le chiffre mis en évidence, %<headline>s, s\'écarte de la source vérifiée ' \
              'complémentaire en fin de réponse, qui indique %<verified>s. Veuillez vérifier la disposition ' \
              'citée dans cette source.'
    NOTES = { 'de' => NOTE, 'fr' => NOTE_FR }.freeze
    NOTE_PARAGRAPH = /\A[\s>*_]*(?:Achtung:[\s*_]*Die hervorgehobene Angabe von|Attention[ \u00a0]?:[\s*_]*le chiffre mis en évidence)/

    # following: the text right after the unit, so "43 ans de carrière" is
    # told from an age.
    # line: the line of text the figure stands on, so the comparison can
    # pick the figures of the line that names the question's own case.
    # item: for a bold figure, the text of its list item (or of its line,
    # outside a list) up to the figure, where a label before the number names
    # the case it is for.
    # preceding: up to 24 characters before the number, where a preposition
    # tells what the figure is ("à 63 ans", an age a pension starts at).
    Figure = Struct.new(:unit, :value, :offset, :following, :line, :item, :preceding)

    class << self
      # nil, or { status:, topic:, unit:, headline:, verified: } for the
      # first rule of the appended lines that covers the question's case and
      # that the answer states a headline figure for (status conflict when
      # the answer states the rule figure nowhere).
      #
      # question: the question the answer was reasoned on (the French one
      # when the German question was translated).
      def detect(french, question:)
        text = french.to_s
        heading = text.to_enum(:scan, VERIFIED_HEADING).map { Regexp.last_match.begin(0) }.first
        return nil unless heading
        return nil if text.match?(VERIFIED_ANSWER_HEADING)

        rules = verified_rules(text[heading..]).select { |rule| rule_applies?(rule, question.to_s) }
        return nil if rules.empty?

        body = text[0...heading]
        headline = headline_figures(body)
        stated = prose_figures(body)
        results = rules.filter_map { |rule| compare(rule, headline, stated, question.to_s) }
        results.find { |result| result[:status] == STATUS_CONFLICT } || results.first
      end

      # Whether the question is the case the rule's figure covers.
      def rule_applies?(rule, question)
        case rule.topic
        when :notice_period_five_years
          years = question_years(question)
          years.include?(5) && years.all?(5) && !question.match?(NOTICE_OTHER_CASES)
        when :maternity_leave
          question.match?(DURATION_ASKED) && !question.match?(MATERNITY_OTHER_CASES)
        when :birth_leave
          !question.match?(BIRTH_LEAVE_OTHER_CASES)
        when :guaranteed_pay_employee
          question.match?(EMPLOYEE_STATUS) && !question.match?(GUARANTEED_PAY_OTHER_CASES)
        when :early_retirement
          !early_retirement_age(question).nil?
        when :pension_age
          !pension_age(question).nil?
        when :alcohol_driving
          !question.match?(ALCOHOL_OTHER_CASES)
        else
          false
        end
      end

      # The career length a question names ("43 ans de carrière", "une
      # carrière de 43 ans", "43 Berufsjahre"), or nil.
      def career_years(question)
        text = question.to_s
        [CAREER_AFTER_VALUE, CAREER_BEFORE_VALUE].each do |pattern|
          text.to_enum(:scan, pattern).each do
            value = number_value(Regexp.last_match[:value])
            return value if value&.between?(15, 60)
          end
        end
        nil
      end

      # A number written in digits or in French or German words, else nil.
      def number_value(word)
        return word.to_i if word.match?(/\A\d+\z/)

        value = NumberWords.french(word).keys.first || NumberWords.german(word).keys.first
        value&.to_i
      end

      # The early pension age for the career a question names (Art. 4 of
      # 1997022010, pensions starting from 2019): 42 years 63, 43 years 61,
      # 44 or more 60; nil for no career or a shorter one.
      def early_retirement_age(question)
        case career_years(question)
        when nil then nil
        when 44.. then 60.0
        when 43 then 61.0
        when 42 then 63.0
        end
      end

      # The legal pension age for the birth year a question names (Art. 2 of
      # 1997022010; the pension starts the month after the age is reached):
      # 65 before 1960, 66 for 1960 to 1963, 67 from 1964; nil without a year.
      def pension_age(question)
        year = birth_year(question)
        return nil unless year

        if year < 1960 then 65.0
        elsif year <= 1963 then 66.0
        else 67.0
        end
      end

      # The birth year a question names, in digits ("né en 1962") or in
      # words ("née en mille neuf cent soixante-deux", the form the question
      # translation wrote in v7, which left the pension line without a note).
      BIRTH_YEAR_WORDS = /(?:n[eé]e?s?|geboren|born)#{WORD_END}[^.?!\d]{0,12}?(?<words>(?:[[:alpha:]]+[ \- ]+){1,6}[[:alpha:]]+)/i
      def birth_year(question)
        text = question.to_s
        match = text.match(BIRTH_YEAR_AFTER) || text.match(BIRTH_YEAR_BEFORE)
        return match[:year].to_i if match

        words = text.match(BIRTH_YEAR_WORDS)
        return nil unless words

        tokens = words[:words].split(/[ \- ]+/)
        tokens.length.downto(2) do |size|
          (0..(tokens.length - size)).each do |start|
            phrase = tokens[start, size].join(' ')
            value = NumberWords.french(phrase).keys.first || NumberWords.german(phrase).keys.first
            return value.to_i if value&.to_i&.between?(1900, 2030)
          end
        end
        nil
      end

      # The years a question names, as integers ("cinq ans" is 5).
      def question_years(question)
        question.to_s.to_enum(:scan, QUESTION_YEARS).filter_map do
          word = Regexp.last_match[:value]
          next word.to_i if word.match?(/\A\d+\z/)

          value = NumberWords.french(word).keys.first || NumberWords.german(word).keys.first
          value&.to_i
        end
      end

      # The note for a detected conflict, in the language of the answer shown.
      def note(detection, language: 'de')
        format(NOTES.fetch(language.to_s) { NOTE },
               headline: amount(detection[:headline], detection[:unit], language, dative: true),
               verified: amount(detection[:verified], detection[:unit], language))
      end

      # History replay never hands the note back to the model.
      def without_note(text)
        return text unless text.is_a?(String) && (text.include?('Achtung:') || text.include?('Attention'))

        paragraphs = text.split(/\n{2,}/)
        kept = paragraphs.grep_v(NOTE_PARAGRAPH)
        return text if kept.length == paragraphs.length || kept.empty?

        kept.join("\n\n").strip
      end

      # Every figure with a unit in a text, as Figure (value a Float).
      def figures(text)
        text.to_enum(:scan, UNIT_PATTERN).filter_map do
          match = Regexp.last_match
          unit = UNITS.keys.find { |key| match[key] }
          unit = UNIT_ALIASES.fetch(unit, unit)
          before = text[0...match.begin(0)]
          value = figure_value(before)
          next unless value
          next if text[match.end(0)..].match?(RATE)
          next if before.sub(DIGIT_VALUE, '').match?(INCREMENT)

          line_start = (text.rindex("\n", match.begin(0)) || -1) + 1
          line_end = text.index("\n", match.end(0)) || text.length
          lead = before.sub(DIGIT_VALUE, '')
          lead = before.sub(WORD_VALUE, '') if lead == before
          Figure.new(unit, value, match.begin(0), text[match.end(0), 40], text[line_start...line_end], nil,
                     lead[-24..] || lead)
        end
      end

      private

      # The rules whose line is among the appended verified lines.
      def verified_rules(block)
        notes = block.to_enum(:scan, VERIFIED_LINE).map { Regexp.last_match[:note] }
        RULES.select { |rule| notes.any? { |note| note.include?(rule.line) } }
      end

      # Every figure the answer's own prose states, quotations and link
      # targets set aside.
      def prose_figures(body)
        figures(GermanAnswerTranslation.replace_quotations(body) { "\n" }.gsub(LINK, ' '))
      end

      # The figures in bold in the answer above the verified lines, with its
      # quotations and link targets set aside.
      def headline_figures(body)
        prose = GermanAnswerTranslation.replace_quotations(body) { "\n" }.gsub(LINK, ' ')
        prose.to_enum(:scan, BOLD).flat_map do
          match = Regexp.last_match
          # The span with what follows it, so a rate outside the bold still reads as one.
          # 60 characters after the bold: enough for "pour les conducteurs
          # professionnels" or "pour une sanction plus lourde" (v10, the
          # alcohol rule's other figures); every following-text pattern is
          # anchored at its start.
          span = "#{match[:inner]}#{prose[match.end(0), 60]}"
          line_start = (prose.rindex("\n", match.begin(0)) || -1) + 1
          line_end = prose.index("\n", match.end(0)) || prose.length
          line = prose[line_start...line_end]
          item = prose[item_start(prose, line_start)...match.begin(0)]
          figures(span).select { |figure| figure.offset < match[:inner].length }.each do |figure|
            figure.line = line
            figure.item = item
          end
        end
      end

      LIST_ITEM = /\A[ \t]*(?:[-*+•→]|\d{1,2}[.)])[ \t]+/
      # Where the list item holding the line at `line_start` begins: the line
      # itself when it opens an item or stands outside a list, else the
      # nearest line above that opens an item less indented than it (the
      # item's quotations and blank lines are walked over; a paragraph
      # outside the list ends the search).
      def item_start(prose, line_start)
        line = prose[line_start...(prose.index("\n", line_start) || prose.length)]
        return line_start if line.match?(LIST_ITEM) || !line.match?(/\A[ \t]+\S/)

        indent = line[/\A[ \t]*/].length
        position = line_start
        while position >= 2
          previous_start = (prose.rindex("\n", position - 2) || -1) + 1
          previous = prose[previous_start...(position - 1)]
          return previous_start if previous.match?(LIST_ITEM) && previous[/\A[ \t]*/].length < indent
          break if previous.match?(/\A\S/) && !previous.match?(LIST_ITEM)

          position = previous_start
        end
        line_start
      end

      # nil when the answer states no headline figure in the rule's unit;
      # else agrees when the rule figure is among its headline figures or
      # anywhere in its prose ("soit 15 semaines au total"), conflict when
      # it is nowhere. The rule figure is the rule's value, or the one its
      # value_for method gives for the question's case.
      def compare(rule, headline, stated, question = '')
        value = rule.value || send(rule.value_for, question)
        return nil unless value

        headline = other_quantities_removed(rule, headline)
        stated = other_quantities_removed(rule, stated)
        all_stated = stated
        headline, stated = case_lines_only(headline, stated, rule, question)
        values = headline.select { |figure| figure.unit == rule.unit }.map(&:value).uniq
        return unstated_start_ages(rule, all_stated, value, question) if values.empty?

        found = values.include?(value) ||
                stated.any? { |figure| figure.unit == rule.unit && figure.value == value } ||
                components_on_one_line?(rule, headline)
        restated = found && restated_otherwise(rule, headline, value, question)
        return { status: STATUS_CONFLICT, topic: rule.topic.to_s, unit: rule.unit, headline: restated, verified: [value] } if restated.present?

        { status: found ? STATUS_AGREES : STATUS_CONFLICT, topic: rule.topic.to_s, unit: rule.unit, headline: values,
          verified: [value] }
      end

      # An answer that states the question's case twice in the same words with
      # two figures, one of them the verified one ("Pour un travailleur avec
      # cinq ans d'ancienneté, le délai de préavis est de **15 semaines**" and,
      # lines later, "... est de **18 semaines**"; the run after round 11,
      # 2026-10-06, q01 run 1 fr_lisloi, a self-correction the note agreed
      # with): the other figure is a claim the answer also makes. Only the very
      # same frame counts (the text of the line or list item up to the figure,
      # emphasis, spacing and case aside, at least 12 characters), and only
      # when the question names its case: a base and its increment, a total and
      # the rows of a table each have their own words. Measured on the 558
      # figure rows: this moves q01's row alone, where a looser "two figures on
      # the case lines" moved 24 rows, 23 of them right.
      def restated_otherwise(rule, headline, value, question)
        return nil unless question_case_pattern(question)

        frame = ->(figure) { figure.item.to_s.gsub(/[*_]/, '').gsub(/[[:space:]]+/, ' ').strip.downcase }
        framed = headline.select { |figure| figure.unit == rule.unit && frame.call(figure).length >= 12 }
        clash = framed.group_by(&frame).values.find do |figures|
          figures.map(&:value).uniq.size > 1 && figures.map(&:value).include?(value)
        end
        clash && (clash.map(&:value).uniq - [value])
      end

      # An answer that highlights no age at all but gives a worker born in a
      # given year the ages the pension starts at, in plain text on the line
      # that names the year, and never the verified age anywhere (the run after
      # round 11, 2026-10-06, q10, three German-lane rows: "Si vous êtes né en
      # 1962, votre pension prendra cours au plus tôt le 1er février 2025 (à 63
      # ans) et au plus tard le 1er janvier 2030 (à 68 ans)" against 66): those
      # ages are the answer's claim. Only "à NN ans" and "âge de NN ans" count,
      # never an age the person reaches ("vous atteignez 63 ans en 2025"); and
      # an answer with a highlighted age keeps the rules above (v9 and v10:
      # a reached age on the year's line, "**66 ans**" in bold below it).
      START_AGE = /(?:(?<![[:alpha:]])à|âge\s+de)[\s (]*\z/i
      def unstated_start_ages(rule, stated, value, question)
        return nil unless rule.topic == :pension_age

        year = birth_year(question)
        return nil unless year

        year_line = /(?<!\d)#{year}(?!\d)/
        same_unit = stated.select { |figure| figure.unit == rule.unit }
        return nil if same_unit.any? { |figure| figure.value == value }

        ages = same_unit.select { |figure| figure.line.to_s.match?(year_line) && figure.preceding.to_s.match?(START_AGE) }
        return nil if ages.empty?

        { status: STATUS_CONFLICT, topic: rule.topic.to_s, unit: rule.unit, headline: ages.map(&:value).uniq,
          verified: [value] }
      end

      # The parts of the verified figure count only when they stand on one
      # line ("6 semaines avant ... et 9 semaines après"): v10 grader 1 found
      # a bold 15 and a bold "3 semaines supplémentaires" on separate lines
      # summed to the verified 18 while the answer said 15.
      def components_on_one_line?(rule, headline)
        return false unless rule.components

        headline.select { |figure| figure.unit == rule.unit }.group_by(&:line).values.any? do |figures|
          values = figures.map(&:value)
          rule.components.all? { |part| values.include?(part) }
        end
      end

      def other_quantities_removed(rule, figures)
        return figures unless rule.not_followed_by

        pattern = rule.not_followed_by == :alcohol_other_figure ? ALCOHOL_OTHER_FIGURE : rule.not_followed_by
        labelled = ->(figure) { rule.not_followed_by == :alcohol_other_figure && figure.item.to_s.match?(ALCOHOL_OTHER_LABEL) }
        figures.reject { |figure| figure.following.to_s.match?(pattern) || labelled.call(figure) }
      end

      # When a line of the answer names the question's own case ("Pour 5 ans
      # d'ancienneté : **15 semaines**", "née en 1962 ... **65 ans**"), the
      # figures of those lines speak for the question and the others do not:
      # grader 1 of v6 found two conflicts missed because a six-years example
      # elsewhere carried the rule figure in bold (q0015 t1). A total line
      # ("**Total : 18 semaines**") belongs to the case lines (v7 grader 1: the
      # parts on the case lines were flagged while the total stood below
      # them), and when the case lines write their figure in plain text
      # ("Base initiale : 15 semaines (pour une ancienneté de 5 ans)") that
      # plain figure speaks for the question rather than the bold figures of
      # the other examples (v7 grader 1: q0015 missed twice more). Without
      # such a line every figure counts, as before.
      TOTAL_LINE = /\A[\s*_>#-]*(?:total|au\s+total|soit|totaal|insgesamt|gesamt)#{WORD_END}/i
      THRESHOLD = /#{WORD_START}(?:ou|et|oder|und|of|en|or)\s+(?:plus|davantage|mehr|meer|more)#{WORD_END}/i
      def case_lines_only(headline, stated, rule, question)
        pattern = question_case_pattern(question)
        return [headline, stated] unless pattern

        case_line = ->(figure) { figure.line.to_s.match?(pattern) }
        unless (headline + stated).any?(&case_line)
          # No line names the question's case: a line that names another
          # seniority or career case does not speak for the question (v11
          # grader 1: a bold 18 "pour 6 ans d'ancienneté" answered for five
          # years, a bold 61 for "42 années" for a 43-year career).
          other = ->(figure) { other_case_line?(figure.line.to_s, question) }
          return [headline.reject(&other), stated.reject(&other)]
        end

        total_line = ->(figure) { figure.line.to_s.match?(TOTAL_LINE) }
        case_headline = headline.select { |figure| figure.unit == rule.unit && (case_line.call(figure) || total_line.call(figure)) }
        case_stated = stated.select { |figure| case_line.call(figure) || total_line.call(figure) }
        return [case_headline, case_stated] if case_headline.any?

        plain = case_stated.select { |figure| figure.unit == rule.unit }
        return [plain, case_stated] if plain.any?

        # The case lines carry no figure in the rule's unit, so every figure
        # counts, but not one on a line that names another case as a
        # threshold (the weekly run of 2026-10-05, q0015 twice: the 52-week cap
        # "pour dix-sept ans d'ancienneté ou plus" read as the answer for five
        # years). Only the threshold lines: v11's wrong 15 on a six-year line
        # stays compared.
        threshold = ->(figure) { figure.line.to_s.match?(THRESHOLD) && other_case_line?(figure.line.to_s, question) }
        [headline.reject(&threshold), stated.reject(&threshold)]
      end

      # A line that names a seniority or career case ("6 ans d'ancienneté",
      # "42 années de carrière") other than the question's.
      CASE_YEARS = /(?<![\d[:alpha:]])(?<value>\d{1,2}|[[:alpha:]]+(?:-[[:alpha:]]+){0,2})[ \t ]+(?:ans|années?)[ \t ]+
                    (?:d['’](?:ancienneté|activité|assurance)|de\s+(?:carrière|service|cotisations?)|civiles)/xi
      def other_case_line?(line, question)
        numbers = question_years(question)
        return false if numbers.empty?

        cases = line.to_enum(:scan, CASE_YEARS).filter_map { number_value(Regexp.last_match[:value]) }
        cases.any? && !cases.intersect?(numbers)
      end

      # The numbers the question names (its years, a birth year), as digits
      # and as the French number words, not inside a larger number.
      def question_case_pattern(question)
        numbers = question_years(question) + question.to_s.scan(/(?<!\d)(?:19|20)\d\d(?!\d)/).map(&:to_i)
        return nil if numbers.empty?

        forms = numbers.uniq.flat_map { |n| [n.to_s] + NumberWords::FRENCH_CARDINALS.select { |_, v| v.to_i == n }.keys }
        Regexp.new("(?<![\\d[:alpha:]])(?:#{forms.map { |f| Regexp.escape(f) }.join('|')})(?![\\d])", Regexp::IGNORECASE)
      end

      def figure_value(before)
        digits = before.match(DIGIT_VALUE)
        return digit_value(digits[:value]) if digits

        words = before.match(WORD_VALUE)
        return nil unless words

        spelled_value(words[:words])
      end

      # "61.500" is sixty-one thousand five hundred, "0,5" a half.
      def digit_value(text)
        return text.delete('.').tr(',', '.').to_f if text.match?(/\A\d{1,3}(?:\.\d{3})+(?:,\d+)?\z/)

        text.tr(',', '.').to_f
      end

      # The number the last words before a unit spell ("dix-huit", "vingt et
      # un"), "un an" and "une semaine" included.
      def spelled_value(words)
        tokens = words.split(/[ \-\u00a0]+/)
        tokens.length.downto(1) do |size|
          tail = tokens.last(size)
          next unless tail.all? { |word| number_word?(word) }

          tally = NumberWords.french(tail.join(' '))
          return tally.keys.first.to_f if tally.size == 1 && tally.values.first == 1
        end
        %w[un une].include?(tokens.last.downcase) ? 1.0 : nil
      end

      def number_word?(word)
        lower = word.downcase
        lower == 'et' || NumberWords::FRENCH_CARDINALS.key?(lower)
      end

      def amount(values, unit, language, dative: false)
        singular, plural, dative_plural = (language.to_s == 'fr' ? FRENCH_UNITS : GERMAN_UNITS).fetch(unit)
        plural = dative_plural if dative && language.to_s == 'de' && dative_plural
        name = values.all? { |value| format_number(value) == '1' } ? singular : plural
        numbers = values.map { |value| format_number(value) }
        "#{numbers.join(language.to_s == 'fr' ? ' et ' : ' und ')} #{name}"
      end

      def german_amount(values, unit)
        amount(values, unit, 'de')
      end

      def format_number(value)
        value == value.round ? value.round.to_s : value.to_s.tr('.', ',')
      end
    end

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    # The result with the note on top and the record when the headline
    # figure contradicts the verified source; the record alone when they
    # agree; the result itself when there is nothing to compare. Reads the
    # French answer (CONTEXT_KEY when the answer shown was made from it) and
    # the question it was reasoned on: the French question when the German
    # one was translated (GermanQuestionTranslation::CONTEXT_KEY), else the
    # reader's `question`. Never mutates `result`, never raises a
    # StandardError. language: the language of the note, that of the answer
    # shown ('de' on gesetzguide, 'fr' for a French answer).
    def apply(result, question:, language: 'de')
      return result unless result.is_a?(Hash)

      shown = result[:answer]
      french = result[GermanAnswerTranslation::CONTEXT_KEY] || shown
      return result unless shown.is_a?(String) && french.is_a?(String)

      reasoned_on = result[GermanQuestionTranslation::CONTEXT_KEY] || question
      detection = self.class.detect(french, question: reasoned_on)
      return result unless detection

      record = detection.merge(headline: detection[:headline].map { |value| self.class.send(:format_number, value) },
                               verified: detection[:verified].map { |value| self.class.send(:format_number, value) })
      @logger&.info("[GermanFigure] status=#{record[:status]} topic=#{record[:topic]} unit=#{record[:unit]} " \
                    "headline=#{record[:headline].join('/')} verified=#{record[:verified].join('/')}")
      out = result.merge(RECORD_KEY => record)
      return out unless detection[:status] == STATUS_CONFLICT

      noted = "#{self.class.note(detection, language: language)}\n\n#{shown}"
      out[:answer] = noted
      out[:error] = noted if result[:error].is_a?(String) && result[:error] == shown
      out[GermanAnswerTranslation::CONTEXT_KEY] = french
      out
    rescue StandardError => e
      @logger&.info("[GermanFigure] status=error error=#{e.class.name}")
      result
    end
  end
end
