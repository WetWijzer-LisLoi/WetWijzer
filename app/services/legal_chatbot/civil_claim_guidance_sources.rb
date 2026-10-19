# frozen_string_literal: true

require 'uri'

module LegalChatbot
  # Reviewed court information, not legislation or a promise that litigation
  # is free. Keep literal quote evidence separate from the editorial summary.
  class CivilClaimGuidanceSources
    VERIFIED_ON = Date.new(2026, 10, 17)
    REVIEW_AFTER = Date.new(2027, 1, 17)
    RECORD = {
      key: 'belgian_courts_conciliation', source: 'official_guidance',
      official_source_id: 'belgian_courts_conciliation', language: 'NL', region: 'federal',
      authority: 'Hoven & Rechtbanken', title: 'Hoven & Rechtbanken — verzoening (toelichting)',
      law_title: 'Hoven & Rechtbanken — verzoening (toelichting)',
      article_title: 'Primary-source guidance, not legislation',
      url: 'https://www.rechtbanken-tribunaux.be/nl/procedures-in-de-rechtbank/verzoening',
      article_text: 'Alvorens een klassieke procedure te beginnen kunnen de partijen gratis gebruik maken van een verzoeningsprocedure.',
      reviewed_summary: 'The courts explain a voluntary conciliation attempt before the competent court, requested orally or by ordinary letter. ' \
                        'If the other party does not attend or no agreement is reached, the judge cannot impose a settlement through this attempt; ' \
                        'ordinary proceedings may then be necessary. A recorded agreement has enforceable effect, but enforcement can require further steps. ' \
                        'The free conciliation attempt does not make summons, litigation, a lawyer or enforcement free. ' \
                        'Use the retrieved Judicial Code for operative rules; this page is court information, not a statute or an assurance of recovery.',
      verified_on: VERIFIED_ON.iso8601
    }.transform_values { |value| value.is_a?(String) ? value.freeze : value }.freeze

    def self.sources_for(question)
      return [] unless MarketplaceCivilClaimIntent.topic?(question)
      return [] if Date.current > REVIEW_AFTER || !valid_record?(RECORD)

      [RECORD.dup]
    end

    def self.valid_record?(record)
      return false unless record == RECORD

      uri = URI.parse(record.fetch(:url))
      uri.scheme == 'https' && uri.host == 'www.rechtbanken-tribunaux.be' && uri.userinfo.nil? &&
        uri.port == 443 && uri.query.nil? && uri.fragment.nil? &&
        uri.path == '/nl/procedures-in-de-rechtbank/verzoening'
    rescue KeyError, URI::InvalidURIError
      false
    end
  end
end
