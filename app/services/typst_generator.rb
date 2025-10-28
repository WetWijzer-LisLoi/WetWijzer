# frozen_string_literal: true

# == TypstGenerator
#
# Generates Typst markup (.typ) for various export contexts.
# Typst is a modern, open-source typesetting system (https://typst.app).
#
# Usage:
#   TypstGenerator.law_document(title:, articles:, citation_mode: false)
#   TypstGenerator.law_compare_document(title_left:, title_right:, ...)
#   TypstGenerator.jurisprudence_document(case_data:, body_text:, locale:)
#
class TypstGenerator
  class << self
    # ── Escaping ──────────────────────────────────────────────────────────
    # Typst special characters that need escaping with backslash
    TYPST_SPECIAL = %w[# $ * _ @ ~ ` < >].freeze

    def escape(text)
      return '' if text.blank?

      result = text.to_s
      # Escape backslashes first, then special chars
      result = result.gsub('\\', '\\\\')
      TYPST_SPECIAL.each { |c| result = result.gsub(c, "\\#{c}") }
      result
    end

    # ── Law Document (single law) ─────────────────────────────────────────

    def law_document(title:, articles:, citation_mode: false, accessed_date: nil, locale: :nl)
      accessed_date ||= Date.today.strftime('%d/%m/%Y')
      accessed_label = accessed_label_for(locale)

      typ = document_preamble(title: title, author: brand_for(locale))
      typ += <<~TYPST
        #align(right, text(size: 9pt, fill: luma(120))[#{escape(accessed_label)}: #{escape(accessed_date)}])

        #align(center, text(size: 18pt, weight: "bold")[#{escape(title)}])

        #v(1em)

      TYPST

      articles.each do |article|
        typ += render_law_article_typst(article, citation_mode)
      end

      typ += footer_block(locale)
      typ
    end

    # ── Law Compare Document (bilingual) ──────────────────────────────────

    def law_compare_document(title_left:, title_right:, left_lang:, right_lang:,
                             left_articles:, right_articles:, citation_mode: false,
                             accessed_date: nil, locale: :nl)
      accessed_date ||= Date.today.strftime('%d/%m/%Y')
      accessed_label = accessed_label_for(locale)
      max_count = [left_articles.size, right_articles.size].max

      typ = document_preamble(
        title: "#{title_left} – #{left_lang}/#{right_lang}",
        author: brand_for(locale)
      )

      typ += <<~TYPST
        #align(right, text(size: 9pt, fill: luma(120))[#{escape(accessed_label)}: #{escape(accessed_date)}])

        #v(0.5em)

        #grid(
          columns: (1fr, 1fr),
          gutter: 12pt,
          align(center, text(weight: "bold", size: 13pt)[#{escape(left_lang)}]),
          align(center, text(weight: "bold", size: 13pt)[#{escape(right_lang)}]),
          text(weight: "bold", size: 10pt)[#{escape(title_left)}],
          text(weight: "bold", size: 10pt)[#{escape(title_right)}],
      TYPST

      max_count.times do |i|
        left_text = render_article_text(left_articles[i], citation_mode)
        right_text = render_article_text(right_articles[i], citation_mode)
        typ += "    [#{left_text}],\n"
        typ += "    [#{right_text}],\n"
      end

      typ += ")\n\n"
      typ += footer_block(locale)
      typ
    end

    # ── Fisconet Law Document ─────────────────────────────────────────────

    def fisconet_document(title:, fisconet_articles:, citation_mode: false, accessed_date: nil, locale: :nl)
      accessed_date ||= Date.today.strftime('%d/%m/%Y')
      accessed_label = accessed_label_for(locale)

      typ = document_preamble(title: title, author: brand_for(locale))
      typ += <<~TYPST
        #align(right, text(size: 9pt, fill: luma(120))[#{escape(accessed_label)}: #{escape(accessed_date)}])

        #align(center, text(size: 18pt, weight: "bold")[#{escape(title)}])

        #v(1em)

      TYPST

      current_section = nil
      fisconet_articles.each do |article|
        if article[:section_path].present? && article[:section_path] != current_section
          current_section = article[:section_path]
          is_top = current_section.match?(/^(HOOFDSTUK|TITEL|DEEL|CHAPITRE|TITRE|PART)/i)
          heading = is_top ? '= ' : '== '
          typ += "\n#{heading}#{escape(current_section)}\n\n"
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

        typ += "*Art. #{escape(art_num)}.* #{escape(body_text)}\n\n"
      end

      typ += footer_block(locale)
      typ
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

      typ = document_preamble(title: ecli, author: brand_for(locale))
      typ += <<~TYPST
        #rect(fill: luma(245), width: 100%, inset: 12pt, stroke: (bottom: 2pt + luma(60)))[
          #text(size: 14pt, weight: "bold")[#{escape(ecli)}]

          #table(
            columns: (auto, 1fr),
            stroke: none,
            inset: 3pt,
            [*#{escape(labels[:court])}:*], [#{escape(court)}],
            [*#{escape(labels[:date])}:*], [#{escape(date)}],
      TYPST

      typ += "        [*#{escape(labels[:subject])}:*], [#{escape(subject)}],\n" if subject
      typ += "        [*#{escape(labels[:ruling])}:*], [#{escape(outcome)}],\n" if outcome

      typ += <<~TYPST
          )
        ]

        #v(1em)

      TYPST

      # Body text – split paragraphs
      body_text.to_s.split(/\n\n+/).each do |para|
        next if para.strip.blank?

        typ += "#{escape(para.strip)}\n\n"
      end

      typ += "\n#line(length: 100%, stroke: 0.5pt + luma(180))\n\n"
      typ += "#text(size: 9pt, fill: luma(140))[#{escape(accessed_label)}: #{escape(Date.today.strftime('%d/%m/%Y'))} – #{escape(brand_for(locale))}]\n\n"

      if pseudonymized
        pseudo_label = case locale
                       when :fr then 'Texte pseudonymisé (RGPD)'
                       when :de then 'Pseudonymisierter Text (DSGVO)'
                       when :en then 'Pseudonymised text (GDPR)'
                       else 'Gepseudonimiseerde tekst (GDPR)'
                       end
        typ += "#text(size: 9pt, fill: luma(140))[#{escape(pseudo_label)}]\n"
      end

      typ
    end

    private

    # ── Shared Helpers ────────────────────────────────────────────────────

    def document_preamble(title:, author:)
      <<~TYPST
        // Generated by #{author} – https://typst.app to compile
        #set document(title: "#{escape(title)}", author: "#{escape(author)}")
        #set page(margin: 2cm)
        #set text(font: "New Computer Modern", size: 11pt, lang: "nl")
        #set par(justify: true)
        #set heading(numbering: none)

      TYPST
    end

    def footer_block(locale)
      brand = brand_for(locale)
      domain = domain_for(locale)
      <<~TYPST

        #v(1fr)
        #line(length: 100%, stroke: 0.5pt + luma(180))
        #text(size: 8pt, fill: luma(140))[#{escape(brand)} · #{escape(domain)}]
      TYPST
    end

    def render_law_article_typst(article, citation_mode)
      return '' unless article.present?

      if article.article_type == 'LNK'
        # Section heading
        heading_text = ActionController::Base.helpers.strip_tags(article.article_text).split(/\n|----------/).first.to_s.strip
        heading_text = heading_text.gsub(/\[\d+\s*/, '').gsub(/\s*\]\d+/, '').gsub(/\[\d+\]/, '')
        heading_text = heading_text.gsub(/&nbsp;/i, ' ').gsub(/\s+/, ' ').strip

        level = heading_level(heading_text)
        prefix = '=' * [level, 6].min
        "\n#{prefix} #{escape(heading_text)}\n\n"
      else
        rendered_html = ActionController::Base.helpers.strip_tags(article.article_text.to_s)
        text = rendered_html.strip

        if citation_mode
          text = text.gsub(/\[\d+\s*\.{3}\s*\d*\]/, '').gsub(/\[\d+\s*…\s*\d*\]/, '')
          text = text.gsub(/\[\d+\s*/, ' ').gsub(/\]\d+/, '').gsub(/\[\d+\]/, '')
          text = text.lines.map(&:strip).join(' ').gsub(/\s+/, ' ').strip
        end

        title_match = text.match(/\A(Art(?:ikel)?\.?\s*\d+[a-z]*\.?)/i)
        if title_match
          art_title = title_match[1]
          art_body = text[title_match[0].length..].strip
          "*#{escape(art_title)}* #{escape(art_body)}\n\n"
        else
          text.present? ? "#{escape(text)}\n\n" : ''
        end
      end
    end

    def render_article_text(article, citation_mode)
      return '–' unless article.present?

      if article.article_type == 'LNK'
        heading_text = ActionController::Base.helpers.strip_tags(article.article_text).split(/\n|----------/).first.to_s.strip
        heading_text = heading_text.gsub(/\[\d+\s*/, '').gsub(/\s*\]\d+/, '').gsub(/\[\d+\]/, '')
        heading_text = heading_text.gsub(/&nbsp;/i, ' ').gsub(/\s+/, ' ').strip
        "*#{escape(heading_text)}*"
      else
        text = ActionController::Base.helpers.strip_tags(article.article_text.to_s).strip

        if citation_mode
          text = text.gsub(/\[\d+\s*\.{3}\s*\d*\]/, '').gsub(/\[\d+\s*…\s*\d*\]/, '')
          text = text.lines.map(&:strip).join(' ').gsub(/\s+/, ' ').strip
        end

        title_match = text.match(/\A(Art(?:ikel)?\.?\s*\d+[a-z]*\.?)/i)
        if title_match
          "*#{escape(title_match[1])}* #{escape(text[title_match[0].length..].strip)}"
        else
          escape(text)
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
