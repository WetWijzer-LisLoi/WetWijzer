# frozen_string_literal: true

require 'uri'

module LegalChatbot
  # Reviewed primary-source guidance, NOT legislation or an entitlement to
  # credit. The Belgian articles corpus cannot ground a lender's current FAQ.
  # Admit only these exact records, only for purchase-finance intent, and stop
  # using them when their short review window expires. No request-time browsing.
  class MortgageFinanceSources
    VERIFIED_ON = Date.new(2026, 10, 11)
    REVIEW_AFTER = Date.new(2027, 1, 11)
    # Merely paying rent by bank transfer is not purchase-finance intent.
    # Require a financing instrument/verb, or a direct bank-funded purchase
    # phrase; do not combine a tenant's bank payment with a landlord's purchase
    # elsewhere in a long post. The cues can otherwise span several sentences,
    # as in a tenant who may buy the home and then asks about a loan.
    FINANCE = /\b(?:hypoth[eè]e?k\w*|hypoth[eéè]que\w*|hypothecair\w*|mortgage\w*|hypoth[eéè]cair\w*|hypothek\w*|immobilienkredit|woonlening|lening|lenen|leent|loan|lend(?:s|ing)?|borrow\w*|pr[eê]t(?:er|e(?:nt|z)?|ons|[eé])?|krediet|credit|cr[eé]dit|darlehen|leihen|leiht|financ(?:e|ed|ing|er)|financement\w*|financier\w*|finanzier\w*)\b/iu
    BANK_PURCHASE_FINANCE = /\b(?:
      (?:bij|via|met)[[:blank:]]+(?:de|een)[[:blank:]]+bank[[:blank:]]+(?:(?:een|het|mijn|ons|dit)[[:blank:]]+)?(?:huis|woning|appartement)[[:blank:]]+(?:te[[:blank:]]+)?kopen |
      (?:huis|woning|appartement)[[:blank:]]+(?:te[[:blank:]]+)?kopen[[:blank:]]+(?:bij|via|met)[[:blank:]]+(?:de|een)[[:blank:]]+bank |
      buy(?:ing)?[[:blank:]]+(?:(?:a|the|my|our|this)[[:blank:]]+)?(?:home|house|apartment)[[:blank:]]+(?:through|via|with)[[:blank:]]+(?:a|the)[[:blank:]]+bank |
      (?:through|via|with)[[:blank:]]+(?:a|the)[[:blank:]]+bank[[:blank:]]+(?:to[[:blank:]]+)?buy[[:blank:]]+(?:(?:a|the|my|our|this)[[:blank:]]+)?(?:home|house|apartment) |
      acheter[[:blank:]]+(?:(?:un|une|le|la|mon|notre)[[:blank:]]+)?(?:logement|habitation|appartement|maison)[[:blank:]]+(?:avec|via|par|aupr[eè]s[[:blank:]]+de)[[:blank:]]+(?:une|la)[[:blank:]]+banque |
      (?:avec|via|par|aupr[eè]s[[:blank:]]+de)[[:blank:]]+(?:une|la)[[:blank:]]+banque[[:blank:]]+(?:pour[[:blank:]]+)?acheter[[:blank:]]+(?:(?:un|une|le|la|mon|notre)[[:blank:]]+)?(?:logement|habitation|appartement|maison) |
      (?:(?:ein|eine|das|die|mein|meine|unser|unsere)[[:blank:]]+)?(?:Haus|Wohnung)[[:blank:]]+(?:[uü]ber|mit|bei)[[:blank:]]+(?:die|der|einer)[[:blank:]]+Bank[[:blank:]]+kaufen
    )\b/ixu
    # A housing word plus "loan" is not enough: rental-deposit questions
    # often mention a home and savings too, but must not receive purchase-
    # mortgage guidance. Require an explicit purchase/mortgage instrument.
    PURCHASE_FINANCE = /\b(?:hypoth[eè]e?k\w*|hypoth[eéè]que\w*|hypothecair\w*|mortgage\w*|hypoth[eéè]cair\w*|hypothek\w*|immobilienkredit|woonlening|ko(?:op|p)\w*|aankoop\w*|acheter|achat|buy(?:ing)?|purchase|kauf\w*)\b/iu
    HOUSING = /\b(?:appartement|woning|huis|woonlening|hypoth[eè]e?k\w*|hypoth[eéè]que\w*|hypothecair\w*|home|house|apartment|mortgage\w*|logement|habitation|hypoth[eéè]cair\w*|wohnung|haus|hypothek\w*|immobilienkredit)\b/iu
    EQUITY = /\b(?:eigen\s+inbreng|spaargeld|spaarboek|zonder\s+(?:sparen|inbreng)|quotiteit|ltv|down\s*payment|deposit|savings|no\s+equity|without\s+equity|apport|[eé]pargne|fonds\s+propres|eigenkapital|ersparnisse|anzahlung|beleihung|social\w*|sociaal\w*)\b/iu
    FOREIGN = /\b(?:nederland|netherlands|frankrijk|france|deutschland|germany|england|united\s+kingdom)\b/iu
    BELGIUM = /\b(?:belgi[eë]|belgique|belgium|belgien)\b/iu

    RECORDS = [
      {
        key: 'nbb_mortgage_expectations', region: 'federal', language: 'NL',
        authority: 'Nationale Bank van België', title: 'NBB — hypothecaire kredietverlening (toelichting)',
        url: 'https://www.nbb.be/nl/financieel-toezicht/macroprudentieel-beleid/macroprudentiele-instrumenten/vastgoed/faq-prudentiele',
        article_text: 'De Nationale Bank legt dus geen verbod op voor leningen met een hoge quotiteit.',
        reviewed_summary: 'The NBB FAQ describes prudential expectations for lenders, not an individual right to a loan or an absolute lending ban. It asks lenders to limit high loan-to-value lending (above 90% for own housing, 80% for rental investment), with room for exceptions including first-time buyers. The lender assesses the particular borrower. Do not present portfolio thresholds as a mandatory personal down payment, or a parliamentary proposal as enacted law.'
      },
      {
        key: 'vlaams_woningfonds_purchase', region: 'vlaamse_codex', language: 'NL',
        authority: 'Vlaams Woningfonds', title: 'Vlaamse woonlening — bedrag en rentevoet (toelichting)',
        url: 'https://www.vlaamswoningfonds.be/onze-diensten/vlaamse-woonlening/bedrag-en-rentevoet',
        article_text: 'Je rentevoet wordt in principe berekend op basis van een aantal factoren:',
        reviewed_summary: 'The Vlaamse woonlening is a purchase-finance option to investigate in Flanders, subject to the programme conditions and an individual assessment. The published amount rules consider purchase price, possible purchase costs and essential works; the total loan cannot exceed the estimated property value, after financed works where applicable. This does not promise that all costs or a purchase without savings will be financed. Ask the fund for a personalised feasibility calculation; this is not a rental-deposit loan.'
      },
      {
        key: 'brussels_housing_fund_purchase', region: 'brussels', language: 'NL',
        authority: 'Woningfonds Brussel', title: 'Woningfonds Brussel — hypothecair aankoopkrediet (toelichting)',
        url: 'https://fonds.brussels/nl/kredieten/hypothecair-krediet',
        article_text: 'Het bedrag van het krediet zal worden vastgesteld op basis van je terugbetalingscapaciteit.',
        reviewed_summary: 'For a property in the Brussels-Capital Region, the Housing Fund offers purchase mortgages subject to income conditions and repayment capacity. The current page says that some acquisition, renovation or deed costs can be financed and that, in justified cases accepted by the fund, a loan may reach 120% of the property value. That is a conditional maximum, not a right or a guarantee of zero personal contribution. The fund recommends arranging finance conditions before committing to buy. Check current eligibility directly with the fund.'
      },
      {
        key: 'swcs_purchase', region: 'wallex', language: 'FR',
        authority: 'Société wallonne du crédit social (SWCS)', title: 'SWCS — Accesspack, achat et épargne (informations)',
        url: 'https://www.swcs.be/solutions/acheter',
        article_text: 'Ce montant peut être fixé par la SWCS qui tient compte de votre situation, de votre projet et de vos possibilités financières.',
        reviewed_summary: 'In Wallonia, the SWCS Accesspack is a social mortgage option for purchase and eligible works, subject to programme conditions and an individual credit decision. Its FAQ asks applicants to contribute as much personal savings as possible; SWCS determines the contribution with regard to their situation, project and financial means. It checks long-term affordability and may refuse the application. Its representative example has costs paid from personal funds, so do not promise an automatically available zero-contribution or all-costs loan. Request an individual simulation.'
      }
    ].map do |record|
      record.merge(source: 'official_guidance', official_source_id: record.fetch(:key),
                   law_title: record.fetch(:title), article_title: 'Primary-source guidance, not legislation',
                   verified_on: VERIFIED_ON.iso8601).transform_values do |value|
        value.is_a?(String) ? value.freeze : value
      end.freeze
    end.freeze

    def self.topic?(question)
      text = question.to_s
      return false if text.match?(FOREIGN) && !text.match?(BELGIUM)

      (text.match?(FINANCE) || text.match?(BANK_PURCHASE_FINANCE)) &&
        text.match?(HOUSING) && text.match?(EQUITY) && text.match?(PURCHASE_FINANCE)
    end

    def self.sources_for(question)
      return [] unless topic?(question)
      return [] if Date.current > REVIEW_AFTER

      regions = RegionalSearch.named_regions(question)
      RECORDS.select do |record|
        (regions.empty? || record[:region] == 'federal' || regions.include?(record[:region])) && valid_record?(record)
      end.map(&:dup)
    end

    def self.valid_record?(record)
      canonical = RECORDS.find { |entry| entry[:key] == record[:key] }
      return false unless canonical && record == canonical

      uri = URI.parse(record.fetch(:url))
      uri.scheme == 'https' && uri.userinfo.nil? && uri.port == 443 && uri.fragment.nil?
    rescue KeyError, URI::InvalidURIError
      false
    end
  end
end
