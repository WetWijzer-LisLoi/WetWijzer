# frozen_string_literal: true

module LegalChatbot
  # The deterministic answer guards (FBL-061, extracted verbatim from the
  # orchestrator): output sanitization, QuoteGuard (every Markdown
  # blockquote must occur verbatim in a source supplied to the same answer,
  # with attribution binding and bounded verbatim reconstruction) and
  # CitationGuard (every surviving prose article reference must be a
  # verified link; fail closed on the whole analysis). The guards write
  # @last_quote_guard_result / @last_citation_guard_result on the host
  # service; the pipeline reads AND rolls these back after a failed retry,
  # so the ivar contract must not be redesigned in a move (see
  # docs/ops/orchestrator-map-2026-08-18.md).
  module AnswerGuards
    extend ActiveSupport::Concern

    # The shared article/citation pattern library stays with the
    # orchestrator; lexical aliases because sibling-concern constants do not
    # resolve via the host's ancestry.
    MARKDOWN_BLOCKQUOTE_PATTERN = Orchestrator::MARKDOWN_BLOCKQUOTE_PATTERN
    MARKDOWN_LINK_PATTERN = Orchestrator::MARKDOWN_LINK_PATTERN
    PLAIN_QUOTE_ARTICLE_ATTRIBUTION_PATTERN = Orchestrator::PLAIN_QUOTE_ARTICLE_ATTRIBUTION_PATTERN
    PLAIN_QUOTE_ARTICLE_ATTRIBUTION_SUFFIX_PATTERN = Orchestrator::PLAIN_QUOTE_ARTICLE_ATTRIBUTION_SUFFIX_PATTERN
    ARTICLE_CITATION_SEQUENCE_PATTERN = Orchestrator::ARTICLE_CITATION_SEQUENCE_PATTERN
    ARTICLE_NUMBER_TOKEN_PATTERN = Orchestrator::ARTICLE_NUMBER_TOKEN_PATTERN
    SINGLE_ARTICLE_CITATION_PATTERN = Orchestrator::SINGLE_ARTICLE_CITATION_PATTERN
    DRUG_CITATION_ARTICLE_PRIORITY = Orchestrator::DRUG_CITATION_ARTICLE_PRIORITY

    # SECURITY: Strip any leaked internal markers from LLM output.
    # Catches cases where the LLM echoes XML tags, delimiter labels, or
    # system prompt fragments that should never reach the user.
    def sanitize_answer(text)
      return text if text.blank?

      text
        .gsub(%r{</?verified_legal_data>}i, '') # XML-style tags (current)
        .gsub(/===\s*(?:END\s+)?CRITICAL CORRECTIONS\s*===/i, '') # Legacy delimiters
        .gsub(%r{</?referentieblad>}i, '')                # Referentieblad tags
        .gsub(/\[REFSHEET\].*$/i, '')                     # Log-style REFSHEET labels
        .gsub(/\[ANTI-HALLUCINATION HINTS?\].*$/i, '')    # Anti-hallucination labels
        .gsub(/^[ \t]*(?:[-*]\s*)?(?:VERIFIED LEGAL DATA|GEVERIFIEERDE JURIDISCHE GEGEVENS|DONNÉES JURIDIQUES VÉRIFIÉES|VERIFIZIERTE RECHTSDATEN)\b[^\n]*\n?/i, '') # Humanized internal marker
        .gsub(/SOURCE RELIABILITY HIERARCHY.*?$/im, '')   # System prompt fragment
        .gsub(/INTERNAL DATA RULE.*?$/im, '')             # System prompt fragment
        .gsub(%r{\(LINK:\s*(/[^)]+)\)}, '(\1)')            # Strip "LINK: " prefix from URLs the LLM copied literally
        .gsub(%r{\(VALEUR_LINK:\s*(/[^)]+)\)}, '(\1)')     # Strip FR variant "VALEUR_LINK: " prefix
        .gsub(/\n+(?:#+\s*)?\*{0,2}(?:(?:RELEVANTE\s+)?BRONNEN|BASE JURIDIQUE|SOURCES PERTINENTES|LEGAL BASIS|RELEVANT SOURCES|RECHTSGRUNDLAGE|RELEVANTE QUELLEN|QUELLEN|SOURCES):?\*{0,2}\s*\n(?:(?:[-•*]|\d+[.)])\s*.*\n?)*/i, "\n") # Strip trailing source sections; UI source cards already render them
        .gsub(/\n{3,}/, "\n\n") # Collapse excessive newlines
        .strip
    end

    def validate_answer_quotes(text, sources)
      source_records = sources.filter_map do |source|
        raw = source[:article_text] || source[:text] || source[:full_text] || source[:content]
        tokens = normalized_quote_tokens(raw)
        next if tokens.empty?

        {
          tokens: tokens,
          text: raw.to_s,
          numac: retrieved_source_numac(source),
          article_number: retrieved_source_article_number(source),
          ecli: (source[:case_number] || source[:ecli] || source['case_number'] || source['ecli']).to_s.presence,
          url: (source[:url] || source['url']).to_s.presence
        }
      end
      return strip_all_blockquotes(text) if source_records.empty?

      rejected = 0
      repaired = 0
      checked = 0
      guarded = text.gsub(MARKDOWN_BLOCKQUOTE_PATTERN) do |block|
        checked += 1
        quote = extract_blockquote_text(block)
        attributed_sources = quote_attributed_sources(block, source_records)
        candidates = attributed_sources.nil? ? source_records : attributed_sources

        if quote.present? && candidates.any? && quote_supported_by_sources?(quote, candidates)
          block
        elsif quote.present? && candidates.any? &&
              (rebuilt = reconstruct_verbatim_quote(quote, candidates))
          # The model elided from real statutory text. Restore the source's own
          # wording instead of dropping the quotation: measured 2026-07-31,
          # 80% of rejected quotes cited an article that WAS in evidence, at
          # 70-90% token overlap, and telling the model to stop eliding did not
          # work (42% rejection before and after the instruction).
          repaired += 1
          block.sub(quote, rebuilt)
        else
          rejected += 1
          quote_removal_notice(block)
        end
      end
      @last_quote_guard_result = {
        verified: true,
        checked: checked,
        rejected: rejected,
        repaired: repaired,
        version: 4
      }
      Rails.logger.warn("[QuoteGuard] removed #{rejected} unsupported blockquote(s)") if rejected.positive?
      Rails.logger.info("[QuoteGuard] restored source wording in #{repaired} blockquote(s)") if repaired.positive?
      guarded
    end

    def strip_all_blockquotes(text)
      stripped = 0
      result = text.gsub(MARKDOWN_BLOCKQUOTE_PATTERN) do |block|
        stripped += 1
        quote_removal_notice(block)
      end
      @last_quote_guard_result = {
        verified: true,
        checked: stripped,
        rejected: stripped,
        version: 3
      }
      Rails.logger.warn("[QuoteGuard] removed #{stripped} blockquote(s): no source text") if stripped.positive?
      result
    end

    def quote_attributed_sources(block, source_records)
      # A model may include an article link inside the quoted statutory text
      # as well as a trailing "— [source](...)" attribution. The trailing
      # attribution is authoritative; considering every link would let an
      # inline link rescue a quote that is labelled as a different article.
      trailing = block.to_s.match(/\s+[—–-]\s+\[[^\]]+\]\(([^)]+)\).*\z/m)
      links = trailing ? [['', trailing[1]]] : block.to_s.scan(/\[([^\]]+)\]\(([^)]+)\)/)
      internal_targets = []
      jurisprudence_targets = []
      external_targets = []

      links.each do |_label, href|
        if (match = href.match(%r{(?:https?://(?:www\.)?wetwijzer\.be)?/laws/([^?#/)\s]+)([^)\s]*)}i))
          numac = match[1].match?(/\Afisconet_\d+\z/i) ? match[1].upcase : match[1]
          article_number = link_article_number(match[2])
          internal_targets << [numac, article_number]
        elsif (match = href.match(%r{(?:https?://(?:www\.)?wetwijzer\.be)?/jurisprudence/([^?#/)\s]+)}i))
          jurisprudence_targets << CGI.unescape(match[1]).upcase
        elsif href.match?(%r{\Ahttps?://}i)
          external_targets << href
        end
      end

      if internal_targets.any?
        return source_records.select do |source|
          internal_targets.include?([source[:numac], source[:article_number]])
        end
      end

      if jurisprudence_targets.any?
        return source_records.select do |source|
          jurisprudence_targets.include?(source[:ecli].to_s.upcase)
        end
      end

      if external_targets.any?
        matched = source_records.select { |source| external_targets.include?(source[:url]) }
        return matched
      end

      plain_attribution = block.to_s.match(PLAIN_QUOTE_ARTICLE_ATTRIBUTION_PATTERN)
      if plain_attribution
        article_number = normalize_article_number(plain_attribution[1].delete(' ')).presence
        return source_records.select { |source| source[:article_number] == article_number }
      end

      nil
    end

    def extract_blockquote_text(block)
      value = block.lines.map { |line| line.sub(/^[ ]{0,3}>\s?/, '') }.join(' ').strip
      value = value.sub(/\s+[—–-]\s+\[[^\]]+\]\([^)]+\).*\z/, '')
      value = value.sub(PLAIN_QUOTE_ARTICLE_ATTRIBUTION_SUFFIX_PATTERN, '')
      value.gsub!(/\A["“”'‘’]+|["“”'‘’]+\z/, '')
      value.strip
    end

    def quote_supported_by_sources?(quote, source_records)
      # A legal blockquote must be one contiguous normalized source span.
      # Treating ellipsis-delimited pieces as independently matchable allowed
      # decisive words (for example "niet" or an exception) to be removed
      # while the shortened sentence was still attested as an exact quote.
      quote_tokens = normalized_quote_tokens(quote)
      return false if quote_tokens.empty?

      source_records.any? do |source|
        tokens = source.is_a?(Hash) ? source[:tokens] : source
        token_subsequence_index(tokens, quote_tokens, 0).present?
      end
    end

    def token_subsequence_index(tokens, segment, start_at)
      last_start = tokens.length - segment.length
      return if last_start < start_at

      (start_at..last_start).find { |index| tokens[index, segment.length] == segment }
    end

    def normalized_quote_tokens(value)
      ensure_utf8(value).downcase
                        .gsub(/<[^>]+>/, ' ')
                        .gsub(/\[([^\]]+)\]\([^)]+\)/, '\\1')
                        .gsub(/\[\d+|\]\d+/, ' ')
                        .scan(/[[:alnum:]]+/)
    end

    # Same tokens, with each token's offsets in the ORIGINAL string, so a span
    # of tokens can be rendered back as the source wrote it (casing,
    # punctuation, paragraph markers intact). Only applied to statutory source
    # text, which carries no markdown, so the substitutions above are not
    # needed here and offsets stay faithful.
    def source_tokens_with_offsets(value)
      text = ensure_utf8(value)
      text.downcase.enum_for(:scan, /[[:alnum:]]+/).map do
        match = Regexp.last_match
        [match[0], match.begin(0), match.end(0)]
      end
    end

    # Reconstruct a verbatim quotation from a near-quotation. When the model's
    # quoted words appear IN ORDER in a source article but with gaps (it elided
    # or lightly condensed), return the exact source substring running from the
    # first to the last matched word. That restores whatever was dropped, which
    # is precisely the property QuoteGuard protects: a quote that omitted a
    # decisive "niet" comes back WITH the "niet", so the reader sees the real
    # provision instead of a notice.
    #
    # Returns nil unless the reconstruction is faithful and useful: the words
    # must all be present in order, the span must not balloon relative to what
    # was quoted, and the result must itself pass the contiguity check.
    QUOTE_RECONSTRUCTION_MAX_GROWTH = 2.5
    QUOTE_RECONSTRUCTION_MAX_TOKENS = 120
    # Words whose omission changes the legal meaning. If restoring them is what
    # the reconstruction would do, the quote is NOT repaired: the surrounding
    # prose was written on the distorted reading, so a quote that now says the
    # opposite would contradict the answer around it. Those cases keep the
    # notice, preserving the rejection this guard was built for.
    QUOTE_MEANING_CRITICAL_TOKENS = %w[
      niet geen nooit zonder tenzij behalve uitgezonderd noch
      ne pas aucun aucune jamais sauf moins hormis
      not no never unless except without
      nicht kein keine niemals ausser außer sofern
    ].freeze

    def reconstruct_verbatim_quote(quote, source_records)
      wanted = normalized_quote_tokens(quote)
      return nil if wanted.length < 4 || wanted.length > QUOTE_RECONSTRUCTION_MAX_TOKENS

      source_records.each do |source|
        text = source.is_a?(Hash) ? source[:text] : nil
        next if text.blank?

        indexed = source_tokens_with_offsets(text)
        next if indexed.empty?

        span = ordered_token_span(indexed.map(&:first), wanted)
        next unless span

        first_index, last_index = span
        covered = last_index - first_index + 1
        next if covered > (wanted.length * QUOTE_RECONSTRUCTION_MAX_GROWTH).ceil

        rebuilt = text[indexed[first_index][1]...indexed[last_index][2]].to_s.strip
        next if rebuilt.blank?
        next unless quote_supported_by_sources?(rebuilt, [source])
        next if meaning_critical_words_restored?(wanted, rebuilt)

        return rebuilt
      end
      nil
    end

    def meaning_critical_words_restored?(quoted_tokens, rebuilt)
      added = normalized_quote_tokens(rebuilt) - quoted_tokens
      added.any? { |token| QUOTE_MEANING_CRITICAL_TOKENS.include?(token) }
    end

    # First and last index of an in-order (gapped) occurrence of `wanted`
    # inside `tokens`, or nil. Greedy from the earliest possible start, which
    # yields the tightest span for the statutory text we deal with.
    def ordered_token_span(tokens, wanted)
      start_positions = tokens.each_index.select { |index| tokens[index] == wanted.first }
      start_positions.each do |start|
        cursor = start
        matched = 0
        while cursor < tokens.length && matched < wanted.length
          matched += 1 if tokens[cursor] == wanted[matched]
          cursor += 1
        end
        return [start, cursor - 1] if matched == wanted.length
      end
      nil
    end

    # The blockquote pattern consumes the newline that ended the quote, so
    # substituting a bare sentence glued the following line onto the notice:
    # a list item rendered as "Huurcontracten in Vlaanderen:" then the notice
    # with "- Bij niet-naleving ..." running straight on from it, in a run the
    # owner reported. Give the notice the same trailing newlines the block had
    # so the surrounding paragraph and list structure survives.
    def quote_removal_notice(block)
      trailing = block.to_s[/\n+\z/].to_s
      trailing = "\n" if trailing.empty?
      "#{missing_quote_message}#{trailing}"
    end

    def missing_quote_message
      case @language
      when 'fr' then 'Aucune citation exacte disponible dans les sources consultées.'
      when 'de' then 'In den konsultierten Quellen ist kein exaktes Zitat verfügbar.'
      when 'en' then 'No exact quotation is available in the consulted sources.'
      else 'Geen exact citaat beschikbaar in de geraadpleegde bronnen.'
      end
    end

    def citation_guard_passed?
      @last_citation_guard_result&.fetch(:passed, false) == true
    end


    # CitationGuard: after LinkGuard and auto-linkification, every supported
    # article citation should be a Markdown link copied from a retrieved source.
    # Any numeric Art./Artikel/Article reference that remains in ordinary prose
    # is therefore unsupported or ambiguous. Fail closed on the whole generated
    # analysis; degrading the citation to plain text would still present the
    # surrounding legal claim as verified.
    def validate_unlinked_article_citations(text, sources)
      required_numacs = Array(@required_regime_citations&.fetch(:required_numacs, nil))
      required_external_pairs = Array(
        @required_gdpr_processor_citations&.fetch(:required_external_pairs, nil)
      )
      forbidden_internal_numacs = Array(
        @required_gdpr_processor_citations&.fetch(:forbidden_internal_numacs, nil)
      )
      if text.blank?
        passed = required_numacs.empty? && required_external_pairs.empty?
        @last_citation_guard_result = {
          verified: true, passed: passed,
          rejected: required_numacs.length + required_external_pairs.length,
          unsupported_references: [], missing_required_regimes: required_numacs,
          missing_required_external_citations: required_external_pairs,
          misattributed_domestic_sources: [], version: 4
        }
        return passed ? text : unsupported_article_citation_message
      end

      allowed_pairs = sources.filter_map do |source|
        numac = retrieved_source_numac(source)
        article_number = retrieved_source_article_number(source)
        [numac, article_number] if numac.present? && article_number.present?
      end.to_set
      allowed_external_pairs = sources.filter_map do |source|
        url = source[:url] || source['url']
        article_number = retrieved_source_article_number(source)
        [url.to_s, article_number] if url.present? && article_number.present?
      end.to_set

      # The marker must itself look like an article token so a verified first
      # item does not hide an unlinked list tail ("Art. 2bis en 2ter"). Keep it
      # unpredictable: a fixed public marker is also a valid plain citation and
      # could otherwise be emitted verbatim to bypass the rejection filter.
      verified_sentinel = "#{SecureRandom.random_number(10**30).to_s.rjust(30, '0')}safe"

      # Preserve the visible labels of all Markdown links. Only mask the exact
      # article number of a canonical law-article link that resolves to a
      # retrieved pair. Arbitrary fragments, schemes, jurisprudence links, and
      # untrusted external URLs therefore remain visible to the scanner and
      # cannot hide a fabricated article citation. Exact regional source URLs
      # are accepted only with their retrieved article number.
      prose = text.gsub(MARKDOWN_BLOCKQUOTE_PATTERN, '')
      prose = citation_visible_text(prose, allowed_pairs, allowed_external_pairs, verified_sentinel)
              .gsub(%r{</?(?:strong|b|em|i|code)\b[^>]*>}i, '')
              .gsub(/[*_~`]+/, '')
              .gsub(/&(?:nbsp|#0*160|#x0*a0);/i, ' ')
              .gsub(/[\u00A0\u2007\u202F]/, ' ')

      unsupported = prose.to_enum(:scan, ARTICLE_CITATION_SEQUENCE_PATTERN).flat_map do
        sequence = Regexp.last_match[:numbers]
        sequence.scan(ARTICLE_NUMBER_TOKEN_PATTERN)
        # A masked citation whose label carried a paragraph suffix re-formed a
        # token of sentinel + ".4", which is not EQUAL to the sentinel and was
        # therefore reported as the unsupported reference
        # "Art. <30 digits>safe.4" (observed on q0909). Any token containing
        # the sentinel came from a citation this method itself verified, so
        # containment is the correct test. The sentinel is unpredictable per
        # call, so this cannot be exploited by generated text.
      end.reject { |number| number.include?(verified_sentinel) }
         .map { |number| "Art. #{number.gsub(/[[:space:]\u00A0\u2007\u202F]+/, '')}" }
         .uniq

      cited_pairs = verified_article_citation_pairs(text, allowed_pairs, allowed_external_pairs)
      cited_numacs = required_drug_regime_numacs(cited_pairs)
      missing_required_regimes = required_numacs - cited_numacs
      cited_external_pairs = verified_external_article_citation_pairs(text, allowed_external_pairs)
      missing_required_external = required_external_pairs - cited_external_pairs.to_a
      linked_internal_numacs = text.to_s.scan(%r{/laws/([^/?#)[:space:]]+)}i).flatten
      misattributed_domestic_sources = (cited_pairs.map(&:first) + linked_internal_numacs).select do |numac|
        forbidden_internal_numacs.include?(numac)
      end.uniq
      passed = unsupported.empty? && missing_required_regimes.empty? && missing_required_external.empty? &&
               misattributed_domestic_sources.empty?

      @last_citation_guard_result = {
        verified: true,
        passed: passed,
        rejected: unsupported.length + missing_required_regimes.length + missing_required_external.length +
                  misattributed_domestic_sources.length,
        unsupported_references: unsupported,
        missing_required_regimes: missing_required_regimes,
        missing_required_external_citations: missing_required_external,
        misattributed_domestic_sources: misattributed_domestic_sources,
        version: 4
      }
      return text if passed

      Rails.logger.warn(
        "[CitationGuard] blocked answer: unsupported_count=#{unsupported.size} " \
        "missing_regime_count=#{missing_required_regimes.size} " \
        "missing_external_count=#{missing_required_external.size} " \
        "misattributed_domestic_count=#{misattributed_domestic_sources.size}"
      )
      unsupported_article_citation_message
    end

    def required_drug_regime_numacs(cited_pairs)
      DRUG_CITATION_ARTICLE_PRIORITY.filter_map do |numac, priority_articles|
        normalized_priorities = priority_articles.map { |article| normalize_article_number(article) }
        numac if normalized_priorities.any? { |article| cited_pairs.include?([numac, article]) }
      end
    end

    def verified_article_citation_pairs(text, allowed_pairs, allowed_external_pairs = Set.new)
      text.to_s.scan(MARKDOWN_LINK_PATTERN).filter_map do |markdown|
        next if markdown.start_with?('!')

        parsed = markdown.match(/\A\[([^\]\n]+)\]\(([^)\n]+)\)\z/)
        next unless parsed

        label = parsed[1]
        href = parsed[2]
        next unless verified_article_citation_link?(label, href, allowed_pairs, allowed_external_pairs)

        target = href.match(%r{\A/laws/([^/?#]+)(?:\?language_id=[12])?#art[-_]([^?#[:space:]]+)\z}i)
        next unless target

        numac = target[1].match?(/\Afisconet_\d+\z/i) ? target[1].upcase : target[1]
        [numac, normalize_article_number(target[2])]
      end.uniq
    end

    def verified_external_article_citation_pairs(text, allowed_external_pairs)
      text.to_s.scan(MARKDOWN_LINK_PATTERN).filter_map do |markdown|
        next if markdown.start_with?('!')

        parsed = markdown.match(%r{\A\[([^\]\n]+)\]\((https?://[^)\n]+)\)\z}i)
        next unless parsed

        label_match = parsed[1].match(SINGLE_ARTICLE_CITATION_PATTERN)
        next unless label_match

        pair = [parsed[2], normalize_article_number(label_match[:number])]
        pair if allowed_external_pairs.include?(pair)
      end.to_set
    end

    def citation_visible_text(text, allowed_pairs, allowed_external_pairs, verified_sentinel)
      text.gsub(MARKDOWN_LINK_PATTERN) do |markdown|
        parsed = markdown.match(/\A!?\[([^\]\n]+)\]\(([^)\n]+)\)\z/)
        next markdown unless parsed

        label = parsed[1]
        href = parsed[2]
        # An image is not a user-visible, clickable legal citation even when
        # its alt text and target happen to resemble a retrieved article link.
        next label if markdown.start_with?('!')

        if verified_article_citation_link?(label, href, allowed_pairs, allowed_external_pairs)
          mask_verified_article_number(label, verified_sentinel)
        else
          label
        end
      end
    end

    def verified_article_citation_link?(label, href, allowed_pairs, allowed_external_pairs = Set.new)
      label_match = label.match(SINGLE_ARTICLE_CITATION_PATTERN)
      return false unless label_match

      label_number = normalize_article_number(label_match[:number])
      target = href.match(%r{\A/laws/([^/?#]+)(?:\?language_id=[12])?#art[-_][^?#[:space:]]+\z}i)
      unless target
        return false unless href.match?(%r{\Ahttps?://[^[:space:]]+\z}i)

        return allowed_external_pairs.include?([href, label_number])
      end

      numac = target[1].match?(/\Afisconet_\d+\z/i) ? target[1].upcase : target[1]
      href_number = link_article_number(href)
      label_number == href_number && allowed_pairs.include?([numac, href_number])
    end

    def mark_citation_guard_failure!(result)
      result[:error] = result[:answer] unless @last_citation_guard_result&.fetch(:passed, false)
      result
    end

    def mask_verified_article_number(label, verified_sentinel)
      match = label.match(SINGLE_ARTICLE_CITATION_PATTERN)
      return label unless match

      masked_match = match[0].sub(match[:number], verified_sentinel)
      "#{match.pre_match}#{masked_match}#{match.post_match}"
    end

    def unsupported_article_citation_message
      case @language
      when 'fr'
        "L'analyse générée contenait une référence d'article qui ne pouvait pas être reliée aux sources consultées. La réponse non vérifiée n'est donc pas affichée. Veuillez réessayer."
      when 'de'
        'Die generierte Analyse enthielt einen Artikelverweis, der keiner konsultierten Quelle zugeordnet werden konnte. Die ungeprüfte Antwort wird daher nicht angezeigt. Bitte versuchen Sie es erneut.'
      when 'en'
        'The generated analysis contained an article reference that could not be linked to a consulted source. The unverified answer is therefore not shown. Please try again.'
      else
        'De gegenereerde analyse bevatte een artikelverwijzing die niet aan een geraadpleegde bron kon worden gekoppeld. Daarom wordt het onbevestigde antwoord niet getoond. Probeer het opnieuw.'
      end
    end
  end
end
