# frozen_string_literal: true

class UnifiedSearchController < ApplicationController
  def index
    @title = case I18n.locale when :fr then 'Recherche unifiée' when :de then 'Einheitliche Suche' when :en then 'Unified search' else 'Gecombineerd zoeken' end
    @query = params[:q].to_s.strip
    @sources = parse_sources(params[:sources])
    # Do not turn arbitrary nested values or unbounded digit strings into an
    # SQL offset. Actual corpus counts bound it further before any fetch.
    raw_page = params[:page]
    @page = raw_page.is_a?(String) && raw_page.bytesize <= 9 && raw_page.match?(/\A[1-9][0-9]{0,8}\z/) ? raw_page.to_i : 1

    @per_page = 20
    @active_tab = (%w[all] + @sources.map(&:to_s)).include?(params[:tab]) ? params[:tab] : 'all'

    # Require >= 3 chars: a 1-2 char query is a non-sargable full-table LIKE scan
    # with almost no selectivity, an unauthenticated DoS lever.
    if @query.length >= 3 && @sources.any?
      @results = search_all_sources(@query, @sources, @per_page, @page)
      @total_count = @results.sum { |_, items| items[:total] }
    else
      @results = {}
      @total_count = 0
    end

    @available_sources = available_sources
    page_total = if @active_tab == 'all'
                   @results.values.map { |data| data[:total] }.max.to_i
                 else
                   @results.dig(@active_tab.to_sym, :total).to_i
                 end
    @total_pages = [(page_total.to_f / @per_page).ceil, 1].max
    return unless @page > @total_pages

    @page = @total_pages
    @results = search_all_sources(@query, @sources, @per_page, @page) if @total_count.positive?
  end

  private

  def parse_sources(sources_param)
    # Jurisprudence re-enabled May 2026 after GDPR pseudonymization verified (98.5% clean, 0 real names)
    return %i[legislation jurisprudence parliamentary] if sources_param.blank?

    allowed = %i[legislation jurisprudence parliamentary]
    Array(sources_param).filter_map do |value|
      next unless value.is_a?(String) && allowed.map(&:to_s).include?(value)

      value.to_sym
    end.uniq
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

    scope = served_legislation.where(language_id: legislation_language_ids)
                              .where('title LIKE ? OR numac LIKE ?', like_query, like_query)
    total = scope.count
    return { items: [], total: total } if offset >= total

    items = scope.order(date: :desc, id: :asc)
                 .offset(offset)
                 .limit(limit)
                 .map do |law|
      {
        id: law.numac,
        title: law.title,
        subtitle: legislation_subtitle(law),
        url: law_path(numac: law.numac, language_id: law.language_id),
        language_id: law.language_id,
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
    return { items: [], total: total } if offset >= total

    rows = db.execute(
      'SELECT id, case_number, court, decision_date, language_id FROM cases WHERE id IN (SELECT rowid FROM cases_fts WHERE cases_fts MATCH ?) ORDER BY decision_date DESC, id ASC LIMIT ? OFFSET ?',
      [fts_query, limit, offset]
    )

    items = rows.map do |row|
      lang_id = row[4].to_s == '2' ? 2 : 1
      {
        id: row[0],
        title: row[1],
        subtitle: "#{row[2]} - #{row[3]}",
        url: jurisprudence_path(row[1], language_id: lang_id),
        language_id: lang_id,
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
    fts_query = ParliamentaryFtsQuery.build(query)

    total = db.execute(
      'SELECT COUNT(*) FROM documents WHERE id IN (SELECT rowid FROM documents_fts WHERE documents_fts MATCH ?)',
      [fts_query]
    ).first[0]
    return { items: [], total: total } if offset >= total

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
        language_id: lang_id,
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
    when :fr, :de then 2
    else 1
    end
  end

  # The legislation languages searched: the site's own, and on the German site
  # the German texts with the French ones it falls back to (phase B of
  # docs/ops/german-corpus-plan-2026-09-27.md).
  def legislation_language_ids
    german_site? ? [HasLanguage::GERMAN_LANGUAGE_ID, 2] : [current_language_id]
  end

  # The date, and on the German site, which lists German and French rows of
  # one NUMAC side by side, the language of the row.
  def legislation_subtitle(law)
    return law.date.to_s unless german_site?

    [law.date.to_s, JurisprudenceHelper::CASE_LANGUAGE_LABELS[law.language_id]].compact_blank.join(' · ')
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
