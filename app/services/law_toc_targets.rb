# frozen_string_literal: true

# WW-UI-02 for Classic (inbox 2026-10-08 10:49, work package B.1): the server
# side of app/javascript/utils/toc_targets.js. Classic runs no JavaScript, so
# the contents links the modern page repairs in the browser are resolved
# before the page is sent. The stored table of contents and the article rows
# differ in text (a repeal note only in the body, a heading split over two
# contents lines, slash-numbered articles held as headings), and in each case
# the intended element sits between the targets of the neighbouring links
# that do resolve, its id extending the link's. Same semantics as the
# JavaScript, checked by the same cases (test/services/law_toc_targets_test.rb
# mirrors test/javascript/toc_targets_test.mjs).
module LawTocTargets
  module_function

  # toc_ids: the links' target ids in order; body_ids: every id of the law
  # text in document order. Returns, per link, the id it should point at: its
  # own when that exists, a matched one, or nil when the body has none. A
  # matched target serves one link only and never lies outside the window
  # between the resolving neighbours.
  def plan(toc_ids, body_ids)
    position = {}
    body_ids.each_with_index { |id, index| position[id] = index unless position.key?(id) }
    resolves = toc_ids.map { |id| position.key?(id) }
    plan = toc_ids.each_with_index.map { |id, index| resolves[index] ? id : :unplanned }
    claimed = plan.grep(String).to_set

    toc_ids.each_index do |index|
      next unless plan[index] == :unplanned

      before = (index - 1).downto(0).find { |earlier| plan[earlier].is_a?(String) }
      from = before ? position[plan[before]] : -1
      after = ((index + 1)...toc_ids.size).find { |later| resolves[later] }
      to = after ? position[toc_ids[after]] : body_ids.size

      plan[index] = ((from + 1)...to).lazy.map { |at| body_ids[at] }
                                     .find { |id| !claimed.include?(id) && extends_target?(id, toc_ids[index]) }
      claimed << plan[index] if plan[index]
    end
    plan
  end

  def extends_target?(id, wanted)
    extends_stem?(id, wanted) || (wanted.start_with?('art-') && extends_stem?(id, "section-#{wanted}"))
  end

  def extends_stem?(id, stem) = id == stem || id.start_with?("#{stem}-")
end
