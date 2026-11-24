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

    # "Wanneer mag mijn foto of afbeelding gebruikt worden?" (Sol 2026-11-20
    # 04:12:53Z, #2450) showed scratch-card lottery decrees, whose tickets
    # carry an "afbeelding", and an immigration badge. Using a picture of a
    # person is the portrait right (WER Art. XI.174, pinned): the question
    # names the right itself ("droit à l'image", "Recht am eigenen Bild") or a
    # picture of a person ("mijn foto", "une photo de moi") with its use.
    PORTRAIT_IMAGE_WORD = "(?:foto(?:'s|s)?|afbeelding(?:en)?|beeltenis(?:sen)?|portret(?:ten)?|photos?|images?|portraits?|Fotos?|Bild(?:er|nis)?|Bildnisse?|pictures?|photographs?)"
    PORTRAIT_USE_PATTERN = /
      (?<![[:alnum:]])(?:portretrecht\p{L}*|recht\s+op\s+(?:de\s+|het\s+|zijn\s+|mijn\s+)?(?:eigen\s+)?(?:afbeelding|beeld|portret|beeltenis)|droit\s+[àa]\s+l['’]\s*image|Recht\s+am\s+eigenen\s+Bild|right\s+to\s+(?:one['’]s|my|your|his|her|their)\s+(?:own\s+)?image|image\s+rights?)(?![[:alnum:]])
      |
      \A
      (?=.*(?:
          (?<![[:alnum:]])(?:mijn|zijn|haar|onze|iemands|ma|mon|mes|sa|son|ses|notre|nos|mein[emnrs]?|sein[emnrs]?|ihr[emnrs]?|my|his|her|our|their|someone['’]s)\s+(?:eigen\s+|own\s+|propres?\s+|eigen[emnrs]?\s+)?#{PORTRAIT_IMAGE_WORD}(?![[:alnum:]])
        |
          (?<![[:alnum:]])#{PORTRAIT_IMAGE_WORD}\s+(?:van|de|d['’]|von|of)\s+(?:mij|mezelf|iemand|een\s+persoon|personen|mijn\s+\p{L}+|moi|quelqu['’]un|une\s+personne|mon\s+\p{L}+|ma\s+\p{L}+|mir|mich|jemand\p{L}*|einer\s+Person|meine[mnrs]?\s+\p{L}+|me|myself|someone|a\s+person|people|my\s+\p{L}+)(?![[:alnum:]])
      ))
      (?=.*(?<![[:alnum:]])(?:gebruik\p{L}*|publice\p{L}*|gepubliceerd|verspreid\p{L}*|online|delen|deelt|gedeeld|posten|gepost|plaatsen|geplaatst|zetten|gezet|toestemming|utilis\p{L}*|publi\p{L}*|diffus\p{L}*|partag\p{L}*|poster|consentement|autoris\p{L}*|verwend\p{L}*|ver[öo]ffentlich\p{L}*|teilen|geteilt|Einwilligung|use[ds]?|using|publish\p{L}*|share[ds]?|sharing|post(?:ed|ing)?|consent)(?![[:alnum:]]))
      .*\z
    /imxu

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
    # A portrait question keeps the copyright family (it carries "portret"),
    # data protection and the right to private life.
    PORTRAIT_FAMILY_PATTERN = Regexp.union(
      COPYRIGHT_FAMILY_PATTERN, DATA_PROTECTION_FAMILY_PATTERN,
      /\b(?:persoonlijke\s+levenssfeer|priv[ée]leven|vie\s+priv[ée]e|Privatsph[äa]re|Privatleben|private\s+life|privacy)\b/iu
    )

    # Guaranteed pay during illness (Sol 2026-11-20 07:32:27Z, #1732): the answers headlined Art. 52's 60% and the
    # cards showed broadcaster and public-staff statutes, whose texts also say "gewaarborgd loon". The question names
    # guaranteed pay, or pay together with illness; a sick child is another subject. The other cards stay in the
    # family read from the law's title: employment contracts, collective agreements and the sickness insurance.
    GUARANTEED_PAY_PATTERN = /
      (?<![[:alnum:]])(?:gewaarborgd\p{L}*\s+(?:week|maand)?loon|salaire\s+garanti|r[ée]mun[ée]ration\s+garantie|garantiert\p{L}*\s+(?:Lohn|Gehalt|Entgelt|Entlohnung)|Lohnfortzahlung\p{L}*|guaranteed\s+(?:pay|salary|wages?|remuneration)|sick\s+pay)(?![[:alnum:]])
      |
      \A
      (?!.*(?<![[:alnum:]])(?:kind\p{L}*|zoon|dochter|enfants?|fils|fille|Kind\p{L}*|Sohn|Tochter|child\p{L}*|daughter)(?![[:alnum:]]))
      (?=.*(?<![[:alnum:]])(?:loon|salaris|wedde|salaire|r[ée]mun[ée]ration|Lohn|Gehalt|pay|salary|wages?)(?![[:alnum:]]))
      (?=.*(?<![[:alnum:]])(?:ziek\p{L}*|arbeidsongeschikt\p{L}*|maladie|malade|incapacit[ée]\p{L}*|krank\p{L}*|arbeitsunf[äa]hig\p{L}*|sick\p{L}*|illness)(?![[:alnum:]]))
      .*\z
    /imxu
    GUARANTEED_PAY_TITLE_FAMILY_PATTERN = /(?:arbeidsovereenkomst\p{L}*|contrats?\s+de\s+travail|Arbeitsvertr[äa]g\p{L}*|employment\s+contracts?|conventions?\s+collectives?\s+de\s+travail|kollektive\p{L}*\s+Arbeitsabkommen|geneeskundige\s+verzorging\s+en\s+uitkeringen|soins\s+de\s+sant[ée]\s+et\s+(?:d['’]\s*)?indemnit[ée]s|ziekte-\s*en\s+invaliditeitsverzekering|assurance\s+maladie-invalidit[ée]|Kranken-\s*und\s+Invalidit[äa]tsversicherung)/iu

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
    # "Onschendbaarheid woning?" quoted Constitution Art. 15 but also showed
    # swine brucellosis, African swine fever and the estate agents' code of
    # ethics (Sol 2026-11-19 10:16:45Z, live 1.1.71): each of those articles
    # lets an inspector or an agent enter "behoudens de onschendbaarheid van de
    # woning". The family is read from the law's title only: the Constitution
    # and human rights treaties, criminal law and procedure with the search
    # laws, the police function, and diplomatic and consular premises.
    HOME_TITLE_FAMILY_PATTERN = /\b(?:grondwet|constitution|Verfassung|rechten\s+van\s+de\s+mens|droits\s+de\s+l['’]\s*homme|Menschenrechte\p{L}*|human\s+rights|burgerrechten\s+en\s+politieke\s+rechten|droits\s+civils\s+et\s+politiques|strafwetboek|code\s+p[ée]nal|Strafgesetzbuch|criminal\s+code|strafvordering|instruction\s+criminelle|proc[ée]dure\s+p[ée]nale|Strafprozess\p{L}*|criminal\s+procedure|huiszoeking\p{L}*|opsporing\p{L}*\s+ten\s+huize|visites?\s+domiciliaires?|perquisitions?|Hausdurchsuchung\p{L}*|politieambt|fonction\s+de\s+police|Polizeiamt|diplomati\p{L}*|consul\p{L}*|Konsular\p{L}*)\b/iu
    # "Wat is een privacyverklaring?" (Sol 2026-11-23 09:24:52Z, #1591) showed art. 6.32 of the decree implementing the
    # Flemish Housing Code (in its Book 6, social rental: the landlord hands the tenant a privacy statement) and art. 5
    # of the Coronalert cooperation agreement (the app's privacy statement is published), beside the GDPR. A privacy
    # notice is GDPR arts. 12 to 14 (EuTopicIntent :privacy_notice); its Belgian cards stay data-protection law, read
    # from the law's title, and a law of another subject stays when the question raises that subject: renting for the
    # housing decree, the app or the pandemic for the cooperation agreement.
    PRIVACY_NOTICE_SUBJECTS = [
      [/(?<![[:alnum:]])(?:wonen|woning\p{L}*|huur\p{L}*|logement\p{L}*|bail\p{L}*|wohn\p{L}*|miet\p{L}*|housing|tenan\p{L}*)(?![[:alnum:]])/iu,
       /(?<![[:alnum:]])(?:huur\p{L}*|verhuur\p{L}*|woning\p{L}*|wonen|bail\p{L}*|bailleu\p{L}*|locataire\p{L}*|logement\p{L}*|miet\p{L}*|
          vermiet\p{L}*|wohnung\p{L}*|rent|rental|rented|renting|tenant\p{L}*|landlord\p{L}*|housing)(?![[:alnum:]])/iux],
      [/(?<![[:alnum:]])(?:contactopsporing\p{L}*|tra[çc]age|kontaktverfolgung\p{L}*|contact\s+tracing)(?![[:alnum:]])/iu,
       /(?<![[:alnum:]])(?:corona\p{L}*|covid\p{L}*|contactopsporing\p{L}*|tra[çc]age|kontaktverfolgung\p{L}*|contact\s*tracing|tracing)(?![[:alnum:]])/iu]
    ].freeze

    # Topics whose family is read from the law's title alone.
    TITLE_TOPICS = { education_right: EDUCATION_TITLE_FAMILY_PATTERN, home_inviolability: HOME_TITLE_FAMILY_PATTERN,
                     guaranteed_pay: GUARANTEED_PAY_TITLE_FAMILY_PATTERN }.freeze

    # Sol 2026-11-24 10:26:43Z (live 1.1.98): under the doorstep deadline question the slot WER art. VII.87 left went
    # to art. 3 of the royal decree of 7 December 2016 on price indication in the hospitality sector (2016011534), which
    # shares only "van buiten" and "verkoopruimte" with it. An off-premises withdrawal question keeps the consumer
    # contract codes, whose own rules decide their articles (book VII and old Civil Code arts. 1701/x in
    # LegislationSearch), the specialist withdrawal regimes (decided there too) and any source on withdrawal or on
    # contracts made away from the business premises; a source the question names by its title stays.
    CONSUMER_CONTRACT_TITLE_PATTERN = /(?<![[:alnum:]])(?:wetboek\s+van\s+economisch\s+recht|code\s+de\s+droit\s+[ée]conomique|
                                       wirtschaftsgesetzbuch|gesetzbuch\s+des\s+wirtschaftsrechts|burgerlijk\s+wetboek|code\s+civil|
                                       zivilgesetzbuch|b[üu]rgerliches\s+gesetzbuch)(?![[:alnum:]])/iux
    # Consumer withdrawal, not the bare verb (Sol 2026-11-24 13:50:41Z: "de vergunning kan worden herroepen" is no
    # withdrawal from a contract): the withdrawal right or period, contracts away from the premises, or the consumer
    # who withdraws in the same sentence.
    WITHDRAWAL_FAMILY_PATTERN = /(?<![[:alnum:]])(?:herroepingsrecht\p{L}*|herroepingstermijn\p{L}*|recht\s+(?:van|op)\s+herroeping|
                                 bedenk(?:ing)?s?(?:tijd|termijn)\p{L}*|buiten\s+(?:de\s+)?verkoopruimte\p{L}*|
                                 droit\s+de\s+r[ée]tractation|d[ée]lai\s+de\s+r[ée]tractation|hors\s+(?:de\s+l['’]\s*|des\s+)?[ée]tablissement\p{L}*|
                                 widerrufsrecht\p{L}*|widerrufsfrist\p{L}*|au[ßs]erhalb\s+von\s+gesch[äa]ftsr[äa]umen|
                                 right\s+of\s+withdrawal|withdrawal\s+period|off[-\s]premises|cooling[-\s]off|
                                 consument\p{L}*[^.;]{0,120}?herroep\p{L}*|herroep\p{L}*[^.;]{0,120}?consument\p{L}*|
                                 consommat\p{L}*[^.;]{0,120}?r[ée]tract\p{L}*|verbraucher\p{L}*[^.;]{0,120}?widerruf\p{L}*|
                                 consumer\p{L}*[^.;]{0,120}?withdraw\p{L}*)/iux

    TOPICS = {
      gas_fine_challenge: GAS_FAMILY_PATTERN,
      internet_image: COPYRIGHT_FAMILY_PATTERN,
      portrait_use: PORTRAIT_FAMILY_PATTERN,
      workplace_camera: CAMERA_FAMILY_PATTERN,
      data_breach: DATA_PROTECTION_FAMILY_PATTERN,
      road_speed: ROAD_TRAFFIC_FAMILY_PATTERN,
      # "Hoe betwist ik een verkeersboete?" showed filiation cards (Sol 2026-11-20 10:14:49Z, #2231): art. 332bis of
      # the old Civil Code and the co-maternity act, which contest paternity. The fine's own articles are pinned.
      traffic_fine_challenge: ROAD_TRAFFIC_FAMILY_PATTERN
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
      found << :portrait_use if text.match?(PORTRAIT_USE_PATTERN)
      found << :guaranteed_pay if text.match?(GUARANTEED_PAY_PATTERN)
      found << :workplace_camera if text.match?(CAMERA_PATTERN) && text.match?(WORKPLACE_PATTERN)
      found << :data_breach if GdprBreachSources.topic?(text)
      found << :road_speed if road_speed_question?(text)
      found << :traffic_fine_challenge if text.match?(LegislationSearch::TRAFFIC_FINE_CONTEST_PATTERN)
      found << :education_right if text.match?(LegislationSearch::CONSTITUTION_EDUCATION_PATTERN)
      found << :home_inviolability if text.match?(LegislationSearch::CONSTITUTION_HOME_INVIOLABILITY_PATTERN)
      found << :privacy_notice if EuTopicIntent.plan(text)&.fetch(:topic, nil) == :privacy_notice
      found << :off_premises_withdrawal if off_premises_withdrawal_question?(text)
      found
    end

    def self.source_relevant?(article, question)
      found = topics(question)
      return true if found.empty?

      title = field(article, :law_title, :title)
      return true if named_by_title?(title, found.include?(:off_premises_withdrawal) ? asked_text(question) : question)

      source = [title, field(article, :article_title), field(article, :article_text)].join("\n")
      found.any? do |topic|
        next false if topic == :workplace_camera && title.match?(CAMERA_SPECIALIST_TITLE_PATTERN)
        next false if topic == :road_speed && title.match?(SHIPPING_TITLE_PATTERN)
        next privacy_notice_source?(title, question) if topic == :privacy_notice
        next off_premises_withdrawal_source?(article, title, source) if topic == :off_premises_withdrawal
        next title.match?(TITLE_TOPICS.fetch(topic)) if TITLE_TOPICS.key?(topic)

        source.match?(TOPICS.fetch(topic))
      end
    end

    # What the question asks: its sentences that end in a question mark. Under a doorstep question a source named by a
    # word of its title must be asked about, not share a word with the facts (Sol 2026-11-24 13:50:41Z: "een etentje
    # in de horecasector" kept the hospitality price decree).
    def self.asked_text(question)
      question.to_s.scan(/[^.!?;]*\?/).join(' ')
    end
    private_class_method :asked_text

    def self.off_premises_withdrawal_question?(text)
      text.match?(LegislationSearch::OFF_PREMISES_PATTERN) && text.match?(LegislationSearch::WITHDRAWAL_RIGHT_QUERY_PATTERN)
    end

    def self.off_premises_withdrawal_source?(article, title, source)
      numac = field(article, :numac)
      title.match?(CONSUMER_CONTRACT_TITLE_PATTERN) || source.match?(WITHDRAWAL_FAMILY_PATTERN) ||
        LegislationSearch::WITHDRAWAL_SPECIALIST_REGIMES.any? { |regime, pattern, _asked| numac == regime || title.match?(pattern) }
    end
    private_class_method :off_premises_withdrawal_source?

    def self.privacy_notice_source?(title, question)
      title.match?(DATA_PROTECTION_FAMILY_PATTERN) ||
        PRIVACY_NOTICE_SUBJECTS.any? { |law, asked| title.match?(law) && question.to_s.match?(asked) }
    end
    private_class_method :privacy_notice_source?

    # A plural title word also names its singular: "een vastgoedmakelaar"
    # names the "Beroepsinstituut van Vastgoedmakelaars".
    def self.named_by_title?(title, question)
      asked = question.to_s.downcase
      title.downcase.scan(/\p{L}+/).uniq.any? do |word|
        next false if GENERIC_TITLE_WORDS.include?(word)

        [word, word.sub(/(?:en|s)\z/, '')].uniq.any? do |form|
          form.length >= TITLE_WORD_MIN && !GENERIC_TITLE_WORDS.include?(form) && asked.include?(form)
        end
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
