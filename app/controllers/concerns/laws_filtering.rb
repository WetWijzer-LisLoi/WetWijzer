# frozen_string_literal: true

module LawsFiltering
  extend ActiveSupport::Concern

  private

  # Returns true only if the form was explicitly submitted by the user.
  # The hidden languages_present flag should NOT count as submission.
  def filters_submitted?
    params[:commit].present?
  end

  # Performs server-side validation and sets instance variables used by the view
  def perform_validation
    params_hash = search_params.to_h.symbolize_keys

    missing = []
    missing << :types unless types_selected?(params_hash)
    missing << :languages unless languages_selected?(params_hash)
    missing << :scope unless scope_selected?(params_hash)

    return if missing.empty?

    @validation_failed = true
    @missing_keys = missing
    @missing_labels = missing.map { |k| I18n.t("filters.validation.missing.#{k}") }
    flash.now[:alert] = I18n.t('filters.validation.incomplete')
  end

  # Runs the search only when needed and safe to do so
  def run_search_if_needed
    return if @validation_failed

    should_query =
      turbo_frame_request? ||
      request.format.turbo_stream? ||
      request.format.json? ||
      request.format.rss? ||
      search_query_present? ||
      (params[:commit].present? && !@validation_failed) # User clicked Search and validation passed

    return unless should_query

    # Determine which sources to search (legislation is default if nothing selected)
    search_legislation = params[:source_legislation] != '0'
    search_jurisprudence = params[:source_jurisprudence] == '1'
    search_parliamentary = params[:source_parliamentary] == '1'

    all_results = []
    @jurisprudence_results = []
    @parliamentary_results = []

    # Get legislation results
    if search_legislation
      legislation_scope = LawSearchService.search(search_params.except(:per_page))
      
      # Also search FisconetPlus (WIB 92) if there's a search query
      fisconet_results = []
      if params[:title].present? && FisconetSearchService.available?
        fisconet_results = FisconetSearchService.search(search_params.to_h)
      end

      # Merge fisconet at top, then legislation
      if fisconet_results.any?
        all_results = fisconet_results + legislation_scope.to_a
      else
        all_results = legislation_scope.to_a
      end
    end

    # Get jurisprudence results if selected OR if search query present (show combined by default)
    # This provides unified search experience on the main index page
    if params[:title].present? && (search_jurisprudence || params[:source].blank? || params[:source] == 'legislation')
      @jurisprudence_results = search_jurisprudence_source.take(5)  # Limit to top 5 for combined view
    end

    # Get parliamentary results if selected and search query present
    if search_parliamentary && params[:title].present?
      @parliamentary_results = search_parliamentary_source
    end

    # Paginate legislation results
    if all_results.any?
      # Use Pagy array pagination
      @pagy, @laws = pagy(all_results, limit: @per_page)
    elsif search_legislation
      @pagy, @laws = pagy(Legislation.none, limit: @per_page)
    else
      @pagy = nil
      @laws = []
    end
  end

  # Search jurisprudence database
  def search_jurisprudence_source
    db_path = ENV.fetch('JURISPRUDENCE_SOURCE_DB') do
      Rails.env.production? ? '/mnt/HC_Volume_103359050/embeddings/jurisprudence.db' : Rails.root.join('storage', 'jurisprudence.db').to_s
    end
    return [] unless File.exist?(db_path)

    db = SQLite3::Database.new(db_path)
    query = params[:title].to_s
    conditions = ["(case_number LIKE ? OR court LIKE ? OR full_text LIKE ?)"]
    bind_params = ["%#{query}%", "%#{query}%", "%#{query}%"]

    # Apply jurisprudence-specific filters
    if params[:juris_court].present?
      conditions << "court LIKE ?"
      bind_params << "%#{params[:juris_court]}%"
    end
    if params[:juris_year].present?
      conditions << "decision_date LIKE ?"
      bind_params << "#{params[:juris_year]}-%"
    end
    if params[:juris_lang].present?
      conditions << "language_id = ?"
      bind_params << params[:juris_lang]
    end

    where_clause = conditions.join(' AND ')
    sql = "SELECT id, case_number, court, decision_date, summary FROM cases WHERE #{where_clause} ORDER BY decision_date DESC LIMIT 10"

    db.execute(sql, bind_params).map do |row|
      { id: row[0], case_number: row[1], court: row[2], decision_date: row[3], summary: row[4], source: :jurisprudence }
    end
  rescue => e
    Rails.logger.error("Jurisprudence search error: #{e.message}")
    []
  end

  # Search parliamentary database
  def search_parliamentary_source
    db_path = ENV.fetch('PARLIAMENTARY_DB') do
      Rails.env.production? ? '/mnt/shared/parliamentary.sqlite3' : Rails.root.join('storage', 'parliamentary.sqlite3').to_s
    end
    return [] unless File.exist?(db_path)

    db = SQLite3::Database.new(db_path)
    query = params[:title].to_s
    conditions = ["(title LIKE ? OR dossier_number LIKE ?)"]
    bind_params = ["%#{query}%", "%#{query}%"]

    # Apply parliamentary-specific filters
    if params[:parl_parliament].present?
      conditions << "parliament = ?"
      bind_params << params[:parl_parliament]
    end
    if params[:parl_year].present?
      conditions << "strftime('%Y', date) = ?"
      bind_params << params[:parl_year].to_s
    end

    where_clause = conditions.join(' AND ')
    sql = "SELECT id, title, parliament, dossier_number, date FROM documents WHERE #{where_clause} ORDER BY date DESC LIMIT 10"

    db.execute(sql, bind_params).map do |row|
      { id: row[0], title: row[1], parliament: row[2], dossier_number: row[3], date: row[4], source: :parliamentary }
    end
  rescue => e
    Rails.logger.error("Parliamentary search error: #{e.message}")
    []
  end

  # Returns true when any user-provided search/filter parameter is present.
  # Used to skip expensive queries on the initial full-page render and let the
  # Turbo Frame fetch results instead (with immediate loading feedback).
  def search_query_present?
    permitted = search_params.to_h.symbolize_keys
    # Ignore non-filtering params and the hidden languages_present flag
    filtering = permitted.except(:per_page, :limit, :page, :sort, :commit, :dark_mode, :frame,
                                 :languages_present, :types_present, :scope_present)
    filtering.values.any?(&:present?)
  end

  # --- Boolean helpers -------------------------------------------------------

  def types_selected?(params_hash)
    # If no type checkboxes sent at all, validation passes (use defaults)
    has_any_type_param = %i[constitution law decree ordinance decision misc].any? { |k| params_hash.key?(k) }
    return true unless has_any_type_param

    # If type params exist, at least one must be '1'
    %i[constitution law decree ordinance decision misc].any? { |k| params_hash[k] == '1' }
  end

  def languages_selected?(params_hash)
    # If no language checkboxes sent at all, validation passes (use defaults)
    has_any_lang_param = params_hash.key?(:lang_nl) || params_hash.key?(:lang_fr)
    return true unless has_any_lang_param

    # If language params exist, at least one must be '1'
    (params_hash[:lang_nl] == '1') || (params_hash[:lang_fr] == '1')
  end

  def scope_selected?(params_hash)
    explicit = params_hash[:scope_present].present? || params_hash[:commit].present?
    if explicit
      # If no scope checkboxes sent at all, validation passes (use defaults)
      has_any_scope_param = params_hash.key?(:search_in_title) || params_hash.key?(:search_in_tags) || params_hash.key?(:search_in_text)
      return true unless has_any_scope_param

      # If scope params exist, at least one must be '1'
      title_on = params_hash[:search_in_title] == '1'
      tags_on  = params_hash[:search_in_tags] == '1'
      text_on  = params_hash[:search_in_text] == '1'
      title_on || tags_on || text_on
    else
      # Default behavior when not explicitly submitted: Title considered on
      params_hash[:search_in_title] != '0'
    end
  end
end
