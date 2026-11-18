# frozen_string_literal: true

module LegalChatbot
  # Sol 2026-11-18 13:42:47Z: the equality pins (Constitution Arts. 10 and 11)
  # and the intestacy pins (Civil Code Book 4 Arts. 4.10, 4.16 and 4.17) match
  # on subject words, so a question about a foreign constitution or a foreign
  # law of succession would get Belgian provisions pinned into its answer.
  #
  # Only explicit wording counts: a constitution every mention of which is
  # foreign ("de Franse grondwet", "la Constitution des États-Unis", "the US
  # constitution", "das Grundgesetz"), or a named foreign legal system ("naar
  # Frans recht", "en droit allemand", "under Dutch law", "nach deutschem
  # Erbrecht"). A question that also says Belgian ("vergelijk met het Belgische
  # recht") keeps the pins. Where someone lives or died is not a choice of law
  # and changes nothing here. An unqualified "Grondwet" or "Verfassung" is the
  # Belgian one, also on the German-language site.
  #
  # Sol 2026-11-18 16:15:53Z: only Belgian law counts as Belgian here, not a
  # Belgian person ("Ik ben Belg; wie erft naar Frans recht?" asks French law),
  # and an unqualified Grondwet beside the Grundgesetz is a comparison.
  module ForeignLegalSystemScope
    CONSTITUTION = ExplicitArticleRequest::CONSTITUTION
    # Book 4 and the two old Civil Code parts the succession keywords inject (CoreLawMappings).
    BELGIAN_SUCCESSION_LAWS = %w[2022B30600 1804032152 1804032153].freeze
    BASIC_LAW = /\bGrundgesetz\p{L}*\b/iu
    # Nationality words in their exact forms: "Nederlandstalig", "Franstalig"
    # and "Duitstalig" describe a Belgian language, not another country.
    NATIONALITY = /
      \b(?:frans|franse|fran[çc]ais|fran[çc]aise|french|franz[öo]sisch\p{L}*|
          nederlands|nederlandse|n[ée]erlandais|n[ée]erlandaise|dutch|niederl[äa]ndisch\p{L}*|
          duits|duitse|allemand|allemande|german|deutsch\p{L}*|
          engels|engelse|anglais|anglaise|english|englisch\p{L}*|brits|britse|britannique|british|britisch\p{L}*|
          amerikaans|amerikaanse|am[ée]ricain|am[ée]ricaine|american|amerikanisch\p{L}*|(?-i:US|U\.S\.)|
          luxemburgs|luxemburgse|luxembourgeois|luxembourgeoise|luxembourgish|luxemburgisch\p{L}*|
          spaans|spaanse|espagnol|espagnole|spanish|spanisch\p{L}*|italiaans|italiaanse|italien|italienne|italian|italienisch\p{L}*|
          zwitsers|zwitserse|suisse|swiss|schweizer\p{L}*|portugees|portugese|portugais|portugaise|portuguese|portugiesisch\p{L}*|
          marokkaans|marokkaanse|marocain|marocaine|moroccan|marokkanisch\p{L}*|turks|turkse|turc|turque|turkish|t[üu]rkisch\p{L}*|
          pools|poolse|polonais|polonaise|polish|polnisch\p{L}*|roemeens|roemeense|roumain|roumaine|romanian|rum[äa]nisch\p{L}*)\b
    /ix
    COUNTRY = /
      (?:frankrijk|france|frankreich|nederland|pays[-\s]bas|netherlands|niederlanden?|duitsland|allemagne|germany|deutschland|
         engeland|angleterre|england|verenigd\s+koninkrijk|royaume[-\s]uni|united\s+kingdom|vereinigten\s+k[öo]nigreich|
         verenigde\s+staten|[ée]tats[-\s]unis|united\s+states|vereinigten\s+staaten|luxemburg|luxembourg|spanje|espagne|spain|spanien|
         itali[ëe]|italie|italy|italien|zwitserland|suisse|switzerland|schweiz|marokko|maroc|morocco|turkije|turquie|turkey|t[üu]rkei)
    /ix
    LAW_NOUN = /(?:erfrecht|recht|wet|wetgeving|wetten|law|laws|Erbrecht|Recht|Gesetz\p{L}*)/i
    # Belgian law, never a Belgian person: the adjective before a law word, also
    # coordinated with a foreign one ("naar Belgisch en naar Frans recht"), a law
    # word with "belge" or "van België", an elliptical "het Belgische", or a
    # Belgian court. "Belg", "Belgen" and "als Belgische" name people.
    BELGIAN_ADJECTIVE = /(?:belgisch\p{L}*|belgian|belge)/i
    BELGIAN_LAW_WORD = /(?:#{LAW_NOUN.source}|grondwet|constitution|Verfassung|droit|loi|l[ée]gislation|code|wetboek)/i
    BELGIAN = /
      \b#{BELGIAN_ADJECTIVE.source}\s+
        (?:(?:en|et|and|und|or|ou|of|oder)\s+(?:(?:het|de|le|la|l['’]|the|das|dem|den|naar|nach|under|au)\s+){0,2}#{NATIONALITY.source}\s+)?
        #{BELGIAN_LAW_WORD.source}\b|
      \b(?:droit|loi|l[ée]gislation|constitution|code)\s+(?:\p{L}+\s+)?belge\b|
      \b#{BELGIAN_LAW_WORD.source}\s+(?:van|of|de|du|des|der|in|von|en)\s+(?:(?:het|de|la|le|l['’]|the|den|dem)\s+)?
        (?:belgi[ëe]|belgique|belgium|belgien)\b|
      \b(?:het|de|le|la|the|das|dem|den|die)\s+#{BELGIAN_ADJECTIVE.source}\s*(?:[?.!;:]|$)|
      \bgrondwettelijk\s+hof\b|\bcour\s+constitutionnelle\b|\bVerfassungsgerichtshof\b
    /ix
    FOREIGN_LEGAL_SYSTEM = /
      #{NATIONALITY.source}\s+(?:(?:inheritance|succession)\s+)?#{LAW_NOUN.source}\b|
      \b(?:droit|loi|l[ée]gislation)\s+(?:successoral\s+|des\s+successions\s+)?#{NATIONALITY.source}|
      \b(?:recht|erfrecht|wetgeving|law|laws|droit|l[ée]gislation|Recht|Erbrecht)\s+(?:van|of|de|du|des|der|in|von|en)\s+
        (?:(?:het|de|la|le|l['’]|the|den|dem)\s+)?#{COUNTRY.source}\b
    /ix

    module_function

    # Every constitution the question names is a foreign one.
    def foreign_constitution_only?(question)
      text = normalized(question)
      return false if text.match?(BELGIAN)

      named = text.match?(ExplicitArticleRequest::CONSTITUTION_NAME)
      return false if named && ExplicitArticleRequest.instrument_mentions(text).any? { |mention| mention[:numac] == CONSTITUTION }

      named || text.match?(BASIC_LAW)
    end

    # The question asks under a named foreign legal system, and names no Belgian one.
    def foreign_legal_system?(question)
      text = normalized(question)
      !text.match?(BELGIAN) && text.match?(FOREIGN_LEGAL_SYSTEM)
    end

    # The Belgian laws core-law injection must not add on its own: the
    # Constitution beside a foreign constitution or legal system, the Civil
    # Code's succession law beside a foreign legal system.
    def belgian_core_laws_to_skip(question)
      foreign_system = foreign_legal_system?(question)
      skipped = []
      skipped << CONSTITUTION if foreign_system || foreign_constitution_only?(question)
      skipped.concat(BELGIAN_SUCCESSION_LAWS) if foreign_system
      skipped
    end

    def normalized(question) = question.to_s.gsub(/[[:space:]]+/, ' ')
  end
end
