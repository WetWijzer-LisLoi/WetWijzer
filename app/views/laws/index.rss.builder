xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
xml.rss version: "2.0", "xmlns:atom" => "http://www.w3.org/2005/Atom" do
  xml.channel do
    xml.title rss_title
    xml.description rss_description
    xml.link laws_url(format: :html, **request.query_parameters.except(:format))
    xml.language I18n.locale.to_s
    xml.lastBuildDate Time.current.rfc2822
    xml.generator "WetWijzer/LisLoi"
    
    # Self-referencing atom link for feed readers
    xml.tag! "atom:link", href: laws_url(format: :rss, **request.query_parameters.except(:format)), rel: "self", type: "application/rss+xml"
    
    # Image/logo
    xml.image do
      xml.url helpers.asset_url("favicon_#{I18n.locale == :fr ? 'fr' : 'nl'}.svg")
      xml.title rss_title
      xml.link root_url
    end
    
    @laws.first(50).each do |law|
      xml.item do
        xml.title law.title.presence || "NUMAC #{law.numac}"
        xml.link law_url(law)
        xml.guid law_url(law), isPermaLink: "true"
        
        # Publication date
        pub_date = law.publication_date || law.created_at
        xml.pubDate pub_date.to_time.rfc2822 if pub_date
        
        # Category based on law type
        type_name = law_type_name(law.type_id)
        xml.category type_name if type_name.present?
        
        # Description with introduction snippet
        description = []
        description << "<strong>#{type_name}</strong>" if type_name.present?
        description << "<br>NUMAC: #{law.numac}"
        description << "<br>#{I18n.t(:publication_date)}: #{law.publication_date&.strftime('%d-%m-%Y')}" if law.publication_date
        
        if law.content&.introduction.present?
          intro = helpers.strip_tags(law.content.introduction).truncate(500)
          description << "<br><br>#{intro}"
        end
        
        xml.description description.join
      end
    end
  end
end
