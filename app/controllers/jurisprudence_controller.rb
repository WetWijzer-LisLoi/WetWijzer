# frozen_string_literal: true

# Controller for browsing and searching Belgian jurisprudence (court cases)
class JurisprudenceController < ApplicationController
  before_action :set_case, only: [:show]

  # GET /rechtspraak
  def index
    @title = I18n.locale == :fr ? 'Jurisprudence' : 'Rechtspraak'
    @query = params[:q].to_s.strip
    @court = params[:court].presence
    @year = params[:year].presence
    @date_from = params[:date_from].presence
    @date_to = params[:date_to].presence
    @lang = params[:lang].presence
    @sort = params[:sort].presence || 'date_desc'
    @page = [params[:page].to_i, 1].max

    per_page = 20
    offset = (@page - 1) * per_page

    filters = { court: @court, year: @year, date_from: @date_from, date_to: @date_to, lang: @lang }
    
    if @query.present? || filters.values.any?(&:present?)
      @cases = search_cases(@query, filters, per_page, offset)
      @total_count = count_cases(@query, filters)
    else
      @cases = recent_cases(per_page, offset)
      @total_count = total_cases_count
    end

    @total_pages = (@total_count.to_f / per_page).ceil
    @courts = available_courts
    @grouped_courts = grouped_courts
  end

  # GET /rechtspraak/:id
  def show
    @title = "#{@case[:court]} - #{@case[:case_number]}"
  end

  private

  def set_case
    db = jurisprudence_db
    row = db.execute(
      "SELECT id, case_number, court, decision_date, summary, full_text, url, language_id, subject_matter, decision_type, outcome, laws_referenced FROM cases WHERE id = ?",
      [params[:id]]
    ).first

    if row
      @case = {
        id: row[0],
        case_number: row[1],
        court: row[2],
        decision_date: row[3],
        summary: row[4],
        full_text: row[5],
        url: row[6],
        language_id: row[7],
        subject_matter: row[8],
        decision_type: row[9],
        outcome: row[10],
        laws_referenced: row[11]
      }
    else
      render plain: 'Case not found', status: :not_found
    end
  end

  def jurisprudence_db
    db_path = ENV.fetch('JURISPRUDENCE_SOURCE_DB') do
      Rails.env.production? ? '/mnt/HC_Volume_103359050/embeddings/jurisprudence.db' : Rails.root.join('storage', 'jurisprudence.db').to_s
    end
    @jurisprudence_db ||= SQLite3::Database.new(db_path)
  end

  def search_cases(query, filters, limit, offset)
    conditions = []
    params = []

    if query.present?
      conditions << "(full_text LIKE ? OR case_number LIKE ? OR court LIKE ?)"
      like_query = "%#{query}%"
      params += [like_query, like_query, like_query]
    end

    build_filter_conditions(filters, conditions, params)

    where_clause = conditions.any? ? "WHERE #{conditions.join(' AND ')}" : ""

    order = @sort == 'date_asc' ? 'ASC' : 'DESC'
    sql = "SELECT id, case_number, court, decision_date, summary, language_id FROM cases #{where_clause} ORDER BY decision_date #{order} LIMIT ? OFFSET ?"
    params += [limit, offset]

    jurisprudence_db.execute(sql, params).map do |row|
      { id: row[0], case_number: row[1], court: row[2], decision_date: row[3], summary: row[4], language_id: row[5] }
    end
  end

  def count_cases(query, filters)
    conditions = []
    params = []

    if query.present?
      conditions << "(full_text LIKE ? OR case_number LIKE ? OR court LIKE ?)"
      like_query = "%#{query}%"
      params += [like_query, like_query, like_query]
    end

    build_filter_conditions(filters, conditions, params)

    where_clause = conditions.any? ? "WHERE #{conditions.join(' AND ')}" : ""
    jurisprudence_db.execute("SELECT COUNT(*) FROM cases #{where_clause}", params).first[0]
  end

  def build_filter_conditions(filters, conditions, params)
    if filters[:court].present?
      court_pattern = court_pattern_for(filters[:court])
      conditions << "court LIKE ?"
      params << court_pattern
    end

    if filters[:year].present?
      conditions << "decision_date LIKE ?"
      params << "#{filters[:year]}-%"
    end

    if filters[:date_from].present?
      conditions << "decision_date >= ?"
      params << filters[:date_from]
    end

    if filters[:date_to].present?
      conditions << "decision_date <= ?"
      params << filters[:date_to]
    end

    if filters[:lang].present?
      conditions << "language_id = ?"
      params << filters[:lang]
    end
  end

  def recent_cases(limit, offset)
    order = @sort == 'date_asc' ? 'ASC' : 'DESC'
    jurisprudence_db.execute(
      "SELECT id, case_number, court, decision_date, summary, language_id FROM cases ORDER BY decision_date #{order} LIMIT ? OFFSET ?",
      [limit, offset]
    ).map do |row|
      { id: row[0], case_number: row[1], court: row[2], decision_date: row[3], summary: row[4], language_id: row[5] }
    end
  end

  def total_cases_count
    jurisprudence_db.execute("SELECT COUNT(*) FROM cases").first[0]
  end

  def available_courts
    # Get unique court categories (normalized)
    raw_courts = jurisprudence_db.execute("SELECT DISTINCT court FROM cases WHERE court IS NOT NULL AND court != 'Unknown'").map(&:first)
    
    # Normalize to main court types
    categories = raw_courts.map { |c| normalize_court(c) }.compact.uniq.sort
    categories
  end

  # Get courts grouped by hierarchy level for the filter dropdown
  def grouped_courts
    locale = I18n.locale
    raw_courts = available_courts

    # Map normalized court names to BelgianCourtService keys
    court_mapping = {
      'Grondwettelijk Hof' => :grondwettelijk_hof,
      'Hof van Cassatie' => :hof_van_cassatie,
      'Raad van State' => :raad_van_state,
      'Hof van Beroep' => :hof_van_beroep,
      'Arbeidshof' => :arbeidshof,
      'Hof van Assisen' => :hof_van_assisen,
      'Rechtbank eerste aanleg' => :rechtbank_eerste_aanleg,
      'Arbeidsrechtbank' => :arbeidsrechtbank,
      'Ondernemingsrechtbank' => :ondernemingsrechtbank,
      'Beslagrechter' => :beslagrechter,
      'Handhavingscollege' => :handhavingscollege
    }

    # Group available courts by level
    grouped = { 1 => [], 2 => [], 3 => [], 4 => [] }
    other_courts = []

    raw_courts.each do |court_name|
      key = court_mapping[court_name]
      if key && (info = BelgianCourtService.court_info(key))
        level = info[:level]
        display_name = locale == :fr ? info[:name_fr] : info[:name_nl]
        grouped[level] << [display_name, court_name]
      else
        other_courts << [court_name, court_name]
      end
    end

    # Build result with level labels
    result = {}
    [1, 2, 3, 4].each do |level|
      next if grouped[level].empty?

      label = BelgianCourtService.level_label(level, locale)
      result[label] = grouped[level].sort_by(&:first)
    end

    # Add other courts if any
    result[locale == :fr ? 'Autres' : 'Overige'] = other_courts.sort_by(&:first) if other_courts.any?

    result
  end

  def court_pattern_for(category)
    # Return SQL LIKE pattern for court category
    case category
    when 'Grondwettelijk Hof'
      '%Grondwettelijk Hof%'
    when 'Hof van Cassatie'
      '%Hof van Cassatie%'
    when 'Raad van State'
      '%Raad van State%'
    when 'Hof van Beroep'
      '%Hof van Beroep%'
    when 'Arbeidshof'
      '%Arbeidshof%'
    when 'Arbeidsrechtbank'
      '%Arbeidsrechtbank%'
    when 'Ondernemingsrechtbank'
      '%Ondernemingsrechtbank%'
    when 'Rechtbank eerste aanleg'
      '%Rechtbank eerste aanleg%'
    when 'Beslagrechter'
      '%Beslagrechter%'
    when 'Handhavingscollege'
      '%Handhavingscollege%'
    else
      "%#{category}%"
    end
  end

  def normalize_court(court)
    return nil if court.blank? || court == 'Unknown'
    
    case court
    when /Grondwettelijk Hof|Cour Constitutionnelle/i
      'Grondwettelijk Hof'
    when /Hof van Cassatie|Cour de Cassation/i
      'Hof van Cassatie'
    when /Raad van State|Conseil d'État/i
      'Raad van State'
    when /Hof van Beroep|Cour d'appel/i
      'Hof van Beroep'
    when /Arbeidshof|Cour du travail/i
      'Arbeidshof'
    when /Arbeidsrechtbank|Tribunal du travail/i
      'Arbeidsrechtbank'
    when /Ondernemingsrechtbank|Tribunal de l'entreprise/i
      'Ondernemingsrechtbank'
    when /Rechtbank eerste aanleg|Tribunal de première instance/i
      'Rechtbank eerste aanleg'
    when /Beslagrechter|Juge des saisies/i
      'Beslagrechter'
    when /Handhavingscollege/i
      'Handhavingscollege'
    else
      court # Keep original if no match
    end
  end
end
