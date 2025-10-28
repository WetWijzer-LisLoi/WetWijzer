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
      search_query_present? ||
      (params[:commit].present? && !@validation_failed) # User clicked Search and validation passed

    return unless should_query

    @pagy, @laws = pagy(
      LawSearchService.search(search_params.except(:per_page)),
      items: @per_page,
      overflow: :last_page
    )
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
