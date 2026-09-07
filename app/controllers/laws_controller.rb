# frozen_string_literal: true

# == Laws Controller
#
# Handles legislation-related requests including listing and showing laws.
# This controller provides the main functionality for browsing and searching
# through the legal documents in the application.
#
# @example Basic usage
#   # In routes.rb:
#   resources :laws, only: [:index, :show]
#
# @see ApplicationController
# @see Legislation
class LawsController < ApplicationController
  include LawsFiltering
  include LawsExportActions
  include LawsCompareActions

  helper RssHelper

  # Persistent class-level SQLite connections for related sources.
  # Opening multi-GB databases on every request has ~500ms overhead.
  # These persist across requests within the same Puma worker process.
  class << self
    # The one definition of the exdec-mapping cache key. lib/tasks/exdec_cache.rake
    # warms and clears through this too; a second copy of the shape is how a key
    # drifts (the rake task carried the old count-keyed shape for a while and
    # warmed nothing the controller could read). render_code_version stands in
    # for the extraction rules: a data cache gets no template digest, and the
    # helper that builds the mapping is in that file set.
    def article_exdec_mapping_cache_key(numac, exdecs, language_id)
      exdec_sig = CacheVersionHelper.text_cache_version(*exdecs.map { |e| "#{e.id}:#{e.exdec_numac}" })
      ['article_exdec_mapping', CacheVersionHelper.render_code_version, numac, language_id,
       exdec_sig, CacheVersionHelper.laws_db_version].join('/')
    end

    def parliamentary_db(path)
      @_parliamentary_db = nil unless @_parliamentary_db_path == path
      @_parliamentary_db_path = path
      @_parliamentary_db ||= begin
        db = SQLite3::Database.new(path)
        db.busy_timeout = 5000
        db
      end
    rescue SQLite3::Exception => e
      @_parliamentary_db = nil
      raise e
    end

    def jurisprudence_db(path)
      @_jurisprudence_db = nil unless @_jurisprudence_db_path == path
      @_jurisprudence_db_path = path
      @_jurisprudence_db ||= begin
        db = SQLite3::Database.new(path)
        db.busy_timeout = 5000
        db
      end
    rescue SQLite3::Exception => e
      @_jurisprudence_db = nil
      raise e
    end
  end

  # Callbacks
  # Always canonicalize to a URL that includes language_id (host-based default when missing)
  before_action :ensure_language_param, only: %i[show articles article_exdecs related_sources export_word]
  before_action :set_law, only: %i[show articles article_exdecs related_sources export_word]
  before_action :set_law_for_compare, only: %i[compare export_word_compare]
  before_action :set_per_page, only: [:index]
  before_action :set_language_id, only: %i[show articles article_exdecs related_sources export_word]

  # Classic (no-JS) pages and the plain-text format render no CSRF meta tags or
  # forms, so the lazy session middleware emits no per-visitor cookie. They are
  # safe to cache publicly - browsers revisit instantly and a CDN cache rule
  # can absorb bot floods at the edge. Skipped automatically when a
  # before_action halts (e.g. the geo challenge), since after_action callbacks
  # only run for completed chains.
  after_action :set_classic_cache_headers, only: %i[index show]

  # GET /laws
  # GET /laws.json
  # GET /laws.turbo_stream
  #
  # Displays a paginated list of laws with optional filtering and sorting.
  # Supports both HTML and JSON formats, as well as Turbo Stream responses.
  #
  # @example Basic usage
  #   GET /laws
  #   GET /laws?page=2&per_page=25
  #
  # @example With search parameters
  #   GET /laws?title=constitution&sort=title_asc
  #
  # @example With type filters
  #   GET /laws?constitution=1&law=1
  #
  # @example With language filters
  #   GET /laws?lang_nl=1&lang_fr=0
  #
  # @return [void]
  # @note The view uses the 'laws/index' template for HTML and 'laws/_list' partial for Turbo Stream
  # @raise [ArgumentError] if pagination parameters are invalid
  def index
    @title = t(:page_title_home)

    # Map ?q= quick search parameter to the proper :title filter param.
    # Without this, ?q= triggers a turbo frame load of ALL laws (unfiltered).
    if params[:q].present? && params[:title].blank?
      params[:title] = params[:q]
      # Apply locale-based language defaults for quick search
      unless params[:lang_nl].present? || params[:lang_fr].present? || params[:lang_de].present?
        case I18n.locale
        when :fr
          params[:lang_nl] = '0'
          params[:lang_fr] = '1'
          params[:lang_de] = '0'
        when :de
          params[:lang_nl] = '0'
          params[:lang_fr] = '1'
          params[:lang_de] = '0'
        else
          params[:lang_nl] = '1'
          params[:lang_fr] = '0'
          params[:lang_de] = '0'
        end
      end
      # Default search scope: title + tags
      params[:search_in_title] = '1' unless params[:search_in_title].present?
      params[:search_in_tags] = '1' unless params[:search_in_tags].present?
    end

    # Validate and search
    @validation_failed = false
    perform_validation if filters_submitted?
    # Classify searches from the permitted filter contract, not arbitrary
    # query-string metadata.
    @search_requested = search_query_present? || filters_submitted?

    search_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    run_search_if_needed
    search_duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - search_start

    if search_duration > 15
      Rails.logger.warn("[SLOW PAGINATION] #{search_duration.round(2)}s - page=#{params[:page]} query=#{params[:title].inspect} per_page=#{@per_page} host=#{request.host}")
    end

    respond_to_request
  end

  # GET /bookmarks
  #
  # Displays the bookmarks page. Bookmarks are stored client-side in localStorage,
  # so this action only renders the view template with no server-side data loading.
  #
  # @return [void]
  def bookmarks
    @title = t('bookmarks.title')
  end

  # GET /laws/:numac
  # GET /laws/:numac.json
  #
  # Displays detailed information about a specific law identified by its Numac ID.
  # Also loads related content, updated laws, executive decisions, and articles.
  #
  # @example
  #   GET /laws/123456789
  #   GET /laws/123456789.json
  #
  # @return [void]
  # @note The view uses the 'laws/show' template
  # @raise [ActiveRecord::RecordNotFound] if the law is not found
  def show
    @title = @law.present? ? helpers.print_multiline(@law.title, skip_paragraphs: true) : t(:details).capitalize

    # SEO: Set canonical URL explicitly to include language_id.
    # Without this, the layout's fallback (request URL minus query params) would strip
    # language_id, making Google see NL and FR versions as duplicates of the same URL.
    @canonical_url = "https://#{request.host}/laws/#{params[:numac]}?language_id=#{@language_id}"

    # Load related data in a single query where possible
    # Skip for FisconetPlus articles - they use an OpenStruct, not ActiveRecord
    load_related_data unless @is_fisconet
  end

  # GET /laws/:numac/articles
  #
  # Renders only the articles section for lazy-loading via Turbo Frames.
  # Returns the existing partial with the same locals used by 'show'.
  # Also builds mapping of articles to executive decisions that reference them.
  #
  # @return [void]
  def articles
    load_articles_data
    set_view_preferences

    # HTTP caching: browser/proxy cache for 1 hour, ETag for 304 Not Modified.
    # The ETag carries the article digest, not the article count: a repair or a
    # consolidation that rewrites text without changing the number of rows must
    # produce a new body, or browsers holding the old one revalidate to 304 and
    # keep it. Same reason the fragment key below is content-keyed.
    expires_in 1.hour, public: true
    return unless stale?(etag: ['law_articles_v3', params[:numac], @language_id, @articles_digest,
                                @exdec_count.to_i, CacheVersionHelper.laws_links_version,
                                # the abolished / no-articles branch renders these from the law row
                                CacheVersionHelper.text_cache_version(@law&.justel, @law&.is_abolished, @law&.repeal_info)])

    render :articles, layout: false
  end

  # GET /laws/:numac/related_sources
  #
  # Lazy-loaded endpoint for related parliamentary docs and jurisprudence.
  # Called via AJAX when the user clicks "Load" buttons in the show page.
  # Supports ?type=parliamentary or ?type=jurisprudence for independent loading.
  # These queries open 8.5GB + 1.8GB SQLite databases, so we avoid loading them
  # eagerly on every page view.
  #
  # @return [HTML] Rendered partial
  def related_sources
    # For Fisconet laws, use numac_real to look up Justel-linked sources
    lookup_numac = @is_fisconet && @law.numac_real.present? ? @law.numac_real : params[:numac]

    # Bound params[:type] to the known set BEFORE it enters the cache key —
    # otherwise ?type=<random> is an always-miss key that runs the expensive
    # else-branch every time and grows the file_store cache unbounded (cache-bust DoS).
    type = %w[parliamentary jurisprudence].include?(params[:type]) ? params[:type] : 'all'

    # Cache related sources HTML for 1 hour – the underlying jurisprudence LIKE query
    # on the 6.2GB database takes ~1.3s per call in the Ruby SQLite3 gem.
    cache_key = "related-sources-v1/#{lookup_numac}/#{type}/#{@language_id}"

    cached = Rails.cache.read(cache_key)
    if cached
      render html: cached.html_safe, layout: false
      return
    end

    empty_result = { items: [], total_count: 0 }
    parl_result =
      type == 'jurisprudence' ? empty_result : load_related_parliamentary(lookup_numac)
    juris_result =
      type == 'parliamentary' ? empty_result : load_related_jurisprudence(lookup_numac)

    html = render_to_string partial: 'related_sources_content',
                            locals: {
                              law: @law,
                              type: type,
                              lookup_numac: lookup_numac,
                              related_parliamentary: parl_result[:items],
                              parliamentary_total: parl_result[:total_count],
                              related_jurisprudence: juris_result[:items],
                              jurisprudence_total: juris_result[:total_count]
                            },
                            layout: false

    Rails.cache.write(cache_key, html, expires_in: 1.hour)
    render html: html.html_safe, layout: false
  end

  # GET /laws/:numac/article_exdecs
  #
  # Returns article-exdec mapping as JSON for client-side injection.
  # Used to load exdec references without re-rendering all articles.
  #
  # @return [JSON] Mapping data and rendered HTML for each article's exdecs
  def article_exdecs
    # set_language_id must be called before load_exdecs_for_articles
    # (it uses @language_id internally)
    set_view_preferences
    @show_exdecs = true # Force show exdecs for this endpoint

    # load_exdecs_for_articles already builds @executive_legislations_cache
    @exdecs = load_exdecs_for_articles

    # Build the mapping with caching for performance
    begin
      @article_exdec_mapping = build_cached_article_exdec_mapping(params[:numac], @exdecs, @language_id)

      # For each article that has exdecs, render its exdec section as HTML
      exdec_html = {}
      @article_exdec_mapping.each do |article_id, related_exdecs|
        exdec_html[article_id] = render_to_string(
          partial: 'laws/article_exdec_section',
          locals: {
            article_id: article_id,
            related_exdecs: related_exdecs,
            executive_legislations_cache: @executive_legislations_cache,
            language_id: @language_id
          },
          layout: false,
          formats: [:html]
        )
      end

      render json: {
        success: true,
        count: @article_exdec_mapping.size,
        exdec_html: exdec_html
      }
    rescue StandardError => e
      Rails.logger.error("Failed to build article-exdec mapping for #{params[:numac]}: #{e.message}")
      Rails.logger.error(e.backtrace.first(10).join("\n"))
      render json: { success: false, error: 'Internal server error' }, status: :internal_server_error
    end
  end

  # export_word, export_word_compare, compare are provided by LawsExportActions and LawsCompareActions concerns

  def load_articles_data
    @content = Content.includes(:legislation).find_by(language_id: @language_id, legislation_numac: params[:numac])
    # Materialize with .to_a to prevent re-querying on each iteration in the view
    # (the view iterates articles 3+ times: references check, doc number prefetch, main render loop)
    @articles = Article.where(language_id: @language_id, content_numac: params[:numac]).order(:id).to_a
    # Content signal for the fragment cache and the ETag, computed once here
    # because the rows are in memory anyway (see CacheVersionHelper).
    @articles_digest = CacheVersionHelper.rows_cache_version(@articles)

    # Never load exdecs by default - always require explicit user action via AJAX
    # This keeps the interface clean and avoids heavy processing on page load
    force_load = params[:show_article_exdecs] == 'true'

    if force_load
      # User explicitly requested exdecs via old-style Turbo Frame reload
      # (Kept for backwards compatibility, but AJAX endpoint is preferred)
      @exdecs = load_exdecs_for_articles
      begin
        Rails.logger.debug { "Force-loading article-exdec mapping for #{params[:numac]} via Turbo Frame" }
        @article_exdec_mapping = build_cached_article_exdec_mapping(params[:numac], @exdecs, @language_id)

        Rails.logger.debug { "Article-exdec mapping loaded with #{@article_exdec_mapping.size} referenced articles" } if @article_exdec_mapping.present?
      rescue StandardError => e
        # Log error but don't break the page
        Rails.logger.error("Failed to build article-exdec mapping for #{params[:numac]}: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        @article_exdec_mapping = {}
        @article_exdecs_disabled = true
        @article_exdecs_error = true
      end
    else
      # Default: Skip the heavy exdec query + executive_legislations_cache entirely.
      # Only fetch a lightweight count so the UI indicator knows whether to show "Toch laden".
      @exdec_count = Exdec.where(language_id: @language_id, content_numac: params[:numac]).count
      @exdecs = []
      @article_exdec_mapping = {}
      @article_exdecs_disabled = true
      @executive_legislations_cache = {}
      Rails.logger.debug { "Article-exdec mapping disabled by default for #{params[:numac]} (#{@exdec_count} exdecs, skipped loading)" }
    end
  end

  def load_exdecs_for_articles
    exdecs = Exdec.where(language_id: @language_id, content_numac: params[:numac])
                  .order(:id)
                  .to_a

    # Build cache for executive legislations
    @executive_legislations_cache = build_executive_legislations_cache(exdecs)

    exdecs
  end

  # Build a cache of executive legislations to prevent N+1 queries
  def build_executive_legislations_cache(exdecs)
    exdec_numacs = exdecs.map(&:exdec_numac).compact.uniq
    return {} if exdec_numacs.empty?

    Legislation
      .where(numac: exdec_numacs, language_id: @language_id)
      .index_by(&:numac)
  end

  def set_view_preferences
    @show_colors = params[:show_colors] != 'false'
    @show_exdecs = params[:show_exdecs] != 'false'
  end

  # Build article-exdec mapping with Rails caching for performance
  # Cache expires after 7 days. The key is content-keyed, not count-keyed:
  #   - exdec_sig: the parent's exdec rows (loaded already), so a re-import that
  #     swaps one exdec for another at the same count is seen;
  #   - render_code_version: the extraction rules, which a data cache does not
  #     get a template digest for;
  #   - laws_db_version: the exdec laws' own articles are what the mapping is
  #     built FROM and are not loaded here, so the corpus stamp stands in for
  #     them. It moves at checkpoint after each corpus write, so the mapping is
  #     rebuilt at most once per write burst per law, on the next explicit load.
  def build_cached_article_exdec_mapping(numac, exdecs, language_id)
    cache_key = self.class.article_exdec_mapping_cache_key(numac, exdecs, language_id)

    start_fetch = Time.current
    mapping = Rails.cache.fetch(cache_key, expires_in: 7.days) do
      start_build = Time.current
      result = helpers.build_article_exdec_mapping(numac, exdecs, language_id)
      build_duration = Time.current - start_build

      Rails.logger.info("[EXDEC CACHE MISS] Built mapping for #{numac} in #{build_duration.round(2)}s (#{result.size} articles, #{exdecs.size} exdecs)")
      result
    end

    fetch_duration = Time.current - start_fetch
    if fetch_duration < 0.1
      Rails.logger.info("[EXDEC CACHE HIT] Retrieved mapping for #{numac} in #{(fetch_duration * 1000).round(0)}ms (#{mapping.size} articles)")
    end

    mapping
  end

  # compare is provided by LawsCompareActions concern

  # Ensures the URL includes a language_id. If missing, 301-redirect to the same
  # route with the default language for the current host/locale (nl for WetWijzer,
  # fr for Lisloi). This provides canonical URLs like /laws/:numac?language_id=1|2.
  # Uses 301 (permanent) so Google drops the bare URL from its index.
  # For Turbo Frame requests (like articles endpoint), sets default instead of redirecting.
  def ensure_language_param
    # language_id=3 is reserved for a future provenance-checked German corpus.
    # Retire old links to the invalid French-as-German import by canonicalizing
    # them to the French source text used by the German UI.
    if params[:language_id].to_s == '3'
      if turbo_frame_request? || action_name.in?(%w[articles related_sources])
        params[:language_id] = 2
      else
        redirect_to_canonical_with_language(2)
      end
      return
    end

    return if params[:language_id].present?

    lang_id = current_language_id

    if turbo_frame_request? || action_name.in?(%w[articles related_sources])
      params[:language_id] = lang_id
    else
      redirect_to_canonical_with_language(lang_id)
    end
  end

  # See the after_action declaration for the safety argument.
  def set_classic_cache_headers
    return unless request.get? && response.successful?
    return unless classic_host? || request.format.text?

    expires_in(action_name == 'show' ? 6.hours : 30.minutes, public: true)
  end

  def redirect_to_canonical_with_language(lang_id)
    qp = request.query_parameters.merge(language_id: lang_id)
    # Carry the format only when the request named one explicitly
    # (/laws/x.json). request.format.symbol is :html even for a bare request,
    # and passing it made every canonical redirect append '.html' - the
    # opposite of canonical.
    target = url_for(
      only_path: true,
      controller: controller_name,
      action: action_name,
      numac: params[:numac],
      **qp,
      format: params[:format]
    )
    redirect_to(target, allow_other_host: false, status: :moved_permanently)
  end

  # Sets the @law instance variable based on the Numac parameter
  # Handles both Justel laws and FisconetPlus legislation
  # @return [void]
  # @raise [ActiveRecord::RecordNotFound] if the law is not found
  def set_law
    numac = params[:numac]

    if FisconetSearchService.fisconet_numac?(numac)
      set_fisconet_law(numac)
    else
      # language_id is guaranteed by ensure_language_param
      @law = Legislation.find_by!(numac: numac, language_id: params[:language_id])
    end
  rescue ActiveRecord::RecordNotFound
    # Handle case when law is not found - return 404 instead of redirect
    respond_to do |format|
      format.html { render file: Rails.root.join('public', '404.html'), status: :not_found, layout: false }
      format.json { head :not_found }
    end
  end

  # Loads a Fisconet legislation with all its articles and metadata
  def set_fisconet_law(numac)
    legislation_id = FisconetSearchService.legislation_id_from_numac(numac)
    lang_id = params[:language_id].to_i
    lang_id = 1 unless [1, 2].include?(lang_id)

    info = FisconetSearchService.legislation_info(legislation_id)
    raise ActiveRecord::RecordNotFound unless info

    @is_fisconet = true
    @fisconet_info = info
    raw_articles = FisconetSearchService.all_articles(legislation_id: legislation_id, language_id: lang_id)

    # Filter out garbage articles (TOC lines, too-short content, URL artifacts)
    @fisconet_articles = raw_articles.select do |art|
      text = art[:text].to_s.strip
      html = art[:html].to_s.strip
      content_length = [text.length, html.length].max
      # The 100-char floor removes TOC lines and extraction debris, but it
      # cannot be applied to rate-table entries: those name a good or service
      # and are legitimately short. It was hiding two real VAT provisions -
      # KB 20 Table A XIII "Waterdistributie" (96 chars, water supply at 6%)
      # and Table B VI "Margarine" (30 chars, at 12%).
      #
      # Only annexes are exempted. The 8 other sub-100 rows are W.Reg articles
      # reading "(niet meer van toepassing)", which SHOULD stay hidden, and
      # they are article-typed. PDF containers cannot come back in through
      # this door either - all_articles already excludes them in SQL.
      next false if content_length < 100 && art[:article_type].to_s != 'annex'
      next false if text.match?(/\.{10,}\s*\d+/) # TOC dotted leaders
      next false if text.match?(/^Art\.?\s*\d+\s*\.{5,}/) # "Art. 13 ....... 96"
      next false if text.include?('www.fisconetplus.be') && content_length < 400

      true
    end

    doc_type = info[:document_type] || 'WIB 92'
    title = lang_id == 2 ? (info[:title_fr] || info[:title_nl]) : (info[:title_nl] || info[:title_fr])
    short_name = lang_id == 2 && doc_type == 'WIB 92' ? 'CIR 92' : doc_type

    # The walk corpus carries neither date, so these are usually nil. Parsing
    # the empty string raised "invalid date" and logged it as "Query failed"
    # twice per tax-code page view (74 times a day) for what is simply an
    # absent value.
    pub_date = FisconetSearchService.parse_date_safe(info[:publication_date])
    eff_date = FisconetSearchService.parse_date_safe(info[:effective_date])

    @law = OpenStruct.new(
      numac: numac,
      language_id: lang_id,
      title: title,
      document_type: short_name,
      date: pub_date,
      effective_date: eff_date,
      last_modified: info[:last_modified],
      is_abolished: !info[:is_in_force],
      is_fisconet: true,
      source_url: info[:source_url],
      category: info[:category],
      is_in_force: info[:is_in_force],
      is_consolidated: info[:is_consolidated],
      numac_real: info[:numac_real],
      article_count: info[:article_count]
    )
  end

  # Sets the @law instance variable for compare action (doesn't require language_id)
  # Finds any version of the law by numac
  # @return [void]
  def set_law_for_compare
    @law = Legislation.find_by(numac: params[:numac])
    return if @law

    render file: Rails.root.join('public', '404.html'), status: :not_found, layout: false
  end

  # Sets the @language_id instance variable based on the resolved law
  # @return [void]
  def set_language_id
    # Use the language of the resolved law for all related queries
    @language_id = @law.language_id
  end

  # Loads all data related to the current law
  # @return [void]
  def load_related_data
    # Content record (no need to eager-load :legislation – @law is already set by set_law)
    @content = Content.find_by(language_id: @language_id, legislation_numac: params[:numac])

    # Use scopes for better query organization
    @updated_laws = load_updated_laws
    @exdecs = load_executive_decisions

    # Articles: loaded lazily via Turbo Frame normally, eagerly in classic
    # mode and for the plain-text (curl) format
    if classic_host? || request.format.text?
      @articles = load_articles
    else
      @articles = []
      # Lightweight COUNT for estimated load time in the skeleton UI
      @article_count = Article.where(language_id: @language_id, content_numac: params[:numac]).count
      @estimated_load_seconds = estimate_article_load_time(@article_count)
    end

    # Parliamentary docs and jurisprudence are loaded on-demand via button click
    @related_parliamentary = []
    @related_jurisprudence = []
  end

  # Loads updated laws for the current law
  # @return [ActiveRecord::Relation] Collection of updated laws
  def load_updated_laws
    UpdatedLaw
      .includes(:updating_legislation)
      .where(language_id: @language_id, content_numac: params[:numac])
      .order(:id)
  end

  # Loads executive decisions for the current law
  # @return [Array] Collection of executive decisions
  def load_executive_decisions
    exdecs = Exdec
             .includes(:executive_legislation)
             .where(language_id: @language_id, content_numac: params[:numac])
             .order(:id)
             .to_a

    # Build cache for executive legislations (prevents N+1 queries in _exdecs partial)
    @executive_legislations_cache = build_executive_legislations_cache(exdecs)

    exdecs
  end

  # Loads articles for the current law
  # @return [Array] Collection of articles (materialized for multiple iterations in TOC/view)
  def load_articles
    Article
      .where(language_id: @language_id, content_numac: params[:numac])
      .order(:id)
      .to_a
  end

  # Estimates article turbo-frame load time based on article count.
  # Empirical: 599 articles ≈ 6s on Hetzner ARM64 (≈0.01s/article + 1s base overhead).
  # Returns nil for small laws where loading is near-instant.
  # @param count [Integer] number of articles
  # @return [Integer, nil] estimated seconds, or nil if <2s
  def estimate_article_load_time(count)
    return nil if count < 100

    estimated = (1 + (count * 0.01)).round
    estimated < 2 ? nil : [estimated, 120].min
  end

  # Loads related parliamentary documents for the current law
  # @return [Array] Collection of parliamentary documents
  def load_related_parliamentary(numac = nil)
    numac ||= params[:numac]
    return { items: [], total_count: 0 } unless defined?(SQLite3)

    items = []
    total = 0

    # 1. Federal parliament (chamber.sqlite3)
    db_path = ENV.fetch('CHAMBER_DB') { Rails.root.join('storage', 'chamber.sqlite3').to_s }
    if File.exist?(db_path)
      begin
        db = self.class.parliamentary_db(db_path)

        # Strategy: use pre-computed parliamentary_refs column → numac match → dossier summary
        # Phase A: direct numac match (fastest path, covers 66.5% of docs)
        total += db.execute('SELECT COUNT(*) FROM documents WHERE legislation_numac = ?', [numac]).first&.first || 0
        rows = db.execute(
          'SELECT id, parliament, dossier_number, document_number, title, document_type FROM documents WHERE legislation_numac = ? LIMIT 10',
          [numac]
        )
        items += rows.map { |r| { id: r[0], parliament: r[1], dossier_number: r[2], document_number: r[3], title: r[4], document_type: r[5] } }

        # Phase B: use pre-computed parliamentary_refs from legislation table (covers remaining docs)
        if items.empty?
          leg = Legislation.find_by(numac: numac)
          parl_refs = begin
            JSON.parse(leg&.parliamentary_refs || '[]')
          rescue JSON::ParserError
            []
          end

          # Extract Kamer (K:) refs – format "K:55-3213"
          kamer_refs = parl_refs.select { |r| r.start_with?('K:') }.map { |r| r.sub('K:', '') }
          kamer_refs.each do |ref|
            match = ref.match(/^(\d+)-(.+)$/)
            next unless match

            legislature = match[1]
            dossier_id = match[2]
            padded = dossier_id.to_s.rjust(4, '0')
            dossier_variants = [dossier_id.to_s, padded].uniq
            placeholders = dossier_variants.map { '?' }.join(', ')

            dossier_total = db.execute(
              "SELECT COUNT(*) FROM documents WHERE dossier_number IN (#{placeholders}) AND legislature = ?",
              dossier_variants + [legislature]
            ).first&.first || 0
            total += dossier_total

            if dossier_total.positive?
              dossier_rows = db.execute(
                "SELECT id, parliament, dossier_number, document_number, title, document_type FROM documents WHERE dossier_number IN (#{placeholders}) AND legislature = ? LIMIT 10",
                dossier_variants + [legislature]
              )
              items += dossier_rows.map { |r| { id: r[0], parliament: r[1] || 'KAMER', dossier_number: r[2], document_number: r[3], title: r[4], document_type: r[5] } }
            else
              # No documents scraped yet – show dossier summary from dossiers table
              dossier_row = db.execute(
                'SELECT id, titel, type, status, dossier_url FROM dossiers WHERE nummer = ? AND legislature = ? LIMIT 1',
                [dossier_id, legislature]
              ).first
              if dossier_row
                items << {
                  id: dossier_row[0], parliament: 'KAMER', dossier_number: "#{legislature}-#{dossier_id}",
                  document_number: "#{legislature}-#{dossier_id}", title: dossier_row[1],
                  document_type: dossier_row[2], dossier_url: dossier_row[4], source: :dossier_summary
                }
                total += 1
              end
            end
          end
        end
      rescue StandardError => e
        Rails.logger.warn "Failed to load federal parliamentary docs: #{e.message}"
      end
    end

    # 2. Vlaamse Parlement (vlaamse_codex.sqlite3) – decreten, besluiten, verslagen
    vlpar_path = Rails.root.join('storage', 'vlaamse_codex.sqlite3').to_s
    if File.exist?(vlpar_path)
      begin
        vlpar_db = SQLite3::Database.new(vlpar_path)
        vlpar_db.busy_timeout = 5000
        vlpar_total = vlpar_db.execute('SELECT COUNT(*) FROM documents WHERE numac = ?', [numac]).first&.first || 0
        total += vlpar_total
        vlpar_rows = vlpar_db.execute(
          'SELECT id, titel, document_type, nummer, zittingsjaar, pdf_url FROM documents WHERE numac = ? LIMIT 10',
          [numac]
        )
        items += vlpar_rows.map do |r|
          {
            id: r[0],
            parliament: 'VLPAR',
            dossier_number: "#{r[4]} nr. #{r[3]}",
            document_number: r[3].to_s,
            title: r[1],
            document_type: r[2],
            pdf_url: r[5],
            source: :vlaamse_codex
          }
        end
        vlpar_db.close
      rescue StandardError => e
        Rails.logger.warn "Failed to load Vlaamse parliamentary docs: #{e.message}"
      end
    end

    # Senate documents come from chamber.sqlite3, read by source 1 above:
    # scrape_senate.py writes there (`--db storage/chamber.sqlite3`), and that
    # store holds 25,799 senate documents of which 14,377 carry a numac.
    #
    # There used to be a third source here reading storage/senate.sqlite3. That
    # file is a legacy copy frozen at 2026-05-21: 1,938 documents, every one of
    # them a subset of chamber.sqlite3, and NONE with a legislation_numac - so
    # the `WHERE legislation_numac = ?` lookup it performed could never match.
    # Every law page paid for opening a dead SQLite file and querying it twice
    # to get nothing, and had anyone ever backfilled numacs into it the page
    # would have started showing duplicate, months-stale entries. Removed
    # 2026-09-06.

    { items: items, total_count: total }
  end

  # Loads related jurisprudence for the current law (cases that reference this law)
  # Uses pre-computed jurisprudence_refs JSON. Request-time scans of the
  # multi-gigabyte jurisprudence database are intentionally forbidden.
  # @return [Hash] { items: [...], total_count: N }
  def load_related_jurisprudence(numac = nil)
    numac = numac.presence || params[:numac].to_s
    return { items: [], total_count: 0 } if numac.blank?

    # 1) Try pre-computed refs from legislation table (instant, no external DB)
    begin
      law = Legislation.find_by(numac: numac)
      if law.respond_to?(:jurisprudence_refs) && law.jurisprudence_refs.present?
        parsed = begin
          JSON.parse(law.jurisprudence_refs)
        rescue StandardError => e
          Rails.logger.warn("[Laws] JSON parse failed: #{e.message}")
          nil
        end

        if parsed
          # Support both formats: {total, cases} (new) and flat array (legacy)
          if parsed.is_a?(Hash) && parsed['cases']
            cases_list = parsed['cases']
            total = parsed['total'] || cases_list.size
          elsif parsed.is_a?(Array)
            cases_list = parsed
            total = cases_list.size
          end

          if cases_list&.any?
            items = cases_list.first(10).map do |r|
              {
                id: nil,
                case_number: r['ecli'],
                court: r['court'],
                decision_date: r['date'],
                subject_matter: nil
              }
            end
            return { items: items, total_count: total }
          end
        end
      end
    rescue StandardError => e
      Rails.logger.debug "jurisprudence_refs lookup failed: #{e.message}"
    end

    # Never fall back to `LIKE '%NUMAC%'` on the multi-gigabyte jurisprudence
    # database in a web request. That unindexed native SQLite scan repeatedly
    # occupied a Puma worker past its 120-second watchdog. The linkage job owns
    # population of `jurisprudence_refs`; an absent precomputed value means no
    # related cases are shown until that job has produced safe indexed evidence.
    Rails.logger.debug(
      "No precomputed jurisprudence_refs for legislation #{numac}"
    )
    { items: [], total_count: 0 }
  end

  # Loads recent jurisprudence for the RSS feed
  # @param lang_id [Integer] 1=NL, 2=FR
  # @param limit [Integer] Max items
  # @return [Array<Hash>] Recent court cases
  def load_rss_jurisprudence(lang_id, limit)
    db_path = ENV.fetch('JURISPRUDENCE_SOURCE_DB') { Rails.root.join('storage', 'jurisprudence.db').to_s }
    return [] unless File.exist?(db_path)

    db = self.class.jurisprudence_db(db_path)
    db_lang_id = lang_id.to_s
    rows = db.execute(
      'SELECT id, case_number, court, decision_date, summary FROM cases WHERE language_id = ? ORDER BY decision_date DESC LIMIT ?',
      [db_lang_id, limit]
    )
    rows.map do |r|
      {
        id: r[0], case_number: r[1], court: r[2], decision_date: r[3],
        summary: r[4].to_s.truncate(300), source: :jurisprudence
      }
    end
  rescue StandardError => e
    Rails.logger.warn "RSS jurisprudence load failed: #{e.message}"
    []
  end

  # Loads recent parliamentary documents for the RSS feed
  # @param limit [Integer] Max items
  # @return [Array<Hash>] Recent parliamentary documents
  def load_rss_parliamentary(limit)
    db_path = ENV.fetch('CHAMBER_DB') { Rails.root.join('storage', 'chamber.sqlite3').to_s }
    return [] unless File.exist?(db_path)

    db = self.class.parliamentary_db(db_path)
    lang = I18n.locale == :nl ? 'nl' : 'fr'
    rows = db.execute(
      'SELECT id, title, parliament, dossier_number, document_date, document_type FROM documents WHERE language = ? ORDER BY id DESC LIMIT ?',
      [lang, limit]
    )
    rows.map do |r|
      {
        id: r[0], title: r[1], parliament: r[2], dossier_number: r[3],
        document_date: r[4], document_type: r[5], source: :parliamentary
      }
    end
  rescue StandardError => e
    Rails.logger.warn "RSS parliamentary load failed: #{e.message}"
    []
  end

  # Handles the response based on the request format
  # @return [void]
  def respond_to_request
    # Also support a fallback query param `frame=1` in case the Turbo-Frame
    # request header is stripped by proxies or not detected in some environments.
    if turbo_frame_request? || params[:frame].present?
      # Respond with a template that wraps the list in <turbo-frame id="laws_list">
      render :list, layout: false
    else
      respond_to do |format|
        format.html
        format.text # curl-friendly plain text (index.text.erb)
        format.json { render :index, status: :ok }
        format.rss do
          # HTTP caching: let browsers/feed readers/CDNs cache for 1 hour
          expires_in 1.hour, public: true

          lang_id = current_language_id

          # Cache the entire rendered RSS XML for 1 hour server-side.
          # Key includes locale + type filters for per-feed caching. The
          # rendered body must depend on nothing else: the builder's channel
          # links and the helper's title are built from @rss_feed_params
          # (the type flags), never from request.query_parameters, or one
          # requester's ?q= text lands in every reader's feed for the hour.
          @rss_feed_params = search_params.to_h.select { |_, v| v == '1' }
          type_filter_key = @rss_feed_params.keys.sort.join('-').presence || 'all'
          cache_key = "rss_feed/v4/#{lang_id}/#{type_filter_key}"

          cached_xml = Rails.cache.fetch(cache_key, expires_in: 1.hour) do
            # --- Legislation (20 items) ---
            rss_scope = Legislation.includes(:type)
                                   .where(language_id: lang_id)
                                   .where.not(date: ['N/A', '', nil])
            type_ids = LawSearchService.send(:type_ids_from_params, search_params.to_h.with_indifferent_access)
            rss_scope = rss_scope.where(law_type_id: type_ids) if type_ids.any?
            @laws = rss_scope.order(date: :desc).limit(20)

            # --- Jurisprudence (10 items, for logged-in users via RSS) ---
            @rss_jurisprudence = load_rss_jurisprudence(lang_id, 10)

            # --- Parliamentary work (15 items) ---
            @rss_parliamentary = load_rss_parliamentary(15)

            render_to_string(layout: false, formats: [:rss])
          end

          render plain: cached_xml, content_type: 'application/rss+xml; charset=utf-8'
        end
        format.turbo_stream { redirect_to laws_path(format: :html), status: :see_other }
      end
    end
  end

  # Sets the number of items per page for pagination.
  # Validates and clamps the value between 1 and 500, with a default of 50.
  #
  # @return [void]
  # @note The maximum number of items per page is limited to 500 for performance reasons
  def set_per_page
    # Support both per_page and limit as aliases (e.g., from API-like callers)
    raw = params[:per_page].presence || params[:limit].presence

    # Classic mode: always 100 results/page (50 pages × 100 = 5,000 laws browsable)
    # Modern mode: user-configurable, default 50
    default = classic_host? ? 100 : 50
    @per_page = raw ? raw.to_i : default
    @per_page = default if @per_page <= 0 # Invalid values use default
    @per_page = @per_page.clamp(1, 500)
  end

  # Defines the permitted parameters for searching and filtering laws.
  #
  # @return [ActionController::Parameters] The permitted parameters
  # @note This method is used by the index action to filter and sort laws
  # Whitelists permitted search parameters
  # @return [ActionController::Parameters]
  # Params include: title, sort, pagination (per_page/limit/page), view flags (frame),
  # presence markers (types_present, languages_present, scope_present), commit button,
  # search scope toggles (search_in_title, search_in_tags, search_in_text, prioritize_tags),
  # type filters (constitution, law, decree, ordinance, decision, misc),
  # language filters (lang_nl, lang_fr),
  # advanced filters (date_from, date_to, numac)
  # Detect common crawlers to skip expensive queries for non-human traffic
  BOT_UA_PATTERN = /bot|crawl|spider|googlebot|bingbot|slurp|duckduck|baidu|yandex|sogou|semrush|ahref|mj12bot|dotbot|petalbot|bytespider|gptbot|facebookexternal|twitterbot|linkedinbot|preview/i
  private_constant :BOT_UA_PATTERN

  def bot_request?
    ua = request.user_agent.to_s
    ua.blank? || ua.match?(BOT_UA_PATTERN)
  end

  def search_params
    params.permit(:title, :sort, :per_page, :limit, :page, :frame,
                  :types_present, :languages_present, :scope_present, :commit,
                  :search_in_title, :search_in_tags, :search_in_text, :prioritize_tags, :search_mode,
                  :constitution, :law, :decree, :ordinance, :decision, :misc,
                  :lang_nl, :lang_fr, :lang_de, :hide_abolished, :hide_empty, :hide_missing_translation, :hide_german_translation,
                  :date_from, :date_to, :numac,
                  :source_legislation, :source_jurisprudence, :source_parliamentary, :source_fisconet,
                  :juris_court, :juris_year, :juris_lang, :juris_subject, :juris_search_body,
                  :juris_page, :juris_sort, :juris_date_from, :juris_date_to,
                  :parl_parliament, :parl_year, :parl_search_body, :parl_doc_type, :parl_lang,
                  :parl_page, :parl_sort, :parl_date_from, :parl_date_to)
  end
end
