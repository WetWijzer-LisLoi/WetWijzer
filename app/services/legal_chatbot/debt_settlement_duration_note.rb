# frozen_string_literal: true

module LegalChatbot
  # Sol 2026-11-26 07:05:47Z (#2797 "Hoelang duurt een collectieve schuldenregeling?", live 1.1.108): the answer cited
  # arts. 1675/10, /12 and /13 and their seven, five and three to five years, but stated the five years as an absolute
  # maximum, without the art. 51 route of art. 1675/12, § 2; art. 1675/13, § 2, rules art. 51 out.
  # Read in full in the corpus on 2026-11-26, Dutch and French: Judicial Code arts. 1675/12 and 1675/13 (1967101056) and
  # art. 51 (1967101052).
  # - Art. 1675/12, § 2: the judicial settlement lasts at most five years; art. 51 does not apply unless the debtor asks
  #   for it expressly and with reasons, to protect certain elements of his assets and to ensure the human dignity of the
  #   debtor and his family; the judge decides by a specially reasoned decision.
  # - Art. 1675/13, § 2: with a remission of capital, between three and five years; art. 51 does not apply.
  # - Art. 51: before they expire, the judge may shorten or extend time limits not set on pain of forfeiture; unless the
  #   law provides otherwise, an extension may not be longer than the original time limit, and a later one is allowed only
  #   for serious reasons and by a reasoned decision.
  # Each note rides on the header of its article's source block (LegalChatbotService#debt_settlement_duration_note), and
  # only while the article's text holds the sentences it restates, in Dutch or in French: an amended text gets no note.
  # Sol 2026-11-26 11:02:56Z: the note checked the text of art. 1675/12 alone while it repeated the rules of art. 51. It
  # now restates art. 1675/12 only; art. 51 itself is pinned for the duration question, so its current text is in the
  # context.
  module DebtSettlementDurationNote
    NUMAC = '1967101056'
    # article => { 'held' => the sentences of § 2 as each language's row holds them, language => the note }
    NOTES = {
      'art1675/12' => {
        'held' => {
          'nl' => ['die de vijf jaar niet mag overschrijden', 'is artikel 51 niet van toepassing',
                   'uitdrukkelijk en met opgave van redenen'],
          'fr' => ['qui ne peut excéder cinq ans', "L'article 51 n'est pas d'application, à moins que",
                   'de manière expresse et motivée']
        },
        'nl' => 'looptijd (§ 2): ten hoogste vijf jaar, maar de schuldenaar kan uitdrukkelijk en met opgave van redenen ' \
                'vragen dat artikel 51 toch van toepassing is, om bepaalde elementen van zijn vermogen te beschermen en de ' \
                'menselijke waardigheid van de schuldenaar en zijn gezin te verzekeren; de rechter beslist bij bijzonder ' \
                'gemotiveerde beslissing. De vijf jaar zijn dus geen absolute grens.',
        'fr' => 'durée (§ 2) : cinq ans au plus, mais le débiteur peut solliciter de manière expresse et motivée que ' \
                "l'article 51 s'applique, en vue de sauvegarder certains éléments de son patrimoine et d'assurer le respect " \
                'de la dignité humaine du débiteur et de sa famille ; le juge statue par une décision spécialement motivée. ' \
                'Les cinq ans ne sont donc pas une limite absolue.'
      },
      'art1675/13' => {
        'held' => {
          'nl' => ['die ligt tussen drie en vijf jaar', 'Artikel 51 is niet van toepassing'],
          'fr' => ['qui est comprise entre trois et cinq ans', "L'article 51 n'est pas d'application"]
        },
        'nl' => 'looptijd (§ 2): tussen drie en vijf jaar; artikel 51 (de verlenging van termijnen door de rechter) is niet ' \
                'van toepassing.',
        'fr' => "durée (§ 2) : entre trois et cinq ans ; l'article 51 (la prorogation des délais par le juge) n'est pas " \
                "d'application."
      }
    }.freeze

    module_function

    # The note for art. 1675/12 or 1675/13 in the answer's language, while the article's text holds § 2 as read; or nil
    def note(numac, article_title, language, article_text)
      return nil unless numac.to_s == NUMAC

      entry = NOTES[article_title.to_s.delete(' .').downcase]
      return nil unless entry

      text = article_text.to_s.squish
      return nil unless entry.fetch('held').values.any? { |sentences| sentences.all? { |sentence| text.include?(sentence) } }

      entry.fetch(language.to_s == 'fr' ? 'fr' : 'nl')
    end
  end
end
