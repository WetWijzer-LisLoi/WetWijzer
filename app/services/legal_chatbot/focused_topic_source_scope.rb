# frozen_string_literal: true

module LegalChatbot
  # Three built-in questions (Sol 2026-11-18 21:35:34Z, live v1.1.65) missed
  # the instrument that answers them, and their source cards filled with
  # unrelated rows:
  #
  # - "Kan ik een GAS-boete aanvechten?" had no GAS law; the cards were
  #   social-penalty, posting, energy and tourism fines.
  # - "Mag ik een foto van internet gebruiken?" had no copyright article; the
  #   answer leaned on the immigration tribunal's hearing rules.
  # - "Mag mijn werkgever camera's plaatsen op de werkplek?" had no CAO nr. 68
  #   and showed a Maritime Code card.
  #
  # The answering articles are pinned in LegislationSearch::ARTICLE_PINS. This
  # scope keeps the other cards to the topic's own family of instruments
  # while the question is on that topic. A source the question names by a
  # distinctive word of its title stays. Pinned and NUMAC-named sources are
  # admitted earlier by LegislationSearch.contextual_source_relevant?.
  module FocusedTopicSourceScope
    # French speakers also write "amende SAC".
    GAS_FINE_PATTERN = /#{MunicipalSanctionsSourceScope::MUNICIPAL_FINE_PATTERN}|\b(?:amendes?|sanctions?)\s+SAC\b/iu
    CHALLENGE_PATTERN = /\b(?:aanvecht\p{L}*|aan\s+te\s+vechten|aangevochten|betwist\p{L}*|beroep|bezwaar|verweer|contest\p{L}*|recours|appel|appeal\p{L}*|challeng\p{L}*|dispute\p{L}*|anfecht\p{L}*|Einspruch|Widerspruch|Berufung|Beschwerde)\b/iu
    # Municipal wording only: "sanctionerend ambtenaar" also names the
    # officials of regional regimes (the Walloon Tourism Code, Sol 22:09:03Z).
    GAS_FAMILY_PATTERN = /\b(?:gemeentelijke\s+administratieve\s+sanct\p{L}*|GAS[-\s]?(?:boete|sanctie|wet)\p{L}*|sanctions?\s+administratives?\s+communales?|amendes?\s+administratives?\s+communales?|kommunalen?\s+Verwaltungssanktion\p{L}*)/iu

    IMAGE_PATTERN = /\b(?:foto(?:'s|s)?|afbeelding(?:en)?|plaatjes?|illustratie(?:s)?|images?|photos?|illustrations?|pictures?|Bild(?:er|ern|es)?|Fotos?|Abbildung(?:en)?)\b/iu
    ONLINE_ORIGIN_PATTERN = /(?:\b(?:van|uit|from|off|de|aus|von)\s+|\bd['’]\s*)(?:(?:het|the|dem)\s+|l['’]\s*)?(?:internet|web|google|een\s+website|a\s+website|un\s+site|einer\s+(?:Webseite|Website)|website|instagram|facebook|pinterest|sociale\s+media|social\s+media)\b|
                             \b(?:gevonden|found|trouv[ée]e?s?|gefunden)\s+(?:op|on|sur|im)\s+(?:(?:het|the|le)\s+)?(?:internet|web|google|online)\b|
                             \bonline\s+gevonden\b/iux
    COPYRIGHT_FAMILY_PATTERN = /\b(?:auteursrecht\p{L}*|naburige\s+rechten|droits?\s+d['’]auteur|droits?\s+voisins|Urheberrecht\p{L}*|copyright|werk(?:en)?\s+van\s+letterkunde\s+of\s+kunst|[œo]e?uvres?\s+litt[ée]raires?\s+ou\s+artistiques?|auteur\s+zich\s+niet\s+verzetten|auteur\s+ne\s+peut\s+interdire|portret\p{L}*|portraits?|Bildnis\p{L}*)/iu

    CAMERA_PATTERN = /\b(?:camera\p{L}*|cam[ée]ra\p{L}*|kamera\p{L}*|videobewaking|vid[ée]osurveillance|Video[üu]berwachung\p{L}*)/iu
    WORKPLACE_PATTERN = /\b(?:werkgever\p{L}*|werknemer\p{L}*|werkplek\p{L}*|werkvloer|arbeidsplaats\p{L}*|op\s+(?:het|mijn|zijn|haar)\s+werk|personeel\p{L}*|employeur\p{L}*|travailleur\p{L}*|lieu\s+de\s+travail|au\s+travail|employer\p{L}*|employee\p{L}*|workplace|at\s+work|Arbeitgeber\p{L}*|Arbeitnehmer\p{L}*|Arbeitsplatz\p{L}*|Mitarbeiter\p{L}*)/iu
    CAMERA_FAMILY_PATTERN = /\b(?:camerabewaking|bewakingscamera\p{L}*|videobewaking|cam[ée]ras?\s+de\s+surveillance|surveillance\s+par\s+cam[ée]ras?|vid[ée]osurveillance|Video[üu]berwachung\p{L}*|[ÜU]berwachungskamera\p{L}*|persoonlijke\s+levenssfeer|vie\s+priv[ée]e|Privatsph[äa]re)/iu
    # Camera regimes of their own (ports and the sea, football grounds, the
    # police and civil protection, medical imaging) are not the employer's.
    CAMERA_SPECIALIST_TITLE_PATTERN = /\b(?:scheepvaart\p{L}*|maritie\p{L}*|maritime\p{L}*|Seeschifffahrt\p{L}*|voetbal\p{L}*|football|Fu[ßs]ball\p{L}*|politieambt|politiediensten|fonction\s+de\s+police|services\s+de\s+police|civiele\s+veiligheid|s[ée]curit[ée]\s+civile|gamma[-\s]?cam[ée]ra\p{L}*|scintillation|nucle[aï]\p{L}*|nucl[ée]aire)/iu

    # "Wanneer en hoe moet ik een datalek melden?" also showed an animal
    # by-products card. GDPR Arts. 33 and 34 come from the official EUR-Lex
    # pack (GdprBreachSources); the Belgian cards stay data-protection rules.
    DATA_PROTECTION_FAMILY_PATTERN = /\b(?:persoonsgegevens|gegevensbescherming|bescherming\s+van\s+de\s+persoonlijke\s+levenssfeer|donn[ée]es\s+[àa]\s+caract[èe]re\s+personnel|protection\s+des\s+donn[ée]es|personenbezogen\p{L}*\s+Daten|Datenschutz\p{L}*|personal\s+data|data\s+protection|AVG|GDPR|RGPD|DSGVO)\b/iu

    # "Wat is de maximumsnelheid in de bebouwde kom?" (Sol 2026-11-18
    # 21:35:34Z) led with one national 50 km/h beside the regional Art. 11
    # cards of the Wegcode (Brussels 30) and showed the Brussels-Scheldt
    # canal's shipping regulation, whose Art. 9 slows vessels "bij de
    # doorvaart van de bebouwde kommen". A road speed question is a regional
    # subject (RegionalSearch.regional_subject_question?, all regions in the
    # prompt); its other cards stay road-traffic law. Vessels, trains,
    # aircraft and an internet connection's speed are not road speed.
    SPEED_LIMIT_PATTERN = /\b(?:maximum\s*snelheid\p{L}*|maximale\s+snelheid|toegelaten\s+snelheid|snelheidsbeperking\p{L}*|snelheidslimiet\p{L}*|snelheidsgrens\p{L}*|hoe\s+snel\s+mag\s+(?:ik|je|men|u)|vitesses?\s+maximales?|limitations?\s+de\s+vitesse|limites?\s+de\s+vitesse|vitesses?\s+autoris[ée]es?|H[öo]chstgeschwindigkeit\p{L}*|Tempolimit\p{L}*|Geschwindigkeitsbegrenzung\p{L}*|zul[äa]ssige\s+Geschwindigkeit|speed\s+limits?|maximum\s+speed)/iu
    NON_ROAD_PATTERN = /\b(?:vaartuig\p{L}*|schip|schepen|boot|boten|kanaal|kanalen|waterweg\p{L}*|scheepvaart\p{L}*|bateaux?|navires?|canal|canaux|voies?\s+navigables?|Schiff\p{L}*|Boot(?:e|en)?|Kanal|Wasserstra[ßs]e\p{L}*|ships?|boats?|vessels?|waterways?|trein\p{L}*|trains?|Zug|Z[üu]ge|vliegtuig\p{L}*|drones?|avions?|Flugzeug\p{L}*|aircraft|internet\p{L}*|verbinding\p{L}*|breedband\p{L}*|download\p{L}*|upload\p{L}*|wifi|wi-fi|Mbps|Mbit\p{L}*|connexion|d[ée]bit|Verbindung\p{L}*|Breitband\p{L}*|broadband|bandwidth|computer\p{L}*|processor\p{L}*)\b/iu
    ROAD_TRAFFIC_FAMILY_PATTERN = /\b(?:wegverkeer\p{L}*|verkeersreglement\p{L}*|wegcode|verkeersveiligheid|verkeersbord\p{L}*|snelheidsbeperking\p{L}*|circulation\s+routi[èe]re|code\s+de\s+la\s+route|police\s+de\s+la\s+circulation|s[ée]curit[ée]\s+routi[èe]re|limitations?\s+de\s+vitesse|Stra[ßs]enverkehr\p{L}*|Geschwindigkeitsbegrenzung\p{L}*|road\s+traffic|speed\s+limits?)/iu
    SHIPPING_TITLE_PATTERN = /\b(?:scheepvaart\p{L}*|navigation|Schifffahrt\p{L}*|shipping)\b/iu

    # "Hoe is het recht op onderwijs gewaarborgd in België?" showed advocates'
    # ethics cards (Sol 2026-11-19 07:20:42Z): the Codex Deontologie's
    # continuing-education articles say "hoger onderwijs" in their text. The
    # education family is therefore read from the law's title only: the
    # Constitution, education law, and human rights and children's rights
    # treaties (Protocol 1 Art. 2 of the ECHR).
    EDUCATION_TITLE_FAMILY_PATTERN = /\b(?:grondwet|constitution|Verfassung|\p{L}*onderwijs\p{L}*|enseignement\p{L}*|Unterricht\p{L}*|education|[ée]ducation|\p{L}*school\p{L}*|[ée]coles?|\p{L}*Schul\p{L}*|leerplicht\p{L}*|scolaire\p{L}*|Bildung\p{L}*|universit\p{L}*|rechten\s+van\s+de\s+mens|droits\s+de\s+l['’]\s*homme|Menschenrechte\p{L}*|human\s+rights|rechten\s+van\s+het\s+kind|droits\s+de\s+l['’]\s*enfant|Rechte\s+des\s+Kindes|rights\s+of\s+the\s+child|economische,\s+sociale\s+en\s+culturele\s+rechten|droits\s+[ée]conomiques,\s+sociaux\s+et\s+culturels)\b/iu
    # Topics whose family is read from the law's title alone.
    TITLE_TOPICS = { education_right: EDUCATION_TITLE_FAMILY_PATTERN }.freeze

    TOPICS = {
      gas_fine_challenge: GAS_FAMILY_PATTERN,
      internet_image: COPYRIGHT_FAMILY_PATTERN,
      workplace_camera: CAMERA_FAMILY_PATTERN,
      data_breach: DATA_PROTECTION_FAMILY_PATTERN,
      road_speed: ROAD_TRAFFIC_FAMILY_PATTERN
    }.freeze

    def self.road_speed_question?(question)
      text = question.to_s
      text.match?(SPEED_LIMIT_PATTERN) && !text.match?(NON_ROAD_PATTERN)
    end

    # Title words too common to say which instrument the question names.
    GENERIC_TITLE_WORDS = %w[
      administratieve administratives betreffende bepalingen bescherming collectieve communales concernant
      dispositions gemeentelijke hoofdstedelijke koninklijk modification ordonnantie organisatie
      persoonlijke toepassing uitvoering vaststelling verordening wijziging arbeidsovereenkomst
    ].freeze
    TITLE_WORD_MIN = 10

    def self.topics(question)
      text = question.to_s
      found = []
      found << :gas_fine_challenge if text.match?(GAS_FINE_PATTERN) && text.match?(CHALLENGE_PATTERN)
      found << :internet_image if text.match?(IMAGE_PATTERN) && text.match?(ONLINE_ORIGIN_PATTERN)
      found << :workplace_camera if text.match?(CAMERA_PATTERN) && text.match?(WORKPLACE_PATTERN)
      found << :data_breach if GdprBreachSources.topic?(text)
      found << :road_speed if road_speed_question?(text)
      found << :education_right if text.match?(LegislationSearch::CONSTITUTION_EDUCATION_PATTERN)
      found
    end

    def self.source_relevant?(article, question)
      found = topics(question)
      return true if found.empty?

      title = field(article, :law_title, :title)
      return true if named_by_title?(title, question)

      source = [title, field(article, :article_title), field(article, :article_text)].join("\n")
      found.any? do |topic|
        next false if topic == :workplace_camera && title.match?(CAMERA_SPECIALIST_TITLE_PATTERN)
        next false if topic == :road_speed && title.match?(SHIPPING_TITLE_PATTERN)
        next title.match?(TITLE_TOPICS.fetch(topic)) if TITLE_TOPICS.key?(topic)

        source.match?(TOPICS.fetch(topic))
      end
    end

    def self.named_by_title?(title, question)
      asked = question.to_s.downcase
      title.downcase.scan(/\p{L}+/).uniq.any? do |word|
        word.length >= TITLE_WORD_MIN && !GENERIC_TITLE_WORDS.include?(word) && asked.include?(word)
      end
    end
    private_class_method :named_by_title?

    def self.field(article, *keys)
      keys.each do |key|
        value = article[key] || article[key.to_s]
        return value.to_s if value.present?
      end
      ''
    end
    private_class_method :field
  end
end
