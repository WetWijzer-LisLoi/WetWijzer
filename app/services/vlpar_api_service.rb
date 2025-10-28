# frozen_string_literal: true

require 'net/http'
require 'json'

# Service to interact with the Vlaams Parlement Open Data API
# https://ws.vlpar.be/e/opendata/api-docs
class VlparApiService
  BASE_URL = 'https://ws.vlpar.be/e/opendata'
  CACHE_TTL = 3600 # 1 hour

  class << self
    # Returns current MPs grouped by faction with seat counts and colors
    # Each faction: { name, color, seats, logo, members: [{name, voornaam, kieskring, photo_url, id}] }
    def current_mps_by_faction
      cached(:current_mps_by_faction) do
        data = fetch_json('/vv/huidige/perfractie')
        return [] unless data && data['items']

        data['items'].filter_map do |item|
          fl = item['fractielijst']
          next unless fl

          fractie = fl['fractie'] || {}
          members_raw = Array(fl['volksvertegenwoordiger'])

          {
            name: fractie['naam'],
            color: "##{fractie['kleur']}",
            seats: fractie['zetel-aantal'].to_i,
            logo: fractie['logo'],
            sort_order: fractie['volgnr'].to_i,
            members: members_raw.map do |m|
              {
                id: m['id'],
                name: "#{m['naam']} #{m['voornaam']}",
                surname: m['naam'],
                first_name: m['voornaam'],
                kieskring: m['kieskring'],
                photo_url: m['fotowebpath'],
                seat: m['zetel'],
                deelstaatsenator: m['deelstaatsenator']
              }
            end
          }
        end.sort_by { |f| f[:sort_order] }
      end
    end

    # Returns all legislatures
    def legislatures
      cached(:legislatures) do
        data = fetch_json('/leg/alle')
        return [] unless data && data['items']

        data['items'].filter_map do |item|
          leg = item['legislatuur']
          next unless leg

          {
            id: leg['id'],
            name: leg['naam'],
            start_date: leg['start-legislatuur'],
            end_date: leg['eind-legislatuur'],
            election_date: leg['verkiezingsdatum']
          }
        end
      end
    end

    # Returns MP detail by ID
    def mp_detail(person_id)
      fetch_json("/vv/#{person_id}")
    end

    private

    def fetch_json(path)
      uri = URI("#{BASE_URL}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 15

      request = Net::HTTP::Get.new(uri)
      request['Accept'] = 'application/json;charset=UTF-8'

      response = http.request(request)

      if response.code.to_i == 200
        JSON.parse(response.body)
      else
        Rails.logger.warn("VlparAPI #{path} returned #{response.code}")
        nil
      end
    rescue StandardError => e
      Rails.logger.error("VlparAPI error: #{e.message}")
      nil
    end

    def cached(key, &block)
      @cache ||= {}
      @cache_ts ||= {}

      return @cache[key] if @cache[key] && @cache_ts[key] && (Time.now - @cache_ts[key]) < CACHE_TTL

      result = block.call
      @cache[key] = result
      @cache_ts[key] = Time.now
      result
    end
  end
end
