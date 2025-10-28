# frozen_string_literal: true

# == Application Helper
#
# Provides view helpers used throughout the application for:
# - Sorting and pagination
# - Legal document formatting
# - UI element generation
# - Content processing and sanitization
# - Reference management for legal citations
#
# @note All methods are available in all views through the ApplicationHelper module.
#
# @example Basic usage in views
#   <%= sort_link_to 'Title', 'title' %>
#   <%= timeago(Time.current) %>
#   <%= loading_tag %>
#
# @see https://guides.rubyonrails.org/action_view_helpers.html
# @see https://github.com/ddnexus/pagy
require 'English'
require 'cgi'
require 'nokogiri'

module ApplicationHelper
  # Include Pagy's frontend helpers for pagination (v43)
  include Pagy::Method
  include SortingHelper
  include ReferencesHelper
  include BrandingHelper
  include PopularLawsHelper

  # Branding methods (site_name, site_url, contact_email, og_*) → BrandingHelper
  # Popular law lookups (batch_popular_law_lookup, popular_law_path) → PopularLawsHelper

  # CSS classes used for metadata tag highlighting
  def metadata_tag_classes
    [
      'metadata-tag',
      'bg-amber-100 text-amber-800',
      'dark:bg-yellow-900/40 dark:text-yellow-300',
      'px-1 rounded'
    ].join(' ')
  end

  # CSS classes used for parenthetical NOTA highlighting
  def nota_tag_classes
    [
      'nota-tag',
      'bg-yellow-50 text-yellow-800',
      'dark:bg-yellow-900/30 dark:text-yellow-200',
      'italic px-1 rounded'
    ].join(' ')
  end

  # Prefetches document number lookups into the per-request cache to reduce queries.
  # @param doc_numbers [Array<String>] Unique document numbers to prefetch
  # @return [void]
  def prefetch_document_lookups(doc_numbers)
    return if doc_numbers.blank?

    @_doc_lookup_cache ||= {}
    missing = doc_numbers.uniq - @_doc_lookup_cache.keys
    return if missing.empty?

    # First, get all the lookups
    lookups = DocumentNumberLookup.where(document_number: missing).to_a
    return if lookups.empty?

    # Batch fetch the legislation titles by numac/language_id
    numac_lang_pairs = lookups.map { |l| [l.numac, l.language_id] }.uniq
    laws_by_key = {}
    numac_lang_pairs.each_slice(100) do |batch|
      Legislation.where(numac: batch.map(&:first), language_id: batch.map(&:last)).find_each do |law|
        laws_by_key[[law.numac, law.language_id]] = law.title
      end
    end

    lookups.each do |lookup|
      law_title = laws_by_key[[lookup.numac, lookup.language_id]]
      @_doc_lookup_cache[lookup.document_number] = {
        numac: lookup.numac,
        language_id: lookup.language_id,
        title: law_title
      }
    end
  rescue ActiveRecord::StatementInvalid => e
    # Gracefully handle missing document_number_lookups table (e.g., v089 DB)
    Rails.logger.warn("prefetch_document_lookups: table missing, skipping: #{e.message}")
  end

  # CSS classes for form elements with dark mode support
  #
  # @group Form Helpers

  # CSS classes for form checkbox inputs
  # @return [String] Tailwind CSS classes for checkbox inputs
  # @note Includes dark mode variants and focus states
  # @example
  #   <%= check_box_tag 'accept', '1', false, class: form_checkbox_classes %>
  def form_checkbox_classes
    # Base reset (appearance:none, borders, checked state, dark mode) is handled
    # globally in app/javascript/stylesheets/application.scss @layer base.
    # These classes only override sizing and accent color.
    'w-4 h-4 transition'
  end

  # CSS classes for form labels
  # @return [String] Tailwind CSS classes for form labels
  # @note Includes dark mode variants and proper spacing
  # @example
  #   <%= label_tag :email, 'Email', class: form_label_classes %>
  def form_label_classes
    [
      'block',
      'text-sm font-medium',
      'text-gray-700 dark:text-mist',
      'mb-1'
    ].join(' ')
  end

  # CSS classes for inline form labels placed next to controls (e.g., checkboxes)
  # @return [String] Tailwind CSS classes optimized for horizontal alignment
  # @note No bottom margin and tighter line-height to align with 16px checkboxes
  # @example
  #   <%= form.label :agree, 'Agree', class: form_inline_label_classes %>
  def form_inline_label_classes
    [
      'text-sm font-medium',
      'text-gray-700 dark:text-mist',
      'leading-4'
    ].join(' ')
  end

  # CSS classes for section headings
  # @return [String] Tailwind CSS classes for section headings
  # @note Includes dark mode variants and proper typography
  # @example
  #   <h2 class="<%= section_heading_classes %>">Section Title</h2>
  def section_heading_classes
    [
      'scroll-mt-24',
      'text-base md:text-lg font-semibold tracking-tight',
      'text-gray-800 dark:text-gray-200',
      'mb-0 mt-0 first:mt-0',
      'leading-tight',
      'text-justify'
    ].join(' ')
  end

  # CSS classes for smaller headings inside compact UI sections like the filters panel
  # Keeps visual hierarchy below main section headings while matching the app's typography.
  # @example
  #   <h4 class="<%= filters_heading_classes %>">Soorten Wetgeving</h4>
  def filters_heading_classes
    [
      'text-sm md:text-base font-semibold uppercase tracking-wider',
      'text-gray-800 dark:text-white/90',
      'mb-2 mt-0',
      'leading-snug'
    ].join(' ')
  end

  # Parses a single TOC line and returns an article_id like "art-<number>" or nil
  # Handles ranges (e.g., "Art. 24-25" -> art-24), multiple numbers ("Art. 38, 28/1, 39" -> art-38),
  # and single article references.
  # If the line contains a variant marker (e.g., "Art. 17 TOEKOMSTIG RECHT"), appends it (e.g., "art-17-toekomstig")
  def article_id_from_toc_line(line)
    line = line.to_s
    # Fast pre-check: skip the expensive extended-mode regex for lines that clearly
    # don't start with an article label. This eliminates >50% of calls instantly.
    return nil unless line.match?(/\A\s*(?:Art|Article|Artikel)\b/i)
    return nil unless line.match(/\A#{article_number_pattern.source}/ix)

    tail = strip_article_label(line)
    token = extract_article_token(tail)
    return nil unless token.present?

    # Extend token with any space/underscore-separated sub-numbers before a variant suffix
    # TOC: "1 4.9.TOEKOMSTIG RECHT" → space-separated
    # Content title: "6_3.12/1.TOEKOMSTIG_RECHT" → underscore-separated
    remainder = tail.sub(/\A#{Regexp.escape(token)}\.?[_\s]*/, '')
    if remainder.match?(%r{\A\d[\d./]*\.?(?:TOEKOMSTIG|DROIT|VLAAMS|WAALS|BRUSSELS|[_\s])}i)
      extra = remainder.match(%r{\A(\d[\d./]*)})&.captures&.first
      token = "#{token}.#{extra}" if extra.present?
    end

    normalized = normalize_article_token(token)
    return nil unless normalized.present?

    base_id = "art-#{normalized}"

    # Check if line contains variant marker and append if present
    variant = extract_article_variant_from_line(line)
    variant.present? ? "#{base_id}-#{variant}" : base_id
  end

  # Extracts article variant from a TOC line or article title
  # Returns normalized variant string like "toekomstig", "waals_gewest", etc.
  def extract_article_variant_from_line(line)
    return nil if line.blank?

    line_upper = line.upcase

    # Regional variants (Dutch)
    return 'waals_gewest' if line_upper.include?('WAALS') && line_upper.include?('GEWEST')
    return 'vlaams_gewest' if line_upper.include?('VLAAMS') && line_upper.include?('GEWEST')
    return 'brussels_hoofdstedelijk_gewest' if line_upper.include?('BRUSSELS') && line_upper.include?('GEWEST')

    # Regional variants (French)
    return 'region_wallonne' if line_upper.match?(/WALLON|NE.*REGION/)
    return 'region_flamande' if line_upper.match?(/FLAMAND|E.*REGION/)
    return 'region_bruxelles_capitale' if line_upper.match?(/BRUXELLOIS.*REGION/)

    # Future law variants
    return 'toekomstig' if line_upper.include?('TOEKOMSTIG')
    return 'futur' if line_upper.include?('FUTUR')

    nil
  end

  def strip_article_label(line)
    line.sub(/\A[[:space:]\u00A0\u202F]*(?:Artikel|Article|Art)\.?(?:[[:space:]\u00A0\u202F])*/i, '')
  end

  def extract_article_token(tail)
    token_match = tail.match(article_token_pattern)
    token_match && token_match[1]
  end

  def article_token_pattern
    # NOTE: [a-z]* (bis/ter/quater) appears both after the initial digits AND
    # after slash-digits so both "32quater /1" and "5/4bis" are captured.
    %r{\b((?:[IVXLCDM]+\.)?[[:space:]\u00A0\u202F]*\d+[a-z]*(?:[[:space:]\u00A0\u202F]*/\d+[a-z]*(?:-\d+)?)*(?:[.:]\d+)*|[A-Za-z]\.??\d+(?:[.:]\d+)*|\d+[a-z]*(?:[[:space:]\u00A0\u202F]*/\d+[a-z]*(?:-\d+)?)*(?:[.:]\d+)*|[A-Za-z]+)\.?}ix
  end

  def normalize_article_token(token)
    token.to_s.downcase.gsub(%r{[./:]+}, '-').gsub(/[^a-z0-9-]/, '').gsub(/-+/, '-').gsub(/^-|-$/, '')
  end

  # Generates a short, stable permalink slug from a line of text.
  # Prefers returning an article id (e.g., "art-12") when the text begins with an
  # article label. Otherwise, produces a parameterized slug from the first heading-like
  # portion of the text.
  #
  # @param text [String]
  # @param prefer_article_id [Boolean] when true, returns canonical article id if present; when false, always slugify heading text
  # @return [String] a short permalink slug (max ~80 chars)
  def generate_short_permalink(text, prefer_article_id: true)
    str = text.to_s
    return '' if str.blank?

    return article_id_from_toc_line(str) if prefer_article_id && article_id_from_toc_line(str)

    slug_from_text(str)
  end

  def slug_from_text(str)
    first = str.split("\n", 2).first.to_s.split('----------', 2).first.to_s
    cleaned = clean_text_for_slug(first)
    slug = cleaned.parameterize(preserve_case: false, separator: '-')
    slug = 'section' if slug.blank?
    slug[0, 160]
  end

  def clean_text_for_slug(text)
    cleaned = text.gsub(/\[\s*\d+\s*\]/, '').gsub(/\]\s*\d+/, '').gsub(/^\s*\(\d+\)\s*/, '')
    CGI.unescapeHTML(cleaned).gsub(/<[^>]*>/, ' ').strip
  end

  # Generates a consistent HTML id for section headings from the given text.
  # Removes inline reference markers and delegates to generate_short_permalink
  # with prefer_article_id: false to avoid accidental article id usage.
  # Always prefixes with "section-".
  #
  # @param text [String]
  # @return [String] e.g., "section-introduction" or "section-afdeling-1"
  def section_heading_id_for(text)
    section_heading_base_id(text)
  end

  # Computes the base section heading id (without uniqueness suffix).
  # Keeps existing normalization rules and returns the plain "section-<slug>" form.
  # @param text [String]
  # @return [String]
  def section_heading_base_id(text)
    base = text.to_s
    # Strip inline reference markers that should not influence the slug.
    # Use optional whitespace (\s*) to handle spacing variations between
    # TOC text (e.g., "[ 1 ]", "] 1") and article text (e.g., "[1]", "]1").
    base = base.gsub(/\[\s*\d+\s*\]/, '').gsub(/\]\s*\d+/, '').strip

    # Preserve inner text of abolished markers written with visible angle brackets
    # e.g. "Afdeling 1. Titel <Opgeheven 2023-01-15/42 art. 1>" ->
    #      "Afdeling 1. Titel Opgeheven 2023-01-15/42 art. 1"
    # Handles both literal <...> and encoded &lt;...&gt; forms.
    base = base.gsub(/(?:&lt;|<)\s*((?:Opgeheven|Abrogé)[^<>]*?)\s*(?:&gt;|>)/i, '\\1')

    "section-#{generate_short_permalink(base, prefer_article_id: false)}"
  end

  # Returns a unique, deterministic section heading id using a per-request counter.
  # The first occurrence of a base id uses the plain form; subsequent duplicates
  # receive a numeric suffix, e.g., "section-onderafdeling-3-2".
  #
  # IMPORTANT: Callers should iterate headings in document/TOC order and reset
  # @section_heading_counts = Hash.new(0) before iteration to ensure consistency
  # between the TOC and the articles rendering.
  #
  # @param text [String]
  # @return [String]
  def unique_section_heading_id(text)
    @_section_heading_counts ||= Hash.new(0)
    base_id = section_heading_base_id(text)
    count = (@_section_heading_counts[base_id] += 1)
    count == 1 ? base_id : "#{base_id}-#{count}"
  end

  # Adjusts hierarchy depth based on current indentation level
  # @param hierarchy [Array<String>] The current hierarchy
  # @param level [Integer] The indentation-derived level
  # @return [Array<String>] Trimmed hierarchy to the correct depth
  def adjust_hierarchy(hierarchy, level)
    return hierarchy if level >= hierarchy.size

    hierarchy[0...level]
  end

  # Formats a date according to the current locale
  # @param date [Date, String] The date to format
  # @param title [String, nil] Optional title to extract date from if date is N/A
  # @return [String, nil] Formatted date or the original value if blank
  # @note Uniform ISO-style: YYYY-MM-DD
  def localized_date(date, title: nil)
    # If date is a proper Date object, format it
    return date.strftime('%Y-%m-%d') if date.respond_to?(:strftime)

    # If date is "N/A" or blank, try to extract from title
    if date.blank? || date.to_s.strip.upcase == 'N/A'
      extracted = extract_date_from_title(title)
      return extracted if extracted.present?
    end

    # Return original value as fallback
    date
  end

  # Extracts a date from a law title (e.g., "15- DECEMBER 1995. - Neerlegging...")
  # @param title [String] The law title
  # @return [String, nil] Formatted date (DD/MM/YYYY) or nil if not found
  def extract_date_from_title(title)
    return nil if title.blank?

    # Month name mappings (Dutch, French, English)
    months = {
      'JANUARI' => 1, 'JANUARY' => 1, 'JANVIER' => 1,
      'FEBRUARI' => 2, 'FEBRUARY' => 2, 'FEVRIER' => 2, 'FÉVRIER' => 2,
      'MAART' => 3, 'MARCH' => 3, 'MARS' => 3,
      'APRIL' => 4, 'AVRIL' => 4,
      'MEI' => 5, 'MAY' => 5, 'MAI' => 5,
      'JUNI' => 6, 'JUNE' => 6, 'JUIN' => 6,
      'JULI' => 7, 'JULY' => 7, 'JUILLET' => 7,
      'AUGUSTUS' => 8, 'AUGUST' => 8, 'AOUT' => 8, 'AOÛT' => 8,
      'SEPTEMBER' => 9, 'SEPTEMBRE' => 9,
      'OKTOBER' => 10, 'OCTOBER' => 10, 'OCTOBRE' => 10,
      'NOVEMBER' => 11, 'NOVEMBRE' => 11,
      'DECEMBER' => 12, 'DECEMBRE' => 12, 'DÉCEMBRE' => 12
    }

    # Pattern: "DD- MONTH YYYY" or "DD MONTH YYYY" at start of title
    # Examples: "15- DECEMBER 1995.", "17 OCTOBER 1995."
    month_pattern = months.keys.join('|')
    match = title.to_s.match(/\A\s*(\d{1,2})[–-]?\s*(#{month_pattern})\s+(\d{4})/i)

    return nil unless match

    day = match[1].to_i
    month_name = match[2].upcase
    year = match[3].to_i
    month = months[month_name]

    return nil unless month && day.between?(1, 31) && year.between?(1800, 2100)

    format('%04d-%02d-%02d', year, month, day)
  end

  # Creates a time element with relative time functionality
  # @param date [Time, Date, DateTime, String] The date to format
  # @param format [Symbol] The date format to use (defaults to :long)
  # @return [ActiveSupport::SafeBuffer, nil] HTML time element or nil if date is blank
  # @note Uses the timeago.js library for relative time display
  # @example
  #   timeago(Time.current) #=> <time>formatted date</time>
  def timeago(date, format: :long)
    return if date.blank?

    content = I18n.l(date, format: format)

    tag.time(content,
             title: content,
             data: {
               controller: 'timeago',
               timeago_datetime_value: date.iso8601,
               timeago_add_suffix_value: true
             })
  end

  # Generates a loading/complete status UI with accessibility attributes
  # @param status [Symbol] :loading or :done/:completed
  # @return [ActiveSupport::SafeBuffer] HTML for a status indicator
  # @note Uses SVG for smooth animation and includes visible localized text
  # @example
  #   loading_tag                 #=> spinner + "Loading..."
  #   loading_tag(status: :done)  #=> check icon + "Completed."
  def loading_tag(status: :loading)
    label = loading_status_label(status)
    icon  = loading_svg_for(status)

    content_tag(
      :div,
      role: 'status',
      aria: { live: 'polite' },
      class: 'flex items-center gap-2 text-sm text-gray-600 dark:text-mist'
    ) do
      safe_join([
                  icon.html_safe,
                  content_tag(:span, CGI.escapeHTML(label)),
                  content_tag(:span, CGI.escapeHTML(label), class: 'sr-only')
                ])
    end
  end

  # Localized label for loading/done states extracted for readability
  def loading_status_label(status)
    case status.to_sym
    when :done, :completed
      I18n.t('loading_status.completed', default: 'Done')
    else
      I18n.t('loading_status.loading', default: I18n.t('loading'))
    end
  end

  # SVG icon for the given status, returned as a string (HTML-safe at call site)
  def loading_svg_for(status)
    if %i[done completed].include?(status.to_sym)
      <<~SVG
        <svg aria-hidden="true" class="w-5 h-5 text-green-600 dark:text-green-400" viewBox="0 0 20 20" fill="currentColor" xmlns="http://www.w3.org/2000/svg">
          <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.707a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293A1 1 0 106.293 10.707l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd"/>
        </svg>
      SVG
    else
      <<~SVG
        <svg aria-hidden="true" class="w-5 h-5 text-gray-300 dark:text-gray-600 animate-spin" style="fill: var(--accent-600)" viewBox="0 0 100 101" fill="none" xmlns="http://www.w3.org/2000/svg">
          <path d="M100 50.5908C100 78.2051 77.6142 100.591 50 100.591C22.3858 100.591 0 78.2051 0 50.5908C0 22.9766 22.3858 0.59082 50 0.59082C77.6142 0.59082 100 22.9766 100 50.5908ZM9.08144 50.5908C9.08144 73.1895 27.4013 91.5094 50 91.5094C72.5987 91.5094 90.9186 73.1895 90.9186 50.5908C90.9186 27.9921 72.5987 9.67226 50 9.67226C27.4013 9.67226 9.08144 27.9921 9.08144 50.5908Z" fill="currentColor"/>
          <path d="M93.9676 39.0409C96.393 38.4038 97.8624 35.9116 97.0079 33.5539C95.2932 28.8227 92.871 24.3692 89.8167 20.348C85.8452 15.1192 80.8826 10.7238 75.2124 7.41289C69.5422 4.10194 63.2754 1.94025 56.7698 1.05124C51.7666 0.367541 46.6976 0.446843 41.7345 1.27873C39.2613 1.69328 37.813 4.19778 38.4501 6.62326C39.0873 9.04874 41.5694 10.4717 44.0505 10.1071C47.8511 9.54855 51.7191 9.52689 55.5402 10.0491C60.8642 10.7766 65.9928 12.5457 70.6331 15.2552C75.2735 17.9648 79.3347 21.5619 82.5849 25.841C84.9175 28.9121 86.7997 32.2913 88.1811 35.8758C89.083 38.2158 91.5421 39.6781 93.9676 39.0409Z" fill="currentFill"/>
        </svg>
      SVG
    end
  end

  # Skeleton shimmer placeholder for content loading
  # @param kind [Symbol] currently supports :article
  # @return [ActiveSupport::SafeBuffer]
  def loading_skeleton_tag(kind: :article)
    label = loading_status_label(:loading)

    case kind.to_sym
    when :article
      skeleton_article(label)
    when :list
      skeleton_list(label)
    else
      skeleton_generic(label)
    end
  end

  private

  def skeleton_article(label)
    lines = ['h-6 w-1/3', 'h-4 w-5/6', 'h-4 w-2/3', 'h-4 w-11/12', 'h-4 w-3/4'].map { |c| skeleton_div(c) }
    wrapper = content_tag(:div, class: 'p-6 space-y-6') { safe_join(lines) }

    content_tag(:div, role: 'status', aria: { live: 'polite' }) do
      safe_join([wrapper, content_tag(:span, CGI.escapeHTML(label), class: 'sr-only')])
    end
  end

  def skeleton_list(label)
    groups = [
      ['h-5 w-2/3', 'h-4 w-5/6', 'h-4 w-1/2'],
      ['h-5 w-1/2', 'h-4 w-2/3', 'h-4 w-1/3'],
      ['h-5 w-3/4', 'h-4 w-5/6', 'h-4 w-2/5'],
      ['h-5 w-2/3', 'h-4 w-1/2', 'h-4 w-4/6']
    ]

    sections = groups.map do |widths|
      content_tag(:div, class: 'space-y-2') { safe_join(widths.map { |c| skeleton_div(c) }) }
    end

    wrapper = content_tag(:div, class: 'p-6 space-y-6') { safe_join(sections) }

    content_tag(:div, role: 'status', aria: { live: 'polite' }) do
      safe_join([wrapper, content_tag(:span, CGI.escapeHTML(label), class: 'sr-only')])
    end
  end

  def skeleton_generic(label)
    lines = ['h-4 w-2/3', 'h-4 w-5/6', 'h-4 w-1/2'].map { |c| skeleton_div(c) }
    wrapper = content_tag(:div, class: 'p-6 space-y-3') { safe_join(lines) }

    content_tag(:div, role: 'status', aria: { live: 'polite' }) do
      safe_join([wrapper, content_tag(:span, CGI.escapeHTML(label), class: 'sr-only')])
    end
  end

  def skeleton_div(size_classes)
    content_tag(:div, '', class: "skeleton #{size_classes} rounded")
  end

  # Highlight helpers (private)
  def dom_skip_highlight_node?(node, disallowed_tags, skip_class_exact)
    node.ancestors.any? do |anc|
      disallowed_tags.include?(anc.name.downcase) ||
        begin
          classes = anc['class'].to_s.split(/\s+/)
          classes.any? { |c| skip_class_exact.include?(c) || c.start_with?('domain-') }
        end
    end
  end

  def dom_highlight_html(original, pattern)
    fragment = Nokogiri::HTML::DocumentFragment.parse(original)
    changed = process_dom_highlight_nodes(fragment, pattern)
    changed ? fragment.to_html.html_safe : nil
  rescue StandardError
    nil
  end

  def process_dom_highlight_nodes(fragment, pattern)
    disallowed_tags = %w[mark script style]
    skip_class_exact = %w[metadata-tag nota-tag domain-tag]
    changed = false

    fragment.traverse do |node|
      next unless node.text? && node.text.present?
      next if dom_skip_highlight_node?(node, disallowed_tags, skip_class_exact)

      new_html = node.text.gsub(pattern) do |m|
        changed = true
        %(<mark class="bg-yellow-200 dark:bg-yellow-800">#{CGI.escapeHTML(m)}</mark>)
      end
      node.replace(Nokogiri::HTML::DocumentFragment.parse(new_html)) if new_html != node.text
    end
    changed
  end

  def split_highlight_html(original, pattern)
    segments = original.split(/(<[^>]+>)/)
    highlighted = segments.map do |seg|
      if seg.start_with?('<') && seg.end_with?('>')
        seg
      else
        seg.gsub(pattern) { |m| content_tag(:mark, m, class: 'bg-yellow-200 dark:bg-yellow-800') }
      end
    end.join
    highlighted.html_safe
  end

  public

  # Highlights a search term within text for unified search results.
  # Wraps matched substrings in <mark> with the search-highlight class.
  # @param text [String] The text to highlight within
  # @param term [String] The search query to highlight
  # @return [ActiveSupport::SafeBuffer] HTML with highlighted terms
  def highlight_search_term(text, term)
    return text if text.blank? || term.blank?

    escaped_text = ERB::Util.html_escape(text.to_s)
    words = term.to_s.split(/\s+/).reject(&:blank?).map { |w| Regexp.escape(w) }
    return escaped_text if words.empty?

    pattern = /(#{words.join('|')})/i
    escaped_text.gsub(pattern) { |m| "<mark class=\"search-highlight\">#{m}</mark>" }.html_safe
  end

  # Highlights search terms in the given text by wrapping them in <mark> tags
  # @param law_title [String] The text to highlight terms in
  # @return [ActiveSupport::SafeBuffer] HTML with highlighted search terms
  # @note Handles case variations of the search term for better highlighting
  # @example
  #   keyword_replacer(law_title: "Some Law Title") #=> "Some <mark>Law</mark> Title" (if searching for "law")
  def keyword_replacer(law_title:)
    term = params[:title].to_s.strip
    return law_title if term.blank?

    original = law_title.to_s

    # Match highlighting to search mode:
    # - Exact mode: highlight the exact phrase
    # - Flexible mode (default): highlight each word separately
    if params[:search_mode] == 'exact'
      pattern = /#{Regexp.escape(term)}/i
    else
      # Split search term into individual words (matching LawSearchService.extract_tokens behavior)
      words = term.split(/\s+/).reject(&:blank?).map { |w| Regexp.escape(w) }
      return law_title if words.empty?

      # Use substring matching to match the actual search behavior
      # LawSearchService uses LIKE '%term%' which matches substrings, so highlighting
      # must also match substrings (e.g., "digital" should highlight inside "digitalisering")
      pattern = /(#{words.join('|')})/i
    end

    dom_highlight_html(original, pattern) || split_highlight_html(original, pattern)
  end

  # Converts newlines in text to HTML line breaks and paragraphs
  #
  # This method processes plain text and converts it to HTML with proper paragraph
  # and line break formatting. It's particularly useful for displaying user-generated
  # content or database-stored text that needs to maintain its original formatting.
  #
  # @param field [String] The text to process
  # @return [ActiveSupport::SafeBuffer] HTML with <p> and <br> tags for line breaks
  # @note Sanitization is currently disabled for testing purposes
  # @see https://api.rubyonrails.org/classes/ActionView/Helpers/TextHelper.html#method-i-simple_format simple_format documentation
  #
  # @example Basic usage
  #   print_multiline("First line\nSecond line\n\nNew paragraph")
  #   #=> "<p>First line<br />\n  #   #    Second line</p>\n  #   #    <p>New paragraph</p>"
  #
  # @example With blank input
  #   print_multiline(nil)  #=> nil
  #   print_multiline("")   #=> ""
  # @option options [Boolean] :skip_paragraphs When true, doesn't wrap in <p> tags
  def print_multiline(field, options = {})
    return if field.blank?

    # Always escape angle brackets first so literal <...> sequences remain visible everywhere
    # (index and show) and are not interpreted as HTML tags by the browser.
    escaped = escape_angle_brackets(field.to_s)

    if options[:skip_paragraphs]
      escaped.gsub(/\r?\n/, '<br>').html_safe
    else
      # Temporarily disable sanitization for testing
      # In production, consider enabling sanitization:
      # sanitize(simple_format(escaped), tags: %w[br p], attributes: [])
      simple_format(escaped, {}, sanitize: false)
    end
  end

  # Regex used to detect an article label + number at the start of a line
  # Supports Dutch/French labels and common numbering variants:
  # - Art. 1. / Article 2.3. / Artikel 4bis
  # - A.1 (lettered articles)
  # - 28/1 (slash sub-numbering)
  # Returns a memoized Regexp in extended mode for readability
  def article_number_pattern
    @article_number_pattern ||= %r{
      (?:Art|Article|Artikel)(?:\.[ ]?|[ ])(?:[\s\u00A0\u202F])*     # label: dot with optional space, OR space without dot
      (?:
        (?:[IVXLCDM]+)\.?(?:[[:space:]\u00A0\u202F])*\d+[a-z]*(?:[[:space:]\u00A0\u202F]*/\d+[a-z]*(?:-\d+)?)*(?:[.:]\d+)*  # Roman + arabic, e.g., IV. 54/5/25-2 or XX. 1 (supports colon)
        |
        \d*N\d+                                                  # Annex articles: N1, N2, 1N1, 1N2, 2N2 (MUST come before letter pattern to avoid N being caught)
        |
        [A-Za-z]\.??\d+(?:[.:]\d+)*                              # A.1 or A1.2 (supports colon)
        |
        \d+[a-z]*(?:[[:space:]\u00A0\u202F]*/\d+[a-z]*(?:-\d+)?)*(?:[.:]\d+)*                   # 28/1, 32quater /1, 5/4bis, 61/25-2, 2.3 (supports colon like 1:34)
        |
        [A-Za-z]+\.?                                             # Letter-only, e.g., M.
      )
      # Optional special designations - both underscore and space-separated variants
      # Underscore variants: 4_4.1.TOEKOMSTIG_RECHT, 14_WAALS_GEWEST
      # Space variants: 4 TOEKOMSTIG RECHT, 14 WAALS GEWEST
      (?:
        [[:space:]\u00A0\u202F]*_[\d./]*(?:TOEKOMSTIG_RECHT|DROIT_FUTUR|VLAAMS_GEWEST|WAALS_GEWEST|BRUSSELS(?:E)?_(?:HOOFDSTEDELIJK_)?GEWEST)
        |
        [\s\u00A0\u202F]+(?:BRUSSELS(?:E)?[\s\u00A0\u202F]+(?:HOOFDSTEDELIJK[\s\u00A0\u202F]+)?GEWEST|WAALS[\s\u00A0\u202F]+GEWEST|VLAAMS[\s\u00A0\u202F]+GEWEST|TOEKOMSTIG[\s\u00A0\u202F]+RECHT|DROIT[\s\u00A0\u202F]+FUTUR)
        |
        \.[\s\u00A0\u202F]+(?:TOEKOMSTIG[\s\u00A0\u202F]+RECHT|DROIT[\s\u00A0\u202F]+FUTUR|WAALS[\s\u00A0\u202F]+GEWEST|VLAAMS[\s\u00A0\u202F]+GEWEST|BRUSSELS(?:E)?[\s\u00A0\u202F]+(?:HOOFDSTEDELIJK[\s\u00A0\u202F]+)?GEWEST)
      )?
      \.?                                                           # optional trailing dot
    }ix
  end

  # Determines the article type based on the database article_type, heading content, and content
  # @param article_heading [String, nil] The article heading text
  # @param content [String, nil] The article content to check for abolished markers
  # @param article_type [String, nil] The database article_type (e.g., 'ART', 'LNK', 'ABO')
  # @return [Symbol] The determined article type (:abolished_law, :section_heading, :abolished_article, or :regular_article)
  # @note
  #   - ABO type is for abolished laws (highest priority)
  #   - ART type articles starting with any article number format followed by <Opgeheven or <Abrogé are abolished_article (second highest priority)
  #   - LNK type represents TOC/section entries and is always a section heading unless explicitly marked abolished
  #   - All other articles are regular_article
  # @example
  #   determine_article_type("ABO123", nil, 'ABO') #=> :abolished_law
  #   determine_article_type("ART456", "Art. 1. <Opgeheven...", 'ART') #=> :abolished_article
  #   determine_article_type("ART789", "Article 2.3. <Abrogé...", 'ART') #=> :abolished_article
  #   determine_article_type("LNK456", "Short section", 'LNK') #=> :section_heading
  #   determine_article_type("ART123", "Regular article text...", 'ART') #=> :regular_article
  def determine_article_type(_article_heading, content = nil, article_type = nil)
    at = article_type.to_s
    body = content.to_s

    return :abolished_law if abolished_law?(at)
    return :abolished_article if abolished_article_header?(at, body)

    if at == 'LNK'
      return :abolished_section if abolished_section_marker?(body)

      return :section_heading
    end

    # Check for special article types
    return :annex_article if annex_article?(body)
    return :future_law_article if future_law_article?(body)

    :regular_article
  end

  # -- Predicates extracted to reduce complexity of determine_article_type --
  def abolished_law?(article_type_str)
    article_type_str == 'ABO'
  end

  def abolished_article_header?(article_type_str, content_str)
    return false unless article_type_str == 'ART'

    s = content_str.to_s
    return false if s.blank?

    # Fast pre-check: skip the expensive article_number_pattern regex if the content
    # doesn't contain abolished markers at all. >95% of articles are NOT abolished.
    return false unless s.match?(/opgeheven|abrog/i)

    # Detect a leading article header and only inspect a short window right after it.
    # This avoids classifying articles as abolished when a later paragraph (e.g., § 2)
    # contains an abolished notice.
    header_match = s.match(/\A[[:space:]\u00A0\u202F]*#{article_number_pattern.source}/ix)
    return false unless header_match

    header_end = header_match.end(0)
    window = s[header_end, 160].to_s

    # Normalize and check only markers that appear immediately after the header
    window = CGI.unescapeHTML(window)
    window = window.gsub(/(?:&nbsp;|&#160;|&#xA0;)/i, ' ').strip

    return true if window.match(/\A[[:space:]\u00A0\u202F]*\(\s*(?:opgeheven|abrogé)\s*\)/i)
    return true if window.match(/\A[[:space:]\u00A0\u202F]*(?:<|&lt;)\s*(?:Opgeheven|Abrogé)\b/i)

    false
  end

  def abolished_section_marker?(content_str)
    s = content_str.to_s
    s.match(/\(\s*(?:opgeheven|abrogé)\s*\)/i) || s.match(/(?:<|&lt;)\s*(?:Opgeheven|Abrogé)\b/i)
  end

  # Detects annex articles (Art. N1, Art. N2, Art. 1N2, Art. 2N2, etc.)
  # @param content_str [String] The article content
  # @return [Boolean]
  def annex_article?(content_str)
    s = content_str.to_s
    # Match article numbers like N1, N2, 1N1, 1N2, 2N2, 3N2, etc.
    s.match?(/\AArt\.\s*(?:\d*N\d+|N\d+)\.\s/i)
  end

  # Detects future law articles (Art. X TOEKOMSTIG RECHT / DROIT FUTUR)
  # Handles both space-separated and underscore-separated variants:
  #   - "Art. 17 TOEKOMSTIG RECHT" (space format)
  #   - "Art. 1_4.9.TOEKOMSTIG_RECHT." (underscore/Justel format)
  #   - "Art. 1.1.4_TOEKOMSTIG_RECHT" (dotted + underscore)
  # @param content_str [String] The article content
  # @return [Boolean]
  def future_law_article?(content_str)
    s = content_str.to_s
    # Space-separated: Art. 17 TOEKOMSTIG RECHT
    return true if s.match?(%r{\AArt\.\s*\d+(?:[./]\d+)*\s+(?:TOEKOMSTIG[\s_]RECHT|DROIT[\s_]FUTUR)}i)
    # Underscore/Justel-separated: Art. 1_4.9.TOEKOMSTIG_RECHT
    return true if s.match?(%r{\AArt\.\s*\d+(?:[_./]\d+)*[_.](?:TOEKOMSTIG_RECHT|DROIT_FUTUR)}i)

    false
  end

  def short_section_content?(content_str)
    content_str.to_s.length < 500
  end

  # Determines the hierarchy level of a section heading for proper nesting
  # Lower numbers = higher in hierarchy (e.g., DEEL/PART is level 1)
  # @param content [String] The section heading text
  # @return [Integer] Hierarchy level (1-7, or 99 for unknown)
  def section_heading_level(content)
    text = content.to_s.strip.upcase

    # Level 1: DEEL/PART/PARTIE
    return 1 if text.match?(/\A(?:DEEL|PART|PARTIE)\b/)

    # Level 2: BOEK/LIVRE/BOOK
    return 2 if text.match?(/\A(?:BOEK|LIVRE|BOOK)\b/)

    # Level 3: TITEL/TITRE/TITLE
    return 3 if text.match?(/\A(?:TITEL|TITRE|TITLE)\b/)

    # Level 4: HOOFDSTUK/CHAPITRE/CHAPTER
    return 4 if text.match?(/\A(?:HOOFDSTUK|CHAPITRE|CHAPTER)\b/)

    # Level 5: AFDELING/SECTION
    return 5 if text.match?(/\A(?:AFDELING|SECTION)\b/)

    # Level 6: ONDERAFDELING/SOUS-SECTION
    return 6 if text.match?(/\A(?:ONDERAFDELING|SOUS-SECTION|SUBSECTION)\b/)

    # Level 7: Other named sections
    return 7 if text.match?(/\A(?:PARAGRAAF|PARAGRAPHE|PARAGRAPH)\b/)

    # Default: assume it's a lower-level heading
    99
  end

  # Central renderer used by views to output article content or headings.
  # Decides how to render based on the detected article type.
  # @param content [String] the article text/content
  # @param article_heading [String, nil] the article title/heading
  # @param db_type [String, nil] the DB article_type (e.g., 'ART', 'LNK', 'ABO')
  # @return [ActiveSupport::SafeBuffer]
  def print_article(content, article_heading = nil, db_type = nil)
    type = determine_article_type(article_heading, content, db_type)
    case type
    when :section_heading
      render_section_heading_with_references(content)
    when :abolished_section
      render_abolished_section_heading(content)
    when :abolished_law
      render_abolished_law(content)
    when :abolished_article
      render_abolished_article(content)
    when :annex_article
      render_annex_article(content)
    when :future_law_article
      render_future_law_article(content)
    else
      process_article_with_references(content)
    end
  end

  # Reference extraction/rendering and linkification lives in `ReferencesHelper`.

  # Controls whether sanitization is enabled.
  # Defaults to enabled, with the ability to disable in non-production via ENV.
  # Set WW_DISABLE_SANITIZE to '1', 'true', 'yes', or 'on' to disable.
  # In production, sanitization is always enabled.
  # @return [Boolean]
  def sanitization_enabled?
    return true if Rails.env.production?

    val = ENV.fetch('WW_DISABLE_SANITIZE', nil)
    return true if val.nil?

    !%w[1 true yes on].include?(val.to_s.strip.downcase)
  end

  # Safely escapes HTML content from the database with different sanitization rules
  # based on the content type. For regular articles, preserves table tags and their structure.
  # For all other content types, fully sanitizes HTML.
  #
  # @param content [String] The HTML content to sanitize
  # @param content_type [Symbol] The type of content (:regular_article, :abolished_article, etc.)
  # @return [ActiveSupport::SafeBuffer] Sanitized and HTML-safe content
  def safe_db_content(content, content_type = :regular_article)
    return ''.html_safe if content.blank?

    unescaped = CGI.unescapeHTML(content.to_s)

    # Normalize spaces: convert NBSP to regular space, collapse multiple consecutive spaces
    # Non-breaking spaces and multiple spaces from Justel cause huge gaps when text is justified
    # Preserve Justel paragraph markers (\n followed by 2+ spaces) as double newlines
    # so format_line_breaks can detect them after the sanitizer strips whitespace.
    unescaped = unescaped.gsub(/\n  +/, "\n\n")
    unescaped = unescaped.tr("\u00A0\u202F", ' ').gsub(/  +/, ' ')

    return unescaped.html_safe unless sanitization_enabled?

    if content_type == :regular_article
      # 1) If table-related tags are HTML-encoded in DB, unencode only those safe tags
      #    Raw table markup remains untouched by this step.
      html = unescape_table_related_tags(unescaped)

      # 1b) Convert domain-specific custom tags to safe <span> wrappers
      html = transform_domain_specific_tags(html)

      # 1c) Highlight metadata tags like <DVR ...> (and encoded forms) into styled spans
      html = highlight_metadata_tags(html)

      # 2) Proactively strip both literal and encoded <script> blocks
      html = html.gsub(%r{<script\b[^>]*>.*?</script>}im, '')
      html = html.gsub(%r{&lt;script\b[^&]*?&gt;.*?&lt;/script&gt;}im, '')

      # 2b) Escape raw single-letter tags that are Belgian legislative references, not HTML
      # e.g. <B 11-10-1916, art. 1> or <I 23-11-1998, art. 2> — these contain dates
      html = html.gsub(%r{<([biu])\s+(\d{2,4}[-/])([^>]*)>}i) do
        m = ::Regexp.last_match
        "&lt
#{m[1]} #{m[2]}#{m[3]}&gt
"
      end

      # 3) Sanitize while preserving allowed table structure and attributes
      ActionController::Base.helpers.sanitize(html, tags: allowed_table_tags, attributes: allowed_table_attributes)
    else
      # Fully escape for non-regular types
      ActionController::Base.helpers.sanitize(escape_angle_brackets(unescaped))
    end
  rescue ArgumentError => e
    # Loofah limits (tree depth, attributes per element) on very large legal documents
    Rails.logger.warn("safe_db_content: Loofah limit hit: #{e.message}")
    ERB::Util.html_escape(content.to_s).html_safe
  end

  # Same as safe_db_content but skips domain tag and metadata tag transformation.
  # Used when reference marker regexes need clean text without <span> wrappers.
  def safe_db_content_without_domain_tags(content, content_type = :regular_article)
    return ''.html_safe if content.blank?

    unescaped = CGI.unescapeHTML(content.to_s)
    # Preserve Justel paragraph markers (\n followed by 2+ spaces) as double newlines
    unescaped = unescaped.gsub(/\n  +/, "\n\n")
    unescaped = unescaped.tr("\u00A0\u202F", ' ').gsub(/  +/, ' ')

    return unescaped.html_safe unless sanitization_enabled?

    if content_type == :regular_article
      html = unescape_table_related_tags(unescaped)

      # Skip domain tag and metadata tag transformation — those run later

      html = html.gsub(%r{<script\b[^>]*>.*?</script>}im, '')
      html = html.gsub(%r{&lt;script\b[^&]*?&gt;.*?&lt;/script&gt;}im, '')

      html = html.gsub(%r{<([biu])\s+(\d{2,4}[-/])([^>]*)>}i) do
        m = ::Regexp.last_match
        "&lt;#{m[1]} #{m[2]}#{m[3]}&gt;"
      end

      ActionController::Base.helpers.sanitize(html, tags: allowed_table_tags, attributes: allowed_table_attributes)
    else
      ActionController::Base.helpers.sanitize(escape_angle_brackets(unescaped))
    end
  rescue ArgumentError => e
    # Loofah limits (tree depth, attributes per element) on very large legal documents
    Rails.logger.warn("safe_db_content_without_domain_tags: Loofah limit hit: #{e.message}")
    ERB::Util.html_escape(content.to_s).html_safe
  end

  # Escapes angle brackets to keep HTML literal
  def escape_angle_brackets(str)
    str.to_s.gsub(/[<>]/, '<' => '&lt;', '>' => '&gt;')
  end

  # Replaces escaped table-related tags/attributes with literal forms to preserve structure
  def unescape_table_related_tags(str)
    out = str.to_s.dup
    # Split tags into multi-char (safe to unescape with any attrs) and single-char
    # Single-char tags like b/i/u conflict with Belgian legislative references:
    #   <b 2019-05-13, art. 2> is a reference, NOT a bold tag
    # Only unescape single-char tags when they have no content or valid HTML attributes
    multi_char_tags = allowed_table_tags.select { |t| t.length > 1 }
    single_char_tags = allowed_table_tags.select { |t| t.length == 1 }

    # Multi-char tags: unescape freely (table, thead, span, strong, etc.)
    if multi_char_tags.any?
      multi_pattern = %r{&lt;(/?(?:#{multi_char_tags.join('|')})\b[^&]*?)&gt;}i
      out.gsub!(multi_pattern) { "<#{::Regexp.last_match(1)}>" }
    end

    # Single-char tags (b, i, u): only unescape closing tags or opening tags
    # with no attributes or valid HTML attributes (class=, style=, id=)
    if single_char_tags.any?
      single_pattern = %r{&lt;(/?(?:#{single_char_tags.join('|')})(?:\s+(?:class|style|id|data-\w+)\s*=[^&]*)?)&gt;}i
      out.gsub!(single_pattern) { "<#{::Regexp.last_match(1)}>" }
    end

    out
  end

  # Converts custom domain-specific tags (e.g., <opgeheven>, <ingevoegd>, <w>, <l>, etc.)
  # into safe <span> wrappers with semantic classes, preserving inner text.
  # This runs before sanitization so the resulting spans are preserved.
  # @param str [String]
  # @return [String]
  def transform_domain_specific_tags(str)
    text = str.to_s
    return text if text.blank?

    # If content already has domain-tag spans (pre-transformed from a previous
    # scrape/import), strip them first to avoid nested/double-wrapped spans.
    # This unwraps e.g. <span class="domain-tag domain-w">&lt;W ...&gt;</span>
    # back to the raw &lt;W ...&gt; form, then re-transforms cleanly.
    if text.include?('domain-tag')
      count = 0
      text = text.gsub(/<span\s+class="domain-tag[^"]*"[^>]*>/i) do
        count += 1
        ''
      end
      # Remove only as many </span> as domain-tag opening tags we stripped
      count.times { text = text.sub('</span>', '') }
    end

    text = replace_literal_domain_tags(text)
    replace_encoded_domain_tags(text)
  end

  def replace_literal_domain_tags(text)
    names = domain_tag_names
    # Match opening tags with or without content: <KB>, <KB 2007-04-25/32, ...>
    # Also match closing tags: </KB>
    literal_pattern = %r{<(/?)\s*(#{names.join('|')})(?:\s+[^>]*)?>}i
    text.gsub(literal_pattern) do |match|
      is_closing = ::Regexp.last_match(1) == '/'
      tag = ::Regexp.last_match(2).downcase

      if is_closing
        '&gt;</span>'
      else
        # Extract the content inside the tag (everything between tag name and >)
        content = match[/#{tag}\s+([^>]+)/i, 1]
        if content
          # For tags with content (e.g., <KB 2007-04-25/32>), render with angle brackets preserved
          %(<span class="domain-tag domain-#{tag}">&lt;#{tag.upcase} #{CGI.escapeHTML(content)}&gt;</span>)
        else
          # For empty tags like <KB>, open the span with opening bracket (closing </KB> will add closing bracket)
          %(<span class="domain-tag domain-#{tag}">&lt;)
        end
      end
    end
  end

  def replace_encoded_domain_tags(text)
    names = domain_tag_names
    # Match encoded opening tags with or without content: &lt;KB&gt;, &lt;KB 2007-04-25/32...&gt;
    # Also match closing tags: &lt;/KB&gt;
    close_enc = %r{&lt;/\s*(#{names.join('|')})\s*&gt;}i
    open_enc = /&lt;\s*(#{names.join('|')})(?:\s+[^&]*?)?&gt;/i

    text.gsub!(close_enc, '&gt;</span>')
    text.gsub!(open_enc) do |match|
      tag = Regexp.last_match(1).downcase
      # Extract content inside tag (everything between tag name and &gt;)
      content = match[/#{tag}\s+([^&]+)/i, 1]
      if content
        # For tags with content, render with angle brackets preserved
        %(<span class="domain-tag domain-#{tag}">&lt;#{tag.upcase} #{content}&gt;</span>)
      else
        # For empty tags like &lt;KB&gt;, open the span with opening bracket
        %(<span class="domain-tag domain-#{tag}">&lt;)
      end
    end
    text
  end

  def domain_tag_names
    # NOTE: 'opgeheven' is handled separately by highlight_abolished_markers in references_helper.rb
    # to strip the angle brackets and show clean text
    %w[ingevoegd w l ord opnieuw kb hersteld dvr ar nota]
  end

  # Highlights metadata tags like <DVR ...> and <Ingevoegd bij DVR ...>
  # Converts both literal and encoded forms into a wrapped span that preserves
  # the visible angle brackets, ensuring safe rendering and consistent styling.
  #
  # Only used for regular articles (called inside safe_db_content regular branch).
  #
  # @param input [String]
  # @return [String]
  def highlight_metadata_tags(input)
    s = input.to_s
    return s if s.blank?

    # Patterns to highlight (case-insensitive):
    #   <DVR ...>
    #   <Ingevoegd bij DVR ...>
    # and their encoded forms &lt;...&gt;
    literal_regex = /<(?:DVR|Ingevoegd\s+bij\s+DVR)[^>]*>/i
    encoded_regex = /&lt;(?:DVR|Ingevoegd\s+bij\s+DVR)[^&]*?&gt;/i

    # Wrap literal forms by escaping angle brackets so they're shown as text
    s = s.gsub(literal_regex) do |m|
      content = CGI.escapeHTML(m)
      %(<span class="#{metadata_tag_classes}">#{content}</span>)
    end

    # Wrap already-encoded forms as-is
    s.gsub(encoded_regex) do |m|
      %(<span class="#{metadata_tag_classes}">#{m}</span>)
    end
  end

  # Mapping of escaped fragments we want to restore for table HTML
  def table_unescape_map
    # Build once and memoize. Restores only whitelisted table-related tags.
    @table_unescape_map ||= begin
      mapping = {}
      allowed_table_tags.each do |tag|
        mapping["&lt;#{tag}"] = "<#{tag}"
        mapping["&lt;/#{tag}"] = "</#{tag}"
      end
      mapping
    end
  end

  # Allowed table tags to preserve in regular article content
  def allowed_table_tags
    %w[table thead tbody tfoot tr th td caption colgroup col p br ul ol li strong em b i u sup sub small span]
  end

  # Allowed attributes for preserved table tags
  def allowed_table_attributes
    %w[
      class style border cellpadding cellspacing width height align valign
      rowspan colspan bgcolor background id name summary scope headers
      rules frame
    ]
  end

  # Abolished article/section rendering lives in `ReferencesHelper`.

  # Generates hierarchical permalinks that include full context path
  # This prevents conflicts when articles with the same number in different sections
  # @param toc_content [String] The full TOC content
  # @param _articles [Array<Article>, nil] Optional array of article objects (currently unused)
  # @return [Hash] Hash mapping article text to hierarchical permalink
  # @note Handles different heading levels and formats them into a consistent permalink structure
  def generate_hierarchical_permalinks(toc_content, _articles = nil)
    permalinks = {}
    current_hierarchy = []

    toc_content.to_s.split("\n").each do |line|
      process_toc_line(line, current_hierarchy, permalinks)
    end

    permalinks
  end

  def process_toc_line(line, current_hierarchy, permalinks)
    cleaned_line = line.strip
    return if cleaned_line.blank?

    level = line[/^\s*/].size / 2
    update_hierarchy!(current_hierarchy, level, cleaned_line)

    return unless article_line?(cleaned_line)

    article_id = article_id_from_toc_line(cleaned_line)
    return unless article_id

    permalinks[cleaned_line] = build_hierarchical_permalink(current_hierarchy, article_id)
  end

  def update_hierarchy!(hierarchy, level, cleaned_line)
    hierarchy.slice!(level..-1) if level < hierarchy.size
    hierarchy[level] = cleaned_line
  end

  def article_line?(line)
    line.match?(/(?:Art\.|Article|Artikel)\s*(?:\d+|[A-Za-z]+)/i)
  end

  def build_hierarchical_permalink(current_hierarchy, article_id)
    (current_hierarchy[0...-1] + [article_id]).join('-')
  end

  # Extracts publication date from introd content
  # @param introd_content [String] The introduction content
  # @return [String, nil] Extracted publication date or nil if not found
  def extract_publication_date(introd_content)
    return nil unless introd_content.present?

    # Look for patterns like "Publicatie: 28 juli 2025" or "Publication: 28 juillet 2025"
    match = introd_content.match(/(?:Publicatie|Publication):\s*(.+?)(?:\n|$)/i)
    match&.[](1)&.strip
  end

  # Extracts effective date from introd content
  # Handles various HTML and text formats for the effective date field
  # @param introd_content [String] The introduction content
  # @return [String, nil] Extracted effective date or nil if not found
  def extract_effective_date(introd_content)
    return nil if introd_content.blank?

    effective_date_patterns.each do |pattern|
      date = try_extract_date(introd_content, pattern)
      return date if date
    end
    nil
  end

  def effective_date_patterns
    [
      # Priority 1: Structured HTML metadata format (most reliable)
      # Matches: <p><strong>Inwerkingtreding :</strong> 23 februari 2017 </p>
      %r{<p><strong>(?:Inwerkingtreding|Entrée\s+en\s+vigueur)\s*:?</strong>\s*([^<]+)}i,
      # Priority 2: Plain text patterns (fallback)
      /(?:Inwerkingtreding|Entrée\s+en\s+vigueur)\s*:\s*(\d{1,2}[\s-]\w+[\s-]\d{4})/i,
      %r{(?:Inwerkingtreding|Entrée\s+en\s+vigueur)\s*:\s*(\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4})}i,
      /(?:ingangsdatum|date\s+de\s+début)[^\d]*(\d{1,2}[\s-]\w+[\s-]\d{4})/i,
      %r{(?:ingangsdatum|date\s+de\s+début)[^\d]*(\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4})}i,
      /(?:vanaf|à\s+partir\s+du)[^\d]*(\d{1,2}[\s-]\w+[\s-]\d{4})/i,
      %r{(?:vanaf|à\s+partir\s+du)[^\d]*(\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4})}i
    ]
  end

  def try_extract_date(content, pattern)
    match = content.match(pattern)
    return nil unless match && match[1].present?

    date = match[1].gsub(/[\r\n]/, ' ').gsub(/\s+/, ' ').strip
    date if date.present? && date != ':'
  end

  # Looks up document numbers and returns their metadata
  # @param text [String, ActiveSupport::SafeBuffer] The text containing document numbers to look up
  # @return [Hash] A hash mapping document numbers to their metadata (numac and language_id)
  # @note Looks up document numbers in the format YYYY-MM-DD/NN and includes the language_id from the referenced law
  # @example
  #   lookup_document_references("See 2023-01-15/42 for details")
  #   #=> { "2023-01-15/42" => { numac: "12345", language_id: 2 } }

  # Converts document numbers in text to clickable links while preserving HTML structure
  # @param text [String, ActiveSupport::SafeBuffer] The text containing document numbers to link
  # @return [ActiveSupport::SafeBuffer] Text with document numbers converted to links
  # @note Uses lookup_document_references to get document metadata
  # @note Handles both plain text and HTML content safely, preserving existing HTML structure
  # @example
  #   apply_document_links("See 2023-01-15/42 for details")
  #   #=> "See <a href='/laws/12345?language_id=2'>2023-01-15/42</a> for details"

  # Highlights metadata tags like <DVR ...> and <Ingevoegd bij DVR ...> with a distinct color
  # This runs before document-number linking so both effects apply.
  # Handles both literal angle brackets and their escaped forms (&lt;...&gt;).
  # @param text [String, ActiveSupport::SafeBuffer]
  # @return [ActiveSupport::SafeBuffer]

  # Returns a consistently styled article number span
  # @param number [String] The article number to display (e.g., "1", "2bis", "A.1")
  # @param options [Hash] Additional HTML options to merge
  # @return [ActiveSupport::SafeBuffer] HTML span with consistent article number styling
  # @example
  #   article_number_tag("1") #=> <span class="article-number ...">1</span>
  def article_number_tag(number, options = {})
    default_classes = 'article-number not-prose cursor-pointer'
    opts = options.dup
    extra_classes = opts.delete(:class)
    classes = [default_classes, extra_classes].compact.join(' ')

    content_tag(:span, number.to_s, **opts, class: classes, title: I18n.t(:copy_options, default: 'Kopieeropties'))
  end

  # Popular law batch lookup and path generation → PopularLawsHelper

  # Sanitize raw User-Agent into a friendly device label for user-facing pages.
  # Never expose raw UA strings to end users (infosec: prevents version fingerprinting).
  # @param ua [String] Raw User-Agent header
  # @return [String] e.g. "Chrome · Windows", "Safari · iPhone", "Firefox · Linux"
  def friendly_device_label(user_agent)
    return '—' if user_agent.blank?

    s = user_agent.to_s

    browser = if s.include?('Edg/')                                then 'Edge'
              elsif s.include?('OPR/')                             then 'Opera'
              elsif s.include?('Chrome/') && s.include?('Safari/') then 'Chrome'
              elsif s.include?('Firefox/')                         then 'Firefox'
              elsif s.include?('Safari/')                          then 'Safari'
              elsif s.include?('Trident/')                         then 'IE'
              else 'Browser'
              end

    os = if s.include?('iPhone') then 'iPhone'
         elsif s.include?('iPad')      then 'iPad'
         elsif s.include?('Android')   then 'Android'
         elsif s.include?('Windows')   then 'Windows'
         elsif s.include?('Macintosh') then 'Mac'
         elsif s.include?('Linux')     then 'Linux'
         elsif s.include?('CrOS')      then 'ChromeOS'
         else nil
         end

    os ? "#{browser} · #{os}" : browser
  end
end
