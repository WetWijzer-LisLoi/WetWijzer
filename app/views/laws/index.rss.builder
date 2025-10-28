# frozen_string_literal: true

xml.instruct! :xml, version: '1.0', encoding: 'UTF-8'
xml.rss version: '2.0', 'xmlns:atom' => 'http://www.w3.org/2005/Atom' do
  xml.channel do
    xml.title rss_title
    xml.description rss_description
    xml.link laws_url(format: :html, **request.query_parameters.except(:format))
    xml.language I18n.locale.to_s
    xml.lastBuildDate Time.current.rfc2822
    xml.generator 'WetWijzer/LisLoi'

    # Self-referencing atom link for feed readers
    xml.tag! 'atom:link', href: laws_url(format: :rss, **request.query_parameters.except(:format)), rel: 'self', type: 'application/rss+xml'

    # Image/logo
    xml.image do
      xml.url asset_url("favicon_#{I18n.locale == :fr ? 'fr' : 'nl'}.svg")
      xml.title rss_title
      xml.link root_url
    end

    # === Legislation items ===
    @laws.each do |law|
      xml.item do
        xml.title law.title.presence || "NUMAC #{law.numac}"
        xml.link law_url(law)
        xml.guid law_url(law), isPermaLink: 'true'

        pub_date = begin
          Date.parse(law.date)
        rescue StandardError
          nil
        end
        xml.pubDate pub_date.to_time.rfc2822 if pub_date

        type_label = law.respond_to?(:type) && law.type ? law.type.law_type : nil
        category = I18n.locale == :fr ? 'Législation' : 'Wetgeving'
        xml.category category
        xml.category type_label.capitalize if type_label.present?

        description = []
        description << "<strong>#{category}</strong>"
        description << " – #{type_label&.capitalize}" if type_label.present?
        description << "<br>NUMAC: #{law.numac}"
        if pub_date
          label = I18n.locale == :fr ? 'Date de promulgation' : 'Afkondigingsdatum'
          description << "<br>#{label}: #{pub_date.strftime('%d-%m-%Y')}"
        end

        xml.description description.join
      end
    end

    # === Jurisprudence items ===
    Array(@rss_jurisprudence).each do |kase|
      xml.item do
        title = "#{kase[:court]} – #{kase[:case_number]}"
        xml.title title

        item_url = jurisprudence_url(ecli: kase[:case_number])
        xml.link item_url
        xml.guid item_url, isPermaLink: 'true'

        if kase[:decision_date].present?
          pub_date = begin
            Date.parse(kase[:decision_date])
          rescue StandardError
            nil
          end
          xml.pubDate pub_date.to_time.rfc2822 if pub_date
        end

        category = I18n.locale == :fr ? 'Jurisprudence' : 'Rechtspraak'
        xml.category category

        description = []
        description << "<strong>#{category}</strong>"
        description << "<br>#{kase[:court]} – #{kase[:case_number]}"
        if kase[:decision_date].present?
          label = I18n.locale == :fr ? 'Date de décision' : 'Beslissingsdatum'
          description << "<br>#{label}: #{kase[:decision_date]}"
        end
        description << "<br><br>#{ERB::Util.html_escape(kase[:summary])}" if kase[:summary].present?

        xml.description description.join
      end
    end

    # === Parliamentary work items ===
    Array(@rss_parliamentary).each do |doc|
      xml.item do
        display_title = doc[:title].presence || doc[:dossier_number]
        parliament_label = case doc[:parliament]
                           when 'kamer' then 'Kamer'
                           when 'senaat' then 'Senaat'
                           when 'vlaams' then 'Vlaams Parlement'
                           when 'brussels' then 'Brussels Parlement'
                           when 'waals' then 'Waals Parlement'
                           else doc[:parliament]
                           end
        xml.title "#{parliament_label} – #{display_title&.truncate(120)}"

        lang_id = (I18n.locale == :fr ? 2 : 1)
        item_url = parliamentary_url(id: doc[:id], language_id: lang_id)
        xml.link item_url
        xml.guid item_url, isPermaLink: 'true'

        if doc[:document_date].present?
          pub_date = begin
            Date.parse(doc[:document_date])
          rescue StandardError
            nil
          end
          xml.pubDate pub_date.to_time.rfc2822 if pub_date
        end

        category = I18n.locale == :fr ? 'Travaux parlementaires' : 'Parlementaire stukken'
        xml.category category

        description = []
        description << "<strong>#{category}</strong>"
        description << " – #{parliament_label}"
        description << "<br>#{doc[:dossier_number]}" if doc[:dossier_number].present?
        description << " (#{doc[:document_type]})" if doc[:document_type].present?
        if doc[:document_date].present?
          label = I18n.locale == :fr ? 'Date' : 'Datum'
          description << "<br>#{label}: #{doc[:document_date]}"
        end

        xml.description description.join
      end
    end
  end
end
