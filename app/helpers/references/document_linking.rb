# frozen_string_literal: true

# Document-number linking, metadata tag processing, and highlight logic.
# Converts inline document numbers (YYYY-MM-DD/XXXX format) to clickable links
# to legislation pages. Also handles DVR/NOTA metadata tag highlighting.
#
# Extracted from ReferencesHelper to improve maintainability.
module References
  module DocumentLinking
    extend ActiveSupport::Concern
    include ActionView::Helpers::TagHelper
    include ActionView::Helpers::UrlHelper
    include ActionView::Context

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
    rescue ActiveRecord::StatementInvalid
      # Table may not exist in v089 DB — skip document number lookups
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
          'text-(--accent-600)',
          'hover:underline decoration-current hover:decoration-current',
          'dark:text-(--accent-400)'
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
  end
end
