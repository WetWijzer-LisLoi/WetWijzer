# frozen_string_literal: true

# == GermanTextHelper
#
# What the German site (gesetzguide.be) says about the text of a law page,
# phase B of docs/ops/german-corpus-plan-2026-09-27.md, section 5: a German
# text carries the label of its provenance (official translation, unofficial
# coordination or consolidation, original), the source named with its URL,
# and the fetch date; a law without a German text is shown in French and
# says so. The labels live in config/locales/de.yml under german_text: the
# German rows are served on the German site only, so they are German only.
module GermanTextHelper
  # "9. Juli 2026", the date form of the Staatsblatt's German notices.
  GERMAN_DATE_FORMAT = '%-d. %B %Y'

  # The Staatsblatt PDF path carries the issue date: /mopdf/2026/07/09_1.pdf
  MOPDF_DATE = %r{/mopdf/(\d{4})/(\d{2})/(\d{2})_}

  # @param law [Legislation] the row the page shows
  # @param content [Content, nil] its contents row
  # @return [Hash, nil] the notice of a German row with a known provenance:
  #   :label (the section 5 sentence), :source_name, :source_url (nil unless
  #   an http(s) URL), :fetched_on (nil when unknown); nil for any other row
  def german_text_notice(law, content)
    return nil unless law.respond_to?(:source_method) && law.language_id == HasLanguage::GERMAN_LANGUAGE_ID

    key = GermanTextProvenance.label_key(law.source_method)
    return nil unless key

    {
      label: t("german_text.labels.#{key}", locale: :de,
                                            published: german_published_phrase(law, content),
                                            state: german_state_phrase(content)),
      source_name: t("german_text.sources.#{GermanTextProvenance.source(law.source_method)}", locale: :de),
      source_url: http_url(law.mon),
      fetched_on: german_date(law.updated_at)
    }
  end

  # 'NL', 'FR' or 'DE': the badge the case-law pages use for the same ids.
  def law_language_label(language_id)
    JurisprudenceHelper::CASE_LANGUAGE_LABELS[language_id.to_i]
  end

  # @param value [String, Date, Time, nil] an ISO date or timestamp
  # @return [String, nil] "9. Juli 2026", nil when the value is no date
  def german_date(value)
    date = value.respond_to?(:to_date) && !value.is_a?(String) ? value.to_date : parse_iso_date(value)
    date && I18n.l(date, format: GERMAN_DATE_FORMAT, locale: :de)
  end

  private

  # " vom 9. Juli 2026": the Staatsblatt date of the text, from the
  # publication date the lane stores, else from the PDF path; empty when
  # neither gives one, so the sentence still reads.
  def german_published_phrase(law, content)
    date = german_date(content&.publication_date)
    date ||= (match = law.mon_pdf.to_s.match(MOPDF_DATE)) && german_date(match.captures.join('-'))
    date ? " vom #{date}" : ''
  end

  # ", Stand 6. Februar 2026": the state of a scta.be consolidation, which
  # the lane writes at the end of contents.source ("..., Stand <date>").
  def german_state_phrase(content)
    source = content.respond_to?(:source) ? content.source.to_s : ''
    state = source[/,\s*Stand\s+(.+)\z/, 1].to_s.strip
    return '' if state.empty?

    ", Stand #{german_date(state) || state}"
  end

  def parse_iso_date(value)
    iso = value.to_s[/\A\d{4}-\d{2}-\d{2}/]
    iso && Date.iso8601(iso)
  rescue Date::Error
    nil
  end

  def http_url(value)
    url = value.to_s.strip
    url.match?(%r{\Ahttps?://}i) ? url : nil
  end
end
