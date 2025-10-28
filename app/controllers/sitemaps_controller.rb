# frozen_string_literal: true

# Serves dynamically generated XML sitemaps with trilingual hreflang annotations.
# Sitemap index splits content into sub-sitemaps of max 45,000 URLs each
# to stay under the 50,000 URL / 50MB limit per sitemap file.
#
# Each <url> entry includes xhtml:link elements pointing to the equivalent page
# on all three language domains (wetwijzer.be, lisloi.be, gesetzguide.be),
# enabling Google to understand the cross-domain language relationship.
class SitemapsController < ApplicationController
  # No authentication, no layout
  skip_before_action :verify_authenticity_token, raise: false

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
    law_count = legislation_db.execute(
      'SELECT COUNT(DISTINCT numac) FROM legislation WHERE is_archived = 0'
    ).first&.first.to_i

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
  def laws
    page = params[:page].to_i
    offset = (page - 1) * 45_000

    rows = legislation_db.execute(
      'SELECT DISTINCT numac FROM legislation WHERE is_archived = 0 ORDER BY numac LIMIT 45000 OFFSET ?',
      [offset]
    )

    builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
      xml.urlset(sitemap_namespaces) do
        rows.each do |row|
          numac = row[0]
          add_url(xml, "/laws/#{numac}", changefreq: 'monthly', priority: '0.6')
        end
      end
    end

    render xml: builder.to_xml
  end

  private

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

  def legislation_db
    @legislation_db ||= SQLite3::Database.new(
      Rails.root.join('storage', 'laws.prod.sqlite3').to_s,
      readonly: true
    )
  end
end
