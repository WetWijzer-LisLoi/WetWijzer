# frozen_string_literal: true

require 'openai'
require 'net/http'
require 'json'

# Service class for AI-powered legal Q&A using RAG (Retrieval Augmented Generation)
# Uses Azure OpenAI for GDPR compliance and EU data residency
class LegalChatbotService
  EMBEDDING_MODEL = 'text-embedding-3-small'
  EMBEDDING_DIMENSIONS = 1536 # Must match worker_0.db (276K articles)
  CHAT_MODEL = 'gpt-4o-mini'
  MAX_CONTEXT_ARTICLES = 5
  
  # Popular/foundational Belgian laws - aligned with ApplicationHelper.popular_laws_lookup
  # These are prioritized over sector-specific CAOs in search results
  CORE_LAW_NUMACS = {
    # Oud Burgerlijk Wetboek (1804)
    '1804032150' => 'Oud BW Boek I - Personen',
    '1804032151' => 'Oud BW Boek II - Goederen/Eigendom',
    '1804032152' => 'Oud BW Boek III - Erfopvolging',
    '1804032153' => 'Oud BW Boek III - Schenkingen/Testamenten',
    '1804032154' => 'Oud BW Boek III - Verbintenissen/Contracten',
    '1804032155' => 'Oud BW Boek III - Bijzondere overeenkomsten',
    '1804032156' => 'Oud BW Boek III - Huwelijksvermogen',
    # Nieuw Burgerlijk Wetboek (2019-2022)
    '2022A32057' => 'Nieuw BW Boek 1 - Algemene bepalingen',
    '2020A20347' => 'Nieuw BW Boek 3 - Goederen',
    '2022A32058' => 'Nieuw BW Boek 5 - Verbintenissen',
    '2019A12168' => 'Nieuw BW Boek 8 - Bewijs',
    '2022A30600' => 'Nieuw BW Boek 2 - Relatievermogensrecht',
    # Huwelijksvermogen
    '1976071406' => 'Wet huwelijksvermogen',
    # Gerechtelijk Wetboek
    '1967101052' => 'Gerechtelijk Wetboek',
    # Criminal Law
    '1867060850' => 'Strafwetboek',
    '1808111701' => 'Wetboek van Strafvordering',
    '2010A09589' => 'Sociaal Strafwetboek',
    # Constitutional
    '1994021048' => 'Grondwet',
    # Labor & Social
    '1971031602' => 'Arbeidswet',
    '1978070303' => 'Arbeidsovereenkomstenwet',
    '1971062850' => 'Jaarlijkse vakantiewet',
    '1996012650' => 'Welzijnswet',
    '1963082803' => 'KB Klein verlet',
    # Corporate & Economic
    '2019A40586' => 'Wetboek van vennootschappen en verenigingen',
    '2013A11134' => 'Wetboek economisch recht',
    # Tax - Federal
    '1993082751' => 'WIB92 (KB uitvoering)',
    '1969070305' => 'BTW-Wetboek',
    # Tax - Regional
    '2013036154' => 'Vlaamse Codex Fiscaliteit',
    # Housing
    '2018015087' => 'Vlaams Woninghuurdecreet',
    '2013A31614' => 'Brusselse Huisvestingscode',
    '1951043003' => 'Handelshuurwet',
    # Other
    '1921022450' => 'Drugswet',
    '1980121550' => 'Vreemdelingenwet',
    '2007000528' => 'Camerawet',
  }.freeze
  
  # Keywords that trigger inclusion of specific core laws (NL + FR bilingual)
  # Maps question keywords to relevant foundational law NUMACs
  KEYWORD_TO_CORE_LAWS = {
    # Employment contracts (NL)
    'opzegtermijn' => ['1978070303'],
    'opzeg' => ['1978070303'],
    'ontslag' => ['1978070303', '2010A09589'],
    'arbeidsovereenkomst' => ['1978070303'],
    'concurrentiebeding' => ['1978070303'],
    'proefperiode' => ['1978070303'],
    'anciënniteit' => ['1978070303'],
    # Employment contracts (FR)
    'préavis' => ['1978070303'],
    'licenciement' => ['1978070303', '2010A09589'],
    'contrat de travail' => ['1978070303'],
    'non-concurrence' => ['1978070303'],
    'période d\'essai' => ['1978070303'],
    'ancienneté' => ['1978070303'],
    # Working time (NL)
    'werktijd' => ['1971031602'],
    'arbeidsduur' => ['1971031602'],
    'overuren' => ['1971031602'],
    'zondagsarbeid' => ['1971031602'],
    'nachtarbeid' => ['1971031602'],
    'rusttijd' => ['1971031602'],
    # Working time (FR)
    'temps de travail' => ['1971031602'],
    'durée du travail' => ['1971031602'],
    'heures supplémentaires' => ['1971031602'],
    'travail de nuit' => ['1971031602'],
    'travail du dimanche' => ['1971031602'],
    # Vacation & Leave (NL)
    'vakantie' => ['1971062850'],
    'vakantiedagen' => ['1971062850'],
    'verlof' => ['1971062850', '1963082803'],
    'klein verlet' => ['1963082803'],
    'rouwverlof' => ['1963082803'],
    # Vacation & Leave (FR)
    'congé' => ['1971062850', '1963082803'],
    'vacances' => ['1971062850'],
    'jours de congé' => ['1971062850'],
    'petit chômage' => ['1963082803'],
    'congé de deuil' => ['1963082803'],
    'décès' => ['1963082803'],
    # Workplace safety (NL + FR)
    'welzijn' => ['1996012650'],
    'veiligheid' => ['1996012650'],
    'veiligheidsmaatregelen' => ['1996012650'],
    'arbeidsongevallen' => ['1996012650'],
    'arbeidsongeval' => ['1996012650'],
    'preventie' => ['1996012650'],
    'risicoanalyse' => ['1996012650'],
    'bien-être' => ['1996012650'],
    'sécurité' => ['1996012650'],
    'accident du travail' => ['1996012650'],
    'prévention' => ['1996012650'],
    # Criminal law (NL)
    'straf' => ['1867060850'],
    'misdrijf' => ['1867060850'],
    'diefstal' => ['1867060850'],
    'huiszoeking' => ['1808111701'],
    'strafprocedure' => ['1808111701'],
    'aanhouding' => ['1808111701'],
    'voorhechtenis' => ['1808111701'],
    # Criminal law (FR)
    'peine' => ['1867060850'],
    'délit' => ['1867060850'],
    'vol' => ['1867060850'],
    'perquisition' => ['1808111701'],
    'procédure pénale' => ['1808111701'],
    'arrestation' => ['1808111701'],
    'détention' => ['1808111701'],
    # Civil law - Oud BW + Nieuw BW (NL)
    'contract' => ['1804032154', '2022A32058'],      # Verbintenissen
    'overeenkomst' => ['1804032154', '2022A32058'],  # Verbintenissen
    'verbintenis' => ['1804032154', '2022A32058'],   # Verbintenissen
    'eigendom' => ['1804032151', '2020A20347'],      # Goederen
    # Note: 'bezit' removed - too generic, conflicts with "bezit van drugs"
    'erfenis' => ['1804032152', '1804032153'],       # Erfopvolging
    'erfrecht' => ['1804032152', '1804032153'],      # Erfopvolging
    'erfopvolging' => ['1804032152', '1804032153'],  # Erfopvolging
    'testament' => ['1804032153'],                   # Schenkingen/Testamenten
    'schenking' => ['1804032153'],                   # Schenkingen/Testamenten
    'huwelijksvermogen' => ['1804032156', '1976071406', '2022A30600'],
    'echtscheiding' => ['1804032150', '2022A30600'],
    'samenwoning' => ['2022A30600'],                 # Relatievermogensrecht
    'bewijs' => ['2019A12168'],                      # Nieuw BW Boek 8
    # Civil law (FR)
    'contrat' => ['1804032154', '2022A32058'],
    'obligation' => ['1804032154', '2022A32058'],
    'propriété' => ['1804032151', '2020A20347'],
    'succession' => ['1804032152', '1804032153'],
    'héritage' => ['1804032152', '1804032153'],
    'donation' => ['1804032153'],
    'testament' => ['1804032153'],
    'régime matrimonial' => ['1804032156', '1976071406'],
    'divorce' => ['1804032150', '2022A30600'],
    'preuve' => ['2019A12168'],
    # Rental (NL)
    'huur' => ['2018015087', '2013A31614'],
    'verhuurder' => ['2018015087', '2013A31614'],
    'huurder' => ['2018015087', '2013A31614'],
    'huurwaarborg' => ['2018015087'],
    'handelshuur' => ['1951043003'],
    # Rental (FR)
    'locataire' => ['2018015087', '2013A31614'],
    'bailleur' => ['2018015087', '2013A31614'],
    'loyer' => ['2018015087', '2013A31614'],
    'garantie locative' => ['2018015087'],
    'bail' => ['2018015087', '2013A31614'],
    # Corporate (NL + FR)
    'vennootschap' => ['2019A40586'],
    'bestuurder' => ['2019A40586'],
    'aandeelhouder' => ['2019A40586'],
    'vzw' => ['2019A40586'],
    'société' => ['2019A40586'],
    'administrateur' => ['2019A40586'],
    'actionnaire' => ['2019A40586'],
    'asbl' => ['2019A40586'],
    # Drugs (NL + FR)
    'drugs' => ['1921022450'],
    'verdovende middelen' => ['1921022450'],
    'cannabis' => ['1921022450'],
    'cocaïne' => ['1921022450'],
    'heroïne' => ['1921022450'],
    'drugsbezit' => ['1921022450'],
    'stupéfiants' => ['1921022450'],
    'drogue' => ['1921022450'],
    'possession' => ['1921022450'],
    # Tax (NL + FR)
    'belasting' => ['1993082751', '2013036154'],
    'erfbelasting' => ['2013036154'],
    'schenkbelasting' => ['2013036154'],
    'onroerende voorheffing' => ['2013036154'],
    'btw' => ['1969070305'],
    'btw-tarief' => ['1969070305'],
    'inkomstenbelasting' => ['1993082751'],
    'personenbelasting' => ['1993082751'],
    'belastingaangifte' => ['1993082751'],
    'impôt' => ['1993082751', '2013036154'],
    'droits de succession' => ['2013036154'],
    'droits de donation' => ['2013036154'],
    'précompte immobilier' => ['2013036154'],
    'tva' => ['1969070305'],
    # Immigration (NL + FR)
    'verblijf' => ['1980121550'],
    'vreemdeling' => ['1980121550'],
    'nationaliteit' => ['1980121550'],
    'séjour' => ['1980121550'],
    'étranger' => ['1980121550'],
    'nationalité' => ['1980121550'],
    # Camera surveillance (NL + FR)
    'camera' => ['2007000528'],
    'bewakingscamera' => ['2007000528'],
    'camerabewaking' => ['2007000528'],
    'videobewaking' => ['2007000528'],
    'caméra' => ['2007000528'],
    'vidéosurveillance' => ['2007000528'],
    # Judicial / Procedural (NL + FR)
    'rechtszaak' => ['1967101052'],
    'procedure' => ['1967101052'],
    'dagvaarding' => ['1967101052'],
    'beroep' => ['1967101052'],
    'rechtbank' => ['1967101052'],
    'procès' => ['1967101052'],
    'tribunal' => ['1967101052'],
    'assignation' => ['1967101052'],
    'appel' => ['1967101052'],
    # Economic / Consumer (NL + FR)
    'consument' => ['2013A11134'],
    'garantie' => ['2013A11134'],
    'faillissement' => ['2013A11134'],
    'insolvabiliteit' => ['2013A11134'],
    'consommateur' => ['2013A11134'],
    'faillite' => ['2013A11134'],
    # Additional tax keywords
    'loonbelasting' => ['1993082751'],
    'aangifte' => ['1993082751'],
    'aftrek' => ['1993082751'],
    # Additional immigration
    'verblijfsvergunning' => ['1980121550'],
    'asiel' => ['1980121550'],
    'visum' => ['1980121550'],
    'uitwijzing' => ['1980121550'],
    'titre de séjour' => ['1980121550'],
    'asile' => ['1980121550'],
    'visa' => ['1980121550'],
    # Social criminal / zwartwerk
    'zwartwerk' => ['2010A09589'],
    'sociale fraude' => ['2010A09589'],
    'travail au noir' => ['2010A09589'],
    'fraude sociale' => ['2010A09589'],
  }.freeze
  
  # Boost factor for core laws (multiplied with similarity score)
  # Increased from 1.15 to 1.35 to better prioritize injected core laws
  CORE_LAW_BOOST = 1.35
  
  # Follow-up suggestions based on detected topics (NL + FR bilingual)
  FOLLOW_UP_SUGGESTIONS = {
    # Employment - NL
    'opzeg' => {
      nl: ['Wat is de opzegvergoeding bij ontslag?', 'Kan ik ontslagen worden tijdens ziekte?', 'Wat zijn mijn rechten bij collectief ontslag?'],
      fr: ['Quelle est l\'indemnité de préavis?', 'Puis-je être licencié pendant une maladie?', 'Quels sont mes droits en cas de licenciement collectif?']
    },
    'ontslag' => {
      nl: ['Hoe bereken ik mijn opzegtermijn?', 'Wat is ontslag om dringende reden?', 'Heb ik recht op werkloosheidsuitkering?'],
      fr: ['Comment calculer mon préavis?', 'Qu\'est-ce qu\'un licenciement pour motif grave?', 'Ai-je droit aux allocations de chômage?']
    },
    'vakantie' => {
      nl: ['Hoeveel vakantiegeld krijg ik?', 'Wat als ik ziek word tijdens vakantie?', 'Kan mijn werkgever mijn vakantie weigeren?'],
      fr: ['Combien de pécule de vacances vais-je recevoir?', 'Que se passe-t-il si je tombe malade pendant mes vacances?', 'Mon employeur peut-il refuser mes vacances?']
    },
    'verlof' => {
      nl: ['Hoeveel dagen klein verlet bij overlijden?', 'Wat is ouderschapsverlof?', 'Heb ik recht op tijdskrediet?'],
      fr: ['Combien de jours de petit chômage pour un décès?', 'Qu\'est-ce que le congé parental?', 'Ai-je droit au crédit-temps?']
    },
    'loon' => {
      nl: ['Wat is het minimumloon in België?', 'Wanneer moet mijn loon betaald worden?', 'Heb ik recht op een eindejaarspremie?'],
      fr: ['Quel est le salaire minimum en Belgique?', 'Quand mon salaire doit-il être payé?', 'Ai-je droit à une prime de fin d\'année?']
    },
    'arbeidsduur' => {
      nl: ['Hoeveel overuren mag ik werken?', 'Wat zijn de regels voor nachtarbeid?', 'Heb ik recht op rusttijden?'],
      fr: ['Combien d\'heures supplémentaires puis-je faire?', 'Quelles sont les règles du travail de nuit?', 'Ai-je droit à des temps de repos?']
    },
    # Employment - FR triggers
    'préavis' => {
      nl: ['Hoe bereken ik mijn opzegtermijn?', 'Wat is de opzegvergoeding?', 'Kan ik ontslagen worden tijdens ziekte?'],
      fr: ['Comment calculer mon préavis?', 'Quelle est l\'indemnité de préavis?', 'Puis-je être licencié pendant une maladie?']
    },
    'licenciement' => {
      nl: ['Wat is ontslag om dringende reden?', 'Heb ik recht op werkloosheidsuitkering?', 'Wat zijn mijn rechten bij collectief ontslag?'],
      fr: ['Qu\'est-ce qu\'un licenciement pour motif grave?', 'Ai-je droit aux allocations de chômage?', 'Quels sont mes droits en cas de licenciement collectif?']
    },
    'congé' => {
      nl: ['Hoeveel vakantiedagen heb ik?', 'Wat is ouderschapsverlof?', 'Hoeveel dagen klein verlet?'],
      fr: ['Combien de jours de congé ai-je?', 'Qu\'est-ce que le congé parental?', 'Combien de jours de petit chômage?']
    },
    # Rental
    'huur' => {
      nl: ['Wat is de maximale huurwaarborg?', 'Wanneer mag de verhuurder de huur verhogen?', 'Wat zijn mijn rechten bij verkoop van de woning?'],
      fr: ['Quel est le montant maximum de la garantie locative?', 'Quand le propriétaire peut-il augmenter le loyer?', 'Quels sont mes droits en cas de vente du bien?']
    },
    'locataire' => {
      nl: ['Wat is de maximale huurwaarborg?', 'Wanneer mag de verhuurder de huur verhogen?', 'Hoe kan ik mijn huurcontract opzeggen?'],
      fr: ['Quel est le montant maximum de la garantie locative?', 'Quand le propriétaire peut-il augmenter le loyer?', 'Comment résilier mon bail?']
    },
    'bail' => {
      nl: ['Wat is de opzegtermijn voor een huurcontract?', 'Wat zijn mijn rechten als huurder?', 'Wat is de maximale huurwaarborg?'],
      fr: ['Quel est le délai de préavis pour un bail?', 'Quels sont mes droits en tant que locataire?', 'Quel est le montant maximum de la garantie locative?']
    },
    # Criminal
    'straf' => {
      nl: ['Wat is het verschil tussen een misdrijf en een overtreding?', 'Wanneer verjaart een misdrijf?', 'Wat zijn mijn rechten bij een verhoor?'],
      fr: ['Quelle est la différence entre un délit et une contravention?', 'Quand un délit est-il prescrit?', 'Quels sont mes droits lors d\'un interrogatoire?']
    },
    'peine' => {
      nl: ['Wat is het verschil tussen een misdrijf en een overtreding?', 'Wanneer verjaart een misdrijf?', 'Wat zijn verzachtende omstandigheden?'],
      fr: ['Quelle est la différence entre un délit et une contravention?', 'Quand un délit est-il prescrit?', 'Que sont les circonstances atténuantes?']
    },
    'vol' => {
      nl: ['Wat is diefstal met verzwarende omstandigheden?', 'Wat is de straf voor heling?', 'Wanneer is er sprake van afpersing?'],
      fr: ['Qu\'est-ce que le vol avec circonstances aggravantes?', 'Quelle est la peine pour recel?', 'Quand parle-t-on d\'extorsion?']
    },
    # Family
    'echtscheiding' => {
      nl: ['Hoe wordt alimentatie berekend?', 'Wat gebeurt er met de kinderen bij echtscheiding?', 'Hoe wordt het vermogen verdeeld?'],
      fr: ['Comment la pension alimentaire est-elle calculée?', 'Que se passe-t-il avec les enfants lors d\'un divorce?', 'Comment le patrimoine est-il partagé?']
    },
    'divorce' => {
      nl: ['Hoe wordt alimentatie berekend?', 'Wat is echtscheiding door onderlinge toestemming?', 'Hoe wordt het vermogen verdeeld?'],
      fr: ['Comment la pension alimentaire est-elle calculée?', 'Qu\'est-ce que le divorce par consentement mutuel?', 'Comment le patrimoine est-il partagé?']
    },
    'erfenis' => {
      nl: ['Hoeveel erfbelasting moet ik betalen?', 'Wat zijn de rechten van de langstlevende?', 'Kan ik een erfenis weigeren?'],
      fr: ['Combien de droits de succession dois-je payer?', 'Quels sont les droits du conjoint survivant?', 'Puis-je refuser un héritage?']
    },
    'succession' => {
      nl: ['Hoeveel erfbelasting moet ik betalen?', 'Wat zijn de rechten van kinderen?', 'Kan ik een erfenis weigeren?'],
      fr: ['Combien de droits de succession dois-je payer?', 'Quels sont les droits des enfants?', 'Puis-je refuser un héritage?']
    },
    # Default suggestions for common topics
    '_default' => {
      nl: ['Waar kan ik juridisch advies krijgen?', 'Hoe start ik een gerechtelijke procedure?', 'Wat is pro deo rechtsbijstand?'],
      fr: ['Où puis-je obtenir des conseils juridiques?', 'Comment entamer une procédure judiciaire?', 'Qu\'est-ce que l\'aide juridique pro deo?']
    }
  }.freeze
  
  # Sample size for embedding similarity search (performance optimization)
  # Scanning all 276K embeddings takes ~10s, sampling 25K takes 1-2s
  # Trade-off: 10x faster, minimal quality loss (semantic clustering)
  EMBEDDING_SAMPLE_SIZE = 25_000
  MAX_QUESTION_LENGTH = 500
  
  # External embeddings database paths
  JURISPRUDENCE_EMBEDDINGS_DB = ENV.fetch('JURISPRUDENCE_EMBEDDINGS_DB', '/mnt/HC_Volume_103359050/embeddings/jurisprudence_embeddings.db')
  JURISPRUDENCE_SOURCE_DB = ENV.fetch('JURISPRUDENCE_SOURCE_DB', '/mnt/HC_Volume_103359050/embeddings/jurisprudence.db')
  LEGISLATION_EMBEDDINGS_DB = ENV.fetch('LEGISLATION_EMBEDDINGS_DB', '/mnt/HC_Volume_103359050/embeddings/legislation_embeddings.db')
  ARTICLE_EMBEDDINGS_DB = ENV.fetch('ARTICLE_EMBEDDINGS_DB', '/mnt/HC_Volume_103359050/embeddings/worker_0.db')
  
  def initialize(language: 'nl', conversation: nil)
    @language = language
    @language_id = language == 'fr' ? 2 : 1
    @conversation = conversation
    @context_numacs = conversation&.context_numacs_array || []
    @client = azure_client
    @juris_emb_db = nil
    @juris_source_db = nil
    @leg_emb_db = nil
    @article_emb_db = nil
  end
  
  private
  
  # Configure Azure OpenAI client for EU data residency (GDPR compliant)
  def azure_client
    endpoint = ENV['AZURE_OPENAI_ENDPOINT']
    return nil unless endpoint
    # Ensure endpoint ends with /openai for Azure API
    endpoint = endpoint.chomp('/') + '/openai' unless endpoint.include?('/openai')
    
    OpenAI::Client.new(
      access_token: ENV['AZURE_OPENAI_KEY'],
      uri_base: endpoint,
      api_type: :azure,
      api_version: ENV.fetch('AZURE_OPENAI_API_VERSION', '2024-02-15-preview')
    )
  end
  
  public
  
  # Main method to answer a question
  def ask(question, source: :all)
    start_time = Time.current
    
    # Timeout wrapper to prevent hanging requests
    Timeout.timeout(45) do
      ask_internal(question, source: source)
    end
  rescue Timeout::Error
    {
      answer: @language == 'fr' ? 
        "Désolé, la requête a pris trop de temps. Essayez une question plus simple." :
        "Sorry, de vraag duurde te lang. Probeer een eenvoudigere vraag.",
      sources: [],
      response_time: (Time.current - start_time).round(2),
      error: 'timeout'
    }
  end
  
  def ask_internal(question, source: :legislation)
    raise ArgumentError, "Question too long" if question.length > MAX_QUESTION_LENGTH
    
    start_time = Time.current
    
    # Route based on source selection:
    # - legislation: Fast (~20s), searches written law only
    # - jurisprudence: Fast (~20s), searches case law only
    # - all: Slow (~40s), searches both for comprehensive results
    result = case source
    when :jurisprudence
      search_jurisprudence(question)
    when :all
      search_both(question)
    else  # :legislation (default)
      search_legislation(question)
    end
    
    result[:response_time] = (Time.current - start_time).round(2)
    result
  rescue OpenAI::Error => e
    Rails.logger.error("Azure OpenAI API error: #{e.message}")
    { error: "Service temporarily unavailable", details: e.message }
  rescue StandardError => e
    Rails.logger.error("Chatbot error: #{e.message}\n#{e.backtrace.join("\n")}")
    { error: "An error occurred", details: e.message }
  end
  
  # Search legislation using hybrid approach: embeddings + keyword fallback
  # Proven to handle both semantic matches (vakantiedagen, zelfstandigen) 
  # and cases where embeddings fail (deeltijds, proeftijd)
  # 
  # For follow-up questions (when @context_numacs present), prioritizes
  # searching within previously mentioned laws for better context continuity
  def search_legislation(question, progress_callback: nil)
    Rails.logger.info("[Search] Searching LEGISLATION ONLY for: #{question}")
    
    # For follow-ups: expand vague questions with conversation context
    effective_question = expand_followup_question(question)
    if effective_question != question
      Rails.logger.info("[Search] Expanded follow-up: #{effective_question}")
    end
    
    # Step 1: Try embeddings first (5 sources for quality)
    question_embedding = generate_embedding(effective_question)
    similar_articles = find_similar_legislation(question_embedding, limit: 5, question: effective_question)
    
    # Step 2: For follow-ups with context, inject articles from previous NUMACs
    if @context_numacs.present? && is_followup_question?(question)
      Rails.logger.info("[Search] Follow-up detected, injecting context from: #{@context_numacs.join(', ')}")
      context_articles = inject_context_articles(@context_numacs, question.downcase)
      similar_articles = merge_search_results(context_articles, similar_articles)
    end
    
    # Step 3: If embeddings weak or no results, add keyword search
    if similar_articles.empty? || similar_articles.first[:similarity] < 0.40
      Rails.logger.info("[Search] Embedding weak (#{similar_articles.first&.dig(:similarity)&.round(3) || 'none'}) - threshold 0.40, adding keyword search")
      
      keywords = extract_keywords(effective_question)
      Rails.logger.info("[Search] Keywords: #{keywords.join(', ')}")
      
      keyword_articles = find_by_keywords(keywords, limit: 10)
      Rails.logger.info("[Search] Keyword search found #{keyword_articles.length} articles")
      
      # Merge results, removing duplicates
      similar_articles = merge_search_results(similar_articles, keyword_articles)
    end
    
    return no_answer_response if similar_articles.empty?
    
    Rails.logger.info("[Search] Final: #{similar_articles.length} articles, top similarity: #{similar_articles.first[:similarity].round(3)}")
    
    # Build context and query LLM
    context = build_legislation_context(similar_articles)
    
    # For follow-ups: add conversation history to LLM context
    if @conversation && @conversation.messages_array.length > 2
      conv_context = @conversation.conversation_context
      context = "#{conv_context}\n\n---\n\n#{context}" if conv_context
    end
    
    answer = query_llm(question, context, source_type: :legislation)
    
    # Generate follow-up suggestions based on question topic
    suggestions = generate_follow_up_suggestions(question)
    
    {
      answer: answer,
      sources: format_legislation_sources(similar_articles),
      suggestions: suggestions,
      language: @language
    }
  end
  
  # Detect if question is a vague follow-up that needs context
  def is_followup_question?(question)
    q = question.downcase.strip
    
    # Short questions are likely follow-ups
    return true if q.split.length <= 5
    
    # Dutch follow-up patterns
    nl_patterns = [
      /^(wat|welke|hoe|wanneer|waar|wie|waarom)\s+(zijn|is|moet|kan|mag)\s+(die|dat|deze|dit|ze|het)/i,
      /^(en|maar|of|dus)\s/i,
      /^(meer|verder|specifiek|detail)/i,
      /\b(die|dat|deze|dit|ervan|erbij|erover|hierover|daarover)\b/i,
      /^(leg uit|vertel meer|geef meer|kun je|kunt u)/i,
      /^(wat bedoel|wat betekent|wat houdt)/i,
      /\b(de regels|de wet|de voorwaarden|de procedure)\b/i
    ]
    
    # French follow-up patterns
    fr_patterns = [
      /^(qu'est-ce|quelles?|comment|quand|où|qui|pourquoi)\s+(sont|est|dois|peut|faut)\s+(ces?|cette?|cela|ça)/i,
      /^(et|mais|ou|donc)\s/i,
      /^(plus|encore|spécifiquement|en détail)/i,
      /\b(ces?|cette?|cela|ça|en|y|là-dessus)\b/i,
      /^(expliquez|dites-moi|donnez-moi|pouvez-vous)/i,
      /^(que signifie|qu'entendez|que veut dire)/i,
      /\b(les règles|la loi|les conditions|la procédure)\b/i
    ]
    
    (nl_patterns + fr_patterns).any? { |p| q.match?(p) }
  end
  
  # Expand vague follow-up questions with context from conversation
  def expand_followup_question(question)
    return question unless @conversation && is_followup_question?(question)
    
    # Get the topic from last question
    last_q = @conversation.last_question
    return question unless last_q.present?
    
    # Extract key topic words from last question
    topic_words = last_q.downcase.split(/\s+/).select { |w| w.length > 4 }
    return question if topic_words.empty?
    
    # Combine current question with topic context
    "#{question} (context: #{topic_words.first(5).join(' ')})"
  end
  
  # Inject articles from conversation context NUMACs
  def inject_context_articles(numacs, question_lower)
    keywords = question_lower.split(/\s+/).select { |w| w.length > 3 }
    
    injected = []
    numacs.first(3).each do |numac|
      articles = Article
        .select('articles.*, legislation.title as law_title, legislation.is_abolished')
        .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
        .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
        .where(content_numac: numac, language_id: @language_id)
        .limit(20)
      
      scored = articles.map do |article|
        text = "#{article.article_title} #{article.article_text}".downcase
        matches = keywords.count { |term| text.include?(term) }
        
        {
          id: article.id,
          numac: article.content_numac,
          law_title: article.law_title || 'Unknown',
          article_title: article.article_title,
          article_text: article.article_text,
          language_id: article.language_id,
          similarity: 0.80 + (matches * 0.02), # High base score for context
          is_abolished: article.try(:is_abolished) == 1
        }
      end
      
      injected.concat(scored.sort_by { |a| -a[:similarity] }.take(2))
    end
    
    Rails.logger.info("[Search] Injected #{injected.length} articles from conversation context")
    injected
  end
  
  # Generate follow-up suggestions based on detected keywords in question
  def generate_follow_up_suggestions(question)
    question_lower = question.downcase
    lang_key = @language == 'fr' ? :fr : :nl
    
    # Find matching topic based on keywords
    FOLLOW_UP_SUGGESTIONS.each do |keyword, suggestions|
      next if keyword == '_default'
      if question_lower.include?(keyword)
        return suggestions[lang_key]
      end
    end
    
    # Return default suggestions if no topic matched
    FOLLOW_UP_SUGGESTIONS['_default'][lang_key]
  end
  
  # Extract important keywords from question with legal term mappings
  def extract_keywords(question)
    # Expanded stop words to filter out
    stop_words = %w[wat is de het een op van voor met als in door bij hoe kan mag moet waar wanneer welke wie waarom hoeveel zijn mijn ik recht hebben rechten onder aan naar tot dit deze die dat jaar jaren]
    
    # Legal term mappings: user term → [search terms with synonyms]
    legal_terms = {
      # Employment & contracts
      /vakantiedagen|jaarlijks.*vakantie/i => ['vakantiedagen', 'jaarlijkse vakantie', 'wettelijke vakantie', 'verlof'],
      'ontslag' => ['ontslag', 'opzeg', 'beëindiging', 'ontslaan', 'opzegtermijn', 'opzegvergoeding'],
      'zelfstandig' => ['zelfstandig', 'zelfstandige', 'freelance', 'independent', 'schijnzelfstandigheid'],
      'deeltijd' => ['deeltijd', 'deeltijds', 'part-time', 'parttime'],
      'proef' => ['proef', 'proeftijd', 'proefperiode', 'trial period', 'testperiode'],
      'concurrentie' => ['concurrentiebeding', 'niet-concurrentiebeding', 'concurrentie', 'non-compete'],
      'arbeider' => ['arbeider', 'arbeiders', 'blue collar', 'handarbeider'],
      'bediende' => ['bediende', 'bedienden', 'white collar', 'kantoorwerk'],
      'loon' => ['loon', 'salaris', 'verloning', 'minimumloon', 'bezoldiging'],
      'overuren' => ['overuren', 'meeruren', 'extra uren', 'overtime'],
      /arbeidsovereenkomst|arbeidscontract|werkcontract/i => ['arbeidsovereenkomst', 'arbeidscontract', 'dienstverband', 'tewerkstelling'],
      /deeltijds.*werk|parttime/i => ['deeltijds', 'part-time', 'gedeeltelijke arbeid', 'halftijds'],
      /overuren|over.*uren|meeruren/i => ['overuren', 'meeruren', 'aanvullende prestaties', 'extra uren'],
      
      # Dismissal & termination
      /ontslag|afdanking/i => ['ontslag', 'afdanking', 'beëindiging', 'arbeidsbeëindiging'],
      /dringende.*reden|dringend.*ontslag/i => ['dringende reden', 'dringend ontslag', 'onmiddellijke beëindiging'],
      
      # Social security & contributions
      /zelfstandige|ondernemer/i => ['zelfstandige', 'zelfstandig ondernemer', 'vrij beroep'],
      /sociale.*bijdrage|rsz/i => ['sociale bijdragen', 'RSZ', 'socialezekerheidsbijdrage'],
      /werkloosheid|werkloosheidsuitkering/i => ['werkloosheid', 'werkloosheidsuitkering', 'werkloosheidsvergoeding'],
      
      # Wages & compensation
      /minimumloon|minimum.*loon/i => ['minimumloon', 'minimum loon', 'gewaarborgd loon'],
      /loon|salaris|bezoldiging/i => ['loon', 'salaris', 'bezoldiging', 'wedde'],
      /eindejaar.*premie|13.*maand/i => ['eindejaarspremie', '13de maand', 'dertiende maand'],
      
      # Leave & absences
      /ziekteverlof|ziek/i => ['ziekteverlof', 'ziekte', 'arbeidsongeschiktheid'],
      /zwangerschapsverlof|moederschaps/i => ['zwangerschapsverlof', 'moederschapsverlof', 'bevallingsrust'],
      
      # Discrimination & harassment
      /discriminatie|ongelijke.*behandeling/i => ['discriminatie', 'ongelijke behandeling', 'gelijke behandeling'],
      /pesten|pestgedrag|intimidatie|harassment/i => ['pestgedrag', 'pesten', 'intimidatie', 'psychosociale risicos'],
      
      # Work conditions
      /thuiswerk|telewerk|remote/i => ['thuiswerk', 'telewerk', 'thuiswerken', 'afstandswerk'],
      /arbeidsduur|werkuren|arbeidstijd/i => ['arbeidsduur', 'arbeidstijd', 'werkuren', 'arbeidstijdvermindering'],
      /concurrentiebeding|concurrentie/i => ['concurrentiebeding', 'niet-concurrentiebeding', 'concurrentieclausule'],
      
      # Specific cases
      /burnout/i => ['burnout', 'overspanning', 'psychische belasting', 'arbeidsongeval'],
    }
    
    # Find matching legal terms
    phrases = []
    legal_terms.each do |pattern, terms|
      if question =~ pattern
        phrases += terms
      end
    end
    
    # Extract meaningful words as fallback
    words = question.downcase.split(/\W+/)
    keywords = words.select { |w| w.length >= 4 && !stop_words.include?(w) }
    
    # Combine: prioritize legal terms, add keywords
    result = phrases.compact.uniq
    result += keywords.take(4) if result.length < 3
    result.uniq.take(8)  # Max 8 search terms
  end
  
  # Find articles by keyword search (fallback for poor embeddings)
  def find_by_keywords(keywords, limit: 5)
    return [] if keywords.empty?
    
    # Build sanitized LIKE conditions
    conditions = []
    params = []
    
    keywords.each do |kw|
      sanitized = kw.gsub("'", "''") # SQL escape
      conditions << "article_text LIKE ?"
      params << "%#{sanitized}%"
    end
    
    articles = Article.includes(:content)
                      .where(conditions.join(' OR '), *params)
                      .where(language_id: @language == 'fr' ? 2 : 1)
                      .limit(limit * 3)
    
    Rails.logger.info("Keyword search found #{articles.count} articles")
    
    # Convert to same format as embedding results
    articles.map do |article|
      next unless article.content
      {
        id: article.id,
        numac: article.content_numac,
        law_title: article.content.legislation&.title || article.content.title || 'Unknown',
        article_title: article.article_title,
        article_text: article.article_text,
        language_id: article.language_id,
        similarity: 0.75 # Higher than weak embeddings
      }
    end.compact.take(limit)
  end
  
  # GPT query expansion: Convert natural language to better search terms
  def expand_query_with_gpt(question)
    prompt = if @language == 'fr'
      "Tu es un expert en droit belge. Reformule cette question pour une recherche dans des textes juridiques.
Ajoute des synonymes et termes juridiques pertinents.
Garde la réponse courte (max 30 mots).

Question: #{question}

Recherche:"
    else
      "Je bent een expert in Belgisch recht. Herformuleer deze vraag als zoekopdracht voor juridische teksten.
Voeg relevante synoniemen en juridische termen toe.
Houd het antwoord kort (max 30 woorden).

Vraag: #{question}

Zoekopdracht:"
    end
    
    messages = [{ role: 'user', content: prompt }]
    
    begin
      expanded = azure_chat_completion(messages, temperature: 0.3, max_tokens: 100)
      expanded&.strip || question
    rescue => e
      Rails.logger.warn("[QueryExpansion] Failed: #{e.message}, using original")
      question
    end
  end
  
  # Rerank articles with embeddings (fast cosine similarity)
  def rerank_with_embeddings(articles, question_embedding)
    articles.map do |article|
      # Generate embedding for article text
      article_text = [article[:article_title], article[:article_text]].compact.join(": ")
      article_text = article_text[0..2000] # Limit for speed
      
      article_embedding = generate_embedding(article_text)
      similarity = cosine_similarity(question_embedding, article_embedding)
      
      article.merge(similarity: similarity)
    end.sort_by { |a| -a[:similarity] }
  rescue => e
    Rails.logger.warn("[EmbeddingRerank] Failed: #{e.message}, returning as-is")
    articles
  end
  
  # GPT-based relevance scoring (slow but accurate)
  def gpt_rerank_candidates(question, candidates, limit: 5)
    return candidates.take(limit) if candidates.length <= limit
    
    Rails.logger.info("[GPTRerank] Scoring #{candidates.length} candidates")
    
    # Score each candidate with GPT
    scored = candidates.map do |article|
      score = gpt_relevance_score(question, article[:article_text])
      [article, score]
    end
    
    # Sort by GPT score and take top N
    scored.sort_by { |_, score| -score }
           .take(limit)
           .map { |article, _| article }
  rescue => e
    Rails.logger.warn("[GPTRerank] Failed: #{e.message}, using embedding scores")
    candidates.take(limit)
  end
  
  # Score article relevance with GPT (0.0 - 1.0)
  def gpt_relevance_score(question, article_text)
    # Truncate article for speed
    snippet = article_text&.slice(0, 800) || ""
    
    prompt = if @language == 'fr'
      "Évalue la pertinence de cet article pour la question (score 0-10).
Réponds uniquement avec un nombre.

Question: #{question}

Article: #{snippet}

Score:"
    else
      "Beoordeel de relevantie van dit artikel voor de vraag (score 0-10).
Antwoord alleen met een getal.

Vraag: #{question}

Artikel: #{snippet}

Score:"
    end
    
    messages = [{ role: 'user', content: prompt }]
    
    begin
      response = azure_chat_completion(messages, temperature: 0.0, max_tokens: 10)
      score_str = response&.strip&.match(/\d+/)&.[](0)
      score = score_str ? score_str.to_f / 10.0 : 0.5
      score.clamp(0.0, 1.0)
    rescue => e
      Rails.logger.warn("[RelevanceScore] Failed: #{e.message}")
      0.5 # Default neutral score
    end
  end
  
  # Merge embedding and keyword results, removing duplicates
  def merge_search_results(embedding_results, keyword_results)
    seen_ids = Set.new
    merged = []
    
    # Add all results, tracking IDs to avoid duplicates
    (embedding_results + keyword_results).each do |result|
      next if seen_ids.include?(result[:id])
      seen_ids.add(result[:id])
      merged << result
    end
    
    # Sort by similarity and take top 5
    merged.sort_by { |r| -r[:similarity] }.take(5)
  end
  
  # ARTICLE-LEVEL RETRIEVAL: Direct search using article embeddings
  # Uses FAISS for fast exact search, falls back to sampling if unavailable
  # Now includes core law boosting to prioritize foundational laws over sector CAOs
  def find_similar_legislation(question_embedding, limit: 5, progress_callback: nil, question: nil)
    # Try FAISS service first (fast path - searches all 2.76M articles in <1s)
    # Request more results so we have room for boosting/reranking
    top_articles = find_similar_legislation_faiss(question_embedding, limit * 2)
    
    # Fallback to direct DB search if FAISS unavailable
    if top_articles.nil?
      Rails.logger.warn("FAISS service unavailable, falling back to sampled DB search")
      return find_similar_legislation_direct(question_embedding, limit)
    end
    
    # Apply core law boosting if question provided
    if question.present?
      top_articles = apply_core_law_boosting(top_articles, question)
    end
    
    # Return top N after boosting
    top_articles.take(limit)
  end
  
  # Apply boost to articles from core/foundational laws
  # This ensures general laws are prioritized over sector-specific CAOs
  def apply_core_law_boosting(articles, question)
    question_lower = question.downcase
    
    # Find which core laws are relevant based on keywords
    relevant_core_numacs = Set.new
    KEYWORD_TO_CORE_LAWS.each do |keyword, numacs|
      if question_lower.include?(keyword)
        numacs.each { |n| relevant_core_numacs.add(n) }
      end
    end
    
    # INJECTION: If core laws are relevant but missing from results, inject them
    if relevant_core_numacs.any?
      existing_numacs = articles.map { |a| a[:numac] }.to_set
      missing_numacs = relevant_core_numacs - existing_numacs
      
      if missing_numacs.any?
        injected = inject_core_law_articles(missing_numacs, question_lower)
        if injected.any?
          Rails.logger.info("Core law injection: Added #{injected.length} articles from #{missing_numacs.to_a.join(', ')}")
          articles = articles + injected
        end
      end
    end
    
    # Also always give a small boost to any core law
    boosted = articles.map do |article|
      numac = article[:numac]
      boost = 1.0
      
      if CORE_LAW_NUMACS.key?(numac)
        if relevant_core_numacs.include?(numac)
          # Strong boost for keyword-matched core laws
          boost = CORE_LAW_BOOST * 1.1
          Rails.logger.debug("Strong boost for #{CORE_LAW_NUMACS[numac]} (keyword match)")
        else
          # Mild boost for any core law
          boost = CORE_LAW_BOOST
        end
      end
      
      article.merge(similarity: article[:similarity] * boost, boosted: boost > 1.0)
    end
    
    # Re-sort by boosted similarity
    result = boosted.sort_by { |a| -a[:similarity] }
    
    # Log if boosting changed the order
    core_in_top5 = result.take(5).count { |a| a[:boosted] }
    if core_in_top5 > 0
      Rails.logger.info("Core law boosting: #{core_in_top5}/5 top results are from foundational laws")
    end
    
    result
  end
  
  # Inject articles from core laws that are missing from FAISS results
  # Uses keyword root matching to find relevant articles, with fallback to top articles
  def inject_core_law_articles(numacs, question_lower)
    # Extract key terms and their roots for matching
    keywords = question_lower.split(/\s+/).select { |w| w.length > 3 }
    roots = keywords.select { |w| w.length >= 6 }.map { |w| w[0, 5] }
    search_terms = (keywords + roots).uniq
    
    injected = []
    numacs.each do |numac|
      # Find articles from this core law (include is_abolished status and preamble)
      articles = Article
        .select('articles.*, legislation.title as law_title, legislation.date, legislation.is_abolished, contents.preamble')
        .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
        .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
        .where(content_numac: numac, language_id: @language_id)
        .limit(100)
      
      # Score articles by keyword/root matches in title/text
      scored = articles.map do |article|
        text = "#{article.article_title} #{article.article_text}".downcase
        matches = search_terms.count { |term| text.include?(term) }
        
        {
          id: article.id,
          numac: article.content_numac,
          law_title: article.law_title || CORE_LAW_NUMACS[numac] || 'Unknown',
          article_title: article.article_title,
          article_text: article.article_text,
          language_id: article.language_id,
          similarity: 0.70 + (matches * 0.03), # Base 0.70, up to 0.85 with matches
          injected: true,
          match_count: matches,
          is_abolished: article.try(:is_abolished) == 1,
          preamble: article.try(:preamble)
        }
      end
      
      # Sort by matches (desc), then take top 2
      # This ensures we always inject SOMETHING from the core law, even without keyword matches
      top_articles = scored.sort_by { |a| [-a[:match_count], -a[:similarity]] }.take(2)
      
      # Log what we're injecting
      if top_articles.any?
        match_info = top_articles.map { |a| "#{a[:article_title]}(#{a[:match_count]} matches)" }.join(', ')
        Rails.logger.info("Injecting from #{CORE_LAW_NUMACS[numac] || numac}: #{match_info}")
      end
      
      injected += top_articles
    end
    
    injected
  end
  
  # Call FAISS service for fast article similarity search
  def find_similar_legislation_faiss(question_embedding, limit)
    require 'net/http'
    require 'json'
    
    faiss_url = ENV.fetch('FAISS_ARTICLES_SERVICE_URL', 'http://127.0.0.1:8766')
    uri = URI("#{faiss_url}/search")
    
    request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
    request.body = { embedding: question_embedding, limit: limit }.to_json
    
    response = Net::HTTP.start(uri.hostname, uri.port, 
                                use_ssl: uri.scheme == 'https',
                                open_timeout: 5, read_timeout: 10) do |http|
      http.request(request)
    end
    
    if response.is_a?(Net::HTTPSuccess)
      data = JSON.parse(response.body)
      Rails.logger.info("FAISS article search completed in #{data['search_time_ms'].round(1)}ms (searched #{data['total_indexed']} articles)")
      
      # Fetch full article details from Rails DB
      article_ids = data['results'].map { |r| r['article_id'] }
      articles_by_id = Article
        .select('articles.*, legislation.title as law_title, legislation.date')
        .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
        .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
        .where(id: article_ids)
        .index_by(&:id)
      
      # Map results with similarity scores
      data['results'].map do |result|
        article = articles_by_id[result['article_id']]
        next unless article
        
        {
          id: article.id,
          numac: article.content_numac,
          law_title: article.law_title || 'Unknown',
          article_title: article.article_title,
          article_text: article.article_text,
          language_id: article.language_id,
          similarity: result['similarity']
        }
      end.compact.sort_by { |a| -a[:similarity] }
    else
      Rails.logger.error("FAISS article service error: #{response.code} #{response.message}")
      nil
    end
  rescue StandardError => e
    Rails.logger.debug("FAISS article service unavailable: #{e.message}")
    nil
  end
  
  # Direct database search (fallback when FAISS unavailable)
  # Samples 2% of articles for speed
  def find_similar_legislation_direct(question_embedding, limit: 5)
    emb_db = article_embeddings_db
    
    q_vec = question_embedding
    q_magnitude = Math.sqrt(q_vec.sum { |x| x * x })
    
    # Find top articles
    top_matches = []
    min_similarity = 0.0
    
    # Aggressive sampling for speed: 2% of records using modulo
    sample_modulo = 50  # id % 50 = 0 gives ~2% sample
    total_count = emb_db.get_first_value('SELECT COUNT(*) FROM article_embeddings')
    estimated_sample = total_count / sample_modulo
    Rails.logger.info("Sampling ~#{estimated_sample} of #{total_count} article embeddings (every #{sample_modulo}th record)...")
    
    emb_db.execute("SELECT * FROM article_embeddings WHERE id % ? = 0", sample_modulo) do |row|
      article_id = row[0]
      numac = row[1]
      article_title = row[2]
      embedding_blob = row[3]
      stored_vec = embedding_blob.unpack('e*')
      
      # Fast cosine similarity
      dot = 0.0
      stored_mag_sq = 0.0
      q_vec.each_with_index do |v, i|
        dot += v * stored_vec[i]
        stored_mag_sq += stored_vec[i] * stored_vec[i]
      end
      stored_magnitude = Math.sqrt(stored_mag_sq)
      
      similarity = (q_magnitude > 0 && stored_magnitude > 0) ? dot / (q_magnitude * stored_magnitude) : 0.0
      
      # Keep top N matches
      if top_matches.size < limit
        top_matches << [article_id, numac, article_title, similarity]
        min_similarity = top_matches.min_by { |_, _, _, s| s }[3] if top_matches.size == limit
      elsif similarity > min_similarity
        top_matches.delete(top_matches.min_by { |_, _, _, s| s })
        top_matches << [article_id, numac, article_title, similarity]
        min_similarity = top_matches.min_by { |_, _, _, s| s }[3]
      end
    end
    
    Rails.logger.info("Sampled search found #{top_matches.size} articles with similarities: #{top_matches.map { |_, _, _, s| s.round(3) }.join(', ')}")
    
    # Fetch full article details from Rails DB
    article_ids = top_matches.map { |id, _, _, _| id }
    articles_by_id = Article
      .select('articles.*, legislation.title as law_title, legislation.date')
      .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
      .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
      .where(id: article_ids)
      .index_by(&:id)
    
    # Map results with similarity scores
    top_matches.map do |article_id, numac, article_title, similarity|
      article = articles_by_id[article_id]
      next unless article
      
      {
        id: article.id,
        numac: article.content_numac,
        law_title: article.law_title || 'Unknown',
        article_title: article.article_title,
        article_text: article.article_text,
        language_id: article.language_id,
        similarity: similarity
      }
    end.compact.sort_by { |a| -a[:similarity] }
  end
  
  # Build context from legislation articles
  # Includes abolished warnings, exdecs, modifications, and parliamentary context
  def build_legislation_context(articles)
    # Track which numacs we've added preamble for (only add once per law)
    seen_preambles = Set.new
    
    articles.map do |article|
      text = article[:article_text].to_s[0..1500]
      numac = article[:numac]
      
      # Status warnings
      warnings = []
      warnings << "[OPGEHEVEN/ABROGÉ]" if article[:is_abolished]
      
      # Check for implementing decrees (exdecs)
      exdec_count = Exdec.where(content_numac: numac, language_id: @language_id).count rescue 0
      warnings << "[HEEFT #{exdec_count} UITVOERINGSBESLUITEN]" if exdec_count > 0
      
      # Check for modifications
      update_count = UpdatedLaw.where(content_numac: numac, language_id: @language_id).count rescue 0
      warnings << "[GEWIJZIGD DOOR #{update_count} WETTEN]" if update_count > 0
      
      warning_str = warnings.any? ? " #{warnings.join(' ')}" : ""
      
      # Add preamble (parliamentary context) once per law if available
      preamble_text = ""
      if article[:preamble].present? && !seen_preambles.include?(numac)
        seen_preambles.add(numac)
        preamble_text = "\n[PARLEMENTAIRE CONTEXT: #{article[:preamble].to_s[0..500]}]"
      end
      
      "[WET NUMAC #{numac}#{warning_str}] #{article[:law_title]}\n#{article[:article_title]}\n#{text}#{preamble_text}"
    end.join("\n\n---\n\n")
  end
  
  # Format legislation sources for response
  # Includes exdecs and modification counts for frontend display
  def format_legislation_sources(articles)
    articles.map do |article|
      numac = article[:numac]
      source = {
        numac: numac,
        law_title: article[:law_title],
        article_title: article[:article_title],
        url: "/#{@language}/#{numac}",
        language: article[:language_id] == 1 ? 'NL' : 'FR',
        relevance: article[:similarity].round(3)
      }
      source[:abolished] = true if article[:is_abolished]
      
      # Add exdecs and modification counts
      exdec_count = Exdec.where(content_numac: numac, language_id: @language_id).count rescue 0
      update_count = UpdatedLaw.where(content_numac: numac, language_id: @language_id).count rescue 0
      source[:exdec_count] = exdec_count if exdec_count > 0
      source[:modification_count] = update_count if update_count > 0
      
      source
    end
  end
  
  # Search jurisprudence only - ZERO HALLUCINATION
  # Uses external embeddings database for similarity search
  def search_jurisprudence(question)
    question_embedding = generate_embedding(question)
    
    # Find similar cases from external embeddings DB
    similar_cases = find_similar_jurisprudence(question_embedding, limit: 5)
    
    return no_answer_response if similar_cases.empty?
    
    context = build_jurisprudence_context_from_db(similar_cases)
    answer = query_llm(question, context, source_type: :jurisprudence)
    suggestions = generate_follow_up_suggestions(question)
    
    {
      answer: answer,
      sources: format_jurisprudence_sources_from_db(similar_cases),
      suggestions: suggestions,
      language: @language
    }
  end
  
  # Find similar jurisprudence cases using external embeddings DB
  # Uses random sampling for broad court coverage with fast response
  def find_similar_jurisprudence(question_embedding, limit: 5)
    source_db = jurisprudence_source_db
    
    # Try FAISS service first (fast path)
    top_cases = find_similar_jurisprudence_faiss(question_embedding, limit)
    
    # Fallback to direct DB search if FAISS unavailable
    if top_cases.nil?
      Rails.logger.warn("FAISS service unavailable, falling back to direct DB search")
      top_cases = find_similar_jurisprudence_direct(question_embedding, limit)
    end
    
    # Fetch case details
    top_cases.map do |case_id, similarity|
      case_data = source_db.execute(
        "SELECT id, case_number, court, decision_date, summary, full_text, url, language_id FROM cases WHERE id = ?",
        [case_id]
      ).first
      
      next unless case_data
      
      {
        id: case_data[0],
        case_number: case_data[1],
        court: case_data[2],
        decision_date: case_data[3],
        summary: case_data[4],
        full_text: case_data[5],
        url: case_data[6],
        language_id: case_data[7],
        similarity: similarity
      }
    end.compact
  end
  
  # Call FAISS service for fast similarity search
  def find_similar_jurisprudence_faiss(question_embedding, limit)
    require 'net/http'
    require 'json'
    
    faiss_url = ENV.fetch('FAISS_SERVICE_URL', 'http://127.0.0.1:8765')
    uri = URI("#{faiss_url}/search")
    
    request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
    request.body = { embedding: question_embedding, limit: limit }.to_json
    
    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 2, read_timeout: 5) do |http|
      http.request(request)
    end
    
    if response.is_a?(Net::HTTPSuccess)
      data = JSON.parse(response.body)
      Rails.logger.info("FAISS search completed in #{data['search_time_ms'].round(1)}ms")
      
      # Convert to [case_id, similarity] format
      data['results'].map { |r| [r['case_id'], r['similarity']] }
    else
      Rails.logger.error("FAISS service error: #{response.code} #{response.message}")
      nil
    end
  rescue StandardError => e
    Rails.logger.debug("FAISS service unavailable: #{e.message}")
    nil
  end
  
  # Direct database search (fallback when FAISS unavailable)
  def find_similar_jurisprudence_direct(question_embedding, limit)
    emb_db = jurisprudence_embeddings_db
    
    q_vec = question_embedding
    q_magnitude = Math.sqrt(q_vec.sum { |x| x * x })
    
    top_matches = []
    min_similarity = -1.0
    
    total = emb_db.get_first_value("SELECT COUNT(*) FROM jurisprudence_embeddings WHERE case_id IN (SELECT case_id FROM valid_case_ids)").to_i
    Rails.logger.info("Direct DB search: scanning ALL #{total} embeddings...")
    
    emb_db.execute("SELECT e.case_id, e.embedding FROM jurisprudence_embeddings e INNER JOIN valid_case_ids v ON e.case_id = v.case_id") do |row|
      case_id = row[0]
      embedding_blob = row[1]
      
      stored_vec = embedding_blob.unpack('e*')
      
      dot = 0.0
      stored_mag_sq = 0.0
      q_vec.each_with_index do |v, i|
        dot += v * stored_vec[i]
        stored_mag_sq += stored_vec[i] * stored_vec[i]
      end
      stored_magnitude = Math.sqrt(stored_mag_sq)
      
      similarity = (q_magnitude > 0 && stored_magnitude > 0) ? dot / (q_magnitude * stored_magnitude) : 0.0
      
      if top_matches.size < limit
        top_matches << [case_id, similarity]
        min_similarity = top_matches.min_by { |_, s| s }[1] if top_matches.size == limit
      elsif similarity > min_similarity
        top_matches.delete(top_matches.min_by { |_, s| s })
        top_matches << [case_id, similarity]
        min_similarity = top_matches.min_by { |_, s| s }[1]
      end
    end
    
    top_matches.sort_by { |_, sim| -sim }
  end
  
  # Connect to external jurisprudence embeddings DB
  def jurisprudence_embeddings_db
    @juris_emb_db ||= SQLite3::Database.new(JURISPRUDENCE_EMBEDDINGS_DB)
  end
  
  # Connect to external jurisprudence source DB
  def jurisprudence_source_db
    @juris_source_db ||= SQLite3::Database.new(JURISPRUDENCE_SOURCE_DB)
  end
  
  # Connect to external legislation embeddings DB
  def legislation_embeddings_db
    @leg_emb_db ||= SQLite3::Database.new(LEGISLATION_EMBEDDINGS_DB)
  end
  
  # Connect to external article embeddings DB
  def article_embeddings_db
    @article_emb_db ||= SQLite3::Database.new(ARTICLE_EMBEDDINGS_DB)
  end
  
  # Search both legislation and jurisprudence (case law)
  # This is now the DEFAULT - gives best coverage for all questions
  # Uses parallel execution to minimize response time (20s instead of 40s)
  def search_both(question)
    Rails.logger.info("[Search] Searching BOTH legislation + jurisprudence for: #{question}")
    
    question_embedding = generate_embedding(question)
    
    # Execute searches in parallel for speed
    leg_articles = nil
    jur_cases = nil
    
    threads = []
    
    # Thread 1: Search legislation
    threads << Thread.new do
      begin
        leg_articles = find_similar_legislation(question_embedding, limit: 2, question: question)
        Rails.logger.info("[Search] Legislation search found #{leg_articles.length} articles")
      rescue => e
        Rails.logger.error("[Search] Legislation search failed: #{e.message}")
        leg_articles = []
      end
    end
    
    # Thread 2: Search jurisprudence
    threads << Thread.new do
      begin
        jur_cases = find_similar_jurisprudence(question_embedding, limit: 2)
        Rails.logger.info("[Search] Jurisprudence search found #{jur_cases.length} cases")
      rescue => e
        Rails.logger.error("[Search] Jurisprudence search failed: #{e.message}")
        jur_cases = []
      end
    end
    
    # Wait for both searches to complete (max 30s each)
    threads.each { |t| t.join(30) }
    
    # Ensure we have results (fallback to empty arrays if threads timed out)
    leg_articles ||= []
    jur_cases ||= []
    
    return no_answer_response if leg_articles.empty? && jur_cases.empty?
    
    # Build combined context
    context = build_combined_context_from_db(leg_articles, jur_cases)
    answer = query_llm(question, context, source_type: :all)
    suggestions = generate_follow_up_suggestions(question)
    
    {
      answer: answer,
      sources: format_legislation_sources(leg_articles) + format_jurisprudence_sources_from_db(jur_cases),
      suggestions: suggestions,
      language: @language
    }
  end
  
  # Build combined context from legislation and jurisprudence
  def build_combined_context_from_db(articles, cases)
    parts = []
    law_label = @language == 'fr' ? 'LOI' : 'WET'
    juris_label = @language == 'fr' ? 'JURISPRUDENCE' : 'RECHTSPRAAK'
    
    articles.each_with_index do |article, index|
      lang_label = article[:language_id] == 1 ? 'NL' : 'FR'
      text = article[:article_text].to_s[0..4000]
      parts << "[Bron #{index + 1} - #{law_label} (#{lang_label})]\nNUMAC: #{article[:numac]}\nWet: #{article[:law_title]}\n#{article[:article_title]}\n#{text}"
    end
    
    cases.each_with_index do |c, index|
      lang_label = c[:language_id] == 1 ? 'NL' : 'FR'
      text = c[:full_text].to_s[0..4000]
      parts << "[Bron #{articles.size + index + 1} - #{juris_label} (#{lang_label})]\nECLI: #{c[:case_number]}\nHof: #{c[:court]}\nDatum: #{c[:decision_date]}\n#{text}"
    end
    
    parts.join("\n\n---\n\n")
  end
  
  # Generate embedding for text using Azure OpenAI (EU data residency)
  # Uses direct HTTP call for proper Azure deployment path
  def generate_embedding(text)
    Timeout.timeout(10) do
      generate_embedding_internal(text)
    end
  rescue Timeout::Error
    Rails.logger.error("Embedding generation timeout for text: #{text[0..100]}")
    raise "Embedding generation timeout"
  end
  
  def generate_embedding_internal(text)
    endpoint = ENV['AZURE_OPENAI_ENDPOINT'].to_s.chomp('/')
    api_key = ENV['AZURE_OPENAI_KEY']
    api_version = ENV.fetch('AZURE_OPENAI_API_VERSION', '2024-02-15-preview')
    
    uri = URI("#{endpoint}/openai/deployments/#{EMBEDDING_MODEL}/embeddings?api-version=#{api_version}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['api-key'] = api_key
    request.body = { input: text, dimensions: EMBEDDING_DIMENSIONS }.to_json
    
    response = http.request(request)
    
    unless response.code == '200'
      raise "Azure OpenAI error #{response.code}: #{response.body}"
    end
    
    result = JSON.parse(response.body)
    result.dig('data', 0, 'embedding')
  end
  
  # Generate embeddings for all articles (used in rake task)
  def self.generate_all_embeddings(batch_size: 100, language_id: nil)
    service_nl = new(language: 'nl')
    service_fr = new(language: 'fr')
    
    scope = Article.where(embedding: nil)
    scope = scope.where(language_id: language_id) if language_id
    
    total = scope.count
    processed = 0
    
    puts "Generating embeddings for #{total} articles..."
    
    scope.find_in_batches(batch_size: batch_size) do |articles|
      articles.each do |article|
        service = article.language_id == 2 ? service_fr : service_nl
        text = build_article_text(article)
        
        embedding = service.generate_embedding(text)
        
        article.update_columns(
          embedding: embedding,
          embedding_generated_at: Time.current,
          embedding_model: EMBEDDING_MODEL
        )
        
        processed += 1
        print "\rProgress: #{processed}/#{total} (#{(processed.to_f / total * 100).round(1)}%)"
      rescue StandardError => e
        Rails.logger.error("Failed to generate embedding for article #{article.id}: #{e.message}")
      end
      
      # Rate limiting: OpenAI allows 3000 requests/min, sleep to be safe
      sleep 0.5
    end
    
    puts "\nDone! Generated #{processed} embeddings."
  end
  
  private
  
  # Find articles most similar to the question embedding
  # CROSS-LINGUAL: Searches both NL and FR legislation
  def find_relevant_articles(embedding)
    # Fetch laws with embeddings from database (prioritize recent laws)
    # SEARCH BOTH LANGUAGES: Belgian laws exist in both NL and FR
    all_laws = Legislation
      .select('legislation.*, contents.*')
      .joins('LEFT JOIN contents ON legislation.numac = contents.legislation_numac AND legislation.language_id = contents.language_id')
      .where.not(embedding: nil)
      .order('legislation.date DESC')
      .limit(100) # Get 100 recent laws (both languages) for similarity calculation
    
    # Calculate cosine similarity in Ruby (SQLite doesn't have vector operations)
    laws_with_similarity = all_laws.map do |law|
      law_embedding = JSON.parse(law.embedding)
      similarity = cosine_similarity(embedding, law_embedding)
      law.define_singleton_method(:distance) { 1 - similarity }
      law.define_singleton_method(:similarity) { similarity }
      law
    end
    
    # Sort by similarity - prioritize user's language but include other if highly relevant
    sorted = laws_with_similarity.sort_by(&:distance)
    top_law_matches = sorted.take(15)
    sorted = articles_with_similarity.sort_by(&:distance)
    user_lang = sorted.select { |a| a.language_id == @language_id }.first(4)
    other_lang = sorted.reject { |a| a.language_id == @language_id }.first(1)
    
    # Return top matches: mostly user's language + 1 from other language if relevant
    (user_lang + other_lang).sort_by(&:distance).first(MAX_CONTEXT_ARTICLES)
  end
  
  # Calculate cosine similarity between two vectors
  def cosine_similarity(vec1, vec2)
    return 0.0 if vec1.empty? || vec2.empty? || vec1.length != vec2.length
    
    dot_product = vec1.zip(vec2).sum { |a, b| a * b }
    magnitude1 = Math.sqrt(vec1.sum { |a| a**2 })
    magnitude2 = Math.sqrt(vec2.sum { |a| a**2 })
    
    return 0.0 if magnitude1.zero? || magnitude2.zero?
    
    dot_product / (magnitude1 * magnitude2)
  end
  
  # Build context string from articles
  def build_context(articles)
    articles.map.with_index do |article, index|
      <<~CONTEXT
        [Bron #{index + 1}]
        Wet: #{article.law_title}
        NUMAC: #{article.numac}
        #{article.article_title}: #{article.article_text}
      CONTEXT
    end.join("\n---\n")
  end
  
  # Build searchable text from article for embedding
  def self.build_article_text(article)
    law = article.content&.legislation
    return "#{article.article_title}: #{article.article_text}" unless law
    
    text = "Wet: #{law.title}\n"
    text += "NUMAC: #{law.numac}\n"
    text += "Datum: #{law.date}\n" if law.date
    
    # Parliamentary work links
    if law.chamber.present? && law.chamber != "N/A"
      text += "Kamer documenten: #{law.chamber}\n"
    end
    if law.senate.present? && law.senate != "N/A"
      text += "Senaat documenten: #{law.senate}\n"
    end
    
    # Additional metadata from Justel
    text += "Justel: #{law.justel}\n" if law.justel.present? && law.justel != "N/A"
    text += "Belgisch Staatsblad: #{law.mon}\n" if law.mon.present? && law.mon != "N/A"
    
    # Article content
    text += "\n#{article.article_title}: #{article.article_text}"
    
    text
  end
  
  # Build jurisprudence context from external DB results
  def build_jurisprudence_context_from_db(cases)
    cases.map.with_index do |c, index|
      lang_label = c[:language_id] == 1 ? 'NL' : 'FR'
      source_label = @language == 'fr' ? 'JURISPRUDENCE' : 'RECHTSPRAAK'
      
      # Use summary if available, otherwise truncate full_text
      text = c[:summary].present? ? c[:summary] : c[:full_text].to_s[0, 2000]
      
      <<~CONTEXT
        [Bron #{index + 1} - #{source_label} (#{lang_label})]
        ECLI: #{c[:case_number]}
        Hof: #{c[:court]}
        Datum: #{c[:decision_date]}
        
        #{text}
      CONTEXT
    end.join("\n---\n")
  end
  
  # Build jurisprudence context (legacy - for CaseChunk model)
  def build_jurisprudence_context(chunks)
    chunks.map.with_index do |chunk, index|
      c = chunk.case
      lang_label = c.language_id == 1 ? 'NL' : 'FR'
      source_label = @language == 'fr' ? 'JURISPRUDENCE' : 'RECHTSPRAAK'
      
      <<~CONTEXT
        [Bron #{index + 1} - #{source_label} (#{lang_label})]
        ECLI: #{c.case_number}
        Hof: #{c.court}
        Datum: #{c.decision_date}
        
        #{chunk.chunk_text}
      CONTEXT
    end.join("\n---\n")
  end
  
  # Build combined context (with language labels for cross-lingual search)
  def build_combined_context(articles, chunks)
    parts = []
    law_label = @language == 'fr' ? 'LOI' : 'WET'
    juris_label = @language == 'fr' ? 'JURISPRUDENCE' : 'RECHTSPRAAK'
    
    articles.each_with_index do |article, index|
      lang_label = article.language_id == 1 ? 'NL' : 'FR'
      parts << <<~CONTEXT
        [Bron #{index + 1} - #{law_label} (#{lang_label})]
        Wet: #{article.law_title}
        NUMAC: #{article.numac}
        #{article.article_title}: #{article.article_text}
      CONTEXT
    end
    
    chunks.each_with_index do |chunk, index|
      c = chunk.case
      lang_label = c.language_id == 1 ? 'NL' : 'FR'
      parts << <<~CONTEXT
        [Bron #{articles.size + index + 1} - #{juris_label} (#{lang_label})]
        ECLI: #{c.case_number}
        Hof: #{c.court}
        Datum: #{c.decision_date}
        
        #{chunk.chunk_text}
      CONTEXT
    end
    
    parts.join("\n---\n")
  end
  
  # Format jurisprudence sources from external DB results
  def format_jurisprudence_sources_from_db(cases)
    cases.map do |c|
      {
        type: 'RECHTSPRAAK',
        ecli: c[:case_number],
        court: c[:court],
        date: c[:decision_date],
        url: c[:url],
        language: c[:language_id] == 1 ? 'NL' : 'FR',
        relevance: c[:similarity].round(2)
      }
    end
  end
  
  # Format jurisprudence sources (legacy - for CaseChunk model)
  def format_jurisprudence_sources(chunks)
    chunks.map do |chunk|
      {
        type: 'RECHTSPRAAK',
        ecli: chunk.case.case_number,
        court: chunk.case.court,
        date: chunk.case.decision_date,
        url: chunk.case.url,
        language: chunk.case.language_id == 1 ? 'NL' : 'FR',
        relevance: (1 - chunk.distance).round(2)
      }
    end
  end
  
  # Query Azure OpenAI with context and question - ZERO HALLUCINATION MODE
  # Data processed in EU (West Europe region) for GDPR compliance
  def query_llm(question, context, source_type: :legislation)
    system_prompt = build_system_prompt(source_type)
    
    messages = [
      { role: 'system', content: system_prompt },
      { role: 'user', content: "Bronnen:\n#{context}\n\nVraag: #{question}" }
    ]
    
    answer = azure_chat_completion(messages, temperature: 0.1, max_tokens: 500)
    
    # Return Azure response as-is (trust the LLM)
    return answer if answer && !answer.empty?
    
    # Only error if Azure completely failed to respond
    Rails.logger.error("Azure returned nil/empty response")
    @language == 'fr' ? 
      "Désolé, je n'ai pas pu générer une réponse. Veuillez réessayer." :
      "Sorry, ik kon geen antwoord genereren. Probeer het opnieuw."
  end
  
  # Direct HTTP call to Azure OpenAI chat completions
  def azure_chat_completion(messages, temperature: 0.7, max_tokens: 500)
    endpoint = ENV['AZURE_OPENAI_ENDPOINT'].to_s.chomp('/')
    api_key = ENV['AZURE_OPENAI_KEY']
    api_version = ENV.fetch('AZURE_OPENAI_API_VERSION', '2024-02-15-preview')
    
    uri = URI("#{endpoint}/openai/deployments/#{CHAT_MODEL}/chat/completions?api-version=#{api_version}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    http.open_timeout = 10
    
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['api-key'] = api_key
    request.body = {
      messages: messages,
      temperature: temperature,
      max_tokens: max_tokens
    }.to_json
    
    response = http.request(request)
    
    unless response.code == '200'
      raise "Azure OpenAI chat error #{response.code}: #{response.body}"
    end
    
    result = JSON.parse(response.body)
    result.dig('choices', 0, 'message', 'content')
  end
  
  # Build strict anti-hallucination system prompt
  def build_system_prompt(source_type)
    base_rules = if @language == 'fr'
      <<~RULES
        Vous êtes un assistant juridique utile. Utilisez les sources pour donner des réponses utiles.
        
        RÈGLES:
        1. Utilisez les sources fournies pour répondre à la question
        2. Si les sources traitent du sujet mais ne répondent pas exactement à la question, donnez les principes généraux ou informations connexes pertinentes
        3. Vous POUVEZ reformuler, synthétiser et interpréter les informations des sources
        4. Soyez utile - si les sources contiennent quelque chose de pertinent, utilisez-le
        5. LOIS ABROGÉES: Si une source est [OPGEHEVEN/ABROGÉ], AVERTISSEZ que cette loi n'est plus en vigueur
        6. ARRÊTÉS D'EXÉCUTION: Si une loi [HEEFT X UITVOERINGSBESLUITEN], MENTIONNEZ qu'il existe des AR/AM qui précisent les détails
        7. MODIFICATIONS: Si une loi [GEWIJZIGD DOOR X WETTEN], MENTIONNEZ que c'est la version consolidée
        8. CONTEXTE PARLEMENTAIRE: Si [PARLEMENTAIRE CONTEXT] est présent, utilisez-le pour expliquer le contexte/l'intention de la loi
        9. Seulement si les sources ne traitent PAS DU TOUT du sujet: "Ces sources ne contiennent pas d'information sur ce sujet."
        10. Citez toujours les sources (NUMAC) - les sources peuvent être en NL ou FR
        
        Format de réponse:
        [Réponse utile et claire utilisant les sources]
        
        Sources: [NUMAC/ECLI des sources utilisées]
      RULES
    else
      <<~RULES
        U bent een behulpzame juridische assistent. Gebruik de bronnen om nuttige antwoorden te geven.
        
        REGELS:
        1. Gebruik de verstrekte bronnen om de vraag te beantwoorden
        2. Als bronnen het onderwerp behandelen maar niet exact de vraag beantwoorden, geef dan de relevante algemene principes of gerelateerde informatie
        3. U MAG informatie uit de bronnen herformuleren, samenvatten en interpreteren
        4. Wees behulpzaam - als bronnen iets relevants bevatten, gebruik dit dan
        5. OPGEHEVEN WETTEN: Als een bron [OPGEHEVEN/ABROGÉ] is, WAARSCHUW dat deze wet niet meer geldig is
        6. UITVOERINGSBESLUITEN: Als een wet [HEEFT X UITVOERINGSBESLUITEN] heeft, VERMELD dat er KB's/MB's zijn die details uitwerken
        7. WIJZIGINGEN: Als een wet [GEWIJZIGD DOOR X WETTEN] is, VERMELD dat dit de geconsolideerde versie is
        8. PARLEMENTAIRE CONTEXT: Als [PARLEMENTAIRE CONTEXT] aanwezig is, gebruik dit om de achtergrond/intentie van de wet uit te leggen
        9. Als de bronnen het VERKEERDE rechtsdomein behandelen, leg uit waarom en verwijs naar juiste bron
        10. Alleen als bronnen NIETS verwants behandelen: "Deze bronnen bevatten geen informatie over dit onderwerp."
        11. Citeer altijd bronnen (NUMAC) en bronnen kunnen in NL of FR zijn
        
        Antwoordformaat:
        [Nuttig, duidelijk antwoord dat de bronnen gebruikt of uitlegt waarom bronnen niet passen]
        
        Bronnen: [NUMAC/ECLI van gebruikte bronnen met toelichting indien niet exact passend]
      RULES
    end
    
    source_specific = case source_type
    when :jurisprudence
      @language == 'fr' ? 
        "\nVous citez UNIQUEMENT des arrêts de jurisprudence. Format: Arrêt ECLI:BE:..." :
        "\nU citeert ALLEEN rechtspraakarresten. Format: Arrest ECLI:BE:..."
    when :all
      @language == 'fr' ?
        "\n\nIMPORTANT - DISTINCTION DES SOURCES:\n" \
        "- [LOI]: Articles de loi et réglementations officielles\n" \
        "- [JURISPRUDENCE]: Décisions de tribunaux et interprétations judiciaires\n\n" \
        "OBLIGATOIRE:\n" \
        "1. Indiquez TOUJOURS la catégorie avant chaque référence: [LOI] ou [JURISPRUDENCE]\n" \
        "2. Expliquez si l'information vient de la loi écrite ou de l'interprétation judiciaire\n" \
        "3. Format: 'Selon la [LOI/JURISPRUDENCE], ...'\n\n" \
        "Exemple: 'Selon la [LOI] (Article 37, NUMAC 1978070303), ... Selon la [JURISPRUDENCE] (Arrêt ECLI:BE:...), les tribunaux interprètent ceci comme...'" :
        "\n\nBELANGRIJK - ONDERSCHEID TUSSEN BRONNEN:\n" \
        "- [WET]: Wetsartikelen en officiële regelgeving\n" \
        "- [RECHTSPRAAK]: Gerechtelijke uitspraken en interpretaties\n\n" \
        "VERPLICHT:\n" \
        "1. Vermeld ALTIJD de categorie voor elke referentie: [WET] of [RECHTSPRAAK]\n" \
        "2. Leg uit of informatie komt van geschreven wet of rechterlijke interpretatie\n" \
        "3. Format: 'Volgens de [WET/RECHTSPRAAK], ...'\n\n" \
        "Voorbeeld: 'Volgens de [WET] (Artikel 37, NUMAC 1978070303), ... Volgens de [RECHTSPRAAK] (Arrest ECLI:BE:...), interpreteren rechtbanken dit als...'"
    else  # legislation
      @language == 'fr' ?
        "\nVous citez UNIQUEMENT des articles de loi. Format: Article X, NUMAC..." :
        "\nU citeert ALLEEN wetsartikelen. Format: Artikel X, NUMAC..."
    end
    
    disclaimer = @language == 'fr' ?
      "\n\nAvertissement obligatoire: \"Ceci n'est pas un conseil juridique officiel. Vérifiez toujours auprès de sources officielles.\"" :
      "\n\nVerplichte waarschuwing: \"Dit is geen officieel juridisch advies. Verifieer altijd bij officiële bronnen.\""
    
    base_rules + source_specific + disclaimer
  end
  
  # Old query_llm method kept for compatibility
  def query_llm_old(question, context)
    system_prompt = if @language == 'fr'
      <<~PROMPT
        Vous êtes un assistant juridique belge expert. Répondez UNIQUEMENT en vous basant sur les articles de loi fournis.
        
        Règles strictes:
        1. Citez toujours les articles spécifiques (ex: "Selon l'article 3...")
        2. Si l'information n'est pas dans les sources, dites "Je ne trouve pas cette information dans les sources disponibles"
        3. Soyez précis et concis
        4. Utilisez un langage clair, pas de jargon juridique excessif
        5. Ajoutez toujours: "Ceci n'est pas un conseil juridique officiel. Les modèles d'IA peuvent faire des erreurs - vérifiez toujours les informations importantes auprès de sources officielles ou consultez un professionnel juridique."
      PROMPT
    else
      <<~PROMPT
        Je bent een Belgische juridische assistent. Beantwoord vragen ENKEL op basis van de verstrekte wetsartikelen.
        
        Strikte regels:
        1. Citeer altijd specifieke artikelen (bijv. "Volgens artikel 3...")
        2. Als de informatie niet in de bronnen staat, zeg dan "Ik vind deze informatie niet in de beschikbare bronnen"
        3. Wees nauwkeurig en bondig
        4. Gebruik duidelijke taal, geen overdreven juridisch jargon
        5. Voeg altijd toe: "Dit is geen officieel juridisch advies. AI-modellen kunnen fouten maken - verifieer belangrijke informatie altijd bij officiële bronnen of raadpleeg een juridisch professional."
      PROMPT
    end
    
    messages = [
      { role: 'system', content: system_prompt },
      { role: 'user', content: "Bronnen:\n#{context}\n\nVraag: #{question}" }
    ]
    
    azure_chat_completion(messages, temperature: 0.3, max_tokens: 500)
  end
  
  # Format sources for response (with language info)
  def format_sources(articles)
    articles.map do |article|
      {
        numac: article.numac,
        law_title: article.law_title,
        article_title: article.article_title,
        url: "/#{@language}/#{article.numac}##{article.article_title.parameterize}",
        language: article.language_id == 1 ? 'NL' : 'FR',
        relevance: (1 - article.distance).round(2) # Convert distance to similarity score
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
end
