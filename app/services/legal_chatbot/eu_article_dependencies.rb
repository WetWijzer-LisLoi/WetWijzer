# frozen_string_literal: true

module LegalChatbot
  # Literal dependency selection for a named EU unit whose ordinary excerpt
  # loses the conditions of its own scope (Codex 2026-10-18 07:10-07:19). A
  # question about one restriction of DSA Article 17(1), such as a closed
  # account, needs that restriction with its lead, the paragraph 2 conditions
  # and exclusion, the paragraph 3 lead with the contractual reason (e) and
  # the redress (f), and paragraph 5's exclusion. This only chooses which
  # literal units of the verified source text are shown and in which order;
  # it adds, translates and relabels nothing. Any other unit, an unexpected
  # structure, an unmatched question or a budget the required set does not
  # fit returns nil, and the caller uses the ordinary excerpt.
  module EuArticleDependencies
    ELISION = ArticleExcerpt::ELISION
    PARAGRAPH = /\A(?:\((\d{1,2})\)[[:space:]]|(\d{1,2})\.\z)/
    ITEM = /\A([a-z])\)[[:space:]]/
    SPECS = {
      # Regulation (EU) 2022/2065, consolidated or original, any language.
      [/\A[03]2022R2065(?:-\d{8})?\z/, '17'] => {
        paragraphs: 5,
        scope: 1,
        required: [[1, :lead], [1, :matched_items], [2, :first], [2, :last], [3, :lead], [3, 'e'], [3, 'f'], [5, :all]],
        optional: [[3, 'b'], [4, :all], [2, :all], [1, :items], [3, :items]]
      }
    }.freeze

    module_function

    def excerpt(record, text, question, max_chars:)
      spec = spec_for(record)
      return nil unless spec && max_chars.to_i.positive?

      units = ArticleExcerpt.split_units(text.to_s).flat_map { |unit| unit.split(ArticleExcerpt::SINGLE_LINE_BOUNDARY) }
                            .map(&:strip).reject(&:empty?)
      structure = parse(units)
      return nil unless structure && structure.keys == (1..spec[:paragraphs]).to_a

      terms = ArticleExcerpt.question_terms(question)
      # The question's own restriction: the best-scoring item(s) of the scope
      # list, not every sibling that shares a generic word.
      scores = structure[spec[:scope]][:items].values.to_h { |index| [index, ArticleExcerpt.score(units[index], terms)] }
      best = scores.values.max.to_i
      return nil unless best.positive?

      matched = scores.select { |_index, score| score == best }.keys

      selected = spec[:required].flat_map { |paragraph, part| indexes(structure[paragraph], part, matched) }.uniq
      return nil if selected.empty? || rendered_length(units, selected) > max_chars

      # A whole optional paragraph is added at once or not at all, so no
      # paragraph number is shown without its text; list items one by one.
      spec[:optional].each do |paragraph, part|
        groups = indexes(structure[paragraph], part, matched)
        groups = part == :all ? [groups] : groups.map { |index| [index] }
        groups.each do |group|
          candidate = (selected + group).uniq
          next if candidate.size == selected.size

          selected = candidate if rendered_length(units, candidate) <= max_chars
        end
      end
      render(units, selected.sort)
    end

    def spec_for(record)
      celex = field(record, :celex).to_s
      number = (field(record, :unit_number) || field(record, :article_number)).to_s
      kind = field(record, :kind)
      return nil if kind.present? && kind.to_s != 'article'

      SPECS.find { |(pattern, unit), _spec| celex.match?(pattern) && number == unit }&.last
    end

    # { paragraph => { lead: [indexes], items: { 'a' => index }, all: [indexes] } }
    # for a body whose paragraphs are numbered in order and whose items follow
    # their lead. A bare "2." unit belongs to the paragraph it numbers.
    def parse(units)
      structure = {}
      current = nil
      units.each_with_index do |unit, index|
        marker = unit.match(PARAGRAPH)
        if marker
          number = (marker[1] || marker[2]).to_i
          return nil unless number == structure.size + 1

          current = structure[number] = { lead: [], items: {}, all: [], bare: [] }
          current[:bare] << index if marker[2]
        end
        return nil unless current

        item = unit.match(ITEM)
        if item && !marker
          current[:items][item[1]] = index
        elsif current[:items].empty?
          current[:lead] << index
        end
        current[:all] << index
      end
      structure
    end

    def indexes(paragraph, part, matched)
      return [] unless paragraph

      case part
      when :lead then paragraph[:lead]
      when :matched_items then paragraph[:items].values & matched
      when :items then paragraph[:items].values
      when :all then paragraph[:all]
      when :first, :last
        # A sentence of an unlisted paragraph, always with its own number
        # ("2." stands alone in the French text): never a naked marker.
        return [] unless paragraph[:items].empty?

        markers = paragraph[:all].take_while { |index| paragraph[:bare].include?(index) }
        content = paragraph[:all] - markers
        markers + Array(part == :first ? content.first : content.last)
      else Array(paragraph[:items][part])
      end
    end

    def rendered_length(units, indexes)
      render(units, indexes.sort).length
    end

    # Adjacent units keep their line break; an omission is always marked,
    # including after the last unit when the article continues.
    def render(units, indexes)
      out = +''
      previous = nil
      indexes.each do |index|
        out << separator(previous, index)
        out << units[index]
        previous = index
      end
      out << ELISION if previous && previous < units.size - 1
      out
    end

    def separator(previous, index)
      return '' if previous.nil?

      index == previous + 1 ? "\n" : ELISION
    end

    def field(record, key)
      return nil unless record.respond_to?(:[])

      record[key].nil? ? record[key.to_s] : record[key]
    end
  end
end
