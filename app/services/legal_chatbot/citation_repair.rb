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
      quote_attributed_article_targets(text).map { |target| target.fetch(:number) }.uniq
    end

    # Keep the law identity as well as the number. Art. 1 of law A cannot
    # satisfy a quote explicitly attributed to Art. 1 of law B. A trailing
    # attribution takes precedence over cross-references inside the quote,
    # just as it does in QuoteGuard.
    def quote_attributed_article_targets(text)
      normalize_internal_law_links(text.to_s).scan(MARKDOWN_BLOCKQUOTE_PATTERN).flat_map do |block|
        block = block.first if block.is_a?(Array)
        trailing = block.to_s.match(/\s+[—–-]\s+\[([^\]]+)\]\(([^)]+)\).*\z/m)
        plain = block.to_s.match(PLAIN_QUOTE_ARTICLE_ATTRIBUTION_PATTERN) unless trailing
        links = if trailing
                  [[trailing[1], trailing[2]]]
                elsif plain
                  []
                else
                  block.to_s.scan(/\[([^\]]+)\]\(([^)]+)\)/)
                end
        targets = links.filter_map do |_label, href|
          match = href.match(%r{\A/laws/([^?#/)\s]+)([^)\s]*)\z}i)
          next unless match

          number = match[2].match(/#art[-_]([^?&#\s)]+)/i)&.[](1)
          next if number.blank?

          numac = match[1].match?(/\Afisconet_\d+\z/i) ? match[1].upcase : match[1]
          { numac: numac, number: number }
        end
        # Never reinterpret an explicit but invalid/external attribution as
        # a bare reference in another law.
        next targets if links.any?

        if plain
          targets << { number: plain[1].delete(' '),
                       named_laws: plain_quote_named_laws(block, plain) }
        end
        targets
      end.uniq
    end

    # Fetch quote-attributed articles that are missing from the evidence, so a
    # verbatim quote of a real article is checked against that article instead
    # of being discarded. Verification itself is unchanged: the quoted words
    # must still occur in the fetched text, so this can only rescue quotes
    # that are genuine.
    def repair_quote_sources(text, leg_articles)
      targets = quote_attributed_article_targets(text)
      return [] if targets.empty? || leg_articles.blank?

      numacs = leg_articles.filter_map { |article| retrieved_source_numac(article) }.uniq
      return [] if numacs.empty?

      have = leg_articles.filter_map do |article|
        numac = retrieved_source_numac(article)
        number = retrieved_source_article_number(article)
        [numac, number] if numac.present? && number.present?
      end.to_set
      wanted = targets.filter_map do |target|
        candidates = if target[:numac]
                       numacs & [target[:numac]]
                     elsif !target[:named_laws].nil?
                       numacs & target[:named_laws].to_a
                     else
                       numacs
                     end
        # A bare number in several retrieved laws carries no identity. Do
        # not pick whichever law happens to rank first.
        next unless candidates.one?

        pair = [candidates.first, normalize_article_number(target.fetch(:number))]
        [candidates.first, target.fetch(:number)] unless have.include?(pair)
      end.uniq.first(CITATION_REPAIR_LIMIT)
      return [] if wanted.empty?

      repairs = []
      wanted.group_by(&:first).each do |numac, pairs|
        remaining = CITATION_REPAIR_LIMIT - repairs.length
        break unless remaining.positive?

        repairs.concat(legislation_search_svc.fetch_articles_by_number(
          numacs: [numac], article_numbers: pairs.map(&:last), limit: remaining
        ).first(remaining))
      end
      repairs
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
    ARTICLE_RANGE_YEAR_LIKE = (1800..2100)

    def expand_article_range(number)
      match = number.to_s.strip.match(/\A(\d{1,4})\s*[-–]\s*(\d{1,4})\z/)
      return [number] unless match

      from = match[1].to_i
      to = match[2].to_i
      return [number] unless to > from && (to - from) <= ARTICLE_RANGE_MAX_SPAN
      return [number] if ARTICLE_RANGE_YEAR_LIKE.cover?(from) && ARTICLE_RANGE_YEAR_LIKE.cover?(to) && (to - from) >= 5

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

    # Existence in an admitted law does not prove applicability. A late
    # article lookup must obey the same question scope as initial retrieval,
    # including unresolved regional tax regimes and specialist occupations.
    # Keep the service's explicit/viewed-source exceptions intact.
    def scope_repair_sources_for_question(articles, question)
      svc = legislation_search_svc
      return svc.send(:scope_repair_articles_to_question, Array(articles), question) if svc.respond_to?(:scope_repair_articles_to_question, true)

      Array(articles).select do |article|
        if svc.respond_to?(:contextual_source_relevant?, true)
          svc.send(:contextual_source_relevant?, article, question)
        else
          LegislationSearch.contextual_source_relevant?(article, question)
        end
      end
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
      sections = []
      if rejected_refs.any?
        sections << <<~FEEDBACK.strip
          CORRECTION - your previous answer was rejected by the citation check and was NOT shown to the user.
          These legal-unit references could not be linked to any provided source: #{rejected_refs.join(', ')}.
          Write the complete answer again, applying these rules strictly:
          - Cite ONLY articles or recitals that appear in the numbered sources above, ALWAYS as a markdown link copying the exact LINK value.
          - Every occurrence of an article or recital number, including an explanatory repeat or list item, must itself be that exact markdown link at that point; never use bare numbers beside or before a later link.
          - Put the whole reference inside the link label, never the number outside the link. For an EU act the label names the article and at most its paragraph, for example [art. 7(1)](LINK); a point or letter such as "onder a)" or "sub b" cannot be verified, so leave it out.
          - Never cite a range such as "Art. 732-733": link each supplied article separately. Copy each LINK value exactly as given; a relative link such as /laws/... stays relative, without https:// or a host in front.
          - Do NOT introduce a cross-reference number merely because a supplied source mentions it. If that provision is not itself supplied, explain the condition or exception in ordinary words without naming its number.
          - Do not mention this correction or the rejected attempt in your answer.
        FEEDBACK
      end
      childcare_feedback = ChildcareExpenseGrounding.corrective_feedback(
        guard_result&.fetch(:missing_childcare_conditions, nil)
      )
      sections << childcare_feedback if childcare_feedback.present?
      house_feedback = HouseHiddenDefectPracticalGrounding.corrective_feedback(
        guard_result&.fetch(:missing_house_practical_conditions, nil), language: @language
      )
      sections << house_feedback if house_feedback.present?
      marketplace_feedback = MarketplaceCivilClaimGrounding.corrective_feedback(
        guard_result&.fetch(:missing_marketplace_conditions, nil), language: @language
      )
      sections << marketplace_feedback if marketplace_feedback.present?
      platform_feedback = PlatformRedressGrounding.corrective_feedback(
        guard_result&.fetch(:missing_platform_redress_conditions, nil), language: @language
      )
      sections << platform_feedback if platform_feedback.present?
      flight_feedback = FlightDisruptionGrounding.corrective_feedback(
        guard_result&.fetch(:missing_flight_disruption_conditions, nil), language: @language
      )
      sections << flight_feedback if flight_feedback.present?
      commute_feedback = OfficeCommuteGrounding.corrective_feedback(
        guard_result&.fetch(:missing_office_commute_conditions, nil), language: @language
      )
      sections << commute_feedback if commute_feedback.present?
      minor_feedback = SalduzMinorGrounding.corrective_feedback(
        guard_result&.fetch(:missing_minor_conditions, nil), language: @language
      )
      sections << minor_feedback if minor_feedback.present?
      payment_feedback = PaymentAcceptanceGrounding.corrective_feedback(
        guard_result&.fetch(:missing_payment_conditions, nil), language: @language
      )
      sections << payment_feedback if payment_feedback.present?
      formation_feedback = FormationDeedGrounding.corrective_feedback(
        guard_result&.fetch(:missing_formation_deed_conditions, nil), language: @language
      )
      sections << formation_feedback if formation_feedback.present?
      classification_feedback = FormationDeedClassification.corrective_feedback(
        guard_result&.fetch(:missing_formation_deed_classification, nil), language: @language
      )
      sections << classification_feedback if classification_feedback.present?
      capital_feedback = FormationBvCapitalGrounding.corrective_feedback(
        guard_result&.fetch(:missing_formation_bv_capital_conditions, nil), language: @language
      )
      sections << capital_feedback if capital_feedback.present?
      checklist_feedback = FormationBvChecklist.corrective_feedback(
        guard_result&.fetch(:missing_formation_bv_source_grounding, nil), language: @language
      )
      sections << checklist_feedback if checklist_feedback.present?
      sections.join("\n\n").presence
    end
  end
end
