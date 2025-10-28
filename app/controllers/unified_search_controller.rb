# frozen_string_literal: true

class UnifiedSearchController < ApplicationController
  def index
    @title = case I18n.locale when :fr then 'Recherche unifiée' when :de then 'Einheitliche Suche' when :en then 'Unified search' else 'Unified zoeken' end
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
    # Jurisprudence re-enabled May 2026 after GDPR pseudonymization verified (98.5% clean, 0 real names)
    return %i[legislation jurisprudence parliamentary] if sources_param.blank?

    allowed = %i[legislation jurisprudence parliamentary]
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
    sanitized = ActiveRecord::Base.sanitize_sql_like(query)
    like_query = "%#{sanitized}%"

    total = Legislation.where(language_id: current_language_id)
                       .where('title LIKE ? OR numac LIKE ?', like_query, like_query)
                       .count

    items = Legislation.where(language_id: current_language_id)
                       .where('title LIKE ? OR numac LIKE ?', like_query, like_query)
                       .order(date: :desc)
                       .offset(offset)
                       .limit(limit)
                       .map do |law|
      {
        id: law.numac,
        title: law.title,
        subtitle: law.date.to_s,
        url: law_path(numac: law.numac, language_id: law.language_id),
        source: :legislation
      }
    end

    { items: items, total: total }
  rescue StandardError => e
    Rails.logger.error("Unified search legislation error: #{e.message}")
    { items: [], total: 0 }
  end

  def search_jurisprudence(query, limit, offset)
    return { items: [], total: 0 } unless File.exist?(jurisprudence_db_path)

    db = @_jurisprudence_db ||= SQLite3::Database.new(jurisprudence_db_path)
    fts_query = query.gsub(/[^\p{L}\p{N}\s]/, ' ').squish

    total = db.execute(
      'SELECT COUNT(*) FROM cases WHERE id IN (SELECT rowid FROM cases_fts WHERE cases_fts MATCH ?)',
      [fts_query]
    ).first[0]

    rows = db.execute(
      'SELECT id, case_number, court, decision_date, language_id FROM cases WHERE id IN (SELECT rowid FROM cases_fts WHERE cases_fts MATCH ?) ORDER BY decision_date DESC LIMIT ? OFFSET ?',
      [fts_query, limit, offset]
    )

    items = rows.map do |row|
      lang_id = row[4].to_s == '2' ? 2 : 1
      {
        id: row[0],
        title: row[1],
        subtitle: "#{row[2]} - #{row[3]}",
        url: jurisprudence_path(row[1], language_id: lang_id),
        source: :jurisprudence
      }
    end

    { items: items, total: total }
  rescue StandardError => e
    Rails.logger.error("Unified search jurisprudence error: #{e.message}")
    { items: [], total: 0 }
  end

  def search_parliamentary(query, limit, offset)
    return { items: [], total: 0 } unless File.exist?(chamber_db_path)

    db = @_chamber_db ||= SQLite3::Database.new(chamber_db_path)
    fts_query = query.gsub(/[^\p{L}\p{N}\s]/, ' ').squish

    total = db.execute(
      'SELECT COUNT(*) FROM documents WHERE id IN (SELECT rowid FROM documents_fts WHERE documents_fts MATCH ?)',
      [fts_query]
    ).first[0]

    rows = db.execute(
      'SELECT id, title, parliament, dossier_number, document_date, language FROM documents WHERE id IN (SELECT rowid FROM documents_fts WHERE documents_fts MATCH ?) ORDER BY id DESC LIMIT ? OFFSET ?',
      [fts_query, limit, offset]
    )

    items = rows.map do |row|
      lang_id = row[5].to_s.upcase.start_with?('F') ? 2 : 1
      {
        id: row[0],
        title: row[1],
        subtitle: "#{parliament_label(row[2])} - #{row[3]} - #{row[4]}",
        url: parliamentary_path(id: row[0], language_id: lang_id),
        source: :parliamentary
      }
    end

    { items: items, total: total }
  rescue StandardError => e
    Rails.logger.error("Unified search parliamentary error: #{e.message}")
    { items: [], total: 0 }
  end

  def current_language_id
    case I18n.locale
    when :fr then 2
    when :de then 3
    else 1
    end
  end

  def jurisprudence_db_path
    ENV.fetch('JURISPRUDENCE_SOURCE_DB') do
      Rails.root.join('storage', 'jurisprudence.db').to_s
    end
  end

  def chamber_db_path
    ENV.fetch('CHAMBER_DB') do
      Rails.root.join('storage', 'chamber.sqlite3').to_s
    end
  end

  def parliament_label(code)
    case I18n.locale
    when :fr
      case code
      when 'chamber' then 'Chambre'
      when 'senate' then 'Sénat'
      when 'vlaams' then 'Parlement flamand'
      when 'brussels' then 'Parlement bruxellois'
      when 'waals' then 'Parlement wallon'
      else code
      end
    when :de
      case code
      when 'chamber' then 'Kammer'
      when 'senate' then 'Senat'
      when 'vlaams' then 'Flämisches Parlament'
      when 'brussels' then 'Brüsseler Parlament'
      when 'waals' then 'Wallonisches Parlament'
      else code
      end
    when :en
      case code
      when 'chamber' then 'Chamber'
      when 'senate' then 'Senate'
      when 'vlaams' then 'Flemish Parliament'
      when 'brussels' then 'Brussels Parliament'
      when 'waals' then 'Walloon Parliament'
      else code
      end
    else
      case code
      when 'chamber' then 'Kamer'
      when 'senate' then 'Senaat'
      when 'vlaams' then 'Vlaams Parlement'
      when 'brussels' then 'Brussels Parlement'
      when 'waals' then 'Waals Parlement'
      else code
      end
    end
  end

  def available_sources
    [
      { key: :legislation, label: case I18n.locale when :fr then 'Législation' when :de then 'Gesetzgebung' when :en then 'Legislation' else 'Wetgeving' end, icon: 'document' },
      { key: :jurisprudence, label: case I18n.locale when :fr then 'Jurisprudence' when :de then 'Rechtsprechung' when :en then 'Case law' else 'Rechtspraak' end, icon: 'scale' },
      { key: :parliamentary, label: case I18n.locale when :fr then 'Travaux parlementaires' when :de then 'Parlamentarische Arbeit' when :en then 'Parliamentary work' else 'Parlementaire stukken' end, icon: 'building' }
    ]
  end
end
