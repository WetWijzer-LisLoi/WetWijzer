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
  before_action :ensure_language_param, only: %i[show articles article_exdecs export_word]
  before_action :set_law, only: %i[show articles article_exdecs export_word]
  before_action :set_per_page, only: [:index]
  before_action :set_language_id, only: %i[show articles article_exdecs export_word]

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
    # NOTE: Pagy v43+ no longer raises errors for out-of-range pages by default
    # It serves an empty page instead. If you want to raise errors, set:
    # Pagy.options[:raise_range_error] = true
    # rescue Pagy::RangeError => e
    #   # Handle pagination overflow (only if raise_range_error is enabled)
    #   last_page = e.respond_to?(:pagy) && e.pagy ? e.pagy.last : 1
    #   redirect_to laws_path(page: last_page, **search_params), notice: t('pagination.overflow')
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

  # GET /laws/:numac/export_word
  #
  # Generates and downloads a Word (.docx) document containing all articles and section headings.
  # Useful for users who need offline access or have difficulty with copy-paste functionality.
  #
  # @return [File] Word document download (HTML format compatible with Word)
  def export_word
    load_articles_data

    # Security: Prevent export of non-existent or empty laws
    unless @articles.present?
      Rails.logger.warn("[SECURITY] Export attempt for law with no articles: #{params[:numac]}")
      redirect_to root_path, alert: t('laws.no_articles_to_export', default: 'Deze wet heeft geen artikelen om te exporteren.')
      return
    end

    # Security: Log export attempts for monitoring
    Rails.logger.info("[EXPORT] Word export requested: #{params[:numac]} (#{@articles.size} articles) by #{request.remote_ip}")

    # Generate HTML content (Word can open HTML files with .doc extension)
    law_title = @law.present? ? helpers.strip_tags(@law.title) : params[:numac]

    # Word-compatible HTML with proper XML namespace for better compatibility
    html_content = <<~HTML
      <html xmlns:o="urn:schemas-microsoft-com:office:office"
            xmlns:w="urn:schemas-microsoft-com:office:word"
            xmlns="http://www.w3.org/TR/REC-html40">
      <head>
        <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
        <title>#{ERB::Util.html_escape(law_title)}</title>
        <!--[if gte mso 9]>
        <xml>
          <w:WordDocument>
            <w:View>Print</w:View>
            <w:Zoom>100</w:Zoom>
          </w:WordDocument>
        </xml>
        <![endif]-->
        <style>
          body { font-family: "Times New Roman", serif; font-size: 12pt; }
          .title { font-size: 20pt; font-weight: bold; text-align: center; margin-bottom: 18pt; }
          h1 { font-size: 16pt; font-weight: bold; margin-top: 14pt; }
          h2 { font-size: 14pt; font-weight: bold; margin-top: 12pt; }
          h3 { font-size: 13pt; font-weight: bold; margin-top: 10pt; }
          h4 { font-size: 12pt; font-weight: bold; margin-top: 8pt; }
          h5 { font-size: 11pt; font-weight: bold; margin-top: 6pt; }
          h6 { font-size: 10pt; font-weight: bold; margin-top: 6pt; }
          p { margin: 6pt 0; }
        </style>
      </head>
      <body>
        <p style="text-align: right; font-size: 10pt; color: #666;">Geraadpleegd op: #{Date.today.strftime('%d/%m/%Y')}</p>
        <p class="title" style="mso-style-name:Title">#{ERB::Util.html_escape(law_title)}</p>
    HTML

    # Add Word's built-in TOC field (auto-generates from headings)
    section_headings = @articles.select { |a| a.article_type == 'LNK' }
    if section_headings.any?
      html_content += <<~TOC
        <h2>Inhoud</h2>
        <!--[if gte mso 9]>
        <p class="MsoToc1">
        <span style="mso-field-code: TOC \\\\o &quot;1-6&quot; \\\\h \\\\z \\\\u">
        <span style="mso-element:field-begin"></span>
        TOC \\o "1-6" \\h \\z \\u
        <span style="mso-element:field-separator"></span>
        </span>
        <span style="mso-element:field-end"></span>
        </p>
        <![endif]-->
        <p><i>Klik met de rechtermuisknop en kies "Veld bijwerken" om de inhoudsopgave te genereren.</i></p>
        <br style="page-break-before: always;">
      TOC
    end

    # Citation mode: strip references and markers, collapse whitespace
    citation_mode = params[:citation] == 'true'

    @articles.each do |article|
      if article.article_type == 'LNK'
        # Section heading - use proper hierarchy level
        # article_text contains the actual heading, article_title contains internal code like "LNK0002"
        # Take only the first line (before any newlines or separator lines)
        full_text = helpers.strip_tags(article.article_text).strip
        heading_text = full_text.split(/\n|----------/).first.to_s.strip
        
        # Clean up reference markers from headings (always, not just citation mode)
        heading_text = heading_text.gsub(/\[\d+\s*/, '').gsub(/\s*\]\d+/, '') # Remove [1 and ]1 markers
        heading_text = heading_text.gsub(/\[\d+\]/, '')  # Remove simple [1] markers
        heading_text = heading_text.gsub(/&nbsp;/i, ' ')  # Convert &nbsp; to regular space
        heading_text = heading_text.gsub(/\s+/, ' ').strip  # Collapse whitespace
        
        level = helpers.section_heading_level(heading_text)
        # Map hierarchy level to HTML heading (level 1 -> h1, level 2 -> h2, etc.)
        # Title style is used for the law title, so h1-h6 are available for sections
        heading_tag = level <= 6 ? "h#{level}" : 'h6'
        html_content += "<#{heading_tag}>#{ERB::Util.html_escape(heading_text)}</#{heading_tag}>\n"
      else
        # Regular article - render with helper then extract text (preserves references)
        # This uses the same rendering logic as the page, ensuring consistency
        rendered_html = helpers.print_article(article.article_text, article.article_title, article.article_type)

        # Convert <br> tags to newlines before extracting text
        doc = Nokogiri::HTML.fragment(rendered_html)
        doc.css('br').each { |br| br.replace("\n") }
        
        # Citation mode: remove reference markers and modification tags
        if citation_mode
          # Remove ref-markers (the [8 and ]8 parts) but keep the inner content
          doc.css('.ref-marker').each(&:remove)
          # Remove modification markers and other metadata
          doc.css('.modification-marker, .domain-tag, .references-section').each(&:remove)
          # Remove abolished markers like <Opgeheven...> or <Abrogé...>
          doc.css('.abolished-marker').each(&:remove)
        end
        
        article_text = doc.text.strip
        
        # Citation mode: clean up reference artifacts and collapse whitespace
        if citation_mode
          # Remove any remaining reference patterns like [8], [8 ]8, (8)<...>, etc.
          article_text = article_text.gsub(/\[\d+\s*\]\d*/, '')  # [8] or [8 ]8
          article_text = article_text.gsub(/\(\d+\)<[^>]*>/, '') # (8)<...>
          # Collapse multiple spaces to single space
          article_text = article_text.gsub(/[ \t]+/, ' ').gsub(/\n +/, "\n").gsub(/ +\n/, "\n")
        end

        # Extract article title (e.g., "Art.1.") and make it bold
        # Common patterns: "Art.1.", "Art. 1.", "Artikel 1.", etc.
        article_title_match = article_text.match(/\A(Art(?:ikel)?\.?\s*\d+[a-z]*\.?)/i)
        
        if article_title_match
          article_title_text = article_title_match[1]
          article_body = article_text[article_title_match[0].length..].strip
          
          # Escape and format body text
          # Use text-indent for new paragraphs (like BOG style) instead of double spacing
          article_body_escaped = ERB::Util.html_escape(article_body)
          article_body_formatted = article_body_escaped
            .gsub(/\n\n+/, "</p>\n<p style=\"text-indent: 1em;\">")
            .gsub("\n", "<br>\n")
          
          html_content += "<p><b>#{ERB::Util.html_escape(article_title_text)}</b> #{article_body_formatted}</p>\n"
        else
          # No article title found, just format the text
          article_text_escaped = ERB::Util.html_escape(article_text)
          article_text_formatted = article_text_escaped
            .gsub(/\n\n+/, "</p>\n<p style=\"text-indent: 1em;\">")
            .gsub("\n", "<br>\n")
          
          html_content += "<p>#{article_text_formatted}</p>\n" if article_text_formatted.present?
        end
      end
    end

    html_content += <<~HTML
      </body>
      </html>
    HTML

    # Generate filename (add -citaat suffix for citation mode)
    base_name = law_title.parameterize.presence || params[:numac]
    filename = citation_mode ? "#{base_name}-citaat.doc" : "#{base_name}.doc"

    # Send as .doc file (HTML format that Word can open)
    send_data html_content,
              filename: filename,
              type: 'application/msword',
              disposition: 'attachment'
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
    raw = params[:per_page].presence || params[:limit].presence

    # Convert to integer, fallback to 50 if invalid
    @per_page = raw ? raw.to_i : 50
    @per_page = 50 if @per_page <= 0 # Invalid values default to 50
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
