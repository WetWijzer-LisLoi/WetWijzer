# frozen_string_literal: true

class UnifiedSearchController < ApplicationController
  def index
    @title = I18n.locale == :fr ? 'Recherche unifiée' : 'Unified zoeken'
    @query = params[:q].to_s.strip
    @sources = parse_sources(params[:sources])
    @page = [params[:page].to_i, 1].max
    
    per_page = 20
    
    if @query.present? && @sources.any?
      @results = search_all_sources(@query, @sources, per_page, @page)
      @total_count = @results.sum { |_, items| items[:total] }
    else
      @results = {}
      @total_count = 0
    end
    
    @available_sources = available_sources
  end

  private

  def parse_sources(sources_param)
    return [:legislation, :jurisprudence, :parliamentary] if sources_param.blank?
    
    allowed = [:legislation, :jurisprudence, :parliamentary]
    Array(sources_param).map(&:to_sym).select { |s| allowed.include?(s) }
  end

  def search_all_sources(query, sources, per_page, page)
    results = {}
    offset = (page - 1) * per_page
    
    sources.each do |source|
      case source
      when :legislation
        results[:legislation] = search_legislation(query, per_page, offset)
      when :jurisprudence
        results[:jurisprudence] = search_jurisprudence(query, per_page, offset)
      when :parliamentary
        results[:parliamentary] = search_parliamentary(query, per_page, offset)
      end
    end
    
    results
  end

  def search_legislation(query, limit, offset)
    like_query = "%#{query}%"
    
    total = Legislation.where(language_id: current_language_id)
                       .where("title LIKE ? OR numac LIKE ?", like_query, like_query)
                       .count
    
    items = Legislation.where(language_id: current_language_id)
                       .where("title LIKE ? OR numac LIKE ?", like_query, like_query)
                       .order(date: :desc)
                       .offset(offset)
                       .limit(limit)
                       .map do |law|
      {
        id: law.numac,
        title: law.title,
        subtitle: law.date.to_s,
        url: law_path(numac: law.numac),
        source: :legislation
      }
    end
    
    { items: items, total: total }
  rescue => e
    Rails.logger.error("Unified search legislation error: #{e.message}")
    { items: [], total: 0 }
  end

  def search_jurisprudence(query, limit, offset)
    return { items: [], total: 0 } unless File.exist?(jurisprudence_db_path)
    
    like_query = "%#{query}%"
    db = SQLite3::Database.new(jurisprudence_db_path)
    
    total = db.execute(
      "SELECT COUNT(*) FROM cases WHERE case_number LIKE ? OR court LIKE ? OR full_text LIKE ?",
      [like_query, like_query, like_query]
    ).first[0]
    
    rows = db.execute(
      "SELECT id, case_number, court, decision_date FROM cases WHERE case_number LIKE ? OR court LIKE ? OR full_text LIKE ? ORDER BY decision_date DESC LIMIT ? OFFSET ?",
      [like_query, like_query, like_query, limit, offset]
    )
    
    items = rows.map do |row|
      {
        id: row[0],
        title: row[1],
        subtitle: "#{row[2]} - #{row[3]}",
        url: jurisprudence_path(id: row[0]),
        source: :jurisprudence
      }
    end
    
    { items: items, total: total }
  rescue => e
    Rails.logger.error("Unified search jurisprudence error: #{e.message}")
    { items: [], total: 0 }
  end

  def search_parliamentary(query, limit, offset)
    return { items: [], total: 0 } unless File.exist?(parliamentary_db_path)
    
    like_query = "%#{query}%"
    db = SQLite3::Database.new(parliamentary_db_path)
    
    total = db.execute(
      "SELECT COUNT(*) FROM documents WHERE title LIKE ? OR dossier_number LIKE ?",
      [like_query, like_query]
    ).first[0]
    
    rows = db.execute(
      "SELECT id, title, parliament, dossier_number, date FROM documents WHERE title LIKE ? OR dossier_number LIKE ? ORDER BY date DESC LIMIT ? OFFSET ?",
      [like_query, like_query, limit, offset]
    )
    
    items = rows.map do |row|
      {
        id: row[0],
        title: row[1],
        subtitle: "#{parliament_label(row[2])} - #{row[3]} - #{row[4]}",
        url: "#", # Parliamentary page not implemented yet
        source: :parliamentary
      }
    end
    
    { items: items, total: total }
  rescue => e
    Rails.logger.error("Unified search parliamentary error: #{e.message}")
    { items: [], total: 0 }
  end

  def current_language_id
    I18n.locale == :fr ? 2 : 1
  end

  def jurisprudence_db_path
    ENV.fetch('JURISPRUDENCE_SOURCE_DB') do
      Rails.env.production? ? '/mnt/HC_Volume_103359050/embeddings/jurisprudence.db' : Rails.root.join('storage', 'jurisprudence.db').to_s
    end
  end

  def parliamentary_db_path
    ENV.fetch('PARLIAMENTARY_DB') do
      Rails.env.production? ? '/mnt/shared/parliamentary.sqlite3' : Rails.root.join('storage', 'parliamentary.sqlite3').to_s
    end
  end

  def parliament_label(code)
    case code
    when 'kamer' then 'Kamer'
    when 'senaat' then 'Senaat'
    when 'vlaams' then 'Vlaams Parlement'
    when 'brussels' then 'Brussels Parlement'
    when 'waals' then 'Waals Parlement'
    else code
    end
  end

  def available_sources
    [
      { key: :legislation, label: I18n.locale == :fr ? 'Législation' : 'Wetgeving', icon: 'document' },
      { key: :jurisprudence, label: I18n.locale == :fr ? 'Jurisprudence' : 'Rechtspraak', icon: 'scale' },
      { key: :parliamentary, label: I18n.locale == :fr ? 'Travaux parlementaires' : 'Parlementaire stukken', icon: 'building' }
    ]
  end
end
