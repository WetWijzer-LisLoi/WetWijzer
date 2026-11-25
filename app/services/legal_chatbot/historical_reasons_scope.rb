# frozen_string_literal: true

module LegalChatbot
  # Sol 2026-11-24 06:57:43Z (live 1.1.97): "Waarom koos de Belgische wetgever in de Antidiscriminatiewet van 10 mei 2007
  # voor een gesloten lijst van discriminatiegronden? Welke redenen uit de parlementaire voorbereiding ...?" showed art. 7
  # of the Brussels joint decree and ordinance of 4 April 2024 twice (2024003443 and 2024003444, the same wording
  # published on 16 and 19 April 2024). An act made after the one whose reasons are asked cannot hold the reasons of the
  # earlier legislature. For a question about a legislator's reasons that names the date of the act concerned, a law
  # whose title dates it after that day leaves the sources, unless the question compares or names the law's year (Sol
  # 2026-11-24 07:27:49Z: a later authority the reader asks for stays), or asks something else in a clause of its own
  # (Sol 08:22:18Z: "... en wat bepaalt artikel 7 van het Brussels Wetboek inzake de gelijkheid?"); each record stays as
  # it is, and every other question keeps it.
  module HistoricalReasonsScope
    MONTHS = {
      'januari' => 1, 'februari' => 2, 'maart' => 3, 'april' => 4, 'mei' => 5, 'juni' => 6, 'juli' => 7, 'augustus' => 8,
      'september' => 9, 'oktober' => 10, 'november' => 11, 'december' => 12, 'janvier' => 1, 'février' => 2, 'fevrier' => 2,
      'mars' => 3, 'avril' => 4, 'mai' => 5, 'juin' => 6, 'juillet' => 7, 'août' => 8, 'aout' => 8, 'septembre' => 9,
      'octobre' => 10, 'novembre' => 11, 'décembre' => 12, 'decembre' => 12, 'januar' => 1, 'februar' => 2, 'märz' => 3,
      'dezember' => 12, 'january' => 1, 'february' => 2, 'march' => 3, 'may' => 5, 'june' => 6, 'july' => 7, 'august' => 8,
      'october' => 10
    }.freeze
    MONTH = MONTHS.keys.map { |month| Regexp.escape(month) }.join('|')
    # The legislator's reasons: why the legislator chose, or what the preparatory works say
    REASONS_QUESTION = /(?<![[:alnum:]])(?:waarom|pourquoi|warum|why|redenen|motieven|motifs|raisons|gr[üu]nde|reasons)(?![[:alnum:]])/iu
    LEGISLATOR = /(?<![[:alnum:]])(?:\p{L}*wetgever\p{L}*|decreetgever\p{L}*|ordonnantiegever\p{L}*|l[ée]gislateur\p{L}*|
                  gesetzgeber\p{L}*|legislat(?:or|ure)s?|parlementaire\s+voorbereiding|travaux\s+pr[ée]paratoires)(?![[:alnum:]])/iux
    # A comparison asks for the later act too: "hoe verhoudt die keuze zich tot ...", "par rapport au code", "im Vergleich"
    COMPARISON = /(?<![[:alnum:]])(?:vergelijk\p{L}*|verhoudt|verhouding\p{L}*|verschil\p{L}*|tegenover|compar\p{L}*|
                  par\s+rapport\s+(?:à|au|aux)|diff[ée]r\p{L}*|vergleich\p{L}*|unterschied\p{L}*|verh[äa]lt|versus)(?![[:alnum:]])/iux
    # A clause ends a sentence before a capital or the end ("nr. 41/2009" and "art. 3" end none), or joins a question word
    # with "en" / "et" / "und" / "and"; a clause of fewer than three words ("Graag kort.") is none
    SENTENCE_BREAK = /[.?!;]+(?=\s+\p{Lu}|\s*\z)/u
    CLAUSE_QUESTION_WORD = /(?:wat|hoe|welke?|waar\p{L}*|wanneer|wie|kan|kun\p{L}*|mag|moet|geldt|bepaalt|zegt|staat|que|qu['’]|
                             quel(?:le)?s?|comment|o[ùu]|quand|qui|peut|puis|peuvent|doit|dit|pr[ée]voit|was|welche[rsnm]?|kann|
                             muss|gilt|sagt|what|how|which|where|when|who|can|may|must|does|do|is|are)(?![[:alnum:]])/iux
    CONJUNCTION_BREAK = /,?\s+(?:en|et|und|and)\s+(?=(?:ook\s+|aussi\s+|auch\s+|also\s+)?#{CLAUSE_QUESTION_WORD.source})/iux
    # Sol 2026-11-24 13:50:41Z and 15:43:06Z: "Antwoord in het Nederlands." appended to the 41/2009 question undid the
    # cutoff, while "Schrijf daarnaast een toelichting op artikel 7 ..." asks for substance. A clause made only of words
    # about the answer's language or form (this closed list) is no clause on another subject.
    INSTRUCTION_WORDS = %w[
      antwoord antwoorden beantwoord answer reply réponds répondez répondre réponse antworte antworten schrijf write écris
      écrivez schreib schreibe graag gelieve svp alsjeblieft alstublieft please merci bitte s il vous te plaît plait in het
      en auf de la le les the a an een ook also aussi auch me mij moi mir nederlands frans duits engels français francais
      néerlandais neerlandais allemand anglais deutsch niederländisch französisch englisch english dutch french german
      kort korte korter beknopt bondig kurz kurze briefly brief bref brièvement court courte concise concisely taal langue
      sprache language puntsgewijs opsomming punten tabel bullets bullet points liste tableau tabelle stichpunkte table
      maximaal maximum max hoogstens minder dan woorden woord zinnen zin alinea alineas regels mots mot phrases words word
      sentences wörter wörtern sätze sätzen höchstens maximal
    ].to_set.freeze
    # Sol 2026-11-24 20:11:39Z: a length instruction such as "Antwoord in maximaal 100 woorden." is form, not substance
    # (numbers are no words here).
    # "van 10 mei 2007", "du 10 mai 2007", "vom 10. Mai 2007", "of 10 May 2007"
    NAMED_DATE = /(?<![[:alnum:]])(?:van|du|vom|of)\s+(\d{1,2})(?:er)?\.?\s+(#{MONTH})\s+((?:19|20)\d{2})(?!\d)/iu
    TITLE_DATE = /\A\s*(\d{1,2})(?:er)?\.?\s+(#{MONTH})\s+((?:17|18|19|20)\d{2})(?!\d)/iu

    module_function

    def source_relevant?(article, question)
      text = question.to_s
      return true unless text.match?(REASONS_QUESTION) && text.match?(LEGISLATOR)
      return true if text.match?(COMPARISON)
      return true unless reasons_only?(text)

      named = date(text.match(NAMED_DATE))
      return true unless named

      law = date(title(article).match(TITLE_DATE))
      return true if law.nil? || law <= named

      # A later act the question names by its year stays, as in a comparison; the year of a judgment number such as
      # 41/2009 names no act
      text.match?(%r{(?<![\d/])#{law.year}(?!\d)})
    end

    def reasons_only?(text)
      clauses = text.split(SENTENCE_BREAK).flat_map { |sentence| sentence.split(CONJUNCTION_BREAK) }
      clauses.select { |clause| clause.scan(/\p{L}+/).size >= 3 && !instruction?(clause) }
             .all? { |clause| clause.match?(REASONS_QUESTION) || clause.match?(LEGISLATOR) }
    end

    def instruction?(clause)
      words = clause.downcase.scan(/\p{L}+/)
      words.any? && words.all? { |word| INSTRUCTION_WORDS.include?(word) }
    end

    def date(match)
      return nil unless match

      month = MONTHS[match[2].downcase]
      month ? Date.new(match[3].to_i, month, match[1].to_i) : nil
    rescue Date::Error
      nil
    end

    def title(article)
      return '' unless article.is_a?(Hash)

      (article[:law_title] || article['law_title'] || article[:title] || article['title']).to_s
    end
    private_class_method :title
  end
end
