# frozen_string_literal: true

# == LawSearchService
#
# Service object responsible for searching and filtering legislation records
# based on various criteria such as language, document type, and title.
# This service encapsulates all search logic, making it easier to maintain
# and test independently of the controller.
#
# @example Basic usage
#   # From a controller:
#   @laws = LawSearchService.search({
#     lang_nl: '1',
#     title: 'constitution',
#     sort: 'title_asc'
#   })
#
# @see LawsController#index The controller action that uses this service
# rubocop:disable Metrics/ClassLength
class LawSearchService
  # Bring in constant mappings for types and sort options
  include LawSearchConstants

  # Common stop words to exclude from token-based search (would match too broadly)
  STOP_WORDS = %w[
    van de het een en of voor bij tot aan met uit ter op den der des te
    du de la le les un une et pour dans sur avec au aux ou par des à
  ].freeze

  # Bilingual legal terminology synonyms (NL <-> FR)
  # Allows cross-language search for common legal terms
  LEGAL_SYNONYMS = {
    # Judgment types
    'vonnis' => %w[jugement],
    'jugement' => %w[vonnis],
    'arrest' => %w[arrêt],
    'arrêt' => %w[arrest],
    'beschikking' => %w[ordonnance],
    'ordonnance' => %w[beschikking],

    # Appeal procedures
    'beroep' => %w[appel],
    'appel' => %w[beroep],
    'cassatie' => %w[cassation pourvoi],
    'cassation' => %w[cassatie],
    'verzet' => %w[opposition],
    'opposition' => %w[verzet],

    # Service/notification
    'betekening' => %w[signification],
    'signification' => %w[betekening],
    'kennisgeving' => %w[notification],
    'notification' => %w[kennisgeving],
    'dagvaarding' => %w[citation assignation],
    'citation' => %w[dagvaarding],

    # Parties
    'eiser' => %w[demandeur],
    'demandeur' => %w[eiser],
    'verweerder' => %w[défendeur],
    'défendeur' => %w[verweerder],

    # Courts
    'rechtbank' => %w[tribunal],
    'tribunal' => %w[rechtbank],
    'hof' => %w[cour],
    'cour' => %w[hof],
    'raad' => %w[conseil],
    'conseil' => %w[raad],

    # Legal codes
    'wetboek' => %w[code],
    'code' => %w[wetboek],
    'grondwet' => %w[constitution],
    'constitution' => %w[grondwet],

    # Document types
    'wet' => %w[loi],
    'loi' => %w[wet],
    'decreet' => %w[décret],
    'décret' => %w[decreet],
    'besluit' => %w[arrêté],
    'arrêté' => %w[besluit],
    'verordening' => %w[règlement ordonnance],
    'règlement' => %w[verordening]
  }.freeze

  # Performs a search for legislation based on the provided parameters
  #
  # @param params [Hash, ActionController::Parameters] The search parameters
  # @option params [String] :title Search term to match against legislation titles
  # @option params [String] :sort Sort order (e.g., 'title_asc', 'date_desc')
  # @option params [String] :lang_nl '1' to include Dutch, '0' to exclude, nil for no filter
  # @option params [String] :lang_fr '1' to include French, '0' to exclude, nil for no filter
  # @option params [String] :constitution '1' to include constitutions
  # @option params [String] :law '1' to include laws
  # @option params [String] :decree '1' to include decrees
  # @option params [String] :ordinance '1' to include ordinances
  # @option params [String] :decision '1' to include decisions
  # @return [ActiveRecord::Relation] The filtered and sorted scope of Legislation records
  # @raise [ArgumentError] if invalid parameters are provided
  #
  # @example Basic search with title filter
  #   results = LawSearchService.search(title: 'constitution', lang_nl: '1')
  #
  # @example With sorting and multiple document types
  #   results = LawSearchService.search(
  #     sort: 'title_asc',
  #     constitution: '1',
  #     law: '1',
  #     lang_nl: '1'
  #   )
  def self.search(params)
    # Convert to hash with indifferent access if it's ActionController::Parameters
    params = params.to_unsafe_h if params.respond_to?(:to_unsafe_h)
    params = params.with_indifferent_access if params.respond_to?(:with_indifferent_access)

    scope = Legislation.all
    scope = by_language(scope, params)
    scope = by_type(scope, params)
    scope = by_status_flags(scope, params)
    scope = by_date_range(scope, params)
    scope = by_text_or_title(scope, params)
    apply_sort(scope, params)
  end

  private

  # Filters the scope by the selected languages
  # @param scope [ActiveRecord::Relation] The current scope to filter
  # @param params [Hash] The search parameters
  # @return [ActiveRecord::Relation] Scope filtered by language
  # @note Returns the original scope if no language filters are applied
  # @private
  def self.by_language(scope, params)
    return scope unless language_filtered?(params)

    language_ids = []
    language_ids << '1' if include_dutch?(params)
    language_ids << '2' if include_french?(params)

    # If no languages are selected, return none to prevent returning all records
    return scope.none if language_ids.empty?

    scope.where(language_id: language_ids)
  end
  private_class_method :by_language

  # Checks if any language filters are applied
  # @param params [Hash] The search parameters
  # @return [Boolean] true if any language filter is present
  def self.language_filtered?(params)
    # Only consider explicit language checkboxes as filters. The hidden
    # languages_present flag is used for validation/UI, not filtering.
    params[:lang_nl].present? || params[:lang_fr].present?
  end
  private_class_method :language_filtered?

  # Checks if Dutch documents should be included
  # @param params [Hash] The search parameters
  # @return [Boolean] true if Dutch documents should be included
  def self.include_dutch?(params)
    params[:lang_nl] == '1'
  end
  private_class_method :include_dutch?

  # Checks if French documents should be included
  # @param params [Hash] The search parameters
  # @return [Boolean] true if French documents should be included
  def self.include_french?(params)
    params[:lang_fr] == '1'
  end
  private_class_method :include_french?

  # Filters the scope by document types based on the selected languages and types
  # @param scope [ActiveRecord::Relation] The current scope to filter
  # @param params [Hash] The search parameters
  # @return [ActiveRecord::Relation] Scope filtered by document types
  # @note Only applies filters for languages that are enabled in the search
  # @private
  def self.by_type(scope, params)
    type_ids = type_ids_from_params(params)

    # If specific types are selected but none match, return no results
    return scope.none if type_ids.empty? && type_filter_applied?(params)

    type_ids.any? ? scope.where(law_type_id: type_ids) : scope
  end
  private_class_method :by_type

  # Filters the scope by content status flags
  # @param scope [ActiveRecord::Relation] The current scope to filter
  # @param params [Hash] The search parameters
  # @return [ActiveRecord::Relation] Scope filtered by status flags
  # @private
  def self.by_status_flags(scope, params)
    scope = scope.where(is_abolished: 0) if params[:hide_abolished] == '1'
    scope = scope.where(is_empty_content: 0) if params[:hide_empty] == '1'
    scope = scope.where(translation_missing: 0) if params[:hide_missing_translation] == '1'

    # Filter out German translations (identified by "Duitse vertaling" or "Traduction allemande" in title)
    if params[:hide_german_translation] == '1'
      scope = scope.where.not('LOWER(title) LIKE ? OR LOWER(title) LIKE ?',
                              '%duitse vertaling%', '%traduction allemande%')
    end

    scope
  end
  private_class_method :by_status_flags

  # Filters the scope by date range
  # @param scope [ActiveRecord::Relation] The current scope to filter
  # @param params [Hash] The search parameters
  # @return [ActiveRecord::Relation] Scope filtered by date range
  # @private
  def self.by_date_range(scope, params)
    if params[:date_from].present?
      date_from = parse_date(params[:date_from])
      scope = scope.where('date >= ?', date_from) if date_from
    end

    if params[:date_to].present?
      date_to = parse_date(params[:date_to])
      scope = scope.where('date <= ?', date_to) if date_to
    end

    scope
  end
  private_class_method :by_date_range

  # Parses a date string in DD/MM/YYYY format to a Date object
  # @param date_string [String] The date string to parse
  # @return [Date, nil] Parsed date or nil if invalid
  # @private
  def self.parse_date(date_string)
    return nil if date_string.blank?

    # Try DD/MM/YYYY format first (from flatpickr)
    if date_string.match?(%r{\A\d{1,2}/\d{1,2}/\d{4}\z})
      day, month, year = date_string.split('/').map(&:to_i)
      begin
        Date.new(year, month, day)
      rescue StandardError
        nil
      end
    # Also support YYYY-MM-DD format (legacy/direct input)
    elsif date_string.match?(/\A\d{4}-\d{1,2}-\d{1,2}\z/)
      begin
        Date.parse(date_string)
      rescue StandardError
        nil
      end
    end
  end
  private_class_method :parse_date

  # Filters the scope by NUMAC number
  # @param scope [ActiveRecord::Relation] The current scope to filter
  # @param params [Hash] The search parameters
  # @return [ActiveRecord::Relation] Scope filtered by NUMAC
  # @private
  def self.by_numac(scope, params)
    return scope if params[:numac].blank?

    numac_query = params[:numac].to_s.gsub(/[^0-9]/, '')
    return scope.none if numac_query.blank?

    scope.where('numac LIKE ?', "%#{sanitize_sql_like(numac_query)}%")
  end
  private_class_method :by_numac

  # Extracts type IDs from parameters based on selected languages and types
  # @param params [Hash] The search parameters
  # @return [Array<String>] Array of type IDs to filter by
  def self.type_ids_from_params(params)
    type_ids = []

    # Add Dutch document types if Dutch is selected
    type_ids += selected_type_ids(:nl, params) if include_dutch?(params)

    # Add French document types if French is selected
    type_ids += selected_type_ids(:fr, params) if include_french?(params)

    type_ids.uniq
  end
  private_class_method :type_ids_from_params

  # Gets selected type IDs for a specific language
  # @param language [Symbol] The language symbol (:nl or :fr)
  # @param params [Hash] The search parameters
  # @return [Array<String>] Selected type IDs for the language
  def self.selected_type_ids(language, params)
    TYPE_MAPPING[language].each_with_object([]) do |(type, id), ids|
      ids << id if params[type.to_s].present? && params[type.to_s] != '0'
    end
  end
  private_class_method :selected_type_ids

  # Checks if any type filters are applied
  # @param params [Hash] The search parameters
  # @return [Boolean] true if any type filter is applied
  def self.type_filter_applied?(params)
    TYPE_MAPPING.values.flat_map(&:keys).any? do |type|
      params[type].present? && params[type] != '0'
    end
  end
  private_class_method :type_filter_applied?

  # Filters the scope by title search term
  # @param scope [ActiveRecord::Relation] The current scope to filter
  # @param title [String, nil] The search term to match against titles
  # @return [ActiveRecord::Relation] Scope filtered by title
  # @note Uses LOWER with LIKE for case-insensitive search in SQLite
  # @private
  def self.by_title(scope, title)
    return scope.none if title.blank?

    # Clean and validate the search term
    search_term = normalize_query(title)
    return scope.none unless valid_query?(search_term)

    # Use LOWER with LIKE for case-insensitive search in SQLite
    result = scope.where('LOWER(title) LIKE ?', "%#{sanitize_sql_like(search_term)}%")
    instrument_strategy(:title_like, title_length: search_term.length, sqlite: sqlite_adapter?,
                                     tag_tokens: extract_tokens(search_term).size)
    result
  end
  private_class_method :by_title

  def self.by_text_or_title(scope, params)
    title = params[:title]
    return scope if title.blank?

    # Auto-detect NUMAC: if query is exactly 10 digits, search in NUMAC field
    cleaned_query = title.to_s.gsub(/[^0-9]/, '')
    return scope.where('numac LIKE ?', "%#{sanitize_sql_like(cleaned_query)}%") if cleaned_query.length == 10

    # Determine search mode (default: flexible for better UX)
    mode = params[:search_mode] == 'exact' ? :exact : :flexible

    return perform_article_text_search(scope, title, params, mode) if params[:search_in_text] == '1'
    return scope unless search_in_title_on?(params)

    perform_title_search(scope, title, params, mode)
  end

  def self.perform_article_text_search(scope, title, params, mode)
    if mode == :flexible
      perform_article_text_search_flexible(scope, title, params)
    else
      perform_article_text_search_exact(scope, title, params)
    end
  end
  private_class_method :perform_article_text_search

  def self.perform_article_text_search_exact(scope, title, params)
    sqlite = sqlite_adapter?
    rel = sqlite ? by_article_ngrams(scope, title) : by_article_text(scope, title)
    combined = combine_relations_by_rowid_or_tags(scope, rel, title, params)
    instrument_strategy(:search_in_text_exact, title_length: normalize_query(title).length, sqlite: sqlite,
                                               tag_tokens: extract_tokens(title).size)
    combined
  end
  private_class_method :perform_article_text_search_exact

  def self.perform_article_text_search_flexible(scope, title, params)
    tokens = extract_tokens(title)
    return scope.none if tokens.empty?

    search_tags = !params.key?(:search_in_tags) || params[:search_in_tags] == '1'

    # Build AND condition for each token in article text (and optionally tags)
    # Each token must be present in either article text or tags
    conditions = tokens.map do
      if search_tags
        '(EXISTS (SELECT 1 FROM articles WHERE articles.content_numac = legislation.numac AND articles.language_id = legislation.language_id AND LOWER(articles.article_text) LIKE ?) OR LOWER(tags) LIKE ?)'
      else
        'EXISTS (SELECT 1 FROM articles WHERE articles.content_numac = legislation.numac AND articles.language_id = legislation.language_id AND LOWER(articles.article_text) LIKE ?)'
      end
    end.join(' AND ')

    binds = if search_tags
              tokens.flat_map { |token| ["%#{sanitize_sql_like(token)}%", "%#{sanitize_sql_like(token)}%"] }
            else
              tokens.map { |token| "%#{sanitize_sql_like(token)}%" }
            end

    result = scope.where(conditions, *binds).distinct
    instrument_strategy(:search_in_text_flexible, title_length: normalize_query(title).length, token_count: tokens.size)
    result
  end
  private_class_method :perform_article_text_search_flexible

  def self.perform_title_search(scope, title, params, mode)
    if mode == :flexible
      perform_title_search_flexible(scope, title, params)
    else
      perform_title_search_exact(scope, title, params)
    end
  end
  private_class_method :perform_title_search

  def self.perform_title_search_exact(scope, title, params)
    sqlite = sqlite_adapter?
    rel = sqlite ? by_title_ngrams(scope, title) : by_title(scope, title)
    combined = combine_relations_by_rowid_or_tags(scope, rel, title, params)
    instrument_strategy(:search_in_title_exact, title_length: normalize_query(title).length, sqlite: sqlite,
                                                tag_tokens: extract_tokens(title).size)
    combined
  end
  private_class_method :perform_title_search_exact

  def self.perform_title_search_flexible(scope, title, params)
    tokens = extract_tokens(title)
    return scope.none if tokens.empty?

    search_tags = !params.key?(:search_in_tags) || params[:search_in_tags] == '1'
    use_synonyms = params[:expand_synonyms] != '0' # Enable by default

    # Build AND condition for each token in title (and optionally tags)
    # Each token (or its synonyms) must be present in either title or tags
    conditions = []
    binds = []

    tokens.each do |token|
      token_variants = use_synonyms ? ([token] + (LEGAL_SYNONYMS[token] || [])).uniq : [token]

      if search_tags
        # OR between token variants, each can match title OR tags
        variant_conditions = token_variants.map { '(LOWER(title) LIKE ? OR LOWER(tags) LIKE ?)' }
        conditions << "(#{variant_conditions.join(' OR ')})"
        token_variants.each do |t|
          binds << "%#{sanitize_sql_like(t)}%"
          binds << "%#{sanitize_sql_like(t)}%"
        end
      else
        variant_conditions = token_variants.map { 'LOWER(title) LIKE ?' }
        conditions << "(#{variant_conditions.join(' OR ')})"
        token_variants.each { |t| binds << "%#{sanitize_sql_like(t)}%" }
      end
    end

    result = scope.where(conditions.join(' AND '), *binds).distinct
    instrument_strategy(:search_in_title_flexible, title_length: normalize_query(title).length, token_count: tokens.size,
                                                   synonyms_enabled: use_synonyms)
    result
  end
  private_class_method :by_text_or_title, :perform_title_search_flexible

  # Safely combine a complex relation (with joins/group/distinct) and tag matches by
  # filtering the base scope with an OR between a rowid IN (subquery) and the tags predicate.
  def self.combine_relations_by_rowid_or_tags(scope, rel, title, params)
    search_tags = !params.key?(:search_in_tags) || params[:search_in_tags] == '1'

    if search_tags
      tag_sql, binds = build_tags_predicate_and_binds(title)
      sub_sql = rel.select('legislation.rowid').to_sql
      result = scope.where("(legislation.rowid IN (#{sub_sql}) OR #{tag_sql})", *binds).distinct
      instrument_strategy(:combine_relations, tag_tokens: (binds.length / 2), has_relation: rel.present?)
    else
      # Just use the relation without tag matching
      sub_sql = rel.select('legislation.rowid').to_sql
      result = scope.where("legislation.rowid IN (#{sub_sql})").distinct
      instrument_strategy(:combine_relations, tag_tokens: 0, has_relation: rel.present?)
    end
    result
  end
  private_class_method :combine_relations_by_rowid_or_tags

  # Build the SQL predicate and binds to match tokens inside the JSON-array tags column.
  # Returns [sql_fragment, binds]
  # Matches tokens anywhere within tag strings, handling multi-word tags like "Oud BW"
  def self.build_tags_predicate_and_binds(title)
    tokens = extract_tokens(title)
    return ['1=0', []] if tokens.empty?

    # Match each token anywhere within a tag value (between quotes)
    # Patterns:
    #   1. "%\"#{t}%\"%" - token at start of tag
    #   2. "%\" #{t} %" - token in middle (space before)
    #   3. "%\" #{t}\"%" - token at end after space
    #   4. "%\"#{t}.%" - token with dot notation (e.g., "BW.", "C. Civ.")
    ors = tokens.map { '(LOWER(tags) LIKE ? OR LOWER(tags) LIKE ? OR LOWER(tags) LIKE ? OR LOWER(tags) LIKE ?)' }.join(' OR ')
    binds = tokens.flat_map { |t| ["%\"#{t} %", "% #{t} %", "% #{t}\"%", "%\"#{t}.%"] }
    ["(tags IS NOT NULL AND (#{ors}))", binds]
  end
  private_class_method :build_tags_predicate_and_binds

  # Performs an FTS5-backed search against article text and joins back to legislation.
  # Ensures DISTINCT to avoid duplicates when multiple articles match the same law.
  # @private
  def self.by_article_text(scope, title)
    term = normalize_query(title)
    return scope unless valid_query?(term)

    fts_query = build_fts_query(term)
    return by_article_like(scope, term) if fts_query.blank?
    return by_title(scope, title) unless sqlite_adapter?

    result = execute_article_fts_search(scope, fts_query)
    instrument_strategy(:article_fts, title_length: term.length)
    result
  rescue StandardError => e
    Rails.logger.warn("FTS search failed, falling back to article LIKE: #{e.class}: #{e.message}")
    by_article_like(scope, term)
  end

  def self.execute_article_fts_search(scope, fts_query)
    scope
      .joins(<<~SQL.squish)
        INNER JOIN articles
          ON articles.content_numac = legislation.numac
         AND articles.language_id = legislation.language_id
      SQL
      .joins('INNER JOIN articles_fts ON articles_fts.rowid = articles.rowid')
      .where('articles_fts MATCH ?', fts_query)
      .distinct
  end
  private_class_method :by_article_text, :execute_article_fts_search

  # Simple LIKE-based article text search (used for very short queries or as a fallback)
  def self.by_article_like(scope, term)
    like_pattern = "%#{sanitize_sql_like(term)}%"

    result = scope
             .joins(<<~SQL.squish)
               INNER JOIN articles
                 ON articles.content_numac = legislation.numac
                AND articles.language_id = legislation.language_id
             SQL
             .where('LOWER(articles.article_text) LIKE ?', like_pattern)
             .distinct

    instrument_strategy(:article_like, title_length: term.length)
    result
  end
  private_class_method :by_article_like

  # Performs a 3-gram substring search against legislation titles using the
  # auxiliary legislation_title_ngrams index. Verifies with LIKE to avoid false positives.
  # @private
  def self.by_title_ngrams(scope, title)
    term = normalize_query(title)
    return scope.none if term.blank?

    grams = build_ngrams(term)
    return by_title(scope, title) if grams.empty? || !ngram_table_populated?

    execute_title_ngram_search(scope, term, grams, title)
  rescue StandardError => e
    Rails.logger.warn("Title n-gram failed, falling back to title LIKE: #{e.class}: #{e.message}")
    by_title(scope, title)
  end

  def self.ngram_table_populated?
    return true unless sqlite_adapter?

    begin
      total = ActiveRecord::Base.connection.select_value('SELECT COUNT(*) FROM legislation_title_ngrams').to_i
      total.positive?
    rescue StandardError
      false
    end
  end

  def self.execute_title_ngram_search(scope, term, grams, _title)
    like_pattern = "%#{sanitize_sql_like(term)}%"
    result = scope
             .joins('INNER JOIN legislation_title_ngrams ON legislation_title_ngrams.rowid = legislation.rowid')
             .where('legislation_title_ngrams.gram IN (?)', grams)
             .group('legislation.rowid')
             .having('COUNT(DISTINCT legislation_title_ngrams.gram) >= ?', grams.size)
             .where('LOWER(title) LIKE ?', like_pattern)
             .distinct

    instrument_strategy(:title_ngrams, title_length: term.length, token_count: grams.size)
    result
  end
  private_class_method :by_title_ngrams, :ngram_table_populated?, :execute_title_ngram_search

  # Performs a 3-gram substring search against article text using the
  # auxiliary articles_text_ngrams index. Verifies with LIKE to avoid false positives.
  # @private
  def self.by_article_ngrams(scope, title)
    term = normalize_query(title)
    return scope.none if term.blank?

    grams = build_ngrams(term)
    return by_article_text(scope, title) if grams.empty?

    execute_article_ngram_search(scope, term, grams, title)
  rescue StandardError => e
    Rails.logger.warn("Article n-gram failed, falling back to FTS/LIKE: #{e.class}: #{e.message}")
    by_article_text(scope, title)
  end

  def self.execute_article_ngram_search(scope, term, grams, _title)
    like_pattern = "%#{sanitize_sql_like(term)}%"
    result = scope
             .joins(<<~SQL.squish)
               INNER JOIN articles
                 ON articles.content_numac = legislation.numac
                AND articles.language_id = legislation.language_id
             SQL
             .joins('INNER JOIN articles_text_ngrams ON articles_text_ngrams.rowid = articles.rowid')
             .where('articles_text_ngrams.gram IN (?)', grams)
             .group('articles.rowid')
             .having('COUNT(DISTINCT articles_text_ngrams.gram) >= ?', grams.size)
             .where('LOWER(articles.article_text) LIKE ?', like_pattern)
             .distinct

    instrument_strategy(:article_ngrams, title_length: term.length, token_count: grams.size)
    result
  end
  private_class_method :by_article_ngrams, :execute_article_ngram_search

  # Performs an FTS5-backed search against legislation titles.
  # Joins the external-content FTS table (legislation_fts) to filter the Legislation scope.
  # Falls back to LIKE on any error or when query invalid.
  # @private
  def self.by_title_fts(scope, title)
    term = normalize_query(title)
    return scope unless valid_query?(term)

    fts_query = build_fts_query(term)
    return scope.none if fts_query.blank?

    # Only attempt on SQLite
    return by_title(scope, title) unless sqlite_adapter?

    result = scope
             .joins('INNER JOIN legislation_fts ON legislation_fts.rowid = legislation.rowid')
             .where('legislation_fts MATCH ?', fts_query)
             .distinct

    instrument_strategy(:title_fts, title_length: term.length)
    result
  rescue StandardError => e
    Rails.logger.warn("Title FTS failed, falling back to title LIKE: #{e.class}: #{e.message}")
    by_title(scope, title)
  end
  private_class_method :by_title_fts

  # Matches query tokens against the JSON-array `tags` column (stored as TEXT).
  # Performs a case-insensitive LIKE search requiring a JSON string boundary (quotes) to limit false positives.
  # Example: query "bw" matches entries where tags contains "BW".
  def self.by_tags(scope, title)
    term = normalize_query(title)
    return scope.none if term.blank?

    tokens = extract_tokens(term)
    return scope.none if tokens.empty?

    # Build OR predicates like: (LOWER(tags) LIKE ? OR LOWER(tags) LIKE ?) OR ...
    ors = tokens.map { '(LOWER(tags) LIKE ? OR LOWER(tags) LIKE ?)' }.join(' OR ')
    binds = tokens.flat_map do |t|
      [
        "%\"#{t}\"%", # exact token within JSON quotes
        "%\"#{t}.%" # dotted continuations inside quotes (e.g., 'c. civ.')
      ]
    end

    result = scope.where.not(tags: nil).where(ors, *binds)
    instrument_strategy(:tags_like, title_length: term.length, token_count: tokens.size)
    result
  end
  private_class_method :by_tags

  # Returns true if we should use FTS (checkbox on and running on SQLite)
  def self.use_fts?(params)
    sqlite_adapter? && params[:search_in_text] == '1'
  end
  private_class_method :use_fts?

  # Returns true if title search should be applied. Defaults to true when param missing.
  def self.search_in_title_on?(params)
    params[:search_in_title] != '0'
  end
  private_class_method :search_in_title_on?

  # Normalize and clamp the query string
  def self.normalize_query(str)
    str.to_s.downcase.strip.gsub(/\s+/, ' ')[0, 100]
  end
  private_class_method :normalize_query

  # Validate query: require minimum length (>= 3) to avoid pathological scans
  def self.valid_query?(str)
    # Allow even very short queries (1–2 chars). Performance is mitigated by
    # preferring n-grams/FTS for >=3 and falling back to LIKE for shorter terms.
    str.present? && str.length >= 1
  end
  private_class_method :valid_query?

  # Build an FTS5 query by tokenizing and AND-ing terms with prefix search
  # Example: "public procurement" => "public* AND procurement*"
  # Allows 2-character tokens for abbreviations like "BW" and single digits for "boek 3"
  def self.build_fts_query(str)
    # Extract tokens that are either 2+ characters or single digits
    tokens = str.scan(/[[:alnum:]]{2,}|\d/)
    return nil if tokens.empty?

    tokens.map { |t| "#{t}*" }.join(' AND ')
  end
  private_class_method :build_fts_query

  # Build unique 3-grams from a normalized string for substring search
  def self.build_ngrams(str, gram_size = 3)
    s = str.to_s
    return [] if s.length < gram_size

    grams = []
    0.upto(s.length - gram_size) { |i| grams << s[i, gram_size] }
    grams.uniq
  end
  private_class_method :build_ngrams

  # Detect if the current adapter is SQLite (required for FTS5)
  def self.sqlite_adapter?
    ActiveRecord::Base.connection.adapter_name.to_s.downcase.start_with?('sqlite')
  end
  private_class_method :sqlite_adapter?

  # Applies sorting to the scope based on the sort parameter
  # @param scope [ActiveRecord::Relation] The current scope to sort
  # @param sort_param [String, nil] The sort parameter (e.g., 'title_asc')
  # @return [ActiveRecord::Relation] The sorted scope
  # @private
  def self.apply_sort(scope, params)
    has_search = params[:title].present?
    
    # Default to relevance when searching, date_desc otherwise
    default = has_search ? 'relevance' : DEFAULT_SORT
    sort_param = params[:sort].presence || default
    
    # Handle relevance sorting specially - score by token matches
    if sort_param == 'relevance'
      return apply_relevance_sort(scope, params)
    end
    
    order_clause = SORT_OPTIONS[sort_param] || SORT_OPTIONS['date_desc']
    scope.order(Arel.sql(order_clause))
  end

  # Sort by relevance: count matching tokens in title, prioritize tag matches, then by date
  def self.apply_relevance_sort(scope, params)
    title = params[:title]
    
    # If no search query, fall back to date desc
    return scope.order(Arel.sql('date DESC')) if title.blank?
    
    term = normalize_query(title)
    tokens = extract_tokens(term)
    
    # If no valid tokens, fall back to date desc
    return scope.order(Arel.sql('date DESC')) if tokens.empty?
    
    # Build relevance score: count how many tokens match in title
    # Higher score = more matches = more relevant
    relevance_parts = tokens.map do |t|
      escaped = t.gsub("'", "''") # Escape single quotes for SQL
      "(CASE WHEN LOWER(title) LIKE '%#{escaped}%' THEN 1 ELSE 0 END)"
    end
    relevance_score = "(#{relevance_parts.join(' + ')})"
    
    # Tag matches get priority (score 0 = has tag match, 1 = no tag match)
    tag_rank = build_tag_rank_clause(tokens)
    
    # Order: tag matches first, then by relevance score (desc), then by date (desc)
    scope.order(Arel.sql("#{tag_rank} ASC, #{relevance_score} DESC, date DESC"))
  end
  private_class_method :apply_sort, :apply_relevance_sort

  # Build a CASE expression that yields 0 when tags contain any of the tokens, else 1
  # Example output:
  #   CASE WHEN (LOWER(tags) LIKE '%"bw"%' OR LOWER(tags) LIKE '%"bw.%' OR ... ) THEN 0 ELSE 1 END
  # Matches tokens anywhere within tag strings, handling multi-word tags like "Oud BW"
  def self.build_tag_rank_clause(tokens)
    # Safe tokens (alnum, dot, hyphen) ensured by the regex in extract_tokens
    ors = tokens.map do |t|
      escaped = t.gsub("'", "''")
      "(LOWER(tags) LIKE '%\"#{escaped} %' OR LOWER(tags) LIKE '% #{escaped} %' OR LOWER(tags) LIKE '% #{escaped}\"%' OR LOWER(tags) LIKE '%\"#{escaped}.%')"
    end.join(' OR ')
    "CASE WHEN (#{ors}) THEN 0 ELSE 1 END"
  end
  private_class_method :build_tag_rank_clause

  # Normalizes tokens shared across search helpers, returning unique lowercase
  # entries of at least two characters, excluding common stop words.
  # Allows abbreviations like "BW", "WVV", "C.", and single-digit numbers for searches like "boek 3"
  def self.extract_tokens(str)
    normalized = normalize_query(str)
    return [] if normalized.blank?

    normalized.scan(/[a-z0-9][a-z0-9.-]{0,15}/i)
              .map(&:downcase)
              .uniq
              .select { |t| t.length >= 2 || t.match?(/^\d$/) } # Keep 2+ chars or single digits
              .reject { |t| STOP_WORDS.include?(t) }
  end
  private_class_method :extract_tokens

  # Expands tokens with bilingual legal synonyms
  # Returns original tokens plus any cross-language equivalents
  # @param tokens [Array<String>] Original search tokens
  # @return [Array<String>] Expanded tokens including synonyms
  def self.expand_with_synonyms(tokens)
    return tokens if tokens.blank?

    expanded = tokens.dup
    tokens.each do |token|
      synonyms = LEGAL_SYNONYMS[token]
      expanded.concat(synonyms) if synonyms
    end
    expanded.uniq
  end
  private_class_method :expand_with_synonyms

  def self.instrument_strategy(strategy, details = {})
    ActiveSupport::Notifications.instrument('wetwijzer.law_search.strategy', { strategy: strategy }.merge(details))
  end
  private_class_method :instrument_strategy

  # Sanitizes SQL LIKE patterns to prevent SQL injection
  # @param str [String] The string to sanitize
  # @return [String] The sanitized string, or empty string if input is nil
  # @private
  def self.sanitize_sql_like(str)
    return '' unless str

    # Use ActiveRecord's sanitize_sql_like if available (Rails 5+)
    if defined?(ActiveRecord::Sanitization) && ActiveRecord::Base.respond_to?(:sanitize_sql_like)
      ActiveRecord::Base.sanitize_sql_like(str)
    else
      # Fallback implementation for older Rails versions
      str.gsub(/[%_]/) { |x| "\\#{x}" }
    end
  end
  private_class_method :sanitize_sql_like
end
# rubocop:enable Metrics/ClassLength
