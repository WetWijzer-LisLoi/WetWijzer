# frozen_string_literal: true

module LegalChatbot
  # Sol 2026-11-27 06:39:23Z (live 1.1.114): two samples showed an article of a relevant law that answers another
  # question.
  # - #2534 "Kan ik ontslagen worden tijdens de proeftijd?": art. 63 of the employment contracts act (1978070303), on the
  #   arbitrary dismissal of a blue-collar worker hired for an indefinite term, "is unhelpful in this general probation
  #   answer and precedes the cited basis. Please fix this narrowly, cover the rendered cards, and preserve Art. 63 for an
  #   explicit arbitrary-dismissal or named-article question."
  # - #304 "Hoeveel werkloosheidsuitkering krijg ik na een arbeidsongeval?": "Of the six cards, three are off topic in this
  #   sample, verified by opening the articles: #2 decree 114bis (arts allowance), #4 Well-being Act 4 (workplace welfare
  #   measures), #6 Occupational Accidents Act 12 (survivor annuity)." "Please test both the answer evidence and final
  #   cards, retaining the specialist articles for questions that actually ask for them."
  # Read in the production corpus on 2026-11-27: art. 114bis of the unemployment decree (1991013192), the flat-rate
  # benefit of a worker whose right under the artists' chapter XII ended; art. 4 of the Well-being Act (1996012650), the
  # measures the King can impose for the workers' well-being; arts. 10 to 21 of the Occupational Accidents Act
  # (1971041001), the compensation when the victim dies (funeral costs, transport of the deceased, the annuities of the
  # spouse, children, parents, grandchildren, brothers and sisters, and from when they are due).
  # Under the question a rule names, its articles leave the cards unless the question raises their own subject or names
  # the article. Every other question is not judged here.
  module ArticleSubjectScope
    B = '(?<![[:alnum:]])'
    E = '(?![[:alnum:]])'
    ARBITRARY_DISMISSAL = /#{B}(?:willekeurig\p{L}*|kennelijk\s+onredelijk\p{L}*|abusi[fv]\p{L}*|manifestement\s+d[ée]raisonnable\p{L}*|
                           willk[üu]rlich\p{L}*|offensichtlich\s+unvern[üu]nftig\p{L}*|arbitrar\p{L}*|manifestly\s+unreasonable|
                           unfair\s+dismissal\p{L}*)#{E}/iux
    ARTISTS = /#{B}(?:\p{L}*kunstenaar\p{L}*|kunstwerk\p{L}*|artistiek\p{L}*|artiste\p{L}*|artistique\p{L}*|k[üu]nstler\p{L}*|
               artist\p{L}*)#{E}/iux
    # "sécurité sociale" and "soziale Sicherheit" are social security: only safety at work counts
    WELL_BEING = /#{B}(?:welzijn\p{L}*|preventie\p{L}*|\p{L}*veiligheid\p{L}*|bien-[êe]tre|pr[ée]vention\p{L}*|
                  s[ée]curit[ée]\s+(?:au|du)\s+travail|s[ée]curit[ée]\s+des\s+travailleurs|wohlbefinden|pr[äa]vention\p{L}*|
                  arbeitssicherheit|sicherheit\s+am\s+arbeitsplatz|well-?being|prevention|safety)#{E}/iux
    # Sol 2026-11-27 09:38:22Z: "Krijgt de echtgenoot van een werkloze na een dodelijk arbeidsongeval een rente?" lost
    # art. 12; a fatal accident is a death too
    DEATH = /#{B}(?:overlijd\p{L}*|overleden\p{L}*|nabestaand\p{L}*|weduw\p{L}*|wees|wezen|begrafenis\p{L}*|dodelijk\p{L}*|d[ée]c[èe]s|
             d[ée]c[ée]d\p{L}*|mortel\p{L}*|veu[fv]\p{L}*|orphelin\p{L}*|survivant\p{L}*|fun[ée]railles|tod|todes\p{L}*|t[öo]dlich\p{L}*|
             stirbt|gestorben|hinterblieben\p{L}*|witwe\p{L}*|waise\p{L}*|death|dies|died|deceased|fatal\p{L}*|survivor\p{L}*|widow\p{L}*|
             orphan\p{L}*|funeral\p{L}*)#{E}/iux
    # Sol 2026-11-27 09:38:22Z (#304 on live 1.1.115): arts. 25 (temporary worsening of a permanent incapacity after
    # reclassification) and 39 (the annual wage ceiling of the compensation and annuities) of the Occupational Accidents Act
    # "support neither the requested unemployment amount nor a statement about those specialist issues in this answer"; to
    # keep "when the question actually asks for accident compensation". Read in full in NL on 2026-11-27.
    # ("werkloosheidsvergoeding" is the unemployment benefit itself)
    ACCIDENT_COMPENSATION = /#{B}(?:(?!werkloosheids)\p{L}*vergoeding\p{L}*|rente|renten|basisloon|\p{L}*plafond\p{L}*|jaarloon|verergert|verergering\p{L}*|
                             revalidatie\p{L}*|indemnit[ée]\p{L}*|r[ée]mun[ée]ration\s+de\s+base|aggravation|r[ée]adaptation|
                             entsch[äa]digung\p{L}*|basislohn|jahreslohn|verschlimmer\p{L}*|compensation|annuit\p{L}*|base\s+wage|
                             ceiling|worsen\p{L}*|rehabilitation)#{E}/iux
    # question: the question the rule judges; articles: the article numbers it reads (nil: every article of the law);
    # subject: the words of a question that asks for the article
    RULES = [
      { question: -> { FocusedTopicSourceScope::EMPLOYMENT_TRIAL_PERIOD_PATTERN }, numac: '1978070303', articles: /\A63\z/,
        subject: ARBITRARY_DISMISSAL },
      { question: -> { LegislationSearch::ACCIDENT_UNEMPLOYMENT_PATTERN }, numac: '1991013192', articles: /\A114bis\z/,
        subject: ARTISTS },
      { question: -> { LegislationSearch::ACCIDENT_UNEMPLOYMENT_PATTERN }, numac: '1996012650', articles: nil,
        subject: WELL_BEING },
      { question: -> { LegislationSearch::ACCIDENT_UNEMPLOYMENT_PATTERN }, numac: '1971041001',
        articles: /\A(?:1\d|2[01])(?:bis|ter|quater)?\z/, subject: DEATH },
      { question: -> { LegislationSearch::ACCIDENT_UNEMPLOYMENT_PATTERN }, numac: '1971041001', articles: /\A(?:25|39)\z/,
        subject: ACCIDENT_COMPENSATION }
    ].freeze

    # Sol 2026-11-27 06:50:19Z (review of the draft): a number alone named the article in any act ("art. 4
    # Arbeidsongevallenwet" kept art. 4 of the Well-being Act), and "art. 114 bis" or "artikelen 61 en 63" named nothing.
    # The acts of the rules by the short name the answers use (CoreLawMappings::CORE_LAW_NUMACS) and by their titles in
    # the four languages; ExplicitArticleRequest reads the article references and ties each to its act.
    ACT_TITLES = {
      '1978070303' => 'wet\s+(?:van\s+3\s+juli\s+1978\s+)?betreffende\s+de\s+arbeidsovereenkomsten|loi\s+(?:du\s+3\s+juillet\s+1978\s+)?' \
                      'relative\s+aux\s+contrats\s+de\s+travail|arbeitsvertragsgesetz\p{L}*|employment\s+contracts\s+act',
      '1991013192' => 'werkloosheidsreglementering|arr[êe]t[ée]\s+royal\s+(?:du\s+25\s+novembre\s+1991\s+)?portant\s+r[ée]glementation\s+' \
                      'du\s+ch[ôo]mage|arbeitslosenregelung|unemployment\s+(?:decree|regulations?)',
      '1996012650' => 'wet\s+(?:van\s+4\s+augustus\s+1996\s+)?betreffende\s+het\s+welzijn\s+van\s+de\s+werknemers|loi\s+' \
                      '(?:du\s+4\s+ao[ûu]t\s+1996\s+)?relative\s+au\s+bien-[êe]tre\s+des\s+travailleurs|well-?being\s+(?:at\s+work\s+)?act',
      '1971041001' => 'wet\s+(?:van\s+10\s+april\s+1971\s+)?(?:op|betreffende)\s+de\s+arbeidsongevallen|loi\s+(?:du\s+10\s+avril\s+1971\s+)?' \
                      'sur\s+les\s+accidents\s+du\s+travail|arbeitsunfallgesetz\p{L}*|(?:occupational|industrial)\s+accidents\s+act'
    }.freeze
    ACTS = ACT_TITLES.to_h do |numac, titles|
      [numac, /#{B}(?:#{Regexp.escape(CoreLawMappings::CORE_LAW_NUMACS.fetch(numac))}|#{titles})#{E}/iux]
    end.freeze

    module_function

    def source_relevant?(article, question)
      return true unless article.is_a?(Hash)

      numac = (article[:numac] || article['numac']).to_s
      number = article_number(article)
      text = question.to_s
      RULES.none? do |rule|
        next false unless rule[:numac] == numac && (rule[:articles].nil? || number.match?(rule[:articles]))
        next false unless text.match?(rule[:question].call)

        !text.match?(rule[:subject]) && !named?(text, numac, number)
      end
    end

    # "Art. 114bis" and "Art.63" read as 114bis and 63
    def article_number(article)
      (article[:article_title] || article['article_title']).to_s.strip.sub(/\AArt(?:ikel|icle)?\.?[[:space:]]*/i, '').downcase
    end

    # The question names this article of this act: a reference ExplicitArticleRequest reads ("artikel 63", "art. 114 bis",
    # "artikelen 61 en 63") that its act phrase or the nearest named act ties to this act, or that names no act at all. A
    # reference tied to another act, or to an instrument that is not one of the rules' acts, names another article.
    def named?(text, numac, number)
      return false if number.empty?

      plain = text.gsub(/[[:space:]]+/, ' ')
      acts = act_mentions(plain)
      plain.to_enum(:scan, ExplicitArticleRequest::ARTICLE).any? do
        match = Regexp.last_match
        next false unless ExplicitArticleRequest.numbers(match[1]).map(&:downcase).include?(number)

        owner = ExplicitArticleRequest.governing(acts, plain, match.end(0)) ||
                ExplicitArticleRequest.nearest(acts, match.begin(0), match.end(0))
        owner.nil? || owner[:numac] == numac
      end
    end

    # The instruments ExplicitArticleRequest finds (a NUMAC, the Constitution, any other act word) and the rules' acts.
    # An instrument it reads within a named act (the bare "loi" of "la loi relative aux contrats de travail", which starts
    # where that act does) gives way to that act; it is not left to the order of equal candidates.
    def act_mentions(text)
      acts = ACTS.flat_map do |numac, pattern|
        text.to_enum(:scan, pattern).map { { from: Regexp.last_match.begin(0), to: Regexp.last_match.end(0), numac: numac } }
      end
      others = ExplicitArticleRequest.instrument_mentions(text).reject do |mention|
        acts.any? { |act| mention[:from] < act[:to] && act[:from] < mention[:to] }
      end
      others + acts
    end
  end
end
