# frozen_string_literal: true

# RSS Helper
# Provides helper methods for generating RSS feeds
module RssHelper
  # Generates the RSS feed title based on search parameters
  # @return [String] RSS feed title
  def rss_title
    parts = [t(:app_title)]
    
    if params[:q].present? || params[:title].present?
      query = params[:q].presence || params[:title]
      parts << ": \"#{query}\""
    elsif any_type_filter?
      parts << " - #{active_type_filters.join(', ')}"
    else
      parts << " - #{I18n.locale == :fr ? 'Dernières lois' : 'Laatste wetten'}"
    end
    
    parts.join
  end

  # Generates the RSS feed description
  # @return [String] RSS feed description
  def rss_description
    if params[:q].present? || params[:title].present?
      query = params[:q].presence || params[:title]
      I18n.locale == :fr ? 
        "Résultats de recherche pour \"#{query}\" sur #{t(:app_title)}" :
        "Zoekresultaten voor \"#{query}\" op #{t(:app_title)}"
    else
      I18n.locale == :fr ?
        "Les dernières lois, décrets et arrêtés belges" :
        "De laatste Belgische wetten, decreten en besluiten"
    end
  end

  # Returns human-readable law type name
  # @param type_id [Integer] The law type ID
  # @return [String] Law type name
  def law_type_name(type_id)
    case type_id.to_i
    when 0 then t(:constitution)
    when 1 then t(:law)
    when 2 then t(:decree)
    when 3 then t(:ordinance)
    when 4..10 then t(:decision)
    when 11 then t(:misc)
    else ''
    end
  end

  private

  def any_type_filter?
    %w[constitution law decree ordinance decision misc].any? { |t| params[t] == '1' }
  end

  def active_type_filters
    types = []
    types << t(:constitution) if params[:constitution] == '1'
    types << t(:law) if params[:law] == '1'
    types << t(:decree) if params[:decree] == '1'
    types << t(:ordinance) if params[:ordinance] == '1'
    types << t(:decision) if params[:decision] == '1'
    types << t(:misc) if params[:misc] == '1'
    types
  end
end
