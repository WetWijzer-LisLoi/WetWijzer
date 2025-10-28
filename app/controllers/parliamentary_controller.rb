# frozen_string_literal: true

# Controller for browsing and searching Belgian parliamentary preparatory works
class ParliamentaryController < ApplicationController
  # GET /parlement
  def index
    @title = I18n.locale == :fr ? 'Travaux Préparatoires' : 'Parlementaire Voorbereidingen'
    @query = params[:q].to_s.strip
    @parliament = params[:parliament].presence
    @year = params[:year].presence
    @page = [params[:page].to_i, 1].max

    per_page = 20
    offset = (@page - 1) * per_page

    filters = { parliament: @parliament, year: @year }
    
    if @query.present? || filters.values.any?(&:present?)
      @documents = search_documents(@query, filters, per_page, offset)
      @total_count = count_documents(@query, filters)
    else
      @documents = recent_documents(per_page, offset)
      @total_count = total_documents_count
    end

    @total_pages = (@total_count.to_f / per_page).ceil
    @parliaments = available_parliaments
    @years = available_years
  end

  # GET /parlement/:id
  def show
    doc = parliamentary_db.execute(
      "SELECT id, parliament, dossier_number, document_number, title, content, url, legislation_numac, legislature, document_type, document_date, language, pdf_url FROM documents WHERE id = ?",
      [params[:id]]
    ).first

    if doc
      @document = {
        id: doc[0],
        parliament: doc[1],
        dossier_number: doc[2],
        document_number: doc[3],
        title: doc[4],
        content: doc[5],
        url: doc[6],
        legislation_numac: doc[7],
        legislature: doc[8],
        document_type: doc[9],
        document_date: doc[10],
        language: doc[11],
        pdf_url: doc[12]
      }
      @title = "#{@document[:parliament]} - #{@document[:document_number]}"
    else
      render plain: 'Document not found', status: :not_found
    end
  end

  private

  def parliamentary_db
    db_path = ENV.fetch('PARLIAMENTARY_DB') do
      Rails.root.join('storage', 'parliamentary.sqlite3').to_s
    end
    @parliamentary_db ||= SQLite3::Database.new(db_path)
  end

  def search_documents(query, filters, limit, offset)
    conditions = []
    params = []

    if query.present?
      conditions << "(title LIKE ? OR content LIKE ? OR dossier_number LIKE ?)"
      like_query = "%#{query}%"
      params += [like_query, like_query, like_query]
    end

    if filters[:parliament].present?
      conditions << "parliament = ?"
      params << filters[:parliament]
    end

    if filters[:year].present?
      conditions << "dossier_number LIKE ?"
      params << "%#{filters[:year]}%"
    end

    where_clause = conditions.any? ? "WHERE #{conditions.join(' AND ')}" : ""

    sql = "SELECT id, parliament, dossier_number, document_number, title, url FROM documents #{where_clause} ORDER BY id DESC LIMIT ? OFFSET ?"
    params += [limit, offset]

    parliamentary_db.execute(sql, params).map do |row|
      { id: row[0], parliament: row[1], dossier_number: row[2], document_number: row[3], title: row[4], url: row[5] }
    end
  end

  def count_documents(query, filters)
    conditions = []
    params = []

    if query.present?
      conditions << "(title LIKE ? OR content LIKE ? OR dossier_number LIKE ?)"
      like_query = "%#{query}%"
      params += [like_query, like_query, like_query]
    end

    if filters[:parliament].present?
      conditions << "parliament = ?"
      params << filters[:parliament]
    end

    if filters[:year].present?
      conditions << "dossier_number LIKE ?"
      params << "%#{filters[:year]}%"
    end

    where_clause = conditions.any? ? "WHERE #{conditions.join(' AND ')}" : ""
    parliamentary_db.execute("SELECT COUNT(*) FROM documents #{where_clause}", params).first[0]
  end

  def recent_documents(limit, offset)
    parliamentary_db.execute(
      "SELECT id, parliament, dossier_number, document_number, title, url FROM documents ORDER BY id DESC LIMIT ? OFFSET ?",
      [limit, offset]
    ).map do |row|
      { id: row[0], parliament: row[1], dossier_number: row[2], document_number: row[3], title: row[4], url: row[5] }
    end
  end

  def total_documents_count
    parliamentary_db.execute("SELECT COUNT(*) FROM documents").first[0]
  end

  def available_parliaments
    parliamentary_db.execute("SELECT DISTINCT parliament FROM documents WHERE parliament IS NOT NULL ORDER BY parliament").map(&:first)
  end

  def available_years
    # Extract years from dossier numbers (format like "54K1234" where 54 = legislature)
    (Date.current.year).downto(2010).to_a
  end
end
