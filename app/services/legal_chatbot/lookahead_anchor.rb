# frozen_string_literal: true

module LegalChatbot
  # A branch of nothing but `(?=.*...)` asks only whether its words occur somewhere in the text. Unanchored, the engine
  # asks again from every position, and for a word that is absent it reads to the end each time. On a question of 1,475
  # characters the patterns of LegislationSearch::ARTICLE_PINS took 3.8 s together that way, and one of them ran into
  # Rails's limit of one second per match on a busy machine, which cost the question all its pins (ledger item 45).
  #
  # On text without newlines such a branch holds at some position exactly when it holds at the start, so `\A` before it
  # changes no answer, only the work. This holds for boolean matching of whitespace-normalised text, and nothing else:
  # the caller owes both. Whatever this cannot read with certainty stays as it was written.
  module LookaheadAnchor
    # Each of these can make the truth of a lookahead depend on where the match began, or hide a parenthesis or a `|`
    # from the scan: a backreference, \G, a comment group, and a `#` where extended mode may read it as a comment.
    POSITION_DEPENDENT = /\\[1-9]|\\k[<']|\\g[<']|\\G|\(\?#/
    EXTENDED_ON = /\(\?[a-wyz]*x/

    module_function

    # The pattern with `\A` before each branch that is safe to anchor, or the same object when none is.
    def anchored(pattern)
      source = pattern.source
      extended = pattern.options.anybits?(Regexp::EXTENDED)
      return pattern if source.match?(POSITION_DEPENDENT)
      return pattern if source.include?('#') && (extended || source.match?(EXTENDED_ON))

      branches = branches_of(source)
      return pattern unless branches

      eligible = branches.map { |branch| lookaheads_only?(branch, extended) }
      return pattern unless eligible.any?

      Regexp.new(branches.zip(eligible).map { |branch, safe| safe ? "\\A#{branch}" : branch }.join('|'), pattern.options)
    end

    # The source split at its top-level `|`, or nil if the scan does not come out even.
    def branches_of(source)
      branches = []
      start = 0
      unbalanced = false
      scan(source) do |char, index, depth|
        unbalanced = true if depth.negative?
        next unless char == '|' && depth.zero?

        branches << source[start...index]
        start = index + 1
      end
      return nil if unbalanced || !balanced?(source)

      branches << source[start..]
    end

    # Only `(?=.*...)` groups at the top, with no `|` directly inside one: in `(?=.*a|b)` the `b` has no `.*` before it
    # and must stand at the very position tried. In extended mode whitespace between the groups means nothing; anywhere
    # else it is a character that has to match, so it makes the branch ineligible.
    def lookaheads_only?(branch, extended)
      top = extended ? branch.gsub(/\s+(?=\(\?=|\z)/, '').sub(/\A\s+/, '') : branch
      return false unless top.start_with?('(?=.*')

      group_start = nil
      fine = true
      scan(top) do |char, index, depth|
        case char
        when '('
          group_start = index if depth == 1
          fine &&= top[index, 5] == '(?=.*' if depth == 1
        when ')'
          group_start = nil if depth.zero?
        when '|'
          fine = false if depth == 1
        else
          fine = false if depth.zero?
        end
      end
      fine && group_start.nil? && balanced?(top)
    end

    # Yields each character outside escapes and character classes, with the depth after it: an opening parenthesis
    # reports its new depth, a closing one the depth it returns to. An escape or a class at the top is reported as the
    # character `\\` or `[`, because it consumes text there.
    def scan(source)
      depth = 0
      index = 0
      while index < source.length
        char = source[index]
        case char
        when '\\'
          yield char, index, depth
          index += 2
          next
        when '['
          yield char, index, depth
          index = end_of_class(source, index) + 1
          next
        when '('
          depth += 1
        when ')'
          depth -= 1
        end
        yield char, index, depth
        index += 1
      end
    end

    def balanced?(source)
      depth = 0
      lowest = 0
      scan(source) do |_char, _index, reported|
        depth = reported
        lowest = reported if reported < lowest
      end
      depth.zero? && lowest.zero?
    end

    def end_of_class(source, open)
      depth = 0
      index = open
      while index < source.length
        case source[index]
        when '\\' then index += 1
        when '[' then depth += 1
        when ']'
          depth -= 1
          return index if depth.zero?
        end
        index += 1
      end
      source.length
    end
  end
end
