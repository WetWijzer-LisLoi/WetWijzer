# frozen_string_literal: true

module LegalChatbot
  # Shared activation for telephone-marketing retrieval and official GDPR
  # facts. A grant/project "call", database, or spam email is not sufficient.
  module TelemarketingPrivacyIntent
    PHONE_CONTACT_PATTERN = /\b(?:telemarketing|spam[-\s]*(?:calls?|callers?|oproep\p{L}*|anrufe?)|cold\s+calls?|(?:unsolicited|unwanted|marketing|advertising|sales|direct\s+marketing)\s+(?:(?:phone|telephone)\s+)?calls?|(?:ongewenste|ongevraagde)\s+(?:telefoontjes|telefoonoproep\p{L}*|oproep\p{L}*)|telefonische\s+(?:direct\s+)?marketing|telefonische\s+verkoop|reclameoproep\p{L}*|d[ée]marchage\s+t[ée]l[ée]phonique|prospection\s+t[ée]l[ée]phonique|appels?\s+(?:ind[ée]sirables?|non\s+sollicit[ée]s?|spam)|Werbeanruf(?:e|en)?|Telefonwerbung|unerw[üu]nschte\s+Anrufe?)\b/iu
    PRIVACY_RIGHTS_PATTERN = /\b(?:GDPR|AVG|RGPD|DSGVO|privacy|gegevensbescherming|datenschutz|persoonsgegevens|personal\s+data|donn[ée]es\s+personnelles|personenbezogene\s+Daten|database|databank|source|origin|herkomst|bron|Herkunft|remove\p{L}*|removal|delet\p{L}*|eras\p{L}*|verwijder\p{L}*|wissen|schrappen|effac\p{L}*|supprim\p{L}*|l[öo]sch\p{L}*|objection|oppose\p{L}*|opposition|verzet|Widerspruch|consent|toestemming|consentement|Einwilligung|stop|stopp\p{L}*)\b|\b(?:where|waar|o[ùu]|woher)\b.{0,80}\b(?:got|obtain\p{L}*|get|nummer|number|num[ée]ro|Nummer)\b/iu
    QUESTION_PATTERN = /\A(?=.*#{PHONE_CONTACT_PATTERN})(?=.*#{PRIVACY_RIGHTS_PATTERN}).*\z/imu

    def self.topic?(question)
      question.to_s.gsub(/[[:space:]]+/, ' ').match?(QUESTION_PATTERN)
    end
  end
end
