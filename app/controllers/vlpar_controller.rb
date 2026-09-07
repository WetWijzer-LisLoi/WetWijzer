# frozen_string_literal: true

class VlparController < ApplicationController
  def index
    db_path = Rails.root.join('storage', 'vlpar.sqlite3').to_s

    unless File.exist?(db_path)
      @factions = []
      @members = []
      @total_seats = 124
      @db_unavailable = true
      return
    end

    db = SQLite3::Database.new(db_path)
    db.results_as_hash = true

    # Get available legislatures for selector
    @legislatures = db.execute('SELECT DISTINCT legislature FROM factions ORDER BY legislature DESC')
                      .map { |r| r['legislature'] }
    @legislature = params[:legislature].presence || @legislatures.first

    # Factions for this legislature
    @factions = db.execute(
      'SELECT * FROM factions WHERE legislature = ? ORDER BY sort_order ASC',
      [@legislature]
    ).map do |row|
      {
        name: row['name'],
        color: row['color'] || '#888888',
        seats: row['seat_count'].to_i,
        logo: row['logo_url'],
        sort_order: row['sort_order'].to_i
      }
    end

    @total_seats = @factions.sum { |f| f[:seats] }

    # Members
    @party_filter = params[:party]
    members_rows = if @party_filter.present?
                     db.execute(
                       'SELECT * FROM members WHERE legislature = ? AND faction_name = ? ORDER BY surname, first_name',
                       [@legislature, @party_filter]
                     )
                   else
                     db.execute(
                       'SELECT m.*, f.sort_order as faction_order FROM members m
         LEFT JOIN factions f ON m.faction_id = f.id AND m.legislature = f.legislature
         WHERE m.legislature = ?
         ORDER BY COALESCE(f.sort_order, 999), m.surname, m.first_name',
                       [@legislature]
                     )
                   end

    @members = members_rows.map do |row|
      {
        id: row['id'],
        name: "#{row['surname']} #{row['first_name']}",
        surname: row['surname'],
        first_name: row['first_name'],
        party: row['faction_name'],
        color: db.get_first_value('SELECT color FROM factions WHERE id = ? AND legislature = ?', [row['faction_id'], @legislature]) || '#888',
        kieskring: row['kieskring'],
        photo_url: row['photo_url'],
        seat: row['seat_number'],
        deelstaatsenator: row['deelstaatsenator'].to_i == 1
      }
    end

    db.close
  rescue StandardError => e
    Rails.logger.error("VlparController error: #{e.message}")
    @factions = []
    @members = []
    @total_seats = 124
  end
end
