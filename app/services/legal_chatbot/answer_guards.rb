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
      text = resolve_fisconet_citation_links(fold_quote_continuations(text), sources)
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
          fisconet_region: retrieved_fisconet_region(source),
          fisconet_anchor: retrieved_fisconet_anchor(source),
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
          withheld_quote_notice(block, judgment_pinpoint(quote, candidates))
        end
      end
      guarded = without_dangling_quote_references(guarded) if rejected.positive?
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
          internal_targets << [numac, article_number, link_article_region(match[2]), match[2][/#(art_[^?&#\s)]+)/i, 1]]
        elsif (match = href.match(%r{\A(?:https?://(?:www\.)?wetwijzer\.be)?/jurisprudence/([^?#/)\s]+)(?:[?#][^)\s]*)?\z}i))
          jurisprudence_targets << CGI.unescape(match[1]).upcase
        elsif href.match?(%r{\Ahttps?://}i) || scheme_missing_external_link?(href)
          admitted_urls = source_records.filter_map { |source| source[:url] }.to_set
          external_targets << (retrieved_external_link_url(href, admitted_urls) || href)
        end
      end

      if internal_targets.any?
        return internal_targets.flat_map do |numac, article_number, region, anchor|
          rows = source_records.select { |source| source[:numac] == numac && source[:article_number] == article_number }
          # A link to one row's text attributes the quote to that text, and 1.2 and 1/2 share an article number here. A
          # region not retrieved says nothing about the rows that were. resolve_fisconet_citation_links has moved such a link
          # to one of them; this is for a link it left alone. A plain id with several rows retrieved names none of them.
          exact = rows.select { |source| anchor && source[:fisconet_anchor] == anchor }
          own = rows.select { |source| region && source[:fisconet_region] == region }
          exact.presence || own.presence || rows
        end.uniq
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
                    LegalFactProvider::GDPR_COMMERCIAL_WEBSITE_OFFICIAL_SOURCES,
                    LegalFactProvider::GDPR_BREACH_OFFICIAL_SOURCES,
                    LegalFactProvider::GDPR_CONTROLLER_OFFICIAL_SOURCES]
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

        span = ordered_token_span(indexed.map(&:first), wanted, (wanted.length * QUOTE_RECONSTRUCTION_MAX_GROWTH).ceil)
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
    # The tightest span of at most max_span tokens that holds the wanted tokens in order (Sol 2026-11-24 10:26:43Z:
    # 140/2018 printed the omission notice). The first start that completed was taken before, so a quotation that begins
    # with a common word ("de", "gebeuren") matched a sprawling early span, failed the growth limit and was dropped
    # although its passage came later.
    def ordered_token_span(tokens, wanted, max_span = tokens.length)
      best = nil
      tokens.each_index.select { |index| tokens[index] == wanted.first }.each do |start|
        cursor = start
        matched = 0
        while cursor < tokens.length && matched < wanted.length && cursor - start < max_span
          matched += 1 if tokens[cursor] == wanted[matched]
          cursor += 1
        end
        next unless matched == wanted.length

        best = [start, cursor - 1] if best.nil? || cursor - 1 - start < best[1] - best[0]
      end
      best
    end

    # The blockquote pattern consumes the newline that ended the quote, so
    # substituting a bare sentence glued the following line onto the notice:
    # a list item rendered as "Huurcontracten in Vlaanderen:" then the notice
    # with "- Bij niet-naleving ..." running straight on from it, in a run the
    # owner reported. Give the notice the same trailing newlines the block had
    # so the surrounding paragraph and list structure survives.
    def quote_removal_notice(block, pinpoint = nil)
      trailing = block.to_s[/\n+\z/].to_s
      trailing = "\n" if trailing.empty?
      "#{[missing_quote_message, pinpoint].compact.join(' ')}#{trailing}"
    end

    # Sol 2026-11-24 15:25:09Z (live 1.1.100): 140/2018 printed the omission notice and named neither B.1.8 nor the
    # memorandum it quotes. When a quotation from a judgment is withheld, the notice adds a verified pinpoint: the
    # consideration that holds at least PINPOINT_MIN_SHARE of the quotation's longer words, and the citations of the
    # preparatory works in it, both copied from the decision. A quotation of a statute gets none.
    PINPOINT_MIN_SHARE = 0.8
    PINPOINT_MIN_WORDS = 6
    PINPOINT_MAX_REFERENCES = 2
    CONSIDERATION_LABEL = /^([AB]\.\d{1,2}(?:\.\d{1,2}){0,3})\.[[:space:]]/

    # Sol 2026-11-24 20:11:39Z: unordered overlap with a whole consideration is not enough. The words must sit together:
    # a supporting passage is a run of the consideration's words that holds PINPOINT_MIN_SHARE of them, at most
    # PINPOINT_MAX_SPREAD times the quotation's length plus PINPOINT_SPREAD_MARGIN words. Two considerations can share
    # the same words with opposite holdings, so passages in a second consideration anywhere in the cited judgments leave
    # the pinpoint out. Sol 21:28:20Z: the same words can also hold the contrary within the one consideration left, so a
    # passage whose sentences negate other words than the quotation does is no support (see same_polarity?); without a
    # passage that agrees there is no pinpoint, and the citations of the passage's own sentences are given only when one
    # passage agrees (two agreeing passages give the consideration alone).
    PINPOINT_MAX_SPREAD = 2
    PINPOINT_SPREAD_MARGIN = 8

    def judgment_pinpoint(quote, candidates)
      quote_tokens = normalized_quote_tokens(quote)
      wanted = quote_tokens.select { |token| token.length >= 4 }.uniq.to_set
      return nil if wanted.length < PINPOINT_MIN_WORDS

      needed = (wanted.length * PINPOINT_MIN_SHARE).ceil
      longest = (quote_tokens.length * PINPOINT_MAX_SPREAD) + PINPOINT_SPREAD_MARGIN
      found = Array(candidates).flat_map do |source|
        next [] unless source.is_a?(Hash) && source[:ecli].to_s.start_with?('ECLI:')

        judgment_considerations(source[:text]).filter_map do |label, body|
          spans = supporting_spans(body, wanted, needed, longest)
          [label, body, spans, source[:ecli]] if spans.any?
        end
      end
      return nil unless found.one?

      label, body, spans, ecli = found.first
      agreeing = spans.map { |first, last| passage_sentence_bounds(body, first, last) }.uniq.select do |start, stop|
        same_polarity?(quote_tokens, source_tokens_with_offsets(body[start..stop]).map(&:first), wanted)
      end
      return nil if agreeing.empty?

      references = if agreeing.one?
                     start, stop = agreeing.first
                     body[start..stop].scan(LegalChatbot::SourcePassageExcerpt::PREPARATORY_REFERENCE).flatten
                                      .map { |reference| reference.gsub(/[[:space:]]+/, ' ').strip }.uniq.first(PINPOINT_MAX_REFERENCES)
                   else
                     []
                   end
      pinpoint_message(label, ecli, references)
    end

    # [[first character, last character], ...] of the passages of body, in order and not overlapping: each is the
    # shortest run that ends where `needed` distinct wanted words are first all present, kept when it is shorter than
    # `longest` words; the next is looked for after the kept one's sentence, so that the rest of that sentence never
    # joins it. A run too long gives up its first word so that a closer run further on can still be found.
    def supporting_spans(body, wanted, needed, longest)
      tokens = source_tokens_with_offsets(body)
      ends = sentence_ends(body)
      spans = []
      counts = Hash.new(0)
      covered = 0
      left = 0
      tokens.each_with_index do |(token, _start, _stop), right|
        next if right < left

        if wanted.include?(token)
          covered += 1 if counts[token].zero?
          counts[token] += 1
        end
        next if covered < needed

        loop do
          head = tokens[left].first
          break if wanted.include?(head) && counts[head] == 1 && covered == needed

          if wanted.include?(head)
            counts[head] -= 1
            covered -= 1 if counts[head].zero?
          end
          left += 1
        end
        if right - left < longest
          spans << [tokens[left][1], tokens[right][2] - 1]
          boundary = ends.find { |index| index >= tokens[right][2] - 1 } || body.length
          counts = Hash.new(0)
          covered = 0
          left = tokens.index { |(_word, start, _stop)| start > boundary } || tokens.length
        else
          head = tokens[left].first
          counts[head] -= 1
          covered -= 1 if counts[head].zero?
          left += 1
        end
      end
      spans
    end

    # Negations whose scope the polarity check compares; "pas" is the French one ("n'est pas justifiée").
    NEGATION_WORDS = %w[niet geen nooit noch niets zonder ne pas ni jamais aucun aucune rien sans nicht kein keine keinen keinem
                        keiner keines nie niemals weder ohne not no never neither nor none without].to_set.freeze
    NEGATION_REACH = 3

    # Each negation's predicate key: the nearest of the quotation's longer words before it and the nearest after it,
    # within NEGATION_REACH words, negations left out ("de Grondwet niet schendt" gives grondwet and schendt); a negation
    # next to none of them counts for nothing.
    def negation_keys(tokens, wanted)
      content = ->(token) { wanted.include?(token) && !NEGATION_WORDS.include?(token) }
      tokens.each_index.filter_map do |index|
        next unless NEGATION_WORDS.include?(tokens[index])

        before = tokens[[index - NEGATION_REACH, 0].max...index].rfind(&content)
        after = tokens[(index + 1)..(index + NEGATION_REACH)].to_a.find(&content)
        [before.to_s, after.to_s] if before || after
      end.sort
    end

    # Sol 2026-11-24 21:28:20Z and 22:16:54Z: the passage must negate exactly what the quotation negates. "niet redelijk
    # verantwoord" does not support "... de Grondwet niet schendt", and "is redelijk maar niet noodzakelijk" does not
    # support "is niet redelijk maar wel noodzakelijk", although the words around the two negations overlap; when the
    # negated predicate is not the same, it is uncertain and no pinpoint is given. A quotation that keeps the passage's
    # words but moves the negation elsewhere ("schendt de Grondwet niet" against "de Grondwet niet schendt") gets none
    # either. Limits of the text alone (Sol 22:16:54Z, 22:49:20Z): a contrary wording without any negation ("gegrond"
    # and "ongegrond", "schendt" and "eerbiedigt") is not seen, nor are swapped actors next to the same words ("de
    # werkgever is aansprakelijk voor de schade van de werknemer" against the reverse); more word lists would not
    # establish support, so the rule stays one that omits a pinpoint when in doubt.
    def same_polarity?(quote_tokens, passage_tokens, wanted)
      negation_keys(quote_tokens, wanted) == negation_keys(passage_tokens, wanted)
    end

    # The sentences the passage stands in (Array#rfind is core Ruby 4.0).
    def passage_sentence_bounds(body, first, last, ends = sentence_ends(body))
      [(ends.rfind { |index| index < first } || -1) + 1, ends.find { |index| index >= last } || (body.length - 1)]
    end

    # Where body's sentences end. A full stop inside parentheses ends no sentence, so a citation such as
    # "(Parl. St., Kamer, 2013-2014, DOC 53-3144/001, p. 39)" stays with the sentence it closes.
    def sentence_ends(body)
      ends = []
      depth = 0
      body.each_char.with_index do |char, index|
        depth += 1 if char == '('
        depth -= 1 if char == ')' && depth.positive?
        ends << index if depth.zero? && '.!?'.include?(char) && (index + 1 == body.length || body[index + 1].match?(/\s/))
      end
      ends
    end

    # Sol 2026-11-24 17:38:35Z (live 1.1.101): the 140/2018 answer said "de formulering hierboven tussen aanhalingstekens
    # is de letterlijke tekst zoals die in de bron staat" after its only quotation was withheld. Sol 20:11:39Z: only that
    # sentence goes, the one directly after the notice of a withheld quotation, when it speaks of a quotation above as
    # literal; an ordinary legal sentence with the same words elsewhere stays. The mark is a private-use character that
    # never leaves the guard.
    WITHHELD_QUOTE_MARK = "\u{E000}"
    QUOTE_ABOVE = /(?<![[:alnum:]])(?:hierboven|bovenstaande?|ci-dessus|plus\s+haut|oben|obige[nmrs]?|above)(?![[:alnum:]])/iu
    QUOTE_LITERAL = /(?<![[:alnum:]])(?:letterlijk\p{L}*|aanhalingstekens|littéra\p{L}*|textuel\p{L}*|guillemets|wörtlich\p{L}*|
                     anführungszeichen|verbatim|quotation\s+marks|quoted)(?![[:alnum:]])/iux
    QUOTE_NOUN = /(?<![[:alnum:]])(?:citaat|citaten|aanhaling\p{L}*|passage|formulering|bewoording\p{L}*|tekst|citation\p{L}*|
                  formulation|libellé|texte|zitat\p{L}*|stelle|formulierung|wortlaut|text|quotation|quote|wording)(?![[:alnum:]])/iux

    def withheld_quote_notice(block, pinpoint)
      quote_removal_notice(block, pinpoint).sub(/(\n*)\z/) { "#{WITHHELD_QUOTE_MARK}#{Regexp.last_match(1)}" }
    end

    def without_dangling_quote_references(text)
      text.gsub(/#{WITHHELD_QUOTE_MARK}(\n*)([^.!?\n]+[.!?]?[[:blank:]]*)?/o) do
        gap = Regexp.last_match(1)
        sentence = Regexp.last_match(2).to_s
        vouching = !sentence.lstrip.start_with?('>') && # a quotation line that follows is never cut
                   sentence.match?(QUOTE_ABOVE) && sentence.match?(QUOTE_LITERAL) && sentence.match?(QUOTE_NOUN)
        vouching ? gap : "#{gap}#{sentence}"
      end
    end

    # [[label, its text], ...] in the judgment's order
    def judgment_considerations(text)
      body = text.to_s
      starts = body.to_enum(:scan, CONSIDERATION_LABEL).map { [Regexp.last_match.begin(0), Regexp.last_match[1]] }
      starts.each_with_index.map { |(start, label), index| [label, body[start...(starts[index + 1]&.first || body.length)]] }
    end

    def pinpoint_message(label, ecli, references)
      cited = references.any? ? " (#{references.join('; ')})" : ''
      case @language
      when 'fr' then "Le passage figure au considérant #{label} de #{ecli}#{cited}."
      when 'de' then "Die Stelle steht in Erwägung #{label} von #{ecli}#{cited}."
      when 'en' then "The passage is in consideration #{label} of #{ecli}#{cited}."
      else "De passage staat in overweging #{label} van #{ecli}#{cited}."
      end
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

    # Measured withdrawal misstatements of the catalogue QA (2026-10-19): the
    # deadline without its 14 days, the sealed-hygiene and alcohol exceptions
    # without their conditions, a defect read as excluding withdrawal. Same
    # contract as the flight check above.
    def validate_consumer_withdrawal_answer(text, question, sources, candidate: text)
      verdict = ConsumerWithdrawalGrounding.evaluate(candidate, question, sources)
      return text unless verdict.fetch(:applicable)

      missing = verdict.fetch(:missing_conditions)
      previous = @last_citation_guard_result || { verified: true, passed: true, rejected: 0 }
      @last_citation_guard_result = previous.merge(
        passed: previous.fetch(:passed, false) && missing.empty?,
        rejected: previous.fetch(:rejected, 0).to_i + missing.length,
        missing_consumer_withdrawal_conditions: missing,
        consumer_withdrawal_grounding_version: verdict.fetch(:version), version: 16
      )
      return text if missing.empty?

      Rails.logger.warn("[ConsumerWithdrawalGrounding] blocked answer: condition_count=#{missing.length}")
      unsupported_article_citation_message
    end

    # Measured lease-notice misstatements of the catalogue QA (2026-10-19):
    # the tenant's one-month counter-notice given to the landlord, the short
    # lease rule applied to a nine-year lease. Same contract as above.
    def validate_rental_notice_answer(text, question, sources, candidate: text)
      verdict = RentalNoticeGrounding.evaluate(candidate, question, sources)
      return text unless verdict.fetch(:applicable)

      missing = verdict.fetch(:missing_conditions)
      previous = @last_citation_guard_result || { verified: true, passed: true, rejected: 0 }
      @last_citation_guard_result = previous.merge(
        passed: previous.fetch(:passed, false) && missing.empty?,
        rejected: previous.fetch(:rejected, 0).to_i + missing.length,
        missing_rental_notice_conditions: missing,
        rental_notice_grounding_version: verdict.fetch(:version), version: 16
      )
      return text if missing.empty?

      Rails.logger.warn("[RentalNoticeGrounding] blocked answer: condition_count=#{missing.length}")
      unsupported_article_citation_message
    end

    # r47 semantic checks of the stage A answers (root 2026-10-19 23:36:18).
    # Each reads only the RETAINED Belgian legislation rows the guard chain
    # received and applies only when its governing unit carries the exact
    # wording the check relies on. Same contract as the checks above.
    def validate_serious_cause_dismissal_answer(text, question, sources, candidate: text)
      merge_semantic_grounding(text, SeriousCauseDismissalGrounding.evaluate(candidate, question, sources),
                               :missing_serious_cause_conditions, :serious_cause_grounding_version,
                               'SeriousCauseDismissalGrounding')
    end

    def validate_rental_indexation_answer(text, question, sources, candidate: text)
      merge_semantic_grounding(text, RentalIndexationGrounding.evaluate(candidate, question, sources),
                               :missing_rental_indexation_conditions, :rental_indexation_grounding_version,
                               'RentalIndexationGrounding')
    end

    # #337 (Sol 2026-11-22 08:38:00Z, 11:43:54Z, 13:14:02Z): not a block but a correction. In an unemployment answer a
    # benefit figure (a base amount of the decree's art. 115, or an indexed one) becomes or stays the amount of the
    # schedule for the period it speaks of, or is withheld when no schedule checked by hand covers that period; a
    # quotation keeps its base amounts. One line under the answer gives the first day, the official table and the manual
    # check (IndexedAmounts). The record counts each outcome.
    # Sol 2026-11-26 22:34:20Z (#115, live 1.1.113): then the paragraph on whom the full-unemployment amounts apply to
    # goes right before the first of them, when the text right above does not already say it
    # (UnemploymentAmountApplicability).
    # Sol 2026-11-27 09:38:22Z (#304, live 1.1.115): an answer on unemployment after an accident that leaves out the
    # temporary-unemployment exception of art. 61, § 2, second paragraph, gets it (AccidentUnemploymentException).
    def apply_indexed_amounts(text, question, sources)
      result = IndexedAmounts.apply(text, question: question, sources: sources, language: @language)
      amounts = UnemploymentAmountApplicability.apply(result.text, question: question, sources: sources, language: @language)
      applied = AccidentUnemploymentException.apply(amounts, question: question, language: @language, sources: sources)
      return text if applied == text

      previous = @last_citation_guard_result || { verified: true, passed: true, rejected: 0 }
      record = {}
      if result.text != text
        record.merge!(indexed_amounts_replaced: result.replaced, indexed_amounts_confirmed: result.confirmed,
                      indexed_amounts_withheld: result.withheld, indexed_amounts_quoted: result.quoted,
                      indexed_amounts_version: IndexedAmounts::VERSION)
      end
      record[:unemployment_applicability_version] = UnemploymentAmountApplicability::VERSION if amounts != result.text
      record[:accident_unemployment_exception_version] = AccidentUnemploymentException::VERSION if applied != amounts
      @last_citation_guard_result = previous.merge(record)
      applied
    end

    # Sol 2026-11-25 12:35:40Z: a drug offence question about facts before 1 September 2026 learns that our Drugswet is
    # today's text and where its official history is (DatedDrugLawNote)
    def apply_dated_drug_law_note(text, question)
      DatedDrugLawNote.apply(text, question: question, language: @language)
    end

    def validate_withdrawal_function_status_answer(text, question, sources, candidate: text)
      merge_semantic_grounding(text, OnlineWithdrawalFunctionStatus.evaluate(candidate, question, sources),
                               :missing_withdrawal_function_status_conditions, :withdrawal_function_status_version,
                               'OnlineWithdrawalFunctionStatus')
    end

    def validate_commercial_website_scope_answer(text, question, sources, candidate: text)
      merge_semantic_grounding(text, CommercialWebsiteScopeGrounding.evaluate(candidate, question, sources),
                               :missing_website_scope_conditions, :website_scope_grounding_version,
                               'CommercialWebsiteScopeGrounding')
    end

    def merge_semantic_grounding(text, verdict, missing_key, version_key, label)
      return text unless verdict.fetch(:applicable)

      missing = verdict.fetch(:missing_conditions)
      previous = @last_citation_guard_result || { verified: true, passed: true, rejected: 0 }
      @last_citation_guard_result = previous.merge(
        {
          passed: previous.fetch(:passed, false) && missing.empty?,
          rejected: previous.fetch(:rejected, 0).to_i + missing.length,
          missing_key => missing,
          version_key => verdict.fetch(:version),
          version: 17
        }
      )
      return text if missing.empty?

      Rails.logger.warn("[#{label}] blocked answer: condition_count=#{missing.length}")
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
      required_points = Array(@required_gdpr_processor_citations&.fetch(:required_definition_points, nil))
      if text.blank?
        passed = required_numacs.empty? && required_external_pairs.empty? && required_points.empty?
        @last_citation_guard_result = {
          verified: true, passed: passed,
          rejected: required_numacs.length + required_external_pairs.length + required_points.length,
          unsupported_references: [], missing_required_regimes: required_numacs,
          missing_required_external_citations: required_external_pairs,
          missing_required_definition_points: required_points, misattributed_definition_points: [],
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
      # #1582: a GDPR art. 4 link names the point users read; it must be a required point the label names, and one
      # a source holds at that link (points 7 and 8 share the URL)
      normalize = method(:normalize_article_number)
      missing_definition_points = required_points - GdprDefinitionPoints.cited(text, allowed_external_pairs, normalize).to_a
      misattributed_points = GdprDefinitionPoints.misattributed(text, sources, normalize)
      domestic_scan_text = text.to_s.gsub(MARKDOWN_LINK_PATTERN) do |markdown|
        parsed = markdown.match(/\A\[([^\]\n]+)\]\(([^)\n]+)\)\z/)
        next markdown unless parsed

        target = parsed[2].match(%r{\A/laws/([^/?#]+)(?:\?language_id=[123])?#art[-_]([^?#[:space:]]+)\z}i)
        next markdown unless target

        pair = [target[1], link_article_number(parsed[2])]
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
               misattributed_domestic_sources.empty? && missing_definition_points.empty? && misattributed_points.empty?

      @last_citation_guard_result = {
        verified: true,
        passed: passed,
        rejected: unsupported.length + missing_required_regimes.length + missing_required_external.length +
                  misattributed_domestic_sources.length + missing_definition_points.length + misattributed_points.length,
        unsupported_references: unsupported,
        missing_required_regimes: missing_required_regimes,
        missing_required_external_citations: missing_required_external,
        missing_required_definition_points: missing_definition_points,
        misattributed_definition_points: misattributed_points,
        misattributed_domestic_sources: misattributed_domestic_sources,
        version: 4
      }
      return text if passed

      Rails.logger.warn(
        "[CitationGuard] blocked answer: unsupported_count=#{unsupported.size} " \
        "missing_regime_count=#{missing_required_regimes.size} " \
        "missing_external_count=#{missing_required_external.size} " \
        "missing_point_count=#{missing_definition_points.size} misattributed_point_count=#{misattributed_points.size} " \
        "misattributed_domestic_count=#{misattributed_domestic_sources.size} " \
        "unsupported=#{citation_guard_log_references(unsupported)} " \
        "misattributed=#{citation_guard_log_references(misattributed_domestic_sources)}"
      )
      unsupported_article_citation_message
    end

    # The references a blocked answer could not support, for the log, so the line names what failed (Sol 2026-11-16
    # 20:17:26Z: counts alone said nothing) and never carries the answer's prose. Only canonical identifiers are
    # written (Sol 2026-11-17 03:58:47Z): "Art. <number>" with a bounded article number ("10", "11bis", "VI.49",
    # "5:233", "32quater/2"), an EU unit ("Overweging 12"), or a NUMAC-shaped source id; anything else is only
    # counted. At most five are written.
    CANONICAL_LOG_SUFFIX = '(?:bis|ter|quater|quinquies|sexies|septies|octies|novies|decies|[a-z])?'
    CANONICAL_LOG_ARTICLE = %r{\AArt\.\ (?:\d{1,5}|[IVXLCDM]{1,6}\.\d{1,5})#{CANONICAL_LOG_SUFFIX}(?:[./:-]\d{1,5}#{CANONICAL_LOG_SUFFIX}){0,4}\z}
    CANONICAL_LOG_EU_UNIT = /\A(?:Overweging|consid[ée]rant|recital|Erw[äa]gungsgrund|randnummer|r\.o\.|punt|point|paragraaf|paragraph|Rn\.) \d{1,5}\z/i
    CANONICAL_LOG_SOURCE = /\A(?:\d{4}[0-9A-Z]\d{5}|FISCONET_\d{1,3})\z/

    def citation_guard_log_references(references)
      canonical, other = Array(references).map(&:to_s).partition do |reference|
        reference.match?(CANONICAL_LOG_ARTICLE) || reference.match?(CANONICAL_LOG_EU_UNIT) || reference.match?(CANONICAL_LOG_SOURCE)
      end
      written = canonical.first(5).map { |reference| reference.delete(' ') }.join('|').presence || '-'
      other.empty? ? written : "#{written}+#{other.size}noncanonical"
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
        [numac, link_article_number(href)]
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
      # analysis was withheld. Mark it as an error like a failed verdict, so
      # the controller delivers no answer; whether the reservation is then
      # charged or released follows its dispatch evidence (a paid provider
      # request that was sent keeps the single charge, owner policy
      # 2026-10-18), not this flag. Do not confuse the list with a
      # substantive, verified source-derived answer sharing the outcome enum.
      verified_answer_delivered = result[:citation_guard_source_list_only] != true &&
                                  @last_citation_guard_result&.fetch(:passed, false)
      result[:error] = result[:answer] unless verified_answer_delivered
      result
    end

    # A point or paragraph of an article in a label: "(8)", ", punt 8", " Nr. 8", ", lid 2", ", 8)"
    LABEL_UNIT_SOURCE = '(?:(?:punt(?:en)?|points?|nrn?\.?|nummern?|lid|leden|paragraphs?|abs\.?|absatz)[[:space:]]*' \
                        '\(?(?:\d{1,2}|[a-z])\)?|\((?:\d{1,2}|[a-z])\)|\d{1,2}\))'
    # A point written as in the text of the GDPR, right after the article: "artikel 4, 7) AVG". Unmasked, the scan
    # reads "artikel 4, 7" as a second article.
    LABEL_POINT_AFTER_COMMA = /\A(,[[:space:]]*)(\d{1,2})(\))/
    # Between two citations of one article in one label: the first one's point, then a list connector
    LABEL_SAME_ARTICLE_GAP = /\A[[:space:],]*(?:#{LABEL_UNIT_SOURCE})?[[:space:]]*
                              (?:,|;|&|(?<![[:alpha:]])(?:en|et|und|and)(?![[:alpha:]]))[[:space:]]*\z/ix
    LABEL_UNIT_AFTER = /\A[[:space:],]*#{LABEL_UNIT_SOURCE}(?![[:alnum:]])/i

    # The label's first citation is the verified one. #1582 (Sol 2026-11-22 14:53:13Z): one label can name two points
    # of that article, each with its prefix ("Art. 4(7) and Art. 4(8)"); a later citation of the same number is masked
    # too when it continues the list and names its own point. A point written ", 7)" right after a masked citation is
    # the point, not an article (Sol 17:42:33Z: valid art. 4(7) labels). Any other citation in the label stays visible.
    def mask_verified_article_number(label, verified_sentinel)
      match = label.match(SINGLE_ARTICLE_CITATION_PATTERN)
      return label unless match

      number = normalize_article_number(match[:number])
      parts = [match.pre_match, match[0].sub(match[:number], verified_sentinel)]
      rest = match.post_match
      while (following = rest.match(SINGLE_ARTICLE_CITATION_PATTERN)) &&
            normalize_article_number(following[:number]) == number &&
            following.pre_match.match?(LABEL_SAME_ARTICLE_GAP) && following.post_match.match?(LABEL_UNIT_AFTER)
        parts << mask_label_point(following.pre_match, verified_sentinel) << following[0].sub(following[:number], verified_sentinel)
        rest = following.post_match
      end
      parts << mask_label_point(rest, verified_sentinel)
      parts.join
    end

    def mask_label_point(text, verified_sentinel)
      text.sub(LABEL_POINT_AFTER_COMMA) { "#{Regexp.last_match(1)}#{verified_sentinel}#{Regexp.last_match(3)}" }
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
