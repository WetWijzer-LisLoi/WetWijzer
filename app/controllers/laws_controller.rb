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

  # Callbacks
  # Always canonicalize to a URL that includes language_id (host-based default when missing)
  before_action :ensure_language_param, only: %i[show articles article_exdecs]
  before_action :set_law, only: %i[show articles article_exdecs]
  before_action :set_per_page, only: [:index]
  before_action :set_language_id, only: %i[show articles article_exdecs]

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
    @title = t(:app_title)

    # Validate and search
    @validation_failed = false
    perform_validation if filters_submitted?
    run_search_if_needed

    respond_to_request
  rescue Pagy::OverflowError
    # Handle pagination overflow by redirecting to the last page
    redirect_to laws_path(page: Pagy::DEFAULT[:last], **search_params), notice: t('pagination.overflow')
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

    # Load related data in a single query where possible
    load_related_data
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
    render :articles, layout: false
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
      render json: { success: false, error: e.message }, status: :internal_server_error
    end
  end

  def load_articles_data
    @content = Content.includes(:legislation).find_by(language_id: @language_id, legislation_numac: params[:numac])
    @articles = Article.where(language_id: @language_id, content_numac: params[:numac]).order(:id)
    @exdecs = load_exdecs_for_articles

    # Never load exdecs by default - always require explicit user action via AJAX
    # This keeps the interface clean and avoids heavy processing on page load
    force_load = params[:show_article_exdecs] == 'true'

    if force_load
      # User explicitly requested exdecs via old-style Turbo Frame reload
      # (Kept for backwards compatibility, but AJAX endpoint is preferred)
      begin
        Rails.logger.info("Force-loading article-exdec mapping for #{params[:numac]} via Turbo Frame")
        @article_exdec_mapping = build_cached_article_exdec_mapping(params[:numac], @exdecs, @language_id)

        if @article_exdec_mapping.present?
          Rails.logger.info("Article-exdec mapping loaded with #{@article_exdec_mapping.size} referenced articles")
        end
      rescue StandardError => e
        # Log error but don't break the page
        Rails.logger.error("Failed to build article-exdec mapping for #{params[:numac]}: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        @article_exdec_mapping = {}
        @article_exdecs_disabled = true
        @article_exdecs_error = true
      end
    else
      # Default: Don't load exdecs, show "Toch laden" button instead
      @article_exdec_mapping = {}
      @article_exdecs_disabled = true
      Rails.logger.info("Article-exdec mapping disabled by default for #{params[:numac]} (#{@exdecs.size} exdecs)")
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
    Rails.logger.info("[EXDEC CACHE] Building cache for #{exdec_numacs.size} unique numacs from #{exdecs.size} exdecs")

    if exdec_numacs.any?
      cache = Legislation
              .where(numac: exdec_numacs, language_id: @language_id)
              .index_by(&:numac)

      Rails.logger.info("[EXDEC CACHE] Cache built with #{cache.size} entries")
      Rails.logger.info("[EXDEC CACHE] Sample keys: #{cache.keys.first(5).join(', ')}") if cache.any?
      cache
    else
      Rails.logger.info('[EXDEC CACHE] No numacs to cache, returning empty hash')
      {}
    end
  end

  def set_view_preferences
    @show_colors = params[:show_colors] != 'false'
    @show_exdecs = params[:show_exdecs] != 'false'
  end

  # Build article-exdec mapping with Rails caching for performance
  # Cache key includes numac, language_id, and exdecs count to detect changes
  # Cache expires after 7 days (exdecs change very rarely, monthly updates at most)
  def build_cached_article_exdec_mapping(numac, exdecs, language_id)
    cache_key = "article_exdec_mapping/#{numac}/#{language_id}/#{exdecs.size}"

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

  private

  # Ensures the URL includes a language_id. If missing, redirect to the same
  # route with the default language for the current host/locale (nl for WetWijzer,
  # fr for Lisloi). This provides canonical URLs like /laws/:numac?language_id=1|2.
  # For Turbo Frame requests (like articles endpoint), sets default instead of redirecting.
  def ensure_language_param
    return if params[:language_id].present?

    lang_id = current_language_id

    if turbo_frame_request? || action_name == 'articles'
      params[:language_id] = lang_id
    else
      redirect_to_canonical_with_language(lang_id)
    end
  end

  def redirect_to_canonical_with_language(lang_id)
    qp = request.query_parameters.merge(language_id: lang_id)
    target = url_for(
      only_path: true,
      controller: controller_name,
      action: action_name,
      numac: params[:numac],
      **qp,
      format: request.format.symbol
    )
    redirect_to(target, allow_other_host: false)
  end

  # Sets the @law instance variable based on the Numac parameter
  # @return [void]
  # @raise [ActiveRecord::RecordNotFound] if the law is not found
  def set_law
    # language_id is guaranteed by ensure_language_param
    @law = Legislation.find_by!(numac: params[:numac], language_id: params[:language_id])
  rescue ActiveRecord::RecordNotFound
    # Handle case when law is not found
    respond_to do |format|
      format.html { redirect_to root_path, alert: t('laws.not_found') }
      format.json { head :not_found }
    end
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
    # Use eager loading to prevent N+1 queries
    @content = Content.includes(:legislation).find_by(language_id: @language_id, legislation_numac: params[:numac])

    # Use scopes for better query organization
    @updated_laws = load_updated_laws
    @exdecs = load_executive_decisions
    @articles = load_articles
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
  # @return [ActiveRecord::Relation] Collection of executive decisions
  def load_executive_decisions
    Exdec
      .includes(:executive_legislation)
      .where(language_id: @language_id, content_numac: params[:numac])
      .order(:id)
  end

  # Loads articles for the current law
  # @return [ActiveRecord::Relation] Collection of articles
  def load_articles
    Article
      .where(language_id: @language_id, content_numac: params[:numac])
      .order(:id)
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
        format.json { render :index, status: :ok }
        format.turbo_stream { render partial: 'laws/list', locals: { laws: @laws, pagy: @pagy } }
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
    raw = params[:per_page].presence || params[:limit].presence || 50
    @per_page = raw.to_i
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
  def search_params
    params.permit(:title, :sort, :per_page, :limit, :page, :frame, :dark_mode,
                  :types_present, :languages_present, :scope_present, :commit,
                  :search_in_title, :search_in_tags, :search_in_text, :prioritize_tags, :search_mode,
                  :constitution, :law, :decree, :ordinance, :decision, :misc,
                  :lang_nl, :lang_fr, :hide_abolished, :hide_empty, :hide_missing_translation, :hide_german_translation,
                  :date_from, :date_to, :numac)
  end
end
