# frozen_string_literal: true

module LegalChatbot
  # Income-tax advances can mention spouses, percentages and non-residents
  # without governing a foreign relative's inherited capital. This is a
  # subject-family boundary, not an age/NUMAC blacklist.
  module ForeignSuccessionTaxSourceScope
    ORDINARY_TAX_SUBJECT = Regexp.union(
      JurisprudenceSearch::INCOME_TAX_SUBJECT_PATTERN,
      /\b(?:vennootschapsbelasting\p{L}*|imp[oô]ts?\s+des\s+soci[ée]t[ée]s|corporate\s+(?:income\s+)?tax\p{L}*|Körperschaftsteuer\p{L}*)\b/iu
    ).freeze
    ADVANCE_PAYMENT_PATTERN = /\b(?:voorafbetal\p{L}*|versements?\s+anticip[ée]\p{L}*|advance\s+(?:income\s+)?tax\s+payments?|tax\s+prepay\p{L}*|Steuervorauszahl\p{L}*)\b/iu
    PROFESSIONAL_ACTOR_PATTERN = /\b(?:zelfstandig\p{L}*|ind[ée]pendant\p{L}*|self[-\s]employed|Selbst[äa]ndig\p{L}*)\b/iu
    REQUEST_PATTERN = /\b(?:vraag\p{L}*|bespreek|uitleg|leg|demande\p{L}*|explique\p{L}*|ask\p{L}*|explain\p{L}*|discuss\p{L}*|frage\p{L}*|erklär\p{L}*)\b/iu
    QUESTION_START_PATTERN = /(?:\A|[.!?;]\s*)\s*(?:wat|welk\p{L}*|hoe\p{L}*|moet\p{L}*|kan|is|geldt|quel\p{L}*|comment|doit|est|what|which|how|do|does|is|can|must|wer|was|welch\p{L}*|wie|muss|soll|ist|gilt)\b/iu
    INHERITANCE_TAX_SUBJECT = /\b(?:erfbelast\p{L}*|erf[-\s]+en\s+schenkbelast\p{L}*|successierecht\p{L}*|droits?\s+(?:de\s+)?succession|inheritance\s+tax\p{L}*|estate\s+tax\p{L}*|Erbschafts?steuer\p{L}*)\b/iu
    INHERITANCE_RULE_EVIDENCE = Regexp.union(
      ParliamentarySearch::INHERITANCE_TAX_CONNECTING_FACTOR_PATTERN,
      ParliamentarySearch::INHERITANCE_TAX_TARIFF_PATTERN,
      /\b\d{1,3}(?:[.,]\d+)?\s*(?:%|procent|pour\s*cent|percent|Prozent)/iu
    ).freeze

    def self.source_relevant?(article, question)
      question = question.to_s
      return true unless question.match?(LegislationSearch::FOREIGN_DECEASED_SUCCESSION_TAX_PATTERN)
      return true if selected_source?(article, question)
      return true unless ordinary_tax_source?(article)
      return true if requested_ordinary_tax_subject?(question)

      inheritance_tax_evidence?(field(article, :article_text).to_s)
    end

    def self.ordinary_tax_source?(article)
      title = (field(article, :law_title) || field(article, :title)).to_s
      return true if title.match?(ORDINARY_TAX_SUBJECT)

      # Only the opening's positively paired subject/procedure identifies an
      # otherwise unspecified source. An incidental income-tax comparison
      # somewhere in an inheritance-tax document must not exclude it.
      intro = field(article, :article_text).to_s.gsub(/[[:space:]]+/, ' ')[0, 1600]
      intro.match?(ORDINARY_TAX_SUBJECT) && intro.match?(ADVANCE_PAYMENT_PATTERN)
    end

    def self.requested_ordinary_tax_subject?(question)
      subject = ORDINARY_TAX_SUBJECT.source
      request = Regexp.union(REQUEST_PATTERN, QUESTION_START_PATTERN).source
      return true if question.match?(/(?:#{request})[^\n.!?;]{0,140}(?:#{subject})/iu)

      # A user may ask about professional advance payments without spelling
      # out "income tax". Bare payment or self-employment facts are not enough.
      advance = ADVANCE_PAYMENT_PATTERN.source
      actor = PROFESSIONAL_ACTOR_PATTERN.source
      question.match?(/(?:#{request})[^\n.!?;]{0,70}(?:#{advance})[^\n.!?;]{0,80}(?:#{actor})|(?:#{request})[^\n.!?;]{0,70}(?:#{actor})[^\n.!?;]{0,80}(?:#{advance})/iu)
    end

    def self.inheritance_tax_evidence?(body)
      text = body.gsub(/[[:space:]]+/, ' ').gsub(/(?<=\d)\.(?=\d)/, ',')
      return true if text.match?(ParliamentarySearch::INHERITANCE_TAX_COMPOUND_TARIFF_PATTERN)

      subject = INHERITANCE_TAX_SUBJECT.source
      evidence = INHERITANCE_RULE_EVIDENCE.source
      # A real inheritance-tax connecting factor or tariff must occur next to
      # its own tax subject in the same clause. An inheritance footnote and an
      # unrelated income-tax rate elsewhere in the circular cannot combine.
      text.match?(/(?:#{subject})[^.!?;]{0,200}(?:#{evidence})|(?:#{evidence})[^.!?;]{0,200}(?:#{subject})/iu)
    end

    def self.selected_source?(article, question)
      return true if field(article, :pinned)

      numac = field(article, :numac).to_s
      return true if numac.present? && question.downcase.include?(numac.downcase)

      number = field(article, :article_title).to_s[%r{\A\s*art(?:ikel|icle)?\.?\s*(\d+(?:\.\d+)*(?:/\d+)?(?:bis|ter)?|[A-Z])\b}iu, 1]
      number.present? && question.match?(%r{\b(?:art(?:ikel|icle)?|Artikel)\.?\s*#{Regexp.escape(number)}(?![\w/]|\.\d)}iu)
    end

    def self.field(article, key)
      article[key] || article[key.to_s]
    end
    private_class_method :ordinary_tax_source?, :requested_ordinary_tax_subject?, :inheritance_tax_evidence?, :selected_source?, :field
  end
end
