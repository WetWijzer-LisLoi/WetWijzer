# frozen_string_literal: true

require 'digest'
require 'json'

module LegalChatbot
  # Request-time discovery is only a durable, bounded acquisition request. No
  # raw question, conversation, URL or personal fact leaves the application.
  # Newly fetched evidence is admitted through EuLiveCorpus on a later search,
  # never through an unverified helper response or a generated source claim.
  class EuDiscovery
    LANGUAGES = %w[nl fr de en].freeze
    SOURCES = %w[legislation jurisprudence].freeze
    DEPTHS = %w[quick balanced thorough extensive].freeze
    CELEX = %r{\A[012346][A-Z0-9()._/-]{1,127}\z}i
    ECLI = /\AECLI:EU:[A-Z]{1,8}:\d{4}:\d{1,8}\z/
    MAX_TERMS = 4
    DEDUP_SECONDS = 300
    ALIASES = {
      /\b(?:avg|gdpr|rgpd|dsgvo)\b/i => '32016R0679',
      /\b(?:AI\s+Act|AI[-\s]verordening|KI[-\s]Verordnung)\b/i => '32024R1689',
      /\b(?:DSA|Digital\s+Services\s+Act|digitaledienstenverordening)\b/i => '32022R2065',
      /\bnilsson\b/i => '61997CJ0162', /\bplanet49\b/i => '62017CJ0673'
    }.freeze
    # Controlled legal vocabulary, not an LLM rewrite of the user's facts.
    TOPICS = {
      /\b(?:privacy|persoonsgegevens|gegevensbescherming|datenschutz|personenbezogen\p{L}*|donnees personnelles|protection des donnees|personal data|data protection|cookies?)\b/iu => ['data protection', 'privacy', 'cookies'],
      /\b(?:websites?|webshops?|e[- ]?commerce|online diensten\p{L}*|dienstenverlening|commerce electronique|site internet|internetauftritt|dienstleistung\p{L}*)\b/iu => ['electronic commerce', 'information society services'],
      /\b(?:herroep\p{L}*|retour\p{L}*|withdrawal|cooling[- ]off|retractation|widerruf\p{L}*)\b/iu => ['consumer rights', 'withdrawal'],
      /\b(?:onrechtmatig\p{L}* beding\p{L}*|oneerlijk\p{L}* beding\p{L}*|unfair terms|clauses abusives|missbrauchlich\p{L}* klauseln)\b/iu => ['unfair contract terms'],
      /\b(?:vlucht\p{L}*|vliegtuig|air passenger\p{L}*|flight delay\p{L}*|vol annule|retard de vol|fluggast\p{L}*)\b/iu => ['air passenger rights'],
      /\b(?:platform\p{L}*|digital services|digitale diensten|services numeriques|digitale dienste)\b/iu => ['digital services'],
      /\b(?:artificiele intelligentie|artificial intelligence|intelligence artificielle|kunstliche intelligenz|AI Act|AI-verordening)\b/iu => ['artificial intelligence'],
      /\b(?:arbeidstijd\p{L}*|working time|temps de travail|arbeitszeit\p{L}*)\b/iu => ['working time'],
      /\b(?:discriminat\p{L}*|gelijke behandeling|equal treatment|egalite de traitement|gleichbehandlung)\b/iu => ['equal treatment'],
      /\b(?:toegankelijkheid|accessibil\p{L}*|barrierefreiheit)\b/iu => ['accessibility'],
      /\b(?:digitale markten|digital markets|marches numeriques|digitale markte|DMA)\b/iu => ['digital markets'],
      /\b(?:arbeidsrecht|arbeidscontract\p{L}*|arbeidsovereenkomst\p{L}*|employment|contrat de travail|droit du travail|arbeitsrecht|arbeitsvertrag\p{L}*)\b/iu => ['employment'],
      /\b(?:rechterlijke bevoegdheid|internationale bevoegdheid|civil jurisdiction|competence judiciaire|gerichtliche zustandigkeit|Brussel I|Brussels I)\b/iu => ['civil jurisdiction'],
      /\b(?:toepasselijk recht|applicable law|loi applicable|anzuwendendes recht|Rome I|Rome II)\b/iu => ['applicable law'],
      /\b(?:insolvent\p{L}*|insolvab\p{L}*|faillissement\p{L}*|bankruptcy)\b/iu => ['insolvency'],
      /\b(?:auteursrecht\p{L}*|copyright|droit d'auteur|intellectual property|intellectuele eigendom|urheberrecht\p{L}*)\b/iu => ['copyright'],
      /\b(?:erfrecht|succession\p{L}*|erbrecht|inheritance)\b/iu => ['succession']
    }.freeze
    TERMS = TOPICS.values.flatten.uniq.freeze
    PAYLOAD_KEYS = %w[operation language source_kinds depth celex ecli terms].freeze

    attr_reader :retrieval_degradation

    def initialize(cache: Rails.cache, job: EuCorpusAcquireJob, enabled: nil)
      @cache = cache
      @job = job
      @enabled = enabled.nil? ? self.class.enabled? : enabled
    end

    def self.enabled?
      setting = ENV.fetch('EURLEX_LIVE_RETRIEVAL_ENABLED', nil)
      setting.nil? ? Rails.env.production? : setting == '1'
    end

    def self.cache_key(payload)
      "eu-live-acquire-v1:#{Digest::SHA256.hexdigest(JSON.generate(payload.sort.to_h))}"
    end

    # Only a named act type establishes the R/L code. A bare 261/2004 or
    # arbitrary date cannot manufacture an EU act identity.
    def self.named_act_identifiers(question)
      pattern = %r{\b(verordening|regulation|r[eè]glement|verordnung|richtlijn|directive|richtlinie)\s*(?:\((?:EU|EC|EG|EEG|EEC|UE|CE)\)\s*)?(?:(?:nr\.?|no\.?|n[o°º]\.?|nummer)\s*)?(\d{1,5})\s*/\s*(\d{1,5})\b}i
      question.to_s[0, 6000].scan(pattern).filter_map do |type, first, second|
        if first.length == 4 && first.to_i.between?(1900, 2199)
          year = first
          number = second
        elsif second.length == 4 && second.to_i.between?(1900, 2199)
          year = second
          number = first
        end
        next unless year && number.length <= 4 && number.to_i.positive?

        kind = type.match?(/\A(?:richtlijn|directive|richtlinie)\z/i) ? 'L' : 'R'
        "3#{year}#{kind}#{number.rjust(4, '0')}"
      end.uniq
    end

    # Also called by the job: persisted job arguments cannot widen the request
    # to arbitrary text, remote URLs, extra languages or unexpected operations.
    def self.valid_payload?(payload)
      return false unless payload.is_a?(Hash) && (payload.keys - PAYLOAD_KEYS).empty?
      return false unless payload['operation'] == 'discover' && LANGUAGES.include?(payload['language']) && DEPTHS.include?(payload['depth'])
      return false unless payload['source_kinds'].is_a?(Array) && payload['source_kinds'].length == 1 && SOURCES.include?(payload['source_kinds'].first)
      unless payload['terms'].is_a?(Array) && payload['terms'].length <= MAX_TERMS && payload['terms'].uniq == payload['terms'] &&
             payload['terms'].all? { |term| TERMS.include?(term) }
        return false
      end
      return false if payload.key?('celex') && (!payload['celex'].is_a?(String) || !CELEX.match?(payload['celex']))
      return false if payload.key?('ecli') && (!payload['ecli'].is_a?(String) || !ECLI.match?(payload['ecli']))
      return false if payload.key?('celex') && payload['celex'].start_with?('6') != (payload['source_kinds'].first == 'jurisprudence')
      return false if payload.key?('ecli') && payload['source_kinds'].first != 'jurisprudence'

      payload.key?('celex') || payload.key?('ecli') || payload['terms'].any?
    end

    def enqueue(question, source:, language: 'nl', depth: 'balanced')
      @retrieval_degradation = nil
      return false unless @enabled

      payload = request_payload(question, source: source, language: language, depth: depth)
      return false unless payload

      key = self.class.cache_key(payload)
      claimed = @cache.write(key, 'pending', expires_in: DEDUP_SECONDS, unless_exist: true)
      unless claimed
        state = @cache.read(key)
        @retrieval_degradation = case state
                                 when 'pending' then 'eu_live_acquisition_pending'
                                 when 'complete' then nil
                                 else 'eu_live_acquisition_unavailable'
                                 end
        return false
      end
      raise 'acquisition_enqueue_rejected' unless @job.perform_later(payload)

      @retrieval_degradation = 'eu_live_acquisition_pending'
      true
    rescue StandardError => e
      @cache.delete(key) if key && claimed
      @retrieval_degradation = 'eu_live_acquisition_unavailable'
      Rails.logger.warn("[EuDiscovery] acquisition queue unavailable: #{e.class}")
      false
    end

    private

    def request_payload(question, source:, language:, depth:)
      return nil unless SOURCES.include?(source.to_s) && LANGUAGES.include?(language.to_s)

      q = question.to_s[0, 6000]
      judicial = source.to_s == 'jurisprudence'
      identities = q.scan(/\b(?:CELEX\s*:?\s*)?([036]\d{4}[A-Z]{1,2}\d{4}(?:-\d{8})?(?:R\(\d{2}\))?)\b/i).flatten.map(&:upcase)
      identities.concat(self.class.named_act_identifiers(q))
      q.scan(%r{\bCELEX\s*:\s*([012346][A-Z0-9()._/-]{1,127})}i) { |entry| identities << entry.first.upcase }
      identities.concat(ALIASES.filter_map { |pattern, id| id if q.match?(pattern) })
      if (match = q.match(%r{\b([CTF])\s*[-–]?\s*(\d{1,4})/(\d{2}|\d{4})\b}i))
        court, number, year = match.captures
        year = (year.to_i >= 50 ? '19' : '20') + year if year.length == 2
        identities << "6#{year}#{court.upcase}J#{number.rjust(4, '0')}"
      end
      scoped = identities.select { |id| CELEX.match?(id) && id.start_with?('6') == judicial }.uniq
      # Multiple named acts/cases need separate deliberate acquisition calls;
      # never pick an arbitrary identity from an ambiguous user request.
      return nil if scoped.length > 1

      celex = scoped.first
      ecli = q[/\bECLI:EU:[A-Z]{1,8}:\d{4}:\d{1,8}\b/i]&.upcase if judicial
      normalized = q.unicode_normalize(:nfd).gsub(/\p{Mn}/, '')
      plan = EuTopicIntent.plan(q) unless celex || ecli || identities.any?
      terms = if plan
                plan[:discovery_terms]
              else
                TOPICS.filter_map { |pattern, vocabulary| vocabulary if normalized.match?(pattern) }.flatten
              end.uniq.take(MAX_TERMS)
      # Explicit identities do not silently become an opposite-lane topic query.
      return nil if (identities.any? || q.match?(/\bECLI:EU:/i)) && !celex && !ecli

      payload = { 'operation' => 'discover', 'language' => language.to_s, 'source_kinds' => [source.to_s],
                  'depth' => DEPTHS.include?(depth.to_s) ? depth.to_s : 'balanced', 'terms' => terms }
      payload['celex'] = celex if celex
      payload['ecli'] = ecli if ecli
      self.class.valid_payload?(payload) ? payload : nil
    end
  end
end
