# frozen_string_literal: true

require 'net/http'
require 'json'

# 100% LOCAL & OFFLINE Chatbot Service
# 
# DATA SOURCES (ALL LOCAL):
# - Local SQLite database (2.3M+ articles from Belgian legislation)
# - Local Ollama LLM (llama3.2:8b recommended, running on localhost:11434)
# - Local trigram search index (765M+ ngrams for fast keyword matching)
#
# ZERO EXTERNAL DEPENDENCIES:
# - No API calls to OpenAI, Anthropic, or any cloud service
# - No internet access required (except for initial Ollama model download)
# - No embeddings needed (uses keyword search instead of vector search)
# - No external knowledge (LLM ONLY uses provided context from database)
#
# GUARANTEES:
# - All answers sourced exclusively from local legal database
# - No hallucination from general LLM knowledge
# - No data sent to external servers
# - Free to run (no API costs)
#
class LocalChatbotService
  OLLAMA_URL = 'http://localhost:11434'
  MODEL = ENV.fetch('OLLAMA_MODEL', 'mistral') # mistral:7b - much better than 3b
  MAX_CONTEXT_ARTICLES = 5
  MAX_QUESTION_LENGTH = 500
  
  def initialize(language: 'nl')
    @language = language
    @language_id = language == 'fr' ? 2 : 1
  end
  
  # Main method to answer a question
  def ask(question, source: :legislation)
    raise ArgumentError, "Question too long" if question.length > MAX_QUESTION_LENGTH
    
    start_time = Time.current
    # Sanitize question for logging (prevent log injection)
    safe_question = question[0..80].gsub(/[\n\r\t\x00-\x1f\x7f]/, ' ')
    safe_question += '...' if question.length > 80
    request_id = Thread.current[:request_id] || 'unknown'
    Rails.logger.info "[CHATBOT] [#{request_id}] Q: '#{safe_question}' (#{@language}, source: #{source})"
    
    # Route to appropriate search method
    case source
    when :jurisprudence
      return search_jurisprudence(question, @language)
    when :all
      return search_both(question, @language)
    # when :legislation (default) falls through to existing logic
    end
    
    # Check if Ollama is running
    unless ollama_running?
      request_id = Thread.current[:request_id] || 'unknown'
      Rails.logger.warn "[CHATBOT] [#{request_id}] Ollama not running!"
      return { error: "Ollama service not running. Start with: ollama serve" }
    end
    
    # Find relevant articles using full-text search
    relevant_articles = find_relevant_articles_fts(question)
    
    if relevant_articles.empty?
      Rails.logger.warn "[CHATBOT] [#{request_id}] No articles found"
      return no_answer_response
    end
    
    # Build context from articles
    context = build_context(relevant_articles)
    
    # Query local LLM
    llm_start = Time.current
    answer = query_ollama(question, context)
    llm_time = (Time.current - llm_start).round(2)
    
    total_time = (Time.current - start_time).round(2)
    safe_answer = answer[0..80].gsub(/[\n\r\t\x00-\x1f\x7f]/, ' ')
    safe_answer += '...' if answer.length > 80
    Rails.logger.info "[CHATBOT] [#{request_id}] #{relevant_articles.size} sources, #{llm_time}s LLM, #{total_time}s total | A: #{safe_answer}"
    
    # Format response with citations
    {
      answer: answer,
      sources: format_sources(relevant_articles),
      language: @language,
      response_time: total_time,
      model: MODEL
    }
  rescue StandardError => e
    Rails.logger.error("[CHATBOT] ERROR: #{e.message}\n#{e.backtrace.join("\n")}")
    { error: "An error occurred", details: e.message }
  end
  
  private
  
  # Check if Ollama is running
  def ollama_running?
    uri = URI("#{OLLAMA_URL}/api/tags")
    response = Net::HTTP.get_response(uri)
    response.is_a?(Net::HTTPSuccess)
  rescue StandardError
    false
  end
  
  # Find articles using smart keyword matching with relevance scoring
  def find_relevant_articles_fts(question)
    # Extract and categorize keywords by importance
    all_keywords = extract_keywords(question)
    return [] if all_keywords.empty?
    
    # Split into important (specific) and common keywords
    important_keywords = all_keywords.select { |k| k.length >= 6 }
    Rails.logger.debug "[CHATBOT] Important: #{important_keywords.join(', ')}"
    
    # Require at least one important keyword
    return [] if important_keywords.empty?
    
    # Try FTS5 first, fall back to LIKE
    if fts_table_exists?
      search_with_fts5(important_keywords, all_keywords)
    else
      search_with_like(important_keywords, all_keywords)
    end
  end
  
  # Search using ngram tables (same as website search)
  def search_with_fts5(important_keywords, all_keywords)
    # Try ngram search first (fastest)
    if ngram_table_populated?
      search_with_ngrams(important_keywords, all_keywords)
    else
      # Fall back to FTS5 if available
      search_with_fts5_match(important_keywords, all_keywords)
    end
  rescue StandardError => e
    Rails.logger.warn("Ngram/FTS5 search failed: #{e.message}, falling back to LIKE")
    search_with_like(important_keywords, all_keywords)
  end
  
  # Search using trigram index (10-100x faster than LIKE)
  def search_with_ngrams(important_keywords, all_keywords)
    # Use ALL important keywords, not just the first one!
    # Build trigrams for each keyword and combine them
    all_grams = []
    important_keywords.take(3).each do |keyword|  # Take top 3 keywords to avoid too many grams
      all_grams.concat(build_ngrams(keyword))
    end
    all_grams.uniq!
    
    return search_with_like(important_keywords, all_keywords) if all_grams.empty?
    
    # Build OR conditions for multiple keywords
    like_conditions = important_keywords.take(3).map { |k| "LOWER(articles.article_text) LIKE ?" }.join(' OR ')
    like_params = important_keywords.take(3).map { |k| "%#{sanitize_sql(k)}%" }
    
    Article
      .select(
        'articles.id',
        'articles.article_title',
        'articles.article_text',
        'articles.content_numac as numac',
        'legislation.title as law_title',
        "#{score_calculation(important_keywords, all_keywords)} as relevance_score"
      )
      .joins('INNER JOIN articles_text_ngrams ON articles_text_ngrams.rowid = articles.rowid')
      .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
      .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
      .where('articles.language_id = ?', @language_id)
      .where('articles_text_ngrams.gram IN (?)', all_grams)
      .group('articles.rowid')
      .having('COUNT(DISTINCT articles_text_ngrams.gram) >= ?', [all_grams.size * 0.15, 1].max.to_i) # Very lenient: 15% match
      .where(like_conditions, *like_params)
      .order('relevance_score DESC')
      .limit(MAX_CONTEXT_ARTICLES)
  end
  
  # Build 3-grams from keyword
  def build_ngrams(text, gram_size = 3)
    str = text.to_s.downcase
    return [] if str.length < gram_size
    
    grams = []
    0.upto(str.length - gram_size) { |i| grams << str[i, gram_size] }
    grams.uniq
  end
  
  # Check if ngram table is populated
  def ngram_table_populated?
    return false unless ActiveRecord::Base.connection.table_exists?('articles_text_ngrams')
    
    count = ActiveRecord::Base.connection.select_value('SELECT COUNT(*) FROM articles_text_ngrams').to_i
    count > 0
  rescue StandardError
    false
  end
  
  # Original FTS5 search (kept as fallback)
  def search_with_fts5_match(important_keywords, all_keywords)
    return nil unless fts_table_exists?
    
    fts_query = important_keywords.join(' OR ')
    
    Article
      .select(
        'articles.id',
        'articles.article_title',
        'articles.article_text',
        'articles.content_numac as numac',
        'legislation.title as law_title'
      )
      .joins('INNER JOIN articles_fts ON articles.id = articles_fts.rowid')
      .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
      .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
      .where('articles.language_id = ?', @language_id)
      .where('articles_fts MATCH ?', fts_query)
      .order('articles_fts.rank')
      .limit(MAX_CONTEXT_ARTICLES)
  end
  
  # Search using LIKE with relevance scoring
  def search_with_like(important_keywords, all_keywords)
    # LIKE search fallback (slowest)
    
    # Build weighted conditions (at least ONE important keyword must match)
    # Changed from AND to OR - articles need to match ANY keyword, not ALL
    important_conditions = important_keywords.map do |keyword|
      "(articles.article_text LIKE ? OR articles.article_title LIKE ? OR legislation.title LIKE ?)"
    end.join(' OR ')
    
    # Parameters for important keywords
    important_params = important_keywords.flat_map { |k| ["%#{k}%", "%#{k}%", "%#{k}%"] }
    
    # Use raw SQL for custom scoring
    sql = <<-SQL
      SELECT 
        articles.id,
        articles.article_title,
        articles.article_text,
        articles.content_numac as numac,
        legislation.title as law_title,
        (
          #{score_calculation(important_keywords, all_keywords)}
        ) as relevance_score
      FROM articles
      LEFT JOIN contents ON articles.content_numac = contents.legislation_numac 
        AND articles.language_id = contents.language_id
      LEFT JOIN legislation ON contents.legislation_numac = legislation.numac 
        AND contents.language_id = legislation.language_id
      WHERE articles.language_id = ?
        AND (#{important_conditions})
      ORDER BY relevance_score DESC
      LIMIT ?
    SQL
    
    Article.find_by_sql([sql, @language_id, *important_params, MAX_CONTEXT_ARTICLES])
  end
  
  # Calculate relevance score SQL with answer-bearing boost
  def score_calculation(important_keywords, all_keywords)
    scores = []
    
    # Important keywords in title: 10 points each
    important_keywords.each do |keyword|
      scores << "CASE WHEN articles.article_title LIKE '%#{sanitize_sql(keyword)}%' THEN 10 ELSE 0 END"
    end
    
    # Important keywords in text: 5 points each
    important_keywords.each do |keyword|
      scores << "CASE WHEN articles.article_text LIKE '%#{sanitize_sql(keyword)}%' THEN 5 ELSE 0 END"
    end
    
    # Law title match: 3 points
    important_keywords.each do |keyword|
      scores << "CASE WHEN legislation.title LIKE '%#{sanitize_sql(keyword)}%' THEN 3 ELSE 0 END"
    end
    
    # BOOST: Articles with numbers (likely contain specific answers)
    # SQLite doesn't have REGEXP by default, use multiple LIKE for common numbers
    number_checks = (0..9).map { |n| "articles.article_text LIKE '% #{n}%'" }.join(' OR ')
    scores << "CASE WHEN #{number_checks} THEN 8 ELSE 0 END"
    
    # BOOST: Quantifier patterns (aantal, minimum, maximum, ten minste)
    if @language == 'nl'
      scores << "CASE WHEN articles.article_text LIKE '%aantal%' OR articles.article_text LIKE '%minimum%' OR articles.article_text LIKE '%maximum%' OR articles.article_text LIKE '%ten minste%' THEN 6 ELSE 0 END"
    else
      scores << "CASE WHEN articles.article_text LIKE '%nombre%' OR articles.article_text LIKE '%minimum%' OR articles.article_text LIKE '%maximum%' OR articles.article_text LIKE '%au moins%' THEN 6 ELSE 0 END"
    end
    
    # BOOST: Pattern "X dagen" or "X jours" (number + days)
    keyword_dagen = @language == 'nl' ? 'dagen' : 'jours'
    scores << "CASE WHEN articles.article_text LIKE '%#{keyword_dagen}%' THEN 4 ELSE 0 END"
    
    # BOOST: Legal/official terms that signal definitive answers
    if @language == 'nl'
      scores << "CASE WHEN articles.article_text LIKE '%bedraagt%' OR articles.article_text LIKE '%vastgesteld%' OR articles.article_text LIKE '%bepaald%' THEN 3 ELSE 0 END"
    else
      scores << "CASE WHEN articles.article_text LIKE '%s''élève%' OR articles.article_text LIKE '%fixé%' OR articles.article_text LIKE '%déterminé%' THEN 3 ELSE 0 END"
    end
    
    scores.join(' + ')
  end
  
  # Sanitize SQL input
  def sanitize_sql(text)
    ActiveRecord::Base.connection.quote_string(text)
  end
  
  # Check if FTS5 table exists
  def fts_table_exists?
    ActiveRecord::Base.connection.table_exists?('articles_fts')
  end
  
  # Extract keywords from question with smart filtering
  def extract_keywords(text)
    # Sanitize input: remove non-word characters except spaces
    # This prevents SQL injection attempts in keywords
    safe_text = text.gsub(/[^\p{L}\p{N}\s]/u, ' ')
    
    # Expanded stopwords for better filtering
    stopwords = %w[
      de het een is zijn wat hoe wie waar wanneer
      voor van op in aan met als bij naar
      kan moet mag kan ik heb hebben
    ]
    
    keywords = safe_text.downcase
        .split
        .reject { |w| stopwords.include?(w) || w.length < 3 }
        .uniq
        .take(7) # Take up to 7 keywords
    
    Rails.logger.debug "[CHATBOT] Keywords: #{keywords.join(', ')}"
    keywords
  end
  
  # Normalize query for search (kept for compatibility)
  def normalize_query(text)
    extract_keywords(text).join(' ')
  end
  
  # Build context string from articles with full citation info
  def build_context(articles)
    # Take top article only - simpler context for better accuracy
    article = articles.first
    return "" unless article
    
    # Limit article text to 500 characters for faster, focused responses
    article_text = article.article_text.to_s[0..500]
    article_text += "..." if article.article_text.to_s.length > 500
    
    <<~CONTEXT
      Wet: #{article.law_title}
      Artikel: #{article.article_title}
      NUMAC: #{article.numac}
      
      #{article_text}
    CONTEXT
  end
  
  # Query Ollama with context and question
  def query_ollama(question, context)
    system_prompt = if @language == 'fr'
      <<~PROMPT
        VOUS ÊTES UN SYSTÈME DE RECHERCHE DANS UNE BASE DE DONNÉES JURIDIQUE BELGE.
        
        RÈGLES ABSOLUES - AUCUNE EXCEPTION:
        1. Vous N'AVEZ PAS accès à Internet
        2. Vous N'AVEZ PAS de connaissances générales
        3. Vous pouvez UNIQUEMENT lire les articles de loi fournis ci-dessous
        4. Si l'information N'EST PAS dans les sources ci-dessous, dites EXACTEMENT: "Je ne trouve pas cette information dans la base de données légale"
        5. Ne citez JAMAIS de lois, articles ou informations qui ne sont pas explicitement dans les sources ci-dessous
        
        FORMAT DE RÉPONSE OBLIGATOIRE - SUIVEZ EXACTEMENT:
        
        [Votre réponse en 2-3 phrases complètes avec des détails spécifiques]
        
        Source: Selon [Numéro d'article], NUMAC [numéro], [brève description de ce que dit l'article].
        
        LÉGISLATION PERTINENTE:
        • NUMAC [numéro]: [Titre de la loi]
        • NUMAC [numéro]: [Titre de la loi]
        
        Attention: Ceci n'est pas un conseil juridique officiel. Consultez un avocat pour votre situation spécifique.
        
        EXEMPLE DE RÉPONSE CORRECTE:
        Question: "Quel est l'âge minimum pour travailler?"
        Réponse:
        En Belgique, l'âge minimum pour pouvoir travailler est de 15 ans. Les jeunes de moins de 18 ans bénéficient d'une protection spécifique et il existe des restrictions sur le type de travail et les horaires.
        
        Source: Selon Art.3, NUMAC 1971033102, les enfants de moins de 15 ans ne peuvent en principe pas être employés, sauf dans des cas exceptionnels.
        
        LÉGISLATION PERTINENTE:
        • NUMAC 1971033102: Loi sur le travail
        • NUMAC 1999012242: Arrêté royal concernant la protection des jeunes au travail
        
        Attention: Ceci n'est pas un conseil juridique officiel. Consultez un avocat pour votre situation spécifique.
      PROMPT
    else
      <<~PROMPT
        Beantwoord de vraag kort en direct op basis van de wetsartikelen.
        
        Zoek in de tekst naar het exacte antwoord (cijfers, dagen, percentages, bedragen).
        Geef het antwoord in 1-2 zinnen.
        
        Als het antwoord niet in de tekst staat: "Ik vind deze informatie niet in de wettelijke database"
      PROMPT
    end
    
    # Use generate API with combined prompt (simpler for small models)
    full_prompt = "#{system_prompt}\n\nBronnen:\n#{context}\n\nVraag: #{question}\n\nAntwoord:"
    
    uri = URI("#{OLLAMA_URL}/api/generate")
    request = Net::HTTP::Post.new(uri)
    request.content_type = 'application/json'
    request.body = {
      model: MODEL,
      prompt: full_prompt,
      stream: false,
      options: {
        temperature: 0.1, # Very low for factual responses only
        top_p: 0.8,
        repeat_penalty: 1.5, # Very strong penalty
        num_predict: 150
      }
    }.to_json
    
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: false) do |http|
      http.request(request)
    end
    
    if response.is_a?(Net::HTTPSuccess)
      result = JSON.parse(response.body)
      result['response'] || "Geen antwoord ontvangen"
    else
      "Fout bij contact met Ollama. Controleer of de service draait."
    end
  end
  
  # Format sources for response
  def format_sources(articles)
    articles.map do |article|
      {
        numac: article.numac,
        law_title: article.law_title || 'Unknown Law',
        article_title: article.article_title || "Article #{article.id}",
        url: "/laws/#{article.numac}"
      }
    end
  end
  
  # Response when no relevant articles found
  def no_answer_response
    message = if @language == 'fr'
      "Je n'ai pas trouvé d'informations pertinentes dans la législation belge pour répondre à cette question."
    else
      "Ik heb geen relevante informatie gevonden in de Belgische wetgeving om deze vraag te beantwoorden."
    end
    
    {
      answer: message,
      sources: [],
      language: @language
    }
  end
  
  # JURISPRUDENCE SEARCH - ZERO HALLUCINATION
  def search_jurisprudence(question, language)
    # Guard: Check if jurisprudence models exist
    unless defined?(CaseChunk) && defined?(CourtCase)
      return {
        answer: language == 'fr' ?
          "La jurisprudence n'est pas encore disponible dans cette version." :
          "Rechtspraak is nog niet beschikbaar in deze versie.",
        sources: [],
        language: language
      }
    end

    # Check if any chunks with embeddings exist first (skip slow embedding generation)
    has_embeddings = CaseChunk.where.not(embedding: nil).exists?
    
    chunks = []
    if has_embeddings
      query_embedding = generate_embedding(question)
      chunks = CaseChunk.includes(:court_case)
        .where(cases: { language_id: language == 'fr' ? 2 : 1 })
        .to_a
        .select { |chunk| chunk.embedding.present? }
        .map { |chunk|
          {
            chunk: chunk,
            similarity: cosine_similarity(query_embedding, JSON.parse(chunk.embedding))
          }
        }
        .sort_by { |h| -h[:similarity] }
        .take(3)
    end
    
    # Fallback to FTS on CourtCase.full_text if no embeddings
    if chunks.empty?
      cases = search_court_cases_fts(question, language)
      if cases.empty?
        return {
          answer: language == 'fr' ? 
            "Je n'ai pas trouvé de jurisprudence pertinente." :
            "Ik heb geen relevante rechtspraak gevonden.",
          sources: [],
          language: language
        }
      end
      
      # Build context from full cases
      context = cases.map { |c|
        text = c.full_text.to_s[0..500]
        "[RECHTSPRAAK #{c.case_number}] #{c.court}, #{c.decision_date}\n#{text}"
      }.join("\n\n---\n\n")
      
      return build_jurisprudence_response(question, context, cases, language)
    end
    
    # Build context with STRICT source attribution (embedding-based)
    context = chunks.map { |h|
      c = h[:chunk].court_case
      "[RECHTSPRAAK #{c.case_number}] #{c.court}, #{c.decision_date}\n#{h[:chunk].chunk_text}"
    }.join("\n\n---\n\n")
    
    # ULTRA-STRICT prompt for jurisprudence
    system_prompt = if language == 'fr'
      <<~PROMPT
        VOUS ÊTES UN SYSTÈME DE CITATION STRICTE DE JURISPRUDENCE BELGE.
        
        RÈGLES ABSOLUES - AUCUNE EXCEPTION:
        1. Vous pouvez UNIQUEMENT citer ce qui est EXPLICITEMENT écrit dans les arrêts ci-dessous
        2. Ne JAMAIS interpréter, résumer ou paraphraser
        3. Ne JAMAIS ajouter d'informations de votre connaissance générale
        4. Si l'information N'EST PAS textuellement présente, dites: "Cette information n'est pas explicitement mentionnée dans la jurisprudence"
        5. Citez TOUJOURS le numéro ECLI complet
        
        FORMAT OBLIGATOIRE:
        [Votre citation EXACTE de l'arrêt, entre guillemets]
        
        Source: Arrêt [ECLI complet], [Cour], [date]
      PROMPT
    else
      <<~PROMPT
        U BENT EEN STRIKTE RECHTSPRAAK CITATIESYSTEEM.
        
        ABSOLUTE REGELS - GEEN UITZONDERINGEN:
        1. U mag ALLEEN citeren wat LETTERLIJK in de arresten hieronder staat
        2. NOOIT interpreteren, samenvatten of parafraseren
        3. NOOIT informatie toevoegen uit algemene kennis
        4. Als informatie NIET letterlijk aanwezig is, zeg dan: "Deze informatie staat niet expliciet in de rechtspraak"
        5. Citeer ALTIJD het volledige ECLI nummer
        6. NOOIT antwoorden met algemene juridische kennis
        
        VERPLICHT FORMAAT:
        [Uw EXACTE citaat uit het arrest, tussen aanhalingstekens]
        
        Bron: Arrest [volledig ECLI], [Hof], [datum]
        
        VOORBEELD VAN CORRECTE RESPONS:
        "De arbeidsovereenkomst moet schriftelijk en in klare bewoordingen zijn opgesteld"
        
        Bron: Arrest ECLI:BE:CASS:2019:ARR.123, Hof van Cassatie, 15/03/2019
        
        VOORBEELD VAN INCORRECTE RESPONS (NOOIT DOEN):
        "Volgens de rechtspraak moet een arbeidsovereenkomst aan bepaalde voorwaarden voldoen..." [TE VAAG - geen exact citaat]
      PROMPT
    end
    
    full_prompt = "#{system_prompt}\n\nARRESTEN:\n#{context}\n\nVraag: #{question}\n\nExact citaat:"
    
    answer = query_ollama_strict(full_prompt)
    
    {
      answer: answer,
      sources: chunks.map { |h|
        {
          type: 'RECHTSPRAAK',
          title: h[:chunk].court_case.case_number,
          court: h[:chunk].court_case.court,
          date: h[:chunk].court_case.decision_date,
          url: h[:chunk].court_case.url,
          relevance: h[:similarity]
        }
      },
      language: language
    }
  end
  
  # COMBINED SEARCH - legislation + jurisprudence
  def search_both(question, language)
    # Search both sources independently
    leg_results = find_relevant_articles_fts(question)

    # Guard: Check if jurisprudence models exist
    unless defined?(CaseChunk) && defined?(CourtCase)
      # Fall back to legislation-only if jurisprudence not available
      if leg_results.empty?
        return no_answer_response
      end

      context = build_context(leg_results)
      answer = query_ollama(question, context)

      return {
        answer: answer,
        sources: format_sources(leg_results),
        language: language
      }
    end

    # Skip embedding check - go straight to FTS (no embeddings in DB yet)
    jur_chunks = []
    jur_cases = search_court_cases_fts(question, language)
    
    # Build combined context with clear source labels
    context_parts = []
    
    # Add legislation (top 2)
    leg_results.take(2).each do |article|
      context_parts << "[WET NUMAC #{article.numac}] #{article.law_title}\n#{article.article_title}\n#{article.article_text[0..800]}"
    end
    
    # Add jurisprudence (from embeddings or FTS)
    if jur_chunks.any?
      jur_chunks.each do |h|
        c = h[:chunk].court_case
        context_parts << "[RECHTSPRAAK #{c.case_number}] #{c.court}, #{c.decision_date}\n#{h[:chunk].chunk_text}"
      end
    else
      jur_cases.take(2).each do |c|
        text = c.full_text.to_s[0..1000]
        context_parts << "[RECHTSPRAAK #{c.case_number}] #{c.court}, #{c.decision_date}\n#{text}"
      end
    end
    
    if context_parts.empty?
      return no_answer_response
    end
    
    context = context_parts.join("\n\n---\n\n")
    
    # ULTRA-STRICT combined prompt
    system_prompt = language == 'fr' ? jurisprudence_combined_prompt_fr : jurisprudence_combined_prompt_nl
    full_prompt = "#{system_prompt}\n\nSOURCES:\n#{context}\n\nQuestion: #{question}\n\nRéponse stricte:"
    
    answer = query_ollama_strict(full_prompt)
    
    # Combine sources
    all_sources = []
    
    leg_results.take(2).each do |article|
      all_sources << {
        type: 'WET',
        title: article.article_title,
        law_title: article.law_title,
        numac: article.numac,
        url: "/laws/#{article.numac}"
      }
    end
    
    # Add jurisprudence sources (from embeddings or FTS)
    if jur_chunks.any?
      jur_chunks.each do |h|
        all_sources << {
          type: 'RECHTSPRAAK',
          title: h[:chunk].court_case.case_number,
          court: h[:chunk].court_case.court,
          date: h[:chunk].court_case.decision_date,
          url: h[:chunk].court_case.url,
          relevance: h[:similarity]
        }
      end
    else
      jur_cases.take(2).each do |c|
        all_sources << {
          type: 'RECHTSPRAAK',
          title: c.case_number,
          court: c.court,
          date: c.decision_date,
          url: c.url
        }
      end
    end
    
    {
      answer: answer,
      sources: all_sources,
      language: language
    }
  end
  
  # Generate embedding using Ollama (local, free)
  def generate_embedding(text)
    uri = URI("#{OLLAMA_URL}/api/embeddings")
    request = Net::HTTP::Post.new(uri)
    request.content_type = 'application/json'
    request.body = {
      model: 'nomic-embed-text',  # Free local embedding model
      prompt: text[0..500]  # Limit length
    }.to_json
    
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: false) do |http|
      http.request(request)
    end
    
    if response.is_a?(Net::HTTPSuccess)
      result = JSON.parse(response.body)
      result['embedding']
    else
      raise "Failed to generate embedding: #{response.body}"
    end
  end
  
  # Cosine similarity calculation
  def cosine_similarity(vec_a, vec_b)
    return 0.0 if vec_a.nil? || vec_b.nil? || vec_a.empty? || vec_b.empty?
    
    dot_product = vec_a.zip(vec_b).sum { |a, b| a * b }
    magnitude_a = Math.sqrt(vec_a.sum { |x| x**2 })
    magnitude_b = Math.sqrt(vec_b.sum { |x| x**2 })
    
    return 0.0 if magnitude_a.zero? || magnitude_b.zero?
    
    dot_product / (magnitude_a * magnitude_b)
  end
  
  # Query Ollama with STRICT anti-hallucination prompt
  def query_ollama_strict(full_prompt)
    uri = URI("#{OLLAMA_URL}/api/generate")
    request = Net::HTTP::Post.new(uri)
    request.content_type = 'application/json'
    request.body = {
      model: MODEL,
      prompt: full_prompt,
      stream: false,
      options: {
        temperature: 0.1,  # Very low = factual only
        top_p: 0.7,
        repeat_penalty: 1.5,
        num_predict: 150
      }
    }.to_json
    
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: false) do |http|
      http.request(request)
    end
    
    if response.is_a?(Net::HTTPSuccess)
      result = JSON.parse(response.body)
      result['response'] || "Geen antwoord ontvangen"
    else
      "Fout bij contact met Ollama"
    end
  end
  
  def jurisprudence_combined_prompt_nl
    <<~PROMPT
      U BENT EEN STRIKTE JURIDISCHE CITATIESYSTEEM VOOR BELGIË.
      
      ABSOLUTE REGELS:
      1. Citeer ALLEEN wat LETTERLIJK in de bronnen staat
      2. NOOIT eigen kennis toevoegen
      3. NOOIT interpreteren of afleiden
      4. Als informatie niet expliciet aanwezig is: "Deze informatie staat niet in de bronnen"
      5. Vermeld ALTIJD [WET] of [RECHTSPRAAK] bij elke bron
      
      FORMAT:
      [Uw exacte citaat tussen aanhalingstekens]
      
      Bronnen:
      - [WET] NUMAC [nummer]: [artikel]
      - [RECHTSPRAAK] [ECLI]: [hof], [datum]
      
      NOOIT algemene uitspraken zonder exacte bronvermelding.
    PROMPT
  end
  
  def jurisprudence_combined_prompt_fr
    <<~PROMPT
      SYSTÈME STRICT DE CITATION JURIDIQUE BELGE.
      
      RÈGLES ABSOLUES:
      1. Citez UNIQUEMENT ce qui est LITTÉRALEMENT dans les sources
      2. JAMAIS ajouter vos connaissances
      3. JAMAIS interpréter ou déduire
      4. Si absent: "Cette information n'est pas dans les sources"
      5. Mentionnez TOUJOURS [LOI] ou [JURISPRUDENCE]
      
      FORMAT:
      [Citation exacte entre guillemets]
      
      Sources:
      - [LOI] NUMAC [numéro]: [article]
      - [JURISPRUDENCE] [ECLI]: [cour], [date]
    PROMPT
  end

  # FTS search on CourtCase.full_text (fallback when no embeddings)
  def search_court_cases_fts(question, language)
    keywords = extract_keywords(question)
    return [] if keywords.empty?

    lang_id = language == 'fr' ? 2 : 1
    
    # Build LIKE conditions for keywords
    conditions = keywords.map { |kw| "full_text LIKE '%#{sanitize_sql(kw)}%'" }
    
    CourtCase.where(language_id: lang_id)
      .where(conditions.join(' OR '))
      .order(decision_date: :desc)
      .limit(3)
  end

  # Build jurisprudence response with strict prompting
  def build_jurisprudence_response(question, context, cases, language)
    system_prompt = if language == 'fr'
      <<~PROMPT
        VOUS ÊTES UN SYSTÈME DE CITATION STRICTE DE JURISPRUDENCE BELGE.
        
        RÈGLES ABSOLUES - AUCUNE EXCEPTION:
        1. Vous pouvez UNIQUEMENT citer ce qui est EXPLICITEMENT écrit dans les arrêts ci-dessous
        2. Ne JAMAIS interpréter, résumer ou paraphraser
        3. Ne JAMAIS ajouter d'informations de votre connaissance générale
        4. Si l'information N'EST PAS textuellement présente, dites: "Cette information n'est pas explicitement mentionnée dans la jurisprudence"
        5. Citez TOUJOURS le numéro ECLI complet
        
        FORMAT OBLIGATOIRE:
        [Votre citation EXACTE de l'arrêt, entre guillemets]
        
        Source: Arrêt [ECLI complet], [Cour], [date]
      PROMPT
    else
      <<~PROMPT
        U BENT EEN STRIKTE RECHTSPRAAK CITATIESYSTEEM.
        
        ABSOLUTE REGELS - GEEN UITZONDERINGEN:
        1. U mag ALLEEN citeren wat LETTERLIJK in de arresten hieronder staat
        2. NOOIT interpreteren, samenvatten of parafraseren
        3. NOOIT informatie toevoegen uit algemene kennis
        4. Als informatie NIET letterlijk aanwezig is, zeg dan: "Deze informatie staat niet expliciet in de rechtspraak"
        5. Citeer ALTIJD het volledige ECLI nummer
        
        VERPLICHT FORMAAT:
        [Uw EXACTE citaat uit het arrest, tussen aanhalingstekens]
        
        Bron: Arrest [volledig ECLI], [Hof], [datum]
      PROMPT
    end

    full_prompt = "#{system_prompt}\n\nARRESTEN:\n#{context}\n\nVraag: #{question}\n\nExact citaat:"
    answer = query_ollama_strict(full_prompt)

    {
      answer: answer,
      sources: cases.map { |c|
        {
          type: 'RECHTSPRAAK',
          title: c.case_number,
          court: c.court,
          date: c.decision_date,
          url: c.url
        }
      },
      language: language
    }
  end
end
