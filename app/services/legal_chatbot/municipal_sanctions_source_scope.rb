# frozen_string_literal: true

module LegalChatbot
  # Keeps ordinary municipal administrative-sanction material available for
  # municipal GAS questions without allowing nearby staff-subsidy or road
  # remediation material to displace the requested source family.
  #
  # This is deliberately a subject gate, not a legal answer or a NUMAC list.
  # The caller remains responsible for explicit/viewed/pinned source context.
  module MunicipalSanctionsSourceScope
    # Bare "gas" is ordinary infrastructure language (gasleiding, gas pipe),
    # so it is not a GAS signal. Require the acronym's fine/sanction context.
    MUNICIPAL_FINE_PATTERN = /\b(?:GAS[-\s]?(?:boete|sanctie|sanction)\p{L}*|gemeentelijke\s+administratieve\s+sanct(?:ie|ions?)\p{L}*|sanctions?\s+administratives?\s+communales?|amendes?\s+administratives?\s+communales?|municipal\s+administrative\s+(?:fine|sanction)s?|kommunale\s+verwaltungs(?:strafe|sanktion)\p{L}*)\b/iu
    SIDEWALK_NUISANCE_PATTERN = /\b(?:stoep\p{L}*|voetpad\p{L}*|trottoir\p{L}*|sidewalk\p{L}*|gehweg\p{L}*|openbare\s+overlast\p{L}*|nuisance\s+publique\p{L}*|public\s+nuisance\p{L}*|öffentliche\s+belästigung\p{L}*)\b/iu
    MUNICIPALITY_PATTERN = /\b(?:stad\p{L}*|gemeente\p{L}*|ville\p{L}*|commune\p{L}*|city|municipality|stadt|gemeinde)\b/iu

    # These paired signals distinguish the irrelevant families found in the
    # corpus from a GAS provision that merely happens to use "sanction".
    STAFF_PERSONNEL_PATTERN = /\b(?:personeel\p{L}*|aanwerv\p{L}*|tewerkstell\p{L}*|justitieassistent\p{L}*|personnel\p{L}*|recrut\p{L}*|staff\b|hiring\b|personal\p{L}*|einstellung\p{L}*)\b/iu
    STAFF_AID_PATTERN = /\b(?:financi[ëe]le\s+hulp\p{L}*|subsid\p{L}*|grant\p{L}*|subvention\p{L}*|alternatieve\s+(?:gerechtelijke\s+)?(?:maatregel|straff?)\p{L}*|peine\s+(?:alternative|judiciaire)\p{L}*|alternative\s+(?:penalt|sanction|measure|strafe)\p{L}*)\b/iu
    STAFF_GRANT_PAIR_PATTERN = /(?:#{STAFF_PERSONNEL_PATTERN.source})[^.!?;\n]{0,180}(?:#{STAFF_AID_PATTERN.source})|(?:#{STAFF_AID_PATTERN.source})[^.!?;\n]{0,180}(?:#{STAFF_PERSONNEL_PATTERN.source})/iu
    ROAD_REMEDIATION_PATTERN = /\b(?:herstelkosten\p{L}*|recuperatiekosten\p{L}*|kosten\s+voor\s+herstel\p{L}*|herstel\s+van\s+de\s+plaats|remise\s+en\s+état|travaux\s+de\s+réparation\p{L}*|frais\s+de\s+réparation\p{L}*|coûts?\s+de\s+réparation\p{L}*|repair\s+costs?|recovery\s+costs?|reparaturkosten\p{L}*|wiederherstellungskosten\p{L}*)\b/iu
    ROAD_SUBJECT_PATTERN = /\b(?:gemeenteweg\p{L}*|openbare\s+weg\p{L}*|voetpad\p{L}*|stoep\p{L}*|voirie\p{L}*|trottoir\p{L}*|municipal\s+road\p{L}*|sidewalk\p{L}*|kommunale[rn]?\s+weg\p{L}*|gehweg\p{L}*)\b/iu

    STAFF_QUERY_PATTERN = /\b(?:subsid\p{L}*|grant\p{L}*|subvention\p{L}*|personeel\p{L}*|aanwerv\p{L}*|tewerkstell\p{L}*|personnel\p{L}*|recrut\p{L}*|hiring\b|staff\b|einstellung\p{L}*|alternative\s+(?:straf|penalt|peine)\p{L}*)\b/iu
    ROAD_QUERY_PATTERN = /\b(?:herstelkosten\p{L}*|recuperatiekosten\p{L}*|kosten\s+voor\s+herstel\p{L}*|reparatiekosten\p{L}*|travaux\s+de\s+réparation\p{L}*|frais\s+de\s+réparation\p{L}*|repair\s+costs?|recovery\s+costs?|reparaturkosten\p{L}*|road\s+law|wegenrecht|droit\s+de\s+la\s+voirie|straßenrecht)\b/iu
    SIDEWALK_TORT_SOURCE_PATTERN = /\b(?:val(?:len|partij|geval(?:len)?)?|struikel\p{L}*|chute\p{L}*|ongeval\p{L}*|aansprakelijk\p{L}*|schadevergoed\p{L}*|liability|fall(?:en|ing)?|fell|injur\p{L}*|accident\p{L}*|responsabilit[ée]\p{L}*|dommage\p{L}*|sturz\p{L}*|verletz\p{L}*|haftung\p{L}*)\b/iu
    SIDEWALK_TORT_QUERY_PATTERN = /\b(?:val(?:len|partij|geval(?:len)?)?|struikel\p{L}*|chute\p{L}*|ongeval\p{L}*|aansprakelijk\p{L}*|schadevergoed\p{L}*|liability|fall(?:en|ing)?|fell|injur\p{L}*|accident\p{L}*|responsabilit[ée]\p{L}*|dommage\p{L}*|sturz\p{L}*|verletz\p{L}*|haftung\p{L}*)\b/iu

    def self.topic?(question)
      text = question.to_s
      text.match?(MUNICIPAL_FINE_PATTERN) &&
        text.match?(SIDEWALK_NUISANCE_PATTERN) &&
        text.match?(MUNICIPALITY_PATTERN)
    end

    def self.admit?(source, question:)
      question = question.to_s
      return true unless topic?(question)
      return true if selected_source?(source, question)

      text = source_text(source)
      return false if staff_grant_source?(text) && !question.match?(STAFF_QUERY_PATTERN)
      return false if road_remediation_source?(text) && !question.match?(ROAD_QUERY_PATTERN)
      return false if sidewalk_tort_source?(text) && !question.match?(SIDEWALK_TORT_QUERY_PATTERN)

      true
    end

    class << self
      alias source_relevant? admit?
    end

    def self.staff_grant_source?(text)
      text.match?(STAFF_GRANT_PAIR_PATTERN)
    end
    private_class_method :staff_grant_source?

    def self.road_remediation_source?(text)
      text.match?(ROAD_REMEDIATION_PATTERN) && text.match?(ROAD_SUBJECT_PATTERN)
    end
    private_class_method :road_remediation_source?

    def self.sidewalk_tort_source?(text)
      text.match?(SIDEWALK_NUISANCE_PATTERN) && text.match?(SIDEWALK_TORT_SOURCE_PATTERN) &&
        !text.match?(MUNICIPAL_FINE_PATTERN)
    end
    private_class_method :sidewalk_tort_source?

    def self.source_text(source)
      # LegislationSearch uses article_text; jurisprudence adapters expose
      # abstract/summary/full_text. Keep all source bytes available to the
      # family classifier without mutating or normalizing the source record.
      %i[law_title title article_title article_text content abstract summary full_text].filter_map do |key|
        field(source, key)&.to_s
      end.join("\n")
    end
    private_class_method :source_text

    def self.selected_source?(source, question)
      return true if %i[pinned viewed selected explicit].any? { |key| truthy?(field(source, key)) }

      numac = field(source, :numac).to_s
      return true if !numac.empty? && question.downcase.include?(numac.downcase)

      article = field(source, :article_title).to_s
      number = article[%r{\A\s*art(?:ikel|icle)?\.?\s*([0-9]+(?:\.[0-9]+)*(?:/[0-9]+)?(?:bis|ter)?|[A-Z])\b}iu, 1]
      number && question.match?(%r{\b(?:art(?:ikel|icle)?|artikel)\.?\s*#{Regexp.escape(number)}(?![\w/.])}iu)
    end
    private_class_method :selected_source?

    def self.truthy?(value)
      value == true || %w[1 true yes on].include?(value.to_s.downcase)
    end
    private_class_method :truthy?

    def self.field(source, key)
      if source.respond_to?(:key?) && source.key?(key)
        source[key]
      elsif source.respond_to?(:key?) && source.key?(key.to_s)
        source[key.to_s]
      elsif source.respond_to?(key)
        source.public_send(key)
      end
    end
    private_class_method :field
  end
end
