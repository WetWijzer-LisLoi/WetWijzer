# frozen_string_literal: true

module LegalChatbot
  # Generic relevance selection can lose Article 4's administrative ceiling,
  # Article 25's defense clause or Article 31's age-dependent appeal route.
  # Keep these bounded,
  # already-retrieved procedural blocks with their native qualifications.
  # This selects source bytes; it supplies no additional legal proposition.
  module MunicipalSanctionsContext
    MAX_EXCERPT_CHARS = 2200
    ARTICLE_TITLE = /\A\s*art(?:ikel|icle)?\.?\s*(4|25|31)\.?\s*\z/iu
    PARAGRAPH_HEADER = /(?:\A|(?<=\n))[[:blank:]]*(?:\[\d+[[:blank:]]*)?§[[:space:]]*([2-5])[[:space:]]*\./u
    SANCTIONS_HEADER = /\A[[:blank:]]*(?:Art(?:ikel|icle)?\.?[[:blank:]]*4\.?[[:blank:]]*)?§[[:blank:]]*1(?:er)?\.[[:blank:]]*/iu
    SANCTIONS_BOUNDARY = /(?:\A|\r?\n)[[:blank:]]*§[[:blank:]]*([2-5])[[:blank:]]*\./u
    EXPLICIT_SANCTIONS_SELECTION = /(?:\bart(?:ikel|icle)?\.?[[:blank:]]*4(?![\p{L}\d])|§[[:blank:]]*5(?!\d))/iu
    APPEAL_HEADER = /\A[[:blank:]]*(?:Art(?:ikel|icle)?\.?[[:blank:]]*31\.?[[:blank:]]*)?§[[:blank:]]*1(?:er)?\.[[:blank:]]*/iu
    NATIVE_CLAUSES = {
      '1' => {
        notification: /\bvijftien[[:space:]]+dagen[[:space:]]+na[[:space:]]+de[[:space:]]+datum[[:space:]]+van[[:space:]]+kennisgeving\b/iu,
        registered: /\baangetekende[[:space:]]+brief\b/iu,
        adult_condition: /\bmeerderjarige\b.*\brecht[[:space:]]+niet\b/imu
      },
      '2' => {
        notification: /\bquinze[[:space:]]+jours[[:space:]]+à[[:space:]]+compter[[:space:]]+du[[:space:]]+jour[[:space:]]+de[[:space:]]+la[[:space:]]+notification\b/iu,
        registered: /\blettre[[:space:]]+recommandée\b/iu,
        adult_condition: /\bmajeur\b.*\bn['’]a[[:space:]]+pas[[:space:]]+le[[:space:]]+droit\b/imu
      }
    }.transform_values(&:freeze).freeze
    APPEAL_CLAUSES = {
      '1' => {
        adult: [
          /\ADe gemeente of de overtreder,/iu,
          /\bin geval van een administratieve geldboete\b/iu,
          /\bgeschreven verzoekschrift bij de politierechtbank\b/iu,
          /\bvolgens de burgerlijke procedure\b/iu,
          /\bbinnen een maand na kennisgeving van de beslissing\b/iu
        ],
        youth: [
          /\A[[:blank:]]*Wanneer de beslissing van de sanctionerend ambtenaar betrekking heeft op minderjarigen\b/iu,
          /\bkosteloos verzoekschrift bij de jeugdrechtbank\b/iu,
          /\bIn dat geval kan het beroep eveneens worden ingesteld door.*\bouderlijk gezag.*\bminderjarige\b/iu,
          /\bDe jeugdrechtbank blijft bevoegd indien de overtreder meerderjarig is geworden op het moment van de uitspraak\.[[:blank:]]*(?:\r?\n)?\z/iu
        ],
        next_alinea: /\A[[:blank:]]*(?:De politierechtbank of de jeugdrechtbank beslissen\b|§[[:blank:]]*2\.)/iu
      },
      '2' => {
        adult: [
          /\ALa commune ou le contrevenant,/iu,
          /\ben cas d['’]amende administrative\b/iu,
          /\brequête écrite auprès du tribunal de police\b/iu,
          /\bselon la procédure civile\b/iu,
          /\bdans le mois de la notification de la décision\b/iu
        ],
        youth: [
          /\A[[:blank:]]*Lorsque la décision du fonctionnaire sanctionnateur se rapporte aux mineurs\b/iu,
          /\brequête gratuite auprès du tribunal de la jeunesse\b/iu,
          /\bDans ce cas, le recours peut également être introduit par.*\bautorité parentale.*\bmineur\b/iu,
          /\bLe tribunal de la jeunesse demeure compétent si le contrevenant est devenu majeur au moment où il se prononce\.[[:blank:]]*(?:\r?\n)?\z/iu
        ],
        next_alinea: /\A[[:blank:]]*(?:Le tribunal de police ou le tribunal de la jeunesse,[[:blank:]]*statuent\b|§[[:blank:]]*2\.)/iu
      }
    }.transform_values { |clauses| clauses.transform_values(&:freeze).freeze }.freeze
    SANCTIONS_CLAUSES = {
      '1' => {
        discretion: /\bDe gemeenteraad kan in zijn reglementen of verordeningen in de mogelijkheid voorzien om een of meer van de volgende sancties op te leggen voor de feiten bedoeld in de artikelen 2 en 3\b/iu,
        items: [
          /1°[[:blank:]]+een administratieve geldboete die maximaal \d+ of (?:\[\d+[[:blank:]]*)?\d+ euro(?:\]\d+)? bedraagt, naargelang de overtreder minderjarig of meerderjarig is;/iu,
          /2°[[:blank:]]+de administratieve schorsing van een door de gemeente verleende toestemming of vergunning;/iu,
          /3°[[:blank:]]+de administratieve (?:\[\d+[[:blank:]]*)?opheffing(?:\]\d+)? van een door de gemeente verleende toestemming of vergunning;/iu,
          /4°[[:blank:]]+de tijdelijke of definitieve administratieve sluiting van een inrichting\./iu
        ],
        alternatives: [
          /De gemeenteraad kan in zijn reglementen of verordeningen voorzien in de volgende alternatieve maatregelen voor de administratieve geldboete bedoeld in § 1, 1°[[:blank:]]*:/iu,
          /1°[[:blank:]]+de gemeenschapsdienst, gedefinieerd als zijnde een prestatie van algemeen belang uitgevoerd door de overtreder ten gunste van de collectiviteit;/iu,
          /2°[[:blank:]]+de (?:\[\d+[[:blank:]]*)?GAS-bemiddeling(?:\]\d+)?, gedefinieerd als zijnde een maatregel die het voor de overtreder mogelijk maakt om, door tussenkomst van een bemiddelaar, de veroorzaakte schade te herstellen of schadeloos te stellen of om het conflict te doen bedaren\./iu
        ],
        penal: /De door de gemeenteraad vastgestelde straffen mogen de politiestraffen niet te boven gaan\./iu,
        traffic: [
          /In afwijking van § 1 kan voor de in artikel 3, 3°, bedoelde inbreuken alleen een administratieve geldboete zoals bedoeld in § 1, 1°, worden opgelegd\./iu,
          /Deze inbreuken worden door de Koning bij een besluit vastgesteld na overleg in de Ministerraad ingedeeld in vier categorieën/iu,
          /het bedrag van de daaraan verbonden administratieve geldboetes wordt bepaald in functie van de ernst van de bedreiging die zij betekenen voor de verkeersveiligheid en de mobiliteit\./iu
        ]
      },
      '2' => {
        discretion: /Le conseil communal peut prévoir dans ses règlements ou ordonnances la possibilité d['’]infliger une ou plusieurs des sanctions suivantes pour les faits visés aux articles 2 et 3/iu,
        items: [
          /1°[[:blank:]]+une amende administrative qui s['’]élève au maximum à \d+ euros ou (?:\[\d+[[:blank:]]*)?\d+ euros(?:\]\d+)? selon que le contrevenant est mineur ou majeur;/iu,
          /2°[[:blank:]]+la suspension administrative d['’]une autorisation ou permission délivrée par la commune;/iu,
          /3°[[:blank:]]+(?:\[\d+[[:blank:]]*)?l['’]abrogation administrative(?:\]\d+)? d['’]une autorisation ou permission délivrée par la commune;/iu,
          /4°[[:blank:]]+la fermeture administrative d['’]un établissement à titre temporaire ou définitif\./iu
        ],
        alternatives: [
          /Le conseil communal peut prévoir dans ses règlements ou ordonnances les mesures alternatives suivantes à l['’]amende administrative visée au § 1er, 1°[[:blank:]]*:/iu,
          /1°[[:blank:]]+la prestation citoyenne définie comme étant une prestation d['’]intérêt général effectuée par le contrevenant au profit de la collectivité;/iu,
          /2°[[:blank:]]+la (?:\[\d+[[:blank:]]*)?médiation SAC(?:\]\d+)? définie comme une mesure permettant au contrevenant, grâce à l['’]intervention d['’]un médiateur, de réparer ou d['’]indemniser le dommage causé ou d['’]apaiser le conflit\./iu
        ],
        penal: /Les peines établies par le conseil communal ne peuvent excéder les peines de police\./iu,
        traffic: [
          /Par dérogation au § 1er, seule une amende administrative visée au § 1er, 1°, peut être imposée pour les infractions visées à l['’]article 3, 3°\./iu,
          /Ces infractions sont réparties par le Roi, par arrêté délibéré en Conseil des ministres, en quatre catégories/iu,
          /précisant le montant des amendes administratives qui y sont liées, en fonction de la gravité de la menace qu['’]elles représentent pour la sécurité routière et la mobilité\./iu
        ]
      }
    }.transform_values { |clauses| clauses.transform_values(&:freeze).freeze }.freeze

    def self.excerpt(article, text:, question:, max_chars:)
      return nil unless MunicipalSanctionsSourceScope.topic?(question)
      return nil unless article.is_a?(Hash)

      title = article[:article_title].to_s.match(ARTICLE_TITLE)
      return nil unless article[:numac].to_s == '2013000441' && title

      clauses = NATIVE_CLAUSES[article[:language_id].to_s]
      return nil unless clauses && max_chars.is_a?(Integer) && max_chars.positive?

      # Use the very same prepared text the ordinary context path received,
      # rather than rereading a differently encoded/unprepared source field.
      text = text.to_s
      return nil unless text.encoding == Encoding::UTF_8 && text.valid_encoding?

      return sanctions_excerpt(text, article[:language_id].to_s, max_chars, question) if title[1] == '4'
      return appeal_route_excerpt(text, article[:language_id].to_s, max_chars) if title[1] == '31'

      defense_excerpt(text, clauses, max_chars)
    end

    def self.defense_excerpt(text, clauses, max_chars)
      headers = text.to_enum(:scan, PARAGRAPH_HEADER).map { Regexp.last_match.dup }
      start = headers.index { |header| header[1] == '2' }
      return nil unless start

      procedural_headers = headers.drop(start)
      return nil unless procedural_headers.map { |header| header[1] } == %w[2 3 4 5]

      defense = text[procedural_headers[0].begin(0)...procedural_headers[1].begin(0)]
      hearing = text[procedural_headers[2].begin(0)...procedural_headers[3].begin(0)]
      return nil unless defense.match?(clauses[:notification]) && defense.match?(clauses[:registered]) &&
                        hearing.match?(clauses[:adult_condition])

      tail = text[procedural_headers[0].begin(0)..]
      return nil if tail.include?('[...]') || tail.length > [max_chars, MAX_EXCERPT_CHARS].min

      tail
    end

    def self.appeal_route_excerpt(text, language_id, max_chars)
      clauses = APPEAL_CLAUSES.fetch(language_id)
      # Justel stores each alinea on its own line. Require the initial §1
      # heading, both complete route alinea, and the next native boundary;
      # never stitch sentences or truncate the minor/parental qualifications.
      first, second, following = text.lines.first(3)
      heading = first&.match(APPEAL_HEADER)
      return nil unless heading && second && following

      adult = first[heading.end(0)..]
      return nil unless clauses[:adult].all? { |pattern| adult.match?(pattern) } &&
                        clauses[:youth].all? { |pattern| second.match?(pattern) } &&
                        following.match?(clauses[:next_alinea])

      route = text[0, first.length + second.length]
      return nil if route.include?('[...]') || route.length > [max_chars, MAX_EXCERPT_CHARS].min

      route
    end

    def self.sanctions_excerpt(text, language_id, max_chars, question)
      # A complete row or deliberately named Article 4/§5 must keep the
      # ordinary path, including its later youth-consultation provision.
      return nil if text.length <= max_chars || question.to_s.match?(EXPLICIT_SANCTIONS_SELECTION)
      return nil unless text.match?(SANCTIONS_HEADER)

      headers = text.to_enum(:scan, SANCTIONS_BOUNDARY).map { Regexp.last_match.dup }
      return nil unless headers.map { |header| header[1] } == %w[2 3 4 5]

      clauses = SANCTIONS_CLAUSES.fetch(language_id)
      first = text[0...headers[0].begin(0)]
      alternatives = text[headers[0].begin(0)...headers[1].begin(0)]
      penal = text[headers[1].begin(0)...headers[2].begin(0)]
      traffic = text[headers[2].begin(0)...headers[3].begin(0)]
      item_headers = /(?:\A|\n)[[:blank:]]*(\d+)°/u
      return nil unless first.scan(item_headers).flatten == %w[1 2 3 4] && alternatives.scan(item_headers).flatten == %w[1 2]
      return nil unless first.match?(clauses[:discretion]) && clauses[:items].all? { |pattern| first.match?(pattern) } &&
                        clauses[:alternatives].all? { |pattern| alternatives.match?(pattern) } &&
                        penal.match?(clauses[:penal]) && clauses[:traffic].all? { |pattern| traffic.match?(pattern) }

      # One initial source prefix: all of §1–§4, including the alternative
      # measures and traffic qualifications. §5 is the verified next boundary,
      # not part of this excerpt; no clauses are stitched or labels supplied.
      prefix = text[0...headers[3].begin(0)]
      return nil if prefix.include?('[...]') || prefix.length > [max_chars, MAX_EXCERPT_CHARS].min

      prefix
    end
    private_class_method :defense_excerpt, :appeal_route_excerpt, :sanctions_excerpt
  end
end
