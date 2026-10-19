# frozen_string_literal: true

module LegalChatbot
  # A paid goods sale followed by non-delivery and a repayment/civil-procedure
  # request. Police reporting is neither an activation requirement nor a
  # reason to substitute tax-declaration sources for the civil claim.
  module MarketplaceCivilClaimIntent
    SALE_PATTERN = /\b(?:verkoper\p{L}*|koper\p{L}*|gekocht|kocht|aankoop|2dehands|tweedehands|marktplaats|marketplace|seller\p{L}*|bought|purchas\p{L}*|vendeur\p{L}*|achet\p{L}*|achat|verk[äa]ufer\p{L}*|gekauft|kaufte)\b/iu
    PAYMENT_PATTERN = /\b(?:betaal\p{L}*|betaald\p{L}*|betal\p{L}*|overgeschreven|overschrijving|paid|payment\p{L}*|transferred|pay[ée]\p{L}*|paiement\p{L}*|virement|bezahlt|gezahlt|[üu]berwiesen|[Üu]berweisung|Zahlungsbeleg)\b/iu
    NON_DELIVERY_PATTERN = /\b(?:niet\s+(?:geleverd|ontvangen|verstuurd)|nooit\s+(?:geleverd|ontvangen|verstuurd)|levert\s+niet|levering\s+blijft\s+uit|niets\s+ontvangen|not\s+(?:delivered|received|sent)|never\s+(?:delivered|received|sent)|(?:does\s+not|did\s+not|won['’]t)\s+(?:deliver|send)|non[-\s]?delivery|(?:ne\s+)?livre\s+pas|pas\s+(?:livr[ée]|re[cç]u)|jamais\s+(?:livr[ée]|re[cç]u)|non[-\s]?livraison|nicht\s+(?:geliefert|erhalten|verschickt)|liefert\s+nicht|nie\s+(?:geliefert|erhalten)|Nichtlieferung)\b/iu
    CLAIM_PATTERN = /\b(?:vrederechter|ingebrekestell\p{L}*|verzoen\p{L}*|gerechtskosten|geld\s+terug|terugbetal\p{L}*|terugvorder\p{L}*|dagvaard\p{L}*|justice\s+of\s+the\s+peace|small\s+claims?|civil\s+claim|conciliation|formal\s+notice|refund\p{L}*|money\s+back|court\s+costs?|summons|justice\s+de\s+paix|juge\s+de\s+paix|mise\s+en\s+demeure|rembours\p{L}*|frais\s+de\s+justice|citation|Friedensrichter|Friedensgericht|Inverzugsetzung|Mahnung|Schlichtung|Geld\s+zur[üu]ck|R[üu]ckerstattung|Gerichtskosten|Zivilklage)\b/iu

    # Exact NL identities and bodies verified in the protected corpus lookup
    # on 2026-10-17. Each row supplies a different part of the civil claim;
    # none establishes that a particular court or remedy applies by itself.
    ALL_ARTICLE_TARGETS = [
      %w[1967101054 590], %w[1967101055 731],
      %w[1967101055 732], %w[1967101055 733],
      %w[2022A32058 5.231], %w[2022A32058 5.233], %w[2022A32058 5.83],
      %w[1967101055 700], %w[1967101055 728], %w[1967101055 1017],
      %w[1967101055 1022], %w[2022A32058 5.90]
    ].map(&:freeze).freeze

    TAX_QUERY_PATTERN = /\b(?:belasting\p{L}*|inkomstenbelast\p{L}*|personenbelast\p{L}*|vennootschapsbelast\p{L}*|roerende\s+voorheffing|fiscaal\p{L}*|fiscale|inkomsten|btw|tax(?:es|ation)?|income\s+tax|vat|imp[ôo]t\p{L}*|fiscal\p{L}*|tva|steuer\p{L}*|Einkommensteuer|Mehrwertsteuer)\b/iu
    TAX_SOURCE_PATTERN = %r{\b(?:inkomstenbelastingen|KB\s*/\s*WIB|WIB\s*92|imp[ôo]ts?\s+sur\s+les\s+revenus|AR\s*/\s*CIR|CIR\s*92|income\s+tax|Einkommensteuer)\b}iu
    SECURITIES_PATTERN = /\b(?:fondsen[-\s]+en\s+wisselbeurs|effectenbeurs|effectenhandel|effectenvereffening|beurstransactie\p{L}*|stock\s+exchange|securities\s+(?:trading|settlement|market)|bourse\s+(?:des\s+)?(?:fonds|valeurs|titres)|r[èe]glement[-\s]livraison|Wertpapier\p{L}*|B[öo]rsenhandel)\b/iu
    FIRE_INSURANCE_PATTERN = /\b(?:brandverzekering\p{L}*|brandschade|verzekering\s+tegen\s+brand|fire\s+(?:insurance|risk|damage)|assurance\s+(?:contre\s+l['’])?incendie|risques?\s+d['’]incendie|Feuerversicherung|Brandschaden)\b/iu
    INTERNET_FOR_ALL_PATTERN = /\b(?:internet\s+voor\s+iedereen|internet\s+pour\s+tous|internet\s+for\s+(?:all|everyone)|internet\s+f[üu]r\s+alle)\b/iu
    RENTAL_PATTERN = /\b(?:woninghuur\p{L}*|huurovereenkomst\p{L}*|huurcontract\p{L}*|huurder\p{L}*|verhuurder\p{L}*|residential\s+(?:lease|tenancy)|tenants?|landlords?|bail\p{L}*|locataire\p{L}*|bailleur\p{L}*|Mietvertrag|Wohnraummiete|Mieter\p{L}*|Vermieter\p{L}*)\b/iu
    INSTALMENT_PATTERN = /\b(?:afbetaling\p{L}*|verkoop\s+op\s+afbetaling|huurkoop|hire[-\s]?purchase|instalments?|installments?|vente\s+[àa]\s+temp[ée]rament|vente\s+[àa]\s+cr[ée]dit|Ratenkauf|Teilzahlung\p{L}*|Ratenzahlung\p{L}*)\b/iu
    # These observed sources have different specialist subjects despite
    # mentioning a seller, payment proof, default or a justice of the peace.
    # Identity fallbacks cover generic annex/number headings, while source
    # text also catches equivalent rows returned through another adapter.
    SPECIALIST_SOURCE_GATES = [
      [%w[1935020153], SECURITIES_PATTERN],
      [%w[1988011063], FIRE_INSURANCE_PATTERN],
      [%w[2006002028], INTERNET_FOR_ALL_PATTERN],
      [%w[2007009485], RENTAL_PATTERN],
      [%w[1957070902], INSTALMENT_PATTERN]
    ].map(&:freeze).freeze
    BAILMENT_PATTERN = /\b(?:vrijwillige\s+bewaargeving|bewaargeving|bewaarnemer\p{L}*|bewaargever\p{L}*|d[ée]p[ôo]t\s+volontaire|contrat\s+de\s+d[ée]p[ôo]t|d[ée]positaire|bailment|bailee|bailor|Verwahrungsvertrag|freiwillige\p{L}*\s+Verwahrung)\b/iu
    PROPERTY_OBJECT_PATTERN = /\b(?:onroerend\p{L}*|vastgoed|terrein\p{L}*|grond|woning\p{L}*|huizen?|appartement\p{L}*|immeuble\p{L}*|immobili\p{L}*|terrains?|maisons?|immovable\s+property|real\s+estate|(?:houses?|homes?)(?!\s+(?:plants?|wares?|goods|appliances?|electronics|decor))|land|Grundst[üu]ck\p{L}*|Immobilie\p{L}*|H[äa]user|Haus)\b/iu
    PROPERTY_SALE_PATTERN = /\b(?:verkoop\p{L}*|aankoop\p{L}*|koopovereenkomst\p{L}*|koop|kocht|gekocht|verkocht\p{L}*|vente|achat|achet[ée]\p{L}*|vendu\p{L}*|sale|purchase\p{L}*|sold|bought|buying|Kauf|Verkauf|verkauft\p{L}*|gekauft\p{L}*)\b/iu
    PROPERTY_SALE_FACT_PATTERN = /
      (?:#{PROPERTY_SALE_PATTERN.source})[^.!?;\n]{0,85}(?:#{PROPERTY_OBJECT_PATTERN.source})|
      (?:#{PROPERTY_OBJECT_PATTERN.source})[^.!?;\n]{0,85}(?:#{PROPERTY_SALE_PATTERN.source})
    /ixu
    CISG_PATTERN = /\b(?:CISG|Weens\s+Koopverdrag|Vienna\s+(?:Sales\s+)?Convention|Convention\s+de\s+Vienne|Wiener\s+Kaufrecht|UN[-\s]?Kaufrecht)\b/iu
    GOODS_DEFECT_PATTERN = /\b(?:niet[-\s]?conform\p{L}*|non[-\s]?conform\p{L}*|conformiteitsgebrek\p{L}*|gebrekkig\p{L}*|gebreken|defect\p{L}*|d[ée]faut\p{L}*|Sachm[äa]ngel\p{L}*|mangelhaft\p{L}*)\b/iu
    GOODS_INSPECTION_PATTERN = /\b(?:keur\p{L}*|onderzoeks[-\s]?\p{L}*|klachtplicht|inspect\p{L}*|examin\p{L}*|examen|v[ée]rifi\p{L}*|Untersuch\p{L}*|R[üu]gepflicht)\b/iu
    GOODS_DEFECT_QUERY_PATTERN = Regexp.union(GOODS_DEFECT_PATTERN, /\b(?:garantie\p{L}*|warrant\p{L}*|Gew[äa]hrleistung\p{L}*)\b/iu)
    # The buyer seeking a refund is a creditor, not the consumer-debtor whose
    # unpaid invoice is being collected. Require affirmative debtor-role AND
    # collection-cost evidence, rather than excluding ordinary notice, proof
    # or court-cost material merely because it mentions a consumer or debt.
    CONSUMER_DEBTOR_SOURCE_PATTERN = /\b(?:consument\p{L}*\s+met\s+betalingsachterstand|schulden\s+van\s+(?:(?:de|een)\s+)?consument\p{L}*|kosten\b[^.!?;]{0,65}\bvan\s+(?:(?:de|een)\s+)?consument\p{L}*\b[^.!?;]{0,65}\bgevorderd|consommateur\p{L}*\b[^.!?;]{0,65}\b(?:d[ée]biteur\p{L}*|retard\s+de\s+paiement)|dettes?\s+(?:du|des)\s+consommateur\p{L}*|consumer\p{L}*\b[^.!?;]{0,55}\b(?:debtors?|payment\s+arrears|unpaid\s+(?:debts?|invoices?))|debts?\s+owed\s+by\s+(?:the\s+)?consumers?|Verbraucher\p{L}*\b[^.!?;]{0,55}\b(?:Zahlungsr[üu]ckstand\p{L}*|Schuldner\p{L}*)|Verbraucherschuld\p{L}*)\b/iu
    CONSUMER_COLLECTION_COST_SOURCE_PATTERN = /\b(?:kosten\b[^.!?;]{0,100}\bgevorderd|minnelijke\s+invordering|schuld\s+minnelijk\s+invordert|frais\s+(?:de\s+)?recouvrement|recouvrement\s+amiable|(?:debt[-\s]?collection|collection)\s+(?:costs?|fees)|Inkassokosten|Beitreibungskosten)\b/iu
    CONSUMER_DEBT_COLLECTION_QUERY_PATTERN = /\b(?:incasso\p{L}*|invorderingskosten|aanmaningskosten|minnelijke\s+invordering|schuldinvordering|betalingsachterstand|consumentenschuld\p{L}*|recouvrement\p{L}*|frais\s+de\s+rappel|dettes?\s+(?:du|des)\s+consommateur\p{L}*|debt[-\s]?collect\p{L}*|collection\s+(?:fees|costs)|payment\s+arrears|consumer\s+debts?|Inkasso\p{L}*|Beitreib\p{L}*|Mahnkosten|Zahlungsr[üu]ckstand\p{L}*|Verbraucherschuld\p{L}*)\b/iu

    def self.topic?(question)
      text = question.to_s.gsub(/[[:space:]]+/, ' ')
      text.match?(SALE_PATTERN) && text.match?(PAYMENT_PATTERN) &&
        text.match?(NON_DELIVERY_PATTERN) && text.match?(CLAIM_PATTERN)
    end

    def self.tax_question?(question)
      question.to_s.match?(TAX_QUERY_PATTERN)
    end

    def self.article_targets(question)
      topic?(question) ? ALL_ARTICLE_TARGETS : []
    end

    def self.source_relevant?(article, question)
      question = question.to_s
      return true unless topic?(question)

      numac = field(article, :numac).to_s
      return true if field(article, :pinned) || (!numac.empty? && question.downcase.include?(numac.downcase))

      title = [field(article, :law_title), field(article, :title)].compact.join(' ')
      return false if (numac == '1993082751' || title.match?(TAX_SOURCE_PATTERN)) && !tax_question?(question)

      source_text = [title, field(article, :article_title), field(article, :article_text), field(article, :text)].compact.join(' ')
      return false if SPECIALIST_SOURCE_GATES.any? do |numacs, pattern|
        (numacs.include?(numac) || source_text.match?(pattern)) && !question.match?(pattern)
      end

      true
    end

    def self.secondary_source_relevant?(source, question, context_numacs: [])
      question = question.to_s
      return true unless topic?(question)
      return true if selected_secondary_source?(source, question, context_numacs)

      # Positive facts identify the other contractual relationship. Generic
      # proof, notice, repayment and court-procedure cases remain available;
      # neither a particular ECLI nor the age of a case determines relevance.
      texts = %i[title summary full_text content article_text].filter_map do |key|
        value = field(source, key)
        value.to_s.gsub(/[[:space:]]+/, ' ') if value.present?
      end
      return false if texts.any? { |text| text.match?(BAILMENT_PATTERN) } && !question.match?(BAILMENT_PATTERN)
      return false if texts.any? { |text| text.match?(PROPERTY_SALE_FACT_PATTERN) } && !question.match?(PROPERTY_SALE_FACT_PATTERN)

      defect_inspection = texts.any? do |text|
        text.match?(CISG_PATTERN) && text.match?(GOODS_DEFECT_PATTERN) && text.match?(GOODS_INSPECTION_PATTERN)
      end
      return false if defect_inspection && !question.match?(CISG_PATTERN) && !question.match?(GOODS_DEFECT_QUERY_PATTERN)

      consumer_debtor_costs = texts.any? do |text|
        text.match?(CONSUMER_DEBTOR_SOURCE_PATTERN) && text.match?(CONSUMER_COLLECTION_COST_SOURCE_PATTERN)
      end
      return false if consumer_debtor_costs && !question.match?(CONSUMER_DEBT_COLLECTION_QUERY_PATTERN) &&
                      texts.none? { |text| topic?(text) }

      true
    end

    def self.selected_secondary_source?(source, question, context_numacs)
      return true if %i[pinned viewed selected explicit].any? { |key| [true, 1, 'true', '1'].include?(field(source, key)) }

      identifiers = %i[case_number ecli numac legislation_numac].map { |key| field(source, key).to_s }.reject(&:empty?)
      return true if identifiers.any? do |identifier|
        question.match?(/(?<![[:alnum:]_:])#{Regexp.escape(identifier)}(?![[:alnum:]_:]|\.[[:alnum:]])/iu)
      end

      numac = (field(source, :numac) || field(source, :legislation_numac)).to_s
      !numac.empty? && Array(context_numacs).any? { |value| value.to_s == numac }
    end
    private_class_method :selected_secondary_source?

    def self.field(article, key)
      article[key] || article[key.to_s]
    end
    private_class_method :field
  end
end
