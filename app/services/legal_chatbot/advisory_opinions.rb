# frozen_string_literal: true

module LegalChatbot
  # The Council of State's Legislation section advises on draft law before it is
  # enacted. Those opinions live in the same table as its rulings and reach the
  # model through the same retrieval, but they are not case law: they are advice
  # on a text that may since have been amended, withdrawn, or passed unchanged.
  #
  # Labelled "RECHTSPRAAK" with an "ECLI" and a "Hof", an opinion reads as a
  # judgment, and an answer built on one would state as settled law what is in
  # fact a legislative adviser's reading of a draft. Hence a label of its own,
  # wherever a case block is built for the model.
  module AdvisoryOpinions
    KEY_PREFIX = 'RVSADV:'

    module_function

    def advisory?(case_number)
      case_number.to_s.start_with?(KEY_PREFIX)
    end

    # The number as the Council itself cites it: "advies 74.123/1".
    def number(case_number)
      case_number.to_s.delete_prefix(KEY_PREFIX).split(':').first
    end

    def source_label(language)
      language.to_s == 'fr' ? "AVIS CONSEIL D'ÉTAT (LÉGISLATION)" : 'ADVIES RAAD VAN STATE (WETGEVING)'
    end

    # The header lines for one context block, so every builder says the same
    # thing: what it is, which number, and that it speaks to a draft.
    def context_header(case_number, court, language)
      if language.to_s == 'fr'
        ["Avis: #{number(case_number)}",
         "Instance: #{court.presence || "Conseil d'État, section de législation"}",
         'Nature: avis sur un projet de législation, rendu avant son adoption - pas une décision de justice']
      else
        ["Advies: #{number(case_number)}",
         "Instantie: #{court.presence || 'Raad van State, afdeling Wetgeving'}",
         'Aard: advies over een ontwerp van regelgeving, gegeven vóór de vaststelling ervan - geen rechterlijke uitspraak']
      end
    end
  end
end
