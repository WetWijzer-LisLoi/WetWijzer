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
    EURLEX_UNIT_PREFIX = '(?:overweging|consid[ée]rant|recital|Erw[aä]gungsgrund|randnummer|r\\.o\\.|punt|point|paragraaf|paragraph|Rn\\.)'
    EURLEX_UNIT_CITATION_PATTERN = /(?<![[:alpha:]])(?<prefix>#{EURLEX_UNIT_PREFIX})\s*(?<number>\d+)(?![\d[:alpha:]])/i
    EURLEX_UNIT_ATTRIBUTION_PATTERN = /\s+[—–-]\s+(?<prefix>#{EURLEX_UNIT_PREFIX})\s*(?<number>\d+)(?![\d[:alpha:]])/i
    EURLEX_ACT_IDENTIFIER_PATTERN = %r{\b(?<act_type>richtlijn|directive|richtlinie|verordening|regulation|r[èe]glement|verordnung)\s*(?:\((?<scope_before>EU|UE|EC|EG|CE|EEC|CEE|EEG)\)\s*)?(?:(?:nr|no|n[°º])\.?\s*)?(?<act_number>\d{2,4}/\d{1,5})(?:/(?<scope_after>EU|UE|EC|EG|CE|EEC|CEE|EEG))?\b}i
    EURLEX_REPORTED_REFERENCE_PATTERN = /\b(?:verwijst|noemt|bespreekt|citeert|interpreteert|verduidelijkt|koppelt|herhaalt|mentions|refers|discusses|interprets|clarifies|links|renvoie|rappelle|pr[ée]cise|interpr[èe]te|verweist|nennt|erl[aä]utert|bezieht)\b|\blegt\b[^.\n]{0,30}\buit\b/i
    EURLEX_OPERATIVE_CLAIM_PATTERN = /\b(?:verplicht|vereist|moet(?:en)?|mag|mogen|verbiedt|verboden|bepaalt|waarborgt|geeft|kent|must|shall|requires?|obliges?|prohibits?|forbids?|permits?|grants?|entitles?|impose|exige|oblige|doit|doivent|interdit|autorise|gew[aä]hrt|verpflichtet|verlangt|fordert|muss|m[üu]ssen|darf|d[üu]rfen|verbietet|bestimmt)\b/i
    EURLEX_REFERENCE_QUALIFIER_PATTERN = /\A[\s,]*(?:(?<paragraph_prefix>lid|leden|paragraphs?|paragraphes?|Absatz|Abs[aä]tze|Abs\.)\s*\(?(?<paragraph>\d+)\)?|(?<point_prefix>onder|under|points?|punt(?:en)?|Buchstabe(?:n)?)\s*\(?(?<point>[a-z]|\d+)\)?|\((?<parenthesized>\d+|[a-z])\)|(?<bare_point>[a-z])\))/i

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
      text = fold_quote_continuations(text)
      source_records = sources.filter_map do |source|
        eu_record = verified_eurlex_corpus_record(source) if eurlex_corpus_source?(source)
        next if eurlex_corpus_source?(source) && !eu_record

        # A German row verifies a quote only as a binding German original
        # (SourceFields#german_original_source?); a German translation is
        # never evidence, whatever path brought it here.
        next if german_row_source?(source) && !german_original_source?(source)

        raw = source_field(eu_record || source, :article_text, 'article_text', :text, 'text',
                           :full_text, 'full_text', :content, 'content')
        tokens = normalized_quote_tokens(raw)
        next if tokens.empty?

        official = sealed_official_quote_source(source, raw)

        {
          tokens: tokens,
          text: raw.to_s,
          numac: retrieved_source_numac(source),
          article_number: retrieved_source_article_number(source),
          ecli: (source[:case_number] || source[:ecli] || source['case_number'] || source['ecli']).to_s.presence,
          url: (source[:url] || source['url']).to_s.presence,
          official_identity: eu_record ? "eurlex:#{source_field(eu_record, :eu_chunk_id, 'eu_chunk_id')}" : official&.fetch(:official_source_id),
          official_aliases: if eu_record
                              eurlex_record_names(eu_record)
                            elsif official
                              official.fetch(:aliases) + [official.fetch(:law_title)]
                            else
                              []
                            end,
          eu_record: eu_record,
          strict_literal: eu_record.present?
        }
      end
      return strip_all_blockquotes(text) if source_records.empty?

      rejected = 0
      repaired = 0
      checked = 0
      guarded = map_answer_blockquotes(text) do |block|
        checked += 1
        quote = extract_blockquote_text(block)
        attributed_sources = quote_attributed_sources(block, source_records)
        candidates = attributed_sources.nil? ? source_records : attributed_sources

        if quote.present? && candidates.any? && quote_supported_by_sources?(quote, candidates)
          canonical_eurlex_quote_attribution(block, candidates)
        elsif quote.present? && candidates.any? &&
              (rebuilt = reconstruct_verbatim_quote(quote, candidates)) &&
              (replacement = render_reconstructed_blockquote(block, quote, rebuilt, candidates))
          # The model elided from real statutory text. Restore the source's own
          # wording instead of dropping the quotation: measured 2026-07-31,
          # 80% of rejected quotes cited an article that WAS in evidence, at
          # 70-90% token overlap, and telling the model to stop eliding did not
          # work (42% rejection before and after the instruction).
          repaired += 1
          replacement
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
        version: 5
      }
      Rails.logger.warn("[QuoteGuard] removed #{rejected} unsupported blockquote(s)") if rejected.positive?
      Rails.logger.info("[QuoteGuard] restored source wording in #{repaired} blockquote(s)") if repaired.positive?
      guarded
    end

    def canonical_eurlex_quote_attribution(block, candidates)
      eu_candidates = candidates.select { |source| source[:eu_record] }
      return block unless eu_candidates.map { |source| source[:url] }.uniq.one?

      suffix = block.to_s.match(/\s+[—–-]\s+([^\n]+)\s*\z/)
      return block unless suffix && !suffix[1].include?('](')

      source = eu_candidates.first
      label = suffix[1].strip.sub(%r{\s*\(https://[^)]+\)\s*\z}, '')
      return block unless eurlex_label_matches_record?(label, source[:eu_record])

      block.sub(suffix[1], "[#{label}](#{source[:url]})")
    end

    # A blockquote whose opening quotation mark its ">" lines do not close
    # continues on the unprefixed lines that follow: the statute's next
    # sentence or its items (1°, 2°), which the guard never read (open item
    # of 2026-09-29; 12 of the 304 blockquotes in the German answers v4
    # evaluation's French answers, 2026-10-04). Those lines are folded into
    # the block, prefixed ">", up to the line that closes the mark, never
    # past a blank line, an attribution line, a heading or another block,
    # and QUOTE_CONTINUATION_MAX_LINES at most; the guard then verifies them
    # with the quotation they belong to, and removes them with it. The
    # model's own bullets after a closed quotation (9 of 304) are left alone.
    QUOTE_CONTINUATION_MAX_LINES = 12
    QUOTE_CONTINUATION_STOP = /\A\s*(?:[—–-]\s*\[|\[[^\]]*\]\(|[—–(]|#|\*\*|\|)/
    BLOCKQUOTE_LINE = /\A {0,3}(?:(?:[-*+]|\d{1,2}[.)]) +)?>/
    QUOTE_LINE_PREFIX = /\A(?<indent> *)(?:(?<marker>[-*+]|\d{1,9}[.)])(?<gap> +))?(?<quote>(?:> ?)+)/
    QUOTE_LIST_ITEM = /\A(?<indent> *)(?<marker>[-*+]|\d{1,9}[.)])(?<gap> +)/
    QUOTE_CODE_FENCE = /\A[ \t]*(`{3,})[^`]*\z/

    # Only valid quote containers are scanned: up to three leading spaces,
    # or up to three spaces beyond a live list's content indentation. A
    # five-space quote nested below a list item is not indented code. A
    # closed backtick fence (also used by the answer renderer) is code, not
    # an asserted quotation. An unmatched fence cannot hide later quotes.
    def answer_blockquote_prefixes(lines)
      prefixes = Array.new(lines.length)
      list_indents = []
      index = 0
      while index < lines.length
        line = lines[index].delete_suffix("\n").delete_suffix("\r")
        if (fence = line.match(QUOTE_CODE_FENCE))
          closing = ((index + 1)...lines.length).find do |candidate|
            match = lines[candidate].strip.match(/\A(`{3,})\z/)
            match && match[1].length >= fence[1].length
          end
          if closing
            index = closing + 1
            next
          end
        end

        indent = line[/\A */].length
        if (item = line.match(QUOTE_LIST_ITEM)) &&
           (indent <= 3 || list_indents.any? { |content_indent| (indent - content_indent).between?(0, 3) })
          list_indents.pop while list_indents.any? && list_indents.last > indent
          list_indents << item[0].length
        elsif line.present? && indent < list_indents.first.to_i
          list_indents.clear
        end

        prefix = line.match(QUOTE_LINE_PREFIX)
        valid_indent = indent <= 3 || list_indents.any? { |content_indent| (indent - content_indent).between?(0, 3) }
        prefixes[index] = prefix[0] if prefix && valid_indent
        index += 1
      end
      prefixes
    end

    def map_answer_blockquotes(text)
      lines = text.to_s.lines
      prefixes = answer_blockquote_prefixes(lines)
      result = +''
      index = 0
      while index < lines.length
        unless prefixes[index]
          result << lines[index]
          index += 1
          next
        end
        ending = index + 1
        ending += 1 while ending < lines.length && prefixes[ending]
        result << yield(lines[index...ending].join)
        index = ending
      end
      result
    end

    def blockquote_payload(block)
      block.lines.map { |line| line.sub(QUOTE_LINE_PREFIX, '').strip }.join(' ').strip
    end

    def render_reconstructed_blockquote(block, quote, rebuilt, candidates)
      payload = blockquote_payload(block)
      return unless payload.include?(quote)

      first = block.lines.first.to_s.match(QUOTE_LINE_PREFIX)
      return unless first

      continuation = first[:indent] + (' ' * (first[:marker].to_s.length + first[:gap].to_s.length)) + first[:quote]
      replacement = payload.sub(quote, rebuilt).lines.map.with_index do |line, index|
        "#{index.zero? ? first[0] : continuation}#{line.chomp}"
      end.join("\n") + block[/\n+\z/].to_s
      return if replacement == block
      return unless quote_supported_by_sources?(extract_blockquote_text(replacement), candidates)

      replacement
    end

    def fold_quote_continuations(text)
      return text unless text.is_a?(String) && text.include?('>')

      lines = text.split("\n", -1)
      prefixes = answer_blockquote_prefixes(lines)
      index = 0
      while index < lines.length
        unless prefixes[index]
          index += 1
          next
        end
        block_end = index
        block_end += 1 while block_end < lines.length && prefixes[block_end]
        body = lines[index...block_end].map { |line| line.sub(QUOTE_LINE_PREFIX, '') }.join("\n")
        index = block_end
        next unless unclosed_quotation_mark?(body)

        folded = 0
        while index < lines.length && folded < QUOTE_CONTINUATION_MAX_LINES
          line = lines[index]
          break if line.strip.empty? || prefixes[index] || line.match?(QUOTE_CONTINUATION_STOP) || line.match?(QUOTE_CODE_FENCE)

          lines[index] = "> #{line.strip}"
          folded += 1
          index += 1
          break unless unclosed_quotation_mark?("#{body}\n#{line}")

          body = "#{body}\n#{line}"
        end
      end
      lines.join("\n")
    end

    # true when the text opens a quotation mark it does not close: an odd
    # number of straight double quotes, or more « or “ than » or ”.
    def unclosed_quotation_mark?(text)
      return true if text.count('"').odd?

      text.count('«“') > text.count('»”')
    end

    def strip_all_blockquotes(text)
      stripped = 0
      result = map_answer_blockquotes(text) do |block|
        stripped += 1
        quote_removal_notice(block)
      end
      @last_quote_guard_result = {
        verified: true,
        checked: stripped,
        rejected: stripped,
        version: 4
      }
      Rails.logger.warn("[QuoteGuard] removed #{stripped} blockquote(s): no source text") if stripped.positive?
      result
    end

    def quote_attributed_sources(block, source_records)
      # A model may include an article link inside the quoted statutory text
      # as well as a trailing "— [source](...)" attribution. The trailing
      # attribution is authoritative; considering every link would let an
      # inline link rescue a quote that is labelled as a different article.
      trailing = block.to_s.match(/\s+[—–-]\s+\[([^\]]+)\]\(([^)]+)\).*\z/m)
      plain_attribution = block.to_s.match(PLAIN_QUOTE_ARTICLE_ATTRIBUTION_PATTERN) unless trailing
      eu_plain_attribution = block.to_s.match(EURLEX_UNIT_ATTRIBUTION_PATTERN) unless trailing || plain_attribution
      links = if trailing
                [[trailing[1], trailing[2]]]
              elsif plain_attribution || eu_plain_attribution
                []
              else
                block.to_s.scan(/\[([^\]]+)\]\(([^)]+)\)/)
              end
      internal_targets = []
      jurisprudence_targets = []
      external_targets = []

      links.map(&:last).each do |href|
        if (match = href.match(%r{\A(?:https?://(?:www\.)?wetwijzer\.be)?/laws/([^?#/)\s]+)([^)\s]*)\z}i))
          numac = match[1].match?(/\Afisconet_\d+\z/i) ? match[1].upcase : match[1]
          article_number = link_article_number(match[2])
          internal_targets << [numac, article_number]
        elsif (match = href.match(%r{\A(?:https?://(?:www\.)?wetwijzer\.be)?/jurisprudence/([^?#/)\s]+)(?:[?#][^)\s]*)?\z}i))
          jurisprudence_targets << CGI.unescape(match[1]).upcase
        elsif href.match?(%r{\Ahttps?://}i) || scheme_missing_external_link?(href)
          admitted_urls = source_records.filter_map { |source| source[:url] }.to_set
          external_targets << (retrieved_external_link_url(href, admitted_urls) || href)
        end
      end

      if internal_targets.any?
        return source_records.select do |source|
          internal_targets.include?([source[:numac], source[:article_number]])
        end
      end

      if jurisprudence_targets.any?
        return source_records.select do |source|
          !source[:eu_record] && jurisprudence_targets.include?(source[:ecli].to_s.upcase)
        end
      end

      if external_targets.any?
        matched = source_records.select do |source|
          external_targets.include?(source[:url]) &&
            (!source[:eu_record] || links.any? do |label, href|
              retrieved_external_link_url(href, Set.new([source[:url]])) == source[:url] &&
                eurlex_label_matches_record?(label, source[:eu_record])
            end)
        end
        return matched
      end

      if eu_plain_attribution
        attribution = block.to_s[eu_plain_attribution.begin(0)..].sub(/\A\s*[—–-]\s*/, '')
        candidates = source_records.select do |source|
          source[:eu_record] && eurlex_label_matches_record?(attribution, source[:eu_record])
        end
        return [] unless candidates.map { |source| source[:url] }.uniq.one?

        return candidates
      end

      if plain_attribution
        article_number = normalize_article_number(plain_attribution[1].delete(' ')).presence
        official_candidates = plain_official_quote_sources(block, plain_attribution, source_records, article_number)
        return official_candidates unless official_candidates.nil?

        named_laws = plain_quote_named_laws(block, plain_attribution)
        candidates = source_records.select do |source|
          source[:article_number] == article_number &&
            (named_laws.nil? || named_laws.include?(source[:numac]))
        end
        return [] if candidates.map { |source| source[:numac] }.uniq.length > 1

        return candidates
      end

      nil
    end

    # Official EU excerpts have a regulation identity, not a Belgian NUMAC.
    # A plain "— Article 21 GDPR" attribution previously resolved only in the
    # Belgian law catalog and discarded even its exact supplied quotation.
    # The additional identity is admitted only for a registry-identical record,
    # never from model output or an arbitrary source's claimed aliases/text.
    def sealed_official_quote_source(source, raw)
      identity = source_field(source, :official_source_id, 'official_source_id')
      return unless identity == LegalFactProvider::GDPR_PROCESSOR_OFFICIAL_SOURCE_ID
      return unless source_field(source, :source, 'source') == 'eur_lex'

      language = source_field(source, :language, 'language').to_s.downcase
      url = source_field(source, :url, 'url')
      number = retrieved_source_article_number(source)
      registries = [LegalFactProvider::GDPR_PROCESSOR_OFFICIAL_SOURCES,
                    LegalFactProvider::GDPR_RETENTION_OFFICIAL_SOURCES,
                    LegalFactProvider::GDPR_DIRECT_MARKETING_OFFICIAL_SOURCES,
                    LegalFactProvider::GDPR_COMMERCIAL_WEBSITE_OFFICIAL_SOURCES]
      registries.flat_map { |registry| registry.fetch(language, []) }.find do |record|
        record.fetch(:official_source_id) == identity && record.fetch(:url) == url &&
          record.fetch(:article_number) == number && record.fetch(:article_text) == raw
      end
    end

    def plain_official_quote_sources(block, attribution, source_records, article_number)
      tail = block.to_s[attribution.end(0)..].to_s
      official = source_records.select { |record| record[:official_identity].present? }
      aliases = official.flat_map { |record| record[:official_aliases] }.uniq
      matched_aliases = aliases.select do |name|
        tail.match?(/(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/i)
      end
      return nil if matched_aliases.empty?

      # An explicitly named second/unknown law cannot borrow the GDPR's text.
      remainder = tail.dup
      matched_aliases.sort_by { |name| -name.length }.each do |name|
        remainder.gsub!(/(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/i, '')
      end
      urls = remainder.scan(%r{(?:https?://|/{0,2}eur-lex\.europa\.eu/)[^\s)>\]]+}i)
      urls.each { |url| remainder.gsub!(url, '') }
      remainder.gsub!(/\b(?:par(?:agraphs?|agraphe?s?|agraaf)?|paragrafen|lid|leden|alinea|points?|punt(?:en)?|abs(?:atz|ätze)?|buchstabe|van|de|du|of|der|des|het|the|le|la)\b/i, '')
      remainder.gsub!(/[§\d\s.,;()\[\]"'’”>]/, '')
      remainder.gsub!(/\b[a-z]\b/i, '') # A statutory point label, e.g. lid 2, f.
      return [] unless remainder.blank?

      candidates = official.select do |record|
        record[:article_number] == article_number &&
          record[:official_aliases].intersect?(matched_aliases)
      end
      if urls.any?
        admitted_urls = candidates.filter_map { |record| record[:url] }.to_set
        targets = urls.map { |url| retrieved_external_link_url(url, admitted_urls) }
        return [] if targets.any?(&:nil?)

        candidates = candidates.select { |record| targets.include?(record[:url]) }
      end
      # Same regulation/article across differing language or corrected editions
      # is still ambiguous without an exact URL; do not choose by token overlap.
      return [] unless candidates.map { |record| record[:url] }.uniq.one?

      candidates
    end

    def extract_blockquote_text(block)
      value = blockquote_payload(block)
      value = value.sub(/\s+[—–-]\s+\[[^\]]+\]\([^)]+\).*\z/, '')
      value = value.sub(PLAIN_QUOTE_ARTICLE_ATTRIBUTION_SUFFIX_PATTERN, '')
      value = value.sub(/\s+[—–-]\s+#{EURLEX_UNIT_PREFIX}\s*\d+.*\z/i, '')
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
        next normalized_eurlex_literal(source[:text]).include?(normalized_eurlex_literal(quote)) if source.is_a?(Hash) && source[:strict_literal]

        tokens = source.is_a?(Hash) ? source[:tokens] : source
        token_subsequence_index(tokens, quote_tokens, 0).present?
      end
    end

    def normalized_eurlex_literal(value)
      ensure_utf8(value).gsub(/[[:space:]\u00A0\u2007\u202F]+/, ' ').strip
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
        next if source.is_a?(Hash) && source[:strict_literal]

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
      when 'fr' then 'Une citation a été omise car elle n’a pas pu être vérifiée à partir des sources consultées.'
      when 'de' then 'Ein Zitat wurde weggelassen, weil es anhand der konsultierten Quellen nicht überprüft werden konnte.'
      when 'en' then 'A quotation was omitted because it could not be verified against the consulted sources.'
      else 'Een citaat is weggelaten omdat het niet kon worden geverifieerd aan de hand van de geraadpleegde bronnen.'
      end
    end

    def citation_guard_passed?
      @last_citation_guard_result&.fetch(:passed, false) == true
    end

    # Supplement link verification with the bounded, source-bound childcare
    # condition check. LinkGuard alone accepted the observed answer even
    # though it omitted 0-3 and invented exceptions. Fixed condition codes
    # join the existing retry verdict; no question/answer text is logged.
    def validate_childcare_expense_answer(text, question, sources)
      verdict = ChildcareExpenseGrounding.evaluate(text, question, sources)
      return text unless verdict.fetch(:applicable)

      missing = verdict.fetch(:missing_conditions)
      previous = @last_citation_guard_result || { verified: true, passed: true, rejected: 0 }
      @last_citation_guard_result = previous.merge(
        passed: previous.fetch(:passed, false) && missing.empty?,
        rejected: previous.fetch(:rejected, 0).to_i + missing.length,
        missing_childcare_conditions: missing,
        childcare_grounding_version: verdict.fetch(:version),
        version: 5
      )
      return text if missing.empty?

      Rails.logger.warn("[ChildcareGrounding] blocked answer: condition_count=#{missing.length}")
      unsupported_childcare_expense_message
    end

    def unsupported_childcare_expense_message
      case @language
      when 'fr'
        'La réponse générée ne tenait pas correctement compte des conditions de la disposition consultée sur les frais de garde. Cette analyse non vérifiée n’est donc pas affichée.'
      when 'de'
        'Die generierte Antwort berücksichtigte die Bedingungen der konsultierten Betreuungskostenregelung nicht zuverlässig. Diese ungeprüfte Analyse wird daher nicht angezeigt.'
      when 'en'
        'The generated answer did not reliably account for the conditions of the consulted childcare-expenses provision. This unverified analysis is therefore not shown.'
      else
        'Het gegenereerde antwoord hield niet betrouwbaar rekening met de voorwaarden van de geraadpleegde bepaling over opvangkosten. Daarom wordt deze onbevestigde analyse niet getoond.'
      end
    end

    # Practical claims are not made safe by a valid statutory link. Inspect
    # all admitted evidence, including judgments with actual costs; fixed
    # codes alone travel through the existing bounded regeneration chain.
    def validate_house_hidden_defect_practical_answer(text, question, sources, candidate: text)
      verdict = HouseHiddenDefectPracticalGrounding.evaluate(candidate, question, sources)
      return text unless verdict.fetch(:applicable)

      missing = verdict.fetch(:missing_conditions)
      previous = @last_citation_guard_result || { verified: true, passed: true, rejected: 0 }
      @last_citation_guard_result = previous.merge(
        passed: previous.fetch(:passed, false) && missing.empty?,
        rejected: previous.fetch(:rejected, 0).to_i + missing.length,
        missing_house_practical_conditions: missing,
        house_practical_grounding_version: verdict.fetch(:version), version: 12
      )
      return text if missing.empty?

      Rails.logger.warn("[HousePracticalGrounding] blocked answer: condition_count=#{missing.length}")
      unsupported_article_citation_message
    end

    # These are two measured contradictions, not semantic certification.
    # Inspect the original candidate even after a citation rejection replaced
    # displayed prose, so the bounded corrective retry receives both failures.
    def validate_marketplace_civil_claim_answer(text, question, sources, candidate: text)
      verdict = MarketplaceCivilClaimGrounding.evaluate(candidate, question, sources)
      return text unless verdict.fetch(:applicable)

      missing = verdict.fetch(:missing_conditions)
      previous = @last_citation_guard_result || { verified: true, passed: true, rejected: 0 }
      @last_citation_guard_result = previous.merge(
        passed: previous.fetch(:passed, false) && missing.empty?,
        rejected: previous.fetch(:rejected, 0).to_i + missing.length,
        missing_marketplace_conditions: missing,
        marketplace_grounding_version: verdict.fetch(:version), version: 14
      )
      return text if missing.empty?

      Rails.logger.warn("[MarketplaceGrounding] blocked answer: condition_count=#{missing.length}")
      unsupported_article_citation_message
    end

    # Measured DSA misstatements (whole-act size exemption, invented size
    # figures, a pending dispute as refusal ground, invented paragraphs).
    # Inspect the original candidate like the marketplace check; fixed codes
    # alone travel through the existing bounded regeneration chain.
    def validate_platform_redress_answer(text, question, sources, candidate: text)
      verdict = PlatformRedressGrounding.evaluate(candidate, question, sources)
      return text unless verdict.fetch(:applicable)

      missing = verdict.fetch(:missing_conditions)
      previous = @last_citation_guard_result || { verified: true, passed: true, rejected: 0 }
      @last_citation_guard_result = previous.merge(
        passed: previous.fetch(:passed, false) && missing.empty?,
        rejected: previous.fetch(:rejected, 0).to_i + missing.length,
        missing_platform_redress_conditions: missing,
        platform_redress_grounding_version: verdict.fetch(:version), version: 15
      )
      return text if missing.empty?

      Rails.logger.warn("[PlatformRedressGrounding] blocked answer: condition_count=#{missing.length}")
      unsupported_article_citation_message
    end

    # Measured flight misstatements (a reversed return route, an unconditional
    # refund after a completed journey, a paragraph that does not say what is
    # attributed to it). Same contract as the platform check above.
    def validate_flight_disruption_answer(text, question, sources, candidate: text)
      verdict = FlightDisruptionGrounding.evaluate(candidate, question, sources)
      return text unless verdict.fetch(:applicable)

      missing = verdict.fetch(:missing_conditions)
      previous = @last_citation_guard_result || { verified: true, passed: true, rejected: 0 }
      @last_citation_guard_result = previous.merge(
        passed: previous.fetch(:passed, false) && missing.empty?,
        rejected: previous.fetch(:rejected, 0).to_i + missing.length,
        missing_flight_disruption_conditions: missing,
        flight_disruption_grounding_version: verdict.fetch(:version), version: 15
      )
      return text if missing.empty?

      Rails.logger.warn("[FlightDisruptionGrounding] blocked answer: condition_count=#{missing.length}")
      unsupported_article_citation_message
    end

    def validate_office_commute_answer(text, question, sources)
      verdict = OfficeCommuteGrounding.evaluate(text, question, sources)
      return text unless verdict.fetch(:applicable)

      missing = verdict.fetch(:missing_conditions)
      previous = @last_citation_guard_result || { verified: true, passed: true, rejected: 0 }
      @last_citation_guard_result = previous.merge(
        passed: previous.fetch(:passed, false) && missing.empty?,
        rejected: previous.fetch(:rejected, 0).to_i + missing.length,
        missing_office_commute_conditions: missing,
        office_commute_grounding_version: verdict.fetch(:version), version: 13
      )
      return text if missing.empty?

      Rails.logger.warn("[OfficeCommuteGrounding] blocked answer: condition_count=#{missing.length}")
      unsupported_article_citation_message
    end

    # Reject the observed minor/adult-waiver confusion only when this turn
    # supplied the exact Article 47bis safeguard. Fixed codes, not answer text,
    # travel through the existing bounded retry verdict.
    def validate_salduz_minor_answer(text, question, sources)
      verdict = SalduzMinorGrounding.evaluate(text, question, sources)
      return text unless verdict.fetch(:applicable)

      missing = verdict.fetch(:missing_conditions)
      previous = @last_citation_guard_result || { verified: true, passed: true, rejected: 0 }
      @last_citation_guard_result = previous.merge(
        passed: previous.fetch(:passed, false) && missing.empty?,
        rejected: previous.fetch(:rejected, 0).to_i + missing.length,
        missing_minor_conditions: missing,
        salduz_minor_grounding_version: verdict.fetch(:version), version: 6
      )
      return text if missing.empty?

      Rails.logger.warn("[SalduzMinorGrounding] blocked answer: condition_count=#{missing.length}")
      unsupported_article_citation_message
    end

    # An electronic-method obligation is not a mandate to accept every card.
    # Activate only with the exact retrieved WER clause; never log content.
    def validate_payment_acceptance_answer(text, question, sources)
      verdict = PaymentAcceptanceGrounding.evaluate(text, question, sources)
      return text unless verdict.fetch(:applicable)

      missing = verdict.fetch(:missing_conditions)
      previous = @last_citation_guard_result || { verified: true, passed: true, rejected: 0 }
      @last_citation_guard_result = previous.merge(
        passed: previous.fetch(:passed, false) && missing.empty?,
        rejected: previous.fetch(:rejected, 0).to_i + missing.length,
        missing_payment_conditions: missing,
        payment_grounding_version: verdict.fetch(:version), version: 7
      )
      return text if missing.empty?

      Rails.logger.warn("[PaymentGrounding] blocked answer: condition_count=#{missing.length}")
      unsupported_article_citation_message
    end

    # An exact retrieved source note must not disappear from a CV checklist.
    # This is a bounded note-presence check, not general legal verification.
    # Persist only fixed condition codes/counts, never question/answer text.
    def validate_formation_deed_answer(text, question, sources)
      verdict = FormationDeedGrounding.evaluate(text, question, sources)
      return text unless verdict.fetch(:applicable)

      missing = verdict.fetch(:missing_conditions)
      previous = @last_citation_guard_result || { verified: true, passed: true, rejected: 0 }
      @last_citation_guard_result = previous.merge(
        passed: previous.fetch(:passed, false) && missing.empty?,
        rejected: previous.fetch(:rejected, 0).to_i + missing.length,
        missing_formation_deed_conditions: missing,
        formation_deed_grounding_version: verdict.fetch(:version), version: 8
      )
      return text if missing.empty?

      Rails.logger.warn("[FormationDeedGrounding] blocked answer: condition_count=#{missing.length}")
      unsupported_article_citation_message
    end

    # Check only the observed explicit placement of numbered deed requirements.
    # Source-derived selections are not a general semantic/legal verifier.
    def validate_formation_deed_classification(text, question, sources)
      verdict = FormationDeedClassification.evaluate(text, question, sources)
      return text unless verdict.fetch(:applicable)

      missing = verdict.fetch(:missing_conditions)
      previous = @last_citation_guard_result || { verified: true, passed: true, rejected: 0 }
      @last_citation_guard_result = previous.merge(
        passed: previous.fetch(:passed, false) && missing.empty?,
        rejected: previous.fetch(:rejected, 0).to_i + missing.length,
        missing_formation_deed_classification: missing,
        formation_deed_classification_version: verdict.fetch(:version), version: 9
      )
      return text if missing.empty?

      Rails.logger.warn("[FormationDeedClassification] blocked answer: condition_count=#{missing.length}")
      unsupported_article_citation_message
    end

    # Reject the measured unconditional BV-capital requirement only with the
    # actual retrieved Article 5:1. Keep content out of the log and verdict.
    def validate_formation_bv_capital_answer(text, question, sources)
      verdict = FormationBvCapitalGrounding.evaluate(text, question, sources)
      return text unless verdict.fetch(:applicable)

      missing = verdict.fetch(:missing_conditions)
      previous = @last_citation_guard_result || { verified: true, passed: true, rejected: 0 }
      @last_citation_guard_result = previous.merge(
        passed: previous.fetch(:passed, false) && missing.empty?,
        rejected: previous.fetch(:rejected, 0).to_i + missing.length,
        missing_formation_bv_capital_conditions: missing,
        formation_bv_capital_grounding_version: verdict.fetch(:version), version: 10
      )
      return text if missing.empty?

      Rails.logger.warn("[FormationBvCapitalGrounding] blocked answer: condition_count=#{missing.length}")
      unsupported_article_citation_message
    end

    # Broad BV deed checklists require actual allocation evidence after quote
    # repair. This is deliberately narrower than general semantic verification.
    def validate_formation_bv_checklist_answer(text, question, sources)
      verdict = FormationBvChecklist.evaluate(text, question, sources)
      return text unless verdict.fetch(:applicable)

      missing = verdict.fetch(:missing_conditions)
      previous = @last_citation_guard_result || { verified: true, passed: true, rejected: 0 }
      @last_citation_guard_result = previous.merge(
        passed: previous.fetch(:passed, false) && missing.empty?,
        rejected: previous.fetch(:rejected, 0).to_i + missing.length,
        missing_formation_bv_source_grounding: missing,
        formation_bv_checklist_version: verdict.fetch(:version), version: 11
      )
      return text if missing.empty?

      Rails.logger.warn("[FormationBvChecklist] blocked answer: condition_count=#{missing.length}")
      unsupported_article_citation_message
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
      permitted_domestic_pairs = Array(
        @required_gdpr_processor_citations&.fetch(:allowed_internal_pairs, nil)
      ).to_set & allowed_pairs
      allowed_external_pairs = sources.filter_map do |source|
        next if eurlex_corpus_source?(source) && !verified_eurlex_corpus_record(source)

        url = source[:url] || source['url']
        article_number = retrieved_source_article_number(source)
        [url.to_s, article_number] if url.present? && article_number.present?
      end.to_set
      # The pairs whose German text is binding law: only they may be cited
      # with ?language_id=3, the German text of the law page on gesetzguide.
      allowed_german_pairs = german_original_pairs(sources)

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
      prose = mask_eurlex_embedded_references(prose, sources, verified_sentinel)
      prose = citation_visible_text(prose, allowed_pairs, allowed_external_pairs, verified_sentinel, allowed_german_pairs)
              .gsub(%r{</?(?:strong|b|em|i|code)\b[^>]*>}i, '')
              .gsub(/[*_~`]+/, '')
              .gsub(/&(?:nbsp|#0*160|#x0*a0);/i, ' ')
              .gsub(/[\u00A0\u2007\u202F]/, ' ')

      unsupported = prose.to_enum(:scan, ARTICLE_CITATION_SEQUENCE_PATTERN).flat_map do
        sequence = Regexp.last_match[:numbers]
        article_numbers_in_citation_sequence(sequence)
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
      unsupported.concat(unsupported_eurlex_unit_citations(text, sources)).uniq!

      cited_pairs = verified_article_citation_pairs(text, allowed_pairs, allowed_external_pairs, allowed_german_pairs)
      cited_numacs = required_drug_regime_numacs(cited_pairs)
      missing_required_regimes = required_numacs - cited_numacs
      cited_external_pairs = verified_external_article_citation_pairs(text, allowed_external_pairs)
      missing_required_external = required_external_pairs - cited_external_pairs.to_a
      domestic_scan_text = text.to_s.gsub(MARKDOWN_LINK_PATTERN) do |markdown|
        parsed = markdown.match(/\A\[([^\]\n]+)\]\(([^)\n]+)\)\z/)
        next markdown unless parsed

        target = parsed[2].match(%r{\A/laws/([^/?#]+)(?:\?language_id=[123])?#art[-_]([^?#[:space:]]+)\z}i)
        next markdown unless target

        pair = [target[1], normalize_article_number(target[2])]
        next markdown unless permitted_domestic_pairs.include?(pair) &&
                             verified_article_citation_link?(parsed[1], parsed[2], allowed_pairs, allowed_external_pairs, allowed_german_pairs)

        ''
      end
      linked_internal_numacs = domestic_scan_text.scan(%r{/laws/([^/?#)[:space:]]+)}i).flatten
      forbidden_cited_numacs = cited_pairs.reject { |pair| permitted_domestic_pairs.include?(pair) }.map(&:first)
      misattributed_domestic_sources = (forbidden_cited_numacs + linked_internal_numacs).select do |numac|
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

    # Recitals and numbered judgment paragraphs are evidence units, not
    # articles. Mask only the exact linked kind/number from this answer's
    # verified generation. A forged link must not become harmless plain prose
    # after LinkGuard strips it. Do not impose this rule on domestic "point"
    # references when no EU corpus was retrieved.
    def unsupported_eurlex_unit_citations(text, sources)
      records = sources.filter_map { |source| verified_eurlex_corpus_record(source) if eurlex_corpus_source?(source) }
      return [] unless sources.any? { |source| eurlex_corpus_source?(source) }

      invalid_link_labels = []
      prose = text.to_s.gsub(MARKDOWN_BLOCKQUOTE_PATTERN, '')
      embedded_sentinel = "#{SecureRandom.random_number(10**30).to_s.rjust(30, '0')}safe"
      prose = mask_eurlex_embedded_references(prose, sources, embedded_sentinel)
      prose = prose.gsub(MARKDOWN_LINK_PATTERN) do |markdown|
        parsed = markdown.match(/\A\[([^\]\n]+)\]\(([^)\n]+)\)\z/)
        next markdown unless parsed

        label, href = parsed.captures
        record = records.find { |candidate| source_field(candidate, :url, 'url') == href }
        if record && !eurlex_label_matches_record?(label, record) &&
           (label.match?(SINGLE_ARTICLE_CITATION_PATTERN) || label.match?(EURLEX_UNIT_CITATION_PATTERN))
          invalid_link_labels << label
        end
        record && eurlex_label_matches_record?(label, record) ? label.gsub(EURLEX_UNIT_CITATION_PATTERN, '') : label
      end
      unsupported = prose.to_enum(:scan, EURLEX_UNIT_CITATION_PATTERN).filter_map do
        match = Regexp.last_match
        prefix = match[:prefix]
        number = match[:number]
        # "punt 1" can be an operative article's subpoint. The more specific
        # recital/randnummer forms always represent EU units; generic point
        # forms require a retrieved judgment/opinion paragraph lane.
        is_recital = prefix.match?(/\A(?:overweging|consid[ée]rant|recital|Erw[aä]gungsgrund)\z/i)
        is_case = records.empty? || sources.any? do |source|
          eurlex_corpus_source?(source) && source_field(source, :kind, 'kind') == 'paragraph'
        end
        next if !is_recital && match.pre_match.last(100).match?(/#{Orchestrator::ARTICLE_PREFIX_SOURCE}\s*\d+[^.;\n]*\z/i)

        "#{prefix} #{number}" if is_recital || is_case
      end.uniq
      prose.to_enum(:scan, AnswerLinking::EURLEX_RECITAL_LIST_PATTERN).each do
        match = Regexp.last_match
        numbers = match[:numbers].scan(Orchestrator::ARTICLE_NUMBER_TOKEN_PATTERN)
        next unless numbers.length > 1

        unsupported.concat(numbers.map { |number| "Overweging #{number}" })
      end
      (invalid_link_labels + unsupported).uniq
    end

    # A judgment can report "article 5 of Directive 2002/58" without supplying
    # that operative article itself. Verify this ONLY as a literal embedded
    # reference reported by the same exact linked paragraph/recital. It does
    # not admit an article link to a paragraph, fetch a new law, or certify an
    # independent statement of the operative provision. Standalone legal
    # claims and conflicting law identities still fail the ordinary gate.
    def mask_eurlex_embedded_references(text, sources, sentinel)
      records = sources.filter_map do |source|
        record = verified_eurlex_corpus_record(source) if eurlex_corpus_source?(source)
        kind = source_field(record, :kind, 'kind') if record
        judicial_holding = record && kind == 'final' && source_field(record, :source_kind, 'source_kind') == 'jurisprudence'
        record if record && (%w[paragraph recital].include?(kind) || judicial_holding)
      end
      return text if records.empty?

      text.to_s.split(/(\n\s*\n|(?<=[.!?])\s+(?=[[:upper:]]))/).map do |sentence|
        next sentence unless sentence.match?(EURLEX_REPORTED_REFERENCE_PATTERN)

        attributed = sentence.scan(MARKDOWN_LINK_PATTERN).filter_map do |markdown|
          parsed = markdown.match(/\A\[([^\]\n]+)\]\(([^)\n]+)\)\z/)
          next unless parsed

          records.find do |record|
            source_field(record, :url, 'url') == parsed[2] && eurlex_label_matches_record?(parsed[1], record)
          end
        end.uniq
        next sentence if attributed.empty?

        masked = sentence.gsub(SINGLE_ARTICLE_CITATION_PATTERN) do |mention|
          match = Regexp.last_match
          next mention if inside_markdown_link_label?(match.pre_match, match.post_match) ||
                          inside_markdown_link_destination?(match.pre_match, match.post_match)
          next mention unless eurlex_reported_reference_context?(match)
          next mention unless attributed.any? { |record| eurlex_embedded_reference_supported?(match, record, 'article') }

          mention.sub(match[:number], sentinel)
        end
        masked.gsub(EURLEX_UNIT_CITATION_PATTERN) do |mention|
          match = Regexp.last_match
          next mention if inside_markdown_link_label?(match.pre_match, match.post_match) ||
                          inside_markdown_link_destination?(match.pre_match, match.post_match)
          next mention unless match[:prefix].match?(/\A(?:overweging|consid[ée]rant|recital|Erw[aä]gungsgrund)\z/i)
          next mention unless eurlex_reported_reference_context?(match)
          next mention unless attributed.any? { |record| eurlex_embedded_reference_supported?(match, record, 'recital') }

          mention.sub(match[:number], sentinel)
        end
      end.join
    end

    def eurlex_embedded_reference_supported?(mention, record, kind)
      number = normalize_article_number(mention[:number])
      claimed_identity = eurlex_embedded_act_identity(mention)
      claimed_qualifiers = eurlex_embedded_reference_qualifiers(mention)
      return false if claimed_qualifiers.nil?
      return false if claimed_identity.nil? && !eurlex_bare_reported_reference?(mention)

      pattern = kind == 'article' ? SINGLE_ARTICLE_CITATION_PATTERN : EURLEX_UNIT_CITATION_PATTERN
      source_field(record, :article_text, 'article_text').to_s.to_enum(:scan, pattern).any? do
        literal = Regexp.last_match
        next false if kind == 'recital' && !literal[:prefix].match?(/\A(?:overweging|consid[ée]rant|recital|Erw[aä]gungsgrund)\z/i)
        next false unless normalize_article_number(literal[:number]) == number

        expected_identity = eurlex_embedded_act_identity(literal)
        expected_qualifiers = eurlex_embedded_reference_qualifiers(literal)
        next false if expected_qualifiers.nil? || !claimed_qualifiers.all? { |qualifier| expected_qualifiers.include?(qualifier) }

        claimed_identity.nil? || (expected_identity && claimed_identity == expected_identity)
      end
    end

    # This exception attests a REPORTED reference, not a new operative rule.
    # A reporting verb elsewhere in the sentence must not bless a later
    # "article 2 ... obliges" clause. Keep each reference's own predicate and
    # immediate reporting clause bounded; ordinary legal claims retain the
    # article gate, even when an exact case link appears in the same sentence.
    def eurlex_reported_reference_context?(mention)
      clause_prefix = mention.pre_match.split(/[;\n]/).last.to_s
      tail = eurlex_embedded_reference_tail(mention)
      clause_prefix.match?(EURLEX_REPORTED_REFERENCE_PATTERN) &&
        tail.length <= 220 && !tail.match?(EURLEX_OPERATIVE_CLAIM_PATTERN)
    end

    def eurlex_embedded_reference_tail(mention)
      # "paragraph3/point(f)" immediately after an article is its qualifier,
      # not the next case unit. Do not cut it off before checking its tuple.
      mention.post_match.split(/#{Orchestrator::ARTICLE_PREFIX_SOURCE}\s*\d+|(?:overweging|consid[ée]rant|recital|Erw[aä]gungsgrund)\s*\d+|[;\n]/i, 2).first.to_s
    end

    # Bounded semantic qualifier tuples permit e.g. NL "lid 3" to match EN
    # "paragraph 3", but never lid99/point(a) against literal lid3/onder(f).
    # An unqualified report of article5 is deliberately broader; any explicit
    # qualifier must be present in the same literal embedded source reference.
    # Unrecognized lists/ranges/qualifier forms fail closed rather than being
    # discarded as harmless title residue.
    def eurlex_embedded_reference_qualifiers(mention)
      qualifiers, remainder = eurlex_parse_reference_qualifiers(eurlex_embedded_reference_tail(mention))
      head = remainder.split(/\b(?:(?:van|of|de|du|der|des)\s+(?=[[:alpha:]])|richtlijn|directive|richtlinie|verordening|regulation|r[èe]glement|verordnung|AVG|GDPR|RGPD|DSGVO)\b/i, 2).first.to_s
      qualifier_head = %r{\b(?:lid|leden|paragraphs?|paragraphes?|subparagraph|Absatz|Abs[aä]tze|Abs|onder|under|points?|punt(?:en)?|Buchstabe(?:n)?|sub|alin[ée]a|alinea)\b|§|\A[\s,]*(?:\(|\d|[-–—/]\s*\d)|\A[\s,]*(?:en|and|et|und|of|ou|tot|to|through|bis)\s*(?:\d+|[a-z]\))}i
      return if head.match?(qualifier_head)

      qualifiers
    end

    def eurlex_parse_reference_qualifiers(tail)
      qualifiers = []
      remainder = tail.to_s
      6.times do
        match = remainder.match(EURLEX_REFERENCE_QUALIFIER_PATTERN)
        break unless match

        if match[:paragraph]
          qualifiers << ['paragraph', match[:paragraph]]
        elsif match[:point] || match[:bare_point]
          qualifiers << ['point', (match[:point] || match[:bare_point]).downcase]
        else
          value = match[:parenthesized]
          qualifiers << [value.match?(/\A\d+\z/) ? 'paragraph' : 'point', value.downcase]
        end
        remainder = match.post_match
      end
      [qualifiers.uniq, remainder]
    end

    # A bare number can be reported without restating its act only when no
    # unknown title or additional claim follows it. It may not borrow a named
    # act from an unrelated sentence merely because the same number occurs.
    def eurlex_bare_reported_reference?(mention)
      _, remainder = eurlex_parse_reference_qualifiers(eurlex_embedded_reference_tail(mention))
      remainder.sub(/[.!?].*\z/m, '').match?(/\A[\s,]*(?:(?:en|and|et|und|of|ou)\s*)?\z/i)
    end

    def eurlex_embedded_act_identity(mention)
      tail = eurlex_embedded_reference_tail(mention).split(/[.;\n]/, 2).first.to_s.first(220)
      # A later predicate can introduce a DIFFERENT act (Planet49: recital17
      # OF Directive2002/58 clarifies its relation to Directive95/46). That
      # later act is not the identity of the embedded recital itself.
      tail = tail.split(EURLEX_REPORTED_REFERENCE_PATTERN, 2).first.to_s
      if tail.match?(/\b(?:van|of|de|du|der)\s+(?:deze|die|this|that|cette|dieser|dieses)\s+(?:richtlijn|directive|richtlinie|verordening|regulation|r[èe]glement|verordnung)\b/i)
        eurlex_named_act_identities(mention.pre_match).last
      else
        identities = eurlex_named_act_identities(tail)
        identities << ['regulation', '2016/679', nil] if tail.match?(/\b(?:AVG|GDPR|RGPD|DSGVO)\b/)
        identities.uniq!
        return 'ambiguous_named_act' if identities.length > 1
        return identities.first if identities.one?
        return 'unknown_named_act' if tail.match?(/\b(?:richtlijn|directive|richtlinie|verordening|regulation|r[èe]glement|verordnung|wet|loi|gesetz|code)\b/i)
        return 'unknown_named_act' if tail.match?(/\b(?:van|of|du|der)\s+(?:(?:de|het|the|le|la|des)\s+)?\p{Lu}[[:alpha:]]+/u)

        nil
      end
    end

    # Act type and an explicitly printed institutional suffix are identity,
    # not decoration. A Directive cannot attest a same-number Regulation;
    # EC/EG/CE are locale equivalents, but EU is not interchangeable with EC.
    # An unstated suffix is intentionally not guessed from an unrelated work.
    def eurlex_named_act_identities(text)
      text.to_s.to_enum(:scan, EURLEX_ACT_IDENTIFIER_PATTERN).map do
        match = Regexp.last_match
        type = match[:act_type].match?(/\A(?:richtlijn|directive|richtlinie)\z/i) ? 'directive' : 'regulation'
        scopes = [match[:scope_before], match[:scope_after]].compact.map do |scope|
          case scope.upcase
          when 'EU', 'UE' then 'eu'
          when 'EC', 'EG', 'CE' then 'ec'
          when 'EEC', 'CEE', 'EEG' then 'eec'
          end
        end.uniq
        scope = scopes.length > 1 ? 'conflicting_scope' : scopes.first
        scope = 'unrecognized_scope' if match.post_match.match?(%r{\A/[[:alpha:]]})
        [type, match[:act_number], scope]
      end
    end

    # Only an explicit degree-marked list item is a point of the preceding
    # article. The first reference and any item with its own article prefix
    # remain citations, including unsupported "Art. 999°". Continue scanning
    # after points so "[Art. 2bis](...) et 1°, 2ter" still rejects Art. 2ter.
    def article_numbers_in_citation_sequence(sequence)
      previous_end = 0
      sequence.to_enum(:scan, ARTICLE_NUMBER_TOKEN_PATTERN).each_with_index.filter_map do |_number, index|
        match = Regexp.last_match
        between = sequence[previous_end...match.begin(0)]
        previous_end = match.end(0)
        explicit_article = between.match?(Regexp.new("\\b#{Orchestrator::ARTICLE_PREFIX_SOURCE}"))
        ordinal = match.post_match.match?(/\A[[:space:]\u00A0\u2007\u202F]*°/)
        next if index.positive? && ordinal && !explicit_article

        match[0]
      end
    end

    def required_drug_regime_numacs(cited_pairs)
      DRUG_CITATION_ARTICLE_PRIORITY.filter_map do |numac, priority_articles|
        normalized_priorities = priority_articles.map { |article| normalize_article_number(article) }
        numac if normalized_priorities.any? { |article| cited_pairs.include?([numac, article]) }
      end
    end

    def verified_article_citation_pairs(text, allowed_pairs, allowed_external_pairs = Set.new, german_pairs = Set.new)
      text.to_s.scan(MARKDOWN_LINK_PATTERN).filter_map do |markdown|
        next if markdown.start_with?('!')

        parsed = markdown.match(/\A\[([^\]\n]+)\]\(([^)\n]+)\)\z/)
        next unless parsed

        label = parsed[1]
        href = parsed[2]
        next unless verified_article_citation_link?(label, href, allowed_pairs, allowed_external_pairs, german_pairs)

        target = href.match(%r{\A/laws/([^/?#]+)(?:\?language_id=[123])?#art[-_]([^?#[:space:]]+)\z}i)
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

    def citation_visible_text(text, allowed_pairs, allowed_external_pairs, verified_sentinel, german_pairs = Set.new)
      text.gsub(MARKDOWN_LINK_PATTERN) do |markdown|
        parsed = markdown.match(/\A!?\[([^\]\n]+)\]\(([^)\n]+)\)\z/)
        next markdown unless parsed

        label = parsed[1]
        href = parsed[2]
        # An image is not a user-visible, clickable legal citation even when
        # its alt text and target happen to resemble a retrieved article link.
        next label if markdown.start_with?('!')

        if verified_article_citation_link?(label, href, allowed_pairs, allowed_external_pairs, german_pairs)
          mask_verified_article_number(label, verified_sentinel)
        else
          label
        end
      end
    end

    # ?language_id=1 or 2 (or none) is accepted for any retrieved pair;
    # ?language_id=3 only for a pair in german_pairs, a retrieved binding
    # German original (SourceFields#german_original_pairs). On an NL or FR
    # pair it opens no binding text, so it is not verified and the article
    # number stays visible to the scanner, which blocks the answer.
    def verified_article_citation_link?(label, href, allowed_pairs, allowed_external_pairs = Set.new, german_pairs = Set.new)
      label_match = label.match(SINGLE_ARTICLE_CITATION_PATTERN)
      return false unless label_match

      label_number = normalize_article_number(label_match[:number])
      target = href.match(%r{\A/laws/([^/?#]+)(?:\?language_id=([123]))?#art[-_][^?#[:space:]]+\z}i)
      unless target
        return false unless href.match?(%r{\Ahttps?://[^[:space:]]+\z}i)

        return allowed_external_pairs.include?([href, label_number])
      end

      numac = target[1].match?(/\Afisconet_\d+\z/i) ? target[1].upcase : target[1]
      href_number = link_article_number(href)
      return false unless label_number == href_number && allowed_pairs.include?([numac, href_number])

      target[2] != '3' || german_pairs.include?([numac, href_number])
    end

    def mark_citation_guard_failure!(result)
      # A generic source list can pass link verification while the requested
      # analysis was withheld. It is still nonbillable; do not confuse it with
      # a substantive, verified source-derived answer sharing the outcome enum.
      verified_answer_delivered = result[:citation_guard_source_list_only] != true &&
                                  @last_citation_guard_result&.fetch(:passed, false)
      result[:error] = result[:answer] unless verified_answer_delivered
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
