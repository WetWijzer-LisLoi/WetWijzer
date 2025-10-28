# frozen_string_literal: true

# == References Helper
#
# Provides helpers for reference extraction, coloring, rendering of references sections,
# document-number linking, and specialized rendering for section headings and abolished content.
# Extracted from ApplicationHelper to reduce its size and improve maintainability.
# rubocop:disable Metrics/ModuleLength
module ReferencesHelper
  # ============================================================================
  # UNIFIED THEMING SYSTEM - CSS Variables (defined in themes/_accent.scss)
  # ============================================================================
  # Reference colors are now theme-aware via CSS custom properties.
  # Each theme (slate, blue, rose, etc.) defines its own set of --ref-1 through --ref-20
  # Professional themes use muted 700-level colors
  # Vibrant themes use bright 600-level colors
  # All colors automatically adapt to light/dark mode

  # Reference colors using CSS variables (adapts per theme)
  REFERENCE_COLORS = [
    'text-[var(--ref-1)]',   # 1
    'text-[var(--ref-2)]',   # 2
    'text-[var(--ref-3)]',   # 3
    'text-[var(--ref-4)]',   # 4
    'text-[var(--ref-5)]',   # 5
    'text-[var(--ref-6)]',   # 6
    'text-[var(--ref-7)]',   # 7
    'text-[var(--ref-8)]',   # 8
    'text-[var(--ref-9)]',   # 9
    'text-[var(--ref-10)]',  # 10
    'text-[var(--ref-11)]',  # 11
    'text-[var(--ref-12)]',  # 12
    'text-[var(--ref-13)]',  # 13
    'text-[var(--ref-14)]',  # 14
    'text-[var(--ref-15)]',  # 15
    'text-[var(--ref-16)]',  # 16
    'text-[var(--ref-17)]',  # 17
    'text-[var(--ref-18)]',  # 18
    'text-[var(--ref-19)]',  # 19
    'text-[var(--ref-20)]'   # 20
  ].freeze

  # Other theme-aware colors
  LIST_MARKER_COLOR = 'text-[var(--list-marker)]'
  SECTION_SYMBOL_COLOR = 'text-[var(--section-symbol)]'
  SPECIAL_MARKER_COLOR = 'text-[var(--special-marker)]'

  # TailwindCSS classes for the main article content wrapper
  ARTICLE_CONTENT_CLASSES = %w[
    prose
    prose-sm
    dark:prose-invert
    max-w-none
    article-content
    overflow-x-auto
    [&_table]:w-full
    [&_table]:max-w-full
    [&_table]:table-auto
    [&_td]:break-words
    [&_th]:break-words
    [&_p:last-child]:mb-0
    [&_ul:last-child]:mb-0
    [&_ol:last-child]:mb-0
    [&_table:last-child]:mb-0
    [&_blockquote:last-child]:mb-0
  ].join(' ').freeze

  # Checks if any articles in the collection have references
  # @param articles [ActiveRecord::Relation, Array] Collection of articles
  # @return [Boolean] true if at least one article has references
  def any_articles_have_references?(articles)
    return false if articles.blank?

    articles.any? do |article|
      content = article.article_text.to_s
      content.match?(/\(\d+\)<[^>]+>/) || content.match?(/\[\d+(?:\s+[^\]]+)?\]/)
    end
  end

  # Extracts and parses reference markers from article content
  # @return [Hash{String => String}]
  def extract_references_from_content(content)
    return {} if content.blank?

    references = {}
    extract_parenthesis_references(content, references)
    extract_bracket_references(content, references)
    references
  end

  def extract_parenthesis_references(content, references)
    content.scan(/\((\d+)\)<([^>]+)>/) do |num, text|
      references[num] = text.strip unless references.key?(num)
    end
  end

  def extract_bracket_references(content, references)
    content.scan(/\[(\d+)(?:\s+([^\]]+))?\]/) do |num, text|
      next if references.key?(num)

      references[num] = extract_bracket_text(content, num, text)
    end
  end

  def extract_bracket_text(content, num, text)
    return text.strip if text.present? && !text.strip.empty?

    match = content.match(/\[#{num}\]\s*([^\[]+)/)
    match&.[](1)&.strip
  end

  # Processes article content with references, extracting them from after the separator
  def process_article_with_references(content, _references = {}, _article_type = :regular_article)
    return ''.html_safe if content.blank?

    main_content, references_text = split_content_and_references(content)
    formatted_content = apply_content_formatting(main_content)
    assemble_article_with_references(formatted_content, references_text)
  end

  def apply_content_formatting(main_content)
    highlighted = highlight_abolished_markers(main_content)
    highlighted = highlight_modification_markers(highlighted)
    highlighted = format_list_markers(highlighted)
    format_line_breaks(process_reference_markers(highlighted, {}))
  end

  def assemble_article_with_references(formatted_content, references_text)
    content_tag(:div, class: ARTICLE_CONTENT_CLASSES) do
      references_section = references_text.present? ? render_references_section(references_text) : nil
      references_section.present? ? safe_join([formatted_content, references_section]) : formatted_content
    end
  end

  # Renders a section heading with proper formatting and reference processing
  def render_section_heading_with_references(content, _references = {})
    return ''.html_safe if content.blank?

    raw_text = content.to_s
    main_content, references_text = split_content_and_references(raw_text)
    processed_content = process_heading_content(main_content)
    heading_id = unique_section_heading_id(main_content)

    build_section_heading_html(processed_content, heading_id, references_text)
  end

  def process_heading_content(main_content)
    processed = process_article_patterns(main_content)
    processed = highlight_modification_markers(processed)
    format_list_markers(processed)
  end

  def build_section_heading_html(processed_content, heading_id, references_text)
    content_tag(:section, class: 'section-heading group mt-2 md:mt-3 mb-2 md:mb-3',
                          'data-section-heading': heading_id,
                          'data-article-scope': true) do
      safe_join([
        build_section_heading_h2(processed_content, heading_id),
        render_references_section(references_text, anchor_id: "wijzigingen-#{heading_id}")
      ].compact)
    end
  end

  # rubocop:disable Metrics/MethodLength
  def build_section_heading_h2(processed_content, heading_id)
    content_tag(:h2, id: heading_id,
                     class: ['not-prose', section_heading_classes, 'flex items-start gap-2 flex-nowrap',
                             'rounded-md px-2 py-1 transition-colors group',
                             'hover:bg-gray-50 dark:hover:bg-gray-800'].join(' ')) do
      # Collapsible button (just chevron + text, no copy button inside)
      collapse_button = content_tag(:button, type: 'button',
                                             class: 'flex items-start gap-2 flex-1 min-w-0 text-left focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent-500)] focus-visible:ring-offset-2',
                                             'data-action': 'click->collapse#toggle',
                                             'data-collapse-target': 'button',
                                             'aria-expanded': 'true') do
        chevron = content_tag(:svg, xmlns: 'http://www.w3.org/2000/svg',
                                    class: 'w-5 h-5 flex-shrink-0 transition-transform text-gray-500 dark:text-gray-400',
                                    viewBox: '0 0 20 20',
                                    fill: 'currentColor',
                                    'data-collapse-target': 'icon') do
          tag.path('fill-rule': 'evenodd',
                   d: 'M5.23 7.21a.75.75 0 011.06.02L10 10.94l3.71-3.71a.75.75 0 111.06 1.06l-4.24 4.24a.75.75 0 01-1.06 0L5.21 8.29a.75.75 0 01.02-1.08z',
                   'clip-rule': 'evenodd')
        end
        heading_text = prepare_heading_text(processed_content)
        safe_join([chevron, heading_text])
      end

      # Copy buttons as sibling (not nested)
      buttons = heading_copy_buttons(heading_id)

      safe_join([collapse_button, buttons])
    end
  end
  # rubocop:enable Metrics/MethodLength

  def prepare_heading_text(processed_content)
    heading_text = process_reference_markers(processed_content, {})
    heading_text = highlight_abolished_markers(heading_text)
    nb_space_before_reference(heading_text)
  end

  # Renders an abolished section heading (LNK with Opgeheven/Abrogé markers)
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/BlockLength
  def render_abolished_section_heading(content, _references = {})
    return ''.html_safe if content.blank?

    # Split the raw content first to preserve reference lines like (n)<...>
    raw_all = content.to_s
    main_content, references_text = split_content_and_references(raw_all)

    raw_text = main_content.to_s
    # Prefer an explicit <Opgeheven/Abrogé …> marker (encoded or literal). Avoid matching other <...> tags like <DVR>.
    angle_match = raw_text.match(/((?:&lt;|<)\s*((?:Opgeheven|Abrogé)[^<>]*?)\s*(?:&gt;|>))/i)
    abolished_parentheses = nil
    abolished_raw = nil

    if angle_match
      # Capture text before the abolished marker
      label_raw = raw_text[0...angle_match.begin(0)]
      # Remove any trailing spaces (including NBSP/NNBSP) before the abolished marker so we can
      # control spacing explicitly between the label and the marker node.
      label_raw = label_raw.to_s.sub(/[[:space:]\u00A0\u202F]+$/u, '')
      abolished_raw = angle_match[2].to_s.strip # inner content without brackets
    else
      # Fallback to the parenthetical form (opgeheven)/(abrogé) when no <Opgeheven/Abrogé> tag is present
      parentheses_match = raw_text.match(/\(\s*(?:opgeheven|abrogé)\s*\)/i)
      if parentheses_match
        label_raw = raw_text[0...parentheses_match.begin(0)]
        label_raw = label_raw.to_s.sub(/[[:space:]\u00A0\u202F]+$/u, '')
        abolished_parentheses = parentheses_match[0]
      else
        label_raw = raw_text
        label_raw = label_raw.to_s.sub(/[[:space:]\u00A0\u202F]+$/u, '')
      end
    end

    label_processed = process_reference_markers(process_article_patterns(label_raw), {})
    if abolished_raw.present?
      # Do NOT call process_article_patterns here because it adds document-number links.
      # We want the entire <...> abolished marker to be a single red link, not split.
      # So we only escape HTML and color reference markers without linking doc numbers.
      safe_inner = ERB::Util.h(abolished_raw)
      abolished_processed = process_reference_markers(safe_inner, {})
    end

    extra_for_slug = if abolished_raw.present?
                       abolished_raw
                     else
                       abolished_parentheses.to_s
                     end
    # Ensure a single space between label and abolished marker for consistent slugs with TOC
    heading_source = [label_raw.to_s, extra_for_slug.presence].compact.join(' ').strip
    heading_id = unique_section_heading_id(heading_source)

    abolished_link = nil
    if abolished_raw.present?
      refs = lookup_document_references(abolished_raw)
      if refs.present?
        first_doc = refs.keys.first
        lookup = refs[first_doc]
        art_match = abolished_raw.match(/(?:art\.|artikel|article)\s*(\d+[a-z]*)/i)
        article_fragment = art_match && art_match[1] ? "#art-#{art_match[1]}" : nil
        url = "/laws/#{lookup[:numac]}?language_id=#{lookup[:language_id]}"
        url += article_fragment if article_fragment
        # Include visible angle brackets around the abolished marker in the link label
        label_with_brackets = safe_join(['&lt;'.html_safe, abolished_processed, '&gt;'.html_safe])
        link_classes = [
          'text-red-700 dark:text-red-400',
          'hover:underline decoration-current hover:decoration-current',
          '[&_span]:!text-red-700 dark:[&_span]:!text-red-400'
        ]
        link_options = {
          title: lookup[:title] || t('articles.view_legislation'),
          target: '_blank',
          rel: 'noopener noreferrer'
        }
        abolished_link = link_to(label_with_brackets, url, class: link_classes.join(' '), **link_options)
      end
    end

    content_tag(:section, class: 'section-heading abolished-section group mt-2 md:mt-3 mb-2 md:mb-3',
                          'data-section-heading': heading_id,
                          'data-article-scope': true,
                          data: { skip_doc_links: true }) do
      safe_join([
        content_tag(
          :h2,
          id: heading_id,
          class: [
            'not-prose',
            section_heading_classes,
            'flex items-start gap-2 flex-nowrap',
            'rounded-md px-2 py-1 transition-colors group',
            'hover:bg-gray-50 dark:hover:bg-gray-800'
          ].join(' ')
        ) do
          # Collapsible button (just chevron + text, no copy button inside)
          collapse_button = content_tag(:button, type: 'button',
                                                 class: 'flex items-start gap-2 flex-1 min-w-0 text-left focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent-500)] focus-visible:ring-offset-2',
                                                 'data-action': 'click->collapse#toggle',
                                                 'data-collapse-target': 'button',
                                                 'aria-expanded': 'true') do
            chevron = content_tag(:svg, xmlns: 'http://www.w3.org/2000/svg',
                                        class: 'w-5 h-5 flex-shrink-0 transition-transform text-gray-500 dark:text-gray-400',
                                        viewBox: '0 0 20 20',
                                        fill: 'currentColor',
                                        'data-collapse-target': 'icon') do
              tag.path('fill-rule': 'evenodd',
                       d: 'M5.23 7.21a.75.75 0 011.06.02L10 10.94l3.71-3.71a.75.75 0 111.06 1.06l-4.24 4.24a.75.75 0 01-1.06 0L5.21 8.29a.75.75 0 01.02-1.08z',
                       'clip-rule': 'evenodd')
            end
            # If not a link, create a red span with the abolished marker
            abolished_node = abolished_link || (
              if abolished_processed.present?
                # Show visible brackets around the abolished marker when not linked
                inner = safe_join(['&lt;'.html_safe, abolished_processed, '&gt;'.html_safe])
                content_tag(
                  :span,
                  inner,
                  class: [
                    'text-red-700 dark:text-red-400',
                    '[&_a]:text-red-700 dark:[&_a]:text-red-400'
                  ].join(' ')
                )
              elsif abolished_parentheses.present?
                # Parenthetical abolished marker without DVR tag/link: show as red text
                content_tag(:span, abolished_parentheses, class: 'text-red-700 dark:text-red-400')
              end
            )

            # Glue abolished marker to title with a non-breaking space, and ensure references stick to previous text
            heading_core = if abolished_node.present?
                             # Exactly one regular space between label and abolished marker
                             safe_join([label_processed, ' ', abolished_node])
                           else
                             label_processed
                           end
            heading_core = nb_space_before_reference(heading_core)
            safe_join([chevron, heading_core])
          end

          # Copy buttons as sibling (not nested)
          buttons = heading_copy_buttons(heading_id)

          safe_join([collapse_button, buttons])
        end,
        content_tag(:div, nil, class: 'sr-only'),
        render_references_section(references_text, anchor_id: "wijzigingen-#{heading_id}")
      ].compact)
    end
  end

  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/BlockLength

  # Renders the standard copy-link button used for section headings (normal and abolished)
  def copy_link_button_for_heading(heading_id)
    data_attrs = {
      controller: 'clipboard',
      action: 'click->clipboard#copy',
      clipboard_fragment_value: heading_id,
      clipboard_copied_label_value: t(:link_copied)
    }
    build_copy_button(t(:copy_section_link), data_attrs, link_icon_svg)
  end

  def build_copy_button(title_text, data_attrs, icon_svg)
    content_tag(:button, class: copy_button_classes, title: title_text, aria: { label: title_text }, data: data_attrs) do
      icon_svg.html_safe
    end
  end

  def copy_button_classes
    'p-1 text-gray-400 hover:text-[var(--accent-600)] shrink-0 transition-colors duration-200 md:opacity-0 md:group-hover:opacity-100 focus:opacity-100 focus:outline-none'
  end

  def link_icon_svg
    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-4 h-4">
        <path stroke-linecap="round" stroke-linejoin="round" d="M13.19 8.688a4.5 4.5 0 011.242 7.244l-4.5 4.5a4.5 4.5 0 01-6.364-6.364l1.757-1.757m13.35-.622l1.757-1.757a4.5 4.5 0 00-6.364-6.364l-4.5 4.5a4.5 4.5 0 001.242 7.244" />
      </svg>
    SVG
  end

  # Renders a copy-text button targeting a DOM selector (uses Stimulus clipboard#copyText)
  def copy_text_button_for_selector(selector, title_key, copied_key)
    data_attrs = {
      controller: 'clipboard',
      action: 'click->clipboard#copyText',
      clipboard_source_selector_value: selector,
      clipboard_copied_label_value: t(copied_key)
    }
    build_copy_button(t(title_key), data_attrs, clipboard_icon_svg)
  end

  def clipboard_icon_svg
    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-4 h-4">
        <path stroke-linecap="round" stroke-linejoin="round" d="M9 12h6m-6 4h6M9.5 4.5A1.5 1.5 0 0111 3h2a1.5 1.5 0 011.5 1.5V6H17a2 2 0 012 2v9a2 2 0 01-2 2H7a2 2 0 01-2-2V8a2 2 0 012-2h2.5V4.5z" />
      </svg>
    SVG
  end

  # Renders the button group for a heading: only the link button (no text copy for headings)
  def heading_copy_buttons(heading_id)
    content_tag(:span, class: 'shrink-0 self-start flex flex-col items-end ml-3 gap-1') do
      copy_link_button_for_heading(heading_id)
    end
  end

  # Highlights abolished markers like <Opgeheven ...> or <Abrogé ...> in red
  # Strips angle brackets and formats with law title when available
  # e.g., "<(Opgeheven) W 1998-12-07/31, art. 214, 018>" becomes "(Opgeheven) art. 214 van [Law Title]"
  def highlight_abolished_markers(html)
    return ''.html_safe if html.blank?

    str = html.to_s
    cls = 'abolished-marker text-red-700 dark:text-red-400'
    
    # Pattern 1: Literal <...> containing Opgeheven/Abrogé
    highlighted = str.gsub(/<\s*((?:\(\s*)?(?:Opgeheven|Abrogé)[^>]*)>/i) do |_match|
      inner = Regexp.last_match(1).to_s.strip
      format_abolished_with_title(inner, cls)
    end
    
    # Pattern 2: Encoded &lt;...&gt; containing Opgeheven/Abrogé
    highlighted = highlighted.gsub(/&lt;\s*((?:\(\s*)?(?:Opgeheven|Abrogé)[^&]*)&gt;/i) do |_match|
      inner = Regexp.last_match(1).to_s.strip
      format_abolished_with_title(inner, cls)
    end

    highlighted.html_safe
  end

  # Formats abolished marker with law title lookup
  # Input: "(Opgeheven) W 1998-12-07/31, art. 214, 018; Inwerkingtreding : 01-01-2001"
  # Output: "(Opgeheven) art. 214 van [Law Title]" as a link, or plain text if no lookup found
  def format_abolished_with_title(inner, cls)
    # Extract the prefix (Opgeheven) or Opgeheven
    prefix_match = inner.match(/^(\(\s*(?:Opgeheven|Abrogé)\s*\)|(?:Opgeheven|Abrogé))\s*/i)
    prefix = prefix_match ? prefix_match[1] : ''
    rest = prefix_match ? inner[prefix_match[0].length..] : inner
    
    # Extract document number (e.g., 1998-12-07/31)
    doc_number = rest[%r{(\d{4}-\d{2}-\d{2}/[A-Za-z0-9]+)}, 1]
    
    # Extract article number (e.g., art. 214)
    art_match = rest.match(/(?:art\.?|artikel|article)\s*(\d+[a-z]*)/i)
    art_num = art_match ? art_match[1] : nil
    
    # Try to get the law title from lookup
    lookup = nil
    if doc_number
      @_doc_lookup_cache ||= {}
      lookup = @_doc_lookup_cache[doc_number]
      unless lookup
        rec = DocumentNumberLookup.find_by(document_number: doc_number)
        if rec
          law = Legislation.find_by(numac: rec.numac, language_id: rec.language_id)
          lookup = { numac: rec.numac, language_id: rec.language_id, title: law&.title }
          @_doc_lookup_cache[doc_number] = lookup
        end
      end
    end
    
    if lookup && lookup[:title].present?
      # Format: "(Opgeheven) art. X van [Title]" or just "(Opgeheven) [Title]"
      title = lookup[:title]
      if art_num
        label = "#{prefix} art. #{art_num} van #{title}".strip
      else
        label = "#{prefix} #{title}".strip
      end
      
      # Build link
      url = "/laws/#{lookup[:numac]}?language_id=#{lookup[:language_id]}"
      url += "#art-#{art_num}" if art_num
      
      %(<a href="#{url}" class="#{cls} hover:underline" target="_blank" rel="noopener noreferrer" title="#{ERB::Util.h(title)}">#{ERB::Util.h(label)}</a>)
    else
      # Fallback: just show the inner content without brackets
      %(<span class="#{cls}">#{ERB::Util.h(inner)}</span>)
    end
  end

  # Highlights plain text abolished phrases in sentences
  # Handles both Dutch and French variations
  def highlight_text_abolished_phrases(html)
    return ''.html_safe if html.blank?

    str = html.to_s
    # Match complete phrases to avoid false positives
    # Dutch: worden opgeheven, wordt opgeheven
    # French: est abrogé, est abrogée, sont abrogés, sont abrogées
    highlighted = str.gsub(/\b(wordt|worden)\s+(opgeheven)\b/i) do |match|
      %(<span class="text-red-600 dark:text-red-400 font-medium">#{match}</span>)
    end

    highlighted = highlighted.gsub(/\b(est|sont)\s+(abrogée?s?)\b/i) do |match|
      %(<span class="text-red-600 dark:text-red-400 font-medium">#{match}</span>)
    end

    highlighted.html_safe
  end

  # Highlights modification markers like <Wijziging ...> or <Modification ...>
  def highlight_modification_markers(html)
    return ''.html_safe if html.blank?

    str = html.to_s
    pattern = /((?:&lt;|<)\s*(?:Wijziging|Modification|Vervangen|Remplacer|Invoegen|Insérer)[^<>]*?(?:&gt;|>))/i
    highlighted = str.gsub(pattern) do |match|
      safe = match.start_with?('&lt;') ? match : ERB::Util.h(match)
      cls = 'modification-marker text-amber-600 dark:text-amber-400 italic'
      %(<span class="#{cls}">#{safe}</span>)
    end

    highlighted.html_safe
  end

  # Formats list markers (°) and section symbols (§) for better visual distinction
  # Only formats when they appear as actual list markers at line starts, not within text
  def format_list_markers(html)
    return ''.html_safe if html.blank?

    str = html.to_s

    # Format degree symbols ONLY when used as list markers at the start of lines
    # Uses lookbehind for start of string or newline to avoid matching "13°" inside reference text
    formatted = str.gsub(/(?:^|(?<=\n))(\s*)(\d+)°(?=\s)/m) do
      leading_space = Regexp.last_match(1)
      num = Regexp.last_match(2)
      %(#{leading_space}<span class="font-semibold #{LIST_MARKER_COLOR}">#{num}°</span>)
    end

    # Format section symbols ONLY at line starts (paragraphs)
    # Uses lookbehind to match only at start of string or after newline
    # Skip if content contains tables (§ inside tables shouldn't be styled)
    unless str.include?('<table')
      formatted = formatted.gsub(/(?:^|(?<=\n))(\s*)(§\s*\d+)/m) do
        leading_space = Regexp.last_match(1)
        match = Regexp.last_match(2)
        %(#{leading_space}<span class="font-semibold #{SECTION_SYMBOL_COLOR}">#{match}</span>)
      end
    end

    formatted.html_safe
  end

  # Processes nested references with proper color inheritance
  def process_reference_markers(content, references = {}, level = 0)
    return '' if content.nil?

    text = content.to_s
    return text if text.blank? || level > 5

    # Check if colors should be shown (defaults to true if not set)
    show_colors = defined?(@show_colors) ? @show_colors : true
    reference_colors = level.zero? ? {} : references.dup

    processed = process_reference_spans(text, reference_colors, level)
    processed = color_standalone_square_refs(processed, reference_colors, show_colors)
    processed = color_bracketed_refs_with_text(processed, reference_colors, level, show_colors)
    processed = color_parenthetical_refs(processed, reference_colors, show_colors)
    processed = color_special_ref_markers(processed, show_colors)

    processed.present? ? processed.html_safe : ''
  end

  # Assigns and returns a consistent color class for a reference number
  def color_for(reference_colors, ref_num)
    reference_colors[ref_num] ||= REFERENCE_COLORS[(ref_num - 1) % REFERENCE_COLORS.length]
  end

  # Processes existing HTML spans, only transforming inner text that contains reference markers
  def process_reference_spans(text, reference_colors, level)
    return text if text.blank?

    text.to_s.gsub(%r{(<span[^>]*>.*?</span>)}m) do |span|
      if span.include?('[') && span.include?(']')
        inner_content = span.gsub(/<[^>]*>/, '')
        if inner_content == span
          span
        else
          processed_inner = process_reference_markers(inner_content, reference_colors, level + 1)
          processed_inner.present? ? span.gsub(inner_content, processed_inner) : span
        end
      else
        span
      end
    end
  end

  # Colors standalone square-bracket references like [1]
  def color_standalone_square_refs(text, reference_colors, show_colors = true)
    return text if text.blank?

    text.gsub(/\[(\d+)\](?![\d\]])/) do
      ref_num = Regexp.last_match(1).to_i
      color = show_colors ? color_for(reference_colors, ref_num) : ''
      classes = ['reference', 'ref-marker', 'inline-block', 'whitespace-nowrap', color].compact.join(' ')
      %(<span class="#{classes}" data-controller="reference-highlight" data-ref-number="#{ref_num}" data-action="mouseenter->reference-highlight#highlight mouseleave->reference-highlight#unhighlight">[#{ref_num}]</span>)
    end.html_safe
  end

  # Colors bracketed references with inner content like [1 ...]1
  def color_bracketed_refs_with_text(text, reference_colors, level, show_colors = true)
    return text if text.blank?

    text.gsub(/\[(\d+)(.*?)\]\1/m) do |match|
      ref_num = Regexp.last_match(1).to_i
      inner_content = Regexp.last_match(2).to_s
      next match if inner_content.blank?

      inner = process_nested_ref_content(inner_content, reference_colors, level)
      build_bracketed_ref_span(ref_num, inner, reference_colors, show_colors)
    end
  end

  def process_nested_ref_content(content, reference_colors, level)
    content.include?('[') && content.include?(']') ? process_reference_markers(content, reference_colors, level + 1) : content
  end

  def build_bracketed_ref_span(ref_num, inner, reference_colors, show_colors)
    color = show_colors ? color_for(reference_colors, ref_num) : ''
    left_marker  = %(<span class="ref-marker inline-block whitespace-nowrap">[#{ref_num} </span>)
    right_marker = %(<span class="ref-marker inline-block whitespace-nowrap">]#{ref_num}</span>)
    classes = ['reference', color].compact.join(' ')
    %(<span class="#{classes}" data-controller="reference-highlight" data-ref-number="#{ref_num}" data-action="mouseenter->reference-highlight#highlight mouseleave->reference-highlight#unhighlight">#{left_marker}#{inner}#{right_marker}</span>).html_safe
  end

  # Colors parenthetical references in the form (1)<...>
  # Excludes HTML tags like <td>, <tr>, <table>, etc. which may follow (1) in tables
  def color_parenthetical_refs(text, reference_colors, show_colors = true)
    return text if text.blank?

    text.gsub(/\((\d+)\)(<[^>]*>)/) do |match|
      ref_num = Regexp.last_match(1).to_i
      ref_text = Regexp.last_match(2).to_s
      next match if ref_text.blank?

      # Skip if the angle bracket content looks like an HTML tag (starts with tag name)
      # Real references contain law text like "W 2024-01-20/13, art. 5"
      next match if ref_text =~ /\A<\s*\/?(?:td|tr|th|table|div|span|p|br|a|img|ul|ol|li|h[1-6])\b/i

      build_parenthetical_ref_span(ref_num, ref_text, reference_colors, show_colors)
    end
  end

  def build_parenthetical_ref_span(ref_num, ref_text, reference_colors, show_colors)
    color = show_colors ? color_for(reference_colors, ref_num) : ''
    classes = ['reference', color, 'hover:underline', 'cursor-pointer'].compact.join(' ')
    %(<span class="#{classes}" data-controller="reference-highlight" data-ref-number="#{ref_num}" data-action="mouseenter->reference-highlight#highlight mouseleave->reference-highlight#unhighlight">(#{ref_num})#{ref_text}</span>).html_safe
  end

  # Colors special reference markers: (*), (+), (#)
  # These are less common but used for special annotations (970 + 235 + 3 = 1208 articles)
  def color_special_ref_markers(text, show_colors = true)
    return text if text.blank?

    text.gsub(/(\([*+#]\))(<[^>]*>)/) do |match|
      marker = Regexp.last_match(1).to_s
      ref_text = Regexp.last_match(2).to_s
      next match if ref_text.blank?

      build_special_marker_span(marker, ref_text, show_colors)
    end
  end

  def build_special_marker_span(marker, ref_text, show_colors)
    marker_span = %(<span class="inline-block whitespace-nowrap">#{marker}</span>)
    color = show_colors ? SPECIAL_MARKER_COLOR : ''
    cls = ['reference', color, 'hover:underline decoration-current hover:decoration-current',
           'cursor-pointer'].compact.join(' ')
    %(<span class="#{cls}">#{marker_span}#{ref_text}</span>).html_safe
  end
  # rubocop:enable Style/OptionalBooleanParameter

  # Ensures a non-breaking space before any reference span so it doesn't wrap to the next line alone
  def nb_space_before_reference(html)
    return ''.html_safe if html.blank?

    s = html.to_s
    # Replace a normal space or NBSP just before a reference span with &nbsp;
    s = s.gsub(/(?: |\u00A0)(<span[^>]*\breference\b[^>]*>)/i, '&nbsp;\\1')
    s.html_safe
  end

  # Renders the references section below an article or heading
  # Optional anchor_id allows unique in-page anchors (avoid duplicate IDs)
  def render_references_section(references_text, anchor_id: nil)
    return nil if references_text.blank?

    doc_number_positions = doc_number_positions_for(references_text)
    lines = reference_lines_for(references_text)
    return nil if lines.empty?

    references_html = build_references_html(lines, doc_number_positions)
    build_references_container(references_html, anchor_id)
  end

  def build_references_html(lines, doc_number_positions)
    last_ref_num = nil
    last_ref_color = nil

    lines.map do |line|
      trimmed = line.to_s.gsub(/\A(?:[[:space:]\u00A0\u202F]|&nbsp;)+|(?:[[:space:]\u00A0\u202F]|&nbsp;)+\z/, '')
      next if trimmed.match?(/\A(?:\[\d+\]|\(\d+\))\z/)

      ref_num = first_reference_number(line)

      # Determine if this is a continuation line
      is_continuation = ref_num.nil? && last_ref_num

      # Use current ref_num or inherit from parent
      active_ref_num = ref_num || last_ref_num
      active_ref_color = active_ref_num ? ref_color_class_for(active_ref_num) : nil

      # Process the line
      result = process_single_reference_line(line, doc_number_positions, active_ref_num, active_ref_color, is_continuation)

      # Update tracking for next iteration (only if this line has its own ref_num)
      if ref_num
        last_ref_num = ref_num
        last_ref_color = ref_color_class_for(ref_num)
      end

      result
    end.compact
  end

  def process_single_reference_line(line, doc_number_positions, ref_num, ref_color, is_continuation)
    processed_line = build_linked_reference_line(line, ref_color, doc_number_positions) ||
                     process_reference_markers(line, {})

    build_reference_row_html(ref_num, ref_color, processed_line, is_continuation)
  end

  def build_references_container(references_html, anchor_id)
    content_tag(:div, class: 'references references-section mt-3 not-prose', id: anchor_id) do
      safe_join([
                  content_tag(:h4, t('articles.changes'), class: 'font-semibold text-gray-800 dark:text-sky mb-2 border-0'),
                  content_tag(:div, safe_join(references_html), class: 'space-y-1')
                ])
    end
  end

  # Extracts all document numbers and their match offsets from a references block
  def doc_number_positions_for(text)
    positions = {}
    text.to_s.scan(%r{\d{4}-\d{2}-\d{2}/[A-Za-z0-9]+}) do |doc_num|
      positions[doc_num] = $LAST_MATCH_INFO.offset(0)
    end
    positions
  end

  # -- small helpers to reduce complexity in reference_lines_for --
  def closing_bracket_token?(line)
    line.match?(/\A\]\d+\z/)
  end

  def standalone_marker?(line)
    line.match?(/\A(?:\[\d+\]|\(\d+\))\z/)
  end

  # Splits reference text into non-empty, trimmed lines
  def reference_lines_for(text)
    raw_lines = text.to_s.split(/\r?\n/).map(&:strip).reject(&:blank?)
    merge_standalone_markers(raw_lines)
  end

  def merge_standalone_markers(raw_lines)
    merged = []
    i = 0
    i = process_line_for_merging(raw_lines, merged, i) while i < raw_lines.length
    merged
  end

  def process_line_for_merging(raw_lines, merged, index)
    line = raw_lines[index]
    if closing_bracket_token?(line) && merged.any?
      merged[-1] = "#{merged[-1]} #{line}".strip
      index + 1
    elsif standalone_marker?(line) && (index + 1) < raw_lines.length
      merged << "#{line} #{raw_lines[index + 1]}".strip
      index + 2
    else
      merged << line
      index + 1
    end
  end

  # Returns the first reference number from a line, from [n ...]n or (n)
  def first_reference_number(line)
    line[/\[(\d+)/, 1]&.to_i || line[/\((\d+)\)/, 1]&.to_i
  end

  # Returns the CSS color class for a given reference number
  def ref_color_class_for(ref_num)
    # Check if colors should be shown (defaults to true if not set)
    show_colors = defined?(@show_colors) ? @show_colors : true
    return 'text-gray-600 dark:text-gray-400' unless show_colors

    ref_num ? REFERENCE_COLORS[(ref_num - 1) % REFERENCE_COLORS.length] : 'text-gray-600 dark:text-gray-400'
  end

  # Builds a linked line for the first document number found in the line, preserving whitespace
  def build_linked_reference_line(line, ref_color, doc_number_positions)
    doc_number, lookup, doc_pos = find_lookup_for_line(line, doc_number_positions)
    return nil unless doc_number && lookup && doc_pos

    leading_ws, trailing_ws = extract_line_whitespace(line)
    reference_text = prepare_reference_text(line)
    linked_reference = build_reference_link(reference_text, lookup, ref_color)

    "#{leading_ws}#{linked_reference}#{trailing_ws}".html_safe
  end

  def extract_line_whitespace(line)
    leading = line[/^(?:[\s\u00A0\u202F]|&nbsp;)*/]
    trailing = line[/(?:[\s\u00A0\u202F]|&nbsp;)*$/]
    [leading, trailing]
  end

  def prepare_reference_text(line)
    prepared = unwrap_metadata_spans_or_entities(line.to_str.dup)
    strip_reference_markers_and_whitespace(prepared)
  end

  def build_reference_link(reference_text, lookup, _ref_color)
    url = law_url_from_lookup_and_ref(lookup, reference_text)
    safe_label = escape_preserving_lt_gt(reference_text)
    # Don't apply color to link - let it inherit from parent .reference span
    link_to(safe_label.html_safe, url, target: '_blank', rel: 'noopener noreferrer',
                                       class: 'hover:underline decoration-current hover:decoration-current',
                                       title: lookup[:title] || t('articles.view_legislation'))
  end

  def find_lookup_for_line(line, doc_number_positions)
    doc_number = doc_number_positions.keys.find { |dn| line.include?(dn) }
    return [nil, nil, nil] unless doc_number

    # Prefer the per-request cache populated by prefetch_document_lookups/lookup_document_references
    @_doc_lookup_cache ||= {}
    lookup_entry = @_doc_lookup_cache[doc_number]

    # Fallback: fetch once and write-through to cache if not present (should be rare)
    if !lookup_entry && (rec = DocumentNumberLookup.find_by(document_number: doc_number))
      law = Legislation.find_by(numac: rec.numac, language_id: rec.language_id)
      lookup_entry = { numac: rec.numac, language_id: rec.language_id, title: law&.title }
      @_doc_lookup_cache[doc_number] = lookup_entry
    end
    return [nil, nil, nil] unless lookup_entry

    doc_pos = line.index(doc_number)
    return [nil, nil, nil] unless doc_pos

    [doc_number, lookup_entry, doc_pos]
  end

  def unwrap_metadata_spans_or_entities(text)
    text
      .gsub(%r{<span[^>]*\bmetadata-tag\b[^>]*>(.*?)</span>}im, '\\1')
      .gsub(%r{&lt;\s*span[^&]*\bmetadata-tag\b[^&]*&gt;(.*?)&lt;/\s*span\s*&gt;}im, '\\1')
  end

  def strip_reference_markers_and_whitespace(text)
    text
      .gsub(/\A(?:[[:space:]\u00A0\u202F]|&nbsp;)+|(?:[[:space:]\u00A0\u202F]|&nbsp;)+\z/, '')
      .gsub(/\(\d+\)\s*/, '')
      .gsub(/\[\d+\]\s*/, '')
      .gsub(/\]\d+\s*/, '')
      .gsub(/[\u0000-\u001F\u007F]/, '')
  end

  def escape_preserving_lt_gt(text)
    tmp = text.to_s.gsub('&lt;', '__LT__').gsub('&gt;', '__GT__')
    ERB::Util.h(tmp).gsub('__LT__', '&lt;').gsub('__GT__', '&gt;')
  end

  def law_url_from_lookup_and_ref(lookup, reference_text)
    # Support both AR objects and cache hashes; reuse build_law_url for consistency
    lookup_hash =
      if lookup.respond_to?(:[])
        lookup
      else
        { numac: lookup.numac, language_id: lookup.language_id }
      end

    fragment = compute_article_fragment(reference_text, nil)
    build_law_url(lookup_hash, fragment)
  end

  # Builds the HTML for a single reference row
  # rubocop:disable Style/OptionalBooleanParameter
  def build_reference_row_html(ref_num, ref_color, processed_line, is_continuation = false)
    if is_continuation && ref_num
      build_row_continuation(processed_line, ref_num, ref_color)
    elsif ref_num
      build_row_with_marker(ref_num, ref_color, processed_line)
    else
      build_row_without_marker(processed_line)
    end
  end
  # rubocop:enable Style/OptionalBooleanParameter

  def unwrap_meta_and_reference_spans(html)
    html
      .gsub(%r{<span[^>]*\bmetadata-tag\b[^>]*>(.*?)</span>}im, '\\1')
      .gsub(%r{&lt;\s*span[^&]*\bmetadata-tag\b[^&]*&gt;(.*?)&lt;/\s*span\s*&gt;}im, '\\1')
      .gsub(%r{<span[^>]*\breference\b[^>]*>(.*?)</span>}im, '\\1')
      .gsub(%r{&lt;\s*span[^&]*\breference\b[^&]*&gt;(.*?)&lt;/\s*span\s*&gt;}im, '\\1')
  end

  def clean_and_strip_markers(str)
    str
      .gsub(/[\u0000-\u001F\u007F]/, '')
      .gsub(/[\u200B\u200C\u200D\u2060\uFEFF]/, '')
      .gsub(/\A(?:[[:space:]\u00A0\u202F]|&nbsp;)+|(?:[[:space:]\u00A0\u202F]|&nbsp;)+\z/, '')
      .gsub(/\A(?:(?:[[:space:]\u00A0\u202F]|&nbsp;)*)\((\d+)\)\s*/, '')
      .gsub(/\A(?:(?:[[:space:]\u00A0\u202F]|&nbsp;)*)\[(\d+)\]\s*/, '')
      .gsub(/\]\d+\s*/, '')
      .gsub(/\A(?:[[:space:]\u00A0\u202F]|&nbsp;)+/, '')
  end

  def build_row_with_marker(ref_num, ref_color, processed_line)
    # Build marker HTML manually to preserve unescaped -> in data-action
    reference_marker = %(<span class="#{ref_color}" data-ref-target="#{ref_num}">[#{ref_num}]</span>).html_safe

    cleaned = processed_line.to_s.gsub(/\[\d+\]/, '').gsub(/\]\d+/, '')
    if cleaned.include?('<a ')
      inner_node = %(<span class="reference #{ref_color}">#{cleaned}</span>).html_safe
      return %(<div class="text-sm mb-1 font-mono" data-controller="reference-highlight" data-ref-number="#{ref_num}" data-action="mouseenter->reference-highlight#highlightInline mouseleave->reference-highlight#unhighlightInline">#{reference_marker}#{inner_node}</div>).html_safe
    end

    cleaned = unwrap_meta_and_reference_spans(cleaned)
    cleaned = clean_and_strip_markers(cleaned)
    plain = escape_preserving_lt_gt(cleaned)
    reference_text = %(<span class="#{ref_color}">#{plain}</span>).html_safe
    %(<div class="text-sm mb-1 font-mono" data-controller="reference-highlight" data-ref-number="#{ref_num}" data-action="mouseenter->reference-highlight#highlightInline mouseleave->reference-highlight#unhighlightInline">#{reference_marker}#{reference_text}</div>).html_safe
  end

  def build_row_continuation(processed_line, parent_ref_num, parent_ref_color)
    # Calculate indentation: [N] + 2 spaces = digits.length + 4 characters
    # Use margin-left with ch units for monospace alignment
    indent_ch = parent_ref_num.to_s.length + 4

    cleaned = unwrap_meta_and_reference_spans(processed_line.to_s)
    cleaned = clean_and_strip_markers(cleaned)

    if cleaned.include?('<a ')
      inner_node = %(<span class="reference #{parent_ref_color}">#{cleaned}</span>).html_safe
      return %(<div class="text-sm mb-1 font-mono" style="margin-left: #{indent_ch}ch;" data-controller="reference-highlight" data-ref-number="#{parent_ref_num}" data-action="mouseenter->reference-highlight#highlightInline mouseleave->reference-highlight#unhighlightInline">#{inner_node}</div>).html_safe
    end

    plain = escape_preserving_lt_gt(cleaned)
    reference_text = %(<span class="#{parent_ref_color}">#{plain}</span>).html_safe
    %(<div class="text-sm mb-1 font-mono" style="margin-left: #{indent_ch}ch;" data-controller="reference-highlight" data-ref-number="#{parent_ref_num}" data-action="mouseenter->reference-highlight#highlightInline mouseleave->reference-highlight#unhighlightInline">#{reference_text}</div>).html_safe
  end

  def build_row_without_marker(processed_line)
    raw = unwrap_meta_and_reference_spans(processed_line.to_s)
    raw = clean_and_strip_markers(raw)
    if raw.include?('<a ')
      content_tag(:div, class: 'text-sm mb-1 font-mono text-gray-600 dark:text-gray-400') { raw.html_safe }
    else
      escaped = escape_preserving_lt_gt(raw)
      content_tag(:div, class: 'text-sm mb-1 font-mono text-gray-600 dark:text-gray-400') { escaped.html_safe }
    end
  end

  # Extracts the leading article number from the text and returns [number, rest]
  # Trims trailing spaces (including NBSP \u00A0 and narrow NBSP \u202F) after the number
  def extract_article_number_and_rest(text)
    s = text.to_s.dup.gsub(/\A[\u200B\u200C\u200D\u2060\uFEFF]+/, '')
    match = match_article_number_prefix(s)

    if match
      article_number = match[1].strip
      rest = s.sub(/\A#{Regexp.escape(match[0])}/, '')
    else
      article_number = nil
      rest = s
    end
    [article_number, rest]
  end

  def match_article_number_prefix(text)
    ws = '[[:space:]\u00A0\u202F\u200B\u200C\u200D\u2060\uFEFF]'
    text.match(/\A#{ws}*(#{article_number_pattern.source})(?:#{ws}*)/ix)
  end

  # Renders an abolished article with document number linking
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
  # rubocop:disable Metrics/AbcSize
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
    return nil unless refs.present?

    first_doc = refs.keys.first
    lookup = refs[first_doc]
    fragment = compute_article_fragment(abolished_inner, fallback_art_num)
    url = "/laws/#{lookup[:numac]}?language_id=#{lookup[:language_id]}"
    url += fragment if fragment
    url
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
    content_tag(:div, class: %w[abolished-article my-2 text-red-600 dark:text-red-400].join(' ')) do
      if article_number.present?
        cleaned_article_number = article_number.sub(/[[:space:]\u00A0\u202F]+$/, '')
        safe_join([article_number_tag(cleaned_article_number), content_html], ' ')
      else
        content_html
      end
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
      content_tag(:span, content_html, class: 'abolished-text text-red-600 dark:text-red-400')
    end
  end

  # Applies article-specific text transformations prior to line-break handling.
  # - Ensures content is safely sanitized when needed
  # - Highlights/bolds a leading article number (Art./Article/Artikel ...)
  # - Applies document-number linking and metadata highlights
  #
  # @param content [String, ActiveSupport::SafeBuffer]
  # @param content_type [Symbol] e.g., :regular_article
  # @return [ActiveSupport::SafeBuffer]
  # rubocop:disable Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def process_article_patterns(content, content_type = :regular_article)
    return ''.html_safe if content.blank?

    # Use as-is if caller already provided safe content, otherwise sanitize appropriately
    text = content.is_a?(ActiveSupport::SafeBuffer) ? content.to_s : safe_db_content(content, content_type).to_s
    # Normalize HTML entity NBSPs to actual NBSP characters to make regex matching reliable
    text = text.gsub(/(?:&nbsp;|&#160;|&#xA0;)/i, "\u00A0")
    # Remove zero-width characters that may appear between label and token and break matching
    text = text.gsub(/[\u200B\u200C\u200D\u2060\uFEFF]/, '')

    # Bold the leading article number for regular articles
    if content_type == :regular_article
      # Case 1: Pure text starts with the full article header using the central pattern
      # Avoid interpolating article_number_pattern.source into another /x regex,
      # because inline comments and free-spacing can corrupt the composed pattern.
      leading_ws_match = text.match(/\A[[:space:]\u00A0\u202F]*/)
      leading_len = leading_ws_match ? leading_ws_match[0].length : 0
      s = text[leading_len..].to_s
      if (m = article_number_pattern.match(s)) && m.begin(0).zero?
        header = m[0]
        consumed = leading_len + m.end(0)
        # Include an optionally spaced trailing dot (e.g., "1.1.1 .")
        if (dot_m = text[consumed..].to_s.match(/\A[[:space:]\u00A0\u202F]*\./))
          header += '.'
          consumed += dot_m[0].length
        end
        normalized = header.gsub(/[[:space:]\u00A0\u202F]+/, ' ').strip
        normalized = normalized.gsub(' .', '.')
        tagged = article_number_tag(normalized)
        remainder = text[consumed..] || ''
        text = "#{tagged} #{remainder.lstrip}"
      # Case 2a: Leading article number is inside a tag, but the trailing dot sits OUTSIDE the tag (e.g., </b>.)
      elsif (m = text.match(
        %r{
          \A[[:space:]\u00A0\u202F]*
          <(?:b|strong|span)\b[^>]*>
            [[:space:]\u00A0\u202F]*
            (?ix:(#{article_number_pattern.source}))
            [[:space:]\u00A0\u202F]*
          </(?:b|strong|span)>
          [[:space:]\u00A0\u202F]*\.
        }x
      ))
        # Append the outside dot to the captured number so it becomes part of the bold span
        num = "#{m[1]}."
        tagged = article_number_tag(num)
        text = text.sub(m[0], "#{tagged} ")
      # Case 2c: Label wrapped in a tag, number outside the tag (e.g., "<b>Artikel</b> 1.1.1." or with spaced dot)
      elsif (m = text.match(
        %r{
          \A[[:space:]\u00A0\u202F]*
          <(?:b|strong|span)\b[^>]*>
            [[:space:]\u00A0\u202F]*
            (?i:(Art|Article|Artikel))
            (\.)?
            [[:space:]\u00A0\u202F]*
          </(?:b|strong|span)>
          [[:space:]\u00A0\u202F]*
          (
            (?:[IVXLCDM]+)\.?(?:[[:space:]\u00A0\u202F])*  # Roman + arabic
            \d+(?:/\d+)?(?:\.\d+)*[a-z]*
            |[A-Za-z]\.??\d+(?:\.\d+)*
            |\d+(?:/\d+)?(?:\.\d+)*[a-z]*
            |[A-Za-z]+\.?
          )
          (?:([[:space:]\u00A0\u202F]*\.))?
        }x
      ))
        label = m[1]
        label_dot = m[2].to_s.strip # may be "." or empty
        token = m[3]
        has_spaced_or_immediate_dot = m[4].present?
        # Reconstruct preserving label dot (e.g., "Art.") and a single space before token
        num = "#{label}#{'.' if label_dot.present?} #{token}"
        num += '.' if has_spaced_or_immediate_dot && !token.to_s.strip.end_with?('.')
        tagged = article_number_tag(num)
        text = text.sub(m[0], "#{tagged} ")
      # Case 2b: Leading article label/number wrapped fully inside a simple tag like <b>, <strong>, or <span>
      elsif (m = text.match(
        %r{
          \A[[:space:]\u00A0\u202F]*
          <(?:b|strong|span)\b[^>]*>
            [[:space:]\u00A0\u202F]*
            (?ix:(#{article_number_pattern.source}))
            [[:space:]\u00A0\u202F]*
          </(?:b|strong|span)>
        }x
      ))
        num = m[1]
        # Guard: avoid wrapping only the label when no token is present inside the tag
        if num.to_s.strip.match?(/\A(?:Art(?:\.? )?|Article|Artikel)\.?\z/i)
          # Skip: let other cases handle the number outside the tag
        else
          tagged = article_number_tag(num)
          text = text.sub(m[0], "#{tagged} ")
        end
      end
    end

    # Add links to document numbers (also applies metadata highlighting)
    linked = apply_document_links(text)
    linked.is_a?(ActiveSupport::SafeBuffer) ? linked : linked.to_s.html_safe
  end
  # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  # Formats line breaks while preserving newlines for article number processing
  # Double line breaks get a paragraph indent (like BOG style) for visual separation
  def format_line_breaks(content)
    return ''.html_safe if content.blank?

    content = content.to_s.dup

    processed_content = process_article_patterns(content, :regular_article)

    # Convert newlines to <br/>, but avoid adding visible gaps before block elements
    # like <table>, lists, paragraphs, and headings. Also collapse multiple <br/>.
    processed_content = processed_content.to_s
    processed_content = processed_content.gsub("\r\n", "\n")
    
    # Double newlines (paragraph breaks) get an indent span for visual separation
    # This mimics BOG style where paragraphs are indicated by a small indent
    processed_content = processed_content.gsub(/\n\n+/, '<br/><span class="paragraph-indent"></span>')
    processed_content = processed_content.gsub("\n", '<br/>')

    # Remove any <br/> immediately before common block-level tags to prevent extra top spacing
    block_tags = %w[
      address article aside blockquote canvas dd div dl dt fieldset figcaption figure footer form
      h1 h2 h3 h4 h5 h6 header hr li main nav noscript ol p pre section table thead tbody tfoot tr td th ul
    ]
    rx_br_before_block = %r{(?:<br\s*/?>\s*)+(?=(?:</?(?:#{block_tags.join('|')})\b))}i
    processed_content = processed_content.gsub(rx_br_before_block, '')

    processed_content.html_safe
  end

  # Splits the content into main content and references based on the separator
  def split_content_and_references(content)
    return [content, nil] if content.blank?

    parts = content.to_s.split(/\s*-{4,}\s*/, 2)

    if parts.size > 1
      main_content = parts[0].to_s.strip
      references = parts[1].to_s.strip
      references = nil if references.blank?
    else
      main_content = content
      references = nil
    end

    [main_content, references]
  end

  # Looks up document numbers and returns their metadata
  def lookup_document_references(text)
    return {} if text.blank?

    doc_numbers = text.to_str.scan(%r{\d{4}-\d{2}-\d{2}/[A-Za-z0-9]+}).uniq
    return {} if doc_numbers.empty?

    load_missing_document_lookups(doc_numbers)
    build_lookup_hash(doc_numbers)
  end

  def load_missing_document_lookups(doc_numbers)
    @_doc_lookup_cache ||= {}
    missing = doc_numbers - @_doc_lookup_cache.keys
    return unless missing.any?

    DocumentNumberLookup.where(document_number: missing).find_each do |lookup|
      # Get title from the law that the lookup.numac points to, not from content.legislation
      # (content.legislation may be a different law that references this document number)
      law = Legislation.find_by(numac: lookup.numac, language_id: lookup.language_id)
      law_title = law&.title
      @_doc_lookup_cache[lookup.document_number] = { numac: lookup.numac, language_id: lookup.language_id, title: law_title }
    end
  end

  def build_lookup_hash(doc_numbers)
    doc_numbers.each_with_object({}) do |doc_number, hash|
      hash[doc_number] = @_doc_lookup_cache[doc_number] if @_doc_lookup_cache[doc_number]
    end
  end

  # Converts document numbers in text to clickable links while preserving HTML structure
  def apply_document_links(text)
    return ''.html_safe if text.blank?

    processed_text = ensure_metadata_highlights(text.to_str.dup)
    lookups = lookup_document_references(processed_text)
    original = processed_text.to_str.dup

    # Make whole metadata-tag spans clickable first
    processed_text = link_metadata_tag_spans(processed_text, lookups)

    # Merge an abolished prefix like (opgeheven)/(abrogé) with the metadata link and color red
    processed_text = merge_abolished_prefix_into_metadata_links(processed_text)

    # Then link any standalone document numbers elsewhere
    link_document_numbers(processed_text, lookups, original)
  end

  def link_metadata_tag_spans(text, lookups)
    # Link metadata-tag and nota-tag spans
    text = text.gsub(%r{<span class="[^"]*\b(metadata-tag|nota-tag)\b[^"]*">([^<]+)</span>}i) do |span_html|
      process_metadata_tag_span(span_html, Regexp.last_match, lookups)
    end

    # Link domain-tag spans (KB, W, L, etc.)
    text.gsub(%r{<span class="[^"]*\bdomain-tag\b[^"]*">([^<]+)</span>}i) do |span_html|
      process_domain_tag_span(span_html, Regexp.last_match, lookups)
    end
  end

  def process_metadata_tag_span(span_html, match, lookups)
    span_type = match[1].downcase
    inner_text = match[2]
    doc_number = inner_text[%r{\d{4}-\d{2}-\d{2}/[A-Za-z0-9]+}]
    return span_html unless doc_number

    lookup = lookups[doc_number]
    return span_html unless lookup

    fragment = extract_article_fragment(inner_text)
    url = build_law_url(lookup, fragment)
    anchor_classes = metadata_tag_anchor_classes(span_type)

    link_to(span_html.html_safe, url, class: anchor_classes, title: lookup[:title] || t('articles.view_legislation'),
                                      target: '_blank', rel: 'noopener noreferrer')
  end

  def extract_article_fragment(inner_text)
    art = inner_text[/\bart\.?\s*(\d+(?:[.:]\d+)*[a-z]*)/i, 1]
    return nil unless art

    norm = art.to_s.downcase.gsub(%r{[.:/]+}, '-').gsub(/[^a-z0-9-]/, '').gsub(/-+/, '-').gsub(/^-|-$/, '')
    norm.present? ? "#art-#{norm}" : nil
  end

  def process_domain_tag_span(span_html, match, lookups)
    inner_text = match[1]
    # Remove the angle brackets and extract document number
    clean_text = inner_text.gsub(/&lt;|&gt;/, '')
    doc_number = clean_text[%r{\d{4}-\d{2}-\d{2}/[A-Za-z0-9]+}]
    return span_html unless doc_number

    lookup = lookups[doc_number]
    return span_html unless lookup

    fragment = extract_article_fragment(clean_text)
    url = build_law_url(lookup, fragment)
    # Use same anchor classes as metadata-tag for consistency
    anchor_classes = metadata_tag_anchor_classes('metadata-tag')

    link_to(span_html.html_safe, url, class: anchor_classes, title: lookup[:title] || t('articles.view_legislation'),
                                      target: '_blank', rel: 'noopener noreferrer')
  end

  def metadata_tag_anchor_classes(span_type)
    if span_type == 'metadata-tag'
      ['text-amber-800 visited:text-amber-800 hover:text-amber-800',
       'dark:text-yellow-300 dark:visited:text-yellow-300 dark:hover:text-yellow-300',
       'hover:underline decoration-current hover:decoration-current'].join(' ')
    else
      'hover:underline decoration-current hover:decoration-current'
    end
  end

  # If we have a pattern like "(opgeheven) <DVR ...>" where the metadata tag has already been
  # converted into a clickable <a>...</a>, merge the abolished prefix into that anchor and
  # color it red, avoiding nested anchors.
  def merge_abolished_prefix_into_metadata_links(text)
    return text if text.blank?

    s = text.to_s
    s = merge_abolished_anchors(s)
    s = merge_abolished_spans(s)
    s.html_safe
  end

  def merge_abolished_anchors(text)
    pattern = %r{
      (\((?:opgeheven|abrogé)\))
      ((?:[[:space:]\u00A0\u202F]|&nbsp;)*)
      <a\b([^>]*?)>(\s*<span[^>]*\bmetadata-tag\b[^>]*>.*?</span>\s*)</a>
    }ix
    text.gsub(pattern) { merge_abolished_anchor_match(Regexp.last_match) }
  end

  def merge_abolished_spans(text)
    pattern = %r{
      (\((?:opgeheven|abrogé)\))
      ((?:[[:space:]\u00A0\u202F]|&nbsp;)*)
      <span([^>]*\bmetadata-tag\b[^>]*)>(.*?)</span>
    }ix
    text.gsub(pattern) { merge_abolished_span_match(Regexp.last_match) }
  end

  # Handles merging the abolished prefix into an existing metadata anchor
  def merge_abolished_anchor_match(match)
    prefix = match[1]
    spacing = match[2]
    attrs = match[3]
    inner = match[4]

    new_attrs = add_red_classes_to_anchor_attrs(attrs)
    escaped_prefix = ERB::Util.h(prefix)
    inner_with_red = inner.gsub(/<span[^>]*\bmetadata-tag\b[^>]*>/i, '<span class="text-red-600 dark:text-red-400">')
    "<a #{new_attrs}>#{escaped_prefix}#{spacing}#{inner_with_red}</a>"
  end

  def add_red_classes_to_anchor_attrs(attrs)
    red_anchor_classes = ['text-red-600', 'hover:underline decoration-current hover:decoration-current', 'dark:text-red-400']
    new_attrs = attrs.dup

    if new_attrs =~ /\bclass\s*=\s*"(.*?)"/i
      classes_val = Regexp.last_match(1)
      filtered = filter_anchor_classes_for_abolished(classes_val)
      merged = (filtered + red_anchor_classes).uniq.join(' ')
      new_attrs.sub(/\bclass\s*=\s*"(.*?)"/i, %(class="#{merged}"))
    else
      %(#{new_attrs} class="#{red_anchor_classes.join(' ')}")
    end
  end

  # Handles fallback case merging the abolished prefix with a metadata span (not linked)
  def merge_abolished_span_match(match)
    prefix = match[1]
    spacing = match[2]
    meta_attrs = match[3]
    meta_inner = match[4]

    meta_attrs_with_red = build_red_class_attrs(meta_attrs)
    escaped_prefix = ERB::Util.h(prefix)
    inner_span = "<span#{meta_attrs_with_red}>#{meta_inner}</span>"
    %(<span class="text-red-600 dark:text-red-400">#{escaped_prefix}#{spacing}#{inner_span}</span>)
  end

  def build_red_class_attrs(meta_attrs)
    red_only_classes = 'text-red-600 dark:text-red-400'
    if meta_attrs =~ /\bclass\s*=\s*"(.*?)"/i
      classes_val = Regexp.last_match(1)
      filtered = filter_metadata_classes(classes_val)
      %( class="#{(filtered + red_only_classes.split).uniq.join(' ')}")
    else
      %( class="#{red_only_classes}")
    end
  end

  def filter_metadata_classes(classes_val)
    classes_val.split(/\s+/).reject do |c|
      c == 'metadata-tag' || c.match?(/^(?:bg-amber-|text-amber-|dark:bg-yellow-|dark:text-yellow-|px-1|rounded)$/)
    end
  end

  def ensure_metadata_highlights(processed_text)
    if processed_text.include?('metadata-tag')
      unless processed_text.include?('nota-tag')
        processed_text = processed_text.gsub(/\(\s*(?:NOTA|Nota)\s*:[^)]*\)/i) do |note|
          %(<span class="#{nota_tag_classes}">#{ERB::Util.h(note)}</span>)
        end
      end
      processed_text
    else
      apply_metadata_highlights(processed_text)
    end
  end

  def link_document_numbers(processed_text, lookups, original)
    html = processed_text.to_str
    html.gsub(%r{(\d{4}-\d{2}-\d{2}/[A-Za-z0-9]+)}) do |_doc_number|
      link_doc_number_match(html, original, lookups, Regexp.last_match)
    end.html_safe
  end

  def link_doc_number_match(html, original, lookups, match)
    doc_number = match[1]
    idx = match.begin(0)

    return doc_number if skip_linking_doc_number?(html, idx)

    lookup = lookups[doc_number]
    return doc_number unless lookup

    build_doc_number_link(html, original, lookup, doc_number, idx)
  end

  def build_doc_number_link(html, original, lookup, doc_number, idx)
    fragment = extract_article_fragment_from_position(original, idx)
    url = build_law_url(lookup, fragment)
    link_classes = link_classes_for_position(html, idx)

    link_to(doc_number, url, class: link_classes, title: lookup[:title] || t('articles.view_legislation'), target: '_blank',
                             rel: 'noopener noreferrer')
  end

  def skip_linking_doc_number?(html, idx)
    inside_html_tag?(html, idx) ||
      inside_anchor?(html, idx) ||
      inside_skip_doc_links_span?(html, idx)
  end

  def link_classes_for_position(html, idx)
    if inside_metadata_span?(html, idx)
      [
        'hover:underline decoration-current hover:decoration-current'
      ].join(' ')
    else
      [
        'text-blue-600',
        'hover:underline decoration-current hover:decoration-current',
        'dark:text-blue-400'
      ].join(' ')
    end
  end

  def extract_article_fragment_from_position(original, idx)
    tail = original[idx..(idx + 200)] || ''
    art_match = tail.match(/^[^\n]*?(?:,|;)?\s*(?:art\.|artikel|article)\s*(\d+(?:[.:]\d+)*[a-z]*)/i)
    token = art_match && art_match[1] ? art_match[1] : nil
    return nil unless token

    norm = token.to_s.downcase
    norm = norm.gsub(%r{[.:/]+}, '-')
    norm = norm.gsub(/[^a-z0-9-]/, '')
    norm = norm.gsub(/-+/, '-')
    norm = norm.gsub(/^-|-$/, '')
    norm.present? ? "#art-#{norm}" : nil
  end

  def build_law_url(lookup, fragment)
    url = "/laws/#{lookup[:numac]}?language_id=#{lookup[:language_id]}"
    url += fragment if fragment
    url
  end

  # Returns true if the index is currently within an HTML tag like <span ...> or </span>
  def inside_html_tag?(html, idx)
    left_lt  = html.rindex('<', idx)
    left_gt  = html.rindex('>', idx)
    left_lt && (!left_gt || left_lt > left_gt)
  end

  # Returns true if the index lies within an <a ...> ... </a> region
  def inside_anchor?(html, idx)
    open_idx = html[0...idx]&.rindex(/<a\b[^>]*>/i)
    return false unless open_idx

    last_close_before = html[0...idx]&.rindex(%r{</a>}i)
    return false if last_close_before && last_close_before > open_idx

    close_after = html.index(%r{</a>}i, idx)
    !!close_after
  end

  # Returns true if the index lies within a <span class="... metadata-tag ..."> ... </span> region
  def inside_metadata_span?(html, idx)
    # Find the last opening span with metadata-tag before idx
    open_idx = html[0...idx]&.rindex(/<span[^>]*\bmetadata-tag\b[^>]*>/i)
    return false unless open_idx

    # Ensure a closing </span> after idx and that the last closing before idx is before the last opening
    last_close_before = html[0...idx]&.rindex(%r{<\s*/\s*span\s*>}i)
    return false if last_close_before && last_close_before > open_idx

    close_after = html.index(%r{<\s*/\s*span\s*>}i, idx)
    !!close_after
  end

  # Returns true if the index lies within a <span ... data-skip-doc-links="true" ...> ... </span>
  def inside_skip_doc_links_span?(html, idx)
    open_idx = html[0...idx]&.rindex(/<span[^>]*\bdata-skip-doc-links\s*=\s*"true"[^>]*>/i)
    return false unless open_idx

    last_close_before = html[0...idx]&.rindex(%r{<\s*/\s*span\s*>}i)
    return false if last_close_before && last_close_before > open_idx

    close_after = html.index(%r{<\s*/\s*span\s*>}i, idx)
    !!close_after
  end

  # Highlights metadata tags like <DVR ...> and <Ingevoegd bij DVR ...>
  # Also wraps domain-specific tags like <KB>, <W>, <L>, etc.
  def apply_metadata_highlights(text)
    return ''.html_safe if text.blank?

    str = text.to_str.dup
    str = transform_domain_specific_tags(str)
    str = highlight_dvr_tags(str)
    str = highlight_nota_tags(str)
    str.html_safe
  end

  def highlight_dvr_tags(str)
    patterns = [/&lt;\s*(?:Ingevoegd\s+bij\s+)?DVR[^&]*?&gt;/i, /<\s*(?:Ingevoegd\s+bij\s+)?DVR[^>]*?>/i]
    patterns.each do |pat|
      str = str.gsub(pat) do |match|
        literal = match.start_with?('&lt;') ? CGI.unescapeHTML(match) : match
        inner = literal.sub(/^<\s*/, '').sub(/\s*>$/, '')
        %(<span class="#{metadata_tag_classes}">&lt;#{ERB::Util.h(inner)}&gt;</span>)
      end
    end
    str
  end

  def highlight_nota_tags(str)
    str.gsub(/\(\s*(?:NOTA|Nota)\s*:\s*[^)]*\)/i) { |note| %(<span class="#{nota_tag_classes}">#{ERB::Util.h(note)}</span>) }
  end

  # @deprecated Use {#apply_document_links} instead
  alias link_document_references apply_document_links

  # Renders an annex article - preserve whitespace for concordance tables
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

  # Renders a future law article - just process normally, no special styling
  def render_future_law_article(content)
    process_article_with_references(content)
  end
end
# rubocop:enable Metrics/ModuleLength
