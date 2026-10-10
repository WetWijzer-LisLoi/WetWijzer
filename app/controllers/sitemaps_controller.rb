# frozen_string_literal: true

# Serves dynamically generated XML sitemaps with four-language hreflang annotations.
# Sitemap index splits content into sub-sitemaps of max 45,000 URLs each
# to stay under the 50,000 URL / 50MB limit per sitemap file.
#
# Each <url> entry includes xhtml:link elements pointing to the equivalent page
# on all four language domains (wetwijzer.be, lisloi.be, gesetzguide.be, lexlibera.be),
# enabling Google to understand the cross-domain language relationship.
class SitemapsController < ApplicationController
  # Staging subdomains should never serve sitemaps - return empty index
  before_action :block_staging_sitemaps

  # Site UI languages: the English site serves the same NL/FR legal corpus.
  LANGUAGE_DOMAINS = [
    { lang: 'nl', host: 'https://wetwijzer.be' },
    { lang: 'fr', host: 'https://lisloi.be' },
    { lang: 'de', host: 'https://gesetzguide.be' },
    { lang: 'en', host: 'https://lexlibera.be' }
  ].freeze

  # A law held only in German exists on the German site alone
  GERMAN_ONLY_DOMAINS = LANGUAGE_DOMAINS.select { |ld| ld[:lang] == 'de' }.freeze

  # GET /sitemap.xml - Sitemap Index
  def index
    # Count legislation entries (unique numacs)
    law_count = sitemap_laws.distinct.count(:numac)

    law_pages = (law_count / 45_000.0).ceil

    builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
      xml.sitemapindex(xmlns: 'http://www.sitemaps.org/schemas/sitemap/0.9') do
        # Static pages sitemap
        xml.sitemap do
          xml.loc "#{base_url}/sitemap-static.xml"
        end

        # Law sitemaps
        law_pages.times do |i|
          xml.sitemap do
            xml.loc "#{base_url}/sitemap-laws-#{i + 1}.xml"
          end
        end
      end
    end

    render xml: builder.to_xml
  end

  # GET /sitemap-static.xml - Static pages
  def static
    builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
      xml.urlset(sitemap_namespaces) do
        # Paths come from the routes, so a renamed page cannot leave a dead
        # <loc> behind: /zoeken and sixteen /privacy-nl.html-style notices
        # answered 404 here until WW-SEO-01. One path per page; the host
        # decides its language.
        add_url(xml, root_path, changefreq: 'daily', priority: '1.0')

        # Main sections
        add_url(xml, parliamentary_work_path, changefreq: 'weekly', priority: '0.7')
        add_url(xml, mp_directory_path, changefreq: 'monthly', priority: '0.6')
        add_url(xml, unified_search_path, changefreq: 'weekly', priority: '0.7')
        add_url(xml, pricing_path, changefreq: 'monthly', priority: '0.5')
        add_url(xml, about_path, changefreq: 'monthly', priority: '0.5')
        add_url(xml, contact_path, changefreq: 'monthly', priority: '0.5')
        add_url(xml, support_page_path, changefreq: 'monthly', priority: '0.5')

        # Legal notices
        [privacy_policy_path, terms_of_service_path, imprint_path, accessibility_statement_path].each do |path|
          add_url(xml, path, changefreq: 'monthly', priority: '0.3')
        end
      end
    end

    render xml: builder.to_xml
  end

  # GET /sitemap-laws-:page.xml - Legislation pages
  # Building 45,000 <url> entries with Nokogiri takes about five seconds; the
  # query behind them takes a fifth of a second. Crawlers fetch each page
  # several times a day, and the set only changes when the corpus merge
  # commits, so the built XML is cached under the corpus stamp (main-file
  # mtime of laws.prod.sqlite3, which moves at that checkpoint) for a day.
  # Gzipped in the store: a page is ~19 MB of XML and ~1.3 MB compressed.
  # The host is in the key because <loc> is host-relative.
  def laws
    page = params[:page].to_i
    key = ['sitemap/laws/v2', request.host, page, CacheVersionHelper.laws_db_version].join('/')
    hit = true
    build_ms = nil
    gz = Rails.cache.fetch(key, expires_in: 25.hours, race_condition_ttl: 30.seconds) do
      hit = false
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      xml = build_laws_sitemap(page)
      build_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
      ActiveSupport::Gzip.compress(xml)
    end
    Rails.logger.info(
      "[SITEMAP] page=#{page} hit=#{hit} gz_bytes=#{gz.bytesize}#{" build_ms=#{build_ms}" if build_ms}"
    )

    # FBL-067: crawlers all accept gzip, so serve the stored bytes as-is
    # instead of inflating ~19 MB of XML into this process on every hit.
    # Rack::Deflater leaves responses that already declare Content-Encoding
    # alone. The rare non-gzip client still gets plain XML.
    if request.headers['Accept-Encoding'].to_s.include?('gzip')
      response.set_header('Content-Encoding', 'gzip')
      response.set_header('Vary', 'Accept-Encoding')
      send_data gz, type: 'application/xml; charset=utf-8', disposition: 'inline'
    else
      render xml: ActiveSupport::Gzip.decompress(gz)
    end
  end

  private

  # The laws the sitemaps list, for the index's page count and the pages
  # alike: the rows the site serves. On the Dutch and French sites NL/FR rows
  # only, since a NUMAC held only in German (updater v0.894) has no page
  # there; the German site also lists its German texts (phase B of the German
  # plan).
  def sitemap_laws
    served_legislation.where(is_archived: 0)
  end

  def build_laws_sitemap(page)
    offset = (page - 1) * 45_000

    numacs = sitemap_laws.distinct
                         .order(:numac)
                         .limit(45_000)
                         .offset(offset)
                         .pluck(:numac)
    german_only = german_only_numacs

    builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
      xml.urlset(sitemap_namespaces) do
        numacs.each do |numac|
          # A law held only in German has no page on the other sites: no
          # alternate points there.
          domains = german_only.include?(numac) ? GERMAN_ONLY_DOMAINS : LANGUAGE_DOMAINS
          add_url(xml, "/laws/#{numac}", changefreq: 'monthly', priority: '0.6', domains: domains)
        end
      end
    end

    builder.to_xml
  end

  # The German site's NUMACs that have a German text and no Dutch or French
  # row. Empty on the other sites, which do not list them.
  def german_only_numacs
    return Set.new unless german_site?

    Legislation.german_with_provenance.where(is_archived: 0)
               .where('NOT EXISTS (SELECT 1 FROM legislation site_rows WHERE site_rows.numac = legislation.numac ' \
                      'AND site_rows.language_id IN (?))', HasLanguage::SITE_LANGUAGE_IDS)
               .distinct.pluck(:numac).to_set
  end

  def block_staging_sitemaps
    return unless staging_host?

    builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
      xml.sitemapindex(xmlns: 'http://www.sitemaps.org/schemas/sitemap/0.9')
    end
    render xml: builder.to_xml
  end

  def base_url
    "https://#{request.host}"
  end

  # XML namespace hash for urlset elements (includes xhtml for hreflang)
  def sitemap_namespaces
    {
      'xmlns' => 'http://www.sitemaps.org/schemas/sitemap/0.9',
      'xmlns:xhtml' => 'http://www.w3.org/1999/xhtml'
    }
  end

  # Adds a <url> entry with hreflang cross-references to the language domains
  # (all four unless a narrower set is given)
  def add_url(xml, path, changefreq: 'monthly', priority: '0.5', domains: LANGUAGE_DOMAINS)
    xml.url do
      xml.loc "#{base_url}#{path}"
      xml.changefreq changefreq
      xml.priority priority

      # The language is the site's UI language, not a translated legal text.
      domains.each do |ld|
        xml['xhtml'].link(
          rel: 'alternate',
          hreflang: ld[:lang],
          href: "#{ld[:host]}#{path}"
        )
      end

      # x-default points to Dutch (primary domain), where the page exists
      next unless domains.any? { |ld| ld[:lang] == 'nl' }

      xml['xhtml'].link(
        rel: 'alternate',
        hreflang: 'x-default',
        href: "https://wetwijzer.be#{path}"
      )
    end
  end
end
