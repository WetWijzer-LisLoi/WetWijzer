# frozen_string_literal: true

# A dated address (?as_of=<day>) on the surfaces that never serve an archived edition (Sol 2026-11-20 13:47:06Z): the
# Classic page and the plain-text response show today's text, so they say so, name the day and give the dated reader on
# the standard site where the archive serves the law; the NL/FR comparison opens the current texts, so it says so and
# leads back to the dated page.
module DatedReaderHelper
  DATED_DAY = /\A\d{4}-\d{2}-\d{2}\z/

  # The day the address asks for, served by the archive view or not; nil without a valid as_of.
  def dated_request_day
    return Date.iso8601(@history_as_of) if @history_pilot && @history_as_of.present?

    @unsupported_as_of
  end

  # The standard site's dated reader for this page where the archive serves this law and language, else nil. Classic
  # has no archive view, so its link leaves the classic host.
  def dated_reader_url
    return unless @history_pilot && @history_as_of.present?

    origin = if classic_host?
               classic_brand_origin(SiteBrand.canonical_domain_for(SiteBrand.resolve_request(request)) ||
                                    request.host.delete_prefix('classic.'))
             else
               request.base_url
             end
    "#{origin}#{law_path(@law, **history_state_params)}"
  end

  def dated_day_label(day) = l(day, format: t('dated_link_notice.date_format'))

  # The dated page a comparison was opened from (compare?return_as_of=<day>), or nil.
  def compare_return_day
    text = params[:return_as_of].to_s
    return unless text.match?(DATED_DAY)

    Date.iso8601(text)
  rescue Date::Error
    nil
  end
end
