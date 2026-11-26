# frozen_string_literal: true

module LegalChatbot
  # Sol 2026-11-25 23:21:19Z (#2548 "Hoeveel RSZ werknemer?" on live 1.1.106): the answer gave the four worker rates of
  # art. 38, § 2 of the law of 29 June 1981 on the general principles of social security for workers (1981001048), its
  # card 5, but refused their total. Read on the production corpus on 2026-11-26, Dutch and French, §§ 1 and 2 in full:
  # the contributions are computed on the full wage of art. 23 (§ 1); a worker pays 7.5% for pensions, 1.15% for
  # sickness and invalidity insurance (benefits), 0.87% for employment and unemployment and 3.55% for sickness and
  # invalidity insurance (medical care), with other rates for miners (§ 2); § 1 names the law of 20 December 1999 on
  # the work bonus and other reductions of the personal contributions. The note rides on the header of art. 38's
  # source block, as the Drugswet ceiling notes do (LegalChatbotService#worker_contribution_note).
  module WorkerContributionNote
    NUMAC = '1981001048'
    NOTES = {
      'nl' => 'werknemersbijdragen (§ 2): voor een werknemer die onder de vier gewone regelingen valt samen 13,07 % van het ' \
              'volledige loon (art. 23): 7,5 % pensioenen, 1,15 % ziekte- en invaliditeitsverzekering (uitkeringen), 0,87 % ' \
              'werkloosheid en 3,55 % ziekte- en invaliditeitsverzekering (geneeskundige verzorging); vóór de verminderingen ' \
              'van de persoonlijke bijdragen, zoals de werkbonus (wet van 20 december 1999); voor mijnwerkers gelden andere voeten',
      'fr' => 'cotisations du travailleur (§ 2) : pour un travailleur soumis aux quatre régimes ordinaires, 13,07 % de la ' \
              'rémunération complète (art. 23) au total : 7,5 % pensions, 1,15 % assurance maladie-invalidité (indemnités), ' \
              '0,87 % emploi et chômage et 3,55 % assurance maladie-invalidité (soins de santé) ; avant les réductions des ' \
              "cotisations personnelles, comme le bonus à l'emploi (loi du 20 décembre 1999) ; d'autres taux pour les ouvriers " \
              'mineurs'
    }.freeze

    # Art. 38, § 2 as the Dutch and the French rows hold it (read in full on 2026-11-26). Sol 2026-11-26 02:34:41Z: the
    # total follows its source, so the note is given only while the text it rides on holds these four rates; an amended
    # rate, or a text without § 2, gets no note rather than a stale total labelled as the current art. 38.
    RATES = {
      'nl' => ['1° (7,5 pct.) van het bedrag van zijn loon', '2° 1,15 pct. van het bedrag van zijn loon',
               '3° 0,87 pct. van het bedrag van zijn loon', '4° (3,55 pct.) van het bedrag van zijn loon'],
      'fr' => ['1° (7,5 p.c.) du montant de sa rémunération', '2° 1,15 p.c. du montant de sa rémunération',
               '3° 0,87 p.c. du montant de sa rémunération', '4° (3,55 p.c.) du montant de sa rémunération']
    }.freeze

    module_function

    # The note for art. 38 of the 1981 law, in the answer's language, or nil when the text does not hold the four rates
    def note(numac, article_title, language, article_text)
      return nil unless numac.to_s == NUMAC && article_title.to_s.delete(' .').downcase == 'art38'

      text = article_text.to_s.squish
      return nil unless RATES.values.any? { |rates| rates.all? { |rate| text.include?(rate) } }

      NOTES.fetch(language.to_s == 'fr' ? 'fr' : 'nl')
    end
  end
end
