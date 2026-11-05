# frozen_string_literal: true

# One structural heading per Fisconet provision, and its body as block-safe HTML.
#
# Owner, 2026-10-26 (via Sol 07:37:06 UTC), on the deployed WIB 92 and VAT code pages: every provision was named
# twice or three times (the generated `Art. N.` marker, then the source's own title line and its standalone
# "Artikel N" heading), the implementing-instrument rows showed their internal `doc:...` key as if it were an
# article number, the sanitized block HTML sat inside an outer <p> the browser auto-closed, and the source's
# spacer paragraphs and leading <br>s compounded the paragraph margins. Sol's v1 review (10:02:12 UTC) and its
# proactive check (10:22:20 UTC) narrowed the removal rule to exact, positively source-supported identity evidence;
# this is v2.
#
# This module decides the heading (FisconetProvision.label) and prepares the body (FisconetProvision.body_html)
# with general rules, never per collection or per document:
#   - a numbered provision keeps the established `Art. N.` label; a provision whose key is not a number (the walk
#     corpus's `doc:` slugs for implementing instruments, `pdf:` and `bijlage:` keys) is headed by its stored source
#     title, or by its bare key when no title is stored, never by `Art. <key>.`;
#   - only LEADING heading-only blocks are dropped, and only when their whole normalized text is EXACTLY one of:
#     an identity form (`Art. N`, `Artikel N`, `Article N`, and the French `1er` of the first article); an identity
#     form, a comma and EXACTLY one of the code's names (FisconetProvision.code_names: the legislation's stored
#     document type and titles, and the registry's names of the code, FisconetCodeRegistry; never a tail the article
#     titles repeat, repetition is not evidence of a name); the stored title when
#     it is such a line; for an implementing instrument its stored title (the heading shown) and the identity forms
#     of the article number that title names. Nothing is inferred from a tail (no suffix match, no "a heading
#     follows"): a bare number, a descriptive title ("Artikel 1. Belastbare handelingen"), an operative sentence
#     ("Artikel 1, eerste lid blijft gelden", even when stored as the title or followed by a bare heading), a title
#     line in a language the source stores no name for ("Article 1er, Code de la TVA"), a version line, a heading
#     that is a link or wraps one, and everything after the first content block stay, with their words, dates,
#     links and tables; only positively empty presentation nodes are skipped on the way (a spacer paragraph before
#     the duplicate heading does not hide it);
#   - presentation artifacts go in one pass: anchors without a target (a targeted link is content wherever it sits,
#     and so is every wrapper holding one), <br>s at the start or end of a block, runs of <br>s,
#     paragraphs and divs holding only whitespace, non-breaking spaces or <br>s, <br>s between or beside blocks (a <br>
#     between inline or text nodes at the top level is a line break the source meant: kept, one for a run), runs of three
#     or more non-breaking spaces; a single <br> is a line break the source meant, a single non-breaking space a word
#     separator; tables and lists are never blank.
# The sanitizer, its allowlists and the inline-style reduction that precedes it (LawsHelper#fisconet_reduce_inline_styles)
# are unchanged: the fragment is parsed and scrubbed ONCE, exactly as the view helper's `sanitize` did, then walked
# once (the leading walk touches the leading nodes only; the cleaning pass visits every node once).
module FisconetProvision
  TAGS = %w[p br em strong b i u a ul ol li table tr td th thead tbody h1 h2 h3 h4 h5 h6 div span sup sub blockquote].freeze
  ATTRIBUTES = %w[href title class border cellpadding cellspacing width height align valign rowspan colspan].freeze
  BLOCKS = %w[p div table ul ol li blockquote h1 h2 h3 h4 h5 h6 thead tbody tr td th].freeze
  INLINE = %w[span a em strong b i u sup sub].freeze
  NEVER_BLANK = %w[table thead tbody tr td th ul ol li].freeze
  TRIMMED = %w[p div li td th blockquote].freeze
  NBSP = [0x00a0].pack('U')
  ZWSP = [0x200b].pack('U')
  BLANK = /\A[[:space:]#{NBSP}#{ZWSP}]*\z/
  NBSP_RUN = /#{NBSP}{3,}/
  # the article number an implementing instrument's title names, at its end: "..., Artikel 3", "... article 25sexies"
  TITLE_NUMBER = %r{(?:art\.?|artikel|article)\s*(\d+(?:[./]\d+)*[a-z]*)\s*\z}i

  module_function

  def numbered?(number) = number.to_s.match?(/\A\d/)

  def label(number, title)
    numbered?(number) ? "Art. #{number}." : (title.to_s.strip.presence || number.to_s)
  end

  def toc_label(number, title)
    numbered?(number) ? "Art. #{number}" : (title.to_s.strip.presence || number.to_s)
  end

  # The number a row's heading and contents entry print (FisconetSearchService.with_shown_numbers). Never for an id.
  def printed_number(article) = article[:shown_number] || article[:article_number]

  # The code's names, normalized, as the positive evidence a title line's tail must EQUAL: the names given (the
  # legislation's stored document type and titles, and the registry's names of the code, FisconetCodeRegistry, as the
  # view helper passes them). Nothing is derived from the article titles themselves: a tail repeated across them is
  # not evidence of a name (the owner via Sol, 2026-10-26 12:44:51 UTC).
  def code_names(*names)
    names.flatten.map { |name| normalize(name) }.select { |name| name.length >= 2 }.uniq
  end

  # The provision's body: sanitized once with the unchanged allowlists, its leading identity headings and its spacer
  # artifacts removed, serialized without any outer element. nil when the source exceeds the parser's depth limit
  # (the caller then renders the plain text), or when there is nothing to render.
  def body_html(html, number:, title:, code_names: [])
    source = html.to_s.strip
    return nil if source.length <= 10

    fragment = Loofah.html5_fragment(source)
    fragment.scrub!(scrubber)
    strip_leading_headings!(fragment, Identity.new(number, title, code_names))
    fragment.children.to_a.each { |child| clean!(child) }
    prune_fragment_breaks!(fragment)
    fragment.to_html(encoding: 'UTF-8').strip.presence
  rescue ArgumentError
    nil
  end

  # The plain-text fallback: the same rule on the leading lines; a blank line between them is skipped.
  def strip_leading_heading_lines(lines, number:, title:, code_names: [])
    identity = Identity.new(number, title, code_names)
    lines = lines.dup
    loop do
      lines.shift while lines.any? && lines.first.match?(BLANK)
      break if lines.empty? || !identity.line?(lines.first)

      lines.shift
    end
    lines
  end

  def identity_forms(key)
    keys = key == '1' ? [key, '1er'] : [key] # the French ordinal of the first article
    keys.flat_map { |k| ["art #{k}", "art. #{k}", "artikel #{k}", "article #{k}"] }.map { |form| normalize(form) }
  end

  def normalize(text)
    text.to_s.gsub(/[#{NBSP}#{ZWSP}]/, ' ').downcase.squish.sub(/[.:;,]+\z/, '').strip
  end

  def scrubber
    Rails::HTML::PermitScrubber.new.tap do |scrubber|
      scrubber.tags = TAGS
      scrubber.attributes = ATTRIBUTES
    end
  end

  # The provision's identity, built once per row: the number's article-word forms, the code's names, and the stored
  # title when it is itself an identity line.
  class Identity
    def initialize(number, title, code_names)
      @forms = Set.new
      @title_lines = Set.new
      @code_names = Array(code_names).map { |name| FisconetProvision.normalize(name) }.select { |name| name.length >= 2 }.to_set
      key = number.to_s.strip
      stored = FisconetProvision.normalize(title)
      if FisconetProvision.numbered?(key)
        @forms.merge(FisconetProvision.identity_forms(key))
        @title_lines << stored if stored.present? && identity_with_code_name?(stored)
      elsif stored.present?
        @title_lines << stored # the title is the heading shown
        named = title.to_s.match(TITLE_NUMBER)
        @forms.merge(FisconetProvision.identity_forms(named[1])) if named
      end
    end

    # Whether a leading heading-only text is exactly this identity: an identity form, the identity plus a comma and
    # exactly one of the code's names, or the stored title when it is such a line.
    def line?(text)
      normalized = FisconetProvision.normalize(text)
      @forms.include?(normalized) || @title_lines.include?(normalized) || identity_with_code_name?(normalized)
    end

    private

    def identity_with_code_name?(normalized)
      head, tail = normalized.split(',', 2)
      head = head.to_s.strip
      return @forms.include?(head) if tail.nil?

      @forms.include?(head) && @code_names.include?(tail.strip)
    end
  end

  # The leading walk: skips positively empty presentation nodes, enters a leading wrapper, drops heading-only nodes
  # that carry the identity, and stops at the first content node.
  def strip_leading_headings!(parent, identity)
    parent.children.to_a.each do |node|
      if presentation_empty?(node)
        node.remove
        next
      end
      if node.element? && %w[div section].include?(node.name)
        strip_leading_headings!(node, identity)
        break unless node.children.all? { |child| presentation_empty?(child) }

        node.remove
        next
      end
      break unless heading_candidate?(node) && identity.line?(node.text)

      node.remove
    end
  end

  # A text node, or a paragraph, heading or inline wrapper with inline content only that is not a link and wraps none.
  def heading_candidate?(node)
    return true if node.text?
    return false unless node.element? && (node.name == 'p' || node.name.match?(/\Ah[1-6]\z/) || INLINE.include?(node.name))
    return false if linked?(node)

    node.xpath('.//*').none? { |element| BLOCKS.include?(element.name) }
  end

  def linked?(node)
    return true if node.name == 'a' && node['href'].present?

    node.xpath('.//a').any? { |anchor| anchor['href'].present? }
  end

  # Positively empty presentation: blank text, a <br>, or an element whose whole subtree is such, never a table,
  # a list or a link.
  def presentation_empty?(node)
    return node.text.match?(BLANK) if node.text?
    return true unless node.element?
    return true if br?(node)
    return false if NEVER_BLANK.include?(node.name) || linked?(node)

    node.children.all? { |child| presentation_empty?(child) }
  end

  # One pass, children before parents: collapses runs of non-breaking spaces, drops empty anchors and blank
  # paragraphs and divs, trims the breaks of each block. Returns whether the node is blank presentation.
  def clean!(node)
    if node.text?
      content = node.content
      node.content = content.gsub(NBSP_RUN, ' ') if content.include?(NBSP * 3)
      return node.content.match?(BLANK)
    end
    return true unless node.element?
    return true if br?(node)

    blank = true
    node.children.to_a.each { |child| blank = clean!(child) && blank }
    return false if node.name == 'a' && node['href'].present? # a targeted link is content, and so are its wrappers

    if node.name == 'a' && node['href'].blank? && blank
      node.remove
      return true
    end
    return false if NEVER_BLANK.include?(node.name)

    trim_breaks!(node) if TRIMMED.include?(node.name)
    if blank && %w[p div].include?(node.name)
      node.remove
      return true
    end
    blank && (INLINE.include?(node.name) || %w[p div blockquote].include?(node.name) || node.name.match?(/\Ah[1-6]\z/))
  end

  # A fragment-level <br> is the source's own line break when it separates inline or text content: kept, one for a
  # run. Between blocks, before or after a block, or at the fragment's edge it is a spacer: removed (Sol 15:14:44 UTC).
  # One pass over the children (Sol 16:57:33 UTC): the last content node and the breaks seen since it decide each run
  # when the next content node arrives; blank text in between is neither.
  def prune_fragment_breaks!(fragment)
    last_content = nil
    pending = []
    fragment.children.to_a.each do |node|
      next if blank_text?(node)

      if br?(node)
        pending << node
        next
      end
      keep = last_content && inline_content?(last_content) && inline_content?(node) ? pending.first : nil
      pending.each { |br| br.remove unless br.equal?(keep) }
      pending = []
      last_content = node
    end
    pending.each(&:remove)
  end

  def inline_content?(node) = node.text? || (node.element? && INLINE.include?(node.name))

  def trim_breaks!(block)
    while (first = block.children.first) && (blank_text?(first) || br?(first))
      first.remove
    end
    while (last = block.children.last) && (blank_text?(last) || br?(last))
      last.remove
    end
    previous_break = false
    block.children.to_a.each do |child|
      if br?(child)
        child.remove if previous_break
        previous_break = true
      elsif !blank_text?(child)
        previous_break = false
      end
    end
  end

  def blank_text?(node) = node.text? && node.text.match?(BLANK)
  def br?(node) = node.element? && node.name == 'br'
end
