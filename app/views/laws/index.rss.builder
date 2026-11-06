# frozen_string_literal: true

xml.instruct! :xml, version: '1.0', encoding: 'UTF-8'
xml.rss version: '2.0', 'xmlns:atom' => 'http://www.w3.org/2005/Atom' do
  xml.channel do
    xml.title rss_title
    xml.description rss_description
    xml.link laws_url(format: :html, **rss_site_params.symbolize_keys)
    xml.language I18n.locale.to_s
    xml.lastBuildDate Time.current.rfc2822
    xml.generator 'WetWijzer/LisLoi'

    # Self-referencing atom link for feed readers
    xml.tag! 'atom:link', href: laws_url(format: :rss, **@rss_feed_params.to_h.symbolize_keys), rel: 'self', type: 'application/rss+xml'

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
        xml.link law_url(law, language_id: law.language_id)
        xml.guid law_url(law, language_id: law.language_id), isPermaLink: 'true'

        pub_date = begin
          Date.parse(law.date)
        rescue StandardError
          nil
        end
        xml.pubDate pub_date.to_time.rfc2822 if pub_date

        type_label = law.respond_to?(:type) && law.type ? law.type.law_type : nil
        category = case I18n.locale
                   when :en, :de then I18n.t('credits.source_legislation')
                   when :fr then 'Législation'
                   else 'Wetgeving'
                   end
        xml.category category
        xml.category type_label.capitalize if type_label.present?

        description = []
        description << "<strong>#{category}</strong>"
        description << " – #{ERB::Util.html_escape(String.new(type_label&.capitalize.to_s))}" if type_label.present?
        description << "<br>NUMAC: #{ERB::Util.html_escape(String.new(law.numac.to_s))}"
        if pub_date
          label = case I18n.locale
                  when :fr then 'Date de promulgation'
                  when :en then 'Date of promulgation'
                  when :de then 'Ausfertigungsdatum'
                  else 'Afkondigingsdatum'
                  end
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

        category = case I18n.locale
                   when :en, :de then I18n.t('credits.source_jurisprudence')
                   when :fr then 'Jurisprudence'
                   else 'Rechtspraak'
                   end
        xml.category category

        description = []
        description << "<strong>#{category}</strong>"
        description << "<br>#{ERB::Util.html_escape(String.new(kase[:court].to_s))} – #{ERB::Util.html_escape(String.new(kase[:case_number].to_s))}"
        if kase[:decision_date].present?
          label = case I18n.locale
                  when :fr then 'Date de décision'
                  when :en then 'Date of decision'
                  when :de then 'Entscheidungsdatum'
                  else 'Beslissingsdatum'
                  end
          description << "<br>#{label}: #{ERB::Util.html_escape(String.new(kase[:decision_date].to_s))}"
        end

        xml.description description.join
      end
    end

    # === Parliamentary work items ===
    Array(@rss_parliamentary).each do |doc|
      xml.item do
        display_title = doc[:title].presence || doc[:dossier_number]
        # The corpus stores 'chamber' and 'senate' (58,250 and 25,834 rows on
        # 2026-10-31); the Dutch-only codes below came first and are kept.
        labels = JurisprudenceHelper::PARLIAMENT_LABELS[doc[:parliament].to_s]
        parliament_label = labels&.fetch(I18n.locale, labels[:nl]) ||
                           case doc[:parliament]
                           when 'kamer' then 'Kamer'
                           when 'senaat' then 'Senaat'
                           when 'vlaams' then 'Vlaams Parlement'
                           when 'brussels' then 'Brussels Parlement'
                           when 'waals' then 'Waals Parlement'
                           else doc[:parliament]
                           end
        xml.title "#{parliament_label} – #{display_title&.truncate(120)}"

        # The language load_rss_parliamentary selected: Dutch on the Dutch
        # interface, French everywhere else (LexLibera and GesetzGuide included).
        lang_id = (I18n.locale == :nl ? 1 : 2)
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

        category = case I18n.locale
                   when :en, :de then I18n.t('credits.source_parliamentary')
                   when :fr then 'Travaux parlementaires'
                   else 'Parlementaire stukken'
                   end
        xml.category category

        description = []
        description << "<strong>#{category}</strong>"
        description << " – #{ERB::Util.html_escape(String.new(parliament_label.to_s))}"
        description << "<br>#{ERB::Util.html_escape(String.new(doc[:dossier_number].to_s))}" if doc[:dossier_number].present?
        description << " (#{ERB::Util.html_escape(String.new(doc[:document_type].to_s))})" if doc[:document_type].present?
        if doc[:document_date].present?
          label = %i[fr en].include?(I18n.locale) ? 'Date' : 'Datum'
          description << "<br>#{label}: #{ERB::Util.html_escape(String.new(doc[:document_date].to_s))}"
        end

        xml.description description.join
      end
    end
  end
end
