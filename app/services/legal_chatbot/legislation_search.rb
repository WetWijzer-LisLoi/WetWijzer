# frozen_string_literal: true

module LegalChatbot
  # Searches federal legislation via FAISS vector search + FTS5/LIKE keyword supplement.
  # This is the primary search service - Belgian federal legislation is the core dataset.
  #
  # Search pipeline:
  # 1. FAISS nearest-neighbor search against 2.3M article embeddings (port 8767)
  # 2. Keyword extraction + FTS5 search as supplement
  # 3. Merge results with core law boosting (Burgerlijk Wetboek, AOW, etc.)
  # 4. Quality filters: title relevance, similarity threshold
  # 5. Context building with abolished warnings, exdecs, modifications
  #
  # Dependencies:
  #   - ActiveRecord models: Article, Legislation, Content, Exdec, UpdatedLaw, ArticleModification
  #   - SQLite: search.sqlite3 (FTS5 for keyword supplement)
  #   - FAISS service on port 8767
  #   - CoreLawMappings concern (constants: CORE_LAW_NUMACS, KEYWORD_TO_CORE_LAWS, etc.)
  class LegislationSearch
    CANONICAL_LANGUAGE_IDS = [1, 2].freeze
    include TextProcessing
    include CoreLawMappings

    FAISS_URL = ENV.fetch('FAISS_LARGE_URL', 'http://localhost:8767')
    FAISS_ENABLED_ENV = 'LEGISLATION_FAISS_ENABLED'

    # Known bad or obsolete source identities must never survive semantic
    # retrieval, viewed-law context, or stale configuration. 1994071450 is an
    # election-information order, not the coordinated sickness-insurance law;
    # 1930123150 is the drugs decree repealed by Art. 64 of the current 2017 KB.
    INVALID_LEGISLATION_NUMACS = %w[1994071450 1930123150].to_set.freeze

    # Short law-code keys are abbreviations, not semantic prefixes. Without a
    # right boundary `wer` also matched ordinary words such as `werkt`, causing
    # unrelated Economic Law articles to be injected into health questions.
    # Short keys and one-word offence names must be complete tokens. Without
    # the right boundary, "april" triggers the consumer-credit key "apr" and
    # "volgens" triggers the theft key "vol".
    EXACT_CORE_LAW_KEYWORDS = %w[
      apr vol wer wib wib92 ziv vcro vov vzw asbl bv nv btw tva rva onem swt ocmw cpas visa
      cao cct igo rsvz epc jkp taeg avg gdpr dpo rgpd fpc tbs pbm cpbw rup vof cv ipr gmbh vat
    ].to_set.freeze

    # "verblijf" also describes ordinary residence, a hospital stay, and
    # childcare. It denotes the Aliens Act only alongside an immigration
    # signal; a bare occurrence must not inject the immigration corpus.
    AMBIGUOUS_RESIDENCE_KEYS = Set.new(%w[verblijf séjour aufenthalt visa]).freeze
    IMMIGRATION_CONTEXT_PATTERN = /\b(?:vreemdeling(?:en)?|immigratie|migratie|asiel\w*|visum|verblijfs?(?:vergunning|kaart)|uitwijzing|gezinshereniging|single\s+permit|dublin|étrangers?|immigration|migration|asile|titre\s+de\s+séjour|permis\s+de\s+séjour|aufenthalts(?:titel|erlaubnis)|ausländer\w*|einwanderung|asyl\w*|residence\s+permit|immigrant\w*|foreign\s+national\w*)\b/i.freeze
    # Visa also names a payment card. A bare "Visa" must not inject the
    # Aliens Act; an application/entry/consular phrase establishes that sense.
    IMMIGRATION_VISA_PATTERN = /\b(?:visa.{0,50}(?:aanvraag|aanvragen|visumaanvraag|inreis|consulaat|ambassade|application|apply|entry|consulat|ambassade|demande\w*|entrée|einreise|beantrag\w*|konsulat)|(?:aanvraag|aanvragen|inreis|consulaat|ambassade|application|apply|entry|consulat|demande\w*|entrée|einreise|beantrag\w*|konsulat).{0,50}visa)\b/i.freeze
    VISA_PAYMENT_PATTERN = /\b(?:credit\s+card|debit\s+card|bankkaart|betaalkaart|carte\s+(?:bancaire|de\s+crédit)|kreditkarte|zahlungskarte)\b/i.freeze
    PAYMENT_CARD_CONTEXT_PATTERN = /\b(?:kaart|kaarten|bankkaart|betaalkaart|creditcard|kredietkaart|credit\s+card|debit\s+card|carte\s+(?:bancaire|de\s+crédit)|kreditkarte|zahlungskarte|kaartbetaling|elektronische\s+betaling|paiement\s+(?:par\s+carte|électronique)|kartenzahlung)\b/i.freeze
    HEALTH_INSURANCE_CONTEXT_PATTERN = /\b(?:ziekteverzekering|ziekenfonds|mutualiteit|riziv|inami|assurance\s+maladie|mutuelle|incapaciteit|invaliditeit|invalidité|hospitalisatieverzekering|hospitalisation)\b/i.freeze
    # General coverage overviews need the statute's care/nomenclature framework,
    # not a semantic neighbour about heavy equipment or reimbursement contracts.
    # Keep this rescue separate from claims about a particular treatment, tariff,
    # medicine, copayment, private policy, or income-replacement benefit.
    HEALTH_INSURANCE_OVERVIEW_PATTERN = %r{
      \A
      (?!.*\b(?:
        geneesmiddel\w*|medicijn\w*|farmaceutisch\w*|médicaments?|pharmaceutique\w*|
        medication\w*|medicines?|drugs?|arzneimittel\w*|medikament\w*|
        remgeld|persoonlijk\s+aandeel|ticket\s+modérateur|co[-\s]?pay\w*|zuzahlung\w*|
        maximumfactuur\w*|maf|derdebetaler\w*|tiers\s+payant|
        zware\s+(?:medische\s+)?apparatuur|appareillage\s+lourd|équipement\s+lourd|
        heavy\s+(?:medical\s+)?equipment|medizinische\s+großgeräte|
        arbeidsongeschikt\w*|invaliditeit\w*|invalidité|incapacité|disability|arbeitsunfähigkeit|
        hospitalisatieverzekering|assurance\s+hospitalisation|private\s+health\s+insurance|
        particuliere\s+ziekteverzekering|privéverzekering|privat\w*\s+krankenversicherung|
        tarief\w*|prijzen?|bedrag\w*|hoeveel|tarif\w*|montant\w*|combien|prices?|amount\w*|
        how\s+much|betrag\w*|gebühren|wie\s+viel|nomensoft|nomenclatuurcode\w*|
        mijn|mij|m['’]n|mon|ma|mes|my|mine|meine?\w*|
        kinesitherapie|kinésithérapie|physiotherapy|physiotherapie|implant\w*|dialys\w*|
        tandheelkund\w*|dentair\w*|dentaire\w*|dental|chirurgie|surgery|operation\w*
      )\b)
      (?=.*\b(?:
        verplichte\s+(?:ziekteverzekering|verzekering\s+(?:voor\s+)?geneeskundige\s+verzorging)|ziv|
        assurance\s+(?:maladie\s+obligatoire|obligatoire\s+(?:de\s+)?soins\s+de\s+santé)|
        gesetzliche\w*\s+krankenversicherung|pflichtkrankenversicherung|
        (?:compulsory|mandatory)\s+health\s+insurance
      )\b)
      (?=.*\b(?:
        wat\s+(?:regelt|bepaalt|omvat)|hoe\s+(?:werkt|werken)|welke\b.{0,40}\b(?:regels|soorten|categorieën)|
        que\s+(?:prévoit|règle|couvre)|comment\b.{0,70}\bfonctionne\w*|
        quels?\b.{0,40}\b(?:types|règles)|quelles\b.{0,40}\b(?:règles|catégories)|
        was\s+(?:regelt|umfasst)|wie\b.{0,70}\bfunktioniert|welche\w*\b.{0,40}\b(?:regeln|arten|kategorien)|
        what\b.{0,70}\b(?:regulate\w*|cover\w*|govern\w*)|how\b.{0,90}\b(?:work\w*|operate\w*)|
        which\b.{0,40}\b(?:rules|types|categories)
      )\b)
      (?=.*\b(?:
        terugbetaling|vergoeding|geneeskundige\s+(?:verzorging|verstrekkingen)|zorg|behandelingen?|nomenclatuur|
        remboursement|soins|prestations\s+de\s+santé|traitements?|nomenclature|
        erstattung|gesundheitsversorgung|behandlungen?|nomenklatur|reimbursement|medical\s+(?:care|services)|treatments?|care
      )\b)
      .*\z
    }imx.freeze
    WORKPLACE_CONTEXT_PATTERN = /\b(?:werk|werken|werkgever|werknemer|arbeid|arbeids|emploi|travail|employeur|salari|arbeit|arbeits|arbeitgeber|arbeitnehmer|beruf)\w*\b/i.freeze
    COMPANY_CONTEXT_PATTERN = /\b(?:vennootschap|onderneming|aandeelhouder|bestuurder|oprichten|oprichting|rechtspersoon|corporation|shareholder|director|société|entreprise|actionnaire|gesellschaft|unternehmen|gesellschafter|geschäftsführer)\w*\b/i.freeze
    COMPANY_ACTION_CONTEXT_PATTERN = /\b(?:bedrijf|company)\b.{0,50}\b(?:opricht(?:en|ing)?|vennootschap|aandeelhoud(?:er|ers)|bestuurder|rechtspersoon|vorm|formation|shareholder|director|société|entreprise|gesellschaft|unternehmen)\b|\b(?:opricht(?:en|ing)?|vennootschap|aandeelhoud(?:er|ers)|bestuurder|rechtspersoon|vorm|formation|shareholder|director|société|entreprise|gesellschaft|unternehmen)\b.{0,50}\b(?:bedrijf|company)\b/i.freeze
    COMPANY_DEFINITION_PATTERN = /\A\s*(?:wat\s+is|what\s+is|was\s+ist|qu['’]est-ce\s+qu['’]?(?:un|une)?|quelle\s+est)\s+(?:een\s+)?(?:bv|cv|nv|vzw|asbl|srl|sprl|gmbh|llc)\b/i.freeze
    NON_COMPANY_ABBREVIATION_CONTEXT_PATTERN = /\b(?:cv[-\s]?ketel|(?:goed|mijn)\s+cv\b|cv['’]s\b|résumé|resume|sollicitatie|huur(?:contract|woning)|huurcontract)\b/i.freeze
    # A generic incorporation-deed question needs the common WVV formation
    # provisions before semantic retrieval gets to choose a neighbouring
    # document. Keep the phrase narrow: "akte" alone is used for medical,
    # court and notarial documents outside company law.
    FORMATION_DEED_PATTERN = /\b(?:oprichtings?akte(?:n|s)?|akte(?:n|s)?\s+van\s+oprichting|oprichtings?document(?:en)?|acte(?:s)?\s+(?:constitutifs?|de\s+constitution)|gründungsurkunde(?:n)?)\b/i.freeze
    FORMATION_DEED_FORM_PATTERN = /\b(?:bv(?:ba)?|besloten\s+vennootschap|srl|cv(?:ba)?|coöperatieve\s+vennootschap|société\s+coopérative|coopérative|nv|naamloze\s+vennootschap|société\s+anonyme|vzw|vereniging\s+zonder\s+winstoogmerk|asbl|ivzw|internationale\s+vereniging|aisbl|stichting|fondation|(?-i:SA|SC))\b/i.freeze
    FORMATION_DEED_GENERIC_PATTERN = /\A(?=.*#{FORMATION_DEED_PATTERN.source})(?!.*#{FORMATION_DEED_FORM_PATTERN.source})/i.freeze
    # French "acte constitutif" also names property/security deeds. An
    # explicit mortgage/servitude/usufruct deed is not an entity's formation
    # deed; do not force the WVV unless the question also identifies an entity.
    FORMATION_DEED_NON_ENTITY_PATTERN = /\bacte(?:s)?\s+(?:constitutif(?:s)?|de\s+constitution)\s+(?:d['’](?:(?:un|une)\s+)?|de\s+(?:(?:la|une?)\s+|l['’])?)(?:hypoth[eèé]ques?|servitudes?|usufruit)\b/i.freeze
    FORMATION_DEED_FORM_PATTERNS = {
      bv: /\b(?:bv(?:ba)?|besloten\s+vennootschap|srl)\b/i,
      cv: /\b(?:cv(?:ba)?|coöperatieve\s+vennootschap|société\s+coopérative|coopérative|(?-i:SC))\b/i,
      nv: /\b(?:nv|naamloze\s+vennootschap|société\s+anonyme|(?-i:SA))\b/i,
      vzw: /\b(?:vzw|vereniging\s+zonder\s+winstoogmerk|asbl)\b/i,
      ivzw: /\b(?:ivzw|internationale\s+vereniging|aisbl)\b/i,
      foundation: /\b(?:stichting|fondation)\b/i
    }.freeze
    FORMATION_DEED_DEPENDENCY_PACKS = {
      bv: %w[2:5 2:8 5:1 5:3 5:5 5:8 5:9 5:12],
      cv: %w[2:5 2:8 6:1 6:4 6:6 6:9 6:10 6:13],
      nv: %w[2:5 2:8 7:2 7:4 7:11 7:12 7:14 7:22]
    }.transform_values(&:freeze).freeze
    FORMATION_DEED_FORM_PRIMARY_ARTICLES = {
      bv: %w[2:8 5:12], cv: %w[2:8 6:13], nv: %w[2:8 7:14],
      vzw: %w[2:9 9:2], ivzw: %w[2:10 10:2], foundation: %w[2:11 11:2]
    }.transform_values(&:freeze).freeze
    FORMATION_DEED_DEPENDENCY_ARTICLES = FORMATION_DEED_DEPENDENCY_PACKS.values.flatten.to_set.freeze
    CUSTODY_CONTEXT_PATTERN = /\b(?:kind(?:eren)?|ouder(?:s)?|familie|gezag|voogd|omgang|garde\s+(?:alternée|des\s+enfants)|enfant(?:s)?|parent(?:s)?|autorité|sorgerecht|elter(?:n)?)\b/i.freeze
    POLICE_CUSTODY_CONTEXT_PATTERN = /\b(?:politie|arrestatie|aanhouding|detentie|verhoor|garde\s+[àa]\s+vue|police|arrest|detention|interrogatoire|polize|haft|vernehmung)\w*\b/i.freeze
    MEDICAL_CONTEXT_PATTERN = /\b(?:medisch|medische|geneesmiddel|geneesmiddelen|arts|dokter|pati[eë]nt|recept|voorschrift|médical|médecin|patient|ordonnance|prescription\s+médicale|medizinisch|arzt|rezept|verschreibung)\w*\b/i.freeze
    RENTAL_CONTEXT_PATTERN = /\b(?:huur|huurder|verhuurder|huurcontract|woning|bail|locataire|propriétaire|loyer|location|miet(?:e|er)|vermieter|mietvertrag)\w*\b/i.freeze
    PATIENT_RIGHTS_CONTEXT_PATTERN = /(?=.*\b(?:pati[eë]nt(?:en)?|patient(?:s)?|patients?|patienten)\b)(?=.*\b(?:recht(?:en)?|dossier|toestemming|consent|privacy|inzage|informatie|droits?|dossier\s+médical|consentement|einwilligung|rechte|akte)\b)/i.freeze

    # Legal questions often start with a forum introduction or end with a
    # personal opinion. Such scaffolding must not consume the lexical budget
    # or reward an unrelated statute simply because it contains "volgens".
    # Keep compounds (thuiswerk, verblijfsvergunning, ...) intact: only whole
    # conversational tokens are discarded, in all supported query languages.
    QUERY_STOP_WORDS = Set.new(%w[
                                 wat is de het een op van voor met als in door bij hoe kan mag moet waar wanneer welke welk wie waarom hoeveel
                                 zijn mijn ik recht hebben rechten onder aan naar tot dit deze die dat jaar jaren er iemand thuis wil willen
                                 weten graag name namelijk rond volgens niet iedere elke zelf bepaalt tijdens gaat valt om nu ook zo nog
                                 kunnen zou wordt worden geeft bestaat bestaan zeggen vraag vragen eigenlijk dus mij uw je jouw onze
                                 le la les un une des du au aux en est ce que qui quoi quel quelle quels quelles pour avec dans par sur
                                 sous comment procédure peut peux puis doit dois où quand pourquoi combien mon ma mes votre vos son sa ses
                                 cette ces être avoir quelqu'un quelqu quelquune savoir voudrais souhaite concernant notamment pendant
                                 der das ein eine einer eines den dem und oder zu zum zur im auf von mit für ist sind war
                                 waren sein was wer wo wann warum welche welcher welches kann darf muss soll mein meine ihr ihre
                                 ich jemand wissen möchte während jeweils selbst bezüglich insbesondere
                                 the a an of on for with into from by as are were be been this that these those what which who
                                 where when why how can could may must should do does my your his her their our someone anyone know want
                                 would please about regarding during according whether each every itself myself
                               ]).freeze
    IMPORTANT_SHORT_QUERY_WORDS = (EXACT_CORE_LAW_KEYWORDS | Set.new(%w[rsz bob wet kb mb bw ar])).freeze
    MAX_LEXICAL_TERMS = 12

    # A bounded morphology bridge for FTS5. The production FTS index uses the
    # default tokenizer (no Dutch/French stemmer), so use prefix queries only
    # as a fallback when exact lexical matches are sparse. This avoids a broad
    # stemmer turning ordinary words into noisy search terms.
    FTS_STEM_SUFFIXES = %w[eringen ering ations ation heids heid ement ment ing en er es s e].freeze
    FTS_IRREGULAR_PREFIXES = {
      'belaging' => %w[belaag belag],
      'belaagd' => %w[belaag belag],
      'belagen' => %w[belaag belag]
    }.freeze

    REGIONAL_TAX_NUMACS = Set.new(%w[2013036154 1936033102 1939113002]).freeze
    FLANDERS_TAX_NUMACS = Set.new(%w[2013036154]).freeze
    REGIONAL_TAX_SUBJECT_PATTERN = /\b(?:erfbelasting|erfenisbelasting|successierecht|schenkbelasting|schenkingsrecht|registratiebelasting|registratierecht(?:en)?|verkooprecht|verdeelrecht|onroerende\s+voorheffing|droits?\s+(?:(?:de\s+)?(?:succession|donation|enregistrement|vente)|d['’]enregistrement)|precompte\s+immobilier|précompte\s+immobilier|erbschafts?steuer|schenkungs?steuer|registrierungssteuer|inheritance\s+tax|gift\s+tax|registration\s+tax|property\s+tax)\b/i
    REGIONAL_TAX_GIFT_TERM_PATTERN = /(?<![[:alnum:]])(?:schenking|donation|schenkung|gift)(?![[:alnum:]])/iu
    REGIONAL_TAX_EXPRESSION_PATTERN = /(?<![[:alnum:]])(?:belasting(?:en)?|belast[[:alpha:]]*|rechten?|tax[[:alpha:]]*|imp[oô]t|impos[[:alpha:]]*|fisc[[:alpha:]]*|steuer[[:alpha:]]*|besteuer[[:alpha:]]*|versteuer[[:alpha:]]*)(?![[:alnum:]])/iu
    REGIONAL_TAX_GIFT_CONTEXT_PATTERN = Regexp.union(
      /#{REGIONAL_TAX_GIFT_TERM_PATTERN.source}.{0,40}#{REGIONAL_TAX_EXPRESSION_PATTERN.source}/iu,
      /#{REGIONAL_TAX_EXPRESSION_PATTERN.source}.{0,40}#{REGIONAL_TAX_GIFT_TERM_PATTERN.source}/iu
    )
    REGIONAL_TAX_SUCCESSION_TERM_PATTERN = /(?<![[:alnum:]])(?:erfenis|nalatenschap|successie|héritage|heritage|succession|inheritance|erbschaft)(?![[:alnum:]])/iu
    REGIONAL_TAX_SUCCESSION_CONTEXT_PATTERN = Regexp.union(
      /#{REGIONAL_TAX_SUCCESSION_TERM_PATTERN.source}.{0,40}#{REGIONAL_TAX_EXPRESSION_PATTERN.source}/iu,
      /#{REGIONAL_TAX_EXPRESSION_PATTERN.source}.{0,40}#{REGIONAL_TAX_SUCCESSION_TERM_PATTERN.source}/iu
    )
    SUCCESSION_TAX_PATTERN = /\b(?:erfbelasting|erfenisbelasting|successierecht|erfenis|nalatenschap|successie|droits?\s+(?:de\s+)?succession|héritage|heritage|succession|erbschaft|erbschafts?steuer|inheritance|inheritance\s+tax)\b/i
    REGISTRATION_TAX_PATTERN = /\b(?:schenkbelasting|schenkingsrecht|schenking|registratiebelasting|registratierecht(?:en)?|verkooprecht|verdeelrecht|droits?\s+(?:(?:de\s+)?(?:donation|enregistrement|vente)|d['’]enregistrement)|donation|schenkung|schenkungs?steuer|registrierungssteuer|gift|gift\s+tax|registration\s+tax)\b/i
    # The taxes for which art. 4, § 1 of the special financing act gives the regions the
    # rate, the taxable base and the exemptions: art. 3, first paragraph, 1° to 4° and 6° to
    # 9°, which covers succession duties (4°) and the registration duties (6° to 8°).
    #
    # Deliberately NOT REGIONAL_TAX_SUBJECT_PATTERN. That constant also carries onroerende
    # voorheffing / précompte immobilier / property tax, which is art. 3, 5° and is governed
    # by art. 4, § 2 with its own carve-out forbidding the regions to change the federal
    # kadastraal inkomen. Reusing it would cite the wrong legal basis for a quarter of what
    # it matches.
    REGIONAL_TAX_COMPETENCE_PATTERN =
      Regexp.union(SUCCESSION_TAX_PATTERN, REGISTRATION_TAX_PATTERN).freeze
    FLANDERS_REGION_PATTERN = RegionalSearch::REGION_PATTERNS.fetch('vlaamse_codex')
    WALLONIA_REGION_PATTERN = RegionalSearch::REGION_PATTERNS.fetch('wallex')
    BRUSSELS_REGION_PATTERN = RegionalSearch::REGION_PATTERNS.fetch('brussels')
    BRUSSELS_WALLONIA_REGION_PATTERN = Regexp.union(WALLONIA_REGION_PATTERN, BRUSSELS_REGION_PATTERN)
    FOREIGN_SUCCESSION_TAX_SUBJECT_PATTERN = /\b(?:erfbelasting\w*|erfenisbelasting\w*|successierecht\w*|droits?\s+(?:de\s+)?succession|inheritance\s+tax\w*|estate\s+tax\w*|Erbschafts?steuer\w*)\b/iu.freeze
    FOREIGN_SUCCESSION_COUNTRY_PATTERN = /\b(?:USA|(?-i:U\.?S\.?A?\.?|VS)|Verenigde\s+Staten|United\s+States|[ÉE]tats[-\s]+Unis|Vereinigte\w*\s+Staaten|buitenland|abroad|[ée]tranger|Ausland|Canada|Zwitserland|Suisse|Switzerland|Schweiz|Frankrijk|France|Frankreich|Duitsland|Germany|Deutschland|Nederland|Netherlands|Pays[-\s]+Bas|Niederlande|Spanje|Spain|Espagne|Spanien|Italië|Italia|Italie|Italy|Italien|Portugal|Australië|Australia|Australie|Australien|Engeland|England|Royaume[-\s]+Uni|United\s+Kingdom|Verenigd\s+Koninkrijk|Großbritannien)\b/iu.freeze
    FOREIGN_SUCCESSION_RESIDENCE_PATTERN = %r{
      \b(?:woon\w*|wonen|woont|woonde|woonden|verblijft|verbleef|résid\p{L}*|habit\p{L}*|vivait|lived?|living|resid\w*|wohn\w*|lebt\w*)\b[^\n.!?;]{0,65}#{FOREIGN_SUCCESSION_COUNTRY_PATTERN.source}|
      #{FOREIGN_SUCCESSION_COUNTRY_PATTERN.source}[^\n.!?;]{0,45}\b(?:woon\w*|wonen|woont|woonde|woonden|résid\p{L}*|habit\p{L}*|vivait|lived?|living|resid\w*|wohn\w*|lebt\w*)\b
    }ixu.freeze
    FOREIGN_SUCCESSION_DEATH_PATTERN = /\b(?:overled\w*|gestorven|décéd\p{L}*|mort\w*|died|dead|deceased|verstorben|gestorben)\b/iu.freeze
    FOREIGN_DECEASED_SUCCESSION_TAX_PATTERN = %r{
      \A
      (?=.*#{FOREIGN_SUCCESSION_TAX_SUBJECT_PATTERN.source})
      (?=.*(?:
        \b(?:erflater\w*|overleden\w*|défunt\p{L}*|deceased|testator\w*|Verstorbene\w*|Erblasser\w*)\b[^\n.!?;]{0,100}(?:#{FOREIGN_SUCCESSION_RESIDENCE_PATTERN.source})|
        \b(?:achternicht\w*|achterneef\w*|tante\w*|oom\w*|nicht\w*|neef\w*|familielid\w*|moeder|vader|cousin\w*|aunt\w*|uncle\w*|relative\w*|mother|father|Tante\w*|Onkel\w*|Cousine?\w*|Mutter|Vater)\b[^\n.!?;]{0,100}
          (?:#{FOREIGN_SUCCESSION_RESIDENCE_PATTERN.source})
          (?:[^\n.!?;]{0,120}#{FOREIGN_SUCCESSION_DEATH_PATTERN.source}|
             [^\n.!?;]{0,60}[.!?;]\s*(?:she|he|they|ze|zij|hij|il|elle|sie|er)\b[^\n.!?;]{0,100}#{FOREIGN_SUCCESSION_DEATH_PATTERN.source})
      ))
      .*\z
    }imxu.freeze
    PUBLIC_BUDGET_SOURCE_PATTERN = /\b(?:begroting\w*|budget\w*|budgétaire\w*|Haushaltsgesetz\w*|Haushaltsplan\w*)\b/iu.freeze
    PUBLIC_BUDGET_QUERY_PATTERN = /\b(?:begroting\w*|budgetdecreet\w*|budgetwet\w*|public\s+budget\w*|government\s+budget\w*|budget\s+(?:decree|law|de\s+l['’][ée]tat)|budgétaire\w*|Haushaltsgesetz\w*|Haushaltsplan\w*)\b/iu.freeze
    SUCCESSION_PENSION_SOCIAL_INSURANCE_QUERY_PATTERN = /\b(?:sociale\s+zekerheid|sécurité\s+sociale|social\s+(?:security|insurance)|Sozialversicherung\w*|sociale\s+verzekering\w*|assurances?\s+sociales?|\p{L}*pensioen\p{L}*|pension\w*|retirement\w*|retraite\w*|(?-i:Rente\w*)|uitkering\w*|benefit\w*|prestation\w*)\b/iu.freeze
    SUCCESSION_TAX_SOURCE_SUBJECT_PATTERN = /\b(?:erfbelast\p{L}*|erf[-\s]+en\s+schenkbelast\p{L}*|successie\p{L}*|droits?\s+(?:de\s+)?succession|inheritance\s+tax\p{L}*|estate\s+tax\p{L}*|Erbschafts?steuer\p{L}*)\b/iu.freeze
    SUCCESSION_PARTNER_SOURCE_PATTERN = /\b(?:langstlevend\p{L}*|partner\p{L}*|echtgeno(?:ot|te|ten)|samenwon\p{L}*|conjoint\p{L}*|partenaire\p{L}*|[ée]pou(?:x|se)|cohabitant\p{L}*|surviv\p{L}*\s+(?:spouse|partner)|spouse\p{L}*|Lebenspartner\p{L}*|Ehegatt\p{L}*)\b/iu.freeze
    SUCCESSION_SURVIVOR_COHABITANT_QUERY_PATTERN = /\b(?:langstlevend\p{L}*|weduw\p{L}*|veuf\p{L}*|veuve\p{L}*|widow\p{L}*|widower\p{L}*|samenwon\p{L}*|cohabit\p{L}*|surviving\s+(?:spouse|partner)|(?:conjoint|partenaire|[ée]pou(?:x|se))\s+survivant\p{L}*|überlebend\p{L}*\s+(?:Ehegatt\p{L}*|Lebenspartner\p{L}*)|Witwe\p{L}*|Witwer\p{L}*|Lebensgemeinschaft\p{L}*)\b/iu.freeze
    SUCCESSION_PARTNER_RELATIONSHIP_PATTERN = /\b(?:vrouw|man|echtgeno(?:ot|te|ten)|partner\p{L}*|femme|mari|[ée]pou(?:x|se)|conjoint\p{L}*|partenaire\p{L}*|wife|husband|spouse|Ehegatt\p{L}*|Ehefrau|Ehemann|Lebenspartner\p{L}*)\b/iu.freeze
    SUCCESSION_PARTNER_DEATH_PATTERN = Regexp.union(
      FOREIGN_SUCCESSION_DEATH_PATTERN,
      /\b(?:overlijd\p{L}*|décèd\p{L}*|dies|sterb\p{L}*|stirb\p{L}*)\b/iu
    ).freeze
    SUCCESSION_NON_PARTNER_RELATIVE_PATTERN = /\b(?:achternicht\p{L}*|achterneef\p{L}*|tante\p{L}*|oom\p{L}*|nicht\p{L}*|neef\p{L}*|familielid\p{L}*|moeder|vader|cousin\p{L}*|aunt\p{L}*|uncle\p{L}*|relative\p{L}*|mother|father|Tante\p{L}*|Onkel\p{L}*|Cousine?\p{L}*|Mutter|Vater)\b/iu.freeze
    SUCCESSION_REGIONAL_INSTRUMENT_PATTERN = /\b(?:decreet|décret|decree|ordonnantie|ordonnance|ordinance|Dekret)\b/iu.freeze
    SUCCESSION_REFORM_HISTORY_QUERY_PATTERN = /\b(?:hervorm\p{L}*|moderniser\p{L}*|wijzig\p{L}*|historisch\p{L}*|historique\p{L}*|historical|geschichtlich\p{L}*|amend\p{L}*|réform\p{L}*|reform\p{L}*|modifi\p{L}*|Änder\p{L}*|Modernisier\p{L}*)\b/iu.freeze
    SUCCESSION_INSTRUMENT_STATUS_QUERY_PATTERN = /\b(?:nog\s+(?:van\s+kracht|geldig)|geldt\s+nog|huidige\s+(?:status|versie)|actuele\s+(?:status|versie)|current\s+(?:status|version)|still\s+(?:in\s+force|valid|applicable)|toujours\s+(?:en\s+vigueur|valable)|statut\s+actuel|version\s+actuelle|noch\s+(?:in\s+Kraft|gültig)|aktueller?\s+(?:Stand|Status|Fassung))\b/iu.freeze
    FOREIGN_SUCCESSION_SPECIALIST_SOURCE_GATES = [
      [%w[1975092450], /\b(?:Belgi\p{L}*|Belgique|Belgium|Belgien)\b.{0,80}\b(?:Zwitserland|Suisse|Switzerland|Schweiz)\b.{0,100}\b(?:sociale\s+zekerheid|sécurité\s+sociale|social\s+security|Sozialversicherung)\b/iu,
       /\b(?:sociale\s+zekerheid|sécurité\s+sociale|social\s+(?:security|insurance)|Sozialversicherung|pensioen\w*|pension\w*|rente\w*|uitkering\w*|benefit\w*|prestation\w*)\b/iu],
      [%w[2009200916], /\b(?:waarborgregeling|garantie\w*\s+régionale\w*|regional\s+guarantee\w*)\b/iu,
       /\b(?:waarborgregeling|overheidswaarborg\w*|bankgarantie\w*|borgtocht\w*|garantie\w*\s+régionale\w*|regional\s+guarantee\w*|guarantee\s+(?:scheme|loan\w*)|state\s+guarantee\w*|Bürgschaft\w*)\b/iu],
      [[], /\b(?:sociale\s+zekerheid|sécurité\s+sociale|social\s+(?:security|insurance)|Sozialversicherung\w*|sociale\s+verzekering\w*|assurances?\s+sociales?)\b/iu,
       SUCCESSION_PENSION_SOCIAL_INSURANCE_QUERY_PATTERN],
      [[], /\b(?:\p{L}*pensioen\p{L}*|pension\w*|Rentenversicherung\w*|Rentenrecht)\b/iu,
       SUCCESSION_PENSION_SOCIAL_INSURANCE_QUERY_PATTERN],
      [[], PUBLIC_BUDGET_SOURCE_PATTERN, PUBLIC_BUDGET_QUERY_PATTERN]
    ].map(&:freeze).freeze
    # This bounded pack supplies connecting factors before rates. An unknown
    # region admits only these exact applicability rows, with regional labels;
    # it does not admit the surrounding Flemish/residual tariff chapters.
    FOREIGN_SUCCESSION_APPLICABILITY_TARGETS = [%w[1936033102 1], %w[1989021010 5],
                                                %w[2013036154 2.7.3.2.2]].map(&:freeze).freeze
    FOREIGN_SUCCESSION_REGIONAL_LABELS = {
      'nl' => { '1936033102' => 'Brussel / Wallonië (toepasselijkheid te controleren)',
                '2013036154' => 'Vlaanderen (alleen indien de Vlaamse regeling van toepassing is)' },
      'fr' => { '1936033102' => 'Bruxelles / Wallonie (applicabilité à vérifier)',
                '2013036154' => 'Flandre (uniquement si le régime flamand est applicable)' },
      'de' => { '1936033102' => 'Brüssel / Wallonien (Anwendbarkeit zu prüfen)',
                '2013036154' => 'Flandern (nur wenn die flämische Regelung anwendbar ist)' },
      'en' => { '1936033102' => 'Brussels / Wallonia (applicability to be checked)',
                '2013036154' => 'Flanders (only if the Flemish regime applies)' }
    }.transform_values(&:freeze).freeze
    REGIONAL_FAMILY_BENEFIT_PATTERN = /\b(?:groeipakket|kinderbijslag|allocations?\s+familiales|kindergeld|child\s+benefit|family\s+allowance)\b/i
    REGIONAL_HOUSING_NUMACS = Set.new(%w[2018015087 2013A31614 2018201408]).freeze
    HOUSING_CONTEXT_EXCLUDED_NUMACS = Set.new(%w[1978070303]).freeze
    # Keep the established legal vocabulary, but also recognise the colloquial
    # residential wording users actually type.  The added branches require a
    # dwelling term alongside a rental/landlord cue: "appartement" or "huur"
    # alone must not open a regional housing lane (and neither must a car/hall/
    # business rental).  Region selection remains unchanged downstream.
    REGIONAL_HOUSING_SUBJECT_PATTERN = %r{
      \b(?:woninghuur|huurwoning(?:en)?|huurwaarborg|huurcontract|huurder|verhuurder|uithuiszetting|plaatsbeschrijving|bail\s+(?:d['’]habitation|de\s+residence|de\s+résidence)|locataire|bailleur|garantie\s+locative|expulsion|état\s+des\s+lieux|mietvertrag|mietkaution|mieterh[oö]hung|mieter|vermieter|wohnungsmiete|kurzzeitmiete|mietdauer|tenant|landlord|rental\s+deposit|residential\s+(?:rent|lease|tenancy)|short-term\s+rental|eviction|property\s+inventory|condition\s+report)\b
      |
      \b(?:huur|huren|huurde)\b
      (?:(?!\b(?:auto|wagen|kantoor|winkel|bedrijf|zaal|hal|loods|commercieel|business|office|shop|car)\w*\b)[^.!?,;\n]){0,45}
      \b(?:appartement|woning|huis)\b
      |
      \b(?:appartement|woning|huis)\b
      (?:(?!\b(?:auto|wagen|kantoor|winkel|bedrijf|zaal|hal|loods|commercieel|business|office|shop|car)\w*\b)[^.!?,;\n]){0,45}
      \bgehuurd\b
      |
      \bhuisbaas\b
      (?:(?!\b(?:kantoor|winkel|bedrijf|zaal|hal|loods|commercieel|business|office|shop)\w*\b)[^.!?,;\n]){0,45}
      \b(?:appartement|woning|huis)\b
      |
      \b(?:appartement|woning|huis)\b
      (?:(?!\b(?:kantoor|winkel|bedrijf|zaal|hal|loods|commercieel|business|office|shop)\w*\b)[^.!?,;\n]){0,45}
      \bhuisbaas\b
    }ix
    # An explicit residential tenancy in solely Flanders is a sufficient core
    # intent, even when the ordinary catalogue has no "huurwoning" key. Do not
    # turn a CV application, owner-occupied heating or commercial lease into
    # a residential-rental answer. Comparisons keep their ordinary retrieval.
    FLANDERS_RESIDENTIAL_RENTAL_PATTERN = %r{
      \A
      (?=.*#{FLANDERS_REGION_PATTERN.source})
      (?!.*(?:#{BRUSSELS_WALLONIA_REGION_PATTERN.source}))
      (?!.*#{RegionalSearch::UNSUPPORTED_GERMAN_COMMUNITY_PATTERN.source})
      (?=.*\b(?:
        woninghuur(?:decreet)?|huurwoning(?:en)?|huurhuis|huurappartement|
        bail\s+(?:d['’]habitation|de\s+r[ée]sidence)|logement\s+(?:lou[ée]|en\s+location)|
        residential\s+(?:rent|lease|tenancy)|rental\s+(?:home|dwelling|apartment)|
        rented\s+(?:home|dwelling|apartment)|wohnungsmiete|mietwohnung|
        rent(?:ing)?\s+(?:a|an|the|my|our)\s+(?:home|house|apartment|dwelling)|
        huur(?:en)?\s+(?:een|de|mijn|onze)\s+(?:woning|huis|appartement)|
        loue(?:r|nt)?\s+(?:un|une|le|la|mon|ma|notre)\s+(?:logement|maison|appartement)|
        miete(?:n)?\s+(?:eine?|meine?|unsere?)\s+(?:wohnung|haus)
      )\b|
      # English Reddit questions often say only “landlord/tenant + lease”
      # and put the residential cue in a separate sentence (for example,
      # “Landlord gave notice ... on a registered lease ... apartment”).
      # Require all three facts so a commercial or railway management
      # contract cannot activate the residential regional lane.
      (?=.*\b(?:lease|tenancy|huurcontract|huurovereenkomst|geregistreerde\s+huur|bail|mietvertrag|[\p{L}\p{N}_-]+mietvertrag)\b)
      (?=.*\b(?:landlord|tenant|verhuurder|huurder|huisbaas|bailleur|locataire|vermieter|mieter)\b)
      (?=.*\b(?:apartment|appartment|flat|home|house|dwelling|appartement|woning|huis|logement|maison|wohnung|haus)\b)
      )
      (?!.*\b(?:do\s+not|don't|never)\s+rent(?:ing)?\s+(?:a|an|the|my|our)\s+(?:home|house|apartment|dwelling)\b)
      (?!.*\b(?:handelshuur|bail\s+commercial|commercial\s+(?:lease|rent|tenancy|rental)|gewerbe(?:raum)?miete|gesch[aä]ftsmiete)\b)
      .*\z
    }imxu.freeze
    FLANDERS_RENTAL_APPLICATION_PATTERN = %r{
      \A(?=#{FLANDERS_RESIDENTIAL_RENTAL_PATTERN.source})
      (?=.*\b(?:cv|curriculum\s+vitae|document(?:en|s)?|gegevens|informatie|information|donn[ée]es|unterlagen|angaben)\b)
      (?=.*\b(?:aanvraag|kandidaat[\s-]huurder|candidature|candidat[\s-](?:locataire|preneur)|application|prospective\s+tenant|bewerbung|mietinteressent)\b)
      .*\z
    }imxu.freeze
    FLANDERS_RENTAL_MAINTENANCE_PATTERN = %r{
      \A(?=#{FLANDERS_RESIDENTIAL_RENTAL_PATTERN.source})
      (?=.*\b(?:onderhoud|herstelling(?:en)?|herstellen|reparatie(?:s)?|repareren|entretien|r[ée]paration(?:s)?|maintenance|repairs?|reparatur(?:en)?|wartung|instandhaltung)\b)
      .*\z
    }imxu.freeze

    # These provisions belong to the main-residence regime, not student
    # leases. A dated pre-2019 contract must retain ordinary retrieval rather
    # than receiving current-regime pins. Merely naming the 2018 decree is
    # not a historical-contract signal.
    RESIDENTIAL_LEASE_WORD_PATTERN = /\b(?:huurcontract|huurovereenkomst|woninghuur|bail|mietvertrag|lease|tenancy)\b/i.freeze
    RESIDENTIAL_LEASE_HISTORY_WORD_PATTERN = %r{(?:#{RESIDENTIAL_LEASE_WORD_PATTERN.source}|geregistreerde\s+huur|[\p{L}\p{N}_-]+mietvertrag)}i.freeze
    HISTORICAL_RESIDENTIAL_LEASE_PATTERN = %r{
      #{RESIDENTIAL_LEASE_HISTORY_WORD_PATTERN.source}
      [^.!?;]{0,30}\b(?:signed|started|began|commenced|concluded|entered\s+into|dated|from|ondertekend|afgesloten|aangegaan|ingegaan|begonnen|sinds|van|sign[ée]|conclu|commenc[ée]|depuis|unterzeichnet|abgeschlossen|begonnen|seit)\b
      [^.!?;]{0,15}(?<!\d)(?:19\d{2}|200\d|201[0-8])(?!\d)
      |
      (?<!\d)(?:19\d{2}|200\d|201[0-8])(?!\d)[^.!?;]{0,25}
      \b(?:signed|started|concluded|ondertekende|sloot|begon|sign[ée]|conclu|unterzeichnet|abgeschlossen)\b
      [^.!?;]{0,20}#{RESIDENTIAL_LEASE_HISTORY_WORD_PATTERN.source}
    }ixu.freeze
    FLANDERS_CURRENT_MAIN_RESIDENCE_RENTAL_PATTERN = %r{
      \A(?=#{FLANDERS_RESIDENTIAL_RENTAL_PATTERN.source})
      (?!.*\b(?:student(?:en)?(?:huur|woning|kamer|en)?|student\s+(?:lease|tenancy|housing|accommodation)|bail\s+[ée]tudiant|logement\s+[ée]tudiant|[ée]tudiant(?:e)?|studenten(?:mietvertrag|wohnung|wohnheim)|studierenden(?:miete|wohnung))\b)
      (?!.*(?:#{HISTORICAL_RESIDENTIAL_LEASE_PATTERN.source}))
      .*\z
    }imxu.freeze
    SHORT_RESIDENTIAL_LEASE_DURATION_PATTERN = %r{
      \b(?:short[\s\p{Pd}]?(?:term|duration)|kort(?:e|lopend(?:e)?)|courte\s+dur[ée]e|kurzfristig(?:en|er|e)?)\s+(?:residential\s+)?(?:lease|tenancy|huurcontract|huurovereenkomst|bail|mietvertrag)\b
      |
      #{RESIDENTIAL_LEASE_WORD_PATTERN.source}\s+(?:of\s+short\s+duration|de\s+courte\s+dur[ée]e|van\s+korte\s+duur)\b
      |
      \b(?:1|2|3|one|two|three|[ée][ée]n|twee|drie|un|une|deux|trois|ein(?:en|em|e)?|zwei|drei)[\s\p{Pd}]+(?:year(?:s)?|jaar|jaren|an(?:s)?|jahr(?:e|en)?)[\s\p{Pd}]+(?:lease|tenancy|huurcontract|huurovereenkomst|bail|mietvertrag)\b
      |
      \b(?:[1-9]|[12]\d|3[0-6])[\s\p{Pd}]+(?:month(?:s)?|maand(?:en)?|mois|monat(?:e|en)?)[\s\p{Pd}]+(?:lease|tenancy|huurcontract|huurovereenkomst|bail|mietvertrag)\b
      |
      #{RESIDENTIAL_LEASE_WORD_PATTERN.source}\s+(?:(?:of|for|lasting|van|voor|de|pour|von|f[üu]r|[üu]ber)\s+|d['’])?(?:a\s+)?
      (?:1|2|3|one|two|three|[ée][ée]n|twee|drie|un|une|deux|trois|ein(?:en|em|e)?|zwei|drei)[\s\p{Pd}]+(?:year(?:s)?|jaar|jaren|an(?:s)?|jahr(?:e|en)?)\b
      |
      #{RESIDENTIAL_LEASE_WORD_PATTERN.source}\s+(?:(?:of|for|lasting|van|voor|de|pour|von|f[üu]r|[üu]ber)\s+)?(?:[1-9]|[12]\d|3[0-6])[\s\p{Pd}]+(?:month(?:s)?|maand(?:en)?|mois|monat(?:e|en)?)\b
    }ixu.freeze
    RESIDENTIAL_LEASE_NONREGISTRATION_PATTERN = %r{
      \b(?:unregistered|ongeregistreerd(?:e)?|niet\s+geregistreerd(?:e)?|non\s+enregistr[ée]|nicht\s+registriert(?:en|er|e)?)\s+#{RESIDENTIAL_LEASE_WORD_PATTERN.source}
      |
      #{RESIDENTIAL_LEASE_WORD_PATTERN.source}\s+(?:(?:is|was|has|have|been|yet|werd|wordt|est|[ée]t[ée]|n['’]a|n['’]est|n['’][ée]tait|a|[ée]tait|ist|wurde)\s+){0,4}
      (?:not|never|isn't|wasn't|hasn't|niet|nooit|pas|jamais|non|nicht|nie)\s+(?:(?:been|yet|[ée]t[ée]|encore|noch)\s+){0,3}(?:registered|geregistreerd|enregistr[ée]|registriert)\b
      |
      \b(?:not|never|didn't|niet|nooit|pas|jamais|nicht|nie)\s+(?:register|registreren|enregistrer|registrieren)\s+(?:(?:the|my|our|het|mijn|ons|le|mon|notre|den|meinen|unseren)\s+)?#{RESIDENTIAL_LEASE_WORD_PATTERN.source}
      |
      #{RESIDENTIAL_LEASE_WORD_PATTERN.source}[^.!?;]{0,45}\b(?:non[\s\p{Pd}]registration|niet[\s\p{Pd}]registratie|non[\s\p{Pd}]enregistrement|nichtregistrierung)\b
    }ixu.freeze
    RESIDENTIAL_LEASE_REGISTRATION_PATTERN = %r{
      #{RESIDENTIAL_LEASE_NONREGISTRATION_PATTERN.source}
      |
      #{RESIDENTIAL_LEASE_WORD_PATTERN.source}\s+(?:(?:is|was|has|have|been|not|never|yet|niet|nooit|werd|wordt|est|[ée]t[ée]|pas|jamais|n['’]a|a|[ée]tait|ist|wurde|nicht|nie|noch)\s+){0,6}(?:registered|geregistreerd|enregistr[ée]|registriert)\b
      |
      \b(?:register|registered|registreren|registreert|enregistrer|enregistr[ée]|registrieren|registriert)\s+(?:(?:the|my|our|het|mijn|ons|le|mon|notre|den|meinen|unseren)\s+)?#{RESIDENTIAL_LEASE_WORD_PATTERN.source}
      |
      \b(?:registration|registratie|enregistrement|registrierung)\s+(?:of|van|de|des)\s+(?:(?:the|my|our|het|mijn|ons|mon|notre|meines|unseres)\s+)?#{RESIDENTIAL_LEASE_WORD_PATTERN.source}
    }ixu.freeze
    RESIDENTIAL_EARLY_TERMINATION_PATTERN = /\b(?:early\s+(?:termination|departure|ending)|(?:leave|leaving|end|ending|terminate)\s+early|opzeg(?:gen|ging)?|vroegtijdig(?:e)?|be[ëe]indig\w*|r[ée]sili(?:er|ation)|quitter\s+avant|vorzeitig|k[üu]ndig(?:en|ung))\b/i.freeze
    FLANDERS_SHORT_RENTAL_TERMINATION_PATTERN = %r{
      \A(?=#{FLANDERS_CURRENT_MAIN_RESIDENCE_RENTAL_PATTERN.source})
      (?=.*(?:#{SHORT_RESIDENTIAL_LEASE_DURATION_PATTERN.source}))
      (?=.*(?:#{RESIDENTIAL_EARLY_TERMINATION_PATTERN.source}|#{RESIDENTIAL_LEASE_NONREGISTRATION_PATTERN.source}))
      .*\z
    }imxu.freeze
    FLANDERS_RENTAL_REGISTRATION_PATTERN = %r{
      \A(?=#{FLANDERS_CURRENT_MAIN_RESIDENCE_RENTAL_PATTERN.source})
      (?=.*(?:#{RESIDENTIAL_LEASE_REGISTRATION_PATTERN.source}))
      .*\z
    }imxu.freeze
    FLANDERS_RENTAL_HABITABILITY_PATTERN = %r{
      \A(?=#{FLANDERS_CURRENT_MAIN_RESIDENCE_RENTAL_PATTERN.source})
      (?=.*\b(?:mou?ld|schimmel|moisissure(?:s)?|habitability|uninhabitable|onbewoonbaar|onbewoonbaarheid|bewoonbaarheid|insalubrit[ée]|inhabitabilit[ée]|salubrit[ée]|unbewohnbar|bewohnbarkeit|housing\s+inspection|woninginspectie|wooninspectie|conformiteits(?:onderzoek|attest)|inspection\s+du\s+logement|wohnungsinspektion)\b)
      .*\z
    }imxu.freeze
    # A standard (long) Flemish lease question can concern a landlord's
    # proposed sale, personal occupation, renovation or no-motive notice. A
    # sale itself is not a termination ground; the matcher only makes the
    # relevant notice/ground provisions available for that distinction. The
    # existing short-
    # lease matcher intentionally does not cover a five-year lease, so keep
    # this as a separate, explicit residential route. It requires the named
    # Flemish region, a landlord/tenant relationship, a dwelling and both a
    # notice/termination cue and a sale/occupation/renovation cue; a generic
    # business or railway contract must not enter this lane.
    FLANDERS_LANDLORD_TERMINATION_PATTERN = %r{
      \A(?=#{FLANDERS_CURRENT_MAIN_RESIDENCE_RENTAL_PATTERN.source})
      (?!.*(?:#{SHORT_RESIDENTIAL_LEASE_DURATION_PATTERN.source}))
      (?=.*\b(?:landlord|verhuurder|huisbaas|bailleur|vermieter)\b)
      (?=.*\b(?:notice|préavis|opzeg\w*|terminate\w*|end\w*|leave\w*|evict\w*|be[ëe]indig\w*|r[ée]sili\w*|k[üu]ndig\w*)\b)
      (?=.*\b(?:sale|sell\w*|sold|verkop\w*|verkoop\w*|vente|vendre\w*|vendu|verkauf\w*|verkaufen\w*|occupation|occupy\w*|personal\s+use|eigen\s+gebruik|renovat\w*|travaux|renovation|renovatie)\b)
      .*\z
    }imxu.freeze
    # A sale also raises the distinct transfer-to-the-buyer rule (Art. 38),
    # even when the tenant is not asking about termination. Keep this
    # relationship and dwelling gate separate from the notice/ground route.
    FLANDERS_LANDLORD_SALE_TRANSFER_PATTERN = %r{
      \A(?=#{FLANDERS_CURRENT_MAIN_RESIDENCE_RENTAL_PATTERN.source})
      (?=.*\b(?:landlord|verhuurder|huisbaas|bailleur|vermieter)\b)
      (?=.*\b(?:sale|sell\w*|sold|verkop\w*|verkoop\w*|vente|vendre\w*|vendu|verkauf\w*|verkaufen\w*)\b)
      .*\z
    }imxu.freeze
    # Notice/compensation and habitability rules sit in Title II. Supplying
    # them without its applicability and mandatory-law provisions left the
    # model unable to evaluate a contradictory twelve-month contractual fee.
    # Keep the same main-residence, region and historical-contract gates.
    FLANDERS_RENTAL_SCOPE_PATTERN = Regexp.union(
      FLANDERS_SHORT_RENTAL_TERMINATION_PATTERN,
      FLANDERS_RENTAL_REGISTRATION_PATTERN,
      FLANDERS_RENTAL_HABITABILITY_PATTERN,
      FLANDERS_LANDLORD_TERMINATION_PATTERN,
      FLANDERS_LANDLORD_SALE_TRANSFER_PATTERN
    ).freeze
    # A focused residential-tenancy question can contain broad terms such as
    # "registration", "inspection" and "address".  Those terms are common
    # in education and administrative-law documents too, so vector/lexical
    # retrieval must not use them as a licence to fill the legal answer with a
    # foreign domain.  This deliberately recognises the *candidate source*,
    # rather than maintaining a blacklist of document numbers: a federal
    # provision that actually concerns a lease remains available alongside the
    # governing regional code.
    RESIDENTIAL_HOUSING_SOURCE_PATTERN = /\b(?:woning\w*|woon\w*|logement\w*|habitat\w*|r[ée]siden\w*|\
      dwelling\w*|housing\w*|habitation\w*|wohn\w*)\b/ixu.freeze
    RESIDENTIAL_TENANCY_RELATIONSHIP_PATTERN = %r{
      (?=.*\b(?:huur\w*|bail\w*|locat\w*|lease\w*|rental\w*|miet\w*)\b)
      (?=.*\b(?:huurder\w*|verhuurder\w*|tenant\w*|landlord\w*|locataire\w*|bailleur\w*|mieter\w*|vermieter\w*)\b)
    }ixu.freeze
    LANDLORD_TERMINATION_QUERY_PATTERN = %r{
      \b(?:landlord|verhuurder|huisbaas|bailleur|propri[ée]taire|vermieter)\b[^.!?;\n]{0,60}
      \b(?:terminate\w*|cancel\w*|end(?:s|ing)?|evict\w*|opzeg\w*|be[ëe]indig\w*|r[ée]sili\w*|expuls\w*|k[üu]ndig\w*)\b
      |
      \b(?:termination|opzegging|r[ée]siliation|k[üu]ndigung)\s+(?:by|door|par|durch)\s+(?:(?:the|de|le|den)\s+)?(?:landlord|verhuurder|bailleur|vermieter)\b
    }ixu.freeze
    RENTAL_DEPOSIT_ABSENCE_CLAUSE_PATTERN = %r{
      \bno\s+(?:rental\s+)?deposit\s+(?:(?:was|has\s+been)\s+)?(?:requested|asked\s+for|paid|provided)\b
      |\b(?:er\s+(?:is|werd)\s+)?geen\s+(?:huur)?waarborg\s+(?:(?:werd|is)\s+)?(?:gevraagd|betaald|gestort)\b
      |\baucune\s+garantie\s+locative\s+(?:n['’]a\s+[ée]t[ée]\s+)?(?:demand[ée]e|vers[ée]e)\b
      |\bkeine\s+mietkaution\s+(?:wurde\s+)?(?:verlangt|gezahlt|bezahlt)\b
    }ixu.freeze
    RENTAL_DEPOSIT_SUBJECT_PATTERN = /\b(?:deposit|huurwaarborg|waarborg|garantie\s+locative|mietkaution|kaution)\b/iu.freeze
    FLANDERS_PLANNING_NUMACS = Set.new(%w[2009A35738 2014036510 2010035645 2010035576]).freeze
    REGIONAL_PLANNING_SUBJECT_PATTERN = /\b(?:ruimtelijke\s+ordening|stedenbouw\w*|omgevingsvergunning|bouwvergunning|verkavelingsvergunning|planologisch\w*|aménagement\s+du\s+territoire|urbanisme|permis\s+(?:d['’])?(?:urbanisme|environnement)|spatial\s+planning|planning\s+permission|planning\s+permits?|building\s+permits?|environmental\s+permits?|raumordnung|baugenehmigung\w*|bauerlaubnis|umgebungsgenehmigung\w*|städtebau\w*)\b/i

    # Shared by pin eligibility, source scoping and regional-lane selection.
    # A browser pop-up is not a commercial lease; the joined Dutch term
    # "pop-uphuur" and explicit short-commercial-lease titles are.
    SHORT_COMMERCIAL_SUBJECT_PATTERN = %r{
      (?=
        .*\bpop[\s\p{Pd}]?ups?\b
      )
      (?=
        .*\b(?:huur|hur(?:en)?|winkel|handelszaak|handelshuur|zaak|locat\w*|bail|commerce|lease|rent(?:al)?|shop|miet\w*|geschäft\w*)\b
      )
      |
      \bpop[\s\p{Pd}]?up(?:huur|huurovereenkomst(?:en)?|leases?|miete(?:n)?)\b
      |
      \b(?:
        handelshuur\s+(?:van\s+)?korte\s+duur |
        huur\s+van\s+korte\s+duur\s+voor\s+handel |
        (?:bail\s+commercial|baux\s+commerciaux)\s+de\s+courte\s+dur[eé]e |
        short[\s-]term\s+commercial\s+(?:lease|rent(?:al)?) |
        commercial\s+(?:lease|rent(?:al)?)\s+(?:of\s+)?short\s+duration |
        kurz(?:zeitige[rsnm]?|fristige[rsnm]?|zeit)\s+(?:gewerbe(?:raum)?miete|gesch[aä]ftsmiete|gewerbliche[rsnm]?\s+miete)
      )\b
    }imxu.freeze

    # The applicability provision of each distinct regional short-commercial
    # lease regime. These are source candidates, not a choice of jurisdiction:
    # an unqualified overview receives all three labelled regimes, whereas a
    # named/comparative question receives only the jurisdictions it names.
    # Source text is fetched from Article; no legal wording is manufactured.
    REGIONAL_SHORT_COMMERCIAL_TARGETS = [
      %w[2016036108 2].freeze,
      %w[2018201406 1].freeze,
      %w[2019041090 2].freeze
    ].freeze
    REGIONAL_SHORT_COMMERCIAL_LABELS = {
      'nl' => { '2016036108' => 'Vlaanderen', '2018201406' => 'Wallonië', '2019041090' => 'Brussel' },
      'fr' => { '2016036108' => 'Flandre', '2018201406' => 'Wallonie', '2019041090' => 'Bruxelles' },
      'de' => { '2016036108' => 'Flandern', '2018201406' => 'Wallonien', '2019041090' => 'Brüssel' },
      'en' => { '2016036108' => 'Flanders', '2018201406' => 'Wallonia', '2019041090' => 'Brussels' }
    }.freeze

    # Verified provisions of the three residential lease regimes, per topic,
    # read in laws.prod on 2026-10-17 (in force, Dutch and French rows):
    #   rent increase  Flanders, Woninghuurdecreet art. 34 (Indexatie) and 35
    #                  (Herziening van de huurprijs); Brussels, Huisvestingscode
    #                  art. 224/2 (Indexering) and 240 (herziening); Wallonia,
    #                  woninghuurdecreet art. 57 (indexation of a main-residence
    #                  lease, under art. 26) and 58 (revision);
    #   deposit        art. 37 (Huurwaarborg), 248 and 62;
    #   termination    art. 20 (by the tenant) and 17 (by the landlord for own
    #                  use), 237 and 55, which cover both sides.
    # Owner rule (2026-10-17): an answer on a regional subject always mentions
    # all three regions. These are therefore never narrowed to a named region;
    # a named region's provisions only come first. Each topic lists one
    # provision per region before the second ones, so a five-source budget
    # keeps every region. Without them the regional-housing scope drops all
    # three statutes from every lane when no region is named: "Mag mijn
    # verhuurder de huurprijs verhogen?" (a suggested question) was answered
    # from social-housing rules on 2026-10-17 and refused three times by the
    # citation guard.
    REGIONAL_RENT_INCREASE_TARGETS = [
      %w[2018015087 34].freeze, %w[2013A31614 224/2].freeze, %w[2018201408 57].freeze,
      %w[2018015087 35].freeze, %w[2013A31614 240].freeze, %w[2018201408 58].freeze
    ].freeze
    REGIONAL_RENTAL_DEPOSIT_TARGETS = [
      %w[2018015087 37].freeze, %w[2013A31614 248].freeze, %w[2018201408 62].freeze
    ].freeze
    REGIONAL_RENTAL_TERMINATION_TARGETS = [
      %w[2018015087 20].freeze, %w[2013A31614 237].freeze, %w[2018201408 55].freeze,
      %w[2018015087 17].freeze
    ].freeze
    REGIONAL_HOUSING_LABELS = {
      'nl' => { '2018015087' => 'Vlaanderen', '2013A31614' => 'Brussel', '2018201408' => 'Wallonië' },
      'fr' => { '2018015087' => 'Flandre', '2013A31614' => 'Bruxelles', '2018201408' => 'Wallonie' },
      'de' => { '2018015087' => 'Flandern', '2013A31614' => 'Brüssel', '2018201408' => 'Wallonien' },
      'en' => { '2018015087' => 'Flanders', '2013A31614' => 'Brussels', '2018201408' => 'Wallonia' }
    }.freeze
    # A rent increase, indexation or revision, in the four site languages.
    RENT_INCREASE_PATTERN = %r{
      \b(?:
        huur(?:prijs)?(?:verhoging|indexatie|indexering|herziening|stijging)
        | (?:verhoging|indexatie|indexering|herziening|stijging|aanpassing)\s+van\s+(?:de\s+|mijn\s+|onze\s+|uw\s+)?huur(?:prijs)?\b
        | huur(?:prijs)?\b[^.!?\n]{0,40}\b(?:verho(?:gen|ogt|ogd|ogde)|indexe(?:ren|ert|erde)|geïndexeerd|herzien|optrekken|opgetrokken|stijgen|stijgt|aanpassen|aangepast)\b
        | (?:verho(?:gen|ogt|ogd)|indexe(?:ren|ert)|herzien|optrekken)\b[^.!?\n]{0,40}\bhuur(?:prijs)?\b
        | loyers?\b[^.!?\n]{0,40}\b(?:augment\w*|index\w*|révis\w*|revis\w*|hausse)
        | (?:augment\w*|index\w*|révis\w*|revis\w*|hausse)\b[^.!?\n]{0,40}\bloyers?\b
        | rent\b[^.!?\n]{0,40}\b(?:increase\w*|raise\w*|index\w*|review\w*)
        | (?:increas\w*|rais\w*|index\w*)\b[^.!?\n]{0,40}\brent\b
        | miete\w*\b[^.!?\n]{0,40}\b(?:erhöh\w*|index\w*)
        | (?:erhöh\w*|index\w*)\b[^.!?\n]{0,40}\bmiete\w*\b
      )
    }xi
    # Lease words; deposit and termination wording counts only beside one.
    RENTAL_CONTEXT_TERMS = '(?:huur\w*|verhuur\w*|huisbaas|loyer\w*|bail\w*|locat\w*|propriétaire|rent\w*|tenan\w*|landlord\w*|lease\w*|miet\w*|vermiet\w*)'
    RENTAL_LEASE_TERM_PATTERN = /\b#{RENTAL_CONTEXT_TERMS}\b/i
    RENTAL_DEPOSIT_TERM_PATTERN = /\b(?:huurwaarborg\w*|huurborg\w*|waarborg\w*|borgsom\w*|garanties?\s+locatives?|garantie|cautions?|deposits?|mietkaution\w*|kaution)\b/i
    # "zeg ... op" is the split form of opzeggen; "congé" is the French notice.
    RENTAL_TERMINATION_TERM_PATTERN = /\b(?:opzeg\w*|opgezegd\w*|vooropzeg\w*|zeg(?:t|de|den)?\s+(?:\S+\s+){0,6}?op(?=\s*(?:[.?!,;]|\z))|beëindig\w*|stopzetten|résili\w*|préavis|cong[ée]s?|mettre\s+fin|termin\w*|notice|kündig\w*)\b/i
    EMPLOYMENT_SUBJECT_PATTERN = /\b(?:werkgever\w*|werknemer\w*|arbeidsovereenkomst\w*|arbeidscontract\w*|ontslag\w*|ontslagen|tewerkstelling|employer\w*|employee\w*|employment|dismiss\w*|contrat\s+de\s+travail|employeur\w*|travailleur\w*|licenci\w*|arbeitgeber\w*|arbeitnehmer\w*|arbeitsvertrag\w*)\b/i
    # The employment contract or its ending, not the employer as a person: an
    # employer can be the actor or landlord of a named lease ("Kan mijn
    # werkgever mijn huurcontract opzeggen?", Codex review 18:21, 2026-10-17).
    EMPLOYMENT_CONTRACT_PATTERN = /\b(?:arbeidsovereenkomst\w*|arbeidscontract\w*|ontslag\w*|ontslagen|tewerkstelling|employment|dismiss\w*|contrat\s+de\s+travail|licenci\w*|arbeitsvertrag\w*|kündigung\s+des\s+arbeitsverhältnisses)\b/i
    # The rented object and the contract decide the regime, not a word anywhere
    # in the question (Codex review, 2026-10-17): a rented car, machine or
    # business premises received the residential provisions; an apartment
    # with a garage, "geen sociale woning" and a student on an ordinary
    # residential lease lost them; a tenancy mentioned beside an employment
    # dismissal received the lease termination rules.
    RENTAL_DWELLING_PATTERN = /\b(?:woning\w*|huurwoning\w*|woninghuur\w*|huis|huizen|appartement\w*|studio\w*|flat|woonst|hoofdverblijf\w*|kamer|dwelling\w*|house|home|apartment\w*|logement\w*|maison\w*|résidence|habitation\w*|wohnung\w*|haus|wohnraum\w*|zimmer)\b/i
    # Objects of another regime that a dwelling in the question overrides
    # (the garage that comes with an apartment).
    RENTAL_OTHER_OBJECT_PATTERN = /\b(?:auto|auto's|autos|wagen|wagens|voitures?|véhicules?|vehicles?|cars?|fahrzeug\w*|pkw|machine\w*|maschine\w*|materiaal|matériel|equipment|toestel\w*|garage\w*|parking\w*|parkeerplaats\w*|staanplaats\w*|loods\w*|hangar\w*|opslagruimte\w*|box)\b/i
    COMMERCIAL_LEASE_PATTERN = /\b(?:handelshuur\w*|handelspand\w*|bedrijfsruimte\w*|bedrijfspand\w*|bedrijfsgebouw\w*|kantoor|kantoren|kantoorruimte\w*|winkel(?:s|pand\w*|ruimte\w*)?|bail\s+(?:commercial|professionnel)|baux\s+commerciaux|locaux?\s+(?:commerciaux|commercial|professionnels?)|commercial\s+(?:lease|premises)|business\s+premises|office\s+(?:lease|space)|gewerbe\w*|geschäftsräum\w*|pop-?up\w*)\b/i
    AGRICULTURAL_LEASE_PATTERN = /\b(?:pacht\w*|landpacht|landbouw\w*|bail\s+à\s+ferme|fermage|baux\s+à\s+ferme|agricultural\s+(?:lease|tenancy)|landpacht|pachtvertrag\w*)\b/i
    SOCIAL_HOUSING_LEASE_PATTERN = /\b(?:sociale?\s+(?:huur)?woning\w*|sociale\s+huur\w*|sociaal\s+(?:wonen|huren|verhuurkantoor)|logements?\s+sociaux|logement\s+social|social\s+(?:housing|rent\w*)|sozialwohnung\w*)\b/i
    # "geen sociale woning", "niet-sociale woning", "non-social housing".
    SOCIAL_HOUSING_NEGATION_PATTERN = /\b(?:geen|niet|pas|not|no|non|kein\w*)(?:\s+(?:(?:een|in\s+een|de|d['’]un|un|a|in\s+a|in)\s+)?|-)\z/i
    # A building named only as where the rented object is, not as the rented
    # object: "mijn appartement boven een winkel" rents the apartment.
    LOCATION_PREFIX_PATTERN = /\b(?:boven|onder|naast|achter|tegenover|nabij|above|below|over|under|next\s+to|beside|behind|opposite|near|au[-\s]dessus|en[-\s]dessous|à\s+côté|derrière|en\s+face|près|über|unter|neben|hinter|gegenüber)\s+(?:(?:d['’]|de|du|des|een|het|a|an|the|un|une|le|la|les|l['’]|einem|einer|dem|der|den)\s*)?(?:\p{L}+\s+)?\z/i
    # A clause ends at sentence punctuation, a colon or semicolon, or a
    # contrast: "Ik huur een appartement, maar mijn vraag gaat over mijn
    # arbeidscontract: wat is mijn opzegtermijn?" asks about the employment.
    RENTAL_CLAUSE_BOUNDARY_PATTERN = /(?<=[.!?;:])\s+|\n+|,?\s+\b(?:maar|echter|doch|but|however|whereas|mais|cependant|toutefois|aber|jedoch)\b/i
    STUDENT_LEASE_PATTERN = /\b(?:studentenhuur\w*|studentenkamer\w*|studentenwoning\w*|studentenhuis\w*|kot|koten|kotbaas|bail\s+(?:d['’])?étudiant|logement\s+étudiant|chambre\s+d['’]étudiant|student\s+(?:room|housing|lease|accommodation)|studentenwohn\w*|studentenzimmer\w*)\b/i
    ORDINARY_RESIDENTIAL_LEASE_PATTERN = /\b(?:gewone\s+(?:woning)?huurovereenkomst|woninghuurovereenkomst|hoofdverblijf\w*|bail\s+(?:de\s+résidence\s+principale|d['’]habitation|ordinaire)|résidence\s+principale|ordinary\s+(?:residential\s+)?(?:lease|tenancy)|main\s+residence|hauptwohnsitz)\b/i
    REGIONAL_HOUSING_TOPIC_TARGETS = [
      [:rent_increase, REGIONAL_RENT_INCREASE_TARGETS].freeze,
      [:deposit, REGIONAL_RENTAL_DEPOSIT_TARGETS].freeze,
      [:termination, REGIONAL_RENTAL_TERMINATION_TARGETS].freeze
    ].freeze

    # :residential, :social, :student, :commercial, :agricultural or
    # :other_object: the regime of the lease a question is about.
    def self.rental_regime(question)
      text = question.to_s.gsub(/[[:space:]]+/, ' ')
      return :social if social_housing_lease?(text)
      return :student if text.match?(STUDENT_LEASE_PATTERN) && !text.match?(ORDINARY_RESIDENTIAL_LEASE_PATTERN)
      return :agricultural if text.match?(AGRICULTURAL_LEASE_PATTERN)
      return :commercial if rented_object?(text, COMMERCIAL_LEASE_PATTERN)
      return :residential if text.match?(RENTAL_DWELLING_PATTERN)
      return :other_object if rented_object?(text, RENTAL_OTHER_OBJECT_PATTERN)

      :residential
    end

    def self.rented_object?(text, pattern)
      text.to_enum(:scan, pattern).any? { !Regexp.last_match.pre_match.last(40).match?(LOCATION_PREFIX_PATTERN) }
    end

    # Social housing the question asserts, not one it denies ("geen sociale woning").
    def self.social_housing_lease?(text)
      text.to_enum(:scan, SOCIAL_HOUSING_LEASE_PATTERN).any? do
        !Regexp.last_match.pre_match.last(24).match?(SOCIAL_HOUSING_NEGATION_PATTERN)
      end
    end

    def self.rent_increase_question?(question)
      question.to_s.match?(RENT_INCREASE_PATTERN)
    end

    def self.rental_deposit_question?(question)
      rental_topic?(question, RENTAL_DEPOSIT_TERM_PATTERN)
    end

    def self.rental_termination_question?(question)
      rental_topic?(question, RENTAL_TERMINATION_TERM_PATTERN)
    end

    # The topic word beside a lease word in one clause; across clauses only
    # when no employment subject could own the word instead.
    def self.rental_topic?(question, term_pattern)
      text = question.to_s
      clauses = text.split(RENTAL_CLAUSE_BOUNDARY_PATTERN)
      return true if clauses.any? { |clause| lease_owned_topic?(clause, term_pattern) }

      text.match?(term_pattern) && text.match?(RENTAL_LEASE_TERM_PATTERN) && !text.match?(EMPLOYMENT_SUBJECT_PATTERN)
    end

    # Within one clause the topic word belongs to the lease only when its own
    # phrase names the lease: "Ik huur een appartement en mijn werkgever zegt
    # mijn arbeidsovereenkomst op" is the employer ending the employment
    # contract (Codex review 16:53, 2026-10-17). Without an employment subject
    # in the clause, a lease word anywhere in it still owns the topic.
    RENTAL_PHRASE_BOUNDARY_PATTERN = /,|\s+(?:en|and|et|und|maar|but|mais|aber)\s+/i
    def self.lease_owned_topic?(clause, term_pattern)
      return false unless clause.match?(term_pattern) && clause.match?(RENTAL_LEASE_TERM_PATTERN)
      return true unless clause.match?(EMPLOYMENT_SUBJECT_PATTERN)

      clause.split(RENTAL_PHRASE_BOUNDARY_PATTERN).any? do |phrase|
        phrase.match?(term_pattern) && phrase.match?(RENTAL_LEASE_TERM_PATTERN) && !phrase.match?(EMPLOYMENT_CONTRACT_PATTERN)
      end
    end

    def self.housing_topic?(question, kind)
      case kind
      when :rent_increase then rent_increase_question?(question)
      when :deposit then rental_deposit_question?(question)
      when :termination then rental_termination_question?(question)
      end
    end

    LEGACY_CRIMINAL_CODE_NUMAC = '1867060850'
    CURRENT_CRIMINAL_CODE_NUMACS = Set.new(%w[2024002052 2024002088]).freeze
    LEGACY_CRIMINAL_CODE_NAME_PATTERN = /\b(?:oud\s+strafwetboek|strafwetboek\s+van\s+1867|ancien\s+code\s+pénal|old\s+criminal\s+code|altes\s+strafgesetzbuch)\b/i
    CRIMINAL_OFFENCE_PATTERN = /\b(?:feiten?|misdrijf|strafbaar\s+feit|diefstal|stelen|belaging|inbraak|oplichting|fraude|moord|doodslag|verkrachting|mishandeling|drugs?(?:bezit)?|vol|harcèlement|infraction|cambriolage|escroquerie|fraude|meurtre|homicide|viol|agression|stupéfiants?|drogue|theft|offen[cs]e|burglary|robbery|fraud|murder|homicide|rape|assault|drugs?|diebstahl|straftat|einbruch|raub|betrug|mord|totschlag|vergewaltigung|körperverletzung|drogen)\b/i
    CRIMINAL_EVENT_PATTERN = %r{
      \b(?:
        vond\s+plaats|gebeurde|dateert|(?:werd|is|heb|heeft|hebben)?\s*gepleegd|begaan|
        (?:a|ont)\s+été\s+commis(?:e|es)?|commis(?:e|es)?|a\s+eu\s+lieu|dat(?:e|ent)|
        was\s+committed|committed|happened|occurred|took\s+place|
        wurde\s+begangen|begangen|ereignete\s+sich|fand\s+statt
      )\b
    }ix
    LEGACY_CRIMINAL_DATE_PATTERN = %r{
      (?:
        (?:19\d{2}|20(?:0\d|1\d|2[0-5]))(?!\d)(?!\s*(?:€|eur(?:o)?s?\b|dollars?\b|usd\b|gbp\b))|
        2026[-/.]0?[1-3][-/.](?:0?[1-9]|[12]\d|3[01])(?!\d)|
        2026[-/.]0?4[-/.]0?[1-7](?!\d)|
        (?:0?[1-9]|[12]\d|3[01])[-/.]0?[1-3][-/.]2026(?!\d)|
        0?[1-7][-/.]0?4[-/.]2026(?!\d)|
        (?:(?:[1-9]|[12]\d|3[01])(?:st|nd|rd|th|er|e|\.)?\s+)?
          (?:januari|janvier|january|januar|februari|février|fevrier|february|februar|maart|mars|march|märz|maerz)\s+2026|
        [1-7](?:st|nd|rd|th|er|e|\.)?\s+(?:april|avril)\s+2026|
        (?:january|february|march)\s+(?:[1-9]|[12]\d|3[01])(?:st|nd|rd|th)?,?\s+2026|
        april\s+[1-7](?:st|nd|rd|th)?,?\s+2026
      )
    }ix
    PRE_CUTOVER_CRIMINAL_REFERENCE_PATTERN = %r{
      (?:
        (?:de\s+|le\s+|dem\s+|the\s+)?(?:8(?:th|e|er|\.)?\s+(?:april|avril)\s+2026|april\s+8(?:th)?,?\s+2026|0?8[-/.]0?4[-/.]2026|2026[-/.]0?4[-/.]0?8)|
        (?:de\s+|du\s+|the\s+|des\s+)?(?:inwerkingtreding|entrée\s+en\s+vigueur|entry\s+into\s+force|inkrafttreten)\s+(?:van\s+|du\s+|of\s+|des\s+)?(?:het\s+|le\s+|the\s+|des\s+)?(?:nieuwe?\s+|nouveau\s+|new\s+|neuen?\s+)?(?:strafwetboek|code\s+pénal|criminal\s+code|strafgesetzbuch)
      )
    }ix
    LEGACY_CRIMINAL_FACT_PATTERN = %r{
      (?:
        #{CRIMINAL_OFFENCE_PATTERN.source}\s+(?:op|in|uit|van|on|from|im|am|aus|le|en|de)\s+#{LEGACY_CRIMINAL_DATE_PATTERN.source}|
        #{CRIMINAL_OFFENCE_PATTERN.source}.{0,30}(?:vóór|voor|avant|before|vor)\s+#{PRE_CUTOVER_CRIMINAL_REFERENCE_PATTERN.source}|
        #{CRIMINAL_OFFENCE_PATTERN.source}.{0,80}#{CRIMINAL_EVENT_PATTERN.source}.{0,30}#{LEGACY_CRIMINAL_DATE_PATTERN.source}|
        #{CRIMINAL_OFFENCE_PATTERN.source}.{0,80}#{LEGACY_CRIMINAL_DATE_PATTERN.source}.{0,30}#{CRIMINAL_EVENT_PATTERN.source}|
        #{LEGACY_CRIMINAL_DATE_PATTERN.source}.{0,40}#{CRIMINAL_EVENT_PATTERN.source}.{0,40}#{CRIMINAL_OFFENCE_PATTERN.source}
      )
    }ix
    HISTORICAL_THEFT_PATTERN = %r{\A(?=.*#{LEGACY_CRIMINAL_FACT_PATTERN.source})(?=.*\b(?:diefstal|stelen|gestolen|vol|theft|diebstahl)\b).*\z}ix
    HISTORICAL_STALKING_PATTERN = %r{\A(?=.*#{LEGACY_CRIMINAL_FACT_PATTERN.source})(?=.*\b(?:belaging|belagen|belaagd|harcèlement|stalking)\b).*\z}ix

    def initialize(embedding_service:, language: 'nl', context_numacs: [], profile: 'general')
      @language = language
      @language_id = %w[fr de].include?(language) ? 2 : 1
      @embedding_service = embedding_service
      @context_numacs = context_numacs
      @profile = profile
    end

    # nil after a search whose semantic leg answered (or was disabled by env),
    # 'semantic_unavailable' when the FAISS service did not answer and the
    # lexical routes carried the search alone. The fan-out reads it in the
    # worker thread right after #search returns.
    attr_reader :retrieval_degradation

    # ------------------------------------------------------------------
    # PUBLIC API
    # ------------------------------------------------------------------

    # Find similar legislation articles via FAISS, lexical FTS supplementation,
    # and core-law boosting. Keeping the hybrid retrieval here (rather than in
    # an orchestrator-only post-step) means FTS can rescue a FAISS zero-hit.
    # Returns array of article hashes with metadata.
    #
    # german_pointers: the rows the German lane resolved from German hits
    # (GermanArticleSearch#search, gesetzguide only, pointers and wording
    # modes): French rows, plus binding German originals with
    # GERMAN_ORIGINALS_MODE=on. nil or [] leaves this method exactly as it was.
    def search(question_embedding, limit: 12, question: nil, german_pointers: nil, keyword_limit: 5, keyword_passes: 1, keyword_quota: 3)
      # Reset first: one service instance can serve more than one ask.
      @retrieval_degradation = nil
      @telemarketing_scope_resolver = nil

      # Main semantic hits must come from a manifest-bound loaded generation
      # and survive the post-generation public article change ledger. Old
      # unbound services fail closed; lexical/pinned routes remain available.
      top_articles = if legislation_faiss_enabled?
                       # nil means the service did not answer, [] means it
                       # answered with nothing; only the first is degraded.
                       # On 2026-09-20 the 10 s read ran out on a cold mmap,
                       # the keyword search below filled in (15 FTS hits on
                       # the word "kleding", three of which reached the
                       # model) and the search still read as 'completed' to
                       # everything downstream. Disabled by env is a
                       # configuration, not a failure, so that branch never
                       # sets it.
                       semantic = search_faiss(question_embedding, limit * 3)
                       @retrieval_degradation = 'semantic_unavailable' if semantic.nil?
                       semantic || []
                     else
                       Rails.logger.info(
                         "[Search] Main legislation FAISS disabled by #{FAISS_ENABLED_ENV}; " \
                         'using verified lexical and pinned routes'
                       )
                       []
                     end

      # Merge semantic and lexical candidates before applying any legal or
      # regional scope. Otherwise a lexical hit added after scoping can
      # reintroduce a repealed code or a law from the wrong region.
      if question.present?
        # The lexical supplement covers the vocabulary gap where a user's word
        # differs from the statute's wording. Preserve a small BM25-ranked
        # lexical quota so a high-volume semantic result set cannot crowd it
        # out before title filtering.
        lexical_limit = (Integer(keyword_limit, exception: false) || 5).clamp(1, 12)
        lexical_quota = (Integer(keyword_quota, exception: false) || 3).clamp(1, 12)
        passes = (Integer(keyword_passes, exception: false) || 1).clamp(1, 3)
        keywords = extract_keywords(question)
        variants = research_keyword_variants(question, keywords, passes: passes)
        batches = variants.map { |variant| find_by_keywords(variant, limit: lexical_limit) }
        # Interleave ranked local-query batches so the primary query cannot
        # consume every lexical slot. No generated/reworded question, extra
        # embedding or paid provider call is needed for these variants.
        keyword_articles = (0...batches.map(&:length).max.to_i).flat_map do |rank|
          batches.filter_map { |batch| batch[rank] }
        end.uniq { |article| article[:id] }
        if keyword_articles.any?
          top_articles = merge_search_results(top_articles, keyword_articles, limit: limit * 3, lexical_quota: lexical_quota)
        end
      end

      # German pointers (and binding German originals) join here, after the
      # lexical merge and BEFORE the core-law boosting, so they take the same
      # scoping, penalties (is_modification x0.5, abolished x0.3), pins,
      # future-law cut and final quota as every other row.
      top_articles = merge_german_pointers(top_articles, german_pointers) if german_pointers.present?

      top_articles = apply_core_law_boosting(top_articles, question, profile: @profile) if question.present?

      # "Pop-uphuur" has no literal equivalent in these statutes' titles.
      # Semantic top hits can consequently contain only generic regional
      # neighbours. Preserve the three exact, labelled applicability sources
      # (or the named subset) through the downstream low-tier source budget.
      # Normal candidate scores deliberately do not pretend a generic
      # overview selected the existing Flemish-only 99.0 article pins.
      if question.present?
        regional_candidates = regional_short_commercial_candidates(question) +
                              regional_housing_topic_candidates(question)
        if regional_candidates.any?
          candidate_ids = regional_candidates.to_set { |article| article[:id] }
          top_articles = regional_candidates + top_articles.reject { |article| candidate_ids.include?(article[:id]) }
        end
      end

      # Article-level pins: for well-known concepts whose governing article the
      # semantic search misses on VOCABULARY MISMATCH (user says "belaging",
      # the statute says "belaagd"; "verjaring" vs "rechtsvorderingen verjaren";
      # "beslagvrije som" vs "voor beslag vatbaar"), force the exact governing
      # article to the top. Core-law boosting is only numac-level, so it
      # surfaces a code's Art.1/headings, never the specific article.
      if question.present?
        pins = pinned_articles(question).uniq { |article| article[:id] }
        if pins.any?
          # A pin is a ranking instruction, not merely an injection fallback.
          # Promote it even when FAISS already found the same article lower in
          # the result list, while retaining exactly one copy of every result.
          pinned_ids = pins.to_set { |article| article[:id] }
          top_articles = pins + top_articles.reject { |article| pinned_ids.include?(article[:id]) }
        end
      end

      # Return top N without allowing the final ranking cut to undo the
      # vocabulary-rescue quota established by the hybrid merge.
      # Sanitize INSIDE the quota call, so rows dropped for being future law are backfilled
      # and the caller still receives `limit` articles that are actually in force.
      retain_final_search_quota(sanitize_future_law(top_articles), limit: limit)
    end

    # Private hospitalisation insurance is governed by the Insurance Act, not
    # by the statutory sickness-insurance regime. These deliberately require a
    # product-specific phrase: the retrieved provisions and policy terms must
    # still establish the concrete duration, premium, eligibility, or waiting
    # rule for the user's contract.
    HOSPITALISATION_POLICY_PATTERN = /\b(?:hospitalisatieverzekering(?:en)?|hospitalisatiepolis(?:sen)?|assurance\s+(?:d[’']hospitalisation|hospitalisation|hospitalière)|hospital(?:i[sz]ation)?\s+insurance|krankenhauszusatzversicherung)\b/i
    HOSPITALISATION_WAITING_PATTERN = /\A(?=.*\b(?:hospitalisatieverzekering(?:en)?|hospitalisatiepolis(?:sen)?|assurance\s+(?:d[’']hospitalisation|hospitalisation|hospitalière)|hospital(?:i[sz]ation)?\s+insurance|krankenhauszusatzversicherung)\b)(?=.*\b(?:wachttijd|wachtperiode|stageperiode|délai\s+de\s+carence|période\s+d[’']attente|waiting\s+period|wartezeit)\b).*\z/im
    HOSPITALISATION_DURATION_PATTERN = /\A(?=.*\b(?:hospitalisatieverzekering(?:en)?|hospitalisatiepolis(?:sen)?|assurance\s+(?:d[’']hospitalisation|hospitalisation|hospitalière)|hospital(?:i[sz]ation)?\s+insurance|krankenhauszusatzversicherung)\b)(?=.*\b(?:levenslang\w*|looptijd|duur|voortzetting|continu[iï]teit|opzeg\w*|be[eë]indig\w*|délai|durée|à\s+vie|résili\w*|cessation|lifetime|duration|terminat\w*|lebenslang\w*|laufzeit|kündig\w*)\b).*\z/im

    # Concept -> governing article, when FAISS reliably misses it. Keep this
    # LIST tight and high-confidence: a wrong pin poisons an answer. Format:
    # [question-regex, numac, article-number]. Seeded 2026-07-15 from the
    # hands-on retrieval diagnosis; expandable from the full-corpus audit.
    DRUG_OFFENCE_PATTERN = %r{
      \b(?:
        drugs?bezit|drugshandel|
        bezit\s+(?:van\s+)?(?:drugs?|verdovende\s+middelen|cannabis|cocaïne|heroïne)|
        handel\s+(?:in|van)\s+(?:drugs?|verdovende\s+middelen)|
        (?:détention|possession|trafic|commerce)\s+(?:de|des)\s+(?:drogues?|stupéfiants?|cannabis|cocaïne|héroïne)|
        drug\s+possession|possession\s+of\s+(?:(?:small|limited)\s+amounts?\s+of\s+)?(?:drugs?|narcotics|cannabis|cocaine|heroin)|drug\s+trafficking|trafficking\s+in\s+(?:drugs?|narcotics)|
        drogenbesitz|drogenhandel|besitz\s+von\s+(?:drogen|betäubungsmitteln?|cannabis|kokain|heroin)|handel\s+mit\s+(?:drogen|betäubungsmitteln?)
      )\b
    }ix.freeze
    CANNABIS_OR_POSSESSION_PATTERN = %r{
      \A(?!.*\b(?:cocaïne|cocaine|heroïne|héroïne|heroin|kokain)\b).*\b(?:
        drugs?bezit|bezit\s+(?:van\s+)?(?:drugs?|verdovende\s+middelen|cannabis)|cannabisbezit|
        (?:détention|possession)\s+(?:de|des)\s+(?:drogues?|stupéfiants?|cannabis)|
        drug\s+possession|possession\s+of\s+(?:(?:small|limited)\s+amounts?\s+of\s+)?(?:drugs?|narcotics|cannabis)|cannabis\s+possession|
        drogenbesitz|besitz\s+von\s+(?:drogen|betäubungsmitteln?|cannabis)
      )\b.*\z
    }ix.freeze
    MAJORITY_AGE_PATTERN = /
      (?=.*\b(?:meerderjarig(?:heid)?|majorité|majeur(?:e)?|age\s+of\s+majority|legally\s+adult|volljährig\w*)\b)
      (?=.*\b(?:leeftijd|jaar|vanaf|wanneer|âge|ans|quel\s+âge|age|years?|when|alter|jahre|wann|18|achttien|dix-huit|achtzehn)\b)
    /ix
    TESTAMENT_FORM_PATTERN = /
      \A
      (?!.*\b(?:aanvecht\w*|betwist\w*|bedrog|dwang|wilsgebrek|wilsbekwaam\w*|onbekwaam\w*|
                 herroep\w*|intrek\w*|révoqu\w*|contest\w*|fraude?|dol|capacité|incapacité|
                 revoc\w*|revok\w*|challeng\w*|fraud|capacity|undue\s+influence|
                 widerruf\w*|anfecht\w*|betrug|testierfähigkeit)\b)
      (?=.*\b(?:testament(?:en|s)?|last\s+will|(?:handwritten|notarial|international)\s+will)\b)
      (?=.*\b(?:geldig(?:heid)?|vorm(?:en)?|voorwaard(?:e|en)|eigenhandig|notarieel|internationaal|
                    valide?|validité|forme|conditions?|olographe|notarié|international|requis|
                    valid(?:ity)?|forms?|requirements?|required|necessary|handwritten|notarial|
                    gültig(?:keit)?|formen?|voraussetzungen?|eigenhändig|handschriftlich\w*|notariell|
                    erforderlich|notwendig)\b)
      .*\z
    /ix
    EMPLOYMENT_NON_COMPETE_PATTERN = /
      (?:
        \b(?:niet[-\s]?)?concurrentiebeding(?:en)?\b|\bnon[-\s]?concurrence\b
      ).{0,80}\b(?:
        arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|ontslag|tewerkstelling|
        contrat\s+de\s+travail|travailleur|employeur|licenciement
      )\b
      |
      \b(?:
        arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|ontslag|tewerkstelling|
        contrat\s+de\s+travail|travailleur|employeur|licenciement
      )\b.{0,80}(?:
        \b(?:niet[-\s]?)?concurrentiebeding(?:en)?\b|\bnon[-\s]?concurrence\b
      )
    /ix
    # Art. 20 of the Act of 7 October 2022 (NUMAC 2022206298) governs
    # parallel employment. Users frequently describe the exclusivity clause
    # without saying "concurrentiebeding", so require both employment context
    # and a functional side-work/exclusivity cue before pinning it.
    PARALLEL_EMPLOYMENT_PATTERN = %r{
      \A
      (?=.*\b(?:werknemer|werkgever|arbeidsovereenkomst|arbeidscontract|tewerkstelling|employee|employer|employment\s+contract|travailleur|employeur|contrat\s+de\s+travail|arbeitnehmer|arbeitgeber|arbeitsvertrag)\b)
      (?:(?=.*\b(?:nevenactiviteit(?:en)?|bijberoep|exclusiviteitsbeding|parallelle?\s+arbeid|andere\s+werkgever|meerdere\s+werkgevers|side\s+job|secondary\s+employment|other\s+employer|another\s+employer|parallel\s+employment|activit[eé](?:\s+professionnelle)?\s+(?:parall[eè]le|accessoire)|autre\s+employeur|Nebenbesch[aä]ftigung|Nebent[aä]tigkeit|parallele\s+Besch[aä]ftigung|andere[rn]?\s+Arbeitgeber)\b)
        |(?=.*\b(?:eigen\s+rekening|rekening\s+van\s+derden|own\s+account|third\s+part(?:y|ies)|compte\s+propre|compte\s+de\s+tiers|eigene\s+Rechnung|Rechnung\s+von\s+Dritten)\b)(?=.*\b(?:werk\w*|werken|beroepsactiviteit|activiteit|work\w*|professional\s+activity|activity|travail\w*|activit[eé]|arbeiten|T[aä]tigkeit)\b)
        |(?=.*\b(?:gehele\s+beroepsactiviteit|entire\s+professional\s+activity|activit[eé]\s+professionnelle\s+enti[eè]re|gesamte\s+berufliche\s+T[aä]tigkeit)\b)(?=.*\b(?:wijden|uitsluitend|exclusief|devote|exclusive|dedicate|consacrer|exclusif|widmen|ausschlie[sß]lich)\b)
        |(?=.*\b(?:schriftelijk\s+akkoord|prior\s+written\s+(?:consent|approval)|accord\s+[ée]crit\s+pr[eé]alable|schriftliche\s+Zustimmung)\b)(?=.*\b(?:nevenactiviteit(?:en)?|bijberoep|andere\s+werkgever|parallelle?\s+arbeid|other\s+employer|another\s+employer|side\s+job|secondary\s+employment|parallel\s+employment|activit[eé](?:\s+professionnelle)?\s+(?:parall[eè]le|accessoire)|autre\s+employeur|Nebenbesch[aä]ftigung|Nebent[aä]tigkeit|parallele\s+Besch[aä]ftigung)\b))
      .*
    \z
    }ixm.freeze
    # These observed specialist cards do not govern ordinary contractual
    # exclusivity. Preserve actual cross-border/notarial questions, and the
    # explicit/viewed/pinned bypass at the shared relevance boundary.
    PARALLEL_EMPLOYMENT_SPECIALIST_SOURCE_GATES = [
      [%w[1977040406],
       /\b(?:sociale\s+zekerheid|s[ée]curit[ée]\s+sociale|social\s+security|Sozialversicherung)\b.{0,160}\b(?:Oostenrijk|Autriche|Austria|[ÖO]sterreich)\b/iu,
       /\b(?:Oostenrijk|Autriche|Austria|[ÖO]sterreich|Wenen|Vienne|Vienna|Wien)\b/iu],
      [%w[2005A09766],
       /\b(?:deontolog\p{L}*|professional\s+conduct|Berufsordnung)\b.{0,160}\b(?:notari\p{L}*|notar\p{L}*|notaire\p{L}*)\b/iu,
       /\b(?:notari\p{L}*|notar\p{L}*|notaire\p{L}*)\b/iu],
      [%w[1998016303 1998016201], /\A(?!)\z/,
       /\b(?:bedrijfsbeheer|beroepsbekwaam\p{L}*|vestigingswet\p{L}*|ondernemingsloket|inschrijv\p{L}*|registrat\p{L}*|vergunn\p{L}*|business\s+registration|professional\s+qualification\p{L}*|business\s+licen[cs]\p{L}*|inscription\p{L}*|immatricul\p{L}*|capacit[ée]\s+professionnelle|gestion\s+de\s+base|autorisation\p{L}*|Gewerbeanmeld\p{L}*|Berufszulass\p{L}*|Betriebsf[üu]hrung|Zulassung)\b/iu]
    ].map(&:freeze).freeze
    # A first-job offer/contract review is a bounded employment-law signal;
    # generic contract or compensation questions must not activate it alone.
    EMPLOYMENT_OFFER_REVIEW_PATTERN = %r{
      \A
      (?=.*\b(?:first\s+full[-\s]?time\s+job|full[-\s]?time\s+job\s+offer|job\s+offer|employment\s+offer|employment\s+contract|offer\s+letter|arbeidsovereenkomst|arbeidscontract|contrat\s+de\s+travail|arbeitsvertrag)\b)
      (?=.*\b(?:review|analyse|check|terms?|package|compensation|salary|wage|benefits?|voorwaarden|verloning|bezoldiging|r[eé]mun[eé]ration|conditions|Gehalt|Verg[uü]tung)\b)
      .*
      \z
    }ixm.freeze
    USED_GOODS_WARRANTY_PATTERN = /
      \A
      (?=.*\b(?:tweedehands(?:e)?|2dehands?|2e[-\s]?hands?|occasie(?:wagen)?|d[’']occasion|seconde?\s+main|used|second[-\s]?hand|gebraucht\w*)\b)
      (?:(?=.*\b(?:aankoop|koop|kopen|gekocht|vente|achat|acheter|purchase|buy|bought|kauf|gekauft)\b)|(?=.*\b(?:voertuig|auto|wagen|vehicle|car|fahrzeug)\b)(?=.*\b(?:handelaar|dealer|vendeur|concessionnaire|seller|Händler)\b))
      (?=.*\b(?:garantie|conformiteit|conformité|warranty|gewährleistung)\b)
      .*\z
    /ixm
    # A product warranty is not a bank guarantee, a tenancy deposit, health
    # insurance or a construction warranty. Match the transaction and the
    # movable good, not a bare word such as "garantie" or "repair".
    CONSUMER_GOODS_DISPUTE_PATTERN = %r{
      \A
      (?=.*\b(?:fiets|fietsen|auto|wagen|voertuig|versnellingsbak|koppeling|toestel|laptop|telefoon|product|goederen|schoen\w*|sneaker\w*|zool\w*|vélo|bicyclette|voiture|véhicule|embrayage|boîte\s+de\s+vitesses|appareil|ordinateur|téléphone|produit|chaussure\w*|basket\w*|semelle\w*|bike|bicycle|car|vehicle|gearbox|clutch|appliance|phone|goods|shoe\w*|sneaker\w*|trainer\w*|sole\w*|Fahrrad|Auto|Fahrzeug|Kupplung|Getriebe|Gerät|Telefon|Produkt|Schuh\w*|Turnschuh\w*|Sohle\w*)\b)
      (?=.*\b(?:koop|kopen|gekocht|aankoop|koper|handelaar|winkel|verkoper|achat|acheter|acheté|acheteur|vendeur|magasin|concessionnaire|buy|bought|purchase|buyer|seller|shop|dealer|retailer|kauf|gekauft|käufer|händler|verkäufer|geschäft|werkstatt)\b)
      (?=.*\b(?:garantie|conformiteit|gebrek|defect|schade|beschadigd|kras|herstell\w*|reparatie|loskom\w*|loslaat|losgelat\w*|slijt\w*|conformité|défaut|endommag\p{L}*|dégât\w*|rayure|répar\w*|se\s+détach\w*|usure\w*|warrant\w*|guarantee|damage\w*|scratch\w*|repair\w*|coming\s+loose|wear\w*|Gewährleistung|Mangel|Mängel|Schaden|beschädigt\w*|Kratzer|Reparatur|löst\s+sich|Verschleiß)\b)
      (?!.*\b(?:bouwgarantie|nieuwbouw|aannemer|architect|garantie\s+décennale|construction\s+warranty|Baugarantie)\b)
      (?!.*\b(?:bankgarantie|financiële\s+garantie|garantie\s+financière|financial\s+guarantee|Bankgarantie)\b)
      .*\z
    }imxu.freeze
    CONSUMER_GOODS_WARRANTY_PATTERN = %r{
      \A(?=#{CONSUMER_GOODS_DISPUTE_PATTERN.source})
      (?=.*\b(?:garantie|conformiteit|conformité|warrant\w*|guarantee|Gewährleistung)\b)
      .*\z
    }imxu.freeze
    # New damage while a professional has a movable good for repair is a
    # performance/liability question, even if the original repair is covered
    # by a sales warranty. Do not conflate that damage with a delivery defect.
    REPAIR_NEW_DAMAGE_RELATION_PATTERN = %r{
      \b(?:tijdens|gedurende|pendant|durant|during|während|bei)\b[^.!?;]{0,45}\b(?:herstell\w*|reparatie|répar\w*|repair\w*|Reparatur)\b
      |
      \b(?:na|après|after|nach)\b[^.!?;]{0,35}\b(?:herstell\w*|reparatie|répar\w*|repair\w*|Reparatur)\b[^.!?;]{0,100}\b(?:schade|beschadigd\w*|kras\w*|endommag\p{L}*|rayure\w*|damage\w*|scratch\w*|Schaden|beschädigt\w*|Kratzer)\b
      |
      \b(?:ophalen|afhalen|terugkreeg|pick\s+(?:it|the\s+\w+)\s+up|picked\s+up|collect\w*|récupér\w*|abhol\w*)\b[^.!?;]{0,120}\b(?:schade|beschadigd\w*|kras\w*|endommag\p{L}*|rayure\w*|damage\w*|scratch\w*|Schaden|beschädigt\w*|Kratzer)\b
      |
      \b(?:winkel|handelaar|hersteller|garage|magasin|réparateur|shop|technician|repairer|Werkstatt)\b[^.!?;]{0,40}\b(?:beschadigd|bekrast|rayé|endommagé|damaged|scratched|beschädigt|zerkratzt)\b
    }ixu.freeze
    PERSONAL_REPAIR_PATTERN = /\b(?:eigen|zelf|my\s+own|DIY|ma\s+propre|moi-même|meiner\s+eigenen|eigene)\b[^.!?;]{0,30}\b(?:herstell\w*|reparatie|répar\w*|repair\w*|Reparatur)\b/i.freeze
    # Book 5 does not automatically govern a repair performed before 2023.
    # Bind an old date to the repair/damage event, in either prose order.
    # A purchase date or a later dated event between them breaks that link:
    # "bought in 2022, damaged during a repair in 2026" is not a 2022 repair.
    REPAIR_DATE_SEPARATING_CONTEXT_PATTERN = /\b(?:koop\w*|kocht\w*|gekocht\w*|aankoop\w*|achat\w*|achet\w*|buy\w*|bought|purchas\w*|kauf\w*|gekauft\w*|20(?:2[3-9]|[3-9]\d))\b/i.freeze
    HISTORICAL_PROFESSIONAL_REPAIR_PATTERN = %r{
      \b(?:repair\w*|herstell\w*|reparatie|répar\w*|Reparatur|repariert\w*|beschadig\w*|bekrast|endommag\p{L}*|rayé\w*|damaged|scratched|beschädigt\w*|zerkratzt\w*)\b
      (?:(?!#{REPAIR_DATE_SEPARATING_CONTEXT_PATTERN.source})[^.!?;\n]){0,35}
      \b(?:in|en|im|tijdens|pendant|during|während)\s+(?:(?:het\s+jaar|the\s+year|l['’]ann[ée]e|Jahr)\s+)?(?:19\d{2}|20[01]\d|202[0-2])\b
      |
      (?:
        \b(?:in|en|im|tijdens|pendant|during|während)\s+(?:(?:het\s+jaar|the\s+year|l['’]ann[ée]e|Jahr)\s+)?(?:19\d{2}|20[01]\d|202[0-2])\b
        |
        (?:\A|[.!?;\n])\s*(?:19\d{2}|20[01]\d|202[0-2])\b
      )
      (?:(?!#{REPAIR_DATE_SEPARATING_CONTEXT_PATTERN.source})[^.!?;\n]){0,110}
      \b(?:repaired|hersteld|gerepareerd|réparé\w*|repariert\w*|beschadig\w*|bekrast|endommag\p{L}*|rayé\w*|damaged|scratched|beschädigt\w*|zerkratzt\w*)\b
    }ixu.freeze
    PROFESSIONAL_REPAIR_DAMAGE_PATTERN = %r{
      \A(?=#{CONSUMER_GOODS_DISPUTE_PATTERN.source})
      (?=.*\b(?:winkel|handelaar|verkoper|hersteller|garage|magasin|vendeur|réparateur|shop|seller|dealer|retailer|technician|repairer|Händler|Verkäufer|Geschäft|Werkstatt)\b)
      (?=.*\b(?:herstell\w*|reparatie|repareren|répar\w*|repair\w*|Reparatur|repariert\w*)\b)
      (?=.*\b(?:schade|beschadigd\w*|kras\w*|endommag\p{L}*|dégât\w*|rayure\w*|damage\w*|scratch\w*|Schaden|beschädigt\w*|Kratzer)\b)
      (?=.*(?:#{REPAIR_NEW_DAMAGE_RELATION_PATTERN.source}))
      (?!.*(?:#{PERSONAL_REPAIR_PATTERN.source}))
      (?!.*(?:#{HISTORICAL_PROFESSIONAL_REPAIR_PATTERN.source}))
      .*\z
    }imxu.freeze
    CONSUMER_HIDDEN_DEFECT_PATTERN = /\b(?:verborgen\s+gebrek\w*|vices?\s+cach[ée]s?|hidden\s+defect\w*|latent\s+defect\w*|versteckte\w*\s+(?:Mangel|Mängel))\b/i.freeze
    # A private house sale is not the physical consumer-goods conformity
    # regime. Require both the dwelling and purchase; a tenant's defect or
    # an abstract construction question must not acquire the sales pack.
    HOUSE_PURCHASE_HIDDEN_DEFECT_PATTERN = %r{
      \A
      (?=.*#{CONSUMER_HIDDEN_DEFECT_PATTERN.source})
      (?=.*\b(?:huis|huizen|woning\w*|appartement\w*|vastgoed|maison\w*|logement\w*|immobilier|house\w*|home\w*|apartment\w*|real\s+estate|Haus|Häuser|Wohnung\w*|Immobilie\w*)\b)
      (?=.*\b(?:kocht|gekocht|koop\w*|aankoop\w*|verkoop\w*|koper\w*|verkoper\w*|achet\p{L}*|achat\w*|vente|vendeur\w*|buy\w*|bought|purchas\w*|sale|seller\w*|Kauf\w*|gekauft|Verkäufer\w*)\b)
      .*\z
    }imxu.freeze
    HOUSE_HIDDEN_DEFECT_PRIORITY = [%w[1804032154 1641], %w[1804032154 1648],
                                    %w[1804032154 1643], %w[1804032154 1644]].map(&:freeze).freeze
    LAWYER_FEE_PATTERN = %r{
      \A
      (?=.*\b(?:advoca\w*|avocat\w*|lawyer\w*|attorney\w*|Rechtsanwalt\w*|Anwalt\w*)\b)
      (?=.*\b(?:ereloon\w*|honorari\w*|honoraire\w*|kosten|tarie\w*|uurtarie\w*|fee\w*|hourly|percentage|procent\w*|pourcentage|Gebühr\w*|Honorar\w*|Stundensatz|Prozent\w*)\b)
      .*\z
    }imxu.freeze
    # The product is often described as a cover inside home insurance, not
    # as a compound "legal-assistance insurance" label. Bind the colloquial
    # legal-assistance term to nearby insurance/policy wording; legal aid on
    # its own must not acquire an insurance free-choice provision.
    LEGAL_EXPENSE_INSURANCE_PATTERN = %r{
      \b(?:rechtsbijstands?verzekering\w*|assurance\s+(?:de\s+)?protection\s+juridique|legal[\s-]+(?:assistance|expenses?)\s+insurance|Rechtsschutzversicherung\w*)\b |
      \b(?:\p{L}*verzeker\p{L}*|(?:woon|brand|auto|verzekerings)?polis(?:sen|voorwaarden)?|assurance\w*|assureur\w*|insurance|insurer\w*|policy|\p{L}*Versicher\p{L}*)\b
      [^.!?;\n]{0,160}\b(?:rechtsbijstand|protection\s+juridique|legal[\s-]+(?:assistance|expenses?)|Rechtsschutz)\b |
      \b(?:rechtsbijstand|protection\s+juridique|legal[\s-]+(?:assistance|expenses?)|Rechtsschutz)\b
      [^.!?;\n]{0,160}\b(?:\p{L}*verzeker\p{L}*|(?:woon|brand|auto|verzekerings)?polis(?:sen|voorwaarden)?|assurance\w*|assureur\w*|insurance|insurer\w*|policy|\p{L}*Versicher\p{L}*)\b
    }ixu.freeze
    # A drain camera describes a diagnostic tool, not surveillance. A mixed
    # query about CCTV/privacy still admits the Camera Act independently.
    TECHNICAL_CAMERA_PATTERN = /\b(?:camera\w*|caméra\w*|Kamera\w*)\b.{0,90}\b(?:inspect\w*|detect\w*|riool\w*|afvoer\w*|leidingen?|lek\w*|égout\w*|canalisat\w*|fuite\w*|sewer\w*|drain\w*|pipe\w*|leak\w*|Rohr\w*|Abwasser\w*)\b|\b(?:inspect\w*|detect\w*|riool\w*|afvoer\w*|leidingen?|lek\w*|égout\w*|canalisat\w*|fuite\w*|sewer\w*|drain\w*|pipe\w*|leak\w*|Rohr\w*|Abwasser\w*)\b.{0,90}\b(?:camera\w*|caméra\w*|Kamera\w*)\b/iu.freeze
    SURVEILLANCE_CAMERA_PATTERN = /\b(?:bewakingscamera\w*|camerabewaking|videobewaking|vidéosurveillance|caméra\w*\s+de\s+surveillance|CCTV|surveillance|security\s+camera\w*|privacy|buren|voorbijganger\w*|neighbou?r\w*|passersby|voisin\w*|passant\w*|Nachbar\w*|Videoüberwachung\w*|Überwachungskamera\w*)\b/iu.freeze
    HOUSE_PURCHASE_SPECIALIST_SOURCE_GATES = [
      [%w[2010014108], /\b(?:gevaarlijke\s+goederen|marchandises\s+dangereuses|dangerous\s+goods|Gefahrgut)\b/iu,
       /\b(?:gevaarlijke\s+goederen|marchandises\s+dangereuses|dangerous\s+goods|Gefahrgut|ADR|RID)\b/iu],
      [%w[2022033799], /\b(?:erfrecht|nalatenschap|successie|succession|inheritance|Erbrecht)\b/iu,
       /\b(?:erf\w*|nalatenschap\w*|successie\w*|succession\w*|hérit\p{L}*|inherit\w*|Erb\w*|testament\w*|last\s+will)\b/iu],
      [%w[1984023228], /\b(?:grondwaterwinning\w*|captage\w*\s+(?:des?\s+)?eaux\s+souterraines|groundwater\s+abstraction|Grundwasserentnahme)\b/iu,
       /\b(?:grondwaterwinning\w*|grondwater\s+(?:oppompen|onttrekken)|waterwinning\w*|boorput\w*|captage\w*|pompage\w*|puits|groundwater\s+(?:abstraction|extract\w*|pump\w*)|borehole\w*|well\s+water|Grundwasserentnahme|Brunnen\w*)\b/iu],
      [%w[2016031013], /\b(?:verwerving|verkrijging|vervreemding|acquisition|aliénation)\b.{0,140}\b(?:openbare\s+besturen|pouvoirs\s+publics|public\s+authorit\w*)\b/iu,
       /\b(?:openbare\s+(?:verwerving|aankoop|verkoop|besturen)|gemeent\w*|overheids\w*|pouvoirs\s+publics|commune\w*|public\s+(?:acquisition|authorit\w*)|municipal\w*|local\s+authorit\w*|Gemeinde\w*)\b/iu],
      [%w[2007037155], /\b(?:minnelijke\s+ontbinding|résolution\s+amiable|mutual\s+(?:termination|rescission))\b/iu,
       /\b(?:minnelijke\s+ontbinding|résolution\s+amiable|mutual\s+(?:termination|rescission)|registration\s+(?:tax|duties)|registratierecht\w*|droits?\s+d['’]enregistrement)\b/iu]
    ].map(&:freeze).freeze
    HOUSE_ECONOMIC_LAW_CONTEXT_PATTERN = /\b(?:(?-i:WER)|wetboek\s+(?:van\s+)?economisch\s+recht|code\s+de\s+droit\s+économique|economic\s+law\s+code|consument\w*|consumer\w*|consommateur\w*|Verbraucher\w*|makelaar\w*|estate\s+agent\w*|agent\s+immobilier|courtier\w*|Makler\w*|professionele\s+verkoper\w*|professional\s+seller\w*|vendeur\w*\s+professionnel\w*|gewerblich\w*\s+Verkäufer\w*|projectontwikkelaar\w*|unfair\s+(?:term\w*|practice\w*)|oneerlijk\w*\s+(?:beding\w*|praktijk\w*))\b/iu.freeze
    # These are subject families, not a list of the latest false-positive
    # NUMACs. Private-sale evidence cannot borrow relevance from inheritance,
    # public appropriations or procurement just through "sale", "fees" or
    # "insolvency". A genuinely mixed question admits each domain normally.
    HOUSE_PURCHASE_SOURCE_FAMILY_GATES = [
      [[], /\b(?:erfrecht\w*|erfopvolg\w*|nalatenschap\w*|successie\w*|succession\w*|inheritance|Erbrecht|schenkingen|donations?|testament\w*)\b/iu,
       /\b(?:erf\w*|nalatenschap\w*|successie\w*|succession\w*|hérit\p{L}*|inherit\w*|Erb\w*|testament\w*|last\s+will|donat\w*|schenking\w*|gifted|deceased|overleden|décédé\w*|verstorben\w*)\b/iu],
      [[], PUBLIC_BUDGET_SOURCE_PATTERN, PUBLIC_BUDGET_QUERY_PATTERN],
      [[], /\b(?:overheidsopdracht\w*|march[ée]s?\s+publics?|public\s+procurement|[öo]ffentliche\w*\s+(?:Auftrag\w*|Vergabe\w*))\b/iu,
       /\b(?:overheidsopdracht\w*|aanbesteding\w*|march[ée]s?\s+publics?|public\s+(?:procurement|tender\w*)|government\s+contract\w*|[öo]ffentliche\w*\s+(?:Auftrag\w*|Vergabe\w*))\b/iu]
    ].map(&:freeze).freeze
    COURT_ORGANISATION_SOURCE_PATTERN = %r{
      \b(?:gerechtelijke\s+organisatie|organisation\s+judiciaire|court\s+organi[sz]ation|Gerichtsorganisation)\b |
      \b(?:hof\s+van\s+beroep|cour\s+d['’]appel|court\s+of\s+appeal|Berufungsgericht\w*)\b
      .{0,90}\b(?:bestaat\s+uit|se\s+compose|consists\s+of|besteht\s+aus)\b |
      \b(?:er\s+zijn|il\s+(?:existe|y\s+a)|there\s+are)\b.{0,50}
      \b(?:hof\s+van\s+beroep|cour\s+d['’]appel|court\s+of\s+appeal)\b
      .{0,60}\b(?:kamers?|chambres?|chambers?)\b
    }ixu.freeze
    COURT_ORGANISATION_QUERY_PATTERN = %r{
      \b(?:gerechtelijke\s+organisatie|organisation\s+judiciaire|court\s+(?:organi[sz]ation|structure|composition)|Gerichtsorganisation|eerste\s+voorzitter|premier\s+président|first\s+president)\b |
      \b(?:hof\s+van\s+beroep|rechtbank\w*|cour\s+d['’]appel|tribunal\w*|court\w*|Gericht\w*)\b
      .{0,80}\b(?:samenstelling|kamers?|composition|chambres?|chambers?|number\s+of\s+judges|aantal\s+rechters|Besetzung|Kammer\w*)\b |
      \b(?:samenstelling|composition|number\s+of\s+judges|aantal\s+rechters|Besetzung)\b.{0,80}
      \b(?:hof\s+van\s+beroep|rechtbank\w*|cour\s+d['’]appel|tribunal\w*|court\w*|Gericht\w*)\b
    }ixu.freeze
    # Performing office work on a commute does not make someone a railway
    # employee. The governing working-time definition and overtime rule must
    # precede the specialist transport sources that share the word "train".
    RAILWAY_EMPLOYMENT_PATTERN = /\b(?:treinbestuurder\w*|treinbesturingspersoneel|treinbegeleider\w*|spoorwegpersoneel|spoorwegwerknemer\w*|machinist\w*|conducteur\w*|railway\s+(?:driver\w*|worker\w*|employee\w*|staff)|train\s+(?:driver\w*|crew)|cheminot\w*|personnel\s+ferroviaire|conducteur\w*\s+de\s+train|Lokführer\w*|Bahnpersonal|Eisenbahner\w*|mobiele\s+werknemers.{0,50}spoorweg\w*|mobile\s+worker\w*.{0,50}rail\w*|(?:personeel\p{L}*|werknemer\p{L}*|employees?|workers?|staff|personnel|Personal)\b.{0,60}\b(?:Belgische\s+Spoorwegen|chemins\s+de\s+fer\s+belges|Belgian\s+Railways|Belgischen\s+Bahnen|NMBS|SNCB)|(?:NMBS|SNCB)\b.{0,60}\b(?:personeel\p{L}*|werknemer\p{L}*|employees?|workers?|staff|personnel|Personal))\b/iu.freeze
    OFFICE_COMMUTE_WORK_PATTERN = %r{
      \A
      (?!.*#{RAILWAY_EMPLOYMENT_PATTERN.source})
      (?=.*\b(?:trein\w*|train\w*|Zug|Bahn)\b)
      (?=.*\b(?:werk\w*|arbeid\w*|travail\w*|work\w*|arbeit\w*|laptop|emails?|e-mails?)\b.{0,55}\b(?:trein\w*|train\w*|Zug|Bahn)\b|.*\b(?:trein\w*|train\w*|Zug|Bahn)\b.{0,55}\b(?:werk\w*|arbeid\w*|travail\w*|work\w*|arbeit\w*|laptop|emails?|e-mails?)\b)
      (?=.*\b(?:kantoor\w*|office|bureau|Büro|woon[-\s]?werk\w*|onderweg\s+naar\s+(?:het\s+)?werk|pendel\w*|commut\w*|trajet\w*|Arbeitsweg)\b)
      (?=.*\b(?:overur\w*|overwerk|overtime|heures\s+supplémentaires|Überstunden|werkur\w*|arbeidsduur|gewerkte\s+uren|working\s+(?:time|hours)|temps\s+de\s+travail|Arbeitszeit|tellen?|tell?ke|clock\w*|geklokt|uitgeklokt|ingeklokt|betaal\w*|paid|pay\w*)\b)
      .*\z
    }imxu.freeze
    OFFICE_COMMUTE_PRIORITY = [%w[1971031602 19], %w[1971031602 29]].map(&:freeze).freeze
    WORK_SCHEDULE_QUERY_PATTERN = /\b(?:uurrooster\w*|ploegen\w*|flexibel\w*|wisselend\w*\s+week\w*|horaires?\w*|équipes?|flexible\w*|shift\w*|schedule\w*|alternating\s+week\w*|Schicht\w*|Dienstplan\w*)\b/iu.freeze
    # Subscription/ticket alone can mean software, streaming or an event.
    # Require a travel-fare expression, not incidental proximity to a journey.
    COMMUTER_FARE_QUERY_PATTERN = %r{
      \b(?:treinabonnement\p{L}*|treinkaart\p{L}*|vervoerskosten|reiskosten|woon[-\s]?werkvergoeding\p{L}*|
          train\s+pass\p{L}*|season\s+(?:ticket|pass)\p{L}*|commut\p{L}*\s+(?:cost\p{L}*|fare\p{L}*|reimburse\p{L}*)|
          frais\s+de\s+transport|Fahrkarte\p{L}*|Fahrkosten\p{L}*|Pendlerpauschale)\b|
      \b(?:train|rail|bus|tram)\s+(?:tickets?|pass|subscription\p{L}*)\b|
      \b(?:abonnement\p{L}*|tickets?|subscription\p{L}*)\s+(?:voor|van|for|on|de|du|pour|f[uü]r)\s+(?:(?:de|the|le|la|den)\s+)?(?:trein|bus|tram|train|rail|Zug|Bahn)\b|
      \b(?:trein|bus|tram|openbaar\s+vervoer|train|rail|public\s+transport|transports?\s+en\s+commun|Zug|Bahn|ÖPNV)\b
        \s+(?:fare\p{L}*|cost\p{L}*|prijs|kosten|tarie\p{L}*|bijdrage|prix|frais|coût\p{L}*|Kosten|Preis\p{L}*)\b|
      \b(?:fare\p{L}*|cost\p{L}*|prijs|kosten|tarie\p{L}*|bijdrage|prix|frais|coût\p{L}*|Kosten|Preis\p{L}*)\b
        \s+(?:van|voor|of|for|de|du|des|pour|f[uü]r)\s+(?:(?:de|het|mijn|the|my|le|la|les|mon|mes|den|meine\p{L}*)\s+)?
        (?:trein|bus|tram|openbaar\s+vervoer|train|rail|public\s+transport|transports?\s+en\s+commun|Zug|Bahn|ÖPNV)\b
    }ixu.freeze
    FARE_REIMBURSEMENT_QUERY_PATTERN = /\b(?:vergoed\p{L}*|terugbetal\p{L}*|reimburse\p{L}*|refund\p{L}*|rembours\p{L}*|erstatt\p{L}*)\b/iu.freeze
    COMMUTER_FARE_SOURCE_PATTERN = %r{
      \b(?:financi[ëe]le\s+bijdrage\s+van\s+(?:de\s+)?werkgevers?|intervention\s+financi[èe]re\s+de\s+l['’]employeur|
          (?:financial\s+)?(?:employer\p{L}*\s+contribution|contribution\s+of\s+(?:the\s+)?employer\p{L}*)|
          (?:finanziell\p{L}*\s+)?(?:Arbeitgeberbeitrag|Beitrag\s+des\s+Arbeitgebers))\b
        .{0,100}\b(?:prijs|prix|price|fare\p{L}*|Preis\p{L}*|Fahrkosten)\b
        .{0,65}\b(?:gemeenschappelijk\s+openbaar\s+vervoer|openbaar\s+vervoer|transports?\s+en\s+commun(?:\s+publics)?|public\s+transport|öffentlichen\s+(?:Verkehr|Nahverkehr))\b
    }ixu.freeze
    RAILWAY_SAFETY_QUERY_PATTERN = %r{
      \A(?=.*\b(?:trein\w*|spoorweg\w*|train\w*|rail\w*|ferroviaire\w*|Zug|Bahn\w*)\b)
      (?=.*\b(?:veilig\w*|ongeval\w*|sécurité|accident\w*|safe\w*|crash\w*|Sicherheit|Unfall\w*)\b).*\z
    }imxu.freeze
    # An ordinary train commuter is not maritime/transport personnel or a
    # railway-policing subject. Identify the occupation/employer or regulatory
    # function positively; a bare ship, train, passenger or fare is not enough.
    TRANSPORT_EMPLOYER_SUBJECT_PATTERN = /\b(?:regie\s+voor\s+maritiem\s+transport|r[ée]gie\s+des\s+transports\s+maritimes|maritiem\s+transport|transports?\s+maritimes|navigation\s+maritime|maritime\s+transport|Seeverkehr|Schifffahrt\p{L}*|scheepvaart\p{L}*|zeevaart\p{L}*|shipping\s+(?:compan\p{L}*|undertaking\p{L}*)|transportonderneming\p{L}*|vervoer\p{L}*maatschappij\p{L}*|transportbedrijf\p{L}*|entreprises?\s+de\s+transport|transport\s+(?:compan\p{L}*|undertaking\p{L}*|operator\p{L}*)|Verkehrsunternehmen\p{L}*)\b/iu.freeze
    TRANSPORT_WORK_ROLE_PATTERN = %r{
      \b(?:personeel|werknemers?)\s+(?:(?:tewerkgesteld|werkzaam)\s+(?:aan|in|voor)|belast\s+met)\s+vervoerwerken\b|
      \bpersonnel\s+(?:occup[ée]|affect[ée])\s+(?:[àa]|aux)\s+(?:(?:des|les)\s+)?travaux\s+de\s+transport\b|
      \b(?:staff|employees?|workers?)\s+(?:employed|assigned)\s+(?:in|to|on)\s+transport\s+work\b|
      \b(?:Personal|Arbeitnehmer\p{L}*|Beschäftigte)\s+(?:mit\s+Transportarbeiten\s+betraut|f[uü]r\s+Transportarbeiten\s+eingesetzt)\b
    }ixu.freeze
    TRANSPORT_STAFF_SUBJECT_PATTERN = %r{
      (?:#{TRANSPORT_WORK_ROLE_PATTERN.source})|
      \b(?:zeevarend\p{L}*|zeelieden|zeelui|scheepspersoneel|scheepsbemanning\p{L}*|transportpersoneel|
          truck\s+drivers?|lorry\s+drivers?|vrachtwagenchauffeur\p{L}*|chauffeurs?\s+de\s+poids\s+lourds|Lkw[-\s]?Fahrer\p{L}*|
          marins?|gens\s+de\s+mer|seafarers?|seafaring\s+(?:staff|workers?)|maritime\s+(?:staff|employees?|workers?|crew)|maritiem\p{L}*\s+(?:personeel|werknemer\p{L}*)|
          transport\s+(?:staff|employees?|workers?)|Seeleute|Seemann\p{L}*|Schiffspersonal|Schiffsbesatzung\p{L}*)\b|
      \b(?:personeel\p{L}*|werknemer\p{L}*|bemanning\p{L}*|personnel|salari[ée]\p{L}*|staff|employees?|workers?|crew|Personal|Beschäftigt\p{L}*|Arbeitnehmer\p{L}*)\b
        .{0,220}#{TRANSPORT_EMPLOYER_SUBJECT_PATTERN.source}|
      #{TRANSPORT_EMPLOYER_SUBJECT_PATTERN.source}.{0,140}
        \b(?:personeel\p{L}*|werknemer\p{L}*|bemanning\p{L}*|personnel|salari[ée]\p{L}*|staff|employees?|workers?|crew|Personal|Beschäftigt\p{L}*|Arbeitnehmer\p{L}*)\b
    }ixmu.freeze
    TRANSPORT_STAFF_QUERY_PATTERN = Regexp.union(
      TRANSPORT_STAFF_SUBJECT_PATTERN,
      /\b(?:regie\s+voor\s+maritiem\s+transport|r[ée]gie\s+des\s+transports\s+maritimes)\b/iu
    ).freeze
    RAILWAY_POLICING_SOURCE_PATTERN = %r{
      \b(?:spoorwegpolitie|spoorweginspectie|railway\s+(?:police|policing|inspection|inspectorate)|rail\s+(?:police|inspection)|Bahnpolizei|Eisenbahnpolizei|Eisenbahnaufsicht)\b|
      \b(?:politie|police|policing|inspectie|inspection|inspectorate|Polizei|Aufsicht|Inspektion)\b.{0,65}
        \b(?:spoorweg\p{L}*|chemins?\s+de\s+fer|ferroviaire\p{L}*|railways?|Eisenbahn\p{L}*|Bahn)\b|
      \b(?:spoorweg\p{L}*|chemins?\s+de\s+fer|ferroviaire\p{L}*|railways?|Eisenbahn\p{L}*|Bahn)\b.{0,65}
        \b(?:politie|police|policing|inspectie|inspection|inspectorate|Polizei|Aufsicht|Inspektion)\b
    }ixmu.freeze
    RAILWAY_POLICING_QUERY_PATTERN = RAILWAY_POLICING_SOURCE_PATTERN
    # These occupational scopes can appear only in an article's body (or a
    # ruling with a generic heading). Company/agency names and a commuter's
    # journey alone do not identify specialist staff or driver obligations.
    VICINAL_RAILWAY_EMPLOYER_PATTERN = /\b(?:NMVB|SNCV|Nationale\s+Maatschappij\s+(?:van|der)\s+(?:de\s+)?Buurtspoorwegen|Soci[ée]t[ée]\s+nationale\s+des\s+chemins\s+de\s+fer\s+vicinaux|National\s+Vicinal\s+Railway\s+Company)\b/iu.freeze
    OCCUPATIONAL_PERSONNEL_PATTERN = /\b(?:personeel\p{L}*|werknemer\p{L}*|werklieden|arbeider\p{L}*|ambtena\p{L}*|personnel|salari[ée]\p{L}*|ouvriers?|fonctionnaire\p{L}*|staff|employees?|workers?|civil\s+servants?|public\s+(?:officials?|employees?)|Personal\p{L}*|Beschäftigt\p{L}*|Mitarbeiter\p{L}*|Arbeitnehmer\p{L}*|Beamt\p{L}*)\b/iu.freeze
    OCCUPATIONAL_RULE_PATTERN = /\b(?:arbeidsduur|arbeidstijd\p{L}*|werkuren|werktijd\p{L}*|werkbelasting|arbeidsvoorwaarden|overur\p{L}*|rusttijd\p{L}*|statuut|rechtspositieregeling\p{L}*|bezoldig\p{L}*|geldelijk|deconnectie|working\s+(?:time|hours|conditions)|workload|overtime|rest\s+(?:time|periods?)|employment\s+(?:status|rules)|remuneration|pay\s+statute|disconnection|dur[ée]e\s+du\s+travail|temps\s+de\s+travail|charge\s+de\s+travail|conditions\s+de\s+travail|heures\s+suppl[ée]mentaires|r[ée]gime.{0,35}\d{1,2}\s+heures|statut\p{L}*|r[ée]mun[ée]ration|d[ée]connexion|Arbeitszeit\p{L}*|Arbeitsbelastung|Arbeitsbedingungen|Überstunden|Ruhezeit\p{L}*|Besoldung\p{L}*|Dienstrecht|Dienstplan\p{L}*|\d{1,2}[-\s]*(?:uren|hours?|heures|Stunden)[-\s]*(?:stelsel|regime|schedule|week))\b/iu.freeze
    VICINAL_RAILWAY_STAFF_PATTERN = Regexp.union(
      /#{OCCUPATIONAL_PERSONNEL_PATTERN.source}.{0,40}\b(?:van|bij|door|de|du|des|of|for|at|chez|bei|der)\b.{0,35}#{VICINAL_RAILWAY_EMPLOYER_PATTERN.source}/imu,
      /#{VICINAL_RAILWAY_EMPLOYER_PATTERN.source}.{0,50}\b(?:tewerkgesteld\p{L}*|werkzaam|employed|employ[ée]\p{L}*|beschäftigt\p{L}*)\b.{0,25}#{OCCUPATIONAL_PERSONNEL_PATTERN.source}/imu,
      /#{VICINAL_RAILWAY_EMPLOYER_PATTERN.source}[-\s]*(?:personeel\p{L}*|staff|personnel|Personal)\b/iu
    ).freeze
    RAILWAY_PERSONAL_EMPLOYMENT_PATTERN = /\b(?:NMBS|SNCB)\b.{0,180}\b(?:zijn|haar|his|her|sa|son|sein\p{L}*)\s+(?:aanvraag|verzoek|request|demande|Antrag)\b.{0,160}\b(?:werken|tewerkgesteld|arbeidsregime|work|working|travailler|employ[ée]\p{L}*|arbeiten|beschäftigt)\b/imu.freeze
    RAILWAY_OCCUPATIONAL_SUBJECT_PATTERN = /\b(?:treinbestuurder\p{L}*|treinbesturingspersoneel|treinpersoneel|spoorwegpersoneel|spoorwegwerknemer\p{L}*|railway\s+(?:staff|workers?|employees?|drivers?)|train\s+(?:crew|drivers?)|personnel\s+ferroviaire|conducteurs?\s+de\s+trains?|cheminot\p{L}*|Bahnpersonal\p{L}*|Eisenbahnpersonal\p{L}*|Lokführer\p{L}*|Zugpersonal\p{L}*)\b/iu.freeze
    RAILWAY_TRANSPORT_SUBJECT_PATTERN = /\b(?:NMBS|SNCB|Infrabel|spoor\p{L}*|trein\p{L}*|ferroviaire\p{L}*|chemins?\s+de\s+fer|railways?|rail|trains?|Eisenbahn\p{L}*|Bahn\p{L}*)\b/iu.freeze
    RAILWAY_STRIKE_PATTERN = /\b(?:staking\p{L}*|stakingsdag\p{L}*|(?:trein|spoor(?:weg)?)[-\s]?staking\p{L}*|gr[èe]ve\p{L}*|strikes?|Streik\p{L}*|Bahn[-\s]?streik\p{L}*)\b/iu.freeze
    PASSENGER_SERVICE_PATTERN = /\b(?:dienstverlening|vervoersaanbod|vervoersplan\p{L}*|personenvervoer|passenger\s+(?:transport|service)|railway\s+service|offre\s+de\s+transport|service\s+de\s+transport|continuit[ée]\s+du\s+service|Personenverkehr|Bahnverkehr|Mindestdienst\p{L}*)\b/iu.freeze
    MANAGEMENT_CONTRACT_PATTERN = /\b(?:beheerscontract\p{L}*|contrat\s+de\s+gestion|management\s+contract|Verwaltungsvertrag|Leistungsvereinbarung)\b/iu.freeze
    ROAD_DRIVER_SUBJECT_PATTERN = /\b(?:vrachtwagenchauffeur\p{L}*|buschauffeur\p{L}*|zelfstandige\s+bestuurder\p{L}*|independent\s+drivers?|truck\s+drivers?|lorry\s+drivers?|bus\s+drivers?|road\s+transport\s+drivers?|chauffeurs?\s+(?:routiers?|de\s+poids\s+lourds)|conducteurs?\s+(?:routiers?|ind[ée]pendants?|d['’]autobus)|Lkw[-\s]?Fahrer\p{L}*|Busfahrer\p{L}*|Berufskraftfahrer\p{L}*|selbst[aä]ndige\s+Fahrer\p{L}*|bestuurder\p{L}*.{0,65}(?:wegvervoer|voertuig\p{L}*)|drivers?.{0,65}road\s+transport)\b/imu.freeze
    TACHOGRAPH_SUBJECT_PATTERN = /\b(?:tachogra\p{L}*|tachograph\p{L}*|Tachograf\p{L}*|Fahrtenschreiber\p{L}*|Kontrollger[aä]t\p{L}*)\b/iu.freeze
    DRIVING_REST_SCOPE_PATTERN = /\b(?:rij[-\s]*(?:en\s+)?rusttijd\p{L}*|rijtijden|driving\s+(?:and\s+rest\s+)?(?:time|hours|periods?)|temps\s+de\s+conduite|Lenk[-\s]*(?:und\s+Ruhe)?zeiten|Lenkzeit\p{L}*)\b/iu.freeze
    DRIVER_REGULATORY_RULE_PATTERN = /\b(?:verplicht\p{L}*|reglement\p{L}*|regel\p{L}*|controle\p{L}*|install\p{L}*|gebruik|toezicht|sancti\p{L}*|oblig\p{L}*|r[ée]glement\p{L}*|utilis\p{L}*|contr[oô]le\p{L}*|require\p{L}*|regulat\p{L}*|rules?|use|enforcement|pflicht\p{L}*|Vorschrift\p{L}*|Kontrolle\p{L}*|Verwendung)\b/iu.freeze
    LOCAL_PUBLIC_EMPLOYER_PATTERN = /\b(?:(?:lokale(?:\s+en\s+provinciale)?|provinciale)\s+besturen|gemeentebestur\p{L}*|provinciebestur\p{L}*|administrations?\s+(?:locales?(?:\s+et\s+provinciales?)?|provinciales?|communales?)|(?:local(?:\s+and\s+provincial)?|municipal|provincial)\s+(?:governments?|authorities|administrations?)|(?:kommunal\p{L}*(?:\s+und\s+provinziell\p{L}*)?|provinziell\p{L}*)\s+Verwaltung\p{L}*)\b/iu.freeze
    LOCAL_PUBLIC_STAFF_PATTERN = Regexp.union(
      /#{OCCUPATIONAL_PERSONNEL_PATTERN.source}\s+(?:van|bij|de|du|des|of|for|at|chez|der|bei)\s+(?:(?:de|het|the|a|an|le|la|les|der|die|dem)\s+)?#{LOCAL_PUBLIC_EMPLOYER_PATTERN.source}/iu,
      /#{LOCAL_PUBLIC_EMPLOYER_PATTERN.source}\s+#{OCCUPATIONAL_PERSONNEL_PATTERN.source}/iu,
      /\b(?:(?:gemeentelijke|provinciale)\s+personeel\p{L}*|agents?\s+(?:communaux|provinciaux)|municipal\s+(?:staff|employees?)|Kommunalbedienstet\p{L}*|Gemeindeangestellt\p{L}*)\b/iu
    ).freeze
    CIVIL_SERVICE_POPULATION_PATTERN = Regexp.union(
      /\b(?:ambtena\p{L}*|fonctionnaire\p{L}*|civil\s+servants?|public\s+(?:officials?|employees?)|government\s+(?:staff|employees?)|Beamt\p{L}*|Staatsbedienstet\p{L}*|(?:personeel\p{L}*|personnel|staff|employees?).{0,100}(?:overheidsinstelling\p{L}*|instellingen\s+van\s+openbaar\s+nut|organismes?\s+d['’]int[ée]r[êe]t\s+public|public\s+institutions?|government\s+institutions?))\b/imu,
      LOCAL_PUBLIC_STAFF_PATTERN
    ).freeze
    PUBLIC_EMPLOYER_QUERY_PATTERN = Regexp.union(
      /\b(?:FOD|SPF|federale\s+overheid|federal\s+government|overheidsinstelling\p{L}*|instellingen\s+van\s+openbaar\s+nut|organismes?\s+d['’]int[ée]r[êe]t\s+public|public\s+institutions?|government\s+institutions?|Bundesbeh[oö]rde\p{L}*|gemeente|provincie|commune|province|municipality|Gemeinde)\b/iu,
      LOCAL_PUBLIC_EMPLOYER_PATTERN
    ).freeze
    MILITARY_EMPLOYER_PATTERN = /\b(?:ADIV|SGRS|Algemene\s+Dienst\s+Inlichtingen\s+en\s+Veiligheid|Service\s+g[ée]n[ée]ral\s+du\s+renseignement\s+et\s+de\s+la\s+s[ée]curit[ée]|Krijgsmacht|forces?\s+arm[ée]es|armed\s+forces|Streitkr[aä]fte|militair\p{L}*|military|militaire\p{L}*|Soldat\p{L}*)\b/iu.freeze
    MILITARY_CIVILIAN_ROLE_PATTERN = /\b(?:burgerlijke\s+ambtena\p{L}*|burgerpersoneel|personnel\s+civil|fonctionnaires?\s+civils?|civilian\s+(?:staff|employees?|officials?)|zivil\p{L}*\s+(?:Personal|Beamt\p{L}*))\b/iu.freeze
    MILITARY_PERSONNEL_PATTERN = Regexp.union(
      /#{MILITARY_CIVILIAN_ROLE_PATTERN.source}.{0,180}#{MILITARY_EMPLOYER_PATTERN.source}/imu,
      /#{OCCUPATIONAL_PERSONNEL_PATTERN.source}.{0,35}\b(?:van|bij|door|de|du|des|of|for|at|chez|bei|der)\b.{0,35}#{MILITARY_EMPLOYER_PATTERN.source}/imu,
      /\b(?:militairen|militaire\s+personeelsleden|militair\s+personeel|military\s+personnel|personnel\s+militaire|Soldaten)\b/iu
    ).freeze
    SPECIALIST_QUESTION_REQUEST_PATTERN = /\b(?:vraag\p{L}*|wat|welke|hoe|leg\s+uit|ask\p{L}*|what|which|how|explain|question|demande\p{L}*|quels?|quelles?|comment|explique\p{L}*|frage\p{L}*|welche\p{L}*|wie|erkl[aä]r\p{L}*)\b/iu.freeze
    NEGATED_OCCUPATION_PATTERN = /\b(?:geen|niet|not|no|pas|nicht|kein\p{L}*)\b.{0,40}\b(?:werknemer\p{L}*|ambtena\p{L}*|chauffeur\p{L}*|bestuurder\p{L}*|employees?|workers?|civil\s+servants?|drivers?|fonctionnaire\p{L}*|conducteur\p{L}*|chauffeur\p{L}*|Beamt\p{L}*|Fahrer\p{L}*)\b/iu.freeze
    ORDINARY_OFFICE_SOURCE_SUBJECT_PATTERN = /\b(?:kantoormedewerker\p{L}*|kantoorpersoneel|office\s+(?:employees?|workers?|commuters?)|salari[ée]\p{L}*.{0,40}bureau|Bürobeschäftigt\p{L}*|Büroangestellt\p{L}*)\b/imu.freeze
    OFFICE_COMMUTE_SPECIALIST_SOURCE_GATES = [
      [%w[1951042416 1950100150 1950102050],
       /\b(?:sociale\s+zekerheid|social\s+security|sécurité\s+sociale|Sozialversicherung|sociale\s+verzekering\w*|assurances?\s+sociales?)\b/iu,
       /\b(?:sociale\s+zekerheid|social\s+(?:security|insurance)|sécurité\s+sociale|Sozialversicherung|sociale\s+verzekering\w*|assurances?\s+sociales?|grensarbeid\w*|cross[-\s]?border\s+(?:work\w*|employ\w*)|travailleur\w*\s+frontalier\w*|Grenzgänger\w*|mijnwerker\w*|mine\s+worker\w*|mineur\w*|Bergarbeiter\w*)\b/iu],
      [%w[2021022705], /\b(?:deconnectie|déconnexion|disconnection)\b.{0,120}\b(?:federale\s+(?:ambtenaren|overheid)|fonctionnaires?\s+fédéra\w*|federal\s+(?:civil|public))\b/iu,
       /\b(?:ambtena\w*|fonctionnaire\w*|civil\s+servant\w*|federal\s+(?:public|employment|employee\w*)|federale\s+overheid|FOD|SPF|Bundesbeamte\w*)\b/iu],
      [%w[2008014330], /\b(?:interoperabel\w*|interopérable\w*|interoperable)\b.{0,100}\b(?:spoorweg\w*|ferroviaire\w*|rail\w*)\b/iu,
       RAILWAY_EMPLOYMENT_PATTERN],
      [[], RAILWAY_EMPLOYMENT_PATTERN, RAILWAY_EMPLOYMENT_PATTERN],
      [[], TRANSPORT_STAFF_SUBJECT_PATTERN, TRANSPORT_STAFF_QUERY_PATTERN],
      [[], COMMUTER_FARE_SOURCE_PATTERN, COMMUTER_FARE_QUERY_PATTERN],
      [[], RAILWAY_POLICING_SOURCE_PATTERN, RAILWAY_POLICING_QUERY_PATTERN],
      [[], /\b(?:veilig\w*|sécurité|safe\w*|Sicherheit)\b.{0,120}\b(?:spoorweg\w*|ferroviaire\w*|railway\w*|Eisenbahn\w*)\b|\b(?:spoorweg\w*|ferroviaire\w*|railway\w*|Eisenbahn\w*)\b.{0,120}\b(?:veilig\w*|sécurité|safe\w*|Sicherheit)\b/iu,
       Regexp.union(RAILWAY_EMPLOYMENT_PATTERN, RAILWAY_SAFETY_QUERY_PATTERN, RAILWAY_POLICING_QUERY_PATTERN)],
      [[], /\b(?:werkgever\w*|employer\w*|employeur\w*|Arbeitgeber\w*)\b.{0,160}\b(?:NMBS|SNCB|nationale\s+maatschappij.{0,60}spoorwegen|société\s+nationale.{0,60}chemins\s+de\s+fer)\b|\b(?:NMBS|SNCB)\b.{0,160}\b(?:werkgever\w*|employer\w*|employeur\w*|Arbeitgeber\w*)\b/iu,
       COMMUTER_FARE_QUERY_PATTERN]
    ].map(&:freeze).freeze
    # Source families that acquired lexical relevance from "calls", "contact
    # information", "data" or a generic obligation. Their own subject must
    # be asked about in a caller-origin/removal question; no law-id blacklist.
    TELEMARKETING_PRIVACY_PATTERN = TelemarketingPrivacyIntent::QUESTION_PATTERN
    TELEMARKETING_PRIORITY = [%w[2013A11134 VI.110], %w[2013A11134 VI.112], %w[2013A11134 VI.111]].map(&:freeze).freeze
    MUNICIPAL_SANCTIONS_PATTERN = /\A(?=.*#{MunicipalSanctionsSourceScope::MUNICIPAL_FINE_PATTERN})(?=.*#{MunicipalSanctionsSourceScope::SIDEWALK_NUISANCE_PATTERN})(?=.*#{MunicipalSanctionsSourceScope::MUNICIPALITY_PATTERN}).*\z/imu.freeze
    MUNICIPAL_SANCTIONS_PRIORITY = %w[2 4 25 31].map { |number| ['2013000441', number].freeze }.freeze
    VEHICLE_HEADLIGHT_PATTERN = VehicleHeadlightGlareSourceScope::QUESTION_PATTERN
    VEHICLE_HEADLIGHT_LIABILITY_PATTERN = VehicleHeadlightGlareSourceScope::LIABILITY_QUESTION_PATTERN
    # Exact parent articles contain the numbered road-code clauses. The
    # enacted postponement is a current-date companion, not a replacement
    # for the law text or a licence to use today's regime for old accidents.
    VEHICLE_HEADLIGHT_PRIORITY = [%w[2026004490 58], %w[1975120109 30], %w[1968031501 28],
                                  %w[2024001600 6.6], %w[2024001600 6.18], %w[1975120109 8],
                                  %w[1975120109 10], %w[2024001600 6.20], %w[2024001600 6.5]].map(&:freeze).freeze
    TELEMARKETING_ENERGY_SUPPORT_SUBJECT_PATTERN = /\b(?:groene[-\s]+warmte|restwarmte|stadsverwarming|stadskoeling|biomethaan|biomassa|biomass|Biomasse|green\s+heat|waste\s+heat|district\s+(?:heating|cooling)|biomethane|chaleur\s+(?:verte|fatale)|(?:chauffage|refroidissement)\s+urbain|biom[ée]thane|gr[üu]ne\s+W[äa]rme|Abw[äa]rme|Fernw[äa]rme|Fernk[üu]hlung|Biomethan)\b/iu.freeze
    TELEMARKETING_ENERGY_SUPPORT_PATTERN = /\b(?:ondersteun\p{L}*|steun\p{L}*|subsid\p{L}*|grants?|funding|support|aides?|soutien|subvention\p{L}*|F[öo]rder\p{L}*|Unterst[üu]tz\p{L}*)\b/iu.freeze
    TELEMARKETING_ENERGY_CALL_PATTERN = /\b(?:calls?|appels?|oproep\p{L}*|Aufruf\p{L}*)\b/iu.freeze
    TELEMARKETING_FINANCIAL_SUPPORT_PATTERN = /\b(?:subsid\p{L}*|grants?|funding|steunaanvr\p{L}*|steunbedrag|financi[ëe]le\s+ondersteuning|financial\s+support|aides?\s+financi[èe]res?|soutien\s+financier|subvention\p{L}*|F[öo]rder\p{L}*|finanzielle\s+Unterst[üu]tzung)\b/iu.freeze
    TELEMARKETING_NONFUNDING_SUPPORT_PATTERN = /\b(?:customer\s+support|technical\s+support|klanten(?:support|ondersteuning)|technische\s+ondersteuning|support\s+(?:client\p{L}*|technique)|assistance\s+technique|Kundendienst|technische\s+Unterst[üu]tzung)\b/iu.freeze
    TELEMARKETING_TOPIC_REQUEST_PATTERN = /\A\s*(?:(?:and|also|en|ook|et|aussi|und|auch)\s+)?(?:what|which|how|can|could|wat|welk\p{L}*|hoe|kan|quel\p{L}*|comment|pouvez|was|welch\p{L}*|wie|kann)\b|\b(?:I\s+(?:also\s+)?(?:ask|want\s+to\s+know)|ik\s+(?:vraag|wil\s+weten)|je\s+(?:demande|veux\s+savoir)|ich\s+(?:frage|m[öo]chte\s+wissen)|explain|bespreek|explique\p{L}*|erkl[äa]r\p{L}*)\b/iu.freeze
    TELEMARKETING_CONTRACT_SUBJECT_PATTERN = /\b(?:contracts?|contrats?|overeenkomst\p{L}*|Vertrag\p{L}*|Vertr[äa]ge\p{L}*)\b/iu.freeze
    TELEMARKETING_CONTRACT_REMEDY_PATTERN = /\b(?:onmogelijkheid|nakoming|wanprestatie|overmacht|restitutie|tegenprestatie|ontbind\p{L}*|inex[ée]cution|impossibilit\p{L}*|ex[ée]cution|r[ée]sili\p{L}*|restitut\p{L}*|force\s+majeure|impossibilit\p{L}*|performan\p{L}*|breach|rescis\p{L}*|Unm[öo]glichkeit|Erf[üu]ll\p{L}*|Leistungsst[öo]rung|R[üu]ckgew[äa]hr|R[üu]ckabwicklung|Gegenleistung|h[öo]here\s+Gewalt)\b/iu.freeze
    TELEMARKETING_PERSONAL_DATA_PATTERN = /\b(?:persoonsgegevens|personal\s+data|donn[ée]es\s+(?:[àa]\s+caract[èe]re\s+)?personnelles|personenbezogene\p{L}*\s+Daten)\b/iu.freeze
    TELEMARKETING_DATA_RIGHT_PATTERN = /\b(?:verwijder\p{L}*|wis(?:sen|sing)|bron|herkomst|toestemming|verzet|eras\p{L}*|delet\p{L}*|source|origin|consent|objection|effac\p{L}*|supprim\p{L}*|suppress\p{L}*|consentement|opposition|l[öo]sch\p{L}*|Herkunft|Einwilligung|Widerspruch)\b/iu.freeze
    TELEMARKETING_DIRECT_PRIVACY_PAIR_PATTERN = /(?:#{TELEMARKETING_PERSONAL_DATA_PATTERN.source})[^.!?;]{0,180}(?:#{TELEMARKETING_DATA_RIGHT_PATTERN.source})|(?:#{TELEMARKETING_DATA_RIGHT_PATTERN.source})[^.!?;]{0,180}(?:#{TELEMARKETING_PERSONAL_DATA_PATTERN.source})/iu.freeze
    TELEMARKETING_GRANT_CALL_SOURCE_PATTERN = /(?=.*\b(?:calls?|appels?|oproep\p{L}*|Aufruf\p{L}*)\b)(?=.*\b(?:steunaanvragen|subsidie\p{L}*|grants?|funding|demandes?\s+d['’]aide|subvention\p{L}*|Förder\p{L}*)\b)/iu.freeze
    TELEMARKETING_SPECIALIST_SOURCE_GATES = [
      [/(?=.*\b(?:schepen|schip|ships?|navires?|Schiff\p{L}*)\b)(?=.*\b(?:klachtenprocedure|klachtenformulier|complaint\p{L}*|plainte\p{L}*|Beschwerde\p{L}*)\b)/iu,
       /(?=.*\b(?:schepen|schip|zeeman|ships?|seafarer\p{L}*|navires?|marins?|Schiff\p{L}*|Seeleute)\b)(?=.*\b(?:klacht\p{L}*|complaint\p{L}*|plainte\p{L}*|Beschwerde\p{L}*)\b)/iu],
      [TELEMARKETING_GRANT_CALL_SOURCE_PATTERN,
       /\b(?:steunaanvragen|subsidie\p{L}*|grants?|funding|demandes?\s+d['’]aide|subvention\p{L}*|Förder\p{L}*|Zusch[uü]ss\p{L}*)\b/iu],
      [/(?=.*\b(?:digitale\s+(?:inhoud|dienst)|digital\s+(?:content|service)|contenu\s+num[ée]rique|service\s+num[ée]rique|digitale\p{L}*\s+(?:Inhalte|Dienstleistung\p{L}*))\b)(?=.*\b(?:conform\p{L}*|consument\p{L}*|consumer\p{L}*|consommateur\p{L}*|Verbraucher\p{L}*|overeenkomst\p{L}*|contracts?|contrats?|Vertrag\p{L}*)\b)/iu,
       /(?=.*\b(?:digitale\s+(?:inhoud|dienst)|digital\s+(?:content|service)|contenu\s+num[ée]rique|service\s+num[ée]rique|software|logiciel\p{L}*|streaming|digitale\p{L}*\s+(?:Inhalte|Dienstleistung\p{L}*))\b)(?=.*\b(?:conform\p{L}*|garantie|warranty|refund\p{L}*|terugbetal\p{L}*|prijsvermindering|rembourse\p{L}*|Erstattung|Gewährleistung|updates?|levering|delivery|livraison|overeenkomst\p{L}*|contracts?|contrats?|Vertrag\p{L}*)\b)/iu],
      [/(?=.*\b(?:schuldeisers?|cr[ée]anciers?|creditors?|Gläubiger\p{L}*)\b)(?=.*\b(?:schuldena\p{L}*|d[ée]biteurs?|debtors?|Schuldner\p{L}*)\b)(?=.*\b(?:betal\p{L}*|schuldvordering|paiement|cr[ée]ance|payment|debt|Zahlung\p{L}*|Forderung\p{L}*)\b)/iu,
       /\b(?:schuldeisers?|schuldena\p{L}*|schuldvordering\p{L}*|cr[ée]anciers?|d[ée]biteurs?|cr[ée]ances?|creditors?|debtors?|debt\p{L}*|Gläubiger\p{L}*|Schuldner\p{L}*|Forderung\p{L}*)\b/iu]
    ].map(&:freeze).freeze
    # Title VIbis (Art.1701/1-19) governs digital content/services, not an
    # ordinary physical-product repair. A bare "service" is not enough to
    # make a bicycle repair a digital-content contract.
    DIGITAL_CONTENT_SERVICE_CONTEXT_PATTERN = /\b(?:digitaal\w*|digitale\w*|digital\w*|num[ée]rique\w*|software|logiciel\w*|app(?:s)?|applicatie\w*|application\w*\s+(?:mobile|informatique)|mobile\s+application|streaming\w*|streamdienst\w*|download\w*|t[ée]l[ée]charg\w*|herunterlad\w*)\b/iu.freeze
    # Ordinary warranty/refund discussion is not a buyer-payment dispute.
    # Keep the old Civil Code's price/payment duties only when the question
    # actually asks about paying, an unpaid sum or outstanding instalments.
    BUYER_PAYMENT_CONTEXT_PATTERN = /\b(?:betal\w*|betaal\w*|onbetaal\w*|achterstallig\w*|restsaldo|verschuldig\w*|payer|pay[ée]\w*|paie\w*|paiement\w*|payement\w*|impay[ée]\w*|solde\s+(?:restant|d[uû])|pay|paying|paid|payment\w*|non[\s-]?payment|unpaid|owe|owed|owing|outstanding\s+balance|balance\s+due|zahl\w*|bezahl\w*|unbezahlt\w*|schulde\w*|Restbetrag|Ratenzahlung\w*)\b/iu.freeze
    # Explicit hazard names are specialist subject evidence too. A tenant
    # need not know the legal label "algemene rampen" to ask about damage
    # from an earthquake, drought or landslide. This only admits the source;
    # its coverage and any compensation conditions still require grounding.
    NATURAL_HAZARD_QUESTION_PATTERN = %r{
      \b(?:ramp\w*|overstrom\w*|storm\w*|catastrophe\w*|inondation\w*|calamit[ée]\w*|flood\w*|disaster\w*|Naturkatastrophe\w*|Überschwemmung\w*|
          aardbev\w*|earthquake\w*|s[ée]isme\w*|tremblement\w*\s+de\s+terre|Erdbeben\w*|
          droogte\w*|drought\w*|s[ée]cheresse\w*|Dürre\w*|
          aardverschuiv\w*|grondverschuiv\w*|landslid\w*|landslip\w*|mudslide\w*|glissement\w*\s+de\s+terrain|[ée]boulement\w*|Erdrutsch\w*)\b
    }ixu.freeze
    # Official titles normally say "kalender voor het schooljaar" rather
    # than the compound "schoolkalender". Keep this bound to educational
    # years, including academic-year equivalents, not arbitrary calendars.
    EDUCATION_CALENDAR_TITLE_PATTERN = %r{
      \b(?:schoolkalender|calendrier\s+(?:scolaire|acad[ée]mique|universitaire)|(?:schul|studien)kalender|(?:school|academic)\s+calendar|
          kalender.{0,60}\b(?:(?:school|academie)j(?:aar|aren)|Schuljahr\w*|Studienjahr\w*|akademisch\w*\s+Jahr\w*)|
          calendrier.{0,60}\bann[ée]es?\s+(?:scolaire|acad[ée]mique|universitaire)s?|
          calendar.{0,60}\b(?:school|academic)(?:\s+and\s+(?:school|academic))?\s+years?)\b
    }ixu.freeze
    # This is a named public-body personnel title family, not a general
    # employment-law category. It happened to rank for a mortgage question
    # because the factual background says that a partner recently started
    # working. Keep it for an actual employment query or an explicit request
    # about the Central Council for the Economy, without turning ordinary
    # mentions of work into subject evidence.
    CENTRAL_ECONOMIC_COUNCIL_PERSONNEL_TITLE_PATTERN = %r{
      \A
      (?=.*\b(?:centrale\s+raad\s+voor\s+(?:het\s+)?bedrijfsleven|conseil\s+central\s+de\s+l['’](?:économie|economie)|central\s+economic\s+council|zentralrat\s+für\s+die\s+wirtschaft)\b)
      (?=.*\b(?:personeelsleden|personeel|personnel|staff|Mitarbeiter(?:innen)?)\b)
      (?=.*\b(?:evaluatie|évaluation|evaluation|beoordeling|loopbaan|carrière|carriere|career|Laufbahn)\b)
      .*\z
    }ixu.freeze
    CENTRAL_ECONOMIC_COUNCIL_PERSONNEL_QUERY_PATTERN = /\b(?:centrale\s+raad\s+voor\s+(?:het\s+)?bedrijfsleven|conseil\s+central\s+de\s+l['’](?:économie|economie)|central\s+economic\s+council|zentralrat\s+für\s+die\s+wirtschaft|arbeids(?:overeenkomst|contract|recht)|contrat\s+de\s+travail|droit\s+du\s+travail|employment\s+(?:contract|law)|labou?r\s+law|Arbeits(?:vertrag|recht)|werknemer\w*|werkgever\w*|employee\w*|employer\w*|employ[ée]\w*|salari[ée]\w*|loon\w*|salaris\w*|wage\w*|salary\w*|bezoldig\w*|rémunérat\w*|remunerat\w*)\b/iu.freeze
    # The 2009029098 education omnibus ranked for the mortgage question's
    # incidental employment background. Match its distinctive TWO-part title,
    # not any decree mentioning education: its retrieved Art.103 concerns
    # education-staff evaluation/priority, not purchasing or renting housing.
    EDUCATION_SPORTS_LEAVE_TITLE_PATTERN = %r{
      \A
      (?=.*\b(?:verlof\s+voor\s+sportactiviteiten|cong[ée]\s+pour\s+(?:des\s+)?activit[ée]s\s+sportives|leave\s+for\s+sport(?:ing)?\s+activities|Urlaub\s+f[üu]r\s+Sportaktivit[äa]ten)\b)
      (?=.*\b(?:diverse\s+dringende\s+maatregelen\s+inzake\s+(?:het\s+)?onderwijs|diverses\s+mesures\s+urgentes\s+en\s+mati[èe]re\s+d['’]enseignement|various\s+urgent\s+measures\s+(?:in|concerning)\s+education|verschiedene\s+dringende\s+Ma[ßs]nahmen\s+im\s+Unterrichtswesen)\b)
      .*\z
    }ixu.freeze
    EDUCATION_SPORTS_LEAVE_QUERY_PATTERN = /\b(?:onderwijs\p{L}*|school\p{L}*|leraar\p{L}*|leerkracht\p{L}*|enseignement\p{L}*|[ée]cole\p{L}*|enseignant\p{L}*|Schule\p{L}*|Unterricht\p{L}*|Lehrer\p{L}*|teacher\p{L}*|education\p{L}*|sportverlof|verlof\s+voor\s+sportactiviteiten|cong[ée]\s+pour\s+(?:des\s+)?activit[ée]s\s+sportives|leave\s+for\s+sport(?:ing)?\s+activities|Urlaub\s+f[üu]r\s+Sportaktivit[äa]ten)\b/iu.freeze
    # Specialist statutes can score highly on generic words ("bike",
    # "repair", "compensation", "employment"). A focused civil dispute
    # needs evidence of the specialist subject before such a source can
    # survive, not merely a high boosted cosine score. Each exclusion has a
    # positive query control; explicitly requested NUMACs remain available.
    CONTEXTUAL_SPECIALIST_SOURCE_GATES = [
      [Regexp.union(EDUCATION_CALENDAR_TITLE_PATTERN,
                    /\b(?:onderwijspersoneel|personeel.{0,30}(?:onderwijs|school)|personnel.{0,30}(?:enseignement|scolaire)|lehrpersonal|school\s+staff)\b/i),
       /\b(?:school|onderwijs|leraar|leerkracht|enseignement|école|enseignant|Schule|Schuljahr|Studienjahr|Lehrer|teacher|education|academi|acad[ée]mi|akademi|universit)\p{L}*\b/iu],
      [CENTRAL_ECONOMIC_COUNCIL_PERSONNEL_TITLE_PATTERN,
       CENTRAL_ECONOMIC_COUNCIL_PERSONNEL_QUERY_PATTERN],
      [EDUCATION_SPORTS_LEAVE_TITLE_PATTERN,
       EDUCATION_SPORTS_LEAVE_QUERY_PATTERN],
      # Generic words such as "notice", "period" and "leave" made lottery
      # and market-rule snippets appear beside an employment resignation
      # question.  Do not filter those domains globally: preserve them where
      # the question actually concerns gaming or securities.
      [/\b(?:kansspel\w*|loterij\w*|loterie\w*|gambling|lottery|Gl[üu]cksspiel\w*)\b/i,
       /\b(?:kansspel\w*|loterij\w*|loterie\w*|gambling|lottery|Gl[üu]cksspiel\w*)\b/i],
      [/\b(?:euronext|verrekeningsorganisme|clearing(?:house)?|effectenbeurs|beursreglement|stock\s+exchange|securities\s+market|march[eé]\s+(?:des\s+)?(?:valeurs|titres)|bourse\s+des\s+valeurs|Wertpapierb[öo]rse|B[öo]rsenreglement)\b/i,
       /\b(?:effecten(?:beurs|markt|handel)?|aandelen\w*|aandeelhouder\w*|securities|stock\s+(?:exchange|market)|financial\s+market|Euronext\s+(?:clearing|market|rules)|beurs(?:reglement|notering|handel|koers|markt)|bourse\s+(?:des\s+)?(?:valeurs|titres)|Wertpapier\w*)\b/i],
      # Official allowances for uniforms or work clothing can resemble an
      # ordinary consumer question about shoes or clothing. Keep them when
      # the user actually asks in an employment setting, rather than letting
      # a product-warranty search turn a staff allowance into a source card.
      [/\b(?:kled(?:ij|ing)\w*|uniform\w*|tenue\w*|vestiment\w*|bekleidung\w*)\b/i,
       WORKPLACE_CONTEXT_PATTERN],
      # Footwear materials and professional licensing share "schoenen" with
      # a sole-defect query, but neither establishes consumer remedies.
      [/\b(?:etikettering|[ée]tiquetage|labelling|labeling|kennzeichnung)\b.{0,100}\b(?:schoeisel|chaussures?|footwear|schuh\w*)\b/iu,
       /\b(?:etiket\w*|[ée]tiquet\w*|label\w*|kennzeich\w*|materiaalsamenstelling|composition\s+des\s+mat[ée]riaux|material\s+composition|materialzusammensetzung)\b/iu],
      [/\b(?:programma\s+van\s+het\s+examen|programme\s+de\s+l['’]examen|examination\s+syllabus|pr[üu]fungsprogramm)\b.{0,150}\b(?:bandagist\w*|orthop[ée]d\w*)\b/iu,
       /\b(?:bandagist\w*|orthop[ée]d\w*|erkenning|agr[ée]ment|licen[sc]\w*|qualification\w*|examen\w*|exam\w*|pr[üu]fung\w*|zulassung)\b/iu],
      [/\b(?:algemene\s+rampen|natuurramp\w*|catastrophes?\s+naturelles?|calamit[ée]\w*|Naturkatastrophe\w*|natural\s+disaster\w*)\b/i,
       NATURAL_HAZARD_QUESTION_PATTERN],
      [/\b(?:uit\s+de\s+handel|uit\s+de\s+markt|retrait\s+(?:du\s+march[ée]|de\s+la\s+vente)|market\s+withdrawal|Rückruf|Verkaufsverbot)\b/i,
       /\b(?:terugroep\w*|uit\s+de\s+handel|recall\w*|product\s+ban|rappel\s+(?:du\s+)?produit|retrait\s+du\s+march[ée]|Rückruf|Verkaufsverbot)\b/i],
      [/\b(?:hospital\w*|hôpital\w*|ziekenhuis\w*|beroepsziekte\w*|maladie\s+professionnelle|Berufskrankheit\w*|occupational\s+disease\w*)\b/i,
       /\b(?:medisch\w*|ziekenhuis\w*|patiënt\w*|hospital\w*|hôpital\w*|médical\w*|patient\w*|beroepsziekte\w*|maladie\s+professionnelle|Berufskrankheit\w*|occupational\s+disease\w*)\b/i],
      [/\b(?:integratie|int[ée]gration|Integration)\b.{0,60}\b(?:handicap\w*|gehandicapt\w*|Behinder\w*)\b/i,
       /\b(?:handicap\w*|gehandicapt\w*|Behinder\w*|disabilit\w*)\b/i]
    ].map(&:freeze).freeze
    ONLINE_CONSUMER_RIGHTS_PATTERN = /
      \A
      (?=.*\b(?:online|webshop|internet|op\s+afstand|afstandsovereenkomst|en\s+ligne|
                    vente\s+à\s+distance|contrat\s+à\s+distance|distance\s+(?:contract|sale)|online\s+purchase)\b)
      (?=.*\b(?:consument|consumenten|consumer|consommateur)\b)
      (?=.*\b(?:bescherming|recht(?:en)?|droits?|protection|rights?)\b)
      .*\z
    /ix
    UNEMPLOYMENT_BENEFIT_PATTERN = /
      \b(?:werkloosheidsuitkering(?:en)?|werkloosheidsvergoeding|werkloze|rva|ch[oô]mage|allocations?\s+de\s+ch[oô]mage|onem)\b
    /ix
    UNEMPLOYMENT_CONDITIONS_PATTERN = /
      \A
      (?=.*#{UNEMPLOYMENT_BENEFIT_PATTERN})
      (?=.*\b(?:voorwaarden|voorwaarde|recht\s+op|toegelaten|toelaatbaar|beroepsverleden|voorwaarden\s+voor\s+toelating|
                conditions?|droit\s+aux?|admis|admissibilit[eé]|stage)\b)
      .*\z
    /ix
    UNEMPLOYMENT_AVAILABILITY_PATTERN = /
      \A
      (?=.*#{UNEMPLOYMENT_BENEFIT_PATTERN})
      (?=.*\b(?:beschikbaar(?:heid)?|arbeidsmarkt|actief\s+zoeken|passende\s+dienstbetrekking|
                disponibilit[eé]|march[eé]\s+de\s+l['’]emploi|recherche\s+d['’]emploi|emploi\s+convenable)\b)
      .*\z
    /ix
    UNEMPLOYMENT_TRAINING_EXEMPTION_PATTERN = /
      \A
      (?=.*#{UNEMPLOYMENT_BENEFIT_PATTERN})
      (?=.*\b(?:vrijstelling|vrijgesteld|dispense|exemption)\b)
      (?=.*\b(?:opleiding|studie|studies|vorming|beroepsopleiding|formation|[eé]tudes?)\b)
      .*\z
    /ix
    UNEMPLOYMENT_FAULT_DISMISSAL_PATTERN = /
      \A
      (?=.*#{UNEMPLOYMENT_BENEFIT_PATTERN})
      (?=.*\b(?:dringende\s+reden|motif\s+grave|eigen\s+toedoen|ontslag\s+wegens\s+fout|faute|ch[oô]mage\s+volontaire)\b)
      .*\z
    /ix
    TEMPORARY_UNEMPLOYMENT_ECONOMIC_PATTERN = /
      \A
      (?=.*\b(?:tijdelijke\s+werkloosheid|ch[oô]mage\s+temporaire)\b)
      (?=.*\b(?:economisch(?:e)?|oorzaken|raisons?\s+[eé]conomiques?|[eé]conomique)\b)
      .*\z
    /ix
    TEMPORARY_UNEMPLOYMENT_FORCE_MAJEURE_PATTERN = /
      \A
      (?=.*\b(?:tijdelijke\s+werkloosheid|ch[oô]mage\s+temporaire)\b)
      (?=.*\b(?:overmacht|force\s+majeure)\b)
      .*\z
    /ix
    VAT_SMALL_ENTERPRISE_EXEMPTION_PATTERN = /
      \A
      (?=.*\b(?:btw|tva|belasting\s+over\s+de\s+toegevoegde\s+waarde|taxe\s+sur\s+la\s+valeur\s+ajout[eé]e)\b)
      (?=.*\b(?:kleine\s+onderneming(?:en)?|kleineondernemersregeling|vrijstellingsregeling|vrijstelling|franchise|petites?\s+entreprises?)\b)
      .*\z
    /ix
    ALCOHOL_DRIVING_LIMIT_PATTERN = /
      \A
      (?=.*\b(?:alcohol(?:limiet|grens)?|alcohollimiet|promille|ademanalyse|bloedanalyse|alcool|alcool[eé]mie|taux\s+d['’]?alcool)\b)
      (?=.*\b(?:bestuurders?|rijden|verkeer|wegverkeer|bloed|voertuig|conducteurs?|conduire|circulation|volant|v[eé]hicules?|route|routi[eè]re?)\b)
      .*\z
    /ix

    # Payment refusal is narrower than a generic card mention: Book VI
    # applies to payment-method acceptance, not identity/gift cards or rent terms.
    PAYMENT_INSTRUMENT_PATTERN = /\b(?:kaartbetaling|betaling\s+(?:per|met)\s+kaart|betalen\s+met\s+kaart|betaalkaart|bankkaart|creditcard|kredietkaart|credit\s+card|debit\s+card|payment\s+card|carte\s+(?:bancaire|de\s+cr[eé]dit)|carte\s+de\s+paiement|paiement\s+par\s+carte|payer\s+par\s+carte|kreditkarte|zahlungskarte)\b/i.freeze
    PAYMENT_REFUSAL_PATTERN = %r{\A
      (?!.*\b(?:cadeaukaart|gift\s+card|carte\s+(?:d['’]identité|cadeau)|identity\s+card|verhuurder|landlord|bailleur|huur(?:der|contract|woning))\b)
      (?=.*#{PAYMENT_INSTRUMENT_PATTERN})
      (?=.*\b(?:weig(?:er|eren|ert)|niet\s+aanvaard(?:en)?|niet\s+accepteren|verplicht\s+aanvaarden|moet\s+aanvaarden|refus(?:er|e)|accepter|obligatoire|refuse|accept|must\s+accept|required\s+to\s+accept|ablehnen|akzeptieren|muss\s+akzeptieren)\b)
      .*\z}ix.freeze
    CASH_PAYMENT_PATTERN = %r{\A
      (?!.*\b(?:verhuurder|landlord|bailleur|huur(?:der|contract|woning))\b)
      (?=.*\b(?:cash|contant(?:e)?|esp[eè]ces|bar|bargeld)\b)
      (?=.*\b(?:weig(?:er|eren|ert)|aanvaard(?:en)?|accepteren|verplicht|refus(?:er|e)|accepter|obligatoire|refuse|accept|must\s+accept|required|ablehnen|akzeptieren)\b)
      .*\z}ix.freeze
    POLICE_CUSTODY_DURATION_PATTERN = %r{
      (?=.*\b(?:garde\s+[àa]\s+vue|politiearrest|police\s+custody|polizeigewahrsam)\b)
      (?=.*\b(?:hoe\s+lang|hoelang|duur|termijn|combien\s+de\s+temps|dur[eé]e|how\s+long|duration|wie\s+lange|dauer)\b)
    }ix.freeze
    # An employee asking whether they may resign while ill, or whether illness
    # changes their notice period, needs the notice-form rule and the
    # suspension rule together.  The older individual pins knew Dutch and
    # French notice vocabulary, but missed the ordinary English "job
    # resignation" / "sick leave" formulation (and its German equivalent).
    # Keep the three concepts conjunctive: health, a termination/notice, and
    # an employment setting.  That avoids treating a sick tenant or a sports
    # club member as an employment-contract question.
    EMPLOYMENT_NOTICE_SICKNESS_PATTERN = %r{
      \A
      (?=.*\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|tewerkstelling|job|werk(?:nemer|gever|plek)?|contrat\s+de\s+travail|travailleur|employeur|salari[ée]e?s?|emploi|employee|employer|employment(?:\s+contract)?|job|work(?:place|er)?|Arbeitsvertrag|Arbeitnehmer|Arbeitgeber|Arbeitsplatz|Beschäftigung)\b)
      (?=.*\b(?:ontslag|opzeg(?:ging|termijn|brief)?|d[eé]mission(?:ner)?|pr[eé]avis|licenciement|resign(?:ation)?|notice(?:\s+period)?|dismissal|termination|k[üu]ndig(?:en|ung|ungsfrist)?|Entlassung)\b)
      (?=.*\b(?:ziek\w*|ziekteverlof|arbeidsongeschikt\w*|malad(?:e|ie)?|incapacit[eé]\s+de\s+travail|cong[eé]\s+de\s+maladie|sick(?:\s+leave)?|illness|medical\s+leave|krank\w*|Krankschreibung|Arbeitsunf[aä]hig\w*)\b)
      .*\z
    }imxu.freeze
    # Urgent medical aid (dringende medische hulp, aide médicale urgente) is
    # the one help an OCMW still owes an alien who stays illegally (Art. 57,
    # § 2, 1° of the OCMW Act); the KB of 12 December 1996 defines it (Art. 1)
    # and has the State reimburse it (Art. 2). 2026-10-14: the catalogue
    # question "Wat is dringende medische hulp?" retrieved the decrees of the
    # Brussels fire and ambulance service (Dienst voor Brandweer en Dringende
    # Medische Hulp) and the 1964 ambulance Act instead; the answer cited
    # Art. 57 without its text, and the citation guard replaced it with the
    # list of consulted sources. The phrase has other senses: that Brussels
    # service, in French the 112 regime of the Law of 8 July 1964 ("loi
    # relative à l'aide médicale urgente", in Dutch "dringende geneeskundige
    # hulpverlening"), and care abroad. So the pins need the OCMW or residence
    # sense in the question, or a question that asks no more than what the
    # term means (the catalogue's wording in all four languages); any other
    # question keeps ordinary retrieval. Boundaries are [[:alnum:]], not \b
    # and \w, which stop at "é" and "ä".
    URGENT_MEDICAL_AID_TERM_PATTERN = %r{
      (?<![[:alnum:]])(?:
        dringende\s+medische\s+(?:hulp|hulpverlening|zorg|bijstand)|
        aide\s+m[ée]dicale\s+urgente|
        dringender?\s+medizinischer?\s+hilfe|
        urgent\s+medical\s+(?:aid|assistance|help)
      )(?![[:alnum:]])
    }ix.freeze
    URGENT_MEDICAL_AID_CONTEXT_PATTERN = %r{
      (?<![[:alnum:]])(?:
        ocmw[[:alpha:]]*|cpas|öshz|sozialhilfezentr[[:alpha:]]*|pcsw|
        leefloon|maatschappelijke\s+(?:dienstverlening|hulp|integratie)|aide\s+sociale|
        revenu\s+d['’]int[ée]gration|sozialhilfe|social\s+(?:assistance|welfare)|
        ill[ée]ga[[:alpha:]]*|onwettig[[:alpha:]]*|irr[ée]gul[[:alpha:]]*|
        zonder\s+(?:wettig\s+)?(?:verblijf[[:alpha:]]*|papieren)|sans[\s-]papiers?|
        ohne\s+(?:papiere|aufenthalt[[:alpha:]]*)|undocumented|without\s+(?:papers|(?:a\s+)?residence[[:alpha:]]*)|
        vreemdeling[[:alpha:]]*|ausländer[[:alpha:]]*|asiel[[:alpha:]]*|asile|asyl[[:alpha:]]*|
        medisch[[:alpha:]]*\s+(?:attest|getuigschrift)|certificat\s+m[ée]dical|
        ärztlich[[:alpha:]]*\s+bescheinigung|medical\s+certificate|medische\s+kaart|carte\s+m[ée]dicale
      )(?![[:alnum:]])
    }ix.freeze
    URGENT_MEDICAL_AID_DEFINITION_PATTERN = %r{
      \A[[:space:][:punct:]]*
      (?:
        wat\s+(?:is|betekent|houdt)|
        qu['’]\s*est[\s-]+ce\s+qu(?:e|['’])|c['’]\s*est\s+quoi|que\s+(?:signifie|recouvre|couvre|comprend)|
        was\s+(?:ist|bedeutet|umfasst)|
        what\s+(?:is|does)
      )
      \s*(?:precies\s+|eigenlijk\s+|juridisch\s+)?
      (?:de\s+|een\s+|l['’]\s*|la\s+|une?\s+|die\s+|eine\s+|an?\s+|the\s+)?
      #{URGENT_MEDICAL_AID_TERM_PATTERN}
      (?:\s+(?:in|precies|eigenlijk|juridisch(?:\s+gezien)?|in\s+belgi[eë]|en\s+belgique|in\s+belgien|in\s+belgium|mean|cover))?
      [[:space:][:punct:]]*\z
    }ix.freeze
    URGENT_MEDICAL_AID_PATTERN = %r{
      \A(?=.*#{URGENT_MEDICAL_AID_TERM_PATTERN})
      (?:(?=.*#{URGENT_MEDICAL_AID_CONTEXT_PATTERN})|(?=#{URGENT_MEDICAL_AID_DEFINITION_PATTERN}))
    }imx.freeze
    # A company's minimum capital: the BV has none since the WVV (Art. 5:1),
    # its founders owe sufficient initial equity (Art. 5:3) and a financial
    # plan (Art. 5:4); the NV keeps 61 500 euro (Art. 7:2). 2026-10-14: "Hoeveel
    # startkapitaal heb ik nodig voor een BV?" retrieved no WVV article in 6
    # of 6 evaluated runs, so the answer stood on the prompt alone and its
    # quotes were dropped as unverifiable. A named form (or, for a plain
    # "vennootschap", a question that asks how much is needed) is required: a
    # capital increase or reduction (Art. 5:120 ff., 7:177 ff.), capital gains,
    # and an insurer's or a pension's capital keep ordinary retrieval.
    COMPANY_CAPITAL_TERM_PATTERN = %r{
      (?<![[:alnum:]])(?:[[:alpha:]]*kapita(?:al|l)|capital|capitaux\s+propres|fonds\s+propres|aanvangsvermogen|eigen\s+vermogen)(?![[:alnum:]])
    }ix.freeze
    COMPANY_CAPITAL_EXCLUDED_PATTERN = %r{
      kapitaal(?:s)?(?:verhoging|vermindering)|(?:verhoging|vermindering)\s+van\s+(?:het\s+)?kapitaal|
      (?:augmentation|r[ée]duction)\s+(?:de\s+|du\s+)?capital|capital\s+(?:increase|reduction|gains?)|
      kapital(?:erh[öo]hung|herabsetzung)|plus-values?|meerwaarde
    }ix.freeze
    BV_FORM_PATTERN = %r{
      (?<![[:alnum:]])(?:bv(?:ba)?|besloten\s+vennootschap|srl|sprl|soci[ée]t[ée]\s+[àa]\s+responsabilit[ée]\s+limit[ée]e|gmbh)(?![[:alnum:]])
    }ix.freeze
    NV_FORM_PATTERN = %r{
      (?<![[:alnum:]])(?:nv|naamloze\s+vennootschap|soci[ée]t[ée]\s+anonyme|aktiengesellschaft|(?-i:SA|AG))(?![[:alnum:]])
    }ix.freeze
    GENERIC_COMPANY_CAPITAL_PATTERN = %r{
      \A(?=.*(?<![[:alnum:]])(?:vennootschap(?:pen)?|soci[ée]t[ée]s?|gesellschaft(?:en)?|compan(?:y|ies))(?![[:alnum:]]))
      (?=.*(?:minimum|minimal|mindest|start|hoeveel|combien|how\s+much|wie\s+viel|nodig|vereist|requis|faut|need|required))
    }ix.freeze
    MINIMUM_CAPITAL_BV_PATTERN = %r{
      \A(?=.*#{COMPANY_CAPITAL_TERM_PATTERN})(?!.*#{COMPANY_CAPITAL_EXCLUDED_PATTERN})
      (?:(?=.*#{BV_FORM_PATTERN})|(?=#{GENERIC_COMPANY_CAPITAL_PATTERN})(?!.*#{NV_FORM_PATTERN}))
    }imx.freeze
    MINIMUM_CAPITAL_NV_PATTERN = %r{
      \A(?=.*#{COMPANY_CAPITAL_TERM_PATTERN})(?!.*#{COMPANY_CAPITAL_EXCLUDED_PATTERN})
      (?:(?=.*#{NV_FORM_PATTERN})|(?=#{GENERIC_COMPANY_CAPITAL_PATTERN})(?!.*#{BV_FORM_PATTERN}))
    }imx.freeze

    ARTICLE_PINS = [
      # Criminal / civil procedure
      [LEGACY_CRIMINAL_FACT_PATTERN,                                  '2024002052', '2'],        # Book I: more-favourable-law transition
      [HISTORICAL_THEFT_PATTERN,                                      '1867060850', '461'],      # 1867 Code: historical theft definition
      [HISTORICAL_THEFT_PATTERN,                                      '1867060850', '463'],      # 1867 Code: historical simple-theft penalty
      [HISTORICAL_STALKING_PATTERN,                                   '1867060850', '442bis'],   # 1867 Code: historical stalking provision
      [/\bbelaging\b|\bstalking\b|belaag[dt]|\bbelagen\b/i,        '2024002088', '237'],      # Strafwetboek Boek II
      [/(?:\b(?:verjarings?termijn|verjaring|verjaren|verjaart|verjaarde|verjaard)\b.{0,60}\b(?:strafvordering|misdrij(?:f|ven)|wanbedrijf|overtreding|diefstal|oplichting|strafzaak|strafrecht|drugsbezit|drugshandel|drugsdelict)\b|\b(?:strafvordering|misdrij(?:f|ven)|wanbedrijf|overtreding|diefstal|oplichting|strafzaak|strafrecht|drugsbezit|drugshandel|drugsdelict)\b.{0,60}\b(?:verjarings?termijn|verjaring|verjaren|verjaart|verjaarde|verjaard)\b)/i, '1878041750', '21'], # V.T.Sv. criminal prescription
      [/(?:\b(?:verjarings?termijn|verjaring|verjaren|verjaart|verjaarde|verjaard)\b.{0,60}\b(?:factuur|schuld|vordering|contract|aansprakelijkheid|schadevergoeding|betaling|burgerlijk|civiel)\b|\b(?:factuur|schuld|vordering|contract|aansprakelijkheid|schadevergoeding|betaling|burgerlijk|civiel)\b.{0,60}\b(?:verjarings?termijn|verjaring|verjaren|verjaart|verjaarde|verjaard)\b)/i, '1804032155', '2262bis'], # oud BW civil prescription
      [/(?:\b(?:verjarings?termijn|verjaring|verjaren|verjaart|verjaarde|verjaard)\b.{0,60}\b(?:factuur|schuld|vordering|contract|betaling|periodieke\s+schuld)\b|\b(?:factuur|schuld|vordering|contract|betaling|periodieke\s+schuld)\b.{0,60}\b(?:verjarings?termijn|verjaring|verjaren|verjaart|verjaarde|verjaard)\b)/i, '1804032155', '2277'], # old BW special short prescription candidates
      [/beslagvrije\s*som|loonbeslag|voor\s*beslag\s*vatbaar/i,       '1967101056', '1409'],     # Ger.W. Part V
      [/\b(?:kort\s+geding|référé|einstweilige\s+verfügung)\b/i,       '1967101054', '584'],      # Ger.W. Part III
      [/\A(?!.*\b(?:straf\w*|misdrijf|beklaagde|veroordeelde|correctioneel|pénal\w*|prévenu|condamné)\b)(?=.*(?:\btermijn\b.*\bhoger\s*beroep\b|\bhoger\s*beroep\b.*\btermijn\b|\bdélai\b.*\bappel\b|\bappel\b.*\bdélai\b)).*\z/im, '1967101055', '1051'], # civil appeal only
      [/(?=.*\b(?:minnelijke\s+schikking|verval\s+van\s+strafvordering|transaction\s+pénale)\b)(?=.*\b(?:straf|misdrijf|parket|procureur|pénal|infraction|ministère\s+public)\b)/i, '1808111901', '216bis'],
      [/(?:\bsalduz\b|(?=.*\b(?:verhoor|politieverhoor|ondervraging|audition|interrogatoire)\b)(?=.*\b(?:advocaat|rechtsbijstand|rechten|avocat|assistance|droits)\b))/i, '1808111701', '47bis'],
      [POLICE_CUSTODY_DURATION_PATTERN, '1990099963', '1'],
      [/\b(?:burgerlijke\s+partijstelling|zich\s+burgerlijke\s+partij\s+stellen|constitution\s+de\s+partie\s+civile)\b/i, '1808111701', '63'],
      [/\b(?:diefstal|stelen|gestolen)\b|\b(?:le|du|au|un|ce|des|pour)\s+vol\b|\bvol\s+(?:simple|qualifi[eé]|avec|commis|constitue|puni|passible)\b/i, '2024002088', '463'],
      [/(?=.*(?:\b(?:diefstal|stelen|gestolen)\b|\b(?:le|du|au|un|ce|des|pour)\s+vol\b|\bvol\s+(?:simple|qualifi[eé]|avec|commis|constitue|puni|passible)\b))(?=.*\b(?:straf|bestraft|gevangenis|boete|peine)\b)/i, '2024002088', '465'],
      [/(?=.*(?:\b(?:diefstal|stelen|gestolen|inbraak)\b|\b(?:le|du|au|un|ce|des|pour)\s+vol\b|\bvol\s+(?:simple|qualifi[eé]|commis|constitue|puni|passible)\b))(?=.*\b(?:braak|inklimming|valse\s+sleutel|effraction|escalade|nacht|nuit)\b)/i, '2024002088', '466'],
      [/(?=.*(?:\b(?:diefstal|stelen|gestolen)\b|\b(?:le|du|au|un|ce|des|pour)\s+vol\b|\bvol\s+(?:avec|violence|menace)\b))(?=.*\b(?:geweld|bedreiging|violence|menace)\b)/i, '2024002088', '467'],
      [/(?=.*\b(?:rechtspersoon|rechtspersonen|personne\s+morale|legal\s+person)\b)(?=.*\b(?:strafrechtelijk|pénal\w*|criminal\w*|aansprakelijk\w*|responsab\w*|liab\w*)\b)/i, '1867060850', '5'],
      [/\bdwangsom\b/i,                                                '1967101055', '1385bis'],  # Ger.W. Part IV

      # Formation deeds are form-dependent. Put the common rule and each
      # form's filing/extract provision first: the low-reasoning context keeps
      # only five articles, so company-only ordering would silently exclude
      # associations and foundations. Explicit forms get their complete triple.
      [FORMATION_DEED_GENERIC_PATTERN,                                 '2019A40586', '2:5'],
      [FORMATION_DEED_GENERIC_PATTERN,                                 '2019A40586', '2:8'],
      [FORMATION_DEED_GENERIC_PATTERN,                                 '2019A40586', '2:9'],
      [FORMATION_DEED_GENERIC_PATTERN,                                 '2019A40586', '2:10'],
      [FORMATION_DEED_GENERIC_PATTERN,                                 '2019A40586', '2:11'],
      [FORMATION_DEED_GENERIC_PATTERN,                                 '2019A40586', '5:12'],
      [FORMATION_DEED_GENERIC_PATTERN,                                 '2019A40586', '6:13'],
      [FORMATION_DEED_GENERIC_PATTERN,                                 '2019A40586', '7:14'],
      [FORMATION_DEED_GENERIC_PATTERN,                                 '2019A40586', '9:2'],
      [FORMATION_DEED_GENERIC_PATTERN,                                 '2019A40586', '10:2'],
      [FORMATION_DEED_GENERIC_PATTERN,                                 '2019A40586', '11:2'],
      [FORMATION_DEED_PATTERN,                                         '2019A40586', '2:5'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:bv(?:ba)?|besloten\s+vennootschap|srl)\b)/i, '2019A40586', '2:8'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:bv(?:ba)?|besloten\s+vennootschap|srl)\b)/i, '2019A40586', '5:12'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:bv(?:ba)?|besloten\s+vennootschap|srl)\b)/i, '2019A40586', '5:1'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:bv(?:ba)?|besloten\s+vennootschap|srl)\b)/i, '2019A40586', '5:3'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:bv(?:ba)?|besloten\s+vennootschap|srl)\b)/i, '2019A40586', '5:5'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:bv(?:ba)?|besloten\s+vennootschap|srl)\b)/i, '2019A40586', '5:8'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:bv(?:ba)?|besloten\s+vennootschap|srl)\b)/i, '2019A40586', '5:9'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:cv(?:ba)?|coöperatieve\s+vennootschap|société\s+coopérative|coopérative|(?-i:SC))\b)/i, '2019A40586', '2:8'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:cv(?:ba)?|coöperatieve\s+vennootschap|société\s+coopérative|coopérative|(?-i:SC))\b)/i, '2019A40586', '6:13'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:cv(?:ba)?|coöperatieve\s+vennootschap|société\s+coopérative|coopérative|(?-i:SC))\b)/i, '2019A40586', '6:1'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:cv(?:ba)?|coöperatieve\s+vennootschap|société\s+coopérative|coopérative|(?-i:SC))\b)/i, '2019A40586', '6:4'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:cv(?:ba)?|coöperatieve\s+vennootschap|société\s+coopérative|coopérative|(?-i:SC))\b)/i, '2019A40586', '6:6'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:cv(?:ba)?|coöperatieve\s+vennootschap|société\s+coopérative|coopérative|(?-i:SC))\b)/i, '2019A40586', '6:9'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:cv(?:ba)?|coöperatieve\s+vennootschap|société\s+coopérative|coopérative|(?-i:SC))\b)/i, '2019A40586', '6:10'],
      # Keep French ``sa`` ("its") from being mistaken for the SA legal form;
      # an abbreviated SA must be explicitly capitalised.
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:nv|naamloze\s+vennootschap|société\s+anonyme|(?-i:SA))\b)/i, '2019A40586', '2:8'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:nv|naamloze\s+vennootschap|société\s+anonyme|(?-i:SA))\b)/i, '2019A40586', '7:14'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:nv|naamloze\s+vennootschap|société\s+anonyme|(?-i:SA))\b)/i, '2019A40586', '7:2'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:nv|naamloze\s+vennootschap|société\s+anonyme|(?-i:SA))\b)/i, '2019A40586', '7:4'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:nv|naamloze\s+vennootschap|société\s+anonyme|(?-i:SA))\b)/i, '2019A40586', '7:11'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:nv|naamloze\s+vennootschap|société\s+anonyme|(?-i:SA))\b)/i, '2019A40586', '7:12'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:nv|naamloze\s+vennootschap|société\s+anonyme|(?-i:SA))\b)/i, '2019A40586', '7:22'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:vzw|vereniging\s+zonder\s+winstoogmerk|asbl)\b)/i, '2019A40586', '2:9'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:vzw|vereniging\s+zonder\s+winstoogmerk|asbl)\b)/i, '2019A40586', '9:2'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:ivzw|internationale\s+vereniging|aisbl)\b)/i, '2019A40586', '2:10'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:ivzw|internationale\s+vereniging|aisbl)\b)/i, '2019A40586', '10:2'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:stichting|fondation)\b)/i, '2019A40586', '2:11'],
      [/(?=.*#{FORMATION_DEED_PATTERN.source})(?=.*\b(?:stichting|fondation)\b)/i, '2019A40586', '11:2'],

      # Constitution: narrow rights/concept phrases only.
      [/\b(?:betog(?:en|ing)|vrijheid\s+van\s+vergadering|manifest(?:er|ation)|liberté\s+de\s+réunion)\b/i, '1994021048', '26'],
      [/(?=.*\b(?:godsdienst(?:vrijheid)?|eredienst|religion|culte)\b)(?=.*\b(?:grondwet(?:telijk)?|vrijheid|recht|constitution(?:nel)?|liberté|droit)\b)/i, '1994021048', '19'],
      [/(?=.*\b(?:godsdienst(?:vrijheid)?|eredienst|religion|culte)\b)(?=.*\b(?:grondwet(?:telijk)?|vrijheid|recht|constitution(?:nel)?|liberté|droit)\b)/i, '1994021048', '20'],
      [/(?=.*\b(?:godsdienst(?:vrijheid)?|eredienst|religion|culte)\b)(?=.*\b(?:grondwet(?:telijk)?|vrijheid|recht|constitution(?:nel)?|liberté|droit)\b)/i, '1994021048', '21'],
      [/(?=.*\b(?:bestuursdocumenten|documenten\s+van\s+het\s+bestuur|documents?\s+administratifs?)\b)(?=.*\b(?:openbaarheid|inzage|raadplegen|publicité|consulter|accès)\b)/i, '1994021048', '32'],
      [/(?=.*\b(?:onteigening|expropriation)\b)(?=.*\b(?:schadeloosstelling|vergoeding|indemnité|indemnisation)\b)/i, '1994021048', '16'],
      [/\b(?:grondwettelijk\s+hof|cour\s+constitutionnelle|verfassungsgerichtshof)\b/i, '1994021048', '142'],

      # Lay-term aliases (decision D, docs/ops/withheld-answers-2026-08-04.md,
      # measured against config/quality/retrieval_recall_fixture_v1.json):
      # the user's everyday word appears nowhere in the official title the
      # index embeds, so the governing law never surfaced. Pins are additive
      # and floor-proof, so a wrong match adds one law to context rather than
      # displacing anything.
      [/\bgroepsverzekering(?:en)?\b|\bassurance[\s\-]groupes?\b/i, '2003022481', '2'],   # WAP: doel/toepassingsgebied
      [/\bgroepsverzekering(?:en)?\b|\bassurance[\s\-]groupes?\b/i, '2003022481', '3'],   # WAP: definities (incl. groepsverzekering)
      [/\bsociaal\s+strafwetboek\b|\bcode\s+p[eé]nal\s+social\b/i,  '2010A09589', '1'],   # the code names itself; the 2024 Strafwetboek otherwise dominates
      # Pop-up rent is regional. Reserve the existing Flemish pins for a
      # solely Flemish question: an unqualified overview or a comparison
      # must not start with a score-99 instruction to apply Flemish law.
      [/\A(?=.*#{FLANDERS_REGION_PATTERN})(?!.*#{BRUSSELS_WALLONIA_REGION_PATTERN})(?=.*#{SHORT_COMMERCIAL_SUBJECT_PATTERN})/imu, '2016036108', '2'],
      [/\A(?=.*#{FLANDERS_REGION_PATTERN})(?!.*#{BRUSSELS_WALLONIA_REGION_PATTERN})(?=.*#{SHORT_COMMERCIAL_SUBJECT_PATTERN})/imu, '2016036108', '3'],

      # Coordinated compulsory health-insurance law (ZIV/AMI). These pins are
      # intentionally concept-specific; exact tariffs and nomenclature remain
      # outside the statute and must still be hedged by the answer model.
      [HEALTH_INSURANCE_OVERVIEW_PATTERN, '1994071451', '34'],
      [HEALTH_INSURANCE_OVERVIEW_PATTERN, '1994071451', '35'],
      [/\b(?:remgeld|persoonlijk\s+aandeel|ticket\s+modérateur)\b/i, '1994071451', '37'],
      [/\b(?:maximumfactuur|maximumfactuurregeling|\bmaf\b)\b/i, '1994071451', '37octies'],
      [/\b(?:derdebetalersregeling|tiers\s+payant)\b/i, '1994071451', '53'],
      [/\b(?:geconventioneerde?\s+arts|médecin\s+conventionné)\b/i, '1994071451', '50'],
      [/\b(?:arbeidsongeschiktheidsuitkering|primaire\s+arbeidsongeschiktheid)\b/i, '1994071451', '87'],
      [/(?=.*\b(?:invaliditeit|invaliditeitsuitkering)\b)(?=.*\b(?:ziekte|arbeidsongeschiktheid|uitkering|mutualiteit|ziekenfonds|riziv|ziv)\b)/i, '1994071451', '93'],
      [/\b(?:progressieve\s+werkhervatting|progressie(?:f|ve)\s+(?:het\s+)?werk\s+hervat\w*|toegelaten\s+arbeid|halftijds\s+werken\s+tijdens\s+arbeidsongeschiktheid)\b/i, '1994071451', '100'],
      [/\b(?:moederschapsuitkering|uitkering\b.{0,40}\bmoederschapsrust|moederschapsrust\b.{0,40}\buitkering)\b/i, '1994071451', '112'],
      [/(?=.*\b(?:aansluiten|aansluiting|aangesloten|verplicht)\b)(?=.*\b(?:ziekenfonds|mutualiteit|ziekteverzekering)\b)/i, '1994071451', '118'],
      [/\b(?:geneesmiddel(?:en)?|medicijn(?:en)?|farmaceutische\s+specialiteit).{0,50}\bterugbeta(?:l|al)\w*\b|\bterugbeta(?:l|al)\w*.{0,50}\b(?:geneesmiddel(?:en)?|medicijn(?:en)?|farmaceutische\s+specialiteit)\b/i, '1994071451', '35bis'],
      [/\b(?:verhoogde\s+tegemoetkoming|bim-statuut|omnio)\b/i, '1994071451', '37'],
      [/\b(?:voorschrijven\s+op\s+stofnaam|voorschrift\s+op\s+stofnaam|international\s+nonproprietary\s+name)\b/i, '1994071451', '73'],

      # Arbeidsovereenkomstenwet (AOW): high-confidence diagnosis cluster.
      [/\b(?:minimumloon|ggmmi|gewaarborgd\s+gemiddeld\s+minimum(?:maand)?inkomen|salaire\s+minimum|rmmmg|revenu\s+minimum\s+mensuel\s+moyen)\b/i, '1988050250', '3'],
      [/\b(?:minimumloon|ggmmi|gewaarborgd\s+gemiddeld\s+minimum(?:maand)?inkomen|salaire\s+minimum|rmmmg|revenu\s+minimum\s+mensuel\s+moyen)\b/i, '1988050250', '5'],
      [/\b(?:ius\s+variandi|eenzijdige?\s+(?:wijziging|wijzigen)\s+(?:van\s+)?(?:arbeidsvoorwaarden|arbeidsovereenkomst|loon|functie)|(?:loon|salaris)\s+eenzijdige?\s+(?:verlagen|verminderen|wijzigen)|eenzijdige?\s+(?:loon|salaris)\s+(?:verlagen|verminderen|wijzigen))\b/i, '1978070303', '25'],
      [EMPLOYMENT_NON_COMPETE_PATTERN, '1978070303', '65'],
      [EMPLOYMENT_NON_COMPETE_PATTERN, '1978070303', '86'],
      [PARALLEL_EMPLOYMENT_PATTERN, '2022206298', '20'],
      [PARALLEL_EMPLOYMENT_PATTERN, '1978070303', '17'],
      [EMPLOYMENT_OFFER_REVIEW_PATTERN, '1978070303', '3'],
      [EMPLOYMENT_OFFER_REVIEW_PATTERN, '1978070303', '9'],
      [EMPLOYMENT_OFFER_REVIEW_PATTERN, '1978070303', '17'],
      [EMPLOYMENT_OFFER_REVIEW_PATTERN, '1978070303', '20'],
      # Resigning while ill asks two distinct questions: whether notice can be
      # served (Art. 37) and whether sickness suspends/extends that notice
      # (Art. 38).  Keep these precise instead of promoting medical-certificate
      # or guaranteed-pay provisions merely because the question says "sick".
      [EMPLOYMENT_NOTICE_SICKNESS_PATTERN, '1978070303', '37'],
      [EMPLOYMENT_NOTICE_SICKNESS_PATTERN, '1978070303', '38'],
      [/(?:\b(?:handelsvertegenwoordiger|représentant\s+de\s+commerce)\b.{0,80}\b(?:niet[-\s]?)?concurrentiebeding\b|\b(?:niet[-\s]?)?concurrentiebeding\b.{0,80}\b(?:handelsvertegenwoordiger|représentant\s+de\s+commerce)\b)/i, '1978070303', '104'],
      [/(?=.*\b(?:geheimhoudingsbeding|vertrouwelijkheidsbeding|geheimhoudingsplicht|vertrouwelijkheidsplicht|discretieplicht|clause\s+de\s+confidentialité)\b)(?=.*\b(?:werknemer|werkgever|arbeidsovereenkomst|arbeidscontract|tewerkstelling|travailleur|employeur|contrat\s+de\s+travail)\b)/i, '1978070303', '17'],
      [/(?:scholingsbeding|opleidingsbeding|clause\s+d[’']écolage)/i,   '1978070303', '22bis'],
      [/(?:deeltijds(?:e)?\s+(?:arbeids)?overeenkomst|arbeidsovereenkomst.{0,30}deeltijd)/i, '1978070303', '11bis'],
      [/\bvervangingsovereenkomst\b|contrat\s+de\s+remplacement/i,   '1978070303', '11ter'],
      [/(?=.*\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|tewerkstelling|job|contrat\s+de\s+travail|travailleur|employeur)\b)(?=.*(?:\b(?:opeenvolgende|successieve)\b.{0,50}\b(?:arbeids?)?overeenkomsten\b|\b(?:maximumduur|duur)\b.{0,40}\b(?:bepaalde\s+tijd|durée\s+déterminée)\b))/i, '1978070303', '10'],
      [/(?=.*\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|tewerkstelling|job|contrat\s+de\s+travail|travailleur|employeur)\b)(?=.*(?:\b(?:opeenvolgende|successieve)\b.{0,50}\b(?:arbeids?)?overeenkomsten\b|\b(?:maximumduur|duur)\b.{0,40}\b(?:bepaalde\s+tijd|durée\s+déterminée)\b))/i, '1978070303', '10bis'],
      [/(?=.*\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|tewerkstelling|job|contrat\s+de\s+travail|travailleur|employeur)\b)(?=.*\b(?:ontslag|opzeg(?:ging|brief)|licenciement|préavis)\b)(?=.*\b(?:schriftelijk|aangetekend|deurwaarder|kennisgeving|écrit|recommandé|huissier|notification)\b)/i, '1978070303', '37'],
      [/(?=.*\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|tewerkstelling|job|contrat\s+de\s+travail|travailleur|employeur)\b)(?=.*\b(?:begin(?:nen|t)?|ingang|start|commenc|début)\w*\b)(?=.*\b(?:opzeg(?:termijn|\s+termijn)|préavis)\b)/i, '1978070303', '37/1'],
      [/(?:opzeg|ontslag).{0,50}anci[eë]nniteit|anci[eë]nniteit.{0,50}(?:opzeg|ontslag)/i, '1978070303', '37/4'],
      [/\btegenopzeg\b|(?=.*\bopzeg(?:termijn|\s+termijn)\b)(?=.*\b(?:bereken(?:en|ing)?|hoeveel|anci[eë]nniteit|weken?|jaren?)\b)(?=.*\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|ontslag|tewerkstelling)\b)/i, '1978070303', '37/2'],
      [/\A(?=.*\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|tewerkstelling|job|ontslag|contrat\s+de\s+travail|travailleur|employeur|licenciement)\b)(?=.*\b(?:opzeg(?:termijn|ging)|préavis)\b)(?=.*\b(?:schors\w*|suspend\w*|vakantie|ziekte|congé|maladie)\b).*\z/im, '1978070303', '38'],
      [/(?=.*\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|tewerkstelling|job|ontslag|contrat\s+de\s+travail|travailleur|employeur|licenciement)\b)(?:opzeg(?:gings)?vergoeding|verbrekingsvergoeding|vergoeding.{0,30}verbreking|indemnité.{0,30}(?:préavis|rupture))/i, '1978070303', '39'],
      [/(?:sollicitatieverlof|wederindiensttredingsverlof|congé\s+pour\s+chercher\s+un\s+emploi)/i, '1978070303', '41'],
      [/\b(?:controlearts|controlegeneesheer)\b|\b(?:medisch(?:e)?\s+(?:attest|getuigschrift)|ziekteattest)\b.*\b(?:werkgever|werknemer|ziekte|arbeidsongeschiktheid)\b|\b(?:werkgever|werknemer|ziekte|arbeidsongeschiktheid)\b.*\b(?:medisch(?:e)?\s+(?:attest|getuigschrift)|ziekteattest)\b|certificat\s+médical.*\b(?:employeur|travailleur|maladie|incapacité)\b/i, '1978070303', '31'],
      [/\bmedische\s+overmacht\b/i,                                '1978070303', '34'],
      [/\A(?=.*\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|tewerkstelling|job|ontslag|contrat\s+de\s+travail|travailleur|employeur|licenciement)\b)(?=.*\b(?:dringende\s+reden|motif\s+grave)\b).*\z/im, '1978070303', '35'],
      [TEMPORARY_UNEMPLOYMENT_FORCE_MAJEURE_PATTERN, '1978070303', '26'],
      [TEMPORARY_UNEMPLOYMENT_ECONOMIC_PATTERN, '1978070303', '51'],
      [TEMPORARY_UNEMPLOYMENT_ECONOMIC_PATTERN, '1978070303', '77/1'],
      [/(?:verlof\s+om\s+dwingende\s+redenen|congé\s+pour\s+raisons\s+impérieuses)/i, '1978070303', '30bis'],
      [/(?:adoptieverlof|congé\s+d[’']adoption)/i,                     '1978070303', '30ter'],
      [/(?:pleegzorgverlof|congé\s+d[’']accueil)/i,                    '1978070303', '30quater'],
      [/(?:pleegouderverlof|congé\s+parental\s+d[’']accueil)/i,       '1978070303', '30sexies'],
      [/(?:studenten(?:contract|overeenkomst|arbeid)|jobstudent|contrat\s+d[’']étudiant)/i, '1978070303', '120'],
      [/(?:student(?:en)?(?:contract|overeenkomst).{0,30}(?:proef|proeftijd)|(?:proef|proeftijd).{0,30}student)/i, '1978070303', '127'],
      [/\b(?:proefperiode|proeftijd)\b/i, '1978070303', '127'],
      [/\b(?:proefperiode|proeftijd)\b/i, '1987012597', '5'],
      [/(?:student(?:en)?(?:contract|overeenkomst).{0,30}(?:opzeg|beëindig)|(?:opzeg|beëindig).{0,30}student)/i, '1978070303', '130'],
      [/\bwillekeurige\s+afdanking\b/i,                              '1978070303', '63'],
      # Classification turns on authority/subordination. Pin the statutory
      # employment definition so a comparison with an independent contractor
      # cannot be built from unrelated termination provisions.
      [/(?=.*\b(?:arbeidsovereenkomst|arbeidscontract)\b)(?=.*\b(?:aannemingsovereenkomst|aannemer|zelfstandig(?:e)?|ondergeschiktheid|gezag)\b)/i, '1978070303', '2'],
      [/(?=.*\b(?:arbeidsovereenkomst|arbeidscontract)\b)(?=.*\b(?:aannemingsovereenkomst|aannemer|zelfstandig(?:e)?|ondergeschiktheid|gezag)\b)/i, '1978070303', '3'],

      # Arbeidswet 1971
      [/(?:zondags(?:rust|arbeid|werk)|travail\s+du\s+dimanche)/i,    '1971031602', '11'],
      [/\b(?:arbeidsduur|maximale?\s+(?:werk|arbeids)uren|hoeveel\s+uur\s+(?:mag|kan)\s+(?:ik|een\s+werknemer)\s+werken|38[-\s]?urenweek)\b/i, '1971031602', '19'],
      [/(?:glijdende\s+(?:werktijd|uurroosters?)|glijtijd|horaires?\s+flexibles?)/i, '1971031602', '20ter'],
      [/\b(?:annualisering|referteperiode)\b.*\b(?:arbeidsduur|werkuren|overuren)\b|\b(?:arbeidsduur|werkuren|overuren)\b.*\b(?:annualisering|referteperiode)\b/i, '1971031602', '26bis'],
      [/\b(?:maximum|plafond|grens)\b.*\b(?:overuren|overwerk)\b|\b(?:overuren|overwerk)\b.*\b(?:maximum|plafond|grens)\b|\b(?:11\s*uur|50\s*uur)\b.*\b(?:werk|arbeid|overuren)\b/i, '1971031602', '27'],
      [/\b(?:overloon|overurenvergoeding|toeslag\s+voor\s+overuren)\b/i, '1971031602', '29'],
      [/(?:nacht(?:arbeid|werk)|travail\s+de\s+nuit)/i,               '1971031602', '35'],
      [/\b(?:uitzondering(?:en)?|toegelaten|toestaan)\b.*\bnacht(?:arbeid|werk|prestaties|shift|dienst)\b|\bnacht(?:arbeid|werk|prestaties|shift|dienst)\b.*\b(?:uitzondering(?:en)?|toegelaten|toestaan)\b/i, '1971031602', '36'],
      [/\b(?:uitzondering(?:en)?|toegelaten|toestaan)\b.*\bnacht(?:arbeid|werk|prestaties|shift|dienst)\b|\bnacht(?:arbeid|werk|prestaties|shift|dienst)\b.*\b(?:uitzondering(?:en)?|toegelaten|toestaan)\b/i, '1971031602', '37'],
      [/\b(?:invoeren|instellen)\b.*\bnacht(?:regeling|prestaties|arbeid)\b|\bnacht(?:regeling|prestaties|arbeid)\b.*\b(?:invoeren|instellen)\b/i, '1971031602', '38'],
      [/\b(?:pauze|rustpauze)\b.*\b(?:werk|arbeid|(?:meer\s+dan\s+)?6\s*uur)\b|\b(?:werk|arbeid|(?:meer\s+dan\s+)?6\s*uur)\b.*\b(?:pauze|rustpauze)\b/i, '1971031602', '38quater'],
      # v5 grader 1: the French maternity questions retrieved the holiday
      # decree's Art. 39 (1967033001) instead of the Labour Act's on q0041, so
      # the pin knows the French, German and English terms too.
      [/\b(?:prenataal|postnataal|nabevallings(?:rust|verlof)?|moederschaps(?:rust|verlof)|bevallingsverlof|zwangerschapsverlof|
           cong[eé]s?\s+de\s+maternit[eé]|repos\s+de\s+maternit[eé]|Mutterschaftsurlaub|Mutterschutz|maternity\s+leave)\b/ix, '1971031602', '39'],
      # Birth leave, Art. 30 § 2 of the Employment Contracts Act (German
      # answers v4, q0046: the question pulled the annual-holidays decrees).
      [/\b(?:geboorteverlof|vaderschapsverlof|cong[eé]s?\s+de\s+(?:naissance|paternit[eé])|birth\s+leave|paternity\s+leave|geburtsurlaub|vaterschaftsurlaub)\b/i, '1978070303', '30'],
      [/(?:zwanger(?:schap|e)?|grossesse).{0,40}(?:ontslag|licenciement)|(?:ontslag|licenciement).{0,40}(?:zwanger(?:schap|e)?|grossesse)/i, '1971031602', '40'],
      [/\bprofylactisch\s+verlof\b|\bpreventieve\s+werkverwijdering\b|\bwerkverwijdering\b.*\b(?:zwangere?|zwangerschap|werkneemster)\b|\b(?:zwangere?|zwangerschap|werkneemster)\b.*\bwerkverwijdering\b/i, '1971031602', '42'],
      [/\b(?:zwangere?|zwangerschap|werkneemster)\b.*\bnacht(?:arbeid|werk|prestaties)\b|\bnacht(?:arbeid|werk|prestaties)\b.*\b(?:zwangere?|zwangerschap|werkneemster)\b/i, '1971031602', '43'],
      [/(?=.*\b(?:jaarlijkse\s+vakantie|vakantiedagen|betaald\s+verlof|wettelijke\s+vakantie|congés?\s+payés?)\b)(?=.*\b(?:hoeveel|aantal|dagen|duur|per\s+jaar|combien|nombre|jours|durée)\b)/i, '1971062850', '3'],

      # German answers v5, grader 1: the guaranteed-pay question reasoned on
      # Art. 72 (the employee hired for under three months) and the pension
      # questions on Art. 4 without its § 3; the same patterns as the
      # TopicCitations topics, kept inline because the two classes load each
      # other's constants.
      [/\A(?=.*\b(?:salaire\s+garanti|r[eé]mun[eé]ration\s+garantie|gewaarborgd\s+loon|garantiert\w*\s+(?:Lohn|Gehalt|Entlohnung)|guaranteed\s+(?:pay|salary|wages?)|maladie|malade|incapacit[eé]\s+de\s+travail|ziek\w*|arbeidsongeschikt\w*|krank\w*|arbeitsunf[aä]hig\w*|sick\w*|illness|arr[eê]ts?\s+de\s+travail|certificat\s+m[eé]dical|cong[eé]\s+de\s+maladie|incapacit[eé]|ziektebriefje|ziekteverlof|Krankschreibung|Krankmeldung)\b)(?=.*\b(?:employ[eé]e?s?|bediendes?|bedienden|Angestellte[rnms]?|white[-\s]collar)\b).*\z/im, '1978070303', '70'],
      # German answers v6, grader 1: the items whose answers reasoned on another article in both runs.
      [/(?:prescri\w*|verjar\w*|verj[aä]hr\w*|limitation\s+period).{0,80}(?:dommage|pr[eé]judice|responsabilit|faute|voisin|schade|aansprakelijk|Schaden|Haftung|Nachbar|damage|liab)|(?:dommage|pr[eé]judice|responsabilit|faute|voisin|schade|aansprakelijk|Schaden|Haftung|Nachbar|damage|liab).{0,80}(?:prescri\w*|verjar\w*|verj[aä]hr\w*|limitation\s+period)/i, '1804032155', '2262bis'], # tort claims: 5 years from knowledge, 20 at most
      [/\b(?:r[eé]serve\s+h[eé]r[eé]ditaire|quotit[eé]\s+disponible|erfrechtelijke\s+reserve|beschikbaar\s+(?:ge)?deel|Pflichtteil|frei\s+verf[uü]gbare[rn]?\s+Teil|forced\s+share|disposable\s+(?:share|portion))\b|(?:testament|erf\w*|succession|h[eé]riti\w*|Erb\w*|inherit\w*).{0,60}(?:enfants|kinderen|Kinder|children).{0,80}(?:disposer|librement|beschikken|verf[uü]gen|dispose)/i, '2022B30600', '4.145'], # the reserve: half of the estate
      [/\b(?:r[eé]serve\s+h[eé]r[eé]ditaire|quotit[eé]\s+disponible|erfrechtelijke\s+reserve|beschikbaar\s+(?:ge)?deel|Pflichtteil|frei\s+verf[uü]gbare[rn]?\s+Teil|forced\s+share|disposable\s+(?:share|portion))\b|(?:testament|erf\w*|succession|h[eé]riti\w*|Erb\w*|inherit\w*).{0,60}(?:enfants|kinderen|Kinder|children).{0,80}(?:disposer|librement|beschikken|verf[uü]gen|dispose)/i, '2022B30600', '4.147'], # the spouse's reserve
      [/\b(?:double\s+p[eé]cule|dubbel\s+vakantiegeld|doppelte[sn]?\s+Urlaubsgeld|double\s+holiday\s+pay)\b/i, '1967033001', '38'], # 92 percent of the month's gross
      [/\b(?:opposition|verzet|Einspruch)\b.{0,60}\b(?:jugement\s+(?:rendu\s+)?par\s+d[eé]faut|verstekvonnis|Vers[aä]umnisurteil|default\s+judgment)|\b(?:jugement\s+(?:rendu\s+)?par\s+d[eé]faut|verstekvonnis|Vers[aä]umnisurteil|default\s+judgment)\b.{0,60}\b(?:opposition|verzet|Einspruch)\b/i, '1967101055', '1048'], # one month from the service
      [/\b(?:pension\s+(?:de\s+retraite\s+)?anticip[eé]e|retraite\s+anticip[eé]e|vervroegde?\s+(?:rust)?pensioen|vervroegde\s+pensionering|vorgezogene[nrs]?\s+(?:Pension|Rente|Ruhestand)|vorzeitige[nrs]?\s+(?:Pension|Pensionierung|Rente|Ruhestand)|Fr[uü]hpension|Fr[uü]hrente|early\s+(?:retirement|pension))\b/i, '1997022010', '4'],
      [/\A(?!.*\b(?:anticip[eé]e?|vervroegd\w*|vorgezogen\w*|vorzeitig\w*|Fr[uü]hpension|Fr[uü]hrente|early)\b)(?=.*(?:\b[aâ]ge\s+(?:l[eé]gal\s+)?de\s+(?:la\s+)?(?:pension|retraite)\b|\b(?:wettelijke\s+)?pensioenleeftijd\b|\bpensioengerechtigde\s+leeftijd\b|\b(?:gesetzliche[sn]?\s+)?(?:Pensions|Renten)alter\b|\b(?:legal\s+|statutory\s+)?(?:pension|retirement)\s+age\b|\b(?:quel|welke?|welchem|what|which)\s+(?:[aâ]ge|leeftijd|Alter|age)\b.{0,60}\b(?:pension|retraite|pensioen|Pension|Rente|retire\w*)\b)).*\z/im, '1997022010', '2'],

      # High-value single-article diagnosis targets.
      # Drug offences: penalties sit in the 1921 Drugs Law, while the current
      # possession/prohibition and penalty bridge are in the 2017 decree. The
      # former KB of 31 December 1930 was repealed by the 2017 decree.
      [DRUG_OFFENCE_PATTERN, '1921022450', '2bis'],
      [CANNABIS_OR_POSSESSION_PATTERN, '1921022450', '2ter'],
      [DRUG_OFFENCE_PATTERN, '2017031231', '6'],
      [DRUG_OFFENCE_PATTERN, '2017031231', '61'],
      [ALCOHOL_DRIVING_LIMIT_PATTERN, '1968031601', '34'],
      [ALCOHOL_DRIVING_LIMIT_PATTERN, '1968031601', '35'],
      [ALCOHOL_DRIVING_LIMIT_PATTERN, '1968031601', '36'],
      [ALCOHOL_DRIVING_LIMIT_PATTERN, '1968031601', '38'],
      [ALCOHOL_DRIVING_LIMIT_PATTERN, '1968031601', '55'],
      [ALCOHOL_DRIVING_LIMIT_PATTERN, '1968031601', '37/1'],
      [ALCOHOL_DRIVING_LIMIT_PATTERN, '1968031601', '37'],
      [/(?:onmiddellijke\s+inning|verkeersboete.{0,30}(?:betalen|inning)|perception\s+immédiate)/i, '1968031601', '65'],
      # Consumer conformity (old Civil Code) versus hidden defects. These are
      # deliberately consumer/product scoped so they do not capture financial
      # guarantees, rental deposits, or construction warranties.
      [USED_GOODS_WARRANTY_PATTERN, '1804032154', '1649quater'],
      # Preserve the full conformity/remedy cluster in every supported query
      # language. English "warranty" used to inject only the Economic Code,
      # despite the governing sales provisions living in the old Civil Code.
      [CONSUMER_GOODS_WARRANTY_PATTERN, '1804032154', '1649quinquies'],
      [CONSUMER_GOODS_WARRANTY_PATTERN, '1804032154', '1649bis'],
      [CONSUMER_GOODS_WARRANTY_PATTERN, '1804032154', '1649ter'],
      [CONSUMER_GOODS_WARRANTY_PATTERN, '1804032154', '1649quater'],
      # Book 5 contractual remedies are evidence to examine for new damage
      # during a professional repair, not a conclusion that fault or a right
      # to replace the whole original purchase has already been established.
      [PROFESSIONAL_REPAIR_DAMAGE_PATTERN, '2022A32058', '5.83'],
      [PROFESSIONAL_REPAIR_DAMAGE_PATTERN, '2022A32058', '5.86'],
      [PROFESSIONAL_REPAIR_DAMAGE_PATTERN, '2022A32058', '5.225'],
      [PROFESSIONAL_REPAIR_DAMAGE_PATTERN, '2022A32058', '5.231'],
      [PROFESSIONAL_REPAIR_DAMAGE_PATTERN, '2022A32058', '5.87'],
      [PROFESSIONAL_REPAIR_DAMAGE_PATTERN, '2022A32058', '5.90'],
      [PROFESSIONAL_REPAIR_DAMAGE_PATTERN, '2022A32058', '5.237'],
      [/(?=.*\b(?:consument|koper|verkoper|product|goed|toestel|wagen|consommateur|acheteur|vendeur|produit|bien)\b)(?=.*\b(?:wettelijke\s+garantie|garantie\s+légale|conformiteit|non[-\s]?conformiteit|conformité|twee\s+jaar|2\s+jaar)\b)/i, '1804032154', '1649bis'],
      [/(?=.*\b(?:consument|koper|verkoper|product|goed|toestel|wagen|consommateur|acheteur|vendeur|produit|bien)\b)(?=.*\b(?:wettelijke\s+garantie|garantie\s+légale|conformiteit|non[-\s]?conformiteit|conformité)\b)/i, '1804032154', '1649ter'],
      [/(?=.*\b(?:consument|koper|verkoper|product|goed|toestel|wagen|consommateur|acheteur|vendeur|produit|bien)\b)(?=.*\b(?:garantie|conformiteit|conformité|gebrek|défaut)\b)(?=.*\b(?:termijn|duur|jaar|bewijs|vermoeden|délai|durée|an|preuve)\b)/i, '1804032154', '1649quater'],
      [/(?=.*\b(?:consument|koper|verkoper|product|goed|toestel|wagen|consommateur|acheteur|vendeur|produit|bien)\b)(?=.*\b(?:garantie|conformiteit|conformité|gebrek|défaut)\b)(?=.*\b(?:herstel|herstelling|vervanging|prijsvermindering|ontbinding|réparation|remplacement|réduction|résolution)\b)/i, '1804032154', '1649quinquies'],
      [/\A(?=.*\b(?:verborgen\s+gebrek|verborgen\s+gebreken|vice\s+caché|vices\s+cachés)\b)(?!.*\b(?:nieuwbouw|aannemer|architect|constructie|bouwwerk|construction|entrepreneur|architecte)\b).*\z/im, '1804032154', '1641'],
      [/\A(?=.*\b(?:verborgen\s+gebrek|verborgen\s+gebreken|vice\s+caché|vices\s+cachés)\b)(?=.*\b(?:terugbetaling|prijsvermindering|ontbinding|remboursement|réduction|résolution)\b)(?!.*\b(?:nieuwbouw|aannemer|architect|constructie|bouwwerk|construction|entrepreneur|architecte)\b).*\z/im, '1804032154', '1644'],
      [HOUSE_PURCHASE_HIDDEN_DEFECT_PATTERN, '1804032154', '1641'],
      [HOUSE_PURCHASE_HIDDEN_DEFECT_PATTERN, '1804032154', '1648'],
      [HOUSE_PURCHASE_HIDDEN_DEFECT_PATTERN, '1804032154', '1644'],
      [HOUSE_PURCHASE_HIDDEN_DEFECT_PATTERN, '1804032154', '1643'],
      [LAWYER_FEE_PATTERN, '1967101053', '446ter'],
      [LEGAL_EXPENSE_INSURANCE_PATTERN, '2014011239', '156'],
      [OFFICE_COMMUTE_WORK_PATTERN, '1971031602', '19'],
      [OFFICE_COMMUTE_WORK_PATTERN, '1971031602', '29'],

      # Family law (old Civil Code, Book I).
      [MAJORITY_AGE_PATTERN, '1804032150', '488'],
      [/(?=.*\b(?:onderhoudsgeld|alimentatie|pension\s+alimentaire)\b)(?=.*\b(?:kind|kinderen|ouder|ouders|enfant|parent)\b)/i, '1804032150', '203'],
      [/(?=.*\b(?:onderhoudsgeld|alimentatie|pension\s+alimentaire)\b)(?=.*\b(?:kind|kinderen|ouder|ouders|bijdrage|enfant|parent|contribution)\b)/i, '1804032150', '203bis'],
      [/(?=.*\b(?:onderhoudsgeld|alimentatie|pension\s+alimentaire)\b)(?=.*\b(?:index|aanpassing|indexation)\b)/i, '1804032150', '203quater'],
      [/(?=.*\b(?:onderhoudsgeld|alimentatie|pension\s+alimentaire)\b)(?=.*\b(?:ex[-\s]?(?:echtgenoot|partner)|echtscheiding|divorce|ex[-\s]?(?:époux|partenaire))\b)/i, '1804032150', '301'],
      [/\b(?:wettelijke\s+samenwoning|cohabitation\s+légale)\b.*\b(?:aangaan|verklaring|begin|voorwaarden|conclure|déclaration|conditions)\b|\b(?:aangaan|verklaring|begin|voorwaarden|conclure|déclaration|conditions)\b.*\b(?:wettelijke\s+samenwoning|cohabitation\s+légale)\b/i, '1804032153', '1475'],
      [/\b(?:wettelijke\s+samenwoning|cohabitation\s+légale)\b.*\b(?:verklaring|ambtenaar|burgerlijke\s+stand|déclaration|officier|état\s+civil)\b/i, '1804032153', '1476'],
      [/(?=.*\b(?:wettelijke\s+samenwoning|cohabitation\s+légale)\b)(?=.*\b(?:rechten|plichten|kosten|schulden|woning|droits|obligations|charges|dettes|logement)\b)/i, '1804032153', '1477'],
      [/(?=.*\b(?:wettelijke\s+samenwoning|cohabitation\s+légale)\b)(?=.*\b(?:eigendom|goederen|vermogen|propriété|biens|patrimoine)\b)/i, '1804032153', '1478'],
      [/(?=.*\b(?:wettelijke\s+samenwoning|cohabitation\s+légale)\b)(?=.*\b(?:beëindig|einde|dringende\s+maatregel|cessation|fin|mesure\s+urgente)\b)/i, '1804032153', '1479'],
      [/\b(?:ouderlijk\s+gezag|autorité\s+parentale)\b/i,             '1804032150', '371'],
      [/\b(?:ouderlijk\s+gezag|autorité\s+parentale)\b/i,             '1804032150', '373'],
      [/(?=.*\b(?:ouderlijk\s+gezag|verblijf|huisvesting|autorité\s+parentale|hébergement)\b)(?=.*\b(?:scheiding|gescheiden|ouders|séparation|parents)\b)/i, '1804032150', '374'],
      [/\b(?:contactrecht\s+(?:van\s+)?grootouders|omgangsrecht\s+(?:van\s+)?grootouders|relations\s+personnelles\s+(?:des\s+)?grands[-\s]?parents)\b/i, '1804032150', '375bis'],
      [/(?=.*\b(?:echtscheiding|divorce)\b)(?=.*\b(?:onherstelbare\s+ontwrichting|désunion\s+irrémédiable|voorwaarden|conditions)\b)/i, '1804032150', '229'],
      # The family home remains protected during marriage; this narrow pin is
      # useful when a divorce question expressly concerns the marital home.
      [/(?=.*\b(?:echtscheiding|divorce)\b)(?=.*\b(?:woonrecht|echtelijke\s+woning|gezinswoning|logement\s+familial|résidence\s+familiale)\b)/i, '1804032150', '215'],

      # Vlaams Woninghuurdecreet: candidate-tenant documents (Art. 7) and
      # landlord/tenant repair allocation (Arts. 25-26), confirmed against
      # Vlaamse Codex 1029963. Eligibility requires an explicitly residential
      # question in solely Flanders; the pin supplies text, not a conclusion
      # that the decree applies to an unspecified historical contract.
      [FLANDERS_RENTAL_APPLICATION_PATTERN, '2018015087', '7'],
      # Exact short-lease termination, registration and habitability anchors
      # (Arts. 21, 11 and 12), verified in the same Vlaamse Codex text. A
      # duration alone or a landlord's address-registration dispute does not
      # select the short-lease/lease-registration provisions.
      [FLANDERS_SHORT_RENTAL_TERMINATION_PATTERN, '2018015087', '21'],
      [FLANDERS_LANDLORD_TERMINATION_PATTERN, '2018015087', '16'],
      [FLANDERS_LANDLORD_TERMINATION_PATTERN, '2018015087', '17'],
      [FLANDERS_LANDLORD_TERMINATION_PATTERN, '2018015087', '18'],
      [FLANDERS_LANDLORD_TERMINATION_PATTERN, '2018015087', '19'],
      [FLANDERS_LANDLORD_SALE_TRANSFER_PATTERN, '2018015087', '38'],
      [FLANDERS_RENTAL_REGISTRATION_PATTERN, '2018015087', '11'],
      [FLANDERS_RENTAL_HABITABILITY_PATTERN, '2018015087', '12'],
      [FLANDERS_RENTAL_SCOPE_PATTERN, '2018015087', '5'],
      [FLANDERS_RENTAL_SCOPE_PATTERN, '2018015087', '6'],
      [FLANDERS_RENTAL_MAINTENANCE_PATTERN, '2018015087', '25'],
      [FLANDERS_RENTAL_MAINTENANCE_PATTERN, '2018015087', '26'],

      # General lease defects: the exact residential regime remains regional,
      # but these Civil Code provisions safely anchor the general warranty and
      # urgent-repairs baseline.
      [/(?=.*\b(?:huurder|huur|huurcontract|verhuurder|bail|locataire|bailleur)\b)(?=.*\b(?:gebrek|gebreken|herstelling|herstellingen|defect|défaut|vice|réparation)\b)/i, '1804032154', '1721'],
      [/(?=.*\b(?:huurder|huur|huurcontract|verhuurder|bail|locataire|bailleur)\b)(?=.*\b(?:gebrek|gebreken|herstelling|herstellingen|defect|défaut|vice|réparation)\b)/i, '1804032154', '1724'],
      [/(?=.*\b(?:echtscheiding|divorce)\b)(?=.*\b(?:onderlinge\s+toestemming|consentement\s+mutuel|mutual\s+consent)\b)/i, '1804032150', '230'],
      [/(?=.*\b(?:echtscheiding|divorce)\b)(?=.*\b(?:onderlinge\s+toestemming|consentement\s+mutuel|mutual\s+consent)\b)/i, '1967101055', '1287'],
      [/(?=.*\b(?:echtscheiding|divorce)\b)(?=.*\b(?:onderlinge\s+toestemming|consentement\s+mutuel|mutual\s+consent)\b)/i, '1967101055', '1288'],
      [/(?=.*\b(?:adoptie|adoption)\b)(?=.*\b(?:voorwaarden|leeftijd|toestemming|conditions|âge|consentement)\b)/i, '1804032150', '343'],
      [/\b(?:bewindvoering|bewindvoerder|beschermde\s+persoon|administration\s+des\s+biens|administrateur\s+de\s+la\s+personne)\b/i, '1804032150', '488/1'],

      # Occupational risks.
      [/(?=.*\b(?:arbeidsongeval|accident\s+du\s+travail)\b)(?=.*\b(?:wanneer|definitie|erken|voorwaarden|quand|définition|reconnaître|conditions)\b)/i, '1971041001', '7'],
      [/(?=.*\b(?:arbeidsongeval|accident\s+du\s+travail)\b)(?=.*\b(?:oorzaak|uitvoering|overkomen|cause|exécution|survenu)\b)/i, '1971041001', '9'],
      [/(?=.*\b(?:arbeidsongeval|accident\s+du\s+travail)\b)(?=.*\b(?:vergoeding|arbeidsongeschiktheid|loon|indemnité|incapacité|rémunération)\b)/i, '1971041001', '24'],
      [/(?=.*\b(?:arbeidsongeval|accident\s+du\s+travail)\b)(?=.*\b(?:aangifte|melden|termijn|déclaration|signaler|délai)\b)/i, '1971041001', '62'],
      [/\b(?:beroepsziekte|beroepsziekten|maladie\s+professionnelle|maladies\s+professionnelles)\b/i, '1970060309', '30'],
      [/\b(?:beroepsziekte|beroepsziekten|maladie\s+professionnelle|maladies\s+professionnelles)\b/i, '1970060309', '30bis'],

      # Motor liability insurance and business registers.
      [/(?=.*\b(?:autoverzekering|verzekering\s+burgerlijke\s+aansprakelijkheid|assurance\s+responsabilité\s+civile)\b)(?=.*\b(?:verplicht|voertuig|obligatoire|véhicule)\b)/i, '1989011371', '2'],
      [/(?=.*\b(?:onverzekerd|zonder\s+verzekering|non\s+assuré|sans\s+assurance)\b)(?=.*\b(?:voertuig|rijden|véhicule|conduire)\b)/i, '1989011371', '22'],
      [/\b(?:zwakke\s+weggebruiker|usager\s+faible)\b/i,             '1989011371', '29bis'],
      [/(?=.*\b(?:onverzekerd|onbekend\s+voertuig|non\s+assuré|véhicule\s+inconnu)\b)(?=.*\b(?:fonds|vergoeding|indemnisation)\b)/i, '1989011371', '19bis-11'],

      # Book 4 Civil Code replaced the old testament-form articles in 2022.
      # Art. 4.184 is explicitly the international-form provision in the
      # current canonical NL corpus.
      [TESTAMENT_FORM_PATTERN, '2022B30600', '4.180'],
      [TESTAMENT_FORM_PATTERN, '2022B30600', '4.181'],
      [TESTAMENT_FORM_PATTERN, '2022B30600', '4.183'],
      [TESTAMENT_FORM_PATTERN, '2022B30600', '4.184'],

      # Private/supplementary hospitalisation policies. Articles 201-206 are
      # supplied as the governing cluster, while the order favours the more
      # specific duration or waiting-period provisions. A pin is evidence to
      # inspect, never proof that a particular policy grants the claimed term.
      [HOSPITALISATION_WAITING_PATTERN, '2014011239', '205'],
      [HOSPITALISATION_WAITING_PATTERN, '2014011239', '206'],
      [HOSPITALISATION_DURATION_PATTERN, '2014011239', '201'],
      [HOSPITALISATION_DURATION_PATTERN, '2014011239', '202'],
      [HOSPITALISATION_DURATION_PATTERN, '2014011239', '203'],
      [HOSPITALISATION_DURATION_PATTERN, '2014011239', '204'],
      [HOSPITALISATION_POLICY_PATTERN, '2014011239', '201'],
      [HOSPITALISATION_POLICY_PATTERN, '2014011239', '202'],
      [HOSPITALISATION_POLICY_PATTERN, '2014011239', '203'],
      [HOSPITALISATION_POLICY_PATTERN, '2014011239', '204'],
      [HOSPITALISATION_POLICY_PATTERN, '2014011239', '205'],
      [HOSPITALISATION_POLICY_PATTERN, '2014011239', '206'],

      [/\b(?:ubo[-\s]register|registre\s+ubo|uiteindelijk\s+begunstigde|bénéficiaire\s+effectif)\b/i, '2017013368', '73'],
      [/\b(?:ubo[-\s]register|registre\s+ubo|uiteindelijk\s+begunstigde|bénéficiaire\s+effectif)\b/i, '2017013368', '74'],
      [/\b(?:ubo[-\s]register|registre\s+ubo|uiteindelijk\s+begunstigde|bénéficiaire\s+effectif)\b/i, '2017013368', '75'],
      [/(?=.*\b(?:kbo|kruispuntbank\s+van\s+ondernemingen|bce|banque-carrefour\s+des\s+entreprises)\b)(?=.*\b(?:inschrij|registr|nummer|identifier|immatricul)\w*\b)/i, '2013A11134', 'III.15'],
      [ONLINE_CONSUMER_RIGHTS_PATTERN, '2013A11134', 'VI.47'],
      [TELEMARKETING_PRIVACY_PATTERN, '2013A11134', 'VI.110'],
      [TELEMARKETING_PRIVACY_PATTERN, '2013A11134', 'VI.112'],
      [TELEMARKETING_PRIVACY_PATTERN, '2013A11134', 'VI.111'],
      [MUNICIPAL_SANCTIONS_PATTERN, '2013000441', '2'],
      [MUNICIPAL_SANCTIONS_PATTERN, '2013000441', '4'],
      [MUNICIPAL_SANCTIONS_PATTERN, '2013000441', '25'],
      [MUNICIPAL_SANCTIONS_PATTERN, '2013000441', '31'],
      [VEHICLE_HEADLIGHT_PATTERN, '2026004490', '58'],
      [VEHICLE_HEADLIGHT_PATTERN, '1975120109', '30'],
      [VEHICLE_HEADLIGHT_PATTERN, '1968031501', '28'],
      [VEHICLE_HEADLIGHT_PATTERN, '1975120109', '8'],
      [VEHICLE_HEADLIGHT_PATTERN, '1975120109', '10'],
      [VEHICLE_HEADLIGHT_LIABILITY_PATTERN, '2024001600', '6.6'],
      [VEHICLE_HEADLIGHT_LIABILITY_PATTERN, '2024001600', '6.18'],
      [VEHICLE_HEADLIGHT_LIABILITY_PATTERN, '2024001600', '6.20'],
      [VEHICLE_HEADLIGHT_LIABILITY_PATTERN, '2024001600', '6.5'],
      [PAYMENT_REFUSAL_PATTERN, '2013A11134', 'VI.7/4'],
      [CASH_PAYMENT_PATTERN, '2013A11134', 'VI.7/5'],
      [/(?=.*\b(?:online|webshop|internet|op\s+afstand|afstandsovereenkomst|en\s+ligne|vente\s+à\s+distance|contrat\s+à\s+distance|distance\s+(?:contract|sale)|online\s+purchase)\b)(?=.*\b(?:herroepingsrecht|droit\s+de\s+rétractation|retour(?:neren)?|terugsturen|herroepen|rétracter|retourner|withdraw\w*)\b)/i, '2013A11134', 'VI.47'],
      [/\bontslagmotivering\b|\bmotiveringsplicht\b.{0,60}\b(?:ontslag|werkgever|werknemer)\b|\b(?:ontslag|werkgever|werknemer)\b.{0,60}\bmotiveringsplicht\b|\b(?:motivering|reden(?:en)?)\s+(?:voor|van)\s+(?:mijn\s+)?ontslag\b/i, '2014A01545', '3'],
      [/\bkennelijk\s+onredelijk\s+ontslag\b.*\b(?:vergoeding|schade|weken)\b|\b(?:vergoeding|schade|weken)\b.*\bkennelijk\s+onredelijk\s+ontslag\b/i, '2014A01545', '9'],
      [/\bkennelijk\s+onredelijk\s+ontslag\b|\blicenciement\s+manifestement\s+déraisonnable\b/i, '2014A01545', '8'],

      # Urgent medical aid for an alien staying illegally: the definition
      # first, then who owes it, then who pays. Art. 57 is pinned in the
      # Brussels-Capital version of the OCMW Act: its § 2 is word for word the
      # same in the four regional versions (Flemish 1976B70810, Walloon
      # 1976A70810, German-speaking 1976C70810), and the federal 1976070810
      # holds no article text.
      [URGENT_MEDICAL_AID_PATTERN, '1996022721', '1'],
      [URGENT_MEDICAL_AID_PATTERN, '1976D70810', '57'],
      [URGENT_MEDICAL_AID_PATTERN, '1996022721', '2'],

      # A company's minimum capital: none for the BV, 61 500 euro for the NV.
      [MINIMUM_CAPITAL_BV_PATTERN, '2019A40586', '5:1'],
      [MINIMUM_CAPITAL_BV_PATTERN, '2019A40586', '5:3'],
      [MINIMUM_CAPITAL_BV_PATTERN, '2019A40586', '5:4'],
      [MINIMUM_CAPITAL_NV_PATTERN, '2019A40586', '7:2'],

      # Werkloosheidsbesluit: high-confidence diagnosis cluster.
      [UNEMPLOYMENT_CONDITIONS_PATTERN, '1991013192', '30'],
      [UNEMPLOYMENT_CONDITIONS_PATTERN, '1991013192', '44'],
      [UNEMPLOYMENT_CONDITIONS_PATTERN, '1991013192', '56'],
      [UNEMPLOYMENT_CONDITIONS_PATTERN, '1991013192', '58'],
      [UNEMPLOYMENT_AVAILABILITY_PATTERN, '1991013192', '56'],
      [UNEMPLOYMENT_AVAILABILITY_PATTERN, '1991013192', '58'],
      [UNEMPLOYMENT_TRAINING_EXEMPTION_PATTERN, '1991013192', '92'],
      [UNEMPLOYMENT_TRAINING_EXEMPTION_PATTERN, '1991013192', '93'],
      [UNEMPLOYMENT_TRAINING_EXEMPTION_PATTERN, '1991013192', '94'],
      [UNEMPLOYMENT_FAULT_DISMISSAL_PATTERN, '1991013192', '51'],
      [UNEMPLOYMENT_FAULT_DISMISSAL_PATTERN, '1991013192', '52'],
      [UNEMPLOYMENT_FAULT_DISMISSAL_PATTERN, '1991013192', '53'],

      # Federal VAT Code: small-enterprise exemption/franchise.
      [VAT_SMALL_ENTERPRISE_EXEMPTION_PATTERN, '1969070305', '56bis'],

      # Consumer debt settlement is judicial procedure, not enterprise bankruptcy.
      [/\b(?:collectieve\s+schuldenregeling|règlement\s+collectif\s+de\s+dettes)\b/i, '1967101056', '1675/2'],
      [/(?:\bfaillissement\b.{0,60}\b(?:onderneming|vennootschap|handelaar)\b|\b(?:onderneming|vennootschap|handelaar)\b.{0,60}\bfaillissement\b)/i, '2013A11134', 'XX.99'],

      # Regional tax competence. Succession and registration duties are REGIONAL taxes, and
      # for them the region sets the rate, the base and the exemptions while the federal
      # text is residual, so an answer that gives a figure without naming a gewest is
      # quoting a rate that may apply nowhere.
      #
      # These are pinned rather than left to retrieval because the citation has to survive
      # the guards: an /laws/1989021010 link whose law was not retrieved is stripped by
      # LinkGuard, and the bare "art. 3" left behind is then reported as an unsupported
      # citation. Pinning is what makes the statement quotable at all.
      [REGIONAL_TAX_COMPETENCE_PATTERN, '1989021010', '3'],
      [REGIONAL_TAX_COMPETENCE_PATTERN, '1989021010', '4'],
      [FOREIGN_DECEASED_SUCCESSION_TAX_PATTERN, '1936033102', '1'],
      [FOREIGN_DECEASED_SUCCESSION_TAX_PATTERN, '1989021010', '5'],
      [FOREIGN_DECEASED_SUCCESSION_TAX_PATTERN, '2013036154', '2.7.3.2.2'],
    ].freeze

    # Deployment tooling must validate the complete target surface, not a
    # hand-maintained subset of laws that happened to need a repair import.
    # Include the exact regional rescue targets as well as ARTICLE_PINS so
    # neither deterministic source path can escape the readiness contract.
    # The historical 1867 Criminal Code targets are
    # the only pins that may intentionally resolve through an abolished law.
    ARTICLE_PIN_TARGETS = (ARTICLE_PINS
                          .map { |_pattern, numac, article_number| [numac, article_number].freeze } +
                          REGIONAL_SHORT_COMMERCIAL_TARGETS + REGIONAL_RENT_INCREASE_TARGETS +
                          REGIONAL_RENTAL_DEPOSIT_TARGETS + REGIONAL_RENTAL_TERMINATION_TARGETS +
                          CommercialWebsiteIntent::ALL_ARTICLE_TARGETS +
                          MarketplaceCivilClaimIntent::ALL_ARTICLE_TARGETS)
                          .uniq
                          .sort
                          .freeze
    ARTICLE_PIN_ALLOWED_ABOLISHED_TARGETS = ARTICLE_PIN_TARGETS
                                             .select { |numac, _article_number| numac == '1867060850' }
                                             .freeze
    ZIV_ARTICLE_PIN_TARGETS = ARTICLE_PIN_TARGETS
                              .select { |numac, _article_number| numac == '1994071451' }
                              .freeze

    def self.article_pin_targets
      ARTICLE_PIN_TARGETS
    end

    def pinned_articles(question)
      matched = matching_article_pins(question)
      return [] if matched.empty?

      matched.filter_map do |_rx, numac, artnum|
        normalized_title = "Art#{artnum}".delete(' .').downcase
        art = ::Article
              .select('articles.*, COALESCE(legislation.short_title, legislation.title) as law_title, ' \
                      'legislation.is_abolished, legislation.is_modification')
              .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
              .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
              .where(content_numac: numac, language_id: @language_id)
              .where("LOWER(REPLACE(REPLACE(article_title, ' ', ''), '.', '')) = ?", normalized_title)
              .first
        unless art
          Rails.logger.warn("[ArticlePins] target missing: #{numac} Art. #{artnum} (language #{@language_id})")
          next
        end

        law_title = art.law_title || lookup_law_title(numac, @language_id) || "Wetgeving #{numac}"
        if question.match?(FOREIGN_DECEASED_SUCCESSION_TAX_PATTERN) &&
           FOREIGN_SUCCESSION_APPLICABILITY_TARGETS.include?([numac, artnum])
          labels = FOREIGN_SUCCESSION_REGIONAL_LABELS.fetch(@language, FOREIGN_SUCCESSION_REGIONAL_LABELS.fetch('nl'))
          law_title = "#{labels.fetch(numac)}: #{law_title}" if labels.key?(numac)
        end

        source = {
          id: art.id, numac: art.content_numac,
          law_title: law_title,
          article_title: art.article_title, article_text: art.article_text,
          article_variant: art.try(:article_variant),
          language_id: art.language_id, similarity: 99.0, pinned: true,
          is_abolished: art.try(:is_abolished) == 1, is_modification: art.try(:is_modification) == 1
        }
        if numac == '1975120109' && artnum == '8' && VehicleHeadlightGlareSourceScope.topic?(question)
          # The actual 8.3 control rule follows more than 7k characters of
          # age rules. Keep the full source unchanged, but start this automatic
          # headlight-query context window at the literal stored subsection.
          source[:context_excerpt_anchor] = '8.3.'
        end
        if numac == '1976D70810' && artnum == '57' && question.to_s.gsub(/[[:space:]]+/, ' ').match?(URGENT_MEDICAL_AID_PATTERN)
          # The stored text opens the urgent-medical-aid paragraph as
          # "(§ 2. (In afwijking", and the model read past it: 4 of 78
          # evaluated answers cited the clause as "§ 1, 1°". Start this
          # context window at the paragraph; § 1 is not what is asked.
          source[:context_excerpt_anchor] = '§ 2.'
        end
        source
      end
    rescue StandardError => e
      Rails.logger.warn("[ArticlePins] skipped: #{e.class}")
      []
    end

    # Extract keywords from a legal question (bilingual NL/FR + cross-lingual)
    def extract_keywords(question)
      # Legal term mappings: user term → [search terms with synonyms]
      legal_terms = build_legal_term_map

      # Find matching legal terms
      phrases = []
      legal_terms.each do |pattern, terms|
        match = if pattern.is_a?(Regexp)
                  question =~ pattern
                else
                  question.downcase.include?(pattern.to_s.downcase)
                end
        phrases += terms if match
      end

      # A mapped concept must not erase the remainder of the actual question,
      # and a forum introduction must not consume all four old fallback slots.
      # Reserve room for distinct original terms before adding synonyms. This
      # keeps dates and the concrete noun being classified without an LLM call,
      # a statute-specific pin, or unbounded OR terms in the FTS query.
      result = (phrases.compact.uniq.take(4) + meaningful_query_words(question)).uniq.take(MAX_LEXICAL_TERMS)
      expansions = result.flat_map { |term| QUERY_EXPANSIONS[term.downcase] || [] }
      (result + expansions).uniq.take(MAX_LEXICAL_TERMS)
    end

    def meaningful_query_words(question)
      question.to_s.downcase.scan(/[[:alnum:]]+/)
              .select { |word| (word.length >= 4 || IMPORTANT_SHORT_QUERY_WORDS.include?(word)) && !QUERY_STOP_WORDS.include?(word) }
              .uniq
    end

    # Cheap, bounded second/third lexical views of the user's same question:
    # original meaningful words and the already-owned legal vocabulary map.
    # Relevance, legal scope, future-law sanitation and pins still run AFTER
    # the merge. One pass is byte-for-byte the legacy keyword query.
    def research_keyword_variants(question, keywords, passes: 1)
      variants = [keywords]
      return variants if passes <= 1

      original = meaningful_query_words(question).take(MAX_LEXICAL_TERMS)
      variants << original if original.any? && original != keywords
      if passes >= 3
        mapped = (keywords - original).take(MAX_LEXICAL_TERMS)
        variants << mapped if mapped.length >= 2 && !variants.include?(mapped)
      end
      variants.take(passes)
    end

    # Find articles by keyword search (FTS5 with LIKE fallback)
    def find_by_keywords(keywords, limit: 5)
      return [] if keywords.empty?

      articles = find_by_keywords_fts(keywords, limit)
      return articles if articles.any?

      find_by_keywords_like(keywords, limit)
    end

    # Merge semantic and lexical results while reserving a small lexical slice.
    # FTS is especially valuable for terminology/morphology misses; without the
    # quota, high-scoring semantic neighbours can push every lexical hit out of
    # the context before the title relevance filter gets to inspect it.
    def merge_search_results(embedding_results, keyword_results, limit: 15, lexical_quota: 3)
      seen_ids = Set.new
      semantic = []

      embedding_results.each do |result|
        next if seen_ids.include?(result[:id])

        seen_ids.add(result[:id])
        semantic << result
      end

      semantic_by_id = semantic.index_by { |result| result[:id] }
      lexical_seen = Set.new
      lexical = keyword_results.filter_map do |result|
        next if lexical_seen.include?(result[:id])

        lexical_seen.add(result[:id])
        # A lexical hit may also be a low-ranked semantic hit. It still needs
        # to consume one lexical-quota slot; otherwise marking every semantic
        # ID as seen before truncation silently defeats the vocabulary rescue.
        (semantic_by_id[result[:id]] || result).merge(keyword_hit: true)
      end

      lexical_keep = lexical.take([lexical_quota, limit].min)
      lexical_ids = lexical_keep.to_set { |result| result[:id] }
      semantic_keep = semantic.reject { |result| lexical_ids.include?(result[:id]) }
                              .take([limit - lexical_keep.length, 0].max)
      (semantic_keep + lexical_keep).sort_by { |result| -result[:similarity] }
    end

    # The German lane's rows (GermanArticleSearch#search): pointers (French
    # rows plus :german_evidence) and, with GERMAN_ORIGINALS_MODE=on, binding
    # German originals (language 3 rows plus :german_original). Each kind
    # merges by its own rule and under its own cap.
    def merge_german_pointers(articles, rows)
      rows = Array(rows).select { |row| row.is_a?(Hash) && row[:id] }
      return articles if rows.empty?

      originals, pointers = rows.partition { |row| row[:german_original].is_a?(Hash) }
      articles = merge_pointer_rows(articles, pointers) if pointers.any?
      articles = merge_german_originals(articles, originals) if originals.any?
      articles
    end

    # A pointer to a row the pool already holds adds its evidence and lifts
    # the similarity to the higher of the two, taking no slot; otherwise at
    # most MAX_POINTERS new rows enter, best first. The pool is re-ranked by
    # similarity, as merge_search_results ranks it.
    def merge_pointer_rows(articles, pointers)
      pointer_by_id = pointers.index_by { |pointer| pointer[:id] }
      existing = 0
      merged = articles.map do |article|
        pointer = pointer_by_id[article[:id]]
        next article unless pointer

        existing += 1
        article.merge(
          similarity: [article[:similarity].to_f, pointer[:similarity].to_f].max,
          german_evidence: pointer[:german_evidence]
        )
      end
      existing_ids = articles.to_set { |article| article[:id] }
      entering = pointers.reject { |pointer| existing_ids.include?(pointer[:id]) }
                         .take(LegalChatbot::GermanArticleSearch::MAX_POINTERS)
      Rails.logger.info("[GermanLane] merged: existing=#{existing} entered=#{entering.size} of #{pointers.size}")

      (merged + entering).sort_by { |result| -result[:similarity].to_f }
    end

    # Binding German originals enter as rows of their own, at most
    # MAX_ORIGINALS, best first. The binding text wins: every NL or FR row of
    # the pool with the same numac and article number as an entering original
    # is its translation and leaves the pool, so the model reads the article
    # once, in the language that is law. Other articles of the same act stay.
    def merge_german_originals(articles, originals)
      existing_ids = articles.to_set { |article| article[:id] }
      entering = originals.reject { |original| existing_ids.include?(original[:id]) }
                          .sort_by { |original| -original[:similarity].to_f }
                          .take(LegalChatbot::GermanArticleSearch::MAX_ORIGINALS)
      keys = entering.filter_map { |original| german_original_key(original) }.to_set
      kept = articles.reject do |article|
        [1, 2].include?(article[:language_id]) && keys.include?(german_original_key(article))
      end
      Rails.logger.info(
        "[GermanLane] originals merged: entered=#{entering.size} of #{originals.size} " \
        "replaced_translations=#{articles.size - kept.size}"
      )

      (kept + entering).sort_by { |result| -result[:similarity].to_f }
    end

    # [numac, "#art-N"], nil without an article number (such a row is never
    # taken for a translation).
    def german_original_key(row)
      anchor = extract_article_anchor(row[:article_title].to_s)
      anchor && [row[:numac].to_s, anchor]
    end

    # Future law (TOEKOMSTIG RECHT / DROIT FUTUR) is enacted but NOT YET IN FORCE. Drop a
    # row that IS future law; cut the trailing future block off a row that merely carries
    # one, keeping its in-force half.
    #
    # This has to happen on the way OUT rather than in the SELECTs. normalize_article_number
    # strips the marker from an article number, so once a row is keyed a future variant is
    # indistinguishable from the in-force article it shadows - same anchor, same
    # citation-repair key. And validate_answer_quotes would then certify a blockquote taken
    # from it, because verification is verbatim presence in the source text.
    #
    # See docs/ops/future-law-in-retrieval-2026-08-07.md.
    def sanitize_future_law(articles)
      Array(articles).filter_map do |article|
        next if LegalChatbot::FutureLaw.row_future?(variant: article[:article_variant],
                                                    title: article[:article_title])

        in_force, future_block = LegalChatbot::FutureLaw.split(article[:article_text])
        next if in_force.nil?          # the marker opens the text: the whole row is future law
        next article if future_block.nil?

        article.merge(
          article_text: in_force,
          future_amendment: true,
          future_effective_date: LegalChatbot::FutureLaw.effective_date(future_block)
        )
      end
    end

    def retain_final_search_quota(results, limit:, lexical_quota: 3)
      pins = results.select { |result| result[:pinned] }.take(limit)
      remaining = results.reject { |result| pins.include?(result) }
      lexical = remaining.select { |result| result[:keyword_hit] }
                         .take([lexical_quota, limit - pins.length].min)
      semantic = remaining.reject { |result| lexical.include?(result) }
                          .take(limit - pins.length - lexical.length)

      (pins + semantic + lexical)
        .sort_by { |result| result[:pinned] ? -Float::INFINITY : -result[:similarity].to_f }
        .take(limit)
    end

    # Filter articles by title relevance to the question
    def filter_by_title_relevance(articles, question)
      telemarketing_scope_resolver.preload(articles) if TelemarketingPrivacyIntent.topic?(question)
      question_lower = question.downcase
      # scan (not split) strips punctuation so 'verkoop?' matches title word
      # 'verkoop'; keep important short legal tokens ('btw', 'cao', ...) that
      # the length cut used to discard; dropping 'btw' filtered every real
      # VAT hit out of context.
      question_words = meaningful_query_words(question_lower)
      topic_keywords = extract_topic_keywords(question_lower)
      matched_core_numacs = matching_core_law_numacs(question)
      context_numacs = @context_numacs.to_set

      lnk_articles = []
      substantive_articles = []

      articles.each do |article|
        # Headings used to bypass the subject gate in the low-hit fallback.
        # Lexical similarity may justify a heading, but cannot make an
        # inheritance/budget/railway heading relevant to another civil issue.
        next unless contextual_source_relevant?(article, question)

        article_title = article[:article_title] || ''
        if article_title.start_with?('LNK') || article_title =~ /^(HOOFDSTUK|CHAPITRE|AFDELING|SECTION|TITEL|TITRE)\b/i
          lnk_articles << article
        else
          substantive_articles << article
        end
      end

      filtered = substantive_articles.select do |article|
        title = (article[:law_title] || '').downcase
        next false unless contextual_source_relevant?(article, question)
        # Catalogue membership is not query relevance. Only an explicitly
        # matched law, a viewed law, or an article pin earns this exemption.
        next true if article[:pinned] || matched_core_numacs.include?(article[:numac]) || context_numacs.include?(article[:numac])
        next true if article[:numac].present? && question_lower.include?(article[:numac].to_s.downcase)

        title_words = title.scan(/[[:alnum:]]+/)
        has_topic_match = topic_keywords.any? { |kw| title.include?(kw) }
        has_word_overlap = question_words.intersect?(title_words)
        # A strong vector match bypasses lexical title filtering. Threshold is
        # cosine (0..1) since the 2026-07-13 metric-aware serve; the old 1.5
        # was a squared-L2 distance and, under cosine, unreachable (dead code
        # that let the LEAST similar articles through when it did the distance).
        high_similarity = article[:similarity] >= 0.55

        has_topic_match || has_word_overlap || high_similarity
      end

      if filtered.length >= 5
        filtered
      else
        filtered + lnk_articles.take(5 - filtered.length)
      end
    end

    # Build context from legislation articles
    def build_context(articles)
      seen_preambles = Set.new

      articles.take(12).map do |article|
        numac = article[:numac]
        window = CORE_LAW_NUMACS.key?(numac) ? 5000 : 3000
        context_text = ensure_utf8(article[:article_text])
        if (anchor = article[:context_excerpt_anchor].to_s).present?
          offset = context_text.index(/(?<![\d.])#{Regexp.escape(anchor)}(?!\d)/)
          context_text = context_text[offset..] if offset
        end
        text = ensure_utf8(extract_relevant_window(context_text, ensure_utf8(article[:article_title]), window_size: window))

        warnings = []
        warnings << '[OPGEHEVEN/ABROGÉ]' if article[:is_abolished]

        # Check article_modifications for specific article abolition.
        # The column stores title strings ("Art. 37/2"), so pass the real title;
        # the old digits-only key ("372") never matched and conflated Art. 37/2
        # with Art. 372.
        #
        # DORMANT: article_modifications holds 0 rows in production (measured
        # 2026-08-15) and nothing in the codebase writes it, so this warning has
        # never been emitted. The code is correct and kept for when a source
        # exists; per-article abolition dates would have to come from Justel,
        # which the updater does not extract today. Abolition is still surfaced
        # by the two coarser signals below - the text-marker regex and the
        # UpdatedLaw joins - so the gap is precision, not silence.
        art_title = article[:article_title].to_s.strip
        if art_title.present?
          begin
            abolition_date = ArticleModification.abolition_date(numac, art_title, @language_id)
            warnings << "[ARTIKEL OPGEHEVEN OP #{abolition_date}]" if abolition_date
          rescue StandardError => e
            Rails.logger.debug("ArticleModification check failed: #{e.class}")
          end
        end

        warnings << '[BEPALING MOGELIJK OPGEHEVEN - controleer actuele status]' if text =~ /\b(opgeheven|abrogé|afgeschaft|geschrapt|vervallen)\b/i

        exdec_count = begin
          Exdec.where(content_numac: numac, language_id: @language_id).count
        rescue StandardError
          0
        end
        warnings << "[HEEFT #{exdec_count} UITVOERINGSBESLUITEN]" if exdec_count.positive?

        begin
          updating_base = UpdatedLaw
                          .joins("LEFT JOIN legislation ON updated_laws.update_numac = legislation.numac AND legislation.language_id = #{@language_id}")
                          .where(content_numac: numac, language_id: @language_id)

          update_count = updating_base.count
          warnings << "[GEWIJZIGD DOOR #{update_count} WETTEN]" if update_count.positive?

          abolition_laws = updating_base.where("legislation.title LIKE '%ophef%' OR legislation.title LIKE '%afschaf%' OR legislation.title LIKE '%intrekk%'")
          warnings << '[BEVAT OPGEHEVEN BEPALINGEN - controleer actuele status]' if abolition_laws.any?
        rescue StandardError => e
          Rails.logger.debug("Error checking modifications: #{e.class}")
        end

        warning_str = warnings.any? ? " #{warnings.join(' ')}" : ''

        preamble_text = ''
        if article[:preamble].present? && !seen_preambles.include?(numac)
          seen_preambles.add(numac)
          preamble_text = "\n[PARLEMENTAIRE CONTEXT: #{article[:preamble].to_s[0..300]}]"
        end

        "[WET NUMAC #{numac}#{warning_str}] #{article[:law_title]}\n#{article[:article_title]}\n#{text}#{preamble_text}"
      end.join("\n\n---\n\n")
    end

    # Format legislation sources for response
    def format_sources(articles)
      sources = articles.map do |article|
        numac = article[:numac]
        article_anchor = article[:article_title].to_s.parameterize.presence
        # A binding German original (language 3) opens the German text.
        german = article[:language_id] == LegalChatbot::GermanArticleSearch::GERMAN_LANGUAGE_ID
        path = german ? "/laws/#{numac}?language_id=#{article[:language_id]}" : "/laws/#{numac}"

        source = {
          numac: numac,
          law_title: ensure_utf8(article[:law_title]),
          article_title: ensure_utf8(article[:article_title]),
          url: article_anchor ? "#{path}##{article_anchor}" : path,
          language: LegalChatbot::SourceFormatter::SOURCE_LANGUAGE_LABELS.fetch(article[:language_id], 'FR'),
          relevance: [article[:similarity].round(3), 1.0].min
        }
        source[:abolished] = true if article[:is_abolished]

        if article[:article_text].present?
          clean_text = ensure_utf8(article[:article_text])
          excerpt = clean_text.gsub(/\s+/, ' ').strip[0..200]
          excerpt += '...' if clean_text.length > 200
          source[:excerpt] = excerpt
        end

        begin
          exdec_count = Exdec.where(content_numac: numac, language_id: @language_id).count
          source[:exdec_count] = exdec_count if exdec_count.positive?

          updating_laws = UpdatedLaw
                          .joins("LEFT JOIN legislation ON updated_laws.update_numac = legislation.numac AND legislation.language_id = #{@language_id}")
                          .where(content_numac: numac, language_id: @language_id)

          update_count = updating_laws.count
          source[:modification_count] = update_count if update_count.positive?

          abolition_laws = updating_laws.where("legislation.title LIKE '%ophef%' OR legislation.title LIKE '%afschaf%' OR legislation.title LIKE '%intrekk%'")
          source[:has_abolitions] = true if abolition_laws.any?
        rescue StandardError => e
          Rails.logger.debug("Error in format_sources: #{e.class}")
        end

        source
      end

      # Filter out noise sources below minimum relevance threshold.
      # relevance = min(boosted_similarity, 1.0) on the cosine scale (metric-
      # aware serve, 2026-07-13). Core laws are boosted (>=2x) so they cap at
      # 1.0 and clear MIN_SOURCE_RELEVANCE trivially; the non-core floor
      # (0.45 cosine) keeps genuinely relevant matches (~0.45-0.62) and drops
      # only noise. The old 0.8 was calibrated to a squared-L2 distance and,
      # once similarity became cosine, culled EVERY non-core source.
      good_sources = sources.select do |s|
        s[:relevance] >= if CORE_LAW_NUMACS.key?(s[:numac])
                           MIN_SOURCE_RELEVANCE
                         else
                           NONCORE_SOURCE_RELEVANCE
                         end
      end
      if good_sources.length >= 2
        dropped = sources.length - good_sources.length
        Rails.logger.info("Source relevance filter: dropped #{dropped} sources below threshold") if dropped.positive?
        good_sources
      else
        # A failed floor used to return EVERYTHING, so the filter waived
        # itself exactly when retrieval was noisiest. Degrade to the best two
        # instead: the user sees the least-bad candidates rather than a dozen
        # noise sources presented as support (decision A,
        # docs/ops/legal-merit-fixes-2026-08-03.md). Loud log on purpose: if a
        # future similarity-scale migration miscalibrates these floors again
        # (as the 2026-07-13 cosine switch did), this line is the tripwire,
        # where the old return-everything branch hid the regression.
        Rails.logger.warn(
          "Source relevance filter: only #{good_sources.length} of #{sources.length} " \
          'sources cleared the floor; returning the best 2 by relevance'
        )
        # Floor-passers first: a plain max_by(2) ranked by raw relevance and
        # could drop the one CORE source that cleared its 0.30 floor in favour
        # of two non-core sources that failed their 0.45 floor (review
        # finding, 2026-08-03). The degraded set must always contain every
        # survivor before any failer.
        (good_sources + (sources - good_sources).sort_by { |s| -s[:relevance].to_f }).first(2)
      end
    end

    # Inject abolished topic warnings into context
    def inject_abolished_warnings(question, context)
      q = question.downcase
      warnings = []

      if q.include?('proefperiode') || q.include?('proeftijd')
        warnings << <<~WARN
          [OPGELET] KRITIEKE CONTEXT VOOR DEZE VRAAG:
          De PROEFPERIODE voor gewone arbeidsovereenkomsten is AFGESCHAFT sinds 1 januari 2014 (Wet Eenheidsstatuut).
          De bronnen hieronder kunnen verwijzen naar een 3-dagen proefperiode, maar dit geldt ALLEEN voor:
          - Uitzendarbeid (interim)
          - Studentencontracten
          Dit is NIET de algemene regel. Begin je antwoord met de afschaffing in 2014, daarna pas de uitzonderingen.
        WARN
      end

      if q.include?('carensdag')
        warnings << <<~WARN
          [OPGELET] KRITIEKE CONTEXT VOOR DEZE VRAAG:
          De CARENSDAG is AFGESCHAFT sinds 1 januari 2014.
          Vroeger: eerste ziektedag onbetaald. Nu: eerste ziektedag WEL betaald (gewaarborgd loon vanaf dag 1).
          Begin je antwoord met deze afschaffing.
        WARN
      end

      # Regional topics
      regional_parts = build_regional_warnings(q)

      if regional_parts.any?
        warnings << <<~WARN
          [OPGELET] DIT IS EEN REGIONAAL ONDERWERP:
          België heeft 3 gewesten met verschillende wetgeving. Vermeld het relevante gewest.
          #{regional_parts.join("\n")}
        WARN
      end

      return context if warnings.empty?

      "#{warnings.join("\n")}\n\n---\nBRONNEN (let op: kunnen verouderde info bevatten):\n#{context}"
    end

    # Detect if a question is tax-related
    def tax_question?(question_lower)
      LegalChatbot::FisconetSearch.tax_question?(question_lower)
    end

    # Fetch specific articles BY NUMBER from laws that were already retrieved
    # for this question. This exists because retrieval routinely returns the
    # right law and misses the article the answer needs: of 89 citations
    # CitationGuard rejected in the 2026-07-29 sample, 77 (87%) were articles
    # that existed in a law the same search had returned - "Art. 37/2" of the
    # Arbeidsovereenkomstenwet for a dismissal question, for example.
    #
    # Deliberately narrow. `numacs` must be laws retrieved this turn, so this
    # can only deepen existing evidence, never introduce a new law the search
    # did not justify. Numbers are matched the same way article pins are
    # (spaces and dots removed), and the result hashes are the same shape as
    # search hits so the context builder, formatter and guards treat them
    # identically. A number that does not exist in any of those laws simply
    # yields nothing, leaving the citation unsupported and the guard's
    # rejection intact.
    def fetch_articles_by_number(numacs:, article_numbers:, limit: 5)
      numacs = Array(numacs).compact.uniq
      wanted = Array(article_numbers).compact.uniq.first(limit)
      return [] if numacs.empty? || wanted.empty?

      by_normalized = wanted.to_h { |number| [normalized_article_key(number), number] }
      rows = ::Article
             .select('articles.*, COALESCE(legislation.short_title, legislation.title) as law_title, ' \
                     'legislation.is_abolished, legislation.is_modification')
             .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
             .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
             .where(content_numac: numacs, language_id: @language_id)
             .where(
               "LOWER(REPLACE(REPLACE(articles.article_title, ' ', ''), '.', '')) IN (?)",
               by_normalized.keys.map { |key| key.delete('.') }
             )
             .limit(limit * numacs.length)
             .to_a

      # Keep retrieval order: the earliest-ranked law wins a number, and each
      # requested number contributes at most one article.
      rank = numacs.each_with_index.to_h
      rows.sort_by! { |row| [rank.fetch(row.content_numac, numacs.length), row.id] }
      seen = {}
      rows.each do |row|
        key = normalized_article_key(row.article_title)
        next unless by_normalized.key?(key)
        next if seen.key?(key)

        seen[key] = {
          id: row.id, numac: row.content_numac,
          law_title: row.law_title || lookup_law_title(row.content_numac, @language_id) ||
                     "Wetgeving #{row.content_numac}",
          article_title: row.article_title, article_text: row.article_text,
          article_variant: row.try(:article_variant),
          language_id: row.language_id, similarity: 0.0, cited_repair: true,
          is_abolished: row.try(:is_abolished) == 1,
          is_modification: row.try(:is_modification) == 1
        }
      end
      # Second pass for the numbers the exact-title SQL could not resolve.
      # Real titles carry suffixes the equality match can never see -
      # "Art. 37/2, par. 1", annotation tails, separator variants - so a
      # repairable citation stayed rejected even though the article sits in a
      # retrieved law (2026-08-04 withheld-answer mining: the largest wrong-
      # withhold cluster). This sweep reads TITLES ONLY for the same laws,
      # extracts each title's own number token, and compares through the same
      # normalization - an exact compare, never prefix matching, so "Art. 37"
      # cannot resolve to "Art. 370". TOEKOMSTIG RECHT variants are excluded:
      # citing future-law text as current law is the obsolete-version hazard,
      # not a repair.
      unresolved = by_normalized.keys.reject { |key| seen.key?(key) }
      if unresolved.any?
        title_rows = ::Article
                     .select(:id, :article_title, :content_numac)
                     .where(content_numac: numacs, language_id: @language_id)
                     .to_a
        rank = numacs.each_with_index.to_h
        matches = title_rows.filter_map do |row|
          key = article_number_key_from_title(row.article_title)
          next if key.nil? || !unresolved.include?(key)

          [key, row]
        end
        matches.sort_by! { |_key, row| [rank.fetch(row.content_numac, numacs.length), row.id] }
        chosen = {}
        matches.each { |key, row| chosen[key] ||= row.id }
        # Internal anchors spell separators as dashes (37/2 -> art-37-2,
        # 8.20 -> art-8-20). Only try that alias AFTER exact title/token
        # matching, and only when the literal number is unambiguous within
        # the selected law. A real Art. 100-16 must not become Art. 100/16.
        unresolved.each do |key|
          next if chosen.key?(key)

          alias_key = citation_article_alias_key(by_normalized.fetch(key))
          candidates = title_rows.select do |row|
            !article_number_key_from_title(row.article_title).nil? &&
              citation_article_alias_key(row.article_title) == alias_key
          end
          candidates.group_by(&:content_numac).sort_by { |numac, _| rank.fetch(numac) }.each do |_numac, same_law|
            literal_numbers = same_law.map { |row| citation_article_number_token(row.article_title).downcase }.uniq
            next unless literal_numbers.one?

            chosen[key] = same_law.min_by(&:id).id
            break
          end
        end
        if chosen.any?
          ::Article
            .select('articles.*, COALESCE(legislation.short_title, legislation.title) as law_title, ' \
                    'legislation.is_abolished, legislation.is_modification')
            .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
            .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
            .where(id: chosen.values)
            .each do |row|
              key = chosen.key(row.id)
              next if key.nil? || seen.key?(key)

              seen[key] = {
                id: row.id, numac: row.content_numac,
                law_title: row.law_title || lookup_law_title(row.content_numac, @language_id) ||
                           "Wetgeving #{row.content_numac}",
                article_title: row.article_title, article_text: row.article_text,
                article_variant: row.try(:article_variant),
                language_id: row.language_id, similarity: 0.0, cited_repair: true,
                is_abolished: row.try(:is_abolished) == 1,
                is_modification: row.try(:is_modification) == 1
              }
            end
        end
      end

      Rails.logger.info(
        "[CitationRepair] resolved #{seen.size}/#{wanted.length} cited articles from #{numacs.length} retrieved laws"
      )
      # Not optional. This method never passes through #search, and the orchestrator splices
      # its output straight into leg_articles AFTER the quality filters have run. It is also
      # the likeliest path to surface a future variant, precisely because it goes looking for
      # articles retrieval did not return.
      sanitize_future_law(seen.values)
    rescue StandardError => e
      Rails.logger.warn("[CitationRepair] lookup skipped: #{e.class}")
      []
    end

    def normalized_article_key(value)
      value.to_s.sub(/\A\s*Art(?:ikel|icle)?s?\.?\s*/i, '')
           .then { |number| "art#{number}" }
           .delete(' ')
           .sub(/\.+\z/, '')
           .downcase
    end

    # Public seam for the title-token extraction the repair fallback relies
    # on, so the exact-compare guarantee is unit-testable without a database.
    def article_number_key_from_title(title)
      return nil if title.to_s.match?(/TOEKOMSTIG\s+RECHT/i)

      token = title.to_s[/\bArt(?:ikel|icle)?\.?\s*([[:alnum:]][\w\/.:\-]*)/i, 1]
      return nil if token.blank?

      normalized_article_key(token)
    end

    def citation_article_number_token(value)
      value.to_s.sub(/\A\s*Art(?:ikel|icle)?s?\.?\s*/i, '')
           .then { |number| number[/\A[[:alnum:]][\w\/.:\-]*/] }
           .to_s.sub(/[.:\-]+\z/, '')
    end

    def citation_article_alias_key(value)
      citation_article_number_token(value).downcase.gsub(/[\/.:]/, '-')
    end

    private

    # ------------------------------------------------------------------
    # FAISS SEARCH
    # ------------------------------------------------------------------

    def legislation_faiss_enabled?
      ENV.fetch(FAISS_ENABLED_ENV, 'false').strip.casecmp?('true')
    end

    # Call FAISS service for fast article similarity search
    def search_faiss(question_embedding, limit)
      require 'net/http'
      require 'json'

      uri = URI("#{FAISS_URL}/search")
      request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      request.body = { embedding: question_embedding, limit: limit }.to_json

      # Keep the guard's ledger reads and source hydration in one SQLite read
      # snapshot. Otherwise an updater could change an approved ID between
      # freshness validation and reading the current article body.
      Article.connection_pool.with_connection do |connection|
        connection.transaction(requires_new: true) do
          checked = SemanticSourceFreshness.new(faiss_url: FAISS_URL).with_verified_response do
            response = Net::HTTP.start(uri.hostname, uri.port,
                                       use_ssl: uri.scheme == 'https',
                                       open_timeout: 5, read_timeout: 10) do |http|
              http.request(request)
            end
            raise SemanticSourceFreshness::Unavailable, :search_unavailable unless response.is_a?(Net::HTTPSuccess)

            JSON.parse(response.body)
          end
          unless checked.available?
            Rails.logger.warn("[Legislation FAISS] unavailable, keyword search only: #{checked.failure}")
            next nil
          end

          hydrate_faiss_response(checked.response)
        end
      end
    rescue StandardError => e
      # Class only: a message can echo response-body text.
      Rails.logger.warn("[Legislation FAISS] unavailable, keyword search only: #{e.class}")
      nil
    end

    def hydrate_faiss_response(data)
      Rails.logger.info("FAISS article search completed in #{data['search_time_ms']&.round(1)}ms (searched #{data['total_indexed']} articles)")

      article_ids = data['results'].map { |r| r['article_id'] }
      articles_by_id = Article
                       .select('articles.*, COALESCE(legislation.short_title, legislation.title) as law_title, legislation.date, legislation.is_abolished, legislation.is_modification')
                       .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
                       .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
                       .where(id: article_ids, language_id: CANONICAL_LANGUAGE_IDS)
                       .index_by(&:id)

      data['results'].map do |result|
        article = articles_by_id[result['article_id']]
        next unless article

        adjusted_similarity = article.language_id == @language_id ? result['similarity'] * 1.20 : result['similarity']

        {
          id: article.id,
          numac: article.content_numac,
          law_title: article.law_title || lookup_law_title(article.content_numac, article.language_id) || "Wetgeving #{article.content_numac}",
          article_title: article.article_title,
          article_text: article.article_text,
          article_variant: article.try(:article_variant),
          language_id: article.language_id,
          similarity: adjusted_similarity,
          is_abolished: article.try(:is_abolished) == 1,
          is_modification: article.try(:is_modification) == 1
        }
      end.compact.sort_by { |a| -a[:similarity] }
    end

    # ------------------------------------------------------------------
    # KEYWORD SEARCH
    # ------------------------------------------------------------------

    def find_by_keywords_fts(keywords, limit)
      match_expr = fts_exact_match_expression(keywords)
      return [] if match_expr.blank?

      article_ids = nil
      fts_search_database_paths.each do |search_path|
        begin
          db = fts_search_database(search_path)
          # A dedicated search database intentionally contains only the
          # extracted FTS/ngram tables, not `articles`. Pull a bounded BM25
          # window from FTS, then filter its rowids through the primary laws DB
          # while preserving rank. The helper expands the window when one
          # language dominates the top.
          article_ids = fts_ranked_article_ids(db, match_expr, limit * 3)

          # Exact phrase terms are precise, but Belgian legal vocabulary often
          # differs only by inflection (verjaring/verjaren, belaging/belaagd).
          # Supplement sparse exact results with conservative FTS prefix terms.
          if article_ids.length < limit
            stem_expr = fts_stemmed_match_expression(keywords)
            if stem_expr.present?
              stem_ids = fts_ranked_article_ids(db, stem_expr, limit * 3)
              added = stem_ids.reject { |id| article_ids.include?(id) }
              article_ids.concat(added)
              Rails.logger.info("[Search] FTS5 stem supplement added #{added.length} candidates") if added.any?
            end
          end
          break if article_ids.any?

          Rails.logger.info("[Search] No FTS5 hits in #{File.basename(search_path)}, trying fallback")
        rescue StandardError => e
          close_fts_search_database
          Rails.logger.warn("[Search] FTS5 error in #{File.basename(search_path)} (#{e.class}), trying fallback")
        end
      end

      if article_ids.nil?
        Rails.logger.warn('[Search] No usable FTS5 database found, falling back to LIKE')
        return []
      end

      return [] if article_ids.empty?

      articles_by_id = keyword_articles_with_metadata
                       .where(articles: { id: article_ids, language_id: @language_id })
                       .index_by(&:id)
      articles = article_ids.filter_map { |id| articles_by_id[id] }

      Rails.logger.info("[Search] FTS5 keyword search found #{articles.length} articles")

      articles.each_with_index.filter_map do |article, rank|
        {
          id: article.id,
          numac: article.content_numac,
          law_title: article.law_title || lookup_law_title(article.content_numac, article.language_id) || "Wetgeving #{article.content_numac}",
          article_title: article.article_title,
          article_text: article.article_text,
          article_variant: article.try(:article_variant),
          language_id: article.language_id,
          # Without these, a keyword-retrieved REPEALED article reached the
          # answer without the [OPGEHEVEN/ABROGÉ] warning the FAISS path adds.
          is_abolished: article.try(:is_abolished) == 1,
          is_modification: article.try(:is_modification) == 1,
          # Keep BM25 order meaningful when results are fused with FAISS.
          # This is intentionally below article pins (99.0) and conservative
          # versus a strong semantic match, while retaining lexical recall.
          similarity: [0.82 - (rank * 0.02), 0.65].max,
          keyword_rank: rank + 1
        }
      end.compact.take(limit)
    end

    # Prefer an explicitly configured search DB. Without one, prefer the
    # primary laws DB because current importers build articles_fts there; a
    # historical storage/search.sqlite3 file is the final compatibility
    # fallback and must not silently shadow the current laws database.
    def fts_search_database_paths
      configured_path = ENV.fetch('SEARCH_DB_PATH', nil).presence
      [configured_path, primary_fts_search_database_path, default_fts_search_database_path]
        .compact
        .map { |path| File.expand_path(path) }
        .select { |path| File.file?(path) }
        .uniq
    rescue StandardError => e
      Rails.logger.warn("[Search] Could not resolve FTS5 database paths: #{e.class}")
      []
    end

    def default_fts_search_database_path
      Rails.root.join('storage', 'search.sqlite3').to_s
    end

    def primary_fts_search_database_path
      Article.connection_db_config.database.to_s.presence
    end

    # Puma reuses worker threads. Bind the cached read-only connection to both
    # its resolved path and the file generation. Updaters install databases by
    # atomic rename, so a path-only cache can otherwise keep querying the old
    # inode after the pathname starts referring to the replacement database.
    def fts_search_database(path)
      resolved_path = File.expand_path(path)
      generation = fts_search_database_generation(resolved_path)
      cached_db = Thread.current[:search_db]
      cached_path = Thread.current[:search_db_path]
      cached_generation = Thread.current[:search_db_generation]
      if cached_db && cached_path == resolved_path && cached_generation == generation
        return cached_db
      end

      close_fts_search_database
      Thread.current[:search_db] = SQLite3::Database.new(resolved_path, readonly: true)
      Thread.current[:search_db_path] = resolved_path
      Thread.current[:search_db_generation] = generation
      Thread.current[:search_db]
    end

    def fts_search_database_generation(path)
      stat = File.stat(path)
      [
        stat.dev,
        stat.ino,
        stat.size,
        (stat.mtime.to_i * 1_000_000_000) + stat.mtime.nsec
      ]
    end

    def close_fts_search_database
      Thread.current[:search_db]&.close
    rescue StandardError
      nil
    ensure
      Thread.current[:search_db] = nil
      Thread.current[:search_db_path] = nil
      Thread.current[:search_db_generation] = nil
    end

    # Build a safe exact-phrase FTS expression. Tokenizing first avoids FTS5
    # treating punctuation in user input (e.g. parentheses or apostrophes) as
    # query operators.
    def fts_exact_match_expression(keywords)
      keywords.filter_map do |keyword|
        phrase = fts_tokens(keyword).join(' ')
        "\"#{phrase}\"" if phrase.present?
      end.uniq.join(' OR ')
    end

    # The dedicated search DB has no `articles` table, so language cannot be
    # filtered in the FTS SQL itself. Expand a small ranked window until enough
    # rowids survive a language lookup in the primary laws DB. This keeps BM25
    # order, avoids the former invalid cross-database JOIN, and prevents an NL
    # or FR-heavy top window from starving the requested language.
    def fts_ranked_article_ids(db, match_expr, desired)
      fetch_limit = [desired * 2, 30].max
      max_fetch = [desired * 32, 480].max

      loop do
        rows = db.execute(
          'SELECT rowid FROM articles_fts WHERE articles_fts MATCH ? ORDER BY rank LIMIT ?',
          [match_expr, fetch_limit]
        )
        ranked_ids = rows.map { |row| row[0] }
        language_ids = article_ids_in_language(ranked_ids)
        filtered = ranked_ids.select { |id| language_ids.include?(id) }
        return filtered.take(desired) if filtered.length >= desired || rows.length < fetch_limit || fetch_limit >= max_fetch

        fetch_limit = [fetch_limit * 2, max_fetch].min
      end
    end

    def article_ids_in_language(article_ids)
      return Set.new if article_ids.empty?

      Article.where(id: article_ids, language_id: @language_id).pluck(:id).to_set
    end

    # Prefix fallback for inflectional vocabulary mismatch. It runs only when
    # the exact search produced fewer than the requested result count.
    def fts_stemmed_match_expression(keywords)
      prefixes = keywords.flat_map do |keyword|
        fts_tokens(keyword).flat_map { |token| fts_prefixes_for(token) }
      end.uniq
      prefixes.map { |prefix| "#{prefix}*" }.join(' OR ')
    end

    def fts_tokens(value)
      value.to_s.downcase.scan(/[\p{L}\p{N}]+/)
    end

    def fts_prefixes_for(token)
      prefixes = FTS_IRREGULAR_PREFIXES.fetch(token, []).dup
      suffix = FTS_STEM_SUFFIXES.find { |candidate| token.end_with?(candidate) }
      if suffix
        stem = token.delete_suffix(suffix)
        prefixes << stem if stem.length >= 5
      end
      prefixes.uniq
    end

    def find_by_keywords_like(keywords, limit)
      conditions = []
      params = []
      keywords.each do |kw|
        # Parameterized bind: no manual quote-doubling (that made "d'office"
        # match the literal string "d''office", i.e. never). Escape only the
        # LIKE wildcards, with an explicit ESCAPE char for SQLite.
        conditions << "article_text LIKE ? ESCAPE '\\'"
        params << "%#{ActiveRecord::Base.sanitize_sql_like(kw)}%"
      end

      articles = nil
      begin
        Timeout.timeout(5) do
          articles = keyword_articles_with_metadata
                     .where(conditions.join(' OR '), *params)
                     .where(articles: { language_id: @language_id })
                     .limit(limit * 3)
                     .to_a
        end
      rescue Timeout::Error
        Rails.logger.warn('[Search] Keyword LIKE search timed out after 5s, skipping')
        return []
      end

      articles.map do |article|
        {
          id: article.id,
          numac: article.content_numac,
          law_title: article.law_title || lookup_law_title(article.content_numac, article.language_id) || "Wetgeving #{article.content_numac}",
          article_title: article.article_title,
          article_text: article.article_text,
          article_variant: article.try(:article_variant),
          language_id: article.language_id,
          is_abolished: article.try(:is_abolished) == 1,
          is_modification: article.try(:is_modification) == 1,
          similarity: 0.75
        }
      end.compact.take(limit)
    end

    KEYWORD_CONTENT_JOIN = 'LEFT JOIN contents ON articles.content_numac = contents.legislation_numac ' \
                           'AND articles.language_id = contents.language_id'
    KEYWORD_LEGISLATION_JOIN = 'LEFT JOIN legislation ON contents.legislation_numac = legislation.numac ' \
                               'AND contents.language_id = legislation.language_id'

    # Article's legacy `belongs_to :content` is keyed only by NUMAC. With NL
    # and FR Content rows for the same law, `includes(:content)` can attach the
    # other language's legislation metadata. Hydrate lexical results through
    # explicit composite (NUMAC + language) joins instead.
    def keyword_articles_with_metadata
      Article
        .select('articles.*, COALESCE(legislation.short_title, legislation.title) AS law_title, ' \
                'legislation.is_abolished AS is_abolished, legislation.is_modification AS is_modification')
        .joins(KEYWORD_CONTENT_JOIN)
        .joins(KEYWORD_LEGISLATION_JOIN)
    end

    # ------------------------------------------------------------------
    # BOOSTING & FILTERING
    # ------------------------------------------------------------------

    def matching_core_law_numacs(question)
      question_lower = question.downcase
      relevant_core_numacs = Set.new
      KEYWORD_TO_CORE_LAWS.each do |keyword, numacs|
        kw = keyword.to_s.downcase
        # Prefix word-boundary match: the keyword must START at a word
        # boundary but may continue into a compound ('huur' still matches
        # 'huurcontract'). Plain include? made 'koop' match inside
        # 'verkoop', injecting+boosting Oud BW articles to the top of the
        # ranking for e.g. VAT questions about online sales.
        right_boundary = EXACT_CORE_LAW_KEYWORDS.include?(kw) ? '(?![[:alnum:]])' : ''
        pattern = /(?<![[:alnum:]])#{Regexp.escape(kw)}#{right_boundary}/
        next unless question_lower.match?(pattern)
        # Several short catalogue keys are ordinary words or abbreviations in
        # other contexts. Keep explicit legal phrases, but do not let an
        # everyday use inject a neighbouring regime.
        next if kw == 'tax' && question_lower.match?(/\btaxi\w*/i)
        next if kw == 'aangifte' && MarketplaceCivilClaimIntent.topic?(question) &&
                !MarketplaceCivilClaimIntent.tax_question?(question)
        next if kw == 'bv' && !company_context?(question_lower)
        next if kw == 'cv' && !company_context?(question_lower)
        next if kw == 'garde' && (!custody_context?(question_lower) || police_custody_context?(question_lower))
        next if kw == 'ziekte' && !workplace_context?(question_lower)
        next if kw == 'prescription' && medical_context?(question_lower)
        next if %w[camera caméra].include?(kw) && question_lower.match?(TECHNICAL_CAMERA_PATTERN) &&
                !question_lower.match?(SURVEILLANCE_CAMERA_PATTERN)
        next if ['acte constitutif', 'acte de constitution'].include?(kw) && !formation_deed_entity_context?(question)
        next if kw == 'congé' && rental_context?(question_lower) && !workplace_context?(question_lower)
        next if %w[veiligheid preventie sécurité prévention].include?(kw) && !workplace_context?(question_lower)
        # "Wer" is the German interrogative, not necessarily the Belgian
        # Economic Law code. Preserve explicit WER (or its spelled-out legal
        # context) without turning every German "Who...?" into economic law.
        next if kw == 'wer' && @language == 'de' &&
                !question.match?(/(?<![[:alnum:]])WER(?![[:alnum:]])/) &&
                !question_lower.match?(/wirtschafts(?:gesetzbuch|recht)|gesetzbuch\s+des\s+wirtschaftsrechts|wetboek\s+(?:van\s+)?economisch\s+recht|code\s+de\s+droit\s+[eé]conomique|economic\s+law\s+code/)

        # "verblijf" is ambiguous in family, hospital and childcare
        # questions; only the immigration sense should promote the Aliens Act.
        next if AMBIGUOUS_RESIDENCE_KEYS.include?(kw) && !immigration_context?(question_lower)

        numacs.each do |n|
          # "Terugbetaling" is deliberately mapped to both consumer and
          # health-insurance law. In a clearly medical-insurance question,
          # keep ZIV but do not inject WER merely because reimbursement was
          # mentioned.
          next if kw == 'terugbetaling' && n == '2013A11134' && health_insurance_context?(question_lower)

          relevant_core_numacs.add(n)
        end
      end

      # Card-payment questions have no dedicated short catalogue key. The
      # economic code remains the safe consumer-law source for payment-card
      # rights, but only when the question actually names a card/payment
      # instrument; never infer it from a generic "betalen".
      relevant_core_numacs.add('2013A11134') if payment_card_context?(question_lower)
      if patient_rights_context?(question_lower)
        relevant_core_numacs.merge(%w[2002022737 2002S82909])
      end
      relevant_core_numacs.add('2018015087') if question_lower.match?(FLANDERS_RESIDENTIAL_RENTAL_PATTERN)
      relevant_core_numacs.add('1804032154') if question_lower.match?(CONSUMER_GOODS_WARRANTY_PATTERN)
      relevant_core_numacs.add('2022A32058') if question_lower.match?(PROFESSIONAL_REPAIR_DAMAGE_PATTERN)
      relevant_core_numacs.add('1804032154') if question_lower.match?(HOUSE_PURCHASE_HIDDEN_DEFECT_PATTERN)
      relevant_core_numacs.add('1967101053') if question_lower.match?(LAWYER_FEE_PATTERN)
      relevant_core_numacs.add('2014011239') if question_lower.match?(LEGAL_EXPENSE_INSURANCE_PATTERN)
      relevant_core_numacs.add('1971031602') if question_lower.match?(OFFICE_COMMUTE_WORK_PATTERN)
      relevant_core_numacs.add('2013A11134') if TelemarketingPrivacyIntent.topic?(question)
      relevant_core_numacs.merge(%w[2013A11134 2018040581]) if CommercialWebsiteIntent.topic?(question)
      relevant_core_numacs.add('2013000441') if MunicipalSanctionsSourceScope.topic?(question)
      relevant_core_numacs.merge(MarketplaceCivilClaimIntent.article_targets(question).map(&:first))
      relevant_core_numacs.merge(vehicle_headlight_targets(question).map(&:first))
      if question.match?(HOUSE_PURCHASE_HIDDEN_DEFECT_PATTERN) && !question.match?(HOUSE_ECONOMIC_LAW_CONTEXT_PATTERN)
        relevant_core_numacs.delete('2013A11134')
      end

      # Safety and prevention are ordinary words outside employment law.
      # Their specific compounds (preventieadviseur, veiligheidscomité, ...)
      # remain mapped independently; only the generic catalogue keys require
      # an occupational context.

      relevant_core_numacs.subtract(INVALID_LEGISLATION_NUMACS)

      # The 1867 Criminal Code was replaced on 8 April 2026. Keep it available
      # only for explicitly historical facts; otherwise stale semantic hits
      # must not outrank the current 2024 Books I/II.
      if historical_criminal_exposition?(question_lower)
        relevant_core_numacs.subtract(CURRENT_CRIMINAL_CODE_NUMACS)
        relevant_core_numacs.add(LEGACY_CRIMINAL_CODE_NUMAC)
      elsif legacy_criminal_fact_question?(question_lower)
        # Facts before the 2026 cutover can require the more-favourable-law
        # comparison. Retrieve both the historical provisions and current
        # Books I/II; Book I Art. 2 is pinned below as the transition rule.
        relevant_core_numacs.add(LEGACY_CRIMINAL_CODE_NUMAC)
        relevant_core_numacs.merge(CURRENT_CRIMINAL_CODE_NUMACS)
      else
        relevant_core_numacs.delete(LEGACY_CRIMINAL_CODE_NUMAC)
      end


      if question_lower.match?(REGIONAL_FAMILY_BENEFIT_PATTERN)
        # 1967102704 was historically mislabeled as a family-benefit law in
        # this app. It is not a current family-benefit regime. Remove stale
        # semantic hits even though the keyword mapping itself is gone.
        relevant_core_numacs.delete('1967102704')
      end


      # Inheritance, donation, registration, and property taxes are regional.
      # VCF is Flemish; the consolidated W.Succ./W.Reg. texts serve Brussels
      # and Wallonia. Never mix those regimes or silently choose Flanders for
      # a question that did not identify a region.
      if (allowed_regional_tax_numacs = regional_tax_numacs_for(question_lower))
        relevant_core_numacs.delete_if do |numac|
          REGIONAL_TAX_NUMACS.include?(numac) && !allowed_regional_tax_numacs.include?(numac)
        end
      end


      if (allowed_housing_numacs = regional_housing_numacs_for(question_lower))
        relevant_core_numacs.delete_if do |numac|
          REGIONAL_HOUSING_NUMACS.include?(numac) && !allowed_housing_numacs.include?(numac)
        end
      end

      # Spatial planning and environmental permits are regional. The mapped
      # NUMACs below are Flemish and must never be injected for an unqualified
      # or explicitly Brussels/Walloon question.
      if (allowed_planning_numacs = regional_planning_numacs_for(question_lower))
        relevant_core_numacs.delete_if do |numac|
          FLANDERS_PLANNING_NUMACS.include?(numac) && !allowed_planning_numacs.include?(numac)
        end
      end

      relevant_core_numacs
    end

    def immigration_context?(question)
      question.match?(IMMIGRATION_CONTEXT_PATTERN) ||
        (question.match?(IMMIGRATION_VISA_PATTERN) && !question.match?(VISA_PAYMENT_PATTERN))
    end

    def workplace_context?(question)
      question.match?(WORKPLACE_CONTEXT_PATTERN)
    end

    def company_context?(question)
      return false if question.match?(NON_COMPANY_ABBREVIATION_CONTEXT_PATTERN)

      question.match?(COMPANY_CONTEXT_PATTERN) ||
        question.match?(COMPANY_ACTION_CONTEXT_PATTERN) ||
        question.strip.match?(/\A(?:bv|cv|nv|vzw|asbl|srl|sprl|gmbh|llc)\z/i) ||
        question.match?(COMPANY_DEFINITION_PATTERN)
    end

    def custody_context?(question)
      question.match?(CUSTODY_CONTEXT_PATTERN)
    end

    def police_custody_context?(question)
      question.match?(POLICE_CUSTODY_CONTEXT_PATTERN)
    end

    def medical_context?(question)
      question.match?(MEDICAL_CONTEXT_PATTERN)
    end

    def health_insurance_context?(question)
      question.match?(HEALTH_INSURANCE_CONTEXT_PATTERN)
    end

    def payment_card_context?(question)
      question.match?(PAYMENT_CARD_CONTEXT_PATTERN)
    end

    def patient_rights_context?(question)
      question.match?(PATIENT_RIGHTS_CONTEXT_PATTERN)
    end

    def rental_context?(question)
      question.match?(RENTAL_CONTEXT_PATTERN)
    end

    def apply_core_law_boosting(articles, question, profile: 'general')
      question_lower = question.downcase
      question_words = meaningful_query_words(question_lower)
      relevant_core_numacs = matching_core_law_numacs(question)

      # INJECTION: If core laws are relevant but missing, inject them
      if relevant_core_numacs.any?
        existing_numacs = articles.to_set { |a| a[:numac] }
        missing_numacs = relevant_core_numacs - existing_numacs

        if missing_numacs.any?
          injected = inject_core_law_articles(missing_numacs, question_lower)
          if injected.any?
            Rails.logger.info("Core law injection: Added #{injected.length} articles")
            articles += injected
          end
        end
      end

      # CONTEXT LAW INJECTION: If user is viewing a specific law and FAISS didn't find it,
      # inject articles from that law so sources are relevant to the viewed page
      context_numacs_set = Set.new(@context_numacs)
      if context_numacs_set.any?
        existing_numacs = articles.to_set { |a| a[:numac] }
        missing_context = context_numacs_set - existing_numacs
        if missing_context.any?
          injected = inject_core_law_articles(missing_context, question_lower)
          if injected.any?
            Rails.logger.info("[ContextBoost] Injected #{injected.length} articles from viewed law(s)")
            articles += injected
          end
        end
      end

      # Scope once, after every source of candidates (semantic, lexical, core
      # injection, and viewed-law context) has been combined. This is the
      # fail-closed boundary that prevents later pipeline stages from
      # reintroducing an inapplicable law.
      articles = scope_articles_to_question(articles, question)

      # Resolve profile-preferred numacs (nudge, not restrict)
      profile_numacs = Set.new(PROFILE_PREFERRED_NUMACS[profile] || [])

      boosted = articles.map do |article|
        numac = article[:numac]
        law_title = article[:law_title] || ''
        boost = 1.0

        if CORE_LAW_NUMACS.key?(numac)
          # A core-law label alone is not evidence that the law governs this
          # question. Preserve the strong promotion for an explicit keyword
          # match, but leave unrelated core neighbours neutral so they cannot
          # displace a semantically exact specialist act.
          boost = relevant_core_numacs.include?(numac) ? CORE_LAW_BOOST * 1.1 : CORE_LAW_UNMATCHED_BOOST
        elsif is_sector_cao?(law_title)
          boost = CAO_PENALTY
        end

        boost *= 1.05 if article[:modification_count].to_i > 50
        boost *= 0.7 if law_title =~ /covid|corona|pandemie|tijdelijke.*2020|tijdelijke.*2021/i
        boost *= 0.5 if article[:is_modification]
        boost *= 0.3 if article[:is_abolished]

        article_text = article[:article_text].to_s.downcase
        boost *= 0.5 if article_text =~ /\b(opgeheven|abrogé|afgeschaft|geschrapt)\b/

        boost *= FISCONET_PENALTY if is_fisconet_source?(numac, law_title) && !tax_question?(question_lower)

        # Profile-based nudge: preferred laws for the selected category get boosted
        # This stacks with core law boosting - a tax law in the 'tax' profile gets both boosts
        if profile_numacs.include?(numac)
          boost *= PROFILE_BOOST
        end

        # Context law boost: user is viewing this law - strongest boost to ensure relevance
        if context_numacs_set.include?(numac)
          boost *= CONTEXT_LAW_BOOST
        end

        # Keyword overlap boost: articles containing more question words rank higher
        # Naturally handles years, specific terms, etc. without special-casing
        if question_words.any?
          combined_text = "#{law_title} #{article_text}"
          matches = question_words.count { |w| combined_text.include?(w) }
          if matches.positive?
            # Scale boost by overlap ratio: 1 of 3 words = small boost, 3 of 3 = strong boost
            overlap_ratio = matches.to_f / question_words.length
            boost *= 1.0 + (overlap_ratio * 0.4) # max +40% for full overlap
          end
        end

        article.merge(similarity: article[:similarity] * boost, boosted: boost > 1.0)
      end

      result = boosted.sort_by { |a| -a[:similarity] }
      core_in_top5 = result.take(5).count { |a| a[:boosted] }
      profile_in_top5 = result.take(5).count { |a| profile_numacs.include?(a[:numac]) }
      context_in_top5 = result.take(5).count { |a| context_numacs_set.include?(a[:numac]) }
      Rails.logger.info("Core law boosting: #{core_in_top5}/5 top results boosted, #{profile_in_top5}/5 profile-preferred") if core_in_top5.positive? || profile_in_top5.positive?
      Rails.logger.info("[ContextBoost] #{context_in_top5}/5 top results from viewed law") if context_in_top5.positive?
      Rails.logger.info("[KeywordOverlap] Boosted using #{question_words.size} normalized question terms") if question_words.any?
      result
    end

    def matching_article_pins(question)
      # A legal form on a second line is still part of the same question.
      question = question.to_s.gsub(/[[:space:]]+/, ' ')
      matched = ARTICLE_PINS.select { |pattern, _numac, _article| question.match?(pattern) }
                            .uniq { |_pattern, numac, article| [numac, article] }
      commercial_targets = CommercialWebsiteIntent.article_targets(question)
      if commercial_targets.any?
        matched = (commercial_targets.map { |numac, number| [CommercialWebsiteIntent::QUESTION_PATTERN, numac, number] } + matched)
                  .uniq { |_pattern, numac, article| [numac, article] }
      end
      marketplace_targets = MarketplaceCivilClaimIntent.article_targets(question)
      if marketplace_targets.any?
        matched = (marketplace_targets.map { |numac, number| [MarketplaceCivilClaimIntent::CLAIM_PATTERN, numac, number] } + matched)
                  .uniq { |_pattern, numac, article| [numac, article] }
      end
      if question.match?(FORMATION_DEED_PATTERN) && formation_deed_entity_context?(question)
        forms = self.class.formation_deed_forms(question)
        if forms.length > 1
          # Comparisons keep the shared rule and each named form's primary
          # provision, without consuming the generic cluster or a full pack.
          wanted = Set.new(['2:5'] + forms.flat_map { |form| FORMATION_DEED_FORM_PRIMARY_ARTICLES.fetch(form) })
          matched = matched.select { |_pattern, numac, article| numac != '2019A40586' || wanted.include?(article) }
        elsif forms.empty? && !question.match?(FORMATION_DEED_GENERIC_PATTERN)
          # A comparison without a recognized form gets the bounded generic
          # cluster; dependency packs are only safe for one named form.
          generic = ARTICLE_PINS.select { |pattern, numac, _article| pattern.equal?(FORMATION_DEED_GENERIC_PATTERN) && numac == '2019A40586' }
          matched = (matched.reject { |_pattern, numac, _article| numac == '2019A40586' } + generic)
                    .uniq { |_pattern, numac, article| [numac, article] }
        end
      end
      matched.reject! { |_pattern, numac, _article| numac == '2019A40586' } unless formation_deed_entity_context?(question)
      foreign_succession_targets = self.class.foreign_succession_applicability_targets(question)
      if foreign_succession_targets.any?
        matched.reject! do |_pattern, numac, number|
          FOREIGN_SUCCESSION_APPLICABILITY_TARGETS.include?([numac, number]) &&
            !foreign_succession_targets.include?([numac, number])
        end
      end
      headlight_targets = vehicle_headlight_targets(question)
      if VehicleHeadlightGlareSourceScope.topic?(question)
        # Filter before source rows become :pinned; a later relevance gate
        # deliberately preserves user selections and cannot undo auto pins.
        matched.reject! do |_pattern, numac, number|
          VEHICLE_HEADLIGHT_PRIORITY.include?([numac, number]) && !headlight_targets.include?([numac, number])
        end
      end
      priority = if question.match?(HOUSE_PURCHASE_HIDDEN_DEFECT_PATTERN)
                   # Five-source searches must retain the additional subjects
                   # actually asked about. Keep the liability/time-limit pair
                   # first, then fees/insurance. Seller liability/exclusion is
                   # the fifth rule in that mixed query; remedies follow it.
                   asked_topics = []
                   asked_topics << %w[1967101053 446ter] if question.match?(LAWYER_FEE_PATTERN)
                   asked_topics << %w[2014011239 156] if question.match?(LEGAL_EXPENSE_INSURANCE_PATTERN)
                   HOUSE_HIDDEN_DEFECT_PRIORITY.take(2) + asked_topics + HOUSE_HIDDEN_DEFECT_PRIORITY.drop(2)
                 elsif question.match?(OFFICE_COMMUTE_WORK_PATTERN)
                   OFFICE_COMMUTE_PRIORITY
                 elsif TelemarketingPrivacyIntent.topic?(question)
                   TELEMARKETING_PRIORITY
                 elsif commercial_targets.any?
                   commercial_targets
                 elsif MunicipalSanctionsSourceScope.topic?(question)
                   MUNICIPAL_SANCTIONS_PRIORITY
                 elsif headlight_targets.any?
                   headlight_targets
                 elsif foreign_succession_targets.any?
                   foreign_succession_targets
                 end
      if priority
        matched = matched.each_with_index.sort_by do |((_pattern, numac, number), index)|
          [priority.index([numac, number]) || priority.length, index]
        end.map(&:first)
      end
      if question.match?(PROFESSIONAL_REPAIR_DAMAGE_PATTERN)
        # Five-source models still need fault, repair and formal-notice
        # evidence for the new damage. Keep the sales remedy as a separate
        # fifth source when there is also an original warranty issue; further
        # dependencies stay available under larger source budgets.
        priority = [%w[2022A32058 5.83], %w[2022A32058 5.86], %w[2022A32058 5.225],
                    %w[2022A32058 5.231], %w[1804032154 1649quinquies]]
        matched = matched.each_with_index.sort_by do |((_pattern, numac, number), index)|
          [priority.index([numac, number]) || priority.length, index]
        end.map(&:first)
      end
      return matched unless historical_criminal_exposition?(question)

      matched.reject { |_pattern, numac, _article| CURRENT_CRIMINAL_CODE_NUMACS.include?(numac) }
    end

    def vehicle_headlight_targets(question)
      scope = VehicleHeadlightGlareSourceScope
      return [] unless scope.topic?(question)

      VEHICLE_HEADLIGHT_PRIORITY.select do |numac, _number|
        case numac
        when '2026004490' then scope.temporal_companion_applicable?(question)
        when '1975120109' then scope.roadcode_applicable?(question)
        when '2024001600' then scope.book_six_applicable?(question)
        else true
        end
      end
    end

    def self.formation_deed_entity_context?(question)
      !question.match?(FORMATION_DEED_NON_ENTITY_PATTERN) ||
        question.match?(FORMATION_DEED_FORM_PATTERN) || question.match?(COMPANY_CONTEXT_PATTERN)
    end

    def self.formation_deed_explicit_form(question)
      forms = formation_deed_forms(question)
      forms.one? ? forms.first : nil
    end

    def self.formation_deed_forms(question)
      FORMATION_DEED_FORM_PATTERNS.filter_map do |form, pattern|
        form if question.match?(pattern)
      end
    end

    def self.formation_deed_dependency_pack(question)
      normalized = question.to_s.gsub(/[[:space:]]+/, ' ')
      return nil unless normalized.match?(FORMATION_DEED_PATTERN)
      return nil unless formation_deed_entity_context?(normalized)

      form = formation_deed_explicit_form(normalized)
      return nil unless %i[bv cv nv].include?(form)

      FORMATION_DEED_DEPENDENCY_PACKS[form]
    end

    def self.formation_deed_pack_size(question)
      formation_deed_dependency_pack(question)&.length
    end

    def formation_deed_explicit_form(question)
      self.class.formation_deed_explicit_form(question)
    end

    def formation_deed_dependency_pack(question)
      self.class.formation_deed_dependency_pack(question)
    end

    def formation_deed_pack_size(question)
      self.class.formation_deed_pack_size(question)
    end

    def formation_deed_entity_context?(question)
      self.class.formation_deed_entity_context?(question)
    end

    def legacy_criminal_code_question?(question)
      historical_criminal_exposition?(question) || legacy_criminal_fact_question?(question)
    end

    def legacy_criminal_fact_question?(question)
      question.match?(LEGACY_CRIMINAL_FACT_PATTERN)
    end

    def historical_criminal_exposition?(question)
      question.match?(LEGACY_CRIMINAL_CODE_NAME_PATTERN) && !legacy_criminal_fact_question?(question)
    end

    # Repair lookups must pass every subject/regional gate, not merely the
    # generic specialist check. Preserve deliberate source selection without
    # treating a cited_repair flag as evidence of applicability.
    def scope_repair_articles_to_question(articles, question)
      scoped = scope_articles_to_question(articles, question)
      context_numacs = @context_numacs.map(&:to_s)
      articles.select do |article|
        numac = (article[:numac] || article['numac']).to_s
        next false if INVALID_LEGISLATION_NUMACS.include?(numac)

        explicitly_selected = article[:pinned] || article['pinned'] || context_numacs.include?(numac) ||
                              (numac.present? && question.to_s.downcase.include?(numac.downcase))
        explicitly_selected || scoped.include?(article)
      end
    end

    def scope_articles_to_question(articles, question)
      telemarketing_scope_resolver.preload(articles) if TelemarketingPrivacyIntent.topic?(question)
      safe_articles = articles.reject do |article|
        numac = (article[:numac] || article['numac']).to_s
        explicitly_selected = article[:pinned] || article['pinned'] || @context_numacs.map(&:to_s).include?(numac)
        INVALID_LEGISLATION_NUMACS.include?(article[:numac]) || (!explicitly_selected && !contextual_source_relevant?(article, question))
      end
      scoped = if historical_criminal_exposition?(question)
                 safe_articles.reject { |article| CURRENT_CRIMINAL_CODE_NUMACS.include?(article[:numac]) }
               elsif legacy_criminal_fact_question?(question)
                 safe_articles
               else
                 safe_articles.reject { |article| article[:numac] == LEGACY_CRIMINAL_CODE_NUMAC }
               end

      if question.match?(REGIONAL_FAMILY_BENEFIT_PATTERN)
        scoped = scoped.reject { |article| article[:numac] == '1967102704' }
      end

      if (allowed = regional_tax_numacs_for(question))
        scoped = scoped.reject do |article|
          REGIONAL_TAX_NUMACS.include?(article[:numac]) && !allowed.include?(article[:numac]) &&
            !self.class.foreign_succession_applicability_source?(article, question)
        end
      end

      if (allowed = regional_housing_numacs_for(question))
        scoped = scoped.reject do |article|
          REGIONAL_HOUSING_NUMACS.include?(article[:numac]) && !allowed.include?(article[:numac])
        end
        scoped = scoped.reject do |article|
          HOUSING_CONTEXT_EXCLUDED_NUMACS.include?(article[:numac]) && !employment_context_question?(question)
        end
      end

      # Do this after the regional choice above, so this is a relevance gate
      # for all remaining lanes (semantic, lexical, core injection and viewed
      # law), not a replacement for jurisdiction selection. A source selected
      # explicitly by the user through the current law view, or deliberately
      # pinned for a verified rule, remains available.
      if question.match?(FLANDERS_RESIDENTIAL_RENTAL_PATTERN)
        scoped = scoped.select { |article| focused_residential_tenancy_source?(article, question) }
      end

      if (allowed = regional_short_commercial_numacs_for(question))
        scoped = scoped.reject do |article|
          %w[2016036108 2018201406 2019041090].include?(article[:numac]) && !allowed.include?(article[:numac])
        end
      end

      if (allowed = regional_planning_numacs_for(question))
        scoped = scoped.reject do |article|
          FLANDERS_PLANNING_NUMACS.include?(article[:numac]) && !allowed.include?(article[:numac])
        end
      end

      scoped
    end

    def focused_residential_tenancy_source?(article, question)
      numac = (article[:numac] || article['numac']).to_s
      return true if article[:pinned] || @context_numacs.map(&:to_s).include?(numac)
      return true if numac.present? && question.include?(numac)
      return true if numac == '2018015087'
      return true if specialist_source_matches_question?(article, question)

      source_text = [article[:law_title], article['law_title'], article[:title], article['title'],
                     article[:article_title], article['article_title'], article[:article_text], article['article_text']].compact.join(' ')
      source_text.match?(RESIDENTIAL_HOUSING_SOURCE_PATTERN) ||
        source_text.match?(RESIDENTIAL_TENANCY_RELATIONSHIP_PATTERN)
    end

    def specialist_source_matches_question?(article, question)
      title = (article[:law_title] || article[:title] || article['law_title'] || article['title']).to_s
      CONTEXTUAL_SPECIALIST_SOURCE_GATES.any? do |source_pattern, query_pattern|
        title.match?(source_pattern) && question.match?(query_pattern)
      end
    end

    def contextual_source_relevant?(article, question)
      numac = (article[:numac] || article['numac']).to_s
      return true if article[:pinned] || article['pinned'] || @context_numacs.map(&:to_s).include?(numac)

      self.class.contextual_source_relevant?(article, question, telemarketing_scope_resolver: telemarketing_scope_resolver)
    end

    def telemarketing_scope_resolver
      @telemarketing_scope_resolver ||= TelemarketingLawEnforcementScope::Resolver.new
    end

    # Shared by the federal candidate routes and the regional-result boundary.
    # RegionalSearch emits :title rather than :law_title; neither lane should
    # acquire a specialist exception just because its adapter uses another key.
    def self.contextual_source_relevant?(article, question, telemarketing_scope_resolver: nil)
      question = question.to_s
      numac = article[:numac] || article['numac']
      return true if numac.present? && question.downcase.include?(numac.to_s.downcase)
      return true if article[:pinned] || article['pinned']

      return false unless TelemarketingLawEnforcementScope.source_relevant?(article, question, resolver: telemarketing_scope_resolver)

      return false unless MunicipalSanctionsSourceScope.source_relevant?(article, question: question)
      return false unless VehicleHeadlightGlareSourceScope.source_relevant?(article, question)
      return false unless CommercialWebsiteIntent.source_relevant?(article, question)
      return false unless AirPassengerSourceScope.source_relevant?(article, question)
      return false unless MarketplaceCivilClaimIntent.source_relevant?(article, question)
      return false unless PlatformModerationSourceScope.source_relevant?(article, question)

      title = (article[:law_title] || article[:title] || article['law_title'] || article['title']).to_s
      technical_camera = question.match?(TECHNICAL_CAMERA_PATTERN) && !question.match?(SURVEILLANCE_CAMERA_PATTERN)
      return false if numac == '2007000528' && technical_camera

      house_defect = question.match?(HOUSE_PURCHASE_HIDDEN_DEFECT_PATTERN)
      commuter_work = question.match?(OFFICE_COMMUTE_WORK_PATTERN)
      foreign_succession = question.match?(FOREIGN_DECEASED_SUCCESSION_TAX_PATTERN)
      telemarketing_privacy = TelemarketingPrivacyIntent.topic?(question)
      if telemarketing_privacy
        source_text = [title, article[:article_text], article['article_text']].compact.join(' ').gsub(/\s+/, ' ')
        # These calls fund heat installations; their title may say only
        # "ondersteuning", without the old grant/application vocabulary.
        energy_support_call = title.match?(TELEMARKETING_ENERGY_CALL_PATTERN) &&
                              title.match?(TELEMARKETING_ENERGY_SUPPORT_PATTERN) &&
                              title.match?(TELEMARKETING_ENERGY_SUPPORT_SUBJECT_PATTERN)
        energy_support_requested = energy_support_call &&
                                   question.split(/[.!?;\n]+/).any? do |clause|
                                     financial_request = clause.match?(TELEMARKETING_FINANCIAL_SUPPORT_PATTERN)
                                     only_other_support = clause.match?(TELEMARKETING_NONFUNDING_SUPPORT_PATTERN) ||
                                                          clause.match?(TELEMARKETING_DIRECT_PRIVACY_PAIR_PATTERN)
                                     clause.match?(TELEMARKETING_ENERGY_SUPPORT_SUBJECT_PATTERN) &&
                                       clause.match?(TELEMARKETING_ENERGY_SUPPORT_PATTERN) && clause.match?(TELEMARKETING_TOPIC_REQUEST_PATTERN) &&
                                       (financial_request || !only_other_support)
                                   end
        return false if energy_support_call && !energy_support_requested
        return false if TELEMARKETING_SPECIALIST_SOURCE_GATES.any? do |source_pattern, query_pattern|
          # A real energy-support request also qualifies when the same title
          # uses older grant terminology in another language.
          next false if source_pattern.equal?(TELEMARKETING_GRANT_CALL_SOURCE_PATTERN) && energy_support_requested

          source_text.match?(source_pattern) && !question.match?(query_pattern)
        end

        # A general contractual-performance remedy is not a GDPR right.
        # Inspect the article's own text, not the whole Civil Code title;
        # actual data-right evidence and a mixed contract-remedy question
        # still earn relevance without a law-id exception.
        article_text = [article[:article_title], article['article_title'], article[:article_text], article['article_text']].compact.join(' ').gsub(/\s+/, ' ')
        contract_remedy = article_text.match?(TELEMARKETING_CONTRACT_SUBJECT_PATTERN) &&
                          article_text.match?(TELEMARKETING_CONTRACT_REMEDY_PATTERN)
        if contract_remedy && !article_text.match?(TELEMARKETING_DIRECT_PRIVACY_PAIR_PATTERN)
          contract_question = question.match?(TELEMARKETING_CONTRACT_SUBJECT_PATTERN) &&
                              question.match?(TELEMARKETING_CONTRACT_REMEDY_PATTERN)
          return false unless contract_question
        end
      end
      return false if foreign_succession && !ForeignSuccessionCivilDevolutionScope.source_relevant?(article, question)
      return false if foreign_succession && !ForeignSuccessionTaxSourceScope.source_relevant?(article, question)

      if commuter_work
        article_heading = (article[:article_title] || article['article_title']).to_s
        article_body = (article[:article_text] || article['article_text']).to_s
        source_text = [title, article_heading, normalize_occupational_source_layout(article_body)].join("\n")
        return false unless office_commute_specialist_source_relevant?(source_text, question, source_subject: [title, article_heading].join(' '))
      end
      return false if foreign_succession && !foreign_succession_regional_source_relevant?(article, question)

      if foreign_succession && REGIONAL_TAX_NUMACS.include?(numac) &&
         !question.match?(FLANDERS_REGION_PATTERN) && !question.match?(BRUSSELS_WALLONIA_REGION_PATTERN) &&
         !foreign_succession_applicability_source?(article, question)
        return false
      end

      gates = []
      gates.concat(HOUSE_PURCHASE_SPECIALIST_SOURCE_GATES) if house_defect
      gates.concat(HOUSE_PURCHASE_SOURCE_FAMILY_GATES) if house_defect
      gates.concat(OFFICE_COMMUTE_SPECIALIST_SOURCE_GATES) if commuter_work
      gates.concat(FOREIGN_SUCCESSION_SPECIALIST_SOURCE_GATES) if foreign_succession
      gates.concat(PARALLEL_EMPLOYMENT_SPECIALIST_SOURCE_GATES) if question.match?(PARALLEL_EMPLOYMENT_PATTERN)
      return false if gates.any? do |numacs, source_pattern, query_pattern|
        (numacs.include?(numac) || title.match?(source_pattern)) && !question.match?(query_pattern)
      end
      return false if house_defect && numac == '2013A11134' && !question.match?(HOUSE_ECONOMIC_LAW_CONTEXT_PATTERN)

      if house_defect && !question.match?(COURT_ORGANISATION_QUERY_PATTERN)
        # The French Judicial Code's law-level title itself contains
        # "organisation judiciaire". Only this article's own heading/body
        # can establish an institutional subtopic, not the whole-code label.
        source_text = [article[:article_title], article['article_title'],
                       article[:article_text], article['article_text']].compact.join(' ').gsub(/\s+/, ' ')
        return false if source_text.match?(COURT_ORGANISATION_SOURCE_PATTERN)
      end
      if commuter_work && numac == '1971031602'
        number = (article[:article_title] || article['article_title']).to_s.delete(' .').sub(/\Aart(?:icle|ikel)?/i, '').downcase
        return false if number == '15' && !question.match?(/\b(?:zondag\w*|dimanche\w*|Sunday\w*|Sonntag\w*)\b/iu)
        return false if %w[20bis/1 20quater].include?(number) && !question.match?(WORK_SCHEDULE_QUERY_PATTERN)
        return false if number == '28' && !question.match?(/\b(?:lagere\s+(?:arbeidsduur|uurgrens\w*|grens\w*)|sectorale\s+(?:arbeidsduur|uurgrens\w*|grens\w*)|lower\s+(?:working[-\s]?time|hour\w*|limit\w*)|sectoral\s+(?:working[-\s]?time|hour\w*|limit\w*)|durée\s+(?:réduite|inférieure)|limites?\s+(?:réduites?|sectorielles?)|niedrigere\w*\s+(?:Arbeitszeit|Grenz\w*))\b/iu)
      end

      # Do not globally censor these statutes: disability integration, school
      # employment, recalls and disaster compensation are valid specialist
      # questions. The additional boundary applies only to a focused civil
      # intent that caused generic lexical/boost matches in the Reddit tests.
      # Reuse the pin intent for colloquial tenancy wording as well, including
      # "rent a home" / "loue un appartement" without tenant/landlord terms.
      housing = question.match?(REGIONAL_HOUSING_SUBJECT_PATTERN) || question.match?(FLANDERS_RESIDENTIAL_RENTAL_PATTERN)
      focused = question.match?(CONSUMER_GOODS_DISPUTE_PATTERN) || housing ||
                question.match?(EMPLOYMENT_OFFER_REVIEW_PATTERN) ||
                question.match?(EMPLOYMENT_NOTICE_SICKNESS_PATTERN) ||
                question.match?(PARALLEL_EMPLOYMENT_PATTERN) ||
                house_defect || commuter_work || foreign_succession || telemarketing_privacy ||
                MortgageFinanceSources.topic?(question)
      return true unless focused

      # The 1936 succession-duties code can share generic terms with a notice
      # question, but it cannot answer whether a sick employee may resign or
      # whether that employee's notice is extended. Keep it for an actual
      # inheritance/succession issue, including a deliberately mixed query;
      # explicit NUMACs and viewed/pinned sources returned above also remain
      # available.
      return false if numac == '1936033102' && question.match?(EMPLOYMENT_NOTICE_SICKNESS_PATTERN) &&
                      !question.match?(REGIONAL_TAX_SUCCESSION_TERM_PATTERN)

      return false if CONTEXTUAL_SPECIALIST_SOURCE_GATES.any? do |source_pattern, query_pattern|
        title.match?(source_pattern) && !question.match?(query_pattern)
      end

      if numac == '1804032154'
        number = (article[:article_title] || article['article_title']).to_s.delete(' .').sub(/\Aart(?:icle|ikel)?/i, '').downcase
        return false if number.match?(/\A(?:171\d|172\d|173\d|174\d|175\d|176\d|177\d)/) &&
                        !housing && !question.match?(/\b(?:huur|bail|lease|tenancy|miet\w*)\b/i)
        return false if number.start_with?('1701/') && !question.match?(DIGITAL_CONTENT_SERVICE_CONTEXT_PATTERN)
      end
      if numac == '2018015087' && question.match?(FLANDERS_SHORT_RENTAL_TERMINATION_PATTERN)
        number = (article[:article_title] || article['article_title']).to_s.delete(' .').sub(/\Aart(?:icle|ikel)?/i, '').downcase
        return false if number == '19' && !question.match?(LANDLORD_TERMINATION_QUERY_PATTERN)

        # A factual statement that no deposit was requested must not make the
        # deposit article a source for an early-departure penalty. Preserve it
        # when another clause actually asks about a deposit, and preserve all
        # explicitly requested NUMACs via the early return above.
        without_absence = question.gsub(RENTAL_DEPOSIT_ABSENCE_CLAUSE_PATTERN, '')
        return false if number == '37' && without_absence != question &&
                        !without_absence.match?(RENTAL_DEPOSIT_SUBJECT_PATTERN)
      end
      if question.match?(CONSUMER_GOODS_WARRANTY_PATTERN)
        # Book 9 surety is not the legal conformity guarantee of a consumer
        # purchase. Keep it when the question actually raises a financial
        # guarantee, and preserve explicit source requests above.
        if numac == '2025A05089' && !question.match?(/\b(?:borgtocht|borgsteller|zekerheidsrecht|(?:zakelijke|persoonlijke|financiële)\s+zekerheid|cautionnement|surety|guarantor|Bürgschaft)\b/i)
          return false
        end

        if numac == '1804032154'
          number = (article[:article_title] || article['article_title']).to_s.delete(' .').sub(/\Aart(?:icle|ikel)?/i, '').downcase
          return true if number.match?(/\A1649(?:bis|ter|quater|quinquies|sexies|septies|octies|nonies)\z/)
          return true if question.match?(CONSUMER_HIDDEN_DEFECT_PATTERN) && number.match?(/\A164[1-8]\z/)
          return true if number.start_with?('1701/') && question.match?(DIGITAL_CONTENT_SERVICE_CONTEXT_PATTERN)
          return true if number.match?(/\A165[0-4]\z/) && question.match?(BUYER_PAYMENT_CONTEXT_PATTERN)

          # A tenancy or other neighbouring article from the same enormous
          # code is not made relevant by code-level boosting. Specific digital
          # and buyer-payment contexts have been admitted above.
          return false unless question.match?(/\b(?:huur|bail|lease|tenancy|miet\w*|dier\w*|animaux|animal\w*|Tier\w*)\b/i)
        end
      end
      true
    end

    # Shared across legislation and case-law retrieval, before context/cards.
    # A meaningful ordinary-office heading outranks a detached comparison in
    # its body. A generic court-number heading does not suppress actual staff
    # employment evidence, such as an employer's 32-urenstelsel decision.
    def self.office_commute_specialist_source_relevant?(text, question, source_subject: nil)
      return true unless question.to_s.match?(OFFICE_COMMUTE_WORK_PATTERN)

      subject = source_subject.to_s
      scoped = if subject.match?(ORDINARY_OFFICE_SOURCE_SUBJECT_PATTERN) &&
                  !subject.match?(VICINAL_RAILWAY_STAFF_PATTERN) && !subject.match?(MILITARY_PERSONNEL_PATTERN) &&
                  !subject.match?(CIVIL_SERVICE_POPULATION_PATTERN)
                 subject
               else
                 text.to_s.split(/(?<=[.!?])\s+|\n/).grep_v(
                   /\b(?:ter\s+vergelijking|vergeleken\s+met|niet\s+van\s+toepassing|for\s+comparison|compared\s+with|not\s+applicable|does\s+not\s+apply|[àa]\s+titre\s+de\s+comparaison|compar[ée]\p{L}*\s+[àa]|pas\s+applicable|zum\s+Vergleich|nicht\s+anwendbar)\b/iu
                 ).join("\n")
               end
      # The occupation and its rule must share a heading or sentence. A
      # detached institutional citation in an ordinary case is not its scope.
      units = scoped.split(/(?<=[.!?])\s+|\n/)
      transport_work = units.any? { |unit| unit.match?(TRANSPORT_WORK_ROLE_PATTERN) && unit.match?(OCCUPATIONAL_RULE_PATTERN) }
      if transport_work
        transport_role = Regexp.union(TRANSPORT_WORK_ROLE_PATTERN, ROAD_DRIVER_SUBJECT_PATTERN,
                                      /\b(?:transportpersoneel|transport\s+(?:staff|employees?|workers?))\b/iu)
        return false unless occupational_topic_requested?(question, transport_role, direct_identity: true)
      end

      if units.any? { |unit| unit.match?(COMMUTER_FARE_SOURCE_PATTERN) }
        clauses = question.to_s.split(/(?<=[.!?;])\s+|\n+|\b(?:but|however|maar|echter|cependant|toutefois|aber|jedoch)\b/iu).map(&:strip).reject(&:empty?)
        # A season ticket for a concert/football match is not a train pass.
        fare_clauses = clauses.map do |clause|
          clause.gsub(/\b(?:football|cinema|theatre|concert|sports?)\s+(?:season\s+)?(?:tickets?|pass)\b|\bseason\s+(?:tickets?|pass)\s+(?:for|to)\s+(?:(?:the|a)\s+)?(?:football|cinema|theatre|concert|sports?)\b/iu, '')
        end
        requested_fare = clauses.each_with_index.any? do |clause, index|
          fare = fare_clauses[index].match?(COMMUTER_FARE_QUERY_PATTERN)
          reimbursement = clause.match?(FARE_REIMBURSEMENT_QUERY_PATTERN)
          anaphor_reimbursement = clause.match?(/\b(?:dat|dit|die|it|that|this|ce|cela|ça|das|dies|es)\s+(?:(?:wordt|worden|is|be|also|auch|aussi|ook|wel|then|dan|[ée]galement|être|werden|wird|not|niet|nicht|pas)\s+){0,3}(?:#{FARE_REIMBURSEMENT_QUERY_PATTERN.source})/iu)
          (fare && (clause.match?(SPECIALIST_QUESTION_REQUEST_PATTERN) || clause.include?('?') || reimbursement)) ||
            (anaphor_reimbursement && index.positive? && fare_clauses[index - 1].match?(COMMUTER_FARE_QUERY_PATTERN))
        end
        return false unless requested_fare
      end

      railway_staff = units.any? do |unit|
        unit.match?(OCCUPATIONAL_RULE_PATTERN) &&
          (unit.match?(VICINAL_RAILWAY_STAFF_PATTERN) || unit.match?(RAILWAY_PERSONAL_EMPLOYMENT_PATTERN) ||
           unit.match?(RAILWAY_OCCUPATIONAL_SUBJECT_PATTERN))
      end
      if railway_staff
        subject_pattern = Regexp.union(VICINAL_RAILWAY_EMPLOYER_PATTERN, RAILWAY_EMPLOYMENT_PATTERN, /\b(?:NMBS|SNCB)\b/iu)
        request_scope = Regexp.union(VICINAL_RAILWAY_STAFF_PATTERN, RAILWAY_EMPLOYMENT_PATTERN)
        requested_contract = units.any? { |unit| unit.match?(MANAGEMENT_CONTRACT_PATTERN) && unit.match?(RAILWAY_TRANSPORT_SUBJECT_PATTERN) } &&
                             question.to_s.split(/[\n.!?;]+/).any? do |clause|
                               clause.match?(SPECIALIST_QUESTION_REQUEST_PATTERN) && clause.match?(MANAGEMENT_CONTRACT_PATTERN) &&
                                 clause.match?(RAILWAY_TRANSPORT_SUBJECT_PATTERN)
                             end
        return false unless requested_contract || occupational_topic_requested?(question, subject_pattern, request_scope: request_scope)
      end

      strike_service = units.any? do |unit|
        unit.match?(RAILWAY_TRANSPORT_SUBJECT_PATTERN) && unit.match?(PASSENGER_SERVICE_PATTERN) && unit.match?(RAILWAY_STRIKE_PATTERN)
      end
      if strike_service
        requested_service = question.to_s.split(/[\n.!?;]+/).any? do |clause|
          clause.match?(SPECIALIST_QUESTION_REQUEST_PATTERN) && clause.match?(RAILWAY_STRIKE_PATTERN) &&
            (clause.match?(RAILWAY_TRANSPORT_SUBJECT_PATTERN) || clause.match?(PASSENGER_SERVICE_PATTERN))
        end
        return false unless requested_service
      end

      driver_regime = units.any? do |unit|
        road_driver = unit.match?(ROAD_DRIVER_SUBJECT_PATTERN)
        (unit.match?(TACHOGRAPH_SUBJECT_PATTERN) &&
          (road_driver || unit.match?(DRIVING_REST_SCOPE_PATTERN) || unit.match?(DRIVER_REGULATORY_RULE_PATTERN))) ||
          (road_driver && (unit.match?(DRIVING_REST_SCOPE_PATTERN) || unit.match?(OCCUPATIONAL_RULE_PATTERN)))
      end
      if driver_regime && !occupational_topic_requested?(question, Regexp.union(ROAD_DRIVER_SUBJECT_PATTERN, TACHOGRAPH_SUBJECT_PATTERN),
                                                         regulatory: true, identity_scope: ROAD_DRIVER_SUBJECT_PATTERN)
        return false
      end

      military = units.any? { |unit| unit.match?(MILITARY_PERSONNEL_PATTERN) && unit.match?(OCCUPATIONAL_RULE_PATTERN) }
      if military
        request_scope = Regexp.union(MILITARY_PERSONNEL_PATTERN, /\b(?:militair|military\s+(?:worker|employee|staff)|militaire|Soldat\p{L}*)\b/iu)
        return false unless occupational_topic_requested?(question, MILITARY_EMPLOYER_PATTERN, request_scope: request_scope)
      elsif units.any? { |unit| unit.match?(CIVIL_SERVICE_POPULATION_PATTERN) && unit.match?(OCCUPATIONAL_RULE_PATTERN) }
        subject_pattern = Regexp.union(CIVIL_SERVICE_POPULATION_PATTERN, PUBLIC_EMPLOYER_QUERY_PATTERN)
        public_staff = /#{OCCUPATIONAL_PERSONNEL_PATTERN.source}\s+(?:van|bij|door|de|du|des|of|for|at|chez|bei|der)\s+(?:(?:de|het|een|the|a|an|my|our|mijn|onze|le|la|les|ma|mon|der|die|dem)\s+)?(?:#{PUBLIC_EMPLOYER_QUERY_PATTERN.source})/iu
        return false unless occupational_topic_requested?(question, subject_pattern, request_scope: Regexp.union(CIVIL_SERVICE_POPULATION_PATTERN, public_staff))
      end
      true
    end

    # PDF extraction wraps one sentence across physical lines. Join those
    # soft wraps for scope matching, keeping paragraphs separate. Callers
    # retain their title/summary/body boundaries and all original source text
    # for quotations and display; this normalization is admission-only.
    def self.normalize_occupational_source_layout(text)
      text.to_s.split(/\r?\n[\t ]*\r?\n/).map { |paragraph| paragraph.gsub(/\r?\n/, ' ') }.join("\n")
    end

    def self.occupational_topic_requested?(question, subject_pattern, regulatory: false, request_scope: subject_pattern, identity_scope: request_scope, direct_identity: false)
      question.to_s.split(/[\n.!?;]+|\b(?:but|however|maar|echter|cependant|toutefois|aber|jedoch)\b/iu).any? do |clause|
        next false unless clause.match?(subject_pattern)
        next false if clause.match?(NEGATED_OCCUPATION_PATTERN)

        if direct_identity
          comparison = clause.match?(/\b(?:vergelij\p{L}*|compar(?:e|ed|ing)|comparison|comparaison|compar[ée]\p{L}*|Vergleich\p{L}*|verglichen)\b/iu)
          comparison_request = clause.match?(SPECIALIST_QUESTION_REQUEST_PATTERN) ||
                               clause.match?(/\A\s*(?:(?:could|can|would)\s+you\s+|please\s+|(?:kun|kan)\s+je\s+|(?:pouvez|pourriez)[-\s]vous\s+|(?:können|könnten)\s+Sie\s+)?(?:compare|vergelijk|comparez|vergleiche\p{L}*)\b/iu)
          incidental_comparison = clause.match?(/\b(?:HR|werkgever\p{L}*|employer\p{L}*|employeur\p{L}*|Arbeitgeber\p{L}*)\s+(?:vergelij\p{L}*|compares?|compar[ée]\p{L}*|vergleicht)\b/iu)
          comparative_request = comparison && comparison_request && !incidental_comparison &&
                                (clause.match?(OCCUPATIONAL_RULE_PATTERN) || clause.match?(/\bworking[-\s]+time\b/iu))
          next true if comparative_request && clause.match?(request_scope)
          next false if comparison
        end

        requested = clause.match?(SPECIALIST_QUESTION_REQUEST_PATTERN)
        scope = clause.match?(OCCUPATIONAL_RULE_PATTERN) || clause.match?(OCCUPATIONAL_PERSONNEL_PATTERN) ||
                (regulatory && clause.match?(DRIVER_REGULATORY_RULE_PATTERN))
        next true if requested && scope && clause.match?(request_scope)

        identity = if direct_identity
                     clause.match?(/\b(?:ik\s+ben|I\s+am|je\s+suis|ich\s+bin)\s+(?:(?:ook|also|aussi|auch)\s+)?(?:(?:een|a|an|un|une|ein\p{L}*)\s+)?(?:#{identity_scope.source})/iu)
                   else
                     clause.match?(/\b(?:ik\s+ben|I\s+am|je\s+suis|ich\s+bin)\b.{0,80}(?:#{identity_scope.source})/iu)
                   end
        identity ||
          clause.match?(/\b(?:ik\s+(?:ook\s+)?werk|I\s+(?:also\s+)?work|je\s+(?:aussi\s+)?travaille|ich\s+(?:auch\s+)?arbeite)\s+(?:(?:ook|also|aussi|auch)\s+)?(?:bij|voor|als|for|at|as|chez|pour|comme|bei|f[uü]r)\s+(?:(?:de|het|een|the|a|an|le|la|les|un|une|der|die|dem|einer?)\s+)?(?:#{subject_pattern.source})/iu)
      end
    end

    def self.foreign_succession_applicability_targets(question)
      return [] unless question.to_s.match?(FOREIGN_DECEASED_SUCCESSION_TAX_PATTERN)

      flanders = question.match?(FLANDERS_REGION_PATTERN)
      brussels_or_wallonia = question.match?(BRUSSELS_WALLONIA_REGION_PATTERN)
      FOREIGN_SUCCESSION_APPLICABILITY_TARGETS.reject do |numac, _number|
        (numac == '1936033102' && flanders && !brussels_or_wallonia) ||
          (numac == '2013036154' && brussels_or_wallonia && !flanders)
      end
    end

    def self.foreign_succession_applicability_source?(article, question)
      numac = (article[:numac] || article['numac']).to_s
      number = (article[:article_title] || article['article_title']).to_s.delete(' ').sub(/\Aart(?:icle|ikel)?\.?/i, '').sub(/\.\z/, '')
      foreign_succession_applicability_targets(question).include?([numac, number])
    end

    # A spouse receiving her cousin's estate is not the deceased's surviving
    # spouse. Estate-tax headings for survivor exemptions/cohabitant rates must
    # earn relevance from that actual relationship, not a bare "my wife".
    # Likewise, a standalone regional reform is not the applicable tariff just
    # because the query says "inheritance tax". Keep all explicit/viewed/pinned
    # exceptions in the callers, and keep the exact scope-first pack untouched.
    def self.foreign_succession_regional_source_relevant?(article, question)
      return true if foreign_succession_applicability_source?(article, question)

      title = (article[:law_title] || article[:title] || article['law_title'] || article['title']).to_s
      return true unless title.match?(SUCCESSION_TAX_SOURCE_SUBJECT_PATTERN)

      named_region = question.match?(FLANDERS_REGION_PATTERN) || question.match?(BRUSSELS_WALLONIA_REGION_PATTERN)
      partner_subject = succession_partner_inheritance_query?(question)
      reform_or_history = question.match?(SUCCESSION_REFORM_HISTORY_QUERY_PATTERN) ||
                          (question.match?(SUCCESSION_REGIONAL_INSTRUMENT_PATTERN) &&
                           question.match?(SUCCESSION_INSTRUMENT_STATUS_QUERY_PATTERN))
      return true if named_region || partner_subject || reform_or_history

      !title.match?(SUCCESSION_PARTNER_SOURCE_PATTERN) && !title.match?(SUCCESSION_REGIONAL_INSTRUMENT_PATTERN)
    end

    def self.succession_partner_inheritance_query?(question)
      return true if question.match?(SUCCESSION_SURVIVOR_COHABITANT_QUERY_PATTERN)

      partner = SUCCESSION_PARTNER_RELATIONSHIP_PATTERN.source
      death = SUCCESSION_PARTNER_DEATH_PATTERN.source
      deceased_partner = question.scan(/#{partner}(?<between>[^\n.!?;]{0,65})(?:#{death})/iu).any? do |captures|
        between = captures.first
        !between.match?(SUCCESSION_NON_PARTNER_RELATIVE_PATTERN) && !between.match?(/\A\s*['’]s\b/iu)
      end
      # In "she died and my wife inherits", wife is the beneficiary, not
      # the deceased. Only a direct attribution admits the reversed order.
      deceased_partner ||
        question.match?(/#{partner}[^\n.!?;]{0,35}\b(?:will|would|may|might|could|were\s+to)\s+die\b/iu) ||
        question.match?(/(?:#{death})\s+(?:(?:mijn|uw|haar|zijn|de|my|your|her|his|the|mon|ma|son|sa|le|la|mein\p{L}*|ihr\p{L}*|der|die)\s+){0,3}#{partner}/iu) ||
        question.match?(/\b(?:erf(?:t|de|den|en)?|erven|inherit(?:s|ed|ing)?|hérit(?:e|er|era|ent|é)|erb(?:e|t|en|te|ten))\b[^\n.!?;]{0,40}\b(?:van|from|de|von)\s+(?:(?:mijn|uw|haar|zijn|de|my|your|her|his|the|mon|ma|son|sa|le|la|mein\p{L}*|ihr\p{L}*|der|die)\s+){0,3}#{partner}(?!\s*['’]s\b)/iu)
    end

    def regional_tax_numacs_for(question)
      return nil unless question.match?(REGIONAL_TAX_SUBJECT_PATTERN) ||
                        question.match?(REGIONAL_TAX_GIFT_CONTEXT_PATTERN) ||
                        question.match?(REGIONAL_TAX_SUCCESSION_CONTEXT_PATTERN) ||
                        question.match?(FOREIGN_DECEASED_SUCCESSION_TAX_PATTERN)

      # Owner rule (2026-10-17): always mention all regions. Every regional
      # regime of the tax asked about stays in scope, whichever region the
      # question names (the prompt puts that one first); until then a named
      # Brussels question lost the Flemish code and an unqualified one lost
      # every native code, so an answer could not compare what the corpus
      # holds. Which regime applies to the user remains the sources' own
      # connecting factor (domicile, location of the property): the foreign-
      # deceased applicability pins and their exemption are unchanged.
      non_flemish = Set.new
      non_flemish << '1936033102' if question.match?(SUCCESSION_TAX_PATTERN) || question.match?(FOREIGN_DECEASED_SUCCESSION_TAX_PATTERN)
      non_flemish << '1939113002' if question.match?(REGISTRATION_TAX_PATTERN)
      return FLANDERS_TAX_NUMACS | non_flemish unless question.match?(FOREIGN_DECEASED_SUCCESSION_TAX_PATTERN)

      # A deceased living abroad: which region taxes the estate is the
      # question itself, so the applicability pack leads and no tariff of an
      # unestablished region is offered as the answer.
      flanders = question.match?(FLANDERS_REGION_PATTERN)
      brussels_or_wallonia = question.match?(BRUSSELS_WALLONIA_REGION_PATTERN)
      return FLANDERS_TAX_NUMACS | non_flemish if flanders && brussels_or_wallonia
      return FLANDERS_TAX_NUMACS if flanders
      return non_flemish if brussels_or_wallonia

      Set.new
    end

    def regional_housing_numacs_for(question)
      return nil unless question.match?(REGIONAL_HOUSING_SUBJECT_PATTERN)

      allowed = Set.new
      allowed << '2018015087' if question.match?(FLANDERS_REGION_PATTERN)
      allowed << '2013A31614' if question.match?(BRUSSELS_REGION_PATTERN)
      allowed << '2018201408' if question.match?(WALLONIA_REGION_PATTERN)
      allowed
    end

    # The three short-commercial-lease statutes are not the residential
    # tenancy statutes above. Scope every candidate route, including viewed
    # laws, but preserve an unqualified overview's explicitly regional
    # sources. Named comparisons keep precisely the named jurisdictions.
    # Verified against Vlaamse Codex 1027051, WALLEX 2018201406 and the
    # Brussels ordinance of 25 April 2019 (NUMAC 2019041090).
    def regional_short_commercial_numacs_for(question)
      return nil unless question.match?(SHORT_COMMERCIAL_SUBJECT_PATTERN)

      allowed = Set.new
      allowed << '2016036108' if question.match?(FLANDERS_REGION_PATTERN)
      allowed << '2018201406' if question.match?(WALLONIA_REGION_PATTERN)
      allowed << '2019041090' if question.match?(BRUSSELS_REGION_PATTERN)
      allowed.presence
    end

    def regional_short_commercial_candidates(question)
      return [] unless question.match?(SHORT_COMMERCIAL_SUBJECT_PATTERN)
      return [] if question.match?(RegionalSearch::UNSUPPORTED_GERMAN_COMMUNITY_PATTERN)

      allowed = regional_short_commercial_numacs_for(question)
      labels = REGIONAL_SHORT_COMMERCIAL_LABELS.fetch(@language, REGIONAL_SHORT_COMMERCIAL_LABELS.fetch('nl'))
      REGIONAL_SHORT_COMMERCIAL_TARGETS.filter_map do |numac, number|
        next if allowed && !allowed.include?(numac)

        # This mixed-purpose Walloon decree also establishes its own substantive
        # short-lease regime. Its French scope article is literally Art.1er.
        # Keep that exception local: citation repair must not globally alias
        # ordinal article numbers or accept arbitrary amending acts.
        walloon_scope = numac == '2018201406' && number == '1'
        requested_number = walloon_scope && @language_id == 2 ? '1er' : number
        # Fetch one law at a time: citation repair intentionally deduplicates
        # a requested article number across laws, while Art. 2 here belongs
        # to two independent regional regimes and both must remain visible.
        article = fetch_articles_by_number(numacs: [numac], article_numbers: [requested_number], limit: 1).first
        next if article.nil? || article[:numac] != numac || article[:language_id] != @language_id
        next unless article_number_key_from_title(article[:article_title]) == normalized_article_key(requested_number)
        next if article[:article_text].blank? || article[:is_abolished]
        next if article[:is_modification] && !walloon_scope

        article.merge(
          law_title: "#{labels.fetch(numac)}: #{article[:law_title]}",
          regional_candidate: true, pinned: true, similarity: 0.85
        )
      end
    end

    # The verified residential lease provisions of every topic the question
    # raises (REGIONAL_HOUSING_TOPIC_TARGETS), for all three regions; a named
    # region only comes first. Within the topics, each region's first provision
    # precedes the second ones. Text comes from Article, fetched one law at a
    # time; a missing, other-language, repealed or amending row fails closed
    # rather than standing in for the provision.
    def regional_housing_topic_candidates(question)
      return [] if question.match?(RegionalSearch::UNSUPPORTED_GERMAN_COMMUNITY_PATTERN)

      topics = REGIONAL_HOUSING_TOPIC_TARGETS.select { |kind, _targets| self.class.housing_topic?(question, kind) }
      return [] if topics.empty?
      # Another regime (student, social, commercial, agricultural) or object
      # (car, machine, parking) keeps every region through the regional lane
      # and the prompt, but never with these private-rental provisions.
      return [] unless self.class.rental_regime(question) == :residential

      named = Set.new
      named << '2018015087' if question.match?(FLANDERS_REGION_PATTERN)
      named << '2013A31614' if question.match?(BRUSSELS_REGION_PATTERN)
      named << '2018201408' if question.match?(WALLONIA_REGION_PATTERN)
      ordered = topics.each_with_index.flat_map do |(_pattern, targets), topic|
        targets.each_with_index.map do |target, index|
          [target, [named.include?(target.first) ? 0 : 1, index / 3, topic, index]]
        end
      end
      labels = REGIONAL_HOUSING_LABELS.fetch(@language, REGIONAL_HOUSING_LABELS.fetch('nl'))
      ordered.sort_by(&:last).map(&:first).uniq.filter_map do |numac, number|
        article = fetch_articles_by_number(numacs: [numac], article_numbers: [number], limit: 1).first
        next if article.nil? || article[:numac] != numac || article[:language_id] != @language_id
        next unless article_number_key_from_title(article[:article_title]) == normalized_article_key(number)
        next if article[:article_text].blank? || article[:is_abolished] || article[:is_modification]

        article.merge(
          law_title: "#{labels.fetch(numac)}: #{article[:law_title]}",
          regional_candidate: true, pinned: true, similarity: 0.85
        )
      end
    end

    def employment_context_question?(question)
      question.match?(/\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|tewerkstelling|job|ontslag|contrat\s+de\s+travail|travailleur|employeur|licenciement|employment\s+contract|employee|employer|dismissal)\b/i)
    end

    def regional_planning_numacs_for(question)
      return nil unless question.match?(REGIONAL_PLANNING_SUBJECT_PATTERN)

      question.match?(FLANDERS_REGION_PATTERN) ? FLANDERS_PLANNING_NUMACS : Set.new
    end

    def inject_core_law_articles(numacs, question_lower)
      keywords = meaningful_query_words(question_lower)
      stop_roots = %w[belg belgi straf recht wetbo]
      roots = keywords.select { |w| w.length >= 6 }.map { |w| w[0, 5] }
      roots.reject! { |r| stop_roots.include?(r) }
      search_terms = (keywords + roots).uniq

      injected = []
      numacs.each do |numac|
        base_query = Article
                     .select('articles.*, COALESCE(legislation.short_title, legislation.title) as law_title, legislation.date, legislation.is_abolished, contents.preamble')
                     .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
                     .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
                     .where(content_numac: numac, language_id: @language_id)

        # Strategy 1: Targeted text search
        targeted_articles = []
        if keywords.any?
          like_conditions = keywords.map { 'article_text LIKE ? OR article_title LIKE ?' }
          like_params = keywords.flat_map { |k| ["%#{k}%", "%#{k}%"] }
          begin
            Timeout.timeout(3) do
              targeted_articles = base_query.where(like_conditions.join(' OR '), *like_params).limit(20).to_a
            end
          rescue Timeout::Error
            Rails.logger.warn("Core law injection: text search timed out for #{numac}")
            targeted_articles = []
          end
        end

        # Strategy 2: Fallback to first N articles
        targeted_articles = base_query.limit(10).to_a if targeted_articles.empty?

        scored = targeted_articles.map do |article|
          text = "#{article.article_title} #{article.article_text}".downcase
          matches = search_terms.count { |term| text.include?(term) }
          base_similarity = matches.positive? ? 0.82 : 0.70

          {
            id: article.id,
            numac: article.content_numac,
            law_title: article.law_title || lookup_law_title(article.content_numac, article.language_id) || "Wetgeving #{article.content_numac}",
            article_title: article.article_title,
            article_text: article.article_text,
            article_variant: article.try(:article_variant),
            language_id: article.language_id,
            similarity: base_similarity + (matches * 0.02),
            injected: true,
            match_count: matches,
            is_abolished: article.try(:is_abolished) == 1,
            preamble: article.try(:preamble)
          }
        end

        injected += scored.sort_by { |a| [-a[:match_count], -a[:similarity]] }.take(3)
      end

      injected
    end

    # ------------------------------------------------------------------
    # HELPERS
    # ------------------------------------------------------------------

    def is_sector_cao?(law_title)
      return false if law_title.blank?

      title_lower = law_title.downcase
      cao_patterns = [
        /paritair comit[eé]/i, /paritair subcomit[eé]/i,
        /collectieve arbeidsovereenkomst/i, /convention collective/i,
        /commission paritaire/i, /sous-commission paritaire/i,
        /pc\s*\d+/i, /cp\s*\d+/i
      ]
      sector_keywords = %w[hardsteengroeven kwartsietgroeven zandsteen warenhuizen groothandelaar
                           voedingsnijverheid bakkerijen textielnijverheid kleding metaal garage carrosserie
                           bouw hout meubel haven scheepvaart luchtvaart hotels horeca toerisme]

      return true if cao_patterns.any? { |p| title_lower.match?(p) }
      return true if (title_lower.include?('overeenkomst') || title_lower.include?('convention')) && sector_keywords.any? { |k| title_lower.include?(k) }

      false
    end

    def is_fisconet_source?(numac, law_title)
      return true if numac.to_s.start_with?('fisconet')

      title = law_title.to_s.downcase
      # Explicit tax law titles (NOT the broad W.Reg. which also covers griffierechten)
      return true if title =~ /\b(fiscaal|btw|belasting|accijns|tva|impôt|taxe)\b/i
      # Specific tax codes within W.Reg. – only if title mentions tax-specific sections
      return true if title =~ /\b(successierecht|schenkbelasting|erfbelasting)\b/i

      false
    end

    def extract_topic_keywords(question)
      topic_map = {
        'ontslag' => %w[arbeid ontslag werk], 'opzeg' => %w[arbeid ontslag opzeg],
        'vakantie' => %w[vakantie arbeid werk verlof], 'huur' => %w[huur woning woon verhuur],
        'belasting' => %w[belasting fiscaal btw inkomsten], 'echtscheiding' => %w[echtscheiding huwelijk burgerlijk],
        'btw' => %w[belasting btw toegevoegde omzet], 'tva' => ['taxe', 'valeur ajoutée', 'impôt'],
        'erfenis' => %w[erfenis successie nalatenschap burgerlijk], 'vennootschap' => %w[vennootschap onderneming economisch],
        'straf' => %w[straf boete sanctie verkeer], 'rijbewijs' => %w[verkeer rijbewijs wegverkeer],
        'werkloosheid' => %w[werkloosheid uitkering sociale], 'pensioen' => %w[pensioen sociale zekerheid],
        'kinderbijslag' => %w[kind gezin groeipakket], 'garantie' => %w[consument garantie economisch]
      }

      keywords = []
      topic_map.each { |topic, title_keywords| keywords.concat(title_keywords) if question.include?(topic) }
      keywords.concat(meaningful_query_words(question).select { |word| word.length >= 5 })
      keywords.uniq
    end

    def extract_relevant_window(full_text, _article_title, window_size: 3000)
      return full_text if full_text.length <= window_size

      data_patterns = [
        /\d+[°º]\s/, /§\s*\d+/,
        /\b\d+\s*(dagen|jours|days|Tage|weken|semaines|weeks|Wochen|maanden|mois|months|Monate|jaar|ans|years|Jahre|euro|EUR|%)\b/i,
        /\b(bedraagt|égale?|equals?|beträgt|maximum|minimum|ten\s+minste|au\s+moins|at\s+least|mindestens)\b/i
      ]

      best_start = nil
      data_patterns.each do |pattern|
        match = full_text.match(pattern)
        if match
          pos = match.begin(0)
          best_start = pos if best_start.nil? || pos < best_start
        end
      end

      if best_start && best_start > 500
        start_pos = [best_start - 300, 0].max
        newline_pos = full_text.rindex("\n", start_pos + 50)
        start_pos = newline_pos + 1 if newline_pos && newline_pos >= start_pos - 100
        return full_text[start_pos, window_size]
      end

      full_text[0, window_size]
    end

    def build_regional_warnings(q)
      parts = []

      if q.include?('registratierecht')
        parts << "REGISTRATIERECHTEN (regionaal!):\nTarieven verschillen per gewest (Vlaanderen, Wallonie, Brussel). " \
                 'Vermeld het toepasselijke gewest en gebruik de tarieven uit de bronnen hieronder.'
      end

      if q.include?('kinderbijslag') || q.include?('groeipakket')
        parts << "KINDERBIJSLAG/GROEIPAKKET (regionaal!):\nBedragen verschillen per gewest. " \
                 'Vlaanderen: "Groeipakket", Wallonie: allocations familiales, Brussel: eigen regeling. ' \
                 'Gebruik de bedragen uit de bronnen hieronder.'
      end

      if q.include?('huur') || q.include?('woninghuur')
        parts << "HUURRECHT (regionaal!):\nVermeld welke gewestelijke regeling van toepassing is " \
                 '(Vlaams Woninghuurdecreet 2018, Brusselse Huisvestingscode, of Waalse Woninghuurwet).'
      end

      if q.include?('erfbelasting') || q.include?('successie')
        parts << "ERFBELASTING/SUCCESSIERECHTEN (regionaal!):\nTarieven en vrijstellingen verschillen per gewest. " \
                 'Vermeld welk gewest van toepassing is en gebruik de tarieven uit de bronnen.'
      end

      if q.include?('onroerende voorheffing')
        parts << "ONROERENDE VOORHEFFING (regionaal!):\nFederale basispercentage KI, " \
                 'maar opcentiemen zijn regionaal en gemeentelijk verschillend. Vermeld het toepasselijke gewest.'
      end

      if q.include?('premie') || q.include?('renovatie') || q.include?('vergunning')
        parts << "PREMIES/VERGUNNINGEN (regionaal!):\nVoorwaarden en bedragen zijn gewestelijk bepaald. " \
                 'Vermeld het toepasselijke gewest.'
      end

      parts
    end

    # The legal term map is huge - extracted to its own method for readability
    def build_legal_term_map
      {
        /vakantiedagen|jaarlijks.*vakantie/i => ['vakantiedagen', 'jaarlijkse vakantie', 'wettelijke vakantie', 'verlof'],
        'ontslag' => %w[ontslag opzeg beëindiging ontslaan opzegtermijn opzegvergoeding],
        'zelfstandig' => %w[zelfstandig zelfstandige freelance independent schijnzelfstandigheid],
        'deeltijd' => %w[deeltijd deeltijds part-time parttime],
        'proef' => ['proef', 'proeftijd', 'proefperiode', 'trial period', 'testperiode'],
        'concurrentie' => %w[concurrentiebeding niet-concurrentiebeding concurrentie non-compete],
        'arbeider' => ['arbeider', 'arbeiders', 'blue collar', 'handarbeider'],
        'bediende' => ['bediende', 'bedienden', 'white collar', 'kantoorwerk'],
        'loon' => %w[loon salaris verloning minimumloon bezoldiging],
        'overuren' => ['overuren', 'meeruren', 'extra uren', 'overtime'],
        PARALLEL_EMPLOYMENT_PATTERN => ['parallelle arbeid', 'andere werkgever', 'gehele beroepsactiviteit', 'nevenactiviteit', 'bijberoep', 'exclusiviteitsbeding', 'transparante en voorspelbare arbeidsvoorwaarden', 'parallel employment', 'other employer', 'another employer', 'side job', 'professional activity', 'activité professionnelle parallèle', 'activité accessoire', 'autre employeur', 'Nebenbeschäftigung', 'Nebentätigkeit', 'parallele Beschäftigung'],
        EMPLOYMENT_OFFER_REVIEW_PATTERN => ['employment contract', 'job offer', 'employment offer', 'full-time job', 'offer letter', 'compensation package', 'employment terms', 'arbeidsovereenkomst', 'contrat de travail', 'Arbeitsvertrag'],
        /arbeidsovereenkomst|arbeidscontract|werkcontract/i => %w[arbeidsovereenkomst arbeidscontract dienstverband tewerkstelling],
        /deeltijds.*werk|parttime/i => ['deeltijds', 'part-time', 'gedeeltelijke arbeid', 'halftijds'],
        /overuren|over.*uren|meeruren/i => ['overuren', 'meeruren', 'aanvullende prestaties', 'extra uren'],
        /ontslag|afdanking/i => %w[ontslag afdanking beëindiging arbeidsbeëindiging],
        /dringende.*reden|dringend.*ontslag/i => ['dringende reden', 'dringend ontslag', 'onmiddellijke beëindiging'],
        /zelfstandige|ondernemer/i => ['zelfstandige', 'zelfstandig ondernemer', 'vrij beroep'],
        /sociale.*bijdrage|rsz/i => ['sociale bijdragen', 'RSZ', 'socialezekerheidsbijdrage'],
        /werkloosheid|werkloosheidsuitkering/i => %w[werkloosheid werkloosheidsuitkering werkloosheidsvergoeding],
        /minimumloon|minimum.*loon/i => ['minimumloon', 'minimum loon', 'gewaarborgd loon'],
        /loon|salaris|bezoldiging/i => %w[loon salaris bezoldiging wedde],
        /eindejaar.*premie|13.*maand/i => ['eindejaarspremie', '13de maand', 'dertiende maand'],
        /ziekteverlof|ziek/i => %w[ziekteverlof ziekte arbeidsongeschiktheid],
        /zwangerschapsverlof|moederschaps/i => %w[zwangerschapsverlof moederschapsverlof bevallingsrust],
        /vaderschapsverlof|vaderschaps/i => ['vaderschapsverlof', 'geboorteverlof', 'verlof geboorte'],
        /congé.*paternel|congé.*paternité|paternité/i => ['congé de paternité', 'congé paternel', 'congé de naissance'],
        /paternity.*leave|paternity/i => ['paternity leave', 'birth leave', 'paternal leave'],
        /vaterschaftsurlaub|vaterschaft/i => %w[vaterschaftsurlaub geburtsurlaub väterurlaub],
        /congé.*maternité|maternité/i => ['congé de maternité', 'congé maternité', 'repos de maternité'],
        /maternity.*leave|maternity/i => ['maternity leave', 'maternal leave', 'pregnancy leave'],
        /mutterschaftsurlaub|mutterschaft/i => %w[mutterschaftsurlaub mutterschutz schwangerschaftsurlaub],
        /durée.*travail|temps.*travail|heures.*travail/i => ['durée du travail', 'temps de travail', 'heures de travail', 'semaine de travail'],
        /working.*hours|work.*hours|maximum.*hours/i => ['working hours', 'work hours', 'maximum hours', 'working time'],
        /arbeitszeit|arbeitsstunden|wochenarbeitszeit/i => %w[arbeitszeit arbeitsstunden wochenarbeitszeit höchstarbeitszeit],
        /discriminatie|ongelijke.*behandeling/i => ['discriminatie', 'ongelijke behandeling', 'gelijke behandeling'],
        /pesten|pestgedrag|intimidatie|harassment/i => ['pestgedrag', 'pesten', 'intimidatie', 'psychosociale risicos'],
        /thuiswerk|telewerk|remote/i => %w[thuiswerk telewerk thuiswerken afstandswerk],
        /arbeidsduur|werkuren|arbeidstijd/i => %w[arbeidsduur arbeidstijd werkuren arbeidstijdvermindering],
        /concurrentiebeding|concurrentie/i => %w[concurrentiebeding niet-concurrentiebeding concurrentieclausule],
        /burnout/i => ['burnout', 'overspanning', 'psychische belasting', 'arbeidsongeval'],
        /alcohol.*driv|drink.*driv|blood.*alcohol/i => ['alcoholgrens', 'rijden onder invloed', 'promille', 'alcool au volant', 'taux alcool'],
        /alkohol.*fahr|alkoholgrenze/i => ['alcoholgrens', 'rijden onder invloed', 'promille', 'alcool au volant'],
        /driving.*licen[sc]e|driving.*ban/i => ['rijbewijs', 'rijverbod', 'permis de conduire', 'retrait permis'],
        /führerschein|fahrverbot/i => ['rijbewijs', 'rijverbod', 'permis de conduire', 'retrait permis'],
        /traffic.*(?:fine|offence|violation)/i => ['verkeersboete', 'verkeersovertreding', 'infraction routière', 'amende'],
        /verkehrsstrafe|bußgeld/i => ['verkeersboete', 'verkeersovertreding', 'infraction routière'],
        /marriage.*age|minimum.*marriage/i => ['huwelijksleeftijd', 'huwelijk', 'meerderjarig', 'âge mariage', 'mariage', 'majeur'],
        /mindestalter.*heirat|heiratsalter/i => ['huwelijksleeftijd', 'huwelijk', 'âge mariage', 'mariage'],
        /child.*support|alimony/i => ['onderhoudsgeld', 'alimentatie', 'pension alimentaire', 'obligation alimentaire'],
        /kindesunterhalt|unterhaltspflicht/i => ['onderhoudsgeld', 'alimentatie', 'pension alimentaire'],
        /divorce|separation/i => %w[echtscheiding scheiding divorce séparation],
        # "their role" and "real estate" in a private house-sale question
        # are not inheritance vocabulary. Keep actual heirs/probate and
        # estate-tax/planning terms without expanding those incidental words.
        /\b(?:inheritance|heirs?|probate)\b|(?<!real[\s-])\bestate\s+(?:tax(?:es)?|dut(?:y|ies)|planning|administration|distribution)\b/i => %w[erfenis erfrecht nalatenschap succession héritage héritier],
        /rental.*deposit|security.*deposit/i => ['huurwaarborg', 'waarborg', 'garantie locative', 'caution', 'bail'],
        /mietkaution|kaution.*miete/i => ['huurwaarborg', 'waarborg', 'garantie locative', 'caution'],
        /notice.*period.*(?:tenant|landlord|rent)/i => ['opzegtermijn', 'huur', 'opzeg huur', 'préavis', 'locataire', 'bailleur'],
        /kündigungsfrist.*miet|mieter.*kündigung/i => %w[opzegtermijn huur préavis locataire],
        /annual.*accounts?.*filing/i => ['jaarrekening', 'neerlegging', 'comptes annuels', 'dépôt', 'WVV'],
        /jahresabschluss/i => ['jaarrekening', 'neerlegging', 'comptes annuels', 'dépôt'],
        /general.*(?:meeting|assembly)|shareholder.*meeting/i => ['algemene vergadering', 'aandeelhouder', 'assemblée générale', 'actionnaire'],
        /hauptversammlung/i => ['algemene vergadering', 'assemblée générale', 'actionnaire'],
        /minimum.*capital|share.*capital/i => ['minimumkapitaal', 'kapitaal', 'capital minimum', 'capital social', 'BV', 'NV'],
        /\bvat\b.*(?:rate|percent|standard)/i => ['BTW', 'BTW-tarief', 'TVA', 'taux TVA', 'taxe sur la valeur ajoutée'],
        /mwst.*(?:satz|prozent)/i => ['BTW', 'BTW-tarief', 'TVA', 'taux TVA'],
        /reduced.*vat|vat.*(?:food|renovation)/i => ['verlaagd BTW-tarief', 'BTW', '6%', 'taux réduit TVA', 'TVA'],
        /ermäßigt.*mwst/i => ['verlaagd BTW-tarief', 'BTW', 'taux réduit TVA'],
        /corporate.*tax.*(?:rate|percent)/i => ['vennootschapsbelasting', 'ISOC', 'impôt des sociétés', 'KMO-tarief', 'taux PME'],
        /körperschaftsteuer/i => ['vennootschapsbelasting', 'ISOC', 'impôt des sociétés'],
        /(?:legal|statutory).*(?:guarantee|warranty)/i => ['wettelijke garantie', 'garantie', 'garantie légale', 'consommateur', 'conformiteit'],
        /gesetzliche.*garantie/i => ['wettelijke garantie', 'garantie légale', 'consommateur'],
        /hidden.*defect|latent.*defect/i => ['verborgen gebrek', 'verborgen gebreken', 'vice caché', 'vices cachés'],
        /versteckte.*mängel/i => ['verborgen gebrek', 'vice caché', 'vices cachés'],
        /withdrawal.*(?:right|period)|cooling.*off/i => ['herroepingsrecht', 'bedenktijd', 'droit de rétractation', 'délai de réflexion'],
        /widerrufsrecht|widerrufsfrist/i => ['herroepingsrecht', 'bedenktijd', 'droit de rétractation'],
        /public.*holiday|bank.*holiday/i => ['feestdag', 'feestdagen', 'wettelijke feestdag', 'jour férié', 'jours fériés'],
        /feiertag/i => ['feestdag', 'feestdagen', 'jour férié', 'jours fériés'],
        /(?:minimum|gross).*(?:wage|salary)/i => ['minimumloon', 'GGMMI', 'salaire minimum', 'RMMMG'],
        /mindestlohn/i => ['minimumloon', 'GGMMI', 'salaire minimum', 'RMMMG'],
        /bereavement.*leave|compassionate.*leave/i => ['rouwverlof', 'klein verlet', 'overlijden', 'congé de deuil', 'décès'],
        /trauerurlaub/i => ['rouwverlof', 'klein verlet', 'congé de deuil'],
        /diefstal|stelen|gestolen/i => %w[diefstal ontvreemding wegnemen heling roof],
        /drugs|drugsbezit|verdovende/i => ['drugs', 'verdovende middelen', 'bezit', 'handel', 'stupéfiants'],
        /geweld|slagen|verwondingen|mishandeling/i => ['slagen', 'verwondingen', 'geweld', 'opzettelijk', 'lichamelijke integriteit'],
        /fraude|oplichting|bedrog/i => %w[fraude oplichting valsheid bedrog misleiding],
        /moord|doodslag/i => ['moord', 'doodslag', 'opzettelijke doding', 'levensberoving'],
        /verkrachting|aanranding/i => ['verkrachting', 'aanranding', 'eerbaarheid', 'seksueel geweld'],
        /stalking|belaging/i => %w[belaging stalking hinderlijk lastigvallen],
        /inbraak|braak/i => ['inbraak', 'braak', 'diefstal met braak', 'inklimming'],
        /vol.*qualifié|cambriolage/i => ['vol', 'vol qualifié', 'effraction', 'cambriolage', 'diefstal'],
        /coups.*blessures|violence/i => %w[coups blessures violence slagen verwondingen],
        /stupéfiants|drogue|détention.*drogue/i => ['stupéfiants', 'drogue', 'détention', 'drugs', 'verdovende middelen'],
        /meurtre|homicide/i => %w[meurtre homicide moord doodslag],
        /escroquerie|fraude/i => %w[escroquerie fraude oplichting tromperie],
        /huurwaarborg|waarborg/i => %w[huurwaarborg waarborg borgsom garantie teruggave],
        /opzeg.*huur|huur.*opzeg/i => ['opzegtermijn', 'opzeg', 'huurovereenkomst', 'beëindiging huur'],
        /renovatie|verbouwing/i => %w[renovatie verbouwing herstellingswerken onderhoud],

        # Colloquial / branded scheme names → the formal statutory vocabulary
        # the corpus is actually indexed on (added 2026-07-15 after the 3k
        # coverage run showed these named schemes hedged despite being in the
        # legislation, just under formal names the question never uses).
        /\bwco\b|continu[iï]teit.*ondernem|gerechtelijke.*reorganisatie/i =>
          ['continuïteit ondernemingen', 'gerechtelijke reorganisatie', 'insolventie', 'Boek XX economisch recht'],
        /flexi.?job/i => ['flexi-job', 'flexijob', 'gelegenheidsarbeid', 'bijkomende tewerkstelling'],
        /plus.?minus.?conto/i => ['plus-minus conto', 'arbeidsduur op jaarbasis', 'arbeidstijdregeling'],
        /niet.?recurrente.*bonus|cao.?90/i => ['niet-recurrente resultaatsgebonden voordelen', 'loonbonus', 'cao 90'],
        /bonus.?malus/i => ['bonus-malus', 'premiegraad', 'verzekering burgerlijke aansprakelijkheid motorrijtuigen'],
        /renault.?procedure|wet.?renault/i => ['collectief ontslag', 'informatie en raadpleging', 'sluiting onderneming'],
        /kaasroute/i => ['registratierecht schenking', 'buitenlandse schenkingsakte', 'notariële schenking'],
        /rijbewijs.*proef|voorlopig.*rijbewijs/i => ['rijbewijs op proef', 'proefperiode rijbewijs', 'terugkommoment'],
        /enkelband|elektronisch.*toezicht/i => ['elektronisch toezicht', 'enkelband', 'strafuitvoering'],
        /probatie/i => ['probatie', 'probatieuitstel', 'opschorting met voorwaarden'],
        /\bipt\b|individuele.*pensioentoezegging/i => ['individuele pensioentoezegging', 'aanvullend pensioen', 'tweede pensioenpijler'],
        /groepsverzekering/i => ['groepsverzekering', 'aanvullend pensioen', 'pensioentoezegging'],
        /single.?permit|gecombineerde.*vergunning/i => ['gecombineerde vergunning', 'single permit', 'verblijf en arbeid'],
        /schengen.?visum|kort.*verblijf.*visum/i => ['visum kort verblijf', 'Schengenvisum', 'visumcode'],
        /inreisverbod/i => ['inreisverbod', 'terugkeerbesluit', 'verwijdering vreemdeling'],
        /epc|energieprestatie/i => ['energieprestatiecertificaat', 'EPC', 'energieprestatie gebouwen'],
        /bindend.*studieadvies|\bbsa\b/i => ['bindend studieadvies', 'studievoortgang', 'inschrijving hoger onderwijs'],
        /reservefonds|\bvme\b|mede.?eigendom/i => ['reservefonds', 'vereniging van mede-eigenaars', 'gedwongen mede-eigendom'],
        /informed.?consent|geïnformeerde.?toestemming/i => ['geïnformeerde toestemming', 'patiëntenrechten', 'toestemming behandeling'],
        /extralegale.?voordelen|extra.?legaal/i => ['extralegale voordelen', 'voordelen alle aard', 'aanvullende voordelen'],
        /aanrijdingsformulier|europees.*aanrijding/i => ['aanrijdingsformulier', 'aangifte schadegeval', 'verkeersongeval'],
        /wapenvergunning|wapenwit/i => ['wapenvergunning', 'vergunning wapen', 'wapenwet'],
        /phishing|internetfraude/i => ['phishing', 'informaticabedrog', 'oplichting', 'computercriminaliteit'],
        /bemiddeling|mediation/i => ['bemiddeling', 'mediation', 'minnelijke schikking', 'alternatieve geschillenbeslechting'],
        /incasso|onbetaalde.*factuur|invordering/i => ['invordering', 'onbetaalde schuld', 'IOS-procedure', 'betalingsachterstand']
      }
    end
  end
end
