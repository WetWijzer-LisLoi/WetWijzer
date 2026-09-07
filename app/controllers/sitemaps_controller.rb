# frozen_string_literal: true

# Serves dynamically generated XML sitemaps with trilingual hreflang annotations.
# Sitemap index splits content into sub-sitemaps of max 45,000 URLs each
# to stay under the 50,000 URL / 50MB limit per sitemap file.
#
# Each <url> entry includes xhtml:link elements pointing to the equivalent page
# on all three language domains (wetwijzer.be, lisloi.be, gesetzguide.be),
# enabling Google to understand the cross-domain language relationship.
class SitemapsController < ApplicationController
  # Staging subdomains should never serve sitemaps - return empty index
  before_action :block_staging_sitemaps

  # Trilingual domain mapping for hreflang annotations
  LANGUAGE_DOMAINS = [
    { lang: 'nl', host: 'https://wetwijzer.be' },
    { lang: 'fr', host: 'https://lisloi.be' },
    { lang: 'de', host: 'https://gesetzguide.be' }
  ].freeze

  # GET /sitemap.xml - Sitemap Index
  def index
    # Count legislation entries (unique numacs)
    law_count = Legislation.where(is_archived: 0).distinct.count(:numac)

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
        # Homepage
        add_url(xml, '/', changefreq: 'daily', priority: '1.0')

        # Main sections
        add_url(xml, '/parliamentary_work', changefreq: 'weekly', priority: '0.7')
        add_url(xml, '/mps', changefreq: 'monthly', priority: '0.6')
        add_url(xml, '/zoeken', changefreq: 'weekly', priority: '0.7')
        add_url(xml, '/pricing', changefreq: 'monthly', priority: '0.5')
        add_url(xml, '/about', changefreq: 'monthly', priority: '0.5')
        add_url(xml, '/contact', changefreq: 'monthly', priority: '0.5')
        add_url(xml, '/support', changefreq: 'monthly', priority: '0.5')

        # Legal pages
        %w[privacy-nl privacy-fr privacy-en privacy-de
           terms-nl terms-fr terms-en terms-de
           imprint-nl imprint-fr imprint-en imprint-de
           accessibility-nl accessibility-fr accessibility-en accessibility-de].each do |page|
          add_url(xml, "/#{page}.html", changefreq: 'monthly', priority: '0.3')
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
    key = ['sitemap/laws/v1', request.host, page, CacheVersionHelper.laws_db_version].join('/')
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
      "[SITEMAP] page=#{page} hit=#{hit} gz_bytes=#{gz.bytesize}" + "#{" build_ms=#{build_ms}" if build_ms}"
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

  def build_laws_sitemap(page)
    offset = (page - 1) * 45_000

    numacs = Legislation.where(is_archived: 0)
                        .distinct
                        .order(:numac)
                        .limit(45_000)
                        .offset(offset)
                        .pluck(:numac)

    builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
      xml.urlset(sitemap_namespaces) do
        numacs.each do |numac|
          add_url(xml, "/laws/#{numac}", changefreq: 'monthly', priority: '0.6')
        end
      end
    end

    builder.to_xml
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

  # Adds a <url> entry with hreflang cross-references to all language domains
  def add_url(xml, path, changefreq: 'monthly', priority: '0.5')
    xml.url do
      xml.loc "#{base_url}#{path}"
      xml.changefreq changefreq
      xml.priority priority

      # Trilingual hreflang annotations
      LANGUAGE_DOMAINS.each do |ld|
        xml['xhtml'].link(
          rel: 'alternate',
          hreflang: ld[:lang],
          href: "#{ld[:host]}#{path}"
        )
      end

      # x-default points to Dutch (primary domain)
      xml['xhtml'].link(
        rel: 'alternate',
        hreflang: 'x-default',
        href: "https://wetwijzer.be#{path}"
      )
    end
  end
end
