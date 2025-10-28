# frozen_string_literal: true

# == OdtGenerator
#
# Generates OpenDocument Text (.odt) files for various export contexts.
# ODT is a ZIP-based format with XML content, supported natively by
# LibreOffice, Google Docs, and many other word processors.
#
# Zero external dependencies – uses Ruby stdlib (zlib, stringio) only.
#
# Usage:
#   OdtGenerator.law_document(title:, articles:, citation_mode: false)
#   OdtGenerator.law_compare_document(title_left:, title_right:, ...)
#   OdtGenerator.fisconet_document(title:, fisconet_articles:, ...)
#   OdtGenerator.jurisprudence_document(case_data:, body_text:, locale:)
#
class OdtGenerator
  require 'zlib'
  require 'stringio'

  class << self
    # ── Law Document (single law) ─────────────────────────────────────────

    def law_document(title:, articles:, citation_mode: false, accessed_date: nil, locale: :nl)
      accessed_date ||= Date.today.strftime('%d/%m/%Y')
      accessed_label = accessed_label_for(locale)

      body_xml = +''
      body_xml << heading(esc(title), level: 1)
      body_xml << paragraph(esc("#{accessed_label}: #{accessed_date}"), style: 'Subtle')

      articles.each do |article|
        body_xml << render_law_article_odt(article, citation_mode)
      end

      body_xml << horizontal_rule
      body_xml << paragraph(esc("#{brand_for(locale)} · #{domain_for(locale)}"), style: 'Subtle')

      build_odt(body_xml, title: title, author: brand_for(locale))
    end

    # ── Law Compare Document (bilingual) ──────────────────────────────────

    def law_compare_document(title_left:, title_right:, left_lang:, right_lang:,
                             left_articles:, right_articles:, citation_mode: false,
                             accessed_date: nil, locale: :nl)
      accessed_date ||= Date.today.strftime('%d/%m/%Y')
      accessed_label = accessed_label_for(locale)
      max_count = [left_articles.size, right_articles.size].max

      body_xml = +''
      body_xml << heading(esc("#{title_left} – #{left_lang}/#{right_lang}"), level: 1)
      body_xml << paragraph(esc("#{accessed_label}: #{accessed_date}"), style: 'Subtle')

      # Table header
      body_xml << '<table:table table:name="CompareTable" table:style-name="CompareTable">'
      body_xml << ('<table:table-column table:style-name="CompareCol"/>' * 2)

      # Header row
      body_xml << '<table:table-row>'
      body_xml << table_cell("<text:p text:style-name=\"TableHeading\">#{esc(left_lang)}</text:p>")
      body_xml << table_cell("<text:p text:style-name=\"TableHeading\">#{esc(right_lang)}</text:p>")
      body_xml << '</table:table-row>'

      # Title row
      body_xml << '<table:table-row>'
      body_xml << table_cell("<text:p text:style-name=\"TableContent\"><text:span text:style-name=\"Bold\">#{esc(title_left)}</text:span></text:p>")
      body_xml << table_cell("<text:p text:style-name=\"TableContent\"><text:span text:style-name=\"Bold\">#{esc(title_right)}</text:span></text:p>")
      body_xml << '</table:table-row>'

      max_count.times do |i|
        left_text = render_article_cell(left_articles[i], citation_mode)
        right_text = render_article_cell(right_articles[i], citation_mode)
        body_xml << '<table:table-row>'
        body_xml << table_cell(left_text)
        body_xml << table_cell(right_text)
        body_xml << '</table:table-row>'
      end

      body_xml << '</table:table>'
      body_xml << horizontal_rule
      body_xml << paragraph(esc("#{brand_for(locale)} · #{domain_for(locale)}"), style: 'Subtle')

      build_odt(body_xml, title: "#{title_left} – #{left_lang}/#{right_lang}", author: brand_for(locale))
    end

    # ── Fisconet Law Document ─────────────────────────────────────────────

    def fisconet_document(title:, fisconet_articles:, citation_mode: false, accessed_date: nil, locale: :nl)
      accessed_date ||= Date.today.strftime('%d/%m/%Y')
      accessed_label = accessed_label_for(locale)

      body_xml = +''
      body_xml << heading(esc(title), level: 1)
      body_xml << paragraph(esc("#{accessed_label}: #{accessed_date}"), style: 'Subtle')

      current_section = nil
      fisconet_articles.each do |article|
        if article[:section_path].present? && article[:section_path] != current_section
          current_section = article[:section_path]
          is_top = current_section.match?(/^(HOOFDSTUK|TITEL|DEEL|CHAPITRE|TITRE|PART)/i)
          body_xml << heading(esc(current_section), level: is_top ? 2 : 3)
        end

        text = article[:text].to_s.strip
        html_src = article[:html].to_s.strip
        next if text.length <= 10 && html_src.length <= 10

        art_num = article[:article_number]
        body_text = html_src.present? && html_src.length > 10 ? strip_html(html_src) : text

        if citation_mode
          body_text = body_text.gsub(/\[\d+\s*\.{3}\s*\d*\]/, '').gsub(/\[\d+\s*…\s*\d*\]/, '')
          body_text = body_text.lines.map(&:strip).join("\n").gsub(/\s+/, ' ').strip
        end

        body_xml << article_paragraph("Art. #{art_num}.", body_text)
      end

      body_xml << horizontal_rule
      body_xml << paragraph(esc("#{brand_for(locale)} · #{domain_for(locale)}"), style: 'Subtle')

      build_odt(body_xml, title: title, author: brand_for(locale))
    end

    # ── Jurisprudence Document ────────────────────────────────────────────

    def jurisprudence_document(case_data:, body_text:, locale: :nl, pseudonymized: false)
      court = case_data[:court].to_s
      date = case_data[:decision_date].to_s
      ecli = case_data[:case_number].to_s
      subject = case_data[:subject_matter].to_s.presence
      outcome = case_data[:outcome].to_s.presence
      accessed_label = accessed_label_for(locale)
      labels = jurisprudence_labels(locale)

      body_xml = +''
      body_xml << heading(esc(ecli), level: 1)

      # Metadata table
      body_xml << '<table:table table:name="MetaTable" table:style-name="MetaTable">'
      body_xml << '<table:table-column table:style-name="MetaColLabel"/>'
      body_xml << '<table:table-column table:style-name="MetaColValue"/>'

      [[labels[:court], court], [labels[:date], date]].each do |label, value|
        body_xml << '<table:table-row>'
        body_xml << table_cell("<text:p text:style-name=\"TableContent\"><text:span text:style-name=\"Bold\">#{esc(label)}:</text:span></text:p>")
        body_xml << table_cell("<text:p text:style-name=\"TableContent\">#{esc(value)}</text:p>")
        body_xml << '</table:table-row>'
      end

      if subject
        body_xml << '<table:table-row>'
        body_xml << table_cell("<text:p text:style-name=\"TableContent\"><text:span text:style-name=\"Bold\">#{esc(labels[:subject])}:</text:span></text:p>")
        body_xml << table_cell("<text:p text:style-name=\"TableContent\">#{esc(subject)}</text:p>")
        body_xml << '</table:table-row>'
      end

      if outcome
        body_xml << '<table:table-row>'
        body_xml << table_cell("<text:p text:style-name=\"TableContent\"><text:span text:style-name=\"Bold\">#{esc(labels[:ruling])}:</text:span></text:p>")
        body_xml << table_cell("<text:p text:style-name=\"TableContent\">#{esc(outcome)}</text:p>")
        body_xml << '</table:table-row>'
      end

      body_xml << '</table:table>'

      # Body text
      body_text.to_s.split(/\n\n+/).each do |para|
        next if para.strip.blank?

        body_xml << paragraph(esc(para.strip))
      end

      body_xml << horizontal_rule
      body_xml << paragraph(esc("#{accessed_label}: #{Date.today.strftime('%d/%m/%Y')} – #{brand_for(locale)}"), style: 'Subtle')

      if pseudonymized
        pseudo_label = case locale
                       when :fr then 'Texte pseudonymisé (RGPD)'
                       when :de then 'Pseudonymisierter Text (DSGVO)'
                       when :en then 'Pseudonymised text (GDPR)'
                       else 'Gepseudonimiseerde tekst (GDPR)'
                       end
        body_xml << paragraph(esc(pseudo_label), style: 'Subtle')
      end

      build_odt(body_xml, title: ecli, author: brand_for(locale))
    end

    private

    # ── XML Helpers ───────────────────────────────────────────────────────

    def esc(text)
      return '' if text.blank?

      text.to_s
          .gsub('&', '&amp;')
          .gsub('<', '&lt;')
          .gsub('>', '&gt;')
          .gsub('"', '&quot;')
          .gsub("'", '&apos;')
    end

    def heading(text, level: 1)
      %(<text:h text:style-name="Heading_20_#{level}" text:outline-level="#{level}">#{text}</text:h>\n)
    end

    def paragraph(text, style: 'Standard')
      %(<text:p text:style-name="#{style}">#{text}</text:p>\n)
    end

    def article_paragraph(art_title, body)
      %(<text:p text:style-name="Standard"><text:span text:style-name="Bold">#{esc(art_title)}</text:span> #{esc(body)}</text:p>\n)
    end

    def horizontal_rule
      %(<text:p text:style-name="Horizontal_20_Line"/>\n)
    end

    def table_cell(content)
      %(<table:table-cell table:style-name="TableCell"><#{'<text:p text:style-name="TableContent">' unless content.start_with?('<text:p')}#{content}#{'</text:p>' unless content.start_with?('<text:p')}</table:table-cell>)
    end

    # ── Article Rendering ─────────────────────────────────────────────────

    def render_law_article_odt(article, citation_mode)
      return '' unless article.present?

      if article.article_type == 'LNK'
        heading_text = ActionController::Base.helpers.strip_tags(article.article_text).split(/\n|----------/).first.to_s.strip
        heading_text = heading_text.gsub(/\[\d+\s*/, '').gsub(/\s*\]\d+/, '').gsub(/\[\d+\]/, '')
        heading_text = heading_text.gsub(/&nbsp;/i, ' ').gsub(/\s+/, ' ').strip
        level = heading_level(heading_text)
        heading(esc(heading_text), level: level)
      else
        rendered = ActionController::Base.helpers.strip_tags(article.article_text.to_s).strip

        if citation_mode
          rendered = rendered.gsub(/\[\d+\s*\.{3}\s*\d*\]/, '').gsub(/\[\d+\s*…\s*\d*\]/, '')
          rendered = rendered.gsub(/\[\d+\s*/, ' ').gsub(/\]\d+/, '').gsub(/\[\d+\]/, '')
          rendered = rendered.lines.map(&:strip).join(' ').gsub(/\s+/, ' ').strip
        end

        title_match = rendered.match(/\A(Art(?:ikel)?\.?\s*\d+[a-z]*\.?)/i)
        if title_match
          article_paragraph(title_match[1], rendered[title_match[0].length..].strip)
        else
          rendered.present? ? paragraph(esc(rendered)) : ''
        end
      end
    end

    def render_article_cell(article, citation_mode)
      return '<text:p text:style-name="TableContent">–</text:p>' unless article.present?

      if article.article_type == 'LNK'
        heading_text = ActionController::Base.helpers.strip_tags(article.article_text).split(/\n|----------/).first.to_s.strip
        heading_text = heading_text.gsub(/\[\d+\s*/, '').gsub(/\s*\]\d+/, '').gsub(/\[\d+\]/, '')
        heading_text = heading_text.gsub(/&nbsp;/i, ' ').gsub(/\s+/, ' ').strip
        "<text:p text:style-name=\"TableContent\"><text:span text:style-name=\"Bold\">#{esc(heading_text)}</text:span></text:p>"
      else
        text = ActionController::Base.helpers.strip_tags(article.article_text.to_s).strip

        if citation_mode
          text = text.gsub(/\[\d+\s*\.{3}\s*\d*\]/, '').gsub(/\[\d+\s*…\s*\d*\]/, '')
          text = text.lines.map(&:strip).join(' ').gsub(/\s+/, ' ').strip
        end

        title_match = text.match(/\A(Art(?:ikel)?\.?\s*\d+[a-z]*\.?)/i)
        if title_match
          "<text:p text:style-name=\"TableContent\"><text:span text:style-name=\"Bold\">#{esc(title_match[1])}</text:span> #{esc(text[title_match[0].length..].strip)}</text:p>"
        else
          "<text:p text:style-name=\"TableContent\">#{esc(text)}</text:p>"
        end
      end
    end

    def heading_level(text)
      case text
      when /\A(DEEL|PARTIE|PART|LIVRE|BOEK)\b/i then 1
      when /\A(TITEL|TITRE|TITLE)\b/i then 2
      when /\A(HOOFDSTUK|CHAPITRE|CHAPTER|KAPITEL)\b/i then 3
      when /\A(AFDELING|SECTION)\b/i then 4
      when /\A(ONDERAFDELING|SOUS-SECTION|SUBSECTION)\b/i then 5
      else 6 # -- intentional: unknown headings get generic level
      end
    end

    # ── ODT File Construction ─────────────────────────────────────────────

    def build_odt(body_xml, title: '', author: 'WetWijzer')
      content_xml = content_xml_document(body_xml)
      styles_xml = styles_xml_document
      meta_xml = meta_xml_document(title: title, author: author)
      manifest_xml = manifest_xml_document
      mimetype = 'application/vnd.oasis.opendocument.text'

      # Build ZIP using stdlib – mimetype MUST be first entry, stored (not deflated)
      zip_buffer = StringIO.new(''.b)
      zip_buffer.set_encoding(Encoding::BINARY)

      entries = []

      # 1. mimetype – stored (no compression)
      entries << zip_entry_stored('mimetype', mimetype.b)

      # 2. content.xml – deflated
      entries << zip_entry_deflated('content.xml', content_xml.encode('UTF-8').b)

      # 3. styles.xml – deflated
      entries << zip_entry_deflated('styles.xml', styles_xml.encode('UTF-8').b)

      # 4. meta.xml – deflated
      entries << zip_entry_deflated('meta.xml', meta_xml.encode('UTF-8').b)

      # 5. META-INF/manifest.xml – deflated
      entries << zip_entry_deflated('META-INF/manifest.xml', manifest_xml.encode('UTF-8').b)

      write_zip(zip_buffer, entries)
      zip_buffer.string
    end

    # ── Minimal ZIP writer (no gems needed) ───────────────────────────────

    ZipEntry = Struct.new(:name, :data, :compressed, :crc32, :comp_size, :uncomp_size, :compression_method, keyword_init: true)

    def zip_entry_stored(name, data)
      ZipEntry.new(
        name: name, data: data, compressed: data,
        crc32: Zlib.crc32(data), comp_size: data.bytesize,
        uncomp_size: data.bytesize, compression_method: 0
      )
    end

    def zip_entry_deflated(name, data)
      deflated = Zlib::Deflate.deflate(data, Zlib::BEST_COMPRESSION)
      # Strip zlib header (2 bytes) and checksum (4 bytes) to get raw deflate
      raw = deflated[2..-5] || deflated
      ZipEntry.new(
        name: name, data: data, compressed: raw,
        crc32: Zlib.crc32(data), comp_size: raw.bytesize,
        uncomp_size: data.bytesize, compression_method: 8
      )
    end

    def write_zip(output, entries)
      offsets = []

      # Local file headers + data
      entries.each do |entry|
        offsets << output.pos
        name_bytes = entry.name.encode('UTF-8').b
        # Local file header
        output.write([0x04034b50].pack('V'))                    # signature
        output.write([20].pack('v'))                            # version needed
        output.write([0].pack('v'))                             # flags
        output.write([entry.compression_method].pack('v')) # compression
        output.write([0, 0].pack('vv'))                         # mod time/date
        output.write([entry.crc32].pack('V'))                   # crc32
        output.write([entry.comp_size].pack('V'))               # compressed size
        output.write([entry.uncomp_size].pack('V'))             # uncompressed size
        output.write([name_bytes.bytesize].pack('v'))           # filename length
        output.write([0].pack('v'))                             # extra field length
        output.write(name_bytes)
        output.write(entry.compressed)
      end

      # Central directory
      cd_start = output.pos
      entries.each_with_index do |entry, i|
        name_bytes = entry.name.encode('UTF-8').b
        output.write([0x02014b50].pack('V'))                    # signature
        output.write([20].pack('v'))                            # version made by
        output.write([20].pack('v'))                            # version needed
        output.write([0].pack('v'))                             # flags
        output.write([entry.compression_method].pack('v')) # compression
        output.write([0, 0].pack('vv'))                         # mod time/date
        output.write([entry.crc32].pack('V'))                   # crc32
        output.write([entry.comp_size].pack('V'))               # compressed size
        output.write([entry.uncomp_size].pack('V'))             # uncompressed size
        output.write([name_bytes.bytesize].pack('v'))           # filename length
        output.write([0].pack('v'))                             # extra field length
        output.write([0].pack('v'))                             # comment length
        output.write([0].pack('v'))                             # disk number start
        output.write([0].pack('v'))                             # internal attrs
        output.write([0].pack('V'))                             # external attrs
        output.write([offsets[i]].pack('V'))                    # relative offset
        output.write(name_bytes)
      end
      cd_end = output.pos
      cd_size = cd_end - cd_start

      # End of central directory
      output.write([0x06054b50].pack('V'))                      # signature
      output.write([0].pack('v'))                               # disk number
      output.write([0].pack('v'))                               # disk with CD
      output.write([entries.size].pack('v'))                     # entries on disk
      output.write([entries.size].pack('v'))                     # total entries
      output.write([cd_size].pack('V'))                          # CD size
      output.write([cd_start].pack('V'))                         # CD offset
      output.write([0].pack('v')) # comment length
    end

    # ── ODT XML Templates ─────────────────────────────────────────────────

    def content_xml_document(body)
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content
          xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
          xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
          xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
          xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
          office:version="1.3">
          <office:automatic-styles>
            <style:style style:name="Bold" style:family="text">
              <style:text-properties fo:font-weight="bold"/>
            </style:style>
            <style:style style:name="Subtle" style:family="paragraph" style:parent-style-name="Standard">
              <style:text-properties fo:font-size="9pt" fo:color="#888888"/>
            </style:style>
            <style:style style:name="Horizontal_20_Line" style:family="paragraph">
              <style:paragraph-properties fo:border-bottom="0.5pt solid #999999" fo:padding-bottom="6pt" fo:margin-bottom="6pt"/>
            </style:style>
            <style:style style:name="TableHeading" style:family="paragraph">
              <style:text-properties fo:font-weight="bold" fo:font-size="11pt"/>
              <style:paragraph-properties fo:text-align="center"/>
            </style:style>
            <style:style style:name="TableContent" style:family="paragraph">
              <style:text-properties fo:font-size="10pt"/>
            </style:style>
            <style:style style:name="CompareTable" style:family="table">
              <style:table-properties style:width="17cm" table:align="margins"/>
            </style:style>
            <style:style style:name="CompareCol" style:family="table-column">
              <style:table-column-properties style:column-width="8.5cm"/>
            </style:style>
            <style:style style:name="MetaTable" style:family="table">
              <style:table-properties style:width="17cm" table:align="margins"/>
            </style:style>
            <style:style style:name="MetaColLabel" style:family="table-column">
              <style:table-column-properties style:column-width="4cm"/>
            </style:style>
            <style:style style:name="MetaColValue" style:family="table-column">
              <style:table-column-properties style:column-width="13cm"/>
            </style:style>
            <style:style style:name="TableCell" style:family="table-cell">
              <style:table-cell-properties fo:padding="3pt" fo:border-bottom="0.5pt solid #cccccc"/>
            </style:style>
          </office:automatic-styles>
          <office:body>
            <office:text>
        #{body}
            </office:text>
          </office:body>
        </office:document-content>
      XML
    end

    def styles_xml_document
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-styles
          xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
          xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
          xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
          office:version="1.3">
          <office:styles>
            <style:style style:name="Standard" style:family="paragraph">
              <style:text-properties fo:font-family="Liberation Serif" fo:font-size="11pt"/>
              <style:paragraph-properties fo:text-align="justify" fo:margin-bottom="0.3cm"/>
            </style:style>
            <style:style style:name="Heading_20_1" style:family="paragraph" style:parent-style-name="Standard" style:next-style-name="Standard" style:class="text">
              <style:text-properties fo:font-size="18pt" fo:font-weight="bold" fo:color="#1e3a5f"/>
              <style:paragraph-properties fo:margin-top="0.5cm" fo:margin-bottom="0.3cm" fo:keep-with-next="always"/>
            </style:style>
            <style:style style:name="Heading_20_2" style:family="paragraph" style:parent-style-name="Standard" style:next-style-name="Standard" style:class="text">
              <style:text-properties fo:font-size="15pt" fo:font-weight="bold" fo:color="#2c5282"/>
              <style:paragraph-properties fo:margin-top="0.4cm" fo:margin-bottom="0.2cm" fo:keep-with-next="always"/>
            </style:style>
            <style:style style:name="Heading_20_3" style:family="paragraph" style:parent-style-name="Standard" style:next-style-name="Standard" style:class="text">
              <style:text-properties fo:font-size="13pt" fo:font-weight="bold" fo:color="#2d3748"/>
              <style:paragraph-properties fo:margin-top="0.3cm" fo:margin-bottom="0.2cm" fo:keep-with-next="always"/>
            </style:style>
            <style:style style:name="Heading_20_4" style:family="paragraph" style:parent-style-name="Standard" style:next-style-name="Standard" style:class="text">
              <style:text-properties fo:font-size="11pt" fo:font-weight="bold" fo:color="#4a5568"/>
              <style:paragraph-properties fo:margin-top="0.2cm" fo:margin-bottom="0.2cm" fo:keep-with-next="always"/>
            </style:style>
            <style:style style:name="Heading_20_5" style:family="paragraph" style:parent-style-name="Standard" style:next-style-name="Standard" style:class="text">
              <style:text-properties fo:font-size="10pt" fo:font-weight="bold" fo:font-style="italic"/>
              <style:paragraph-properties fo:margin-top="0.15cm" fo:margin-bottom="0.15cm" fo:keep-with-next="always"/>
            </style:style>
            <style:style style:name="Heading_20_6" style:family="paragraph" style:parent-style-name="Standard" style:next-style-name="Standard" style:class="text">
              <style:text-properties fo:font-size="10pt" fo:font-style="italic"/>
              <style:paragraph-properties fo:margin-top="0.1cm" fo:margin-bottom="0.1cm" fo:keep-with-next="always"/>
            </style:style>
          </office:styles>
          <office:automatic-styles>
            <style:page-layout style:name="pm1">
              <style:page-layout-properties fo:page-width="21cm" fo:page-height="29.7cm" fo:margin-top="2cm" fo:margin-bottom="2cm" fo:margin-left="2cm" fo:margin-right="2cm"/>
            </style:page-layout>
          </office:automatic-styles>
          <office:master-styles>
            <style:master-page style:name="Standard" style:page-layout-name="pm1"/>
          </office:master-styles>
        </office:document-styles>
      XML
    end

    def meta_xml_document(title: '', author: '')
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-meta
          xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0"
          xmlns:dc="http://purl.org/dc/elements/1.1/"
          office:version="1.3">
          <office:meta>
            <dc:title>#{esc(title)}</dc:title>
            <dc:creator>#{esc(author)}</dc:creator>
            <meta:creation-date>#{Time.now.iso8601}</meta:creation-date>
            <meta:generator>#{esc(author)} OdtGenerator</meta:generator>
          </office:meta>
        </office:document-meta>
      XML
    end

    def manifest_xml_document
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">
          <manifest:file-entry manifest:full-path="/" manifest:version="1.3" manifest:media-type="application/vnd.oasis.opendocument.text"/>
          <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
          <manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>
          <manifest:file-entry manifest:full-path="meta.xml" manifest:media-type="text/xml"/>
        </manifest:manifest>
      XML
    end

    # ── Shared ────────────────────────────────────────────────────────────

    def brand_for(locale)
      case locale
      when :fr then 'LisLoi'
      when :de then 'GesetzGuide'
      when :en then 'LexLibera'
      else 'WetWijzer'
      end
    end

    def domain_for(locale)
      case locale
      when :fr then 'lisloi.be'
      when :de then 'gesetzguide.be'
      when :en then 'lexlibera.be'
      else 'wetwijzer.be'
      end
    end

    def accessed_label_for(locale)
      case locale
      when :fr then 'Consulté le'
      when :de then 'Abgerufen am'
      when :en then 'Accessed on'
      else 'Geraadpleegd op'
      end
    end

    def jurisprudence_labels(locale)
      case locale
      when :fr then { court: 'Juridiction', date: 'Date', subject: 'Domaine', ruling: 'Décision' }
      when :de then { court: 'Gericht', date: 'Datum', subject: 'Rechtsgebiet', ruling: 'Urteil' }
      when :en then { court: 'Court', date: 'Date', subject: 'Subject', ruling: 'Ruling' }
      else { court: 'Rechtsinstantie', date: 'Datum', subject: 'Rechtsdomein', ruling: 'Uitspraak' }
      end
    end

    def strip_html(html)
      ActionController::Base.helpers.strip_tags(html.to_s)
    end
  end
end
