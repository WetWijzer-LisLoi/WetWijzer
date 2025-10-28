# frozen_string_literal: true

# Controller for browsing and searching Belgian jurisprudence (court cases)
class JurisprudenceController < ApplicationController
  before_action :check_access
  before_action :set_case, only: [:show]

  # GET /rechtspraak
  def index
    @title = I18n.locale == :fr ? 'Jurisprudence' : 'Rechtspraak'
    @query = params[:q].to_s.strip
    @court = params[:court]
    @page = [params[:page].to_i, 1].max

    per_page = 20
    offset = (@page - 1) * per_page

    if @query.present? || @court.present?
      @cases = search_cases(@query, @court, per_page, offset)
      @total_count = count_cases(@query, @court)
    else
      @cases = recent_cases(per_page, offset)
      @total_count = total_cases_count
    end

    @total_pages = (@total_count.to_f / per_page).ceil
    @courts = available_courts
  end

  # GET /rechtspraak/:id
  def show
    @title = "#{@case[:court]} - #{@case[:case_number]}"
  end

  private

  def check_access
    client_ip = request.remote_ip
    passphrase = ENV.fetch('CHATBOT_PASSPHRASE', 'o6PctYY0oI2fGPISpNcIgW7vpkmo5UxKpoHr2C2uZDX6v6Xmlv_U7vghmlIRHiXn')

    unless ActiveSupport::SecurityUtils.secure_compare(params[:pass].to_s, passphrase)
      Rails.logger.warn("Jurisprudence access denied - invalid passphrase from IP: #{client_ip}")
      render plain: 'Access denied.', status: :forbidden
    end
  end

  def set_case
    db = jurisprudence_db
    row = db.execute(
      "SELECT id, case_number, court, decision_date, summary, full_text, url, language_id FROM cases WHERE id = ?",
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
        language_id: row[7]
      }
    else
      render plain: 'Case not found', status: :not_found
    end
  end

  def jurisprudence_db
    @jurisprudence_db ||= SQLite3::Database.new(
      ENV.fetch('JURISPRUDENCE_SOURCE_DB', '/mnt/HC_Volume_103359050/embeddings/jurisprudence.db')
    )
  end

  def search_cases(query, court, limit, offset)
    conditions = []
    params = []

    if query.present?
      conditions << "(full_text LIKE ? OR case_number LIKE ? OR court LIKE ?)"
      like_query = "%#{query}%"
      params += [like_query, like_query, like_query]
    end

    if court.present?
      conditions << "court = ?"
      params << court
    end

    where_clause = conditions.any? ? "WHERE #{conditions.join(' AND ')}" : ""

    sql = "SELECT id, case_number, court, decision_date, summary, language_id FROM cases #{where_clause} ORDER BY decision_date DESC LIMIT ? OFFSET ?"
    params += [limit, offset]

    jurisprudence_db.execute(sql, params).map do |row|
      { id: row[0], case_number: row[1], court: row[2], decision_date: row[3], summary: row[4], language_id: row[5] }
    end
  end

  def count_cases(query, court)
    conditions = []
    params = []

    if query.present?
      conditions << "(full_text LIKE ? OR case_number LIKE ? OR court LIKE ?)"
      like_query = "%#{query}%"
      params += [like_query, like_query, like_query]
    end

    if court.present?
      conditions << "court = ?"
      params << court
    end

    where_clause = conditions.any? ? "WHERE #{conditions.join(' AND ')}" : ""
    jurisprudence_db.execute("SELECT COUNT(*) FROM cases #{where_clause}", params).first[0]
  end

  def recent_cases(limit, offset)
    jurisprudence_db.execute(
      "SELECT id, case_number, court, decision_date, summary, language_id FROM cases ORDER BY decision_date DESC LIMIT ? OFFSET ?",
      [limit, offset]
    ).map do |row|
      { id: row[0], case_number: row[1], court: row[2], decision_date: row[3], summary: row[4], language_id: row[5] }
    end
  end

  def total_cases_count
    jurisprudence_db.execute("SELECT COUNT(*) FROM cases").first[0]
  end

  def available_courts
    jurisprudence_db.execute("SELECT DISTINCT court FROM cases WHERE court IS NOT NULL ORDER BY court").map(&:first)
  end
end
