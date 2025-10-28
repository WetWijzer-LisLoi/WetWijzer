# frozen_string_literal: true

# Rendering logic for abolished (opheven/abrogé) articles and laws.
# Handles article-number extraction, cross-referenced linking to replacement laws,
# DVR tag processing, and European date reference lookups.
#
# Also includes rendering for annex articles and future-enforcement articles.
# Extracted from ReferencesHelper to improve maintainability.
module References
  module AbolishedRendering
    extend ActiveSupport::Concern
    include ActionView::Helpers::TagHelper
    include ActionView::Helpers::UrlHelper
    include ActionView::Context

    def render_abolished_article(content)
      return ''.html_safe if content.blank?

      unescaped = CGI.unescapeHTML(content)
      article_number, content_after_number = extract_article_number_and_rest(unescaped)
      cleaned = cleaned_abolished_text(content_after_number)
      fallback_art_num = extract_fallback_article_number(article_number)

      render_abolished_article_variants(cleaned, article_number, fallback_art_num)
    end

    def extract_fallback_article_number(article_number)
      return nil unless article_number.present?

      article_number[/\b(?:art\.?|artikel|article)\s*(\d+[a-z]*)/i, 1]
    end

    def render_abolished_article_variants(cleaned, article_number, fallback_art_num)
      angle_result = render_abolished_article_with_angle_marker(cleaned, article_number, fallback_art_num)
      return angle_result if angle_result

      dvr_result = render_abolished_article_with_dvr_tag(cleaned, article_number, fallback_art_num)
      return dvr_result if dvr_result

      wrap_abolished_article(article_number, link_abolished_content(cleaned, fallback_art_num))
    end

    # Handles the variant where an angle-bracket marker like <Opgeheven ...> is present.
    # Returns the full rendered HTML string or nil if not applicable.
    def render_abolished_article_with_angle_marker(cleaned, article_number, fallback_art_num)
      before_text, abolished_inner, after_text = match_angle_marker(cleaned)
      return nil unless abolished_inner

      abolished_node = build_abolished_anchor_or_span(abolished_inner, fallback_art_num)
      content_html = join_processed_segments(before_text, abolished_node, after_text)
      wrap_abolished_article(article_number, content_html)
    end

    # Extracts before/inner/after for an angle-bracket abolished marker like <Opgeheven ...>
    # Pattern 1: <Opgeheven ...> or <Abrogé ...> - must start with these words (not "(opgeheven)")
    # Pattern 2: (opgeheven) <W ...> - parenthetical OUTSIDE brackets, followed by any doc reference
    def match_angle_marker(cleaned)
      # Pattern 1: <Opgeheven ...> or <Abrogé ...> starting with those exact words (case insensitive)
      # This ensures we don't match <(opgeheven) W ...> or <W ...>
      angle_match = cleaned.match(/((?:&lt;|<)\s*((?:Opgeheven|Abrogé)\b[^<>]*?)\s*(?:&gt;|>))/i)
      if angle_match
        before_text = cleaned[0...angle_match.begin(0)].to_s.strip
        abolished_inner = angle_match[2].to_s.strip
        after_text = cleaned[angle_match.end(0)..].to_s.strip
        return [before_text, abolished_inner, after_text]
      end

      # Pattern 2: (opgeheven) <W ...> - parenthetical OUTSIDE angle brackets
      # Must ensure (opgeheven) is NOT inside the angle brackets
      prefix_match = cleaned.match(/\((?:opgeheven|abrogé)\)\s*(?:&lt;|<)(?!\()/i)
      if prefix_match
        # Find the full extent: (opgeheven) <...> and extract content WITHOUT brackets
        full_match = cleaned.match(/(\((?:opgeheven|abrogé)\))\s*(?:&lt;|<)([^<>]*?)(?:&gt;|>)/i)
        if full_match
          before_text = cleaned[0...full_match.begin(0)].to_s.strip
          # Combine parenthetical with content WITHOUT brackets (abolished_label will add them)
          abolished_inner = "#{full_match[1]} #{full_match[2]}".strip
          after_text = cleaned[full_match.end(0)..].to_s.strip
          return [before_text, abolished_inner, after_text]
        end
      end

      [nil, nil, nil]
    end

    # Builds a red anchor if a lookup can be resolved, otherwise a red span.
    def build_abolished_anchor_or_span(abolished_inner, fallback_art_num)
      abolished_processed = process_reference_markers(ERB::Util.h(abolished_inner), {})
      url = abolished_anchor_url(abolished_inner, fallback_art_num)
      return abolished_span(abolished_processed) unless url

      label = abolished_label(abolished_processed)
      abolished_link(label, url)
    end

    def abolished_anchor_url(abolished_inner, fallback_art_num)
      refs = lookup_document_references(abolished_inner)

      # Fallback: try European date format (DD-MM-YYYY) common in older legislation
      refs = lookup_european_date_references(abolished_inner) if refs.blank?

      return nil unless refs.present?

      first_doc = refs.keys.first
      lookup = refs[first_doc]
      fragment = compute_article_fragment(abolished_inner, fallback_art_num)
      url = "/laws/#{lookup[:numac]}?language_id=#{lookup[:language_id]}"
      url += fragment if fragment
      url
    end

    # Tries to find document references using European date format (DD-MM-YYYY)
    # by converting to YYYY-MM-DD and doing a prefix search in the lookup table
    def lookup_european_date_references(text)
      return {} if text.blank?

      # Match DD-MM-YYYY dates (European format used in older Belgian legislation)
      eu_dates = text.scan(/\b(\d{2})-(\d{2})-(\d{4})\b/)
      return {} if eu_dates.empty?

      results = {}
      eu_dates.each do |day, month, year|
        iso_prefix = "#{year}-#{month}-#{day}"
        # Find any document that starts with this ISO date
        lookup = DocumentNumberLookup.where('document_number LIKE ?', "#{iso_prefix}%").first
        next unless lookup

        law = Legislation.find_by(numac: lookup.numac, language_id: lookup.language_id)
        results[lookup.document_number] = { numac: lookup.numac, language_id: lookup.language_id, title: law&.title }
      end

      results
    rescue ActiveRecord::StatementInvalid
      {}
    end

    def compute_article_fragment(text, fallback_art_num)
      art_match = text.match(/(?:art\.|artikel|article)\s*(\d+(?:[.:]\d+)*[a-z]*)/i)
      token = art_match && art_match[1] ? art_match[1] : fallback_art_num
      return nil unless token

      norm = token.to_s.downcase
      norm = norm.gsub(%r{[.:/]+}, '-')
      norm = norm.gsub(/[^a-z0-9-]/, '')
      norm = norm.gsub(/-+/, '-')
      norm = norm.gsub(/^-|-$/, '')
      norm.present? ? "#art-#{norm}" : nil
    end

    def abolished_label(abolished_processed)
      safe_join(['&lt;'.html_safe, abolished_processed, '&gt;'.html_safe])
    end

    def abolished_span(abolished_processed)
      content_tag(:span, abolished_label(abolished_processed), class: ['text-red-600', 'dark:text-red-400'].join(' '))
    end

    def abolished_link(label, url, lookup = nil)
      link_to(
        label,
        url,
        class: [
          'text-red-600',
          'hover:underline decoration-current hover:decoration-current',
          'dark:text-red-400'
        ].join(' '),
        title: lookup&.dig(:title) || t('articles.view_legislation'),
        target: '_blank',
        rel: 'noopener noreferrer'
      )
    end

    # Joins optional before/after content processed as regular article with the middle node
    def join_processed_segments(before_text, middle_node, after_text)
      parts = []
      parts << process_article_patterns(before_text, :regular_article) unless before_text.blank?
      parts << middle_node
      parts << process_article_patterns(after_text, :regular_article) unless after_text.blank?
      safe_join(parts, ' ')
    end

    # Wraps the abolished article block, optionally prefixing the article number tag
    def wrap_abolished_article(article_number, content_html)
      content_tag(:div, class: %w[abolished-article my-2].join(' ')) do
        parts = []
        if article_number.present?
          cleaned_article_number = article_number.sub(/[[:space:]\u00A0\u202F]+$/, '')
          parts << safe_join([article_number_tag(cleaned_article_number), content_html], ' ')
        else
          parts << content_html
        end
        parts << justel_archive_link_tag
        safe_join(parts)
      end
    end

    # Handles the variant: optional (opgeheven)/(abrogé) prefix + DVR metadata tag
    # Returns full HTML or nil when not matched.
    DVR_TAG_REGEX = /
      \A
      (.*?)                                   # before_text
      (\((?:opgeheven|abrogé)\))?            # optional prefix
      ((?:[[:space:]\u00A0\u202F]|&nbsp;)*)   # spacing
      (                                       # meta_tag
        (?:&lt;\s*(?:Ingevoegd\s+bij\s+)?DVR[^&]*?&gt;|<\s*(?:Ingevoegd\s+bij\s+)?DVR[^>]*?>)
      )
      (.*)                                    # after_text
      \z
    /ix

    def render_abolished_article_with_dvr_tag(cleaned, article_number, fallback_art_num)
      m = cleaned.match(DVR_TAG_REGEX)
      return nil unless m

      before_text, segment, after_text = extract_dvr_tag_parts(m)
      linked_segment = link_abolished_content(segment, fallback_art_num)
      content_html = join_processed_segments(before_text, linked_segment, after_text)
      wrap_abolished_article(article_number, content_html)
    end

    def extract_dvr_tag_parts(match)
      before_text = match[1].to_s.strip
      prefix = match[2].to_s.strip
      meta_tag = match[4].to_s
      after_text = match[5].to_s.strip
      segment = [prefix.presence, meta_tag].compact.join(' ').strip
      [before_text, segment, after_text]
    end

    # Filters conflicting classes (yellow/amber) from an anchor before adding red classes
    def filter_anchor_classes_for_abolished(classes_val)
      classes_val.split(/\s+/).reject { |c| anchor_class_conflicts_with_red?(c) }
    end

    def anchor_class_conflicts_with_red?(cls)
      return true if cls.start_with?('text-amber-')
      return true if cls.start_with?('visited:text-amber-')
      return true if cls.start_with?('hover:text-amber-')
      return true if cls.start_with?('dark:text-yellow-')
      return true if cls.start_with?('dark:visited:text-yellow-')
      return true if cls.start_with?('dark:hover:text-yellow-')

      false
    end

    # Normalizes abolished text by converting NBSPs and squeezing whitespace, but keeps brackets
    def cleaned_abolished_text(text)
      text.to_s
          .gsub(/(?:&nbsp;|&#160;|&#xA0;)/i, ' ')
          .gsub(/\s+/, ' ')
          .strip
    end

    # Build a safe label preserving visible &lt; and &gt;
    def preserved_lt_gt_label(text)
      tmp = text.to_s.gsub('&lt;', '__LT__').gsub('&gt;', '__GT__')
      ERB::Util.h(tmp).gsub('__LT__', '&lt;').gsub('__GT__', '&gt;')
    end

    # Normalize an article fragment token into an anchor-safe slug
    def normalize_article_fragment(token)
      norm = token.to_s.downcase
      norm = norm.gsub(%r{[.:/]+}, '-')
      norm = norm.gsub(/[^a-z0-9-]/, '')
      norm = norm.gsub(/-+/, '-')
      norm.gsub(/^-|-$/, '')
    end

    # CSS classes for abolished anchors
    def abolished_anchor_classes
      [
        'text-red-600',
        'hover:underline decoration-current hover:decoration-current',
        'dark:text-red-400'
      ].join(' ')
    end

    # Links the abolished content to the referenced document when possible
    # Always returns HTML-safe content with visible < and > preserved in the label
    def link_abolished_content(cleaned_content, fallback_art_num = nil)
      safe_label = preserved_lt_gt_label(cleaned_content)
      lookup = find_document_lookup_for_abolished(cleaned_content)

      return content_tag(:span, safe_label.html_safe, class: 'text-red-600 dark:text-red-400') unless lookup

      url = build_abolished_content_url(cleaned_content, lookup, fallback_art_num)
      link_to(safe_label.html_safe, url, class: abolished_anchor_classes,
                                         title: lookup[:title] || t('articles.view_legislation'), target: '_blank', rel: 'noopener noreferrer')
    end

    def find_document_lookup_for_abolished(cleaned_content)
      doc_number = cleaned_content[%r{(\d{4}-\d{2}-\d{2}/[A-Za-z0-9]+)}, 1]
      return nil unless doc_number

      rec = DocumentNumberLookup.find_by(document_number: doc_number)
      return nil unless rec

      law = Legislation.find_by(numac: rec.numac, language_id: rec.language_id)
      { numac: rec.numac, language_id: rec.language_id, title: law&.title }
    rescue ActiveRecord::StatementInvalid
      nil # Table may not exist in v089 DB
    end

    def build_abolished_content_url(cleaned_content, lookup, fallback_art_num)
      url = law_path(lookup[:numac], language_id: lookup[:language_id])
      token = cleaned_content[/\bart\.?\s*(\d+(?:[.:]\d+)*[a-z]*)/i, 1] || fallback_art_num
      return url unless token

      norm = normalize_article_fragment(token)
      norm.present? ? "#{url}#art-#{norm}" : url
    end

    # Renders an abolished law with proper formatting for [Opgeheven or [Abrogé notices
    def render_abolished_law(content)
      return ''.html_safe if content.blank?

      safe_content = safe_db_content(content, :abolished_law)
      abolished_content = extract_abolished_notice(safe_content)
      content_html = link_abolished_content(cleaned_abolished_text(abolished_content))

      wrap_abolished_law_content(content_html)
    end

    def extract_abolished_notice(safe_content)
      notice_match = safe_content.match(/(\[(?:Opgeheven|Abrogé)[^\]]*\].*)/i)
      notice_match ? notice_match[1] : safe_content
    end

    def wrap_abolished_law_content(content_html)
      content_tag(:div, class: 'abolished-law bg-red-50 dark:bg-red-900/20 border-l-4 border-red-400 dark:border-red-600 p-4 my-4') do
        safe_join([
                    content_tag(:span, content_html, class: 'abolished-text text-red-600 dark:text-red-400'),
                    justel_archive_link_tag
                  ])
      end
    end

    # Applies article-specific text transformations prior to line-break handling.
    # - Ensures content is safely sanitized when needed
    # - Highlights/bolds a leading article number (Art./Article/Artikel ...)
    # - Applies document-number linking and metadata highlights
    #

    def render_annex_article(content)
      return ''.html_safe if content.blank?

      # Check if it's a concordance table by looking for:
      # 1. "Coordinatie" header OR
      # 2. Multiple consecutive spaces (indicating column formatting)
      has_coordinatie = content.match?(/\b(?:Coordinatie|Coordination|CONCORDANTIETABEL|TABLE DE CONCORDANCE)\b/i)
      has_table_spacing = content.match?(/\s{3,}/) # 3+ consecutive spaces indicate table columns
      is_concordance = has_coordinatie || has_table_spacing

      if is_concordance
        # Preserve whitespace formatting for table layout
        main_content, references_text = split_content_and_references(content)

        # Apply document links but preserve whitespace (no line break formatting)
        safe_content = safe_db_content(main_content, :regular_article)
        linked_content = apply_document_links(safe_content)

        # Wrap in div with whitespace preservation and monospace font for alignment
        formatted = content_tag(:div, linked_content, class: 'whitespace-pre-wrap font-mono text-sm')

        # Add references if present
        if references_text.present?
          references_section = render_references_section(references_text)
          content_tag(:div, class: ARTICLE_CONTENT_CLASSES) do
            safe_join([formatted, references_section])
          end
        else
          content_tag(:div, formatted, class: ARTICLE_CONTENT_CLASSES)
        end
      else
        # Not a concordance table, process normally
        process_article_with_references(content)
      end
    end

    # Renders a future law article with a visual badge indicating it's a future law variant.
    # Article text is NOT modified — only a badge is appended after the rendered content.
    def render_future_law_article(content)
      return ''.html_safe if content.blank?

      rendered = process_article_with_references(content)

      # Build the badge label based on locale
      badge_label = case I18n.locale when :fr then 'Droit futur' when :de then 'Zukünftiges Recht' when :en then 'Future law' else 'Toekomstig recht' end
      badge = content_tag(:span, badge_label,
                          class: 'inline-flex items-center ml-2 px-2 py-0.5 text-xs font-semibold rounded-full ' \
                                 'bg-(--accent-100) text-(--accent-700) dark:bg-(--accent-900)/40 dark:text-(--accent-300) ' \
                                 'border border-(--accent-300) dark:border-(--accent-600) whitespace-nowrap')

      safe_join([rendered, badge])
    end

    private

    # Builds a small inline link button to the Justel archive page for the current law.
    # Returns an empty string if no Justel URL is available.
    def justel_archive_link_tag
      justel_url = defined?(@law) && @law.respond_to?(:justel) ? @law.justel : nil
      return ''.html_safe if justel_url.blank? || justel_url == 'N/A'

      label = case I18n.locale
              when :fr then 'Voir les archives sur Justel'
              when :de then 'Archiv auf Justel ansehen'
              when :en then 'View archive on Justel'
              else 'Bekijk archief op Justel'
              end

      content_tag(:a, href: justel_url, target: '_blank', rel: 'noopener noreferrer',
                      class: 'inline-flex items-center gap-1 ml-2 px-1.5 py-0.5 text-xs font-medium ' \
                             'rounded border border-gray-300 dark:border-gray-600 ' \
                             'text-gray-500 dark:text-gray-400 ' \
                             'hover:bg-gray-100 dark:hover:bg-gray-700/40 ' \
                             'transition-colors no-print',
                      title: label) do
        safe_join([
                    # Small scroll/archive icon
                    content_tag(:svg, class: 'w-3 h-3 shrink-0', fill: 'none', stroke: 'currentColor',
                                      viewBox: '0 0 24 24', 'stroke-width': '2',
                                      xmlns: 'http://www.w3.org/2000/svg', 'aria-hidden': 'true') do
                      content_tag(:path, '', 'stroke-linecap': 'round', 'stroke-linejoin': 'round',
                                             d: 'M13.5 6H5.25A2.25 2.25 0 003 8.25v10.5A2.25 2.25 0 005.25 21h10.5A2.25 2.25 0 0018 18.75V10.5m-4.5 0V6.75A.75.75 0 0114.25 6h1.5a.75.75 0 01.75.75v1.5m-4.5 0h4.5m-4.5 0l6-6')
                    end,
                    content_tag(:span, 'Justel', class: 'hidden sm:inline')
                  ])
      end
    end
  end
end
