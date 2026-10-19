# frozen_string_literal: true

# Helpers for law views
module LawsHelper
  # Past this many entries the main table of contents starts collapsed in a
  # bounded native disclosure (the sidebar also keeps it searchable), and
  # past this many rows implementing decisions or updates start collapsed.
  LARGE_TOC_ENTRIES = 300
  LARGE_LIST_ROWS = 50

  # WW-WER-01: the table of contents as its logical entries (LawTocEntries),
  # computed once per request for both renderings, the main card and the
  # sidebar.
  def law_toc_entries(content)
    @law_toc_entries ||= {}
    @law_toc_entries[[content.legislation_numac, content.language_id, content.toc.to_s.hash]] ||=
      LawTocEntries.call(content.toc)
  end

  def large_law_toc?(content)
    law_toc_entries(content).size > LARGE_TOC_ENTRIES
  end

  def large_law_list?(count)
    count > LARGE_LIST_ROWS
  end

  # WW-UI-02: every article anchor in the body is unique. Two article rows
  # can derive one permalink (an annex "Art. VII. N3." read as VII., a
  # repealed row filed under a sibling's number): the first keeps it, so
  # links to it still land, and a later one takes the first numeric suffix
  # that no real article uses. reserved holds every article permalink of the
  # page, emitted the anchors already written.
  def unique_article_permalink(permalink, reserved, emitted)
    return permalink if emitted.add?(permalink)

    suffix = 2
    suffix += 1 while reserved.include?("#{permalink}-#{suffix}") || emitted.include?("#{permalink}-#{suffix}")
    "#{permalink}-#{suffix}".tap { |unique| emitted.add(unique) }
  end

  # A variant article's anchor suffix. Contents lines carry no variant, so the
  # base id stays reachable as an alias.
  ARTICLE_VARIANT_SUFFIX = /-(toekomstig|futur|vlaams_gewest|waals_gewest|brussels_hoofdstedelijk_gewest|region_wallonne|region_flamande|region_bruxelles_capitale)$/
  HEADING_TYPES = %i[section_heading abolished_section].freeze

  # The VAT Code, the W.Reg. and the W.Succ. (ledger item 29): the July 2026
  # fisconet ingest titled an article whose number has a superscript with the
  # two run together, "Art.1222" for Art. 122² (fisconet's 122/2), so links
  # went to #art-1222. Retitled "Art.122/2" (#art-122-2) on 2026-10-15, such a
  # row answers to its old anchor too. Only these codes: elsewhere "Art.3/1"
  # read as #art-31 would be another article's anchor.
  FUSED_TITLE_CODES = %w[1969070305 1939113002 1936033102].freeze

  def fused_title_anchor(article, reserved)
    return unless FUSED_TITLE_CODES.include?(article.content_numac.to_s)

    match = article.article_title.to_s.match(%r{\AArt\.\s?(\d+)/(\d+)\z})
    anchor = "art-#{match[1]}#{match[2]}" if match
    anchor unless anchor.nil? || reserved.include?(anchor)
  end

  # An article row's anchor before it is made unique: the article number of
  # its title or text, or a slug of them.
  def article_permalink_for(article)
    text = article.article_text.to_s.chomp.strip
    title = article.article_title.to_s.chomp.strip
    is_lnk = article.article_type == 'LNK'
    article_id_from_toc_line(title) || (!is_lnk && article_id_from_toc_line(text)) ||
      generate_short_permalink(is_lnk ? title : text, prefer_article_id: !is_lnk)
  end

  # Inbox 2026-10-08 10:49, B.1: the anchors of a law's rows, in document
  # order and exactly as the modern article frame writes them, so a #art- or
  # #section- link lands on both pages. A heading row gives { heading: true,
  # id: } (nil for an empty heading), an article row { heading: false, id:,
  # aliases: } with its section- alias and, for a variant, the base id.
  def law_body_anchors(articles)
    with_fresh_section_heading_counts do
      types = articles.map { |a| determine_article_type(a.article_title, a.article_text, a.article_type) }
      permalinks = articles.map { |article| article_permalink_for(article) }
      reserved = permalinks.each_with_index.filter_map { |link, i| link unless HEADING_TYPES.include?(types[i]) }.to_set
      emitted = Set.new
      articles.each_with_index.map do |article, index|
        if HEADING_TYPES.include?(types[index])
          source = section_heading_anchor_source(article.article_text, types[index]) if article.article_text.present?
          { heading: true, id: source && unique_section_heading_id(source), aliases: [] }
        else
          permalink = unique_article_permalink(permalinks[index], reserved, emitted)
          base = permalink.sub(ARTICLE_VARIANT_SUFFIX, '')
          aliases = ["section-#{permalink}"]
          aliases << base if base != permalink && !reserved.include?(base) && emitted.add?(base)
          fused = fused_title_anchor(article, reserved)
          aliases << fused if fused && emitted.add?(fused)
          { heading: false, id: permalink, aliases: aliases }
        end
      end
    end
  end

  # Inbox 2026-10-08 10:49, B.1: the Classic contents, one entry per logical
  # line (LawTocEntries), each pointed at the element of the law text it
  # names, as the modern page's toc-targets controller points them. A nil
  # target means the text has no such element: the entry stays plain text.
  def classic_toc(content, body_ids)
    entries = law_toc_entries(content)
    wanted = with_fresh_section_heading_counts do
      entries.map { |line| article_id_from_toc_line(line) || unique_section_heading_id(line) }
    end
    targets = LawTocTargets.plan(wanted, body_ids)
    entries.each_with_index.map { |line, index| { text: line, target: targets[index], level: section_heading_level(line) } }
  end

  # unique_section_heading_id numbers repeated headings per rendering; each
  # list that computes them starts from zero and leaves the page's own count
  # alone.
  def with_fresh_section_heading_counts
    saved = @_section_heading_counts
    @_section_heading_counts = Hash.new(0)
    yield
  ensure
    @_section_heading_counts = saved
  end

  FISCONET_STYLE_ATTR = /\sstyle="([^"]*)"/i
  # The language of the legal text shown, for its lang attribute: nl, fr or
  # de by language_id, nil when unknown (tag.attributes then omits it). It is
  # not the page language, which the host decides: the Dutch site shows
  # French texts too.
  def legal_text_lang(language_id = @language_id)
    Legislation.language_key_for(language_id.to_i)&.to_s
  end

  # The stored HTML entity-encodes the colon (font-style&#58;italic).
  FISCONET_ITALIC = /font-style\s*(?::|&#58;)\s*italic/i

  # Reduce Fisconet's inline styles to the one that carries meaning.
  #
  # Fisconet HTML puts a style attribute on nearly every span: font-family
  # 'titillium web', 10pt, text-align justify, margins - its own typography,
  # which this site overrides anyway. Only font-style:italic is content: it
  # marks the amendment annotations ("van toepassing vanaf ..., gewijzigd
  # door ..."). Keep that as a class and drop the rest BEFORE sanitizing.
  #
  # This is not cosmetic. With `style` in the sanitizer's allowlist every one
  # of those attributes went through Loofah's CSS scrubber: 91,077 of them on
  # the registration-duties code, 25 of its 29 seconds of cold render. Without
  # `style` the same page sanitizes in under four. One regex pass here costs
  # milliseconds. (No source tag carries both class and style, so the class
  # is never clobbered; measured on the live corpus.)
  def fisconet_reduce_inline_styles(html)
    return html if html.blank?

    html.gsub(FISCONET_STYLE_ATTR) { Regexp.last_match(1).match?(FISCONET_ITALIC) ? ' class="italic"' : '' }
  end

  # The VAT Code, the W.Reg. and the W.Succ. have no article text from Justel:
  # their Justel pages were empty shells, and every article row they show was
  # filled from Fisconet by the 2026-07-13 ingest
  # (lib/wetwijzer_updater/fisconet_ingest_to_laws.py; ledger item 23).
  FISCONET_TEXT_NUMACS = %w[1969070305 1939113002 1936033102].freeze

  # The sentence that says so on their pages, in the page language; nil for
  # every other law.
  def fisconet_text_source_note(numac)
    return unless FISCONET_TEXT_NUMACS.include?(numac.to_s)

    case I18n.locale
    when :fr then 'Le texte des articles de cette page provient de Fisconet (SPF Finances), et non de la version consolidée de Justel.'
    when :de then 'Der Artikeltext auf dieser Seite stammt aus Fisconet (FÖD Finanzen), nicht aus der konsolidierten Fassung von Justel.'
    when :en then 'The article text on this page comes from Fisconet (FPS Finance), not from the Justel consolidation.'
    else 'De artikeltekst op deze pagina komt uit Fisconet (FOD Financiën), niet uit de geconsolideerde versie van Justel.'
    end
  end

  # Their rows keep the text in force (scripts/ops/tax_codes_text_refresh.py,
  # ledger item 29); the amendment history and the older versions stay on
  # the Fisconet version, which this sentence links: [lead, link text].
  def fisconet_history_pointer
    case I18n.locale
    when :fr then ["L'historique des modifications et les versions antérieures figurent dans la", 'version Fisconet']
    when :de then ['Die Änderungshistorie und die früheren Fassungen stehen in der', 'Fisconet-Fassung']
    when :en then ['The amendment history and the earlier versions are in the', 'Fisconet version']
    else ['De wijzigingsgeschiedenis en de vroegere versies staan in de', 'Fisconet-versie']
    end
  end

  # Renders a single jurisdiction badge with tooltip
  # @param court [Hash] Court info from BelgianCourtService
  # @param locale [Symbol] The locale
  # @return [ActiveSupport::SafeBuffer] HTML for the badge
  def jurisdiction_badge(court, _locale = I18n.locale)
    level_colors = {
      1 => 'bg-purple-100 dark:bg-purple-900/50 text-purple-800 dark:text-purple-200 border-purple-200 dark:border-purple-700',
      2 => 'bg-blue-100 dark:bg-blue-900/50 text-blue-800 dark:text-blue-200 border-blue-200 dark:border-blue-700',
      3 => 'bg-green-100 dark:bg-green-900/50 text-green-800 dark:text-green-200 border-green-200 dark:border-green-700',
      4 => 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 border-gray-200 dark:border-gray-600'
    }

    color = level_colors[court[:level]] || level_colors[3]

    content_tag(:span, class: "inline-flex items-center gap-1 px-2 py-1 text-xs font-medium rounded border #{color}",
                       title: court[:description]) do
      safe_join([
                  content_tag(:span, "L#{court[:level]}", class: 'font-bold'),
                  content_tag(:span, court[:name])
                ])
    end
  end
end
