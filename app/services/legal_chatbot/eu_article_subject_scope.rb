# frozen_string_literal: true

module LegalChatbot
  # Sol 2026-11-23 05:02:05Z: a question that raises an EU act's subject keeps every article of that act that a word
  # search finds, also one whose own subject is narrower than the act's: the e-commerce directive's art. 7 on a web shop
  # that accepts a prescription, GDPR arts. 8 and 83 on an ordinary storage of customer data. Such an article stays
  # only when the question raises its own subject; a row an EU topic plan or the question itself targets (eu_targeted)
  # stays before this scope is asked. The headings, read in the EU corpus (NL) on 2026-11-23: Directive 2000/31/EC
  # art. 7 "Ongevraagde commerciële communicatie"; Regulation (EU) 2016/679 art. 8 "Voorwaarden voor de toestemming
  # van kinderen met betrekking tot diensten van de informatiemaatschappij" and art. 83 "Algemene voorwaarden voor het
  # opleggen van administratieve geldboeten".
  module EuArticleSubjectScope
    B = '(?<![[:alnum:]])'
    E = '(?![[:alnum:]])'
    # A minor's age, in the words that give one (Sol 2026-11-23 14:42:44Z: "a 13-year-old asking explicitly about
    # personal consent in an app can miss the rule"): "ik ben 13", "13-jarige", "13 years old", "j'ai 13 ans", "onder de
    # 16". A number of days, euros or per cent after "ik ben" is no age, and "vijf jaar" alone is a retention period.
    # Sol 2026-11-23 15:53:08Z: "for under 6 months" is a duration: after "under", "onder de", "unter" or "moins de" a
    # time unit makes the number a period ("onder de 16 jaar" and "unter 16 Jahren" stay ages), while "jonger dan",
    # "younger than" and "jünger als" compare ages whatever follows. Sol 2026-11-24 01:24:47Z: "les moins de 16 ans"
    # and "les utilisateurs de moins de 15 ans" name the young, not a period.
    MINOR = '(?:1[0-7]|[1-9])(?!\d)'
    UPTO18 = '(?:1[0-8]|[1-9])(?![\d.,])'
    NOT_AN_AGE = '(?![.,]\d)(?!\s*(?:%|euro|dagen|tage|days|jours|weken|wochen|weeks|semaines|maanden|monate|months|mois|uur|' \
                 'uren|stunden|hours|heures|minuten|minutes|keer|mal|times|fois|procent|prozent|percent))'
    AGE = "(?:ik\\s+ben|ich\\s+bin|i\\s+am|i['’]m|j['’]ai)\\s+(?:pas\\s+|erst\\s+|only\\s+|just\\s+|seulement\\s+|moins\\s+de\\s+)?#{MINOR}" \
          "(?:\\s+(?:jaar|jahre|years|ans))?#{NOT_AN_AGE}|" \
          "#{MINOR}(?:[\\s-]*(?:jarige?n?|j[äa]hrige?[nmrs]?|year[\\s-]olds?)|\\s+(?:jaar\\s+oud|jahre\\s+alt|years?\\s+old))|" \
          "[âa]g[ée]e?s?\\s+de\\s+(?:#{MINOR}|moins\\s+de\\s+#{UPTO18})\\s+ans|aged\\s+#{MINOR}|" \
          "(?:les|des|aux|enfants?|jeunes|mineurs?|utilisateurs?|utilisatrices?|personnes?|ceux|celles)\\s+(?:de\\s+|d['’]\\s*)?" \
          "moins\\s+de\\s+#{UPTO18}\\s+ans|" \
          "(?:jonger\\s+dan|younger\\s+than|j[üu]nger\\s+als)\\s+#{UPTO18}|" \
          "onder\\s+de\\s+#{UPTO18}(?!\\s*(?:maand|maanden|week|weken|dag|dagen|uur|uren|minuten))|" \
          "unter\\s+#{UPTO18}(?!\\s*(?:monat\\p{L}*|woche\\p{L}*|tag|tage|tagen|stunde\\p{L}*|minute\\p{L}*))|" \
          "(?:under|below|moins\\s+de)\\s+#{UPTO18}(?!\\s*(?:years?|months?|weeks?|days?|hours?|minutes?|ans?|mois|semaines?|" \
          'jours?|heures?))'.freeze
    # [base CELEX, article number] => the words that raise the article's own subject
    SUBJECTS = {
      %w[32000L0031 7] => /#{B}(?:ongevraagd\p{L}*|ongewenst\p{L}*|reclame\p{L}*|marketing\p{L}*|spam\p{L}*|nieuwsbrie\p{L}*|
                           commerci[eë]le\s+communicatie\p{L}*|publicit\p{L}*|prospection\p{L}*|non\s+sollicit\p{L}*|newsletters?|
                           communications?\s+commerciales?|werbung\p{L}*|unerw[üu]nscht\p{L}*|unaufgefordert\p{L}*|unsolicited|
                           advertis\p{L}*|commercial\s+communications?|opt-?out)#{E}/iux,
      # Sol 2026-11-23 14:42:44Z: "What kind of customer data may we keep?" and "klantgegevens die ouder zijn dan vijf
      # jaar" raised it. The English kind is a type, so "kind" after an English determiner is none; a single Dutch
      # parent needs a determiner and is no "ouder dan" (older than); a parent company and a minor breach are no child.
      %w[32016R0679 8] => /#{B}(?:(?<!what\s|which\s|this\s|that\s|these\s|those\s|any\s|some\s|every\s|each\s|the\s|a\s|one\s|
                          other\s|same\s|different\s|certain\s|no\s|all\s|what's\s)kind|kinderen|minderjarig\p{L}*|jongere\p{L}*|
                          tiener\p{L}*|ouders|ouderlijk\p{L}*|
                          (?:de|een|elke|iedere|mijn|zijn|haar|uw|je|jouw|hun|onze|beide|andere|tweede)\s+ouder(?!\s+dan)|
                          leeftijd\p{L}*|enfants?|mineur(?:e|es|s)?|adolescent\p{L}*|
                          parents?(?!\s+(?:company|companies|undertakings?|entit(?:y|ies)|firms?|groups?|organi[sz]ations?))|
                          parental\p{L}*|kindern?|minderj[äa]hrig\p{L}*|jugendlich\p{L}*|eltern\p{L}*|children|child|minors|
                          minor(?!\s+(?:data\s+|security\s+|privacy\s+)?(?:breach\p{L}*|change\p{L}*|issue\p{L}*|error\p{L}*|
                          incident\p{L}*|infringement\p{L}*|
                          violation\p{L}*|offen[cs]e\p{L}*|amendment\p{L}*|update\p{L}*|detail\p{L}*|role|part|risk\p{L}*))|
                          teenagers?|[âa]ge|#{AGE})#{E}/iux,
      %w[32016R0679 83] => /#{B}(?:\p{L}*boete\p{L}*|sanctie\p{L}*|amendes?|sanctions?|bu(?:ß|ss)geld\p{L}*|geldbu(?:ß|ss)e\p{L}*|
                           fines?|penalt\p{L}*)#{E}/iux
    }.freeze

    module_function

    # Whether the question raises the own subject of an EU article that has one; any other row: true
    def source_relevant?(row, question)
      return true unless row.is_a?(Hash) && field(row, :kind) == 'article'

      asked = SUBJECTS[[base_celex(field(row, :celex)), field(row, :unit_number)]]
      asked.nil? || question.to_s.match?(asked)
    end

    # The base act of a consolidated CELEX: 02016R0679-20160504 is 32016R0679
    def base_celex(celex) = celex.to_s.sub(/\A0/, '3').sub(/-\d{8}\z/, '')

    def field(row, key) = (row[key] || row[key.to_s]).to_s
    private_class_method :field
  end
end
