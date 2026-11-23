# frozen_string_literal: true

require 'nokogiri'

# The comparison of an article's wording with the wording before it, inside the wording's normal presentation (the
# owner, via Sol 2026-11-23 04:31:08Z). Both wordings are printed as the law page prints them (print_article), and
# their statutory words are compared: not the article's number, not Justel's reference marks ("[1 ", "]1") and not
# the amendments list below the text. The result is the newer wording's own HTML, with its colours and typography,
# in which
#   - a word both wordings have stands once, as printed;
#   - a word only the newer wording has is wrapped in <ins> (it keeps the colour of the amendment that inserted it);
#   - the words only the older wording had stand struck through, in <del>, where they stood: before the word that
#     followed them, so a replacement reads old then new, and on a line of their own when they were a paragraph.
# Line breaks are not compared, so a wording that only wraps elsewhere shows no change.
module HistoryInlineComparison
  SKIPPED = '.article-number, .ref-marker, .references-section, .sr-only'
  WORD = /[^[:space:]  ]+/
  ADDED_CLASS = 'history-added'
  REMOVED_CLASS = 'history-removed'
  # Elements a word never runs across: one block's last word and the next block's first are two words.
  BLOCK = %w[address article aside blockquote dd div dl dt figure footer h1 h2 h3 h4 h5 h6 header hr li main nav ol p pre
             section table tbody td tfoot th thead tr ul].freeze
  # A statutory word of a printed wording: its pieces (each a text node and the place of the word's part in it); for a
  # newer wording, whether it was added and the removed runs that stood before it.
  Word = Struct.new(:text, :pieces, :added, :before)
  # The words of a removed run with the older wording's line breaks: before it, after each word, and after it.
  Run = Struct.new(:words, :breaks, :break_before, :break_after, keyword_init: true)

  module_function

  # [html, counts]: the newer wording's HTML with the comparison in it, and { same:, added:, removed: } in words.
  def compare(old_html, new_html, removed_label: nil, added_label: nil)
    old_stream = stream(Nokogiri::HTML5.fragment(old_html.to_s))
    fragment = Nokogiri::HTML5.fragment(new_html.to_s)
    new_stream = stream(fragment)
    counts, trailing = align(old_stream, new_stream)
    if counts[:added].positive? || counts[:removed].positive?
      rewrite(fragment, new_stream, removed_label, added_label)
      append_trailing(fragment, trailing, removed_label)
      unlink_removed(fragment)
    end
    [fragment.to_html, counts]
  end

  # A struck word never stands inside a link of the newer wording (Sol 2026-11-23 10:08:33Z: the old "art. 10" struck
  # inside the new link to art. 11 clicked through to art. 11). Each element between the struck words and the link is
  # split around them, so they stand unlinked where they stood and the newer words keep their link.
  def unlink_removed(fragment)
    fragment.css("del.#{REMOVED_CLASS}").each do |mark|
      split_out(mark) while mark.ancestors('a').any?
    end
  end

  # Moves mark out of its parent: what stood before it stays in the parent, what stood after it goes to a copy of the
  # parent after mark; an element left empty goes.
  def split_out(mark)
    parent = mark.parent
    after = parent.document.create_element(parent.name)
    parent.attribute_nodes.each { |attribute| after[attribute.name] = attribute.value }
    while (sibling = mark.next_sibling)
      after.add_child(sibling)
    end
    parent.add_next_sibling(mark)
    mark.add_next_sibling(after) unless after.children.empty?
    parent.remove if parent.children.empty?
  end

  # The statutory words of a printed wording in reading order, with :break for each line break between them. A word
  # runs on across inline markup (Sol 2026-11-23 11:08:38Z: "arbeidsrecht" against "<em>arbeids</em>recht" is one
  # word, not one removed and two added). White space, a line break, a block and a skipped element (a reference mark,
  # the article's number) end a word. A rule (<hr>) holds no text, so no word has it among its ancestors: it counts as
  # a line break (Sol 2026-11-23 14:42:44Z).
  def stream(fragment)
    skipped = fragment.css(SKIPPED).to_a
    open = nil
    fragment.xpath('.//text() | .//br | .//hr').each_with_object([]) do |node, out|
      if skipped.any? { |element| node.ancestors.include?(element) }
        open = nil
        next
      end
      if node.element?
        open = nil
        next out << :break
      end

      text = node.content
      open = nil if open && !inline_neighbours?(open.pieces.last.first, node)
      text.scan(WORD) do
        match = Regexp.last_match
        if open && match.begin(0).zero?
          open.text += match[0]
          open.pieces << [node, 0, match.end(0)]
        else
          out << Word.new(match[0], [[node, match.begin(0), match.end(0)]], false, [])
        end
        open = nil
      end
      last = out.last
      open = last.is_a?(Word) && last.pieces.last.first.equal?(node) && last.pieces.last.last == text.length ? last : nil
    end
  end

  # Whether no block starts or ends between two text nodes
  def inline_neighbours?(before, after)
    left = before.ancestors.to_a
    right = after.ancestors.to_a
    shared = left.map(&:pointer_id) & right.map(&:pointer_id)
    (left + right).none? { |element| BLOCK.include?(element.name) && !shared.include?(element.pointer_id) }
  end

  # Marks each newer word as added or not and hangs every removed run before the newer word it stood before.
  # [counts, the runs after the last newer word].
  def align(old_stream, new_stream)
    old_words = old_stream.grep(Word)
    new_words = new_stream.grep(Word)
    places = {}.compare_by_identity
    old_stream.each_with_index { |item, index| places[item] = index }
    counts = { same: 0, added: 0, removed: 0 }
    pending = []
    trailing = []
    flush = lambda do |word|
      unless pending.empty?
        (word ? word.before : trailing) << removed_run(pending, old_stream, places)
        pending = []
      end
    end
    old_texts = old_words.map { |word| comparable(word.text) }
    new_texts = new_words.map { |word| comparable(word.text) }
    operations = diff(old_texts, new_texts)
    operations = slide(operations, :removed, 1, old_texts, line_starts(old_stream))
    operations = slide(operations, :added, 2, new_texts, line_starts(new_stream))
    operations.each do |kind, old_index, new_index|
      counts[kind] += 1
      next pending << old_words[old_index] if kind == :removed

      word = new_words[new_index]
      word.added = kind == :added
      flush.call(word)
    end
    flush.call(nil)
    [counts, trailing]
  end

  def comparable(text) = text.unicode_normalize(:nfc)

  # Per word of a stream, whether it is the first word of its line.
  def line_starts(stream)
    starts = []
    after_break = true
    stream.each do |item|
      next after_break = true if item == :break

      starts << after_break
      after_break = false
    end
    starts
  end

  # A run of removed (or added) words between common words can often stand some words earlier with the same result:
  # "Het [geschrapte lid. Het] laatste lid." is "[Het geschrapte lid.] Het laatste lid.". Each such run is moved to
  # the earliest place where it starts a line, or failing that a sentence; a run next to a run of the other kind (a
  # replacement) stays. column: the index of the run's own wording in an operation (1 older, 2 newer).
  def slide(operations, kind, column, texts, starts)
    operations = operations.map(&:dup)
    first = 0
    while first < operations.size
      next first += 1 unless operations[first][0] == kind

      last = first
      last += 1 while last + 1 < operations.size && operations[last + 1][0] == kind
      neighbours = [first.positive? ? operations[first - 1][0] : :same, last + 1 < operations.size ? operations[last + 1][0] : :same]
      shift = neighbours == %i[same same] ? best_shift(operations, first, last, column, texts, starts) : 0
      if shift.positive?
        length = last - first + 1
        start = operations[first][column] - shift
        # The common words the run passes now pair with the run's last words, which are the same words
        passed = operations[(first - shift)...first].map { |operation| operation.dup.tap { |copy| copy[column] += length } }
        run = Array.new(length) { |offset| [kind, nil, nil].tap { |operation| operation[column] = start + offset } }
        operations[(first - shift)..last] = run + passed
      end
      first = last + 1
    end
    operations
  end

  # How many words earlier the run starts best: at a line (2), after the end of a sentence (1), or where it is (0).
  def best_shift(operations, first, last, column, texts, starts)
    start = operations[first][column]
    finish = operations[last][column]
    best = 0
    best_score = start_score(start, texts, starts)
    shift = 0
    while first - shift - 1 >= 0 && operations[first - shift - 1][0] == :same &&
          texts[start - shift - 1] == texts[finish - shift]
      shift += 1
      score = start_score(start - shift, texts, starts)
      next unless score > best_score

      best = shift
      best_score = score
    end
    best
  end

  def start_score(index, texts, starts)
    return 2 if starts[index]

    index.positive? && texts[index - 1].match?(/[.;:]\z/) ? 1 : 0
  end

  def removed_run(words, old_stream, places)
    first = places.fetch(words.first)
    last = places.fetch(words.last)
    Run.new(words: words.map(&:text), breaks: words.map { |word| old_stream[places.fetch(word) + 1] == :break },
            break_before: first.positive? && old_stream[first - 1] == :break, break_after: old_stream[last + 1] == :break)
  end

  # [[:same, i, j], [:removed, i, nil], [:added, nil, j]]: a longest common subsequence, the common start and end
  # taken first; in a changed stretch the removed words come before the added ones.
  def diff(old, new)
    head = 0
    head += 1 while head < old.size && head < new.size && old[head] == new[head]
    tail = 0
    tail += 1 while tail < old.size - head && tail < new.size - head && old[-1 - tail] == new[-1 - tail]
    a = old[head...(old.size - tail)]
    b = new[head...(new.size - tail)]
    lengths = Array.new(a.size + 1) { Array.new(b.size + 1, 0) }
    (a.size - 1).downto(0) do |i|
      (b.size - 1).downto(0) do |j|
        lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : [lengths[i + 1][j], lengths[i][j + 1]].max
      end
    end
    middle = []
    i = j = 0
    while i < a.size || j < b.size
      if i < a.size && j < b.size && a[i] == b[j]
        middle << [:same, head + i, head + j]
        i += 1
        j += 1
      elsif i < a.size && (j == b.size || lengths[i + 1][j] >= lengths[i][j + 1])
        middle << [:removed, head + i, nil]
        i += 1
      else
        middle << [:added, nil, head + j]
        j += 1
      end
    end
    start = (0...head).map { |index| [:same, index, index] }
    finish = (0...tail).map { |index| [:same, old.size - tail + index, new.size - tail + index] }
    start + removed_first(middle) + finish
  end

  def removed_first(operations)
    operations.chunk_while { |x, y| (x[0] == :same) == (y[0] == :same) }.flat_map do |stretch|
      next stretch if stretch.first[0] == :same

      stretch.select { |operation| operation[0] == :removed } + stretch.select { |operation| operation[0] == :added }
    end
  end

  # Each text node of the newer wording is rebuilt from the pieces of its words: the added ones in <ins>, each removed
  # run in <del> before the word it stood before. The piece of an added word that runs on into another text node gets
  # an <ins> of its own there, without a second label for screen readers.
  def rewrite(fragment, new_stream, removed_label, added_label)
    document = fragment.document
    starts_line = {}.compare_by_identity
    new_stream.each_with_index { |item, index| starts_line[item] = index.zero? || new_stream[index - 1] == :break }
    by_node = {}.compare_by_identity
    new_stream.grep(Word).each do |word|
      word.pieces.each_with_index { |(node, from, to), index| (by_node[node] ||= []) << [word, from, to, index.zero?] }
    end
    by_node.each do |node, pieces|
      text = node.content
      parts = []
      cursor = 0
      open = nil
      pieces.each do |word, from, to, first|
        gap = text[cursor...from]
        before = first ? word.before : []
        if open && word.added && before.empty?
          open.add_child(document.create_text_node(gap))
        else
          open = nil
          parts << document.create_text_node(gap) unless gap.empty?
          before.each { |run| parts.concat(removed_nodes(document, run, removed_label, at_line_start: starts_line[word])) }
        end
        if word.added
          open ||= added_node(document, first ? added_label : nil).tap { |element| parts << element }
          open.add_child(document.create_text_node(text[from...to]))
        else
          open = nil
          parts << document.create_text_node(text[from...to])
        end
        cursor = to
      end
      rest = text[cursor..].to_s
      parts << document.create_text_node(rest) unless rest.empty?
      node.replace(Nokogiri::XML::NodeSet.new(document, parts))
    end
  end

  def added_node(document, label)
    element = document.create_element('ins', class: ADDED_CLASS)
    element.add_child(screen_reader_label(document, label)) if label
    element
  end

  def screen_reader_label(document, label) = document.create_element('span', "[#{label}] ", class: 'sr-only')

  def line_break(document) = [document.create_element('br'), document.create_element('span', class: 'paragraph-indent')]

  def removed_element(document, run, label)
    element = document.create_element('del', class: REMOVED_CLASS)
    element.add_child(screen_reader_label(document, label)) if label
    run.words.each_with_index do |word, index|
      if index.positive?
        separators = run.breaks[index - 1] ? line_break(document) : [document.create_text_node(' ')]
        separators.each { |separator| element.add_child(separator) }
      end
      element.add_child(document.create_text_node(word))
    end
    element
  end

  # The struck words before a newer word: on a line of their own when they were one in the older wording.
  def removed_nodes(document, run, label, at_line_start:)
    nodes = []
    nodes.concat(line_break(document)) if run.break_before && !at_line_start
    nodes << removed_element(document, run, label)
    nodes.concat(run.break_after ? line_break(document) : [document.create_text_node(' ')])
  end

  # Removed words after the last newer word: where the text ends, before the amendments list.
  def append_trailing(fragment, runs, label)
    return if runs.empty?

    document = fragment.document
    list = fragment.at_css('.references-section')
    root = fragment.at_css('div') || fragment
    runs.each do |run|
      nodes = run.break_before ? line_break(document) : [document.create_text_node(' ')]
      nodes << removed_element(document, run, label)
      set = Nokogiri::XML::NodeSet.new(document, nodes)
      list ? list.add_previous_sibling(set) : root.add_child(set)
    end
  end
end
