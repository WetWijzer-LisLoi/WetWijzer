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
      classic_host? || # Classic always queries (no Turbo, no commit param)
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

    all_results = nil
    @jurisprudence_results = []
    @parliamentary_results = []

    # Get legislation results (FiscoNet tax legislation is always included with Wetgeving)
    if search_legislation
      legislation_scope = LawSearchService.search(search_params.except(:per_page))

      # Always merge FisconetPlus tax legislation when searching legislation
      if FisconetSearchService.available?
        fisconet_results = FisconetSearchService.search(search_params.to_h)
        if fisconet_results.any?
          # Merge tax laws at top, then regular legislation — must use .to_a
          # because we're mixing OpenStructs (FiscoNet) with AR records
          all_results = fisconet_results + legislation_scope.to_a
        end
      end

      # If no FiscoNet merge happened, keep the AR relation for efficient pagination
      all_results ||= legislation_scope
    end

    # Get jurisprudence results if checkbox is checked
    @jurisprudence_results = search_jurisprudence_source if search_jurisprudence

    # Get parliamentary results if selected
    @parliamentary_results = search_parliamentary_source if search_parliamentary

    # Paginate legislation results
    if all_results.is_a?(Array) && all_results.any?
      # Array pagination (mixed AR + FiscoNet OpenStruct results)
      @pagy, @laws = pagy(all_results, limit: @per_page)
    elsif all_results.is_a?(ActiveRecord::Relation)
      # AR relation — efficient SQL LIMIT/OFFSET pagination
      @pagy, @laws = pagy(all_results, limit: @per_page)
    elsif search_legislation
      @pagy, @laws = pagy(Legislation.none, limit: @per_page)
    else
      @pagy = nil
      @laws = []
    end
  end

  # Delegate to dedicated search services (extracted for testability and consistency
  # with LawSearchService and FisconetSearchService patterns)
  def search_jurisprudence_source
    locale = if params[:juris_lang].present?
               params[:juris_lang].to_s.upcase == 'FR' || params[:juris_lang] == '2' ? :fr : :nl
             else
               I18n.locale
             end
    JurisprudenceSearchService.search(
      query: params[:title].to_s.strip,
      court: params[:juris_court],
      year: params[:juris_year],
      subject: params[:juris_subject],
      locale: locale,
      search_body: params[:juris_search_body] == '1'
    )
  end

  def search_parliamentary_source
    ParliamentarySearchService.search(
      query: params[:title].to_s.strip,
      parliament: params[:parl_parliament],
      year: params[:parl_year],
      doc_type: params[:parl_doc_type],
      lang: params[:parl_lang],
      search_body: params[:parl_search_body] == '1'
    )
  end

  # Returns true when any user-provided search/filter parameter is present.
  # Used to skip expensive queries on the initial full-page render and let the
  # Turbo Frame fetch results instead (with immediate loading feedback).
  def search_query_present?
    permitted = search_params.to_h.symbolize_keys
    # Ignore non-filtering params and the hidden languages_present flag
    filtering = permitted.except(:per_page, :limit, :page, :sort, :commit, :frame,
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
    has_any_lang_param = params_hash.key?(:lang_nl) || params_hash.key?(:lang_fr) || params_hash.key?(:lang_de)
    return true unless has_any_lang_param

    # If language params exist, at least one must be '1'
    (params_hash[:lang_nl] == '1') || (params_hash[:lang_fr] == '1') || (params_hash[:lang_de] == '1')
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
