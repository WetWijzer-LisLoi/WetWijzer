# frozen_string_literal: true

module ParliamentaryRelations
  # The reviewed relations of config/parliamentary_relations.yml. Loading
  # refuses an entry it cannot trust instead of guessing: a malformed NUMAC, a
  # dossier without its legislature and number, or evidence that is not the
  # official page of exactly that dossier.
  class Manifest
    PATH = Rails.root.join('config/parliamentary_relations.yml')
    NUMAC = /\A\d{4}[0-9A-Z]\d{5}\z/
    # parliament => [official hosts, legislature parameter, dossier parameter]
    OFFICIAL_PAGES = {
      'chamber' => [%w[www.dekamer.be www.lachambre.be], 'legislat', 'dossierID'],
      'senate' => [%w[www.senate.be www.senaat.be], 'LEG', 'NR']
    }.freeze

    class Invalid < StandardError; end

    Dossier = Data.define(:parliament, :legislature, :number, :evidence_url) do
      # "53-2543", as the corpus and the official pages write it
      def label = format('%<legislature>d-%<number>04d', legislature:, number:)

      # documents.dossier_number is stored with and without leading zeros
      def number_variants = [number.to_s, number.to_s.rjust(4, '0')].uniq

      # The official dossier page in the site's language, in the shape
      # Content#chamber_dossier_url and #senate_dossier_url build.
      def url(locale = I18n.locale)
        french = locale.to_s == 'fr'
        if parliament == 'senate'
          "https://www.senate.be/www/?MIval=/dossier&LEG=#{legislature}&NR=#{number}&LANG=#{french ? 'fr' : 'nl'}"
        else
          'https://www.dekamer.be/kvvcr/showpage.cfm?section=/flwb' \
            "&language=#{french ? 'fr' : 'nl'}&cfm=/site/wwwcfm/flwb/flwbn.cfm" \
            "?lang=#{french ? 'F' : 'N'}&legislat=#{legislature}&dossierID=#{number}"
        end
      end
    end

    # replaces_numacs: other laws' NUMACs that documents of these dossiers
    # carry and that the review found wrong; ParliamentaryRelations::Apply
    # refuses to overwrite any other.
    Relation = Data.define(:numac, :law, :dossiers, :evidence, :reviewed_by, :reviewed_on, :replaces_numacs)

    def self.current
      @current ||= load(PATH)
    end

    def self.load(path)
      new(YAML.safe_load_file(path, permitted_classes: [Date]), source: File.basename(path.to_s))
    end

    attr_reader :version, :relations

    def initialize(data, source: 'manifest')
      @source = source
      raise Invalid, "#{source}: expected a mapping with version and relations" unless data.is_a?(Hash)

      @version = data['version']
      raise Invalid, "#{source}: version must be a positive integer" unless @version.is_a?(Integer) && @version.positive?
      raise Invalid, "#{source}: relations must be a list" unless data['relations'].is_a?(Array)

      @relations = data['relations'].each_with_index.map { |entry, index| relation(entry, "#{source}: relation #{index + 1}") }.freeze
      repeated = @relations.map(&:numac).tally.select { |_, count| count > 1 }.keys
      raise Invalid, "#{source}: #{repeated.join(', ')} listed more than once" if repeated.any?

      @by_numac = @relations.index_by(&:numac)
      @by_dossier = @relations.flat_map { |rel| rel.dossiers.map { |d| [[d.parliament, d.legislature, d.number], rel] } }
                              .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    end

    def for_law(numac) = @by_numac[numac.to_s]

    def for_dossier(parliament, legislature, dossier_number)
      return [] unless dossier_number.to_s.match?(/\A\d+\z/)

      @by_dossier.fetch([parliament.to_s, legislature.to_i, dossier_number.to_i], [])
    end

    private

    def relation(entry, where)
      raise Invalid, "#{where}: expected a mapping" unless entry.is_a?(Hash)

      numac = entry['numac']
      raise Invalid, "#{where}: numac must be a quoted NUMAC such as '2013A11134'" unless numac.is_a?(String) && NUMAC.match?(numac)

      where = "#{where} (#{numac})"
      %w[law evidence reviewed_by].each { |key| raise Invalid, "#{where}: #{key} is required" if entry[key].to_s.strip.empty? }
      raise Invalid, "#{where}: reviewed_on must be a date" unless entry['reviewed_on'].is_a?(Date)
      raise Invalid, "#{where}: name at least one dossier" unless entry['dossiers'].is_a?(Array) && entry['dossiers'].any?

      replaces = entry.fetch('replaces_numacs', [])
      unless replaces.is_a?(Array) && replaces.all? { |other| other.is_a?(String) && NUMAC.match?(other) && other != numac }
        raise Invalid, "#{where}: replaces_numacs must list other quoted NUMACs"
      end

      Relation.new(numac:, law: entry['law'].strip, dossiers: entry['dossiers'].map { |d| dossier(d, where) }.freeze,
                   evidence: entry['evidence'].strip, reviewed_by: entry['reviewed_by'].strip,
                   reviewed_on: entry['reviewed_on'], replaces_numacs: replaces.uniq.freeze)
    end

    def dossier(entry, where)
      raise Invalid, "#{where}: each dossier must be a mapping" unless entry.is_a?(Hash)

      parliament, legislature, number, url = entry.values_at('parliament', 'legislature', 'number', 'evidence_url')
      raise Invalid, "#{where}: parliament must be one of #{OFFICIAL_PAGES.keys.join(', ')}" unless OFFICIAL_PAGES.key?(parliament)
      unless [legislature, number].all? { |value| value.is_a?(Integer) && value.positive? }
        raise Invalid, "#{where}: legislature and number must be positive integers"
      end
      unless official_page?(url.to_s, parliament, legislature, number)
        raise Invalid, "#{where}: evidence_url must be the official #{parliament} page of dossier #{legislature}-#{number}"
      end

      Dossier.new(parliament:, legislature:, number:, evidence_url: url)
    end

    def official_page?(url, parliament, legislature, number)
      hosts, legislature_key, number_key = OFFICIAL_PAGES.fetch(parliament)
      uri = URI.parse(url)
      params = URI.decode_www_form(uri.query.to_s).group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
      uri.is_a?(URI::HTTPS) && hosts.include?(uri.host) && uri.port == 443 && uri.userinfo.nil? &&
        dossier_endpoint?(uri.path, params, parliament) &&
        dossier_number_param?(params[legislature_key], legislature) && dossier_number_param?(params[number_key], number)
    rescue URI::InvalidURIError, ArgumentError
      false
    end

    def dossier_number_param?(values, expected)
      values&.size == 1 && values.first.match?(/\A[0-9]+\z/) && values.first.to_i == expected
    end

    def dossier_endpoint?(path, params, parliament)
      if parliament == 'senate'
        path == '/www/' && params['MIval'] == ['/dossier']
      else
        path == '/kvvcr/showpage.cfm' && params['section'] == ['/flwb'] &&
          [%w[nl], %w[fr]].include?(params['language']) &&
          [%w[/site/wwwcfm/flwb/flwbn.cfm?lang=N], %w[/site/wwwcfm/flwb/flwbn.cfm?lang=F]].include?(params['cfm'])
      end
    end
  end
end
