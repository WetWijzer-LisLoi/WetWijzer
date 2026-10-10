# frozen_string_literal: true

# What the classic (no-JavaScript) site serves, decided per action and
# request, not per controller (work package A of the 10:49 Classic plan).
# One map behind both directions:
# - on a classic host, a request classic does not serve gets one redirect
#   to the same path on the modern host
#   (ApplicationController#redirect_unported_classic_pages);
# - on a modern host, a reader without JavaScript is sent to classic only
#   from a page classic renders (the layout's <noscript> refresh).
# Sending every page there was a loop for the ones classic sends back:
# wetwijzer.be/login refreshed to classic.wetwijzer.be/login, which
# redirected to wetwijzer.be/login, and so on.
module ClassicRouting
  extend ActiveSupport::Concern

  # Full pages the classic layout renders, which a modern page hands to
  # classic: the law search, a law (not a Fisconet one, see classic_page?)
  # and the static legal notices.
  CLASSIC_PAGES = {
    'laws' => %w[index show],
    'legal_pages' => %w[about accessibility ai_security contact faq imprint legal_changes privacy terms]
  }.freeze

  # Also served by classic, never offered: the support page posts its
  # donation forms to the host that rendered it, and a donation return
  # lands on that page with a flash message a refresh would lose.
  CLASSIC_SERVED = {
    'legal_pages' => %w[support],
    'donations' => %w[create complete cancel]
  }.freeze

  # Parts, downloads and machine files of the pages above: served on
  # whatever host asks, never redirected or offered.
  CLASSIC_PASS_THROUGH = {
    'laws' => %w[articles article_exdecs related_sources export_word export_typst export_odt
                 export_word_compare export_typst_compare export_odt_compare],
    'robots' => %w[show], 'sitemaps' => %w[index static laws], 'favicons' => %w[show]
  }.freeze
  # Never host-redirect machine endpoints (payment providers deliver with
  # Accept: */* which Rails treats as HTML).
  CLASSIC_EXEMPT_PREFIXES = %w[webhooks/ api/ admin/ rails/].freeze

  # Pages that cannot work without JavaScript, which say so: the AI chat
  # streams its answers, bookmarks live in the browser.
  JAVASCRIPT_ONLY_PAGES = { 'chatbot' => %w[index], 'laws' => %w[bookmarks] }.freeze

  included do
    helper_method :classic_fallback_url, :classic_link_url, :javascript_required_page?
  end

  private

  def classic_action?(map)
    map.fetch(controller_path, []).include?(action_name)
  end

  # A full page classic renders, for this request. A Fisconet law is not
  # one: the classic law template renders Justel rows only.
  def classic_page?
    return false unless classic_action?(CLASSIC_PAGES)

    !(controller_path == 'laws' && action_name == 'show' && FisconetSearchService.fisconet_numac?(params[:numac]))
  end

  def classic_serves_request?
    classic_page? || classic_action?(CLASSIC_SERVED) || classic_action?(CLASSIC_PASS_THROUGH) ||
      CLASSIC_EXEMPT_PREFIXES.any? { |prefix| controller_path.start_with?(prefix) }
  end

  # Where the layout's <noscript> refresh sends a reader without JavaScript:
  # the same URL on the classic host, for a successful GET of a full HTML
  # page classic renders; nil anywhere else. A #fragment never reaches the
  # server, so it cannot follow this refresh across hosts.
  def classic_fallback_url
    return unless (request.get? || request.head?) && request.format.html? && !turbo_frame_request? && !request.xhr?
    return unless response.status == 200 && classic_page?

    classic_url = classic_peer_url("classic.#{request.host}", request.fullpath)
    forward_flash_to_classic!(classic_url)
    classic_url
  end

  # The footer's Classic link: this page on classic where classic renders
  # it, else the classic home, never a page classic would send back.
  def classic_link_url
    base = classic_peer_url("classic.#{request.host.sub('staging.', '')}", '')
    classic_page? || classic_action?(CLASSIC_SERVED.slice('legal_pages')) ? "#{base}#{request.fullpath}" : "#{base}/"
  end

  def javascript_required_page?
    classic_action?(JAVASCRIPT_ONLY_PAGES)
  end

  # Keep the local HTTP scheme and port. A hardcoded https:// peer sent
  # scripts-off browser tests (and local readers) away from their app server.
  # In production the proxy supplies the original HTTPS scheme/default port.
  def classic_peer_url(host, path)
    "#{request.protocol}#{host}#{request.port_string}#{path}"
  end
end
