# frozen_string_literal: true

module Search
  # Normalises a user-typed date into the ISO form the corpora store.
  #
  # Both corpora keep dates as ISO text (jurisprudence.cases.decision_date,
  # chamber.documents.document_date), so an ISO string compares correctly with
  # >= and <=. The filter inputs use flatpickr, which submits DD/MM/YYYY, and
  # the dedicated /jurisprudence page passes ISO straight through - so accept
  # both and reject anything else rather than letting a malformed value reach
  # the query as a silent no-match.
  module DateInput
    module_function

    # @return [String, nil] 'YYYY-MM-DD', or nil when the input is unusable
    def iso(value)
      parsed = parse(value)
      parsed&.strftime('%Y-%m-%d')
    end

    def parse(value)
      text = value.to_s.strip
      return nil if text.empty?

      if text.match?(%r{\A\d{1,2}/\d{1,2}/\d{4}\z})
        day, month, year = text.split('/').map(&:to_i)
        safe_date(year, month, day)
      elsif text.match?(/\A\d{4}-\d{1,2}-\d{1,2}\z/)
        year, month, day = text.split('-').map(&:to_i)
        safe_date(year, month, day)
      end
    end

    def safe_date(year, month, day)
      Date.new(year, month, day)
    rescue Date::Error
      nil
    end
  end
end
