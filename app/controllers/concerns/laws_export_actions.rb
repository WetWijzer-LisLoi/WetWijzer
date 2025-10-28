# frozen_string_literal: true

# == LawsExportActions Concern
#
# Extracted from LawsController (Product Evolution Target #2).
# Contains all Word export functionality: single law export, bilingual compare
# export, and Fisconet-specific export.
#
# @see LawsController
module LawsExportActions
  extend ActiveSupport::Concern

  # GET /laws/:numac/export_word
  #
  # Generates and downloads a Word (.docx) document containing all articles and section headings.
  def export_word
    # Fisconet exports use @fisconet_articles directly (set by set_law)
    return export_word_fisconet if @is_fisconet

    load_articles_data

    unless @articles.present?
      Rails.logger.warn("[SECURITY] Export attempt for law with no articles: #{params[:numac]}")
      redirect_to root_path, alert: t('laws.no_articles_to_export', default: 'Deze wet heeft geen artikelen om te exporteren.')
      return
    end

    Rails.logger.info("[EXPORT] Word export requested: #{params[:numac]} (#{@articles.size} articles) by #{request.remote_ip}")

    law_title = @law.present? ? helpers.strip_tags(@law.title) : params[:numac]
    citation_mode = params[:citation] == 'true'
    html_content = build_word_header(law_title)

    # Add Word's built-in TOC field
    section_headings = @articles.select { |a| a.article_type == 'LNK' }
    html_content += build_word_toc if section_headings.any?

    @articles.each do |article|
      html_content += render_article_html_for_word(article, citation_mode)
    end

    html_content += '</body></html>'

    base_name = law_title.parameterize.presence || params[:numac]
    filename = citation_mode ? "#{base_name}-citaat.doc" : "#{base_name}.doc"

    send_data html_content,
              filename: filename,
              type: 'application/msword',
              disposition: 'attachment'
  end

  # GET /laws/:numac/export_word_compare
  #
  # Generates a two-column Word document with NL and FR versions side by side.
  def export_word_compare
    law_nl = Legislation.find_by(numac: params[:numac], language_id: 1)
    law_fr = Legislation.find_by(numac: params[:numac], language_id: 2)
    articles_nl = Article.where(content_numac: params[:numac], language_id: 1).order(:id).to_a
    articles_fr = Article.where(content_numac: params[:numac], language_id: 2).order(:id).to_a

    unless articles_nl.present? || articles_fr.present?
      redirect_to root_path, alert: t('laws.no_articles_to_export', default: 'Deze wet heeft geen artikelen om te exporteren.')
      return
    end

    Rails.logger.info("[EXPORT] Word compare export: #{params[:numac]} (NL: #{articles_nl.size}, FR: #{articles_fr.size}) by #{request.remote_ip}")

    is_dutch_site = I18n.locale == :nl
    left_lang = is_dutch_site ? 'NL' : 'FR'
    right_lang = is_dutch_site ? 'FR' : 'NL'
    left_law = is_dutch_site ? law_nl : law_fr
    right_law = is_dutch_site ? law_fr : law_nl
    left_articles = is_dutch_site ? articles_nl : articles_fr
    right_articles = is_dutch_site ? articles_fr : articles_nl

    law_title_left = left_law.present? ? helpers.strip_tags(left_law.title) : params[:numac]
    law_title_right = right_law.present? ? helpers.strip_tags(right_law.title) : params[:numac]

    citation_mode = params[:citation] == 'true'
    html_content = build_word_compare_header(law_title_left, left_lang, right_lang, law_title_right)

    max_articles = [left_articles.size, right_articles.size].max
    max_articles.times do |i|
      left_html = render_article_for_word(left_articles[i], citation_mode)
      right_html = render_article_for_word(right_articles[i], citation_mode)
      row_class = left_articles[i]&.article_type == 'LNK' || right_articles[i]&.article_type == 'LNK' ? ' class="section"' : ''
      html_content += "<tr#{row_class}><td>#{left_html}</td><td>#{right_html}</td></tr>\n"
    end

    html_content += '</table></body></html>'

    citation_suffix = citation_mode ? '_citaat' : ''
    filename = "#{params[:numac]}_#{left_lang}_#{right_lang}#{citation_suffix}.doc"

    send_data html_content,
              filename: filename,
              type: 'application/msword',
              disposition: 'attachment'
  end

  private

  # Fisconet Word export — generates Word doc from @fisconet_articles
  def export_word_fisconet
    unless @fisconet_articles.present?
      Rails.logger.warn("[SECURITY] Export attempt for Fisconet law with no articles: #{params[:numac]}")
      redirect_to root_path, alert: t('laws.no_articles_to_export', default: 'Deze wet heeft geen artikelen om te exporteren.')
      return
    end

    Rails.logger.info("[EXPORT] Fisconet Word export: #{params[:numac]} (#{@fisconet_articles.size} articles) by #{request.remote_ip}")

    law_title = @law.present? ? helpers.strip_tags(@law.title.to_s) : params[:numac]
    citation_mode = params[:citation] == 'true'
    html_content = build_word_header(law_title)

    current_section = nil
    @fisconet_articles.each do |article|
      if article[:section_path].present? && article[:section_path] != current_section
        current_section = article[:section_path]
        is_top = current_section.match?(/^(HOOFDSTUK|TITEL|DEEL|CHAPITRE|TITRE|PART)/i)
        heading_tag = is_top ? 'h1' : 'h2'
        html_content += "<#{heading_tag}>#{ERB::Util.html_escape(current_section)}</#{heading_tag}>\n"
      end

      text = article[:text].to_s.strip
      html_src = article[:html].to_s.strip
      next if text.length <= 10 && html_src.length <= 10

      art_num = article[:article_number]
      body_text = html_src.present? && html_src.length > 10 ? helpers.strip_tags(html_src) : text

      if citation_mode
        body_text = body_text.gsub(/\[\d+\s*\.{3}\s*\d*\]/, '').gsub(/\[\d+\s*…\s*\d*\]/, '')
        body_text = body_text.lines.map(&:strip).join("\n").gsub(/\s+/, ' ').strip
      end

      body_escaped = ERB::Util.html_escape(body_text).gsub("\n", "<br>\n")
      html_content += "<p><b>Art. #{ERB::Util.html_escape(art_num)}.</b> #{body_escaped}</p>\n"
    end

    html_content += '</body></html>'

    base_name = law_title.parameterize.presence || params[:numac]
    filename = citation_mode ? "#{base_name}-citaat.doc" : "#{base_name}.doc"

    send_data html_content,
              filename: filename,
              type: 'application/msword',
              disposition: 'attachment'
  end

  # Render a single article for Word export
  def render_article_for_word(article, citation_mode)
    return '-' unless article.present?

    if article.article_type == 'LNK'
      heading_text = helpers.strip_tags(article.article_text).split(/\n|----------/).first.to_s.strip
      heading_text = heading_text.gsub(/\[\d+\s*/, '').gsub(/\s*\]\d+/, '').gsub(/\[\d+\]/, '')
      heading_text = heading_text.gsub(/&nbsp;/i, ' ').gsub(/\s+/, ' ').strip
      level = helpers.section_heading_level(heading_text)
      heading_tag = level <= 4 ? "h#{level}" : 'h4'
      "<#{heading_tag}>#{ERB::Util.html_escape(heading_text)}</#{heading_tag}>"
    else
      rendered_html = helpers.print_article(article.article_text, article.article_title, article.article_type)
      doc = Nokogiri::HTML.fragment(rendered_html)
      doc.css('br').each { |br| br.replace("\n") }

      if citation_mode
        doc.css('.ref-marker').each(&:remove)
        doc.css('.reference').each do |ref|
          text = ref.text.strip
          ref.remove if text.empty? || text.match?(/\A[.…\s]+\z/)
        end
        doc.css('.modification-marker, .domain-tag, .references-section, .abolished-marker').each(&:remove)
      end

      article_text = doc.text.strip
      article_text = clean_citation_text(article_text) if citation_mode

      "<p>#{ERB::Util.html_escape(article_text)}</p>"
    end
  end

  # Render a full article block for single-law export (includes bold article title, paragraph formatting)
  def render_article_html_for_word(article, citation_mode)
    if article.article_type == 'LNK'
      full_text = helpers.strip_tags(article.article_text).strip
      heading_text = full_text.split(/\n|----------/).first.to_s.strip
      heading_text = heading_text.gsub(/\[\d+\s*/, '').gsub(/\s*\]\d+/, '').gsub(/\[\d+\]/, '')
      heading_text = heading_text.gsub(/&nbsp;/i, ' ').gsub(/\s+/, ' ').strip

      level = helpers.section_heading_level(heading_text)
      heading_tag = level <= 6 ? "h#{level}" : 'h6'
      "<#{heading_tag}>#{ERB::Util.html_escape(heading_text)}</#{heading_tag}>\n"
    else
      rendered_html = helpers.print_article(article.article_text, article.article_title, article.article_type)
      doc = Nokogiri::HTML.fragment(rendered_html)
      doc.css('br').each { |br| br.replace("\n") }

      if citation_mode
        doc.css('.ref-marker').each(&:remove)
        doc.css('.reference').each do |ref|
          text = ref.text.strip
          ref.remove if text.empty? || text.match?(/\A[.…\s]+\z/)
        end
        doc.css('.modification-marker, .domain-tag, .references-section, .abolished-marker').each(&:remove)
      end

      article_text = doc.text.strip
      article_text = clean_citation_text(article_text) if citation_mode

      article_title_match = article_text.match(/\A(Art(?:ikel)?\.?\s*\d+[a-z]*\.?)/i)

      if article_title_match
        article_title_text = article_title_match[1]
        article_body = article_text[article_title_match[0].length..].strip

        article_body_escaped = ERB::Util.html_escape(article_body)
        article_body_formatted = article_body_escaped
                                 .gsub(/\n\n+/, "</p>\n<p style=\"text-indent: 1em;\">")
                                 .gsub("\n", "<br>\n")

        "<p><b>#{ERB::Util.html_escape(article_title_text)}</b> #{article_body_formatted}</p>\n"
      else
        article_text_escaped = ERB::Util.html_escape(article_text)
        article_text_formatted = article_text_escaped
                                 .gsub(/\n\n+/, "</p>\n<p style=\"text-indent: 1em;\">")
                                 .gsub("\n", "<br>\n")

        article_text_formatted.present? ? "<p>#{article_text_formatted}</p>\n" : ''
      end
    end
  end

  # Clean up citation text by removing reference artifacts
  def clean_citation_text(text)
    text = text.gsub(/\[\d+\s*\]\d*/, '').gsub(/\[\d+\]/, '').gsub(/\(\d+\)<[^>]*>/, '')
    text = text.gsub(/\[\d+\s*\.{3}\s*\d*\]/, '').gsub(/\[\d+\s*…\s*\d*\]/, '')
    text = text.gsub(/\[\d+\s/, ' ').gsub(/\]\d+/, '').gsub(/\[\d+\]/, '')
    text = text.gsub(/(?:^|\s)\.{3}(?:\s|$)/, ' ').gsub(/(?:^|\s)…(?:\s|$)/, ' ')
    text.lines.map(&:strip).join(' ').gsub(/\s+/, ' ').strip
  end

  # Build Word HTML header with XML namespace and styles
  def build_word_header(law_title)
    <<~HTML
      <html xmlns:o="urn:schemas-microsoft-com:office:office"
            xmlns:w="urn:schemas-microsoft-com:office:word"
            xmlns="http://www.w3.org/TR/REC-html40">
      <head>
        <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
        <title>#{ERB::Util.html_escape(law_title)}</title>
        <!--[if gte mso 9]>
        <xml>
          <w:WordDocument>
            <w:View>Print</w:View>
            <w:Zoom>100</w:Zoom>
          </w:WordDocument>
        </xml>
        <![endif]-->
        <style>
          body { font-family: "Times New Roman", serif; font-size: 12pt; }
          .title { font-size: 20pt; font-weight: bold; text-align: center; margin-bottom: 18pt; }
          h1 { font-size: 16pt; font-weight: bold; margin-top: 14pt; }
          h2 { font-size: 14pt; font-weight: bold; margin-top: 12pt; }
          h3 { font-size: 13pt; font-weight: bold; margin-top: 10pt; }
          h4 { font-size: 12pt; font-weight: bold; margin-top: 8pt; }
          h5 { font-size: 11pt; font-weight: bold; margin-top: 6pt; }
          h6 { font-size: 10pt; font-weight: bold; margin-top: 6pt; }
          p { margin: 6pt 0; }
        </style>
      </head>
      <body>
        <p style="text-align: right; font-size: 10pt; color: #666;">Geraadpleegd op: #{Date.today.strftime('%d/%m/%Y')}</p>
        <p class="title" style="mso-style-name:Title">#{ERB::Util.html_escape(law_title)}</p>
    HTML
  end

  # Build Word compare document header
  def build_word_compare_header(law_title_left, left_lang, right_lang, law_title_right)
    <<~HTML
      <html xmlns:o="urn:schemas-microsoft-com:office:office"
            xmlns:w="urn:schemas-microsoft-com:office:word"
            xmlns="http://www.w3.org/TR/REC-html40">
      <head>
        <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
        <title>#{ERB::Util.html_escape(law_title_left)} - #{left_lang}/#{right_lang}</title>
        <style>
          body { font-family: "Times New Roman", serif; font-size: 10pt; }
          table { width: 100%; border-collapse: collapse; }
          td { vertical-align: top; padding: 4pt; border: 1px solid #ccc; width: 50%; }
          .header { background-color: #f0f0f0; font-weight: bold; text-align: center; font-size: 12pt; }
          .title { font-size: 11pt; font-weight: bold; }
          .section { background-color: #f8f8f8; font-weight: bold; }
          h1, h2, h3, h4 { margin: 4pt 0; }
          h1 { font-size: 14pt; }
          h2 { font-size: 12pt; }
          h3 { font-size: 11pt; }
          p { margin: 4pt 0; }
        </style>
      </head>
      <body>
        <p style="text-align: right; font-size: 9pt; color: #666;">#{case I18n.locale when :fr then 'Consulté le' when :de then 'Abgerufen am' when :en then 'Accessed on' else 'Geraadpleegd op' end}: #{Date.today.strftime('%d/%m/%Y')}</p>
        <table>
          <tr class="header">
            <td>#{left_lang}</td>
            <td>#{right_lang}</td>
          </tr>
          <tr>
            <td class="title">#{ERB::Util.html_escape(law_title_left)}</td>
            <td class="title">#{ERB::Util.html_escape(law_title_right)}</td>
          </tr>
    HTML
  end

  # Build Word TOC field
  def build_word_toc
    <<~TOC
      <h2>Inhoud</h2>
      <!--[if gte mso 9]>
      <p class="MsoToc1">
      <span style="mso-field-code: TOC \\\\o &quot;1-6&quot; \\\\h \\\\z \\\\u">
      <span style="mso-element:field-begin"></span>
      TOC \\o "1-6" \\h \\z \\u
      <span style="mso-element:field-separator"></span>
      </span>
      <span style="mso-element:field-end"></span>
      </p>
      <![endif]-->
      <p><i>Klik met de rechtermuisknop en kies "Veld bijwerken" om de inhoudsopgave te genereren.</i></p>
      <br style="page-break-before: always;">
    TOC
  end
end
