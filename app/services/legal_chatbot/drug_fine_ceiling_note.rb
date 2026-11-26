# frozen_string_literal: true

module LegalChatbot
  # Sol 2026-11-25 23:00:07Z (#1556 on live 1.1.106): the answer put the 800,000 euro ceiling only on the art. 2ter
  # exception and left out the general one. Read in full on the production corpus on 2026-11-26, Dutch and French: the
  # Drugswet (1921022450) arts 2bis and 2ter as replaced by arts 4 and 5 of the law of 16 March 2026 (in force on
  # 1 September 2026), and Book I art. 52 (2024002052).
  # - Art. 52, § 1: with a main penalty of level 2 to 8 the judge may add a fine as an accessory penalty, from 200 euro to
  #   a ceiling per level (10,000 euro at level 3, 5,000 at level 2).
  # - Art. 2bis, § 6: for the offences of that article the fine reaches 800,000 euro at most, in derogation from
  #   art. 52, § 1, second paragraph.
  # - Art. 2ter: for the offences the King defines, level 1 with a fine of 200 euro, at most 400 euro on a repetition
  #   within a year of the first conviction and 800 euro on a new one (1°), or level 2 with a fine of at most 800,000
  #   euro, in derogation from art. 52, § 1, second paragraph, 7° (2°).
  # Each note rides on the header of its article's source block, as the deferred penalties note does
  # (LegalChatbotService#drug_fine_ceiling_note). Titles as the rows hold them: "Art. 2bis.", "Art. 2ter.".
  module DrugFineCeilingNote
    NUMAC = '1921022450'
    NOTES = {
      'nl' => {
        'art2bis' => 'geldboete: bij een straf van niveau 2 tot 8 kan de rechter een geldboete als bijkomende straf ' \
                     'opleggen (art. 52, § 1 Strafwetboek); voor de misdrijven van art. 2bis bedraagt die ten hoogste ' \
                     '800.000 euro (art. 2bis, § 6)',
        'art2ter' => 'art. 2ter geldt alleen voor de misdrijven die de Koning bepaalt: niveau 1 met een geldboete van 200 ' \
                     'euro (ten hoogste 400 euro bij herhaling binnen een jaar na de eerste veroordeling, 800 euro bij ' \
                     'nieuwe herhaling), of niveau 2 met een geldboete van ten hoogste 800.000 euro; voor de andere ' \
                     'misdrijven van art. 2bis geldt de grens van art. 2bis, § 6'
      },
      'fr' => {
        'art2bis' => 'amende : en cas de peine de niveau 2 à 8, le juge peut prononcer une amende comme peine accessoire ' \
                     "(art. 52, § 1er, du Code pénal) ; pour les infractions de l'article 2bis, elle s'élève à 800.000 euros " \
                     'au plus (art. 2bis, § 6)',
        'art2ter' => "l'article 2ter ne vise que les infractions que le Roi définit : une peine de niveau 1 avec une amende " \
                     "de 200 euros (400 euros au plus en cas de récidive dans l'année qui suit la première condamnation, " \
                     '800 euros en cas de nouvelle récidive), ou une peine de niveau 2 avec une amende de 800.000 euros au ' \
                     "plus ; pour les autres infractions de l'article 2bis vaut le plafond de l'article 2bis, § 6"
      }
    }.freeze

    module_function

    # The note for an article of the Drugswet that sets a fine ceiling, in the answer's language, or nil
    def note(numac, article_title, language)
      return nil unless numac.to_s == NUMAC

      NOTES.fetch(language.to_s == 'fr' ? 'fr' : 'nl')[article_title.to_s.delete(' .').downcase]
    end
  end
end
