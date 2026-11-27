# frozen_string_literal: true

module LegalChatbot
  # Sol 2026-11-27 09:38:22Z (#304 "Hoeveel werkloosheidsuitkering krijg ik na een arbeidsongeval?", live 1.1.115): the
  # answer now tells temporary from permanent incapacity and links art. 61, § 2, but "the temporary side says only "in
  # beginsel"; it never explains the actual Art. 61 §2 second-paragraph exception for temporary unemployment when certain
  # work is permitted subject to suspension or temporary reduction of the compensation. Please cover that in the rendered
  # answer." The unemployment rule note (LegalFactProvider) states the exception; the generated text can leave it out.
  #
  # Art. 61, § 2, second paragraph, of the unemployment decree (1991013192), read in full in NL and FR on 2026-11-27: the
  # temporarily unfit worker can nevertheless have benefits as temporarily unemployed when the insurance scheme that
  # applies allows certain work subject to suspension or temporary reduction of the right to compensation.
  #
  # Under a question on unemployment benefit after an accident or an occupational disease
  # (LegislationSearch::ACCIDENT_UNEMPLOYMENT_PATTERN), an answer that does not state the exception gets one short
  # paragraph right after the block that speaks of the temporary incapacity (else of art. 61, else its first block).
  module AccidentUnemploymentException
    VERSION = 1
    HREF = '/laws/1991013192#art-61'
    TEXT = {
      'nl' => "**Uitzondering bij tijdelijke arbeidsongeschiktheid ([art. 61, § 2, tweede lid](#{HREF})):** wie tijdelijk " \
              'volledig of gedeeltelijk arbeidsongeschikt is, kan toch uitkeringen als tijdelijk werkloze genieten wanneer ' \
              'de toepasselijke verzekeringsregeling toestaat dat bepaalde arbeid wordt verricht onder voorbehoud van ' \
              'schorsing of tijdelijke vermindering van het recht op vergoeding.',
      'fr' => "**Exception en cas d'incapacité temporaire ([art. 61, § 2, alinéa 2](#{HREF})) :** le travailleur en incapacité " \
              'temporaire, totale ou partielle, peut toutefois bénéficier des allocations en tant que chômeur temporaire ' \
              "lorsque le régime d'assurance applicable l'autorise à fournir certaines prestations de travail sous réserve " \
              "de suspension ou de réduction temporaire de son droit à l'indemnité.",
      'de' => "**Ausnahme bei vorübergehender Arbeitsunfähigkeit ([Art. 61 § 2 Abs. 2](#{HREF})):** Wer vorübergehend ganz " \
              'oder teilweise arbeitsunfähig ist, kann dennoch Leistungen als zeitweilig arbeitslose Person erhalten, wenn ' \
              'die anwendbare Versicherungsregelung bestimmte Arbeit unter Vorbehalt der Aussetzung oder vorübergehenden ' \
              'Kürzung des Entschädigungsanspruchs erlaubt.',
      'en' => "**Exception for temporary incapacity ([art. 61, § 2, second paragraph](#{HREF})):** a worker who is " \
              'temporarily fully or partly unfit for work can still receive benefits as temporarily unemployed when the ' \
              'applicable insurance scheme allows certain work subject to suspension or temporary reduction of the right ' \
              'to compensation.'
    }.freeze
    # The answer states the exception already: temporary unemployment together with the suspension or reduction. The
    # paragraph says both in each language, so a second pass adds nothing.
    STATED_UNEMPLOYED = /tijdelijk\s+werkloz\p{L}*|ch[ôo]meurs?\s+temporaires?|zeitweilig\s+arbeitslos\p{L}*|temporarily\s+unemployed/iu
    STATED_RESERVE = /(?<![[:alpha:]])(?:schorsing|vermindering|suspension|r[ée]duction|aussetzung|k[üu]rzung|reduction)(?![[:alpha:]])/iu
    # Where the answer speaks of the temporary incapacity, or of art. 61
    TEMPORARY_INCAPACITY = /tijdelijk\p{L}*[^.\n]{0,60}?ongeschikt\p{L}*|\p{L}*ongeschikt\p{L}*[^.\n]{0,60}?tijdelijk\p{L}*|
                            incapacit[ée]s?\s+(?:de\s+travail\s+)?temporaires?|temporairement\s+(?:inapte|incapable)|
                            vor[üu]bergehend\p{L}*[^.\n]{0,30}?unf[äa]hig\p{L}*|zeitweilig\p{L}*[^.\n]{0,30}?unf[äa]hig\p{L}*|
                            temporar\p{L}*[^.\n]{0,30}?(?:incapacit\p{L}*|unfit|disab\p{L}*)/iux
    ART_61 = /(?<![[:alnum:]])art(?:ikel|icle|\.)?[[:space:]]*61(?![[:digit:]])|\#art-61(?![[:digit:]])/iu

    module_function

    def apply(text, question:, language: 'nl')
      return text if text.blank? || !question.to_s.match?(LegislationSearch::ACCIDENT_UNEMPLOYMENT_PATTERN)
      return text if text.match?(STATED_UNEMPLOYED) && text.match?(STATED_RESERVE)

      lines = text.split("\n", -1)
      anchor = first_line(lines, TEMPORARY_INCAPACITY) || first_line(lines, ART_61) || lines.index { |line| !line.strip.empty? }
      return text unless anchor

      stop = anchor
      stop += 1 while stop + 1 < lines.size && !lines[stop + 1].strip.empty?
      paragraph = TEXT.fetch(TEXT.key?(language.to_s) ? language.to_s : 'nl')
      rest = lines[(stop + 1)..] || []
      [*lines[0..stop], '', paragraph, *(rest.first.to_s.strip.empty? ? [] : ['']), *rest].join("\n")
    end

    # The first line outside a quotation that matches
    def first_line(lines, pattern)
      lines.index { |line| !line.match?(IndexedAmounts::BLOCKQUOTE) && line.match?(pattern) }
    end
  end
end
