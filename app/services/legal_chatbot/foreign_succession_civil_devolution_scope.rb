# frozen_string_literal: true

module LegalChatbot
  # Civil kinship/devolution rules do not establish where a foreign deceased's
  # estate is taxable. Keep this positive family boundary independent of code
  # numbers: explicit civil questions can still use the same provisions.
  module ForeignSuccessionCivilDevolutionScope
    CIVIL_DEVOLUTION_HEADING = /
      \b(?:lijnen\s+en\s+graden|lignes\s+et\s+degr[ée]s|
          lines\s+and\s+degrees|Linien\s+und\s+Grade|
          wettelijke\s+erfopvolging|wettelijke\s+erfgenamen|erfopvolgingsorde\p{L}*|orden?\s+van\s+(?:de\s+)?erfgenamen|
          d[ée]volution\s+(?:l[ée]gale|successorale)|h[ée]ritiers?\s+l[ée]gaux|
          succession\s+ab\s+intestat|intestate\s+(?:succession|devolution)|
          legal\s+heirs?|gesetzliche\s+Erbfolge|gesetzliche\s+Erben|Erbordnung\p{L}*)\b
    /ixu
    CIVIL_LINE_PATTERN = /
      \b(?:erfopvolging\b[^\n.!?;]{0,70}\b(?:rechte\s+lijn|zijlijn)|
          succession\b[^\n.!?;]{0,70}\bligne\s+(?:directe|collat[ée]rale)|
          succession\b[^\n.!?;]{0,70}\b(?:direct|collateral)\s+line|
          Erbfolge\b[^\n.!?;]{0,70}\b(?:gerade\s+Linie|Seitenlinie))\b
    /ixu
    GENERATION_PATTERN = /\b(?:generatie\p{L}*|g[ée]n[ée]ration\p{L}*|generation\p{L}*)\b/iu
    DEGREE_PATTERN = /\b(?:graad|graden|degr[ée]s?|degrees?|Grade?n?)\b/iu

    CIVIL_TOPIC_PATTERN = /
      \b(?:verwantschapsgraad|verwantschap|lijnen\s+en\s+graden|erfopvolgingsorde\p{L}*|orden?\s+van\s+(?:de\s+)?erfgenamen|
          wettelijke\s+erfopvolging|wettelijke\s+erfgenamen|plaatsvervulling|
          erfgenaamschap|recht\s+om\s+te\s+erven|zonder\s+testament|
          geen\s+testament|d[ée]volution\s+(?:l[ée]gale|successorale)|
          degr[ée]\s+de\s+parent[ée]|lignes\s+et\s+degr[ée]s|h[ée]ritiers?\s+l[ée]gaux|
          qualit[ée]\s+d['’]\s*h[ée]ritier|repr[ée]sentation\s+successorale|
          substitution\s+successorale|sans\s+testament|succession\s+ab\s+intestat|
          intestacy|intestate\s+succession|(?:kinship|relationship)\s+degree|
          degree\s+of\s+kinship|lines\s+and\s+degrees|heir\s+qualification|
          legal\s+heirs?|right\s+to\s+inherit|without\s+a\s+will|no\s+will|
          substitution\s+(?:of\s+(?:an?\s+)?heirs?|in\s+(?:the\s+)?(?:succession|inheritance))|
          (?:heir|inheritance|succession)\s+substitution|right\s+of\s+representation|
          Verwandtschaftsgrad\p{L}*|Linien\s+und\s+Grade|
          gesetzliche\s+Erbfolge|gesetzliche\s+Erben|Erbordnung\p{L}*|
          Erbberechtigung|Eintrittsrecht|ohne\s+Testament)\b
    /ixu
    REQUEST_PATTERN = /\b(?:vraag\p{L}*|bespreek|verklaar|toelicht\p{L}*|uitleg|leg|demande\p{L}*|explique\p{L}*|examine\p{L}*|ask\p{L}*|explain\p{L}*|discuss\p{L}*|clarify|frage\p{L}*|erklär\p{L}*|erläuter\p{L}*)\b/iu
    DEGREE_QUESTION_PATTERN = /
      \b(?:welke?|quel(?:le)?|which|welcher?)\s+(?:verwantschaps)?(?:graad|lijn|degr[ée]|ligne|degree|line|Verwandtschaftsgrad|Grad|Linie)\b|
      \b(?:wat|what|was)\s+(?:is|are|ist|sind)\s+(?:(?:de|het|onze|mijn|the|our|my|der|die|das|unser\p{L}*)\s+){0,2}
        (?:graad|verwantschapsgraad|lijn|degree|kinship\s+degree|line|Verwandtschaftsgrad|Grad|Linie)\b|
      \b(?:hoe|comment|how|wie)\b[^\n.!?;]{0,40}\b
        (?:bereken\p{L}*|bepaal\p{L}*|bepaald|tellen|calcul\p{L}*|d[ée]termin\p{L}*|calculate|determine|count|berechn\p{L}*|ermittel\p{L}*)\b
        [^\n.!?;]{0,60}\b(?:graad|graden|verwantschapsgraad|degr[ée]s?|degrees?|Verwandtschaftsgrad|Grade?n?)\b
    /ixu
    HEIR_QUESTION_PATTERN = /
      \b(?:wie|who|qui|wer)\s+(?:(?:mag|kan|zal|gaat|can|may|will|kann|darf)\s+)?
        (?:erven|erft|erfgenaam|inherits?|qualifies\s+as\s+(?:an?\s+)?heir|h[ée]rite\p{L}*|erbt|erben)\b|
      (?:\A|[.!?;]\s*)\s*(?:kan|kunnen|mag|mogen|can|could|may|kann|können|darf|dürfen|peut|peuvent)
        \b[^\n.!?;]{0,80}\b(?:erven|erfgenaam\p{L}*|inherit\p{L}*|heir|h[ée]riter|h[ée]ritier\p{L}*|erben|Erbe)\b|
      (?:\A|[.!?;]\s*)\s*(?:heeft|hebben|has|have|hat|haben)\b[^\n.!?;]{0,60}
        \b(?:recht\s+(?:om\s+te\s+erven|op\s+de\s+nalatenschap)|right\s+to\s+inherit|Erbberechtigung)\b|
      \b(?:wat\s+gebeurt|what\s+happens|que\s+se\s+passe|was\s+geschieht)\b
        [^\n.!?;]{0,80}\b(?:zonder\s+testament|geen\s+testament|without\s+a\s+will|no\s+will|sans\s+testament|ohne\s+Testament)\b
    /ixu
    CIVIL_LAW_QUESTION_PATTERN = /
      \b(?:welk\s+erfrecht|quel\s+droit\s+successoral|which\s+(?:civil\s+)?succession\s+law|welches\s+Erbrecht)\b|
      (?:\A|[.!?;]\s*)\s*(?:is|geldt|est|does|ist|gilt)\b[^\n.!?;]{0,70}
        \b(?:erfrecht|droit\s+successoral|civil\s+succession\s+law|Erbrecht)\b
        [^\n.!?;]{0,45}\b(?:van\s+toepassing|geldt|applicable|appl\p{L}*|anwendbar|gilt)\b
    /ixu

    def self.source_relevant?(article, question)
      question = question.to_s
      return true unless question.match?(LegislationSearch::FOREIGN_DECEASED_SUCCESSION_TAX_PATTERN)
      return true if selected_source?(article, question)
      return true unless civil_devolution_source?(article)

      civil_devolution_question?(question)
    end

    def self.civil_devolution_source?(article)
      title = field(article, :law_title) || field(article, :title)
      # A tax statute may itself classify relatives. Do not confuse those
      # provisions with civil heir eligibility merely because terms overlap.
      return false if title.to_s.match?(LegislationSearch::SUCCESSION_TAX_SOURCE_SUBJECT_PATTERN)

      body = field(article, :article_text).to_s
      heading = [field(article, :article_title), body.lines.first(2).join].compact.join(' ')
      heading.match?(CIVIL_DEVOLUTION_HEADING) ||
        (body.match?(CIVIL_LINE_PATTERN) && body.match?(GENERATION_PATTERN) && body.match?(DEGREE_PATTERN))
    end

    def self.civil_devolution_question?(question)
      return true if question.match?(DEGREE_QUESTION_PATTERN) || question.match?(HEIR_QUESTION_PATTERN) ||
                     question.match?(CIVIL_LAW_QUESTION_PATTERN)

      request = REQUEST_PATTERN.source
      topic = CIVIL_TOPIC_PATTERN.source
      question.match?(/(?:#{request})[^\n.!?;]{0,100}(?:#{topic})/ixu)
    end

    def self.selected_source?(article, question)
      return true if field(article, :pinned)

      numac = field(article, :numac).to_s
      return true if numac.present? && question.downcase.include?(numac.downcase)

      number = field(article, :article_title).to_s[%r{\A\s*art(?:ikel|icle)?\.?\s*(\d+(?:\.\d+)*(?:/\d+)?(?:bis|ter)?)}iu, 1]
      number.present? && question.match?(%r{\b(?:art(?:ikel|icle)?|Artikel)\.?\s*#{Regexp.escape(number)}(?![\w/]|\.\d)}iu)
    end

    def self.field(article, key)
      article[key] || article[key.to_s]
    end
    private_class_method :civil_devolution_source?, :civil_devolution_question?, :selected_source?, :field
  end
end
