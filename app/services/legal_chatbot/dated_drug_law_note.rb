# frozen_string_literal: true

module LegalChatbot
  # Sol 2026-11-25 12:35:40Z (#1556, #1557, option b): production holds the Drugswet (NUMAC 1921022450) only as in force
  # since 1 September 2026. Its art. 2bis was replaced by art. 4 of the law of 16 March 2026, in force on that day, and
  # the corpus keeps one row per language with no earlier version; the article-history pilot (DatedArticleAnswer) is
  # local only. A drug offence question about facts before that day therefore gets, under the answer:
  # - that our sources hold today's text;
  # - that the text in force at the time of the facts is not among them;
  # - the official version history on Justel.
  # The comparison of the regimes under the more-favourable-law rule (Book I art. 2) is the prompts' transition rule; this
  # note adds what the sources cannot give. The scope is that of the drug pins (LegislationSearch::DRUG_OFFENCE_PATTERN)
  # and of the old-Code date (LegislationSearch::LEGACY_CRIMINAL_FACT_PATTERN, built from CriminalCodeCommencement).
  module DatedDrugLawNote
    NUMAC = '1921022450'
    # The law's Justel pages (legislation.justel of its Dutch and French rows, read on 2026-11-25)
    JUSTEL = { 'nl' => 'https://www.ejustice.just.fgov.be/eli/wet/1921/02/24/1921022450/justel',
               'fr' => 'https://www.ejustice.just.fgov.be/eli/loi/1921/02/24/1921022450/justel' }.freeze
    TEXT = {
      'nl' => '**Let op:** onze bronnen geven de Drugswet (wet van 24 februari 1921) zoals die geldt sinds %<date>s. De ' \
              'tekst die gold op het moment van de feiten staat niet in onze bronnen; de officiële versiegeschiedenis ' \
              'staat op [Justel](%<url>s).',
      'fr' => "**Attention :** nos sources donnent la loi du 24 février 1921 sur les stupéfiants telle qu'elle s'applique " \
              "depuis le %<date>s. Le texte applicable au moment des faits n'est pas dans nos sources ; l'historique " \
              'officiel des versions se trouve sur [Justel](%<url>s).',
      'de' => '**Hinweis:** Unsere Quellen geben das Gesetz vom 24. Februar 1921 über Betäubungsmittel in der Fassung, die ' \
              'seit dem %<date>s gilt. Der zur Tatzeit geltende Text ist nicht in unseren Quellen; die amtliche ' \
              'Versionsgeschichte steht auf [Justel](%<url>s).',
      'en' => '**Note:** our sources give the Act of 24 February 1921 on narcotics as in force since %<date>s. The text ' \
              'in force when the facts took place is not among our sources; the official version history is on ' \
              '[Justel](%<url>s).'
    }.freeze
    # A German answer links the French text (GesetzGuide's law shortcuts open the French text), an English one the Dutch
    LINK_LANGUAGE = { 'nl' => 'nl', 'fr' => 'fr', 'de' => 'fr', 'en' => 'nl' }.freeze

    module_function

    def applies?(question)
      text = question.to_s
      text.match?(LegislationSearch::DRUG_OFFENCE_PATTERN) && text.match?(LegislationSearch::LEGACY_CRIMINAL_FACT_PATTERN)
    end

    # The answer with the note under it, once. Sol 16:22:46Z: an answer may cite Justel without saying that the former
    # text is missing, so the note itself, not its link, decides whether it is there already.
    def apply(answer, question:, language:)
      return answer unless applies?(question)

      key = TEXT.key?(language.to_s) ? language.to_s : 'nl'
      note = format(TEXT.fetch(key), date: CriminalCodeCommencement.date_text(key), url: JUSTEL.fetch(LINK_LANGUAGE.fetch(key)))
      return answer if answer.to_s.include?(note)

      "#{answer.to_s.rstrip}\n\n#{note}"
    end
  end
end
