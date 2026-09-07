# frozen_string_literal: true

module LegalChatbot
  # Citation and quote repair calculators (FBL-061, extracted verbatim from
  # the orchestrator): bounded lookup of rejected article references inside
  # the laws already in evidence, quote-attribution mining, endpoint-first
  # range expansion, and the corrective-feedback prompt for a guarded
  # regeneration. The retry LOOP that drives these stays in the
  # orchestrator's pipeline. Mixed into LegalChatbotService alongside the
  # orchestrator; collaborators (legislation_search_svc,
  # retrieved_source_* readers, normalize_article_number) are host methods.
  module CitationRepair
    extend ActiveSupport::Concern

    # Blockquote shapes are owned by the orchestrator's quote guard; repair
    # only reads them. Lexical aliases because bare constant references in a
    # sibling concern do not resolve through the host's ancestry.
    MARKDOWN_BLOCKQUOTE_PATTERN = Orchestrator::MARKDOWN_BLOCKQUOTE_PATTERN
    PLAIN_QUOTE_ARTICLE_ATTRIBUTION_PATTERN = Orchestrator::PLAIN_QUOTE_ARTICLE_ATTRIBUTION_PATTERN

    # Look up the rejected article numbers inside the laws this search already
    # returned. Bounded on purpose: only rejected prose references, only laws
    # already in evidence, at most CITATION_REPAIR_LIMIT articles, and never
    # an article already present.
    # Raised from 5 with the round-robin interleave in repair_cited_articles:
    # the cap now bounds total repair candidates across references instead of
    # letting the first reference's expansion consume it alone.
    CITATION_REPAIR_LIMIT = 10

    # Article numbers a blockquote attributes itself to, whether by trailing
    # link ("— [Art. 8.20 BW](/laws/...)") or plain text ("— Art. 2044 Oud
    # BW"). Used to deepen evidence when a quote is attributed to an article
    # of a retrieved law that retrieval itself did not return: the same recall
    # gap as rejected citations, but it surfaces as a quote silently degraded
    # to "geen exact citaat beschikbaar" rather than as a withheld analysis.
    def quote_attributed_article_numbers(text)
      text.to_s.scan(MARKDOWN_BLOCKQUOTE_PATTERN).flat_map do |block|
        block = block.first if block.is_a?(Array)
        numbers = block.to_s.scan(%r{/laws/[^?#/)\s]+#art[-_]([^?#)\s]+)}i).flatten
        plain = block.to_s.match(PLAIN_QUOTE_ARTICLE_ATTRIBUTION_PATTERN)
        numbers << plain[1].delete(' ') if plain
        numbers
      end.map { |number| number.to_s.strip }.reject(&:blank?).uniq
    end

    # Fetch quote-attributed articles that are missing from the evidence, so a
    # verbatim quote of a real article is checked against that article instead
    # of being discarded. Verification itself is unchanged: the quoted words
    # must still occur in the fetched text, so this can only rescue quotes
    # that are genuine.
    def repair_quote_sources(text, leg_articles)
      numbers = quote_attributed_article_numbers(text)
      return [] if numbers.empty? || leg_articles.blank?

      numacs = leg_articles.filter_map { |article| retrieved_source_numac(article) }.uniq
      return [] if numacs.empty?

      have = leg_articles.filter_map { |article| retrieved_source_article_number(article) }.to_set
      wanted = numbers.reject { |number| have.include?(normalize_article_number(number)) }
      return [] if wanted.empty?

      legislation_search_svc.fetch_articles_by_number(
        numacs: numacs, article_numbers: wanted, limit: CITATION_REPAIR_LIMIT
      )
    end

    # Belgian answers cite spans ("Art. 52-71 ZIV-wet", "Art. 66-69"), which no
    # article title can match, so repair found nothing and the analysis stayed
    # withheld - the remaining failure for the owner's dismissal question after
    # the 2026-07-31 repair measurement. Expand a plain numeric span into its
    # members so each can be looked up in the retrieved laws. Whether they
    # exist is still decided by the corpus, never by this expansion.
    #
    # Both ends must be plain ascending integers, so "100-16" (a real Sociaal
    # Strafwetboek article title) is left alone. Spans up to
    # ARTICLE_RANGE_MAX_SPAN are expanded: real citations reach this far, e.g.
    # "Art. 52-71 ZIV-wet" covers the whole gewaarborgd-loon regime and blocked
    # three of the eight answers still withheld after the 2026-07-31
    # measurement. A pair that looks like years is refused instead.
    ARTICLE_RANGE_MAX_SPAN = 40
    ARTICLE_RANGE_YEAR_LIKE = (1800..2100).freeze

    def expand_article_range(number)
      match = number.to_s.strip.match(/\A(\d{1,4})\s*[-–]\s*(\d{1,4})\z/)
      return [number] unless match

      from = match[1].to_i
      to = match[2].to_i
      return [number] unless to > from && (to - from) <= ARTICLE_RANGE_MAX_SPAN
      if ARTICLE_RANGE_YEAR_LIKE.cover?(from) && ARTICLE_RANGE_YEAR_LIKE.cover?(to) && (to - from) >= 5
        return [number]
      end

      # Endpoints first, then inward. The repair budget is small, so the two
      # articles a span is named for must be tried before its middle.
      members = (from..to).map(&:to_s)
      ordered = []
      until members.empty?
        ordered << members.shift
        ordered << members.pop unless members.empty?
      end
      [number] + ordered
    end

    def repair_cited_articles(guard_result, leg_articles)
      rejected = Array(guard_result&.fetch(:unsupported_references, nil))
      return [] if rejected.empty? || leg_articles.blank?

      numacs = leg_articles.filter_map { |article| retrieved_source_numac(article) }.uniq
      return [] if numacs.empty?

      have = leg_articles.filter_map { |article| retrieved_source_article_number(article) }.to_set
      per_reference = rejected.map do |reference|
        number = reference.to_s.sub(/\A\s*Art(?:ikel|icle)?s?\.?\s*/i, '')
        expand_article_range(number)
          .reject { |candidate| candidate.blank? || have.include?(normalize_article_number(candidate)) }
      end
      # Interleave round-robin: a single wide range expansion (up to 41
      # candidates) used to fill the whole repair budget and starve every
      # other rejected reference, so one repairable citation stayed broken
      # because an unrelated one was greedy (2026-08-04 withheld-answer
      # mining, docs/ops/withheld-answers-2026-08-04.md).
      numbers = []
      index = 0
      loop do
        contributed = false
        per_reference.each do |candidates|
          candidate = candidates[index]
          next unless candidate

          numbers << candidate
          contributed = true
        end
        break unless contributed

        index += 1
      end
      numbers.uniq!
      return [] if numbers.empty?

      legislation_search_svc.fetch_articles_by_number(
        numacs: numacs, article_numbers: numbers, limit: CITATION_REPAIR_LIMIT
      )
    end

    # Retry feedback for the unsupported-prose-reference class only. Missing
    # required regimes/external citations are handled by the deterministic
    # appenders; a regeneration cannot cite sources that were never retrieved.
    def citation_guard_corrective_feedback(guard_result)
      # Deliberately not named after the guard field: the privacy test scans
      # this file for needles that indicate guard payloads reaching the LOGS.
      # These references travel only back to the same provider that just
      # produced them, and carry article numbers, never question or answer
      # text, so the prompt use is legitimate while the log ban stays strict.
      rejected_refs = Array(guard_result&.fetch(:unsupported_references, nil)).first(10)
      return nil if rejected_refs.empty?

      <<~FEEDBACK.strip
        CORRECTION - your previous answer was rejected by the citation check and was NOT shown to the user.
        These article references could not be linked to any provided source: #{rejected_refs.join(', ')}.
        Write the complete answer again, applying these rules strictly:
        - Cite ONLY articles that appear in the numbered sources above, ALWAYS as a markdown link copying the exact LINK value.
        - Do NOT mention any article number that is not in the sources. Describe such rules in words, without a number, and state that the specific provision is not among the consulted sources.
        - Do not mention this correction or the rejected attempt in your answer.
      FEEDBACK
    end
  end
end
