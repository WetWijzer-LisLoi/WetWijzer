# frozen_string_literal: true

module LegalChatbot
  # #1582 (Sol 2026-11-22 08:38:00Z): asked "Wat is een verwerkingsverantwoordelijke?", the answer disclaimed a general
  # definition, covered joint controllers only and cited six Belgian special provisions, but not the definition the
  # GDPR gives in art. 4, point 7. That point, literal with its number, from the corrected EUR-Lex consolidation
  # 02016R0679-20160504: the Publications Office's XHTML of each language edition (the four resources the
  # direct-marketing pack names), read in full on 2026-11-22. No corrigendum marks point 7 in these editions.
  #
  # The topic is a question about who or what the controller is, or how it differs from the processor; a question that
  # only names the controller (its duties, a breach, a contract) keeps its own topic, also when it opens like a
  # definition: "Wat is de verwerkingsverantwoordelijke verplicht te doen bij een datalek?", "What is the controller
  # required to do after a data breach?" or "What are the controller's obligations?" (Sol 2026-11-22 13:14:02Z).
  # Processing by police, intelligence or criminal-investigation services has its own definition in the Belgian act
  # (Title 2), so it is not this topic either.
  module GdprControllerSources
    OFFICIAL_EDITION = '02016R0679-20160504'
    VERIFIED_ON = '2026-11-22'
    REQUIRED_ARTICLES = %w[4].freeze
    # The point of art. 4 each record gives: art. 4 holds every definition at one URL (GdprDefinitionPoints)
    POINTS = { '4' => '7' }.freeze
    TERM = '(?:(?:gezamenlijke|gemeenschappelijke)\s+)?verwerkingsverantwoordelijken?|' \
           'responsables?\s+(?:conjoints?\s+)?du\s+traitement|(?:gemeinsam(?:e|en|er)?\s+)?Verantwortliche[nr]?|' \
           '(?:joint\s+)?(?:data\s+)?controllers?'
    ARTICLE = '(?:(?:een|de|het|un|une|le|la|les|ein|eine|einen|einer|der|die|den|a|an|the)\s+)?'
    # What the controller is obliged, liable or expected to do: such a word ends the definition question, right after
    # the term or after up to three words of an adjunct ("volgens de AVG", "under the GDPR"). A modal verb does not:
    # "Wie is de verwerkingsverantwoordelijke als een app persoonsgegevens kan inzien?" still asks who the controller is.
    DUTY = '(?:verplicht|verplichtingen|gehouden|geacht|verondersteld|aansprakelijk|verantwoordelijk|oblig[ée]e?s?|' \
           'tenue?s?|responsable|verpflichtet|haftet|haftbar|verantwortlich|gehalten|required|obliged|obligated|bound|' \
           'supposed|liable|responsible|expected|entitled|allowed|permitted)'
    # The adjunct's words: never a conjunction or question word, which open a second question
    GAP = '(?:[[:space:]]+(?!(?:en|and|et|und|of|or|ou|oder|wat|what|que|was|wie|who|qui|wer|which|that|dat|dont|' \
          'welche[nrs]?)(?![[:alpha:]]))[[:alnum:]]+){0,3}'
    # The term ends at its word, is no possessive ("the controller's obligations") and is followed by no duty
    TERM_END = "(?![[:alpha:]])(?!['’]s(?![[:alpha:]]))(?!#{GAP}[[:space:],]+#{DUTY}(?![[:alpha:]]))".freeze
    DEFINITION = /
      (?<![[:alpha:]])(?:wat|wie)\s+(?:is|zijn|wordt|worden)\s+#{ARTICLE}(?:#{TERM})#{TERM_END}|
      (?<![[:alpha:]])(?:definitie|begrip|betekenis|omschrijving)\s+(?:van\s+)?#{ARTICLE}(?:begrip\s+)?(?:#{TERM})#{TERM_END}|
      (?<![[:alpha:]])(?:ben|is|wordt|word)\s+(?:ik|u|je|jij|men|(?:mijn|ons|onze|het|de|een)\s+[[:alpha:]]+)\s+#{ARTICLE}(?:#{TERM})#{TERM_END}|
      (?<![[:alpha:]])qu['’]est[\s-]ce\s+qu['’](?:on\s+entend\s+par\s+)?#{ARTICLE}(?:#{TERM})#{TERM_END}|
      (?<![[:alpha:]])qu['’]est[\s-]ce\s+qu['’]un\s+(?:#{TERM})#{TERM_END}|
      (?<![[:alpha:]])qui\s+(?:est|sont)\s+#{ARTICLE}(?:#{TERM})#{TERM_END}|
      (?<![[:alpha:]])d[ée]finition\s+(?:du|des|d['’]une?|de\s+la\s+notion\s+de)\s+(?:#{TERM})#{TERM_END}|
      (?<![[:alpha:]])(?:suis-je|sommes-nous|est-il|est-elle)\s+#{ARTICLE}(?:#{TERM})#{TERM_END}|
      (?<![[:alpha:]])(?:was|wer)\s+(?:ist|sind)\s+#{ARTICLE}(?:#{TERM})#{TERM_END}|
      (?<![[:alpha:]])(?:Definition|Begriff|Begriffsbestimmung)\s+(?:des|der|eines|einer|von)\s+(?:#{TERM})#{TERM_END}|
      (?<![[:alpha:]])(?:bin\s+ich|sind\s+wir|ist\s+(?:mein|meine|unser|unsere|das|die|der)\s+[[:alpha:]]+)\s+#{ARTICLE}(?:#{TERM})#{TERM_END}|
      (?<![[:alpha:]])(?:what|who)\s+(?:is|are)\s+#{ARTICLE}(?:#{TERM})#{TERM_END}|
      (?<![[:alpha:]])(?:definition|meaning)\s+of\s+#{ARTICLE}(?:#{TERM})#{TERM_END}|
      (?<![[:alpha:]])define\s+#{ARTICLE}(?:#{TERM})#{TERM_END}|
      (?<![[:alpha:]])(?:am\s+i|are\s+we|is\s+(?:my|our|the|a)\s+[[:alpha:]]+)\s+#{ARTICLE}(?:#{TERM})#{TERM_END}|
      (?<![[:alpha:]])(?:verschil|onderscheid|diff[ée]rence|Unterschied|difference)(?![[:alpha:]])[^?.!]{0,80}(?:#{TERM})|
      (?:#{TERM})[^?.!]{0,80}(?<![[:alpha:]])(?:verschil|onderscheid|diff[ée]rence|Unterschied|difference)(?![[:alpha:]])
    /iux
    # "controller" and "Verantwortlicher" are also ordinary words: they need a data-protection context
    GENERIC_TERM = /(?<![[:alpha:]])(?:(?:gemeinsam(?:e|en|er)?\s+)?Verantwortliche[nr]?|(?:joint\s+)?controllers?)(?![[:alpha:]])/iu
    SPECIFIC_TERM = /(?<![[:alpha:]])(?:(?:gezamenlijke|gemeenschappelijke)\s+)?verwerkingsverantwoordelijken?|
                     responsables?\s+(?:conjoints?\s+)?du\s+traitement|data\s+controllers?/iux
    DATA_CONTEXT = /(?<![[:alpha:]])(?:avg|gdpr|rgpd|dsgvo|privacy|persoonsgegevens|gegevensbescherming|personal\s+data|
                    data\s+protection|donn[ée]es\s+(?:à\s+caract[èe]re\s+)?personnelles|protection\s+des\s+donn[ée]es|
                    personenbezogen\p{L}*|datenschutz\p{L}*|verarbeitung)(?![[:alpha:]])/iux
    SOURCE_LABELS = {
      'nl' => 'AVG, definitie van de verwerkingsverantwoordelijke',
      'fr' => 'RGPD, définition du responsable du traitement',
      'de' => 'DSGVO, Begriffsbestimmung des Verantwortlichen',
      'en' => 'GDPR, definition of the controller'
    }.freeze
    ARTICLE_TITLES = {
      'nl' => { '4' => 'Artikel 4, punt 7' }.freeze,
      'fr' => { '4' => 'Article 4, point 7' }.freeze,
      'de' => { '4' => 'Artikel 4 Nummer 7' }.freeze,
      'en' => { '4' => 'Article 4(7)' }.freeze
    }.freeze
    ARTICLE_TEXTS = {
      'nl' => {
        '4' => <<~TEXT.strip.freeze
          7) „verwerkingsverantwoordelijke” : een natuurlijke persoon of rechtspersoon, een overheidsinstantie, een dienst of een ander orgaan die/dat, alleen of samen met anderen, het doel van en de middelen voor de verwerking van persoonsgegevens vaststelt; wanneer de doelstellingen van en de middelen voor deze verwerking in het Unierecht of het lidstatelijke recht worden vastgesteld, kan daarin worden bepaald wie de verwerkingsverantwoordelijke is of volgens welke criteria deze wordt aangewezen;
        TEXT
      }.freeze,
      'fr' => {
        '4' => <<~TEXT.strip.freeze
          7) «responsable du traitement», la personne physique ou morale, l'autorité publique, le service ou un autre organisme qui, seul ou conjointement avec d'autres, détermine les finalités et les moyens du traitement; lorsque les finalités et les moyens de ce traitement sont déterminés par le droit de l'Union ou le droit d'un État membre, le responsable du traitement peut être désigné ou les critères spécifiques applicables à sa désignation peuvent être prévus par le droit de l'Union ou par le droit d'un État membre;
        TEXT
      }.freeze,
      'de' => {
        '4' => <<~TEXT.strip.freeze
          7. „Verantwortlicher“ die natürliche oder juristische Person, Behörde, Einrichtung oder andere Stelle, die allein oder gemeinsam mit anderen über die Zwecke und Mittel der Verarbeitung von personenbezogenen Daten entscheidet; sind die Zwecke und Mittel dieser Verarbeitung durch das Unionsrecht oder das Recht der Mitgliedstaaten vorgegeben, so kann der Verantwortliche beziehungsweise können die bestimmten Kriterien seiner Benennung nach dem Unionsrecht oder dem Recht der Mitgliedstaaten vorgesehen werden;
        TEXT
      }.freeze,
      'en' => {
        '4' => <<~TEXT.strip.freeze
          (7) ‘controller’ means the natural or legal person, public authority, agency or other body which, alone or jointly with others, determines the purposes and means of the processing of personal data; where the purposes and means of such processing are determined by Union or Member State law, the controller or the specific criteria for its nomination may be provided for by Union or Member State law;
        TEXT
      }.freeze
    }.freeze

    def self.topic?(question)
      value = question.to_s
      return false unless value.match?(DEFINITION)
      return false unless value.match?(SPECIFIC_TERM) || (value.match?(GENERIC_TERM) && value.match?(DATA_CONTEXT))
      return false if value.match?(LegalFactProvider::GDPR_SECURITY_PROCESSING_PURPOSE_PATTERN)

      !value.match?(LegalFactProvider::GDPR_SPECIAL_SECURITY_CONTEXT_PATTERN)
    end
  end
end
