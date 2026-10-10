# frozen_string_literal: true

require 'cgi'

# The Classic site's links and containers (inbox 2026-10-08 10:49, work
# package B). Classic runs no JavaScript and is cached publicly. Global product
# links are fixed home links; the modern-page switch alone may carry an
# allowlisted subset of the current request, never its raw query string.
module ClassicHelper
  CLASSIC_THEMES = %w[system light dark].freeze
  # The search and law parameters the Modern-page switch may carry.
  CLASSIC_SAFE_QUERY_KEYS = %w[title constitution law decree ordinance decision misc lang_nl lang_fr lang_de
                               sort page per_page commit source_legislation].freeze
  CLASSIC_QUERY_VALUE_LIMIT = 200
  # The legal-text languages each site prefers, in order, when the current
  # one is not served there (the German site also serves German rows).
  CLASSIC_LANGUAGE_PREFERENCE = { 'nl' => [1, 2], 'fr' => [2, 1], 'de' => [3, 2, 1], 'en' => [2, 1] }.freeze

  # A wide legal-text or legal-page table scrolls in its own container instead
  # of widening the page on a phone. The container is named and takes keyboard
  # focus, so it can be scrolled without a pointer. Only markup that is
  # already safe comes back marked safe.
  def classic_contain_tables(html)
    return html unless html.respond_to?(:html_safe?) && html.html_safe? && html.to_str.match?(/<table\b/i)

    label = ERB::Util.html_escape(t('classic.table_scroll'))
    html.to_str.gsub(/<table\b/i, %(<div class="classic-table-scroll" tabindex="0" role="region" aria-label="#{label}"><table))
        .gsub(%r{</table\s*>}i, '</table></div>').html_safe
  end

  # Global portal navigation. These are deliberately home links: a reader
  # choosing another product must not be taken to a similarly-shaped URL whose
  # record, filters, or credentials may not exist on that product. Individual
  # law-language controls remain on the law page and use their own URLs.
  def classic_site_links
    SiteBrand::KEYS.map do |brand|
      domain = SiteBrand.canonical_domain_for(brand)
      locale = SiteBrand.locale_for(brand)
      url = "#{classic_brand_origin(domain, classic: true)}/"
      url = classic_with_query(url, 'classic_theme' => classic_theme) unless classic_theme == 'system'
      { label: "#{locale.upcase} (#{domain})", active: I18n.locale.to_s == locale,
        url: url }
    end
  end

  # The modern site's version of this page, on this brand's own domain.
  def classic_modern_url
    domain = SiteBrand.canonical_domain_for(SiteBrand.resolve_request(request)) || request.host.delete_prefix('classic.')
    "#{classic_brand_origin(domain)}#{classic_path_for(I18n.locale.to_s, keep_language: true)}"
  end

  # The Classic reader has a server-rendered colour choice, rather than a
  # JavaScript toggle.  It intentionally lives in the URL: Classic responses
  # are public-cacheable, so a per-browser cookie would let a shared cache
  # serve one reader's appearance to another.  Rails' default URL options
  # retain an explicit choice on local Classic links.
  def classic_theme
    value = params[:classic_theme].to_s
    CLASSIC_THEMES.include?(value) ? value : 'system'
  end

  def classic_theme_url(theme)
    theme = theme.to_s
    raise ArgumentError, 'unsupported Classic theme' unless CLASSIC_THEMES.include?(theme)

    query = request.query_parameters.slice(*CLASSIC_SAFE_QUERY_KEYS, 'language_id', 'classic_theme')
    query.delete('classic_theme')
    query['classic_theme'] = theme unless theme == 'system'
    classic_with_query(request.path, query)
  end

  def classic_theme_selected?(theme)
    classic_theme == theme.to_s
  end

  # Source rows commonly keep an article label twice: once in article_title
  # for indexing and again as the opening words of the canonical legal text.
  # Classic used to render both, producing “Art. 2” immediately followed by
  # “Art. 2. …”.  Only suppress the presentation copy when the canonical
  # source demonstrably begins with the same article label; the legal text and
  # its wrapper anchor remain untouched.
  def classic_article_title_repeated_in_text?(title, html)
    return false unless title.to_s.match?(/\A\s*(?:art(?:ikel|icle)?\.?\s*|§)/i)

    title_tokens = classic_article_label_tokens(title)
    return false if title_tokens.empty?

    text_tokens = classic_article_label_tokens(Nokogiri::HTML.fragment(html.to_s).text).first(title_tokens.length)
    text_tokens == title_tokens
  end

  private

  def classic_article_label_tokens(value)
    tokens = CGI.unescapeHTML(value.to_s).unicode_normalize(:nfkc).downcase.scan(/[[:alnum:]§]+/)
    tokens[0] = 'art' if %w[art artikel article].include?(tokens[0])
    tokens
  end

  # Local language links must remain in the local app too; otherwise a real
  # click during a scripts-off check visits production rather than its fixture.
  # Public site links still use canonical HTTPS brand domains.
  def classic_brand_origin(domain, classic: false)
    prefix = classic ? 'classic.' : ''
    if request.host.end_with?('.localhost')
      local_domain = domain == 'localhost' || domain.end_with?('.localhost') ? domain : "#{domain.delete_suffix('.be')}.localhost"
      "#{request.protocol}#{prefix}#{local_domain}#{request.port_string}"
    else
      "https://#{prefix}#{domain}"
    end
  end

  def classic_path_for(locale, keep_language: false)
    return classic_with_query(request.path, classic_safe_query) unless @law.respond_to?(:numac) && action_name == 'show'

    language_id = keep_language ? @language_id : classic_law_language_for(locale)
    language_id ? classic_with_query(law_path(@law.numac, classic_theme: nil), 'language_id' => language_id) : laws_path(classic_theme: nil)
  end

  def classic_with_query(path, query) = query.present? ? "#{path}?#{query.to_query}" : path

  def classic_safe_query
    request.query_parameters.slice(*CLASSIC_SAFE_QUERY_KEYS)
           .select { |_, value| value.is_a?(String) && value.length <= CLASSIC_QUERY_VALUE_LIMIT }
  end

  def classic_law_language_for(locale)
    served = classic_law_versions & (locale == 'de' ? [1, 2, 3] : [1, 2])
    return @language_id.to_i if served.include?(@language_id.to_i)

    CLASSIC_LANGUAGE_PREFERENCE.fetch(locale).find { |id| served.include?(id) }
  end

  def classic_law_versions
    @classic_law_versions ||= Legislation.served_on_german_site.where(numac: @law.numac).distinct.pluck(:language_id)
  end
end
