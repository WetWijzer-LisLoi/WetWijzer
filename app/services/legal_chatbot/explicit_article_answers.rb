# frozen_string_literal: true

module LegalChatbot
  # What the answer does with an article the reader asked for by number (ExplicitArticleRequest), and with the
  # source list shown when the citation guard withholds an answer (Sol 2026-11-16 16:49:59Z).
  #
  # * An article that the corpus lookup does not find in a law it holds ("Citeer artikel 9999 van de Belgische
  #   Grondwet") gets a plain statement that the lookup did not find it, with a link to the law, instead of a withheld
  #   answer and unrelated links. It never says the article does not exist: a law row without a matching heading does
  #   not establish what an edition contains (Sol 18:15:39Z). Only when EVERY requested article is unfound, the law has
  #   articles in the corpus at all, and the question asks for nothing else (no other instrument's article, no article
  #   mention the parser cannot read); anything else goes the ordinary way, where the found articles are pinned.
  # * The withheld-answer source list keeps only sources that help with the question: for an explicit request the
  #   requested articles (else that law's articles, else none, which leaves the guard's own message); otherwise, when
  #   some sources are evidently relevant (pinned or governing rows, rows retrieval found close, rows sharing a topic
  #   word with the question), only those. When none is, the list stays as retrieved.
  # Citation verification itself is unchanged.
  module ExplicitArticleAnswers
    # Words that say nothing about a topic and occur in every question.
    FALLBACK_SIMILARITY_FLOOR = 0.6
    QUESTION_FILLER = %w[welke welk artikel artikelen artikels belgische belgisch belgique belge belgian geef geeft
                         graag kunnen kun mogen moet moeten wanneer waarom hoeveel waarbij uitsluitend directe
                         rechtstreekse bronlink link links zinnen eerste korte korte letterlijk citaat paragraaf
                         quels quelle quelles article articles donnez pouvez combien pourquoi lorsque which what
                         where when article articles please give short direct quote paragraph wetgeving
                         législation legislation bepaling bepalingen disposition dispositions provision provisions
                         gewone samen vatten regels regel gelden geldt situatie vraag vragen recht rechten mogelijk
                         toepassing toepasselijk toepasselijke geval gevallen kader situation règles règle applicable
                         applicables question rules apply applies situations hier deze dezelfde zaken].freeze

    private

    # [[numac, number], ...] of the explicit request, limited to laws the corpus holds (a 10-digit enterprise or phone
    # number is no NUMAC).
    def explicit_article_targets(question)
      @explicit_article_targets ||= {}
      @explicit_article_targets[question] ||= begin
        targets = ExplicitArticleRequest.targets(question)
        known = targets.map(&:first).uniq.select { |numac| ::Legislation.where(numac: numac).exists? }
        targets.select { |target| known.include?(target.first) }
      end
    end

    # The question also asks for an article of another instrument, names one the parser cannot read, or names an
    # instrument the corpus does not hold.
    def explicit_article_mixed_request?(question)
      analysis = ExplicitArticleRequest.analyze(question)
      analysis[:others].positive? || analysis[:targets].size > explicit_article_targets(question).size
    end

    # The sources that are requested articles, in the order the question asks for them.
    def explicit_article_exact_sources(targets, sources)
      targets.map { |numac, number| [numac, explicit_article_title_key(number)] }.uniq.flat_map do |pair|
        sources.select { |source| fallback_source_pair(source) == pair }
      end
    end

    # Words a pure lookup uses besides the article reference itself ("Citeer artikel 9999 van de Belgische Grondwet
    # woordelijk en geef de officiële bronlink"). Anything else is another question the shortcut must not discard
    # (Sol 19:02:40Z: "... en leg uit hoe het Grondwettelijk Hof is samengesteld").
    LOOKUP_WORDS = %w[citeer citeren geef geven zoek zoeken toon tonen wat zegt zeggen woordelijk letterlijk volledige
                      tekst bronlink link links officiële officiele directe rechtstreekse bron graag aub alsjeblieft
                      citez citer donnez donner montrez cherchez que dit disent texte complet intégral integral lien
                      officiel officielle source quote cite give show find what does say says full text official direct please belgische belgisch belge belgian numac van het de la le les des du der den
                      een dat die en et and of uit from in voor pour for zijn ses haar ihr zitiere gib zeige
                      wortlich wörtlich quelle offizielle].to_set.freeze

    # Words that ask for an explanation, a comparison, an application or a choice: more than the requested article.
    WIDER_QUESTION = /\b(?:leg|uitleg\p{L}*|toepass\p{L}*|toegepast|appliqu\p{L}*|apply|applies|applied|anwend\p{L}*|verklaar|vergelijk|waarom|hoe|wanneer|welke|expliqu\p{L}*|compar\p{L}*|pourquoi|comment|quand|quel\p{L}*|explain|compare|why|how|when|which|erkl[äa]r\p{L}*|warum|wie)\b/

    def explicit_article_lookup_only?(question)
      text = explicit_article_request_rest(question)
      return false if text.match?(WIDER_QUESTION)
      return false if text.count('?') > 1

      text.scan(/\p{L}{3,}/).reject { |word| LOOKUP_WORDS.include?(word) }.size <= 2
    end

    # The question without its article references, NUMACs and the names of the Constitution and the Convention.
    def explicit_article_request_rest(question)
      question.to_s.downcase.gsub(ExplicitArticleRequest::ARTICLE, ' ').gsub(ExplicitArticleRequest::NUMAC, ' ')
              .gsub(ExplicitArticleRequest::CONSTITUTION_NAME, ' ').gsub(ExplicitArticleRequest::ECHR_NAME, ' ')
    end

    # Words a bounded task on the requested text uses: summarise it, its first sentence, in plain words, a link to it.
    # A word outside these and LOOKUP_WORDS is another task ("en pas het toe op ongelijke pensioenrechten") that needs
    # more law than the requested article (Sol 2026-11-17 03:58:47Z).
    FOCUS_WORDS = %w[vat vatten samen samenvatting samenvatten uitsluitend enkel alleen eerste tweede derde laatste zin
                     zinnen lid leden gewone eenvoudige duidelijke taal woorden kort korte beknopt beknopte naar
                     résume résumez résumer résumé uniquement seulement première premier deuxième dernière phrase phrases
                     alinéa langage clair claire termes mots bref brève vers summarize summarise summary only just first
                     second last sentence sentences paragraph plain simple language words brief short nur ersten satz
                     einfacher einfachen sprache zusammen zusammenfassen fasse kurz the der die das].to_set.freeze

    # A clearly bounded task: no wider-question word, no word outside the lookup and focus vocabularies, and no
    # question of its own beside the article ("Vat artikel 10 van de Grondwet samen. Is dat discriminatie?" asks a
    # second question; Sol 2026-11-17 06:53:58Z).
    def explicit_article_bounded_task?(rest, question = nil)
      return false if rest.match?(WIDER_QUESTION) || rest.count('?') > 1
      return false if question && explicit_article_separate_question?(question)

      rest.scan(/\p{L}{3,}/).none? { |word| !LOOKUP_WORDS.include?(word) && !FOCUS_WORDS.include?(word) }
    end

    # A sentence ending in a question mark that names no article itself: a question of its own.
    def explicit_article_separate_question?(question)
      question.to_s.scan(/[^.?!]+\?/).any? { |sentence| !sentence.match?(ExplicitArticleRequest::ARTICLE) }
    end

    # The legislation rows an answer about requested articles keeps, or nil to keep retrieval as it is.
    #
    # When the question asks about articles of one named law by number ("Zoek de Belgische Grondwet (NUMAC
    # 1994021048), artikel 10. Vat uitsluitend de eerste zin samen"), and every one of them was retrieved, those
    # articles are the answer's whole subject: the context, the citation guard and the source cards keep them alone.
    # Unrelated retrieval hits (other articles of the law, VAT articles, unrelated decrees) gave the model articles to
    # cite wrongly, and the guard then withheld the answer (Sol 2026-11-16 20:17:26Z, Q2). Only a clearly bounded task
    # on the requested text qualifies (explicit_article_bounded_task?): a question that asks more (an explanation, a
    # comparison, an application to a situation, which rules apply), names another instrument, or whose article was
    # not found keeps ordinary retrieval.
    def explicit_article_focus_sources(question, sources)
      targets = explicit_article_targets(question)
      return nil if targets.empty? || explicit_article_mixed_request?(question)

      return nil unless explicit_article_bounded_task?(explicit_article_request_rest(question), question)

      pairs = targets.map { |numac, number| [numac, explicit_article_title_key(number)] }.uniq
      exact = explicit_article_exact_sources(targets, sources)
      return nil unless pairs.all? { |pair| exact.any? { |source| fallback_source_pair(source) == pair } }

      exact
    end

    def explicit_article_title_key(number)
      "art#{number.to_s.sub(/\A\s*art(?:ikel|icle)?\.?\s*/i, '')}".delete(' .').downcase
    end

    def explicit_article_exists?(numac, number)
      ::Article.where(content_numac: numac)
               .where("LOWER(REPLACE(REPLACE(article_title, ' ', ''), '.', '')) = ?", explicit_article_title_key(number))
               .exists?
    end

    def generic_deadline_clarification_response
      result = { answer: GenericDeadlineClarification.message(@language), sources: [], language: @language,
                 retrieval_status: 'clarification_needed' }
      result[:quality_evidence] = ChatbotQualityEvidence.skipped(retrieval_status: 'clarification_needed') if @include_quality_evidence
      result
    end

    # The plain answer for requested articles the lookup does not find in a held law, or nil.
    def missing_explicit_article_response(question)
      by_law = explicit_article_targets(question).group_by(&:first)
      return nil if by_law.empty? || explicit_article_mixed_request?(question) || !explicit_article_lookup_only?(question)
      return nil unless by_law.keys.all? { |numac| ::Article.where(content_numac: numac).exists? }

      missing = by_law.filter_map do |numac, pairs|
        numbers = pairs.map(&:last)
        absent = numbers.reject { |number| explicit_article_exists?(numac, number) }
        [numac, absent] if absent.size == numbers.size
      end
      return nil if missing.empty? || missing.size < by_law.size

      result = { answer: missing.map { |numac, numbers| missing_explicit_article_sentence(numac, numbers) }.join("\n\n"),
                 sources: [], language: @language, retrieval_status: 'explicit_article_missing' }
      result[:quality_evidence] = ChatbotQualityEvidence.skipped(retrieval_status: 'explicit_article_missing') if @include_quality_evidence
      result
    end

    MISSING_ARTICLE_CONJUNCTIONS = { 'fr' => ' et ', 'en' => ' and ', 'de' => ' und ' }.freeze

    def missing_explicit_article_sentence(numac, numbers)
      law = ::Legislation.where(numac: numac).order(Arel.sql("CASE WHEN language_id = #{@language_id.to_i} THEN 0 ELSE 1 END")).first
      # A stored title can end with a full stop ("De gecoördineerde Grondwet."); the sentence adds its own.
      title = (law&.short_title.presence || law&.display_title.presence || numac).to_s.strip.sub(/\.+\z/, '')
      list = numbers.join(MISSING_ARTICLE_CONJUNCTIONS.fetch(@language, ' en '))
      plural = numbers.size > 1
      link = "[#{title}](/laws/#{numac})"
      case @language
      when 'fr'
        "Je n'ai pas trouvé #{plural ? "d'articles #{list}" : "d'article #{list}"} dans le texte consolidé de #{title} " \
        "(NUMAC #{numac}) que contient WetWijzer. Il se peut que le numéro soit différent, que l'article ait été " \
        "renuméroté ou abrogé, ou qu'il manque dans cette version. Vérifiez le numéro d'article ; le texte complet : #{link}."
      when 'en'
        "I did not find #{plural ? 'Articles' : 'Article'} #{list} in the consolidated text of #{title} (NUMAC #{numac}) held " \
        'by WetWijzer. The number may differ, the article may have been renumbered or repealed, or it may be missing ' \
        "from this version. Please check the article number; the full text: #{link}."
      when 'de'
        "Ich habe #{plural ? 'die Artikel' : 'Artikel'} #{list} im konsolidierten Text von #{title} (NUMAC #{numac}) in " \
        'WetWijzer nicht gefunden. Die Nummer kann abweichen, der Artikel kann umnummeriert oder aufgehoben sein oder in ' \
        "dieser Fassung fehlen. Bitte prüfen Sie die Artikelnummer; der vollständige Text: #{link}."
      else
        "Ik vond #{plural ? 'artikelen' : 'artikel'} #{list} niet in de geconsolideerde tekst van #{title} " \
        "(NUMAC #{numac}) die WetWijzer bevat. Mogelijk is het nummer anders, werd het artikel hernummerd of opgeheven, " \
        "of ontbreekt het in deze versie. Controleer het artikelnummer; de volledige tekst: #{link}."
      end
    end

    # The sources the withheld-answer list may show for this question.
    def relevant_fallback_sources(question, sources)
      targets = explicit_article_targets(question)
      if targets.any?
        exact = explicit_article_exact_sources(targets, sources)
        numacs = targets.map(&:first)
        own = exact.presence || sources.select { |source| numacs.include?(source_field(source, :numac, 'numac').to_s) }
        return own unless explicit_article_mixed_request?(question)

        # A mixed request ("artikel 9999 van de Grondwet en artikel 10 EVRM") keeps the other instrument's sources:
        # the requested Belgian rows first, then the rest under the general rule below.
        others = sources.reject { |source| numacs.include?(source_field(source, :numac, 'numac').to_s) }
        other_keys = ExplicitArticleRequest.analyze(question)[:other_numbers].map { |number| explicit_article_title_key(number) }
        # The other instrument's requested article ("artikel 10 EVRM") stays by its number, with or without a
        # similarity score and whatever keyword hits compete with it (Sol 19:02:40Z).
        numbered = others.select { |source| other_keys.include?(explicit_article_title_key(source_field(source, :article_title, 'article_title'))) }
        # With the other request found by number, the remainder keeps only evidently relevant rows.
        rest = numbered + general_relevant_fallback_sources(question, others - numbered, keep_all: numbered.empty?)
        return own + rest
      end

      general_relevant_fallback_sources(question, sources)
    end

    def general_relevant_fallback_sources(question, sources, keep_all: true)
      terms = fallback_question_terms(question)
      relevant = sources.select do |source|
        source_field(source, :pinned, 'pinned') || source_field(source, :governing_group, 'governing_group') ||
          terms.empty? || fallback_source_similarity(source) >= FALLBACK_SIMILARITY_FLOOR ||
          fallback_source_mentions?(source, terms)
      end
      # Nothing evidently relevant: relevance cannot be judged here (real governing articles can share no word with
      # the question and carry no similarity), so the list stays as retrieved rather than going empty.
      return relevant unless keep_all

      relevant.presence || sources
    end

    def fallback_source_pair(source)
      [source_field(source, :numac, 'numac').to_s, explicit_article_title_key(source_field(source, :article_title, 'article_title'))]
    end

    # The question's topic words, cut to a 5-letter stem so "verwittigen" meets "verwittiging" and "opzegtermijn" meets
    # "opzegging".
    def fallback_question_terms(question)
      question.to_s.downcase.scan(/\p{L}{5,}/).reject { |word| QUESTION_FILLER.include?(word) }.map { |word| word[0, 5] }.uniq
    end

    # Retrieval's own similarity (0..1; pins carry 99.0): a source the search found close to the question helps with it
    # even when it shares no word with it.
    def fallback_source_similarity(source)
      source_field(source, :similarity, 'similarity').to_f
    end

    def fallback_source_mentions?(source, terms)
      text = [source_field(source, :law_title, 'law_title'), source_field(source, :title, 'title'),
              source_field(source, :article_title, 'article_title'),
              source_field(source, :article_text, 'article_text').to_s[0, 2000]].join(' ').downcase
      terms.any? { |term| text.include?(term) }
    end
  end
end
