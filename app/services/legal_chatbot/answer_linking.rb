# frozen_string_literal: true

module LegalChatbot
  # LinkGuard and the article linkifier (FBL-061, extracted verbatim from
  # the orchestrator). Policy per citation link: a target retrieved this
  # turn is kept, a miscased fisconet id is normalized, a slug matching a
  # retrieved tax code's title is rewritten to its page, anything else is
  # degraded to plain text. The linkifier deliberately does NOT share the
  # citation gate's article prefix: the two have opposite safety polarities
  # (gate over-match rejects, linkifier over-match MINTS a citation).
  # law_anchor_numbers memoizes ::Article anchor lookups per instance.
  module AnswerLinking
    extend ActiveSupport::Concern

    # Shared pattern-library aliases (the library stays with the
    # orchestrator; lexical scope does not cross sibling concerns).
    ARTICLE_SPACE_SOURCE = Orchestrator::ARTICLE_SPACE_SOURCE
    LINKIFY_ARTICLE_PREFIX_SOURCE = Orchestrator::LINKIFY_ARTICLE_PREFIX_SOURCE

    def validate_answer_links(
      text,
      leg_articles,
      tax_articles,
      jur_cases,
      parl_docs = [],
      regional_docs = [],
      authoritative_docs = []
    )
      return text if text.blank?

      # Cheap normalization before validation: lower-cost models sometimes
      # omit the leading slash (`(laws/...)`) or use the retired `/wetgeving/`
      # route. Canonicalize those forms first; the guard below still strips a
      # slug or identifier that is not a permitted law page.
      text = normalize_internal_law_links(text)

      allowed_laws = Set.new
      allowed_article_pairs = Set.new
      (leg_articles + tax_articles).each do |article|
        numac = retrieved_source_numac(article)
        next if numac.blank?

        allowed_laws << numac
        article_number = retrieved_source_article_number(article)
        allowed_article_pairs << [numac, article_number] if article_number.present?
      end
      allowed_ecli = jur_cases.to_set { |c| c[:case_number].to_s }
      allowed_external = (parl_docs + regional_docs + authoritative_docs).filter_map do |document|
        (document[:url] || document['url']).presence
      end.to_set

      # Slug-repair lookup: fabricated /laws/<law-name> → retrieved tax code page
      tax_titles = {}
      tax_articles.each do |a|
        next if a[:numac].blank?

        tax_titles[a[:numac].to_s] = "#{a[:document_type]} #{a[:legislation_title]}".downcase
      end

      stripped = []
      rewritten = []

      # Bare parenthesized paths are not Markdown links, but some renderers
      # still recognize them as internal paths. Validate them under the same
      # source/known-NUMAC policy before leaving a canonical route in output.
      out = text.gsub(%r{(?<!\])(?<![\w/])\(/laws/([^)\s?#]+)([^)]*)\)}) do
        id = Regexp.last_match(1)
        suffix = Regexp.last_match(2)
        whole = Regexp.last_match(0)

        canonical_id = if id.match?(/\Afisconet_\d+\z/i) && allowed_laws.include?(id.upcase)
                         id.upcase
                       else
                         id
                       end
        anchor = link_article_number(suffix)

        valid_target = if suffix.include?('#')
                         anchor.present? && allowed_article_pairs.include?([canonical_id, anchor])
                       else
                         true
                       end
        if allowed_laws.include?(canonical_id) && valid_target
          if canonical_id != id
            rewritten << "#{id}→#{canonical_id}"
            "(/laws/#{canonical_id}#{suffix})"
          else
            whole
          end
        elsif canonical_id != id
          rewritten << "#{id}→#{id.upcase}"
          "(#{canonical_id}#{suffix})"
        else
          stripped << "/laws/#{id}#{suffix}"
          "(#{id}#{suffix})"
        end
      end

      out = out.gsub(%r{(?<!\!)\[([^\]]+)\]\((/(?:laws|jurisprudence)/([^)\s?#]+))([^)]*)\)}) do
        label = Regexp.last_match(1)
        path = Regexp.last_match(2)
        id = Regexp.last_match(3)
        suffix = Regexp.last_match(4)
        whole = Regexp.last_match(0)

        if path.start_with?('/jurisprudence/')
          if allowed_ecli.include?(id) || allowed_ecli.include?(CGI.unescape(id))
            whole
          else
            stripped << path
            label
          end
        elsif allowed_laws.include?(id)
          window = "#{label} #{Regexp.last_match.pre_match.last(100)} #{Regexp.last_match.post_match.first(120)}"
          rehome_law_anchor(whole, label, id, suffix, allowed_article_pairs, rewritten, stripped, window)
        elsif id.match?(/\Afisconet_\d+\z/i) && allowed_laws.include?(id.upcase)
          canonical_id = id.upcase
          canonical = "[#{label}](/laws/#{canonical_id}#{suffix})"
          rehome_law_anchor(canonical, label, canonical_id, suffix, allowed_article_pairs, rewritten, stripped)
        else
          # Fabricated slug (e.g. btw-wetboek): try to map it onto a retrieved
          # tax code by title tokens; else degrade to plain text.
          tokens = id.downcase.scan(/[[:alnum:]]+/).select { |token| token.length >= 3 } -
                   %w[wet wetboek code loi]
          repairs = tax_titles.filter_map do |numac, title|
            title_tokens = title.scan(/[[:alnum:]]+/)
            numac if tokens.any? { |token| title_tokens.include?(token) }
          end
          repair = repairs.one? ? repairs.first : nil
          if repair && label_article_number(label).blank? && !suffix.include?('#')
            rewritten << "#{path}→/laws/#{repair}"
            "[#{label}](/laws/#{repair})"
          else
            stripped << path
            label
          end
        end
      end

      # Empty/legacy internal destinations cannot be evidence. This covers
      # model output such as /wetgeving, /verwijzing, or the site root.
      out = out.gsub(%r{(?<!\!)\[([^\]]+)\]\((?:https?://(?:www\.)?wetwijzer\.be)?/(?:wetgeving|wetten|verwijzing)?/?(?:[?#][^)]*)?\)}) do
        stripped << Regexp.last_match(0)
        Regexp.last_match(1)
      end

      # Second pass: external links. Context blocks carry a LINK only when the
      # retrieved document has a URL. Models can fabricate plausible links on
      # any host, not only the known parliament/regional hosts, so keep an
      # external Markdown citation only when that exact URL was retrieved.
      out = out.gsub(%r{(?<!\!)\[([^\]]+)\]\((https?://([^/)\s]+)[^)]*)\)}) do
        label = Regexp.last_match(1)
        url = Regexp.last_match(2)
        if allowed_external.include?(url)
          Regexp.last_match(0)
        else
          stripped << url
          label
        end
      end

      if stripped.any? || rewritten.any?
        Rails.logger.info("[LinkGuard] stripped=#{stripped.uniq.size} rewritten=#{rewritten.uniq.size}")
      end
      out
    end

    # Canonicalize malformed internal law paths without trusting them. The
    # caller's LinkGuard validation then checks both Markdown and bare paths
    # against retrieved/known sources before they reach the renderer.
    def normalize_internal_law_links(text)
      normalized = text.gsub(%r{(?<!\!)\[([^\]]+)\]\(\s*https?://(?:www\.)?wetwijzer\.be/jurisprudence/([^)\s?#]+)([^)]*)\)}) do
        label = Regexp.last_match(1)
        id = Regexp.last_match(2)
        suffix = Regexp.last_match(3)
        "[#{label}](/jurisprudence/#{id}#{suffix})"
      end

      normalized = normalized.gsub(%r{(?<!\!)\[([^\]]+)\]\(\s*https?://(?:www\.)?wetwijzer\.be/(?:laws|wetgeving|wetten)/([^)\s?#]+)([^)]*)\)}) do
        label = Regexp.last_match(1)
        id = Regexp.last_match(2)
        suffix = Regexp.last_match(3)
        "[#{label}](/laws/#{id}#{suffix})"
      end

      normalized = normalized.gsub(%r{(?<!\!)\[([^\]]+)\]\(\s*(?:/)?(?:laws|wetgeving|wetten)/([^)\s?#]+)([^)]*)\)}) do
        label = Regexp.last_match(1)
        id = Regexp.last_match(2)
        suffix = Regexp.last_match(3)
        "[#{label}](/laws/#{id}#{suffix})"
      end

      # Some generated answers contain only a parenthesized relative path,
      # e.g. `(laws/2007002099)`, without a markdown label. Preserve that
      # formatting but make the path canonical so renderers can recognize it.
      normalized.gsub(%r{(?<!\])(?<![\w/])\((?:/)?(?:laws|wetgeving|wetten)/([^)\s?#]+)([^)]*)\)}) do
        id = Regexp.last_match(1)
        suffix = Regexp.last_match(2)
        "(/laws/#{id}#{suffix})"
      end
    end

    # Post-process: auto-linkify unlinked article references using found sources.
    # When the LLM writes "— Art. 37/2 AOW" without a markdown link, this method
    # wraps it in [Art. 37/2 AOW](/laws/numac#art-37-2) using the search results.
    # Already-linked references (inside [...](url)) are left untouched.
    # The model sometimes attaches a correct article anchor to the WRONG
    # retrieved law — both laws legitimately in context, e.g. 'Art. 37/2 van
    # de Arbeidsovereenkomstenwet' linked to the Sociaal Strafwetboek page.
    # The numac passes the retrieval check, so verify the ANCHOR: if the
    # article number does not exist under this law but exactly one other
    # retrieved law has it, re-home the link there. Ambiguity (0 or 2+ other
    # candidates) leaves the link untouched — never guess.
    # Generic law-name tokens that appear in many CORE_LAW_NUMACS short names
    # and cannot disambiguate on their own.
    REHOME_TOKEN_STOPLIST = %w[wetboek besluit koninklijk vlaamse waalse brussels codex decreet uitvoering].freeze

    def rehome_law_anchor(whole, label, numac, suffix, allowed_article_pairs, rewritten, stripped, _window = nil)
      anchor_num = link_article_number(suffix)
      label_anchor = label_article_number(label)
      if anchor_num.blank?
        # A retrieved law-level link is allowed only when its visible label is
        # law-level too. "Art. 25" linked to the law root is not an exact
        # article citation; degrade it so auto-linkification can rebuild it
        # from a retrieved article.
        return whole if !suffix.include?('#') && label_anchor.blank?

        reason = suffix.include?('#') ? 'malformed article anchor' : 'article label points to law root'
        stripped << "/laws/#{numac}#{suffix} (#{reason})"
        return label
      end

      # HIGHEST PRIORITY — honor the label. The visible text is what the user
      # is promised; the href must match it. When the label itself names a law
      # AND an article (e.g. "Art. 37/2 AOW"), and that law actually contains
      # that article, the link MUST point there — even if the current href's
      # own anchor happens to be valid in a DIFFERENT law. This catches the
      # class the anchor-existence check below cannot: label "Art. 37/2 AOW"
      # linked to /laws/2010A09589#art-201 (Sociaal Strafwetboek Art. 201
      # exists, so the old guard passed a link whose label named a different
      # law and a different article than its href).
      declared_numac, declared_anchor = label_declared_target(label)
      declared_pair = [declared_numac, declared_anchor]
      declared_pair = nil unless declared_numac && allowed_article_pairs.include?(declared_pair)

      if label_anchor.present? && label_anchor != anchor_num
        target = declared_pair if declared_pair && declared_anchor == label_anchor
        label_homes = allowed_article_pairs.select { |_law, article| article == label_anchor }
        target ||= label_homes.first if label_homes.one?
        unless target
          stripped << "/laws/#{numac}#{suffix} (label article mismatch)"
          return label
        end

        target_href = chatbot_article_href(target.first, target.last)
        rewritten << "/laws/#{numac}#{suffix}→#{target_href} (label)"
        return "[#{label}](#{target_href})"
      end

      if declared_pair && (declared_numac != numac || declared_anchor != anchor_num)
        target_href = chatbot_article_href(declared_numac, declared_anchor)
        rewritten << "/laws/#{numac}#{suffix}→#{target_href} (label)"
        return "[#{label}](#{target_href})"
      end

      if allowed_article_pairs.include?([numac, anchor_num])
        return whole unless numac.start_with?('FISCONET_')

        target_href = chatbot_article_href(numac, anchor_num)
        return whole if whole.include?(target_href)

        rewritten << "/laws/#{numac}#{suffix}→#{target_href} (language)"
        return "[#{label}](#{target_href})"
      end

      homes = allowed_article_pairs.select { |_law, article| article == anchor_num }
      unless homes.one?
        stripped << "/laws/#{numac}#{suffix} (article not retrieved)"
        return label
      end

      target = homes.first
      target_href = chatbot_article_href(target.first, target.last)
      rewritten << "/laws/#{numac}#{suffix}→#{target_href}"
      "[#{label}](#{target_href})"
    rescue StandardError => e
      # WARN, not DEBUG: a silent rescue here hid a NameError for two deploys.
      Rails.logger.warn("[LinkGuard] anchor re-home skipped: #{e.class}")
      stripped << "/laws/#{numac}#{suffix} (validation error)"
      label
    end

    def chatbot_article_href(numac, article_number)
      separator = numac.to_s.start_with?('FISCONET_') ? '_' : '-'
      language_query = numac.to_s.start_with?('FISCONET_') ? "?language_id=#{@language_id || 1}" : ''
      "/laws/#{numac}#{language_query}#art#{separator}#{article_number}"
    end

    def link_article_number(suffix)
      raw = suffix.to_s.match(/#art[-_]([^?&#\s)]+)/i)&.[](1)
      normalize_article_number(raw).presence
    end

    def label_article_number(label)
      # Deliberately NOT the gate's SINGLE_ARTICLE_CITATION_PATTERN: its number
      # token requires a leading digit, so every letter-leading article number
      # would parse as nil - and the Walloon codes use exactly those
      # ("Art. L1332-32" CDLD, "Art. D.I.1" CoDT, ~154k articles corpus-wide).
      # Swapping it in silently disabled rehome_law_anchor's label-mismatch
      # repair for those laws, shipping links whose label named one article and
      # whose href opened another (Opus review round 4, 2026-08-04).
      raw = label.to_s.match(/\b(?:Artikel|Article|Artt?)\.?\s*([[:alnum:]][\w\/.:-]*)/i)&.[](1)
      normalize_article_number(raw).presence
    end

    # If the link LABEL names both an article and a law it can be resolved to
    # (e.g. "Art. 37/2 AOW", "Artikel 15 W.Btw", "art. 1382 BW"), return
    # [numac, normalized_anchor] for that law+article — but ONLY when the law
    # is named unambiguously (exactly one abbreviation/core-law match) and it
    # actually contains that article. Returns nil otherwise (label has no law,
    # names several, or the article isn't in the named law → don't guess).
    def label_declared_target(label)
      return nil if label.blank?

      art_m = label.match(/\b(?:Artikel|Article|Artt?)\.?\s*([0-9][\w\/.:-]*)/i)
      return nil unless art_m

      anchor = normalize_article_number(art_m[1])
      hay = label.downcase

      candidates = ::Set.new
      ::Search::ArticleLookupService::LAW_ABBREVIATIONS.each do |abbr, numacs|
        candidates.merge(numacs) if hay.match?(/(?<![[:alnum:]])#{Regexp.escape(abbr)}(?![[:alnum:]])/)
      end
      ::LegalChatbot::CoreLawMappings::CORE_LAW_NUMACS.each do |core_numac, short_name|
        tokens = short_name.downcase.scan(/[[:alpha:]]{6,}/) - REHOME_TOKEN_STOPLIST
        candidates << core_numac if tokens.any? { |t| hay.include?(t) }
      end

      hits = candidates.select { |n| !n.start_with?('FISCONET_') && law_anchor_numbers(n).include?(anchor) }
      hits.size == 1 ? [hits.first, anchor] : nil
    rescue StandardError => e
      Rails.logger.warn("[LinkGuard] label parse skipped: #{e.class}")
      nil
    end

    # Normalized article-number set per numac (both languages — numbering is
    # language-invariant), memoized for the duration of one answer.
    def law_anchor_numbers(numac)
      @law_anchor_numbers ||= {}
      @law_anchor_numbers[numac] ||= ::Article.where(content_numac: numac)
                                              .where("article_title LIKE 'Art%'")
                                              .distinct.pluck(:article_title)
                                              .filter_map { |t|
                                                normalize_article_number(Regexp.last_match(1)) if t =~ /\AArt\.?\s*(\S+)/i
                                              }.to_set
    end

    def auto_linkify_articles(text, articles)
      return text if text.blank? || articles.blank?

      # Build a lookup by source identity. Federal/Fisconet articles use their
      # canonical local law route; hydrated regional results use the exact
      # external URL that LinkGuard already verified was retrieved this turn.
      source_lookup = {}
      articles.each do |art|
        numac = retrieved_source_numac(art)
        external_url = (art[:url] || art['url']).to_s.presence
        regional_url = external_url if (art[:source] || art['source']).present?
        next if numac.blank? && regional_url.blank?

        source_key = numac.presence || "external:#{regional_url}"

        source_lookup[source_key] ||= {
          numac: numac,
          law_title: (art[:law_title] || art['law_title'] || art[:title] || art['title']).to_s,
          aliases: Array(art[:aliases] || art['aliases']).map { |value| value.to_s.downcase },
          platform: (art[:source] || art['source']).to_s,
          articles: {}
        }
        art_title = (art[:article_title] || art['article_title']).to_s
        # Extract article number: "Art.37/2" → "37/2"
        art_num = art[:article_number] || art['article_number']
        art_num ||= art.dig(:metadata, :article_number) if art.respond_to?(:dig)
        art_num ||= art.dig(:metadata, 'article_number') if art.respond_to?(:dig)
        art_num ||= art.dig('metadata', :article_number) if art.respond_to?(:dig)
        art_num ||= art.dig('metadata', 'article_number') if art.respond_to?(:dig)
        art_num = art_num.presence || art_title.match(/Art\.?\s*([[:alnum:]][\w\/.:-]*)/i)&.[](1)
        # Importer-shaped titles end in sentence punctuation ("Art. 2bis.").
        # Keep meaningful internal separators such as 37/2 and VI.47, but do
        # not require the answer model to reproduce the terminal full stop.
        art_num = art_num.to_s.sub(/\.+\z/, '') if art_num.present?
        # Variant-titled records ("Art. 63_TOEKOMSTIG_RECHT") must linkify
        # the BASE article number the answer actually writes; the underscore
        # form otherwise captures the whole tail and matches nothing.
        art_num = art_num.to_s.sub(TextProcessing::ARTICLE_VARIANT_SUFFIX, '') if art_num.present?
        if art_num.present?
          source_lookup[source_key][:articles][art_num] = {
            title: art_title,
            url: regional_url
          }
        end
      end

      return text if source_lookup.empty?

      # Regroup by article NUMBER: the same number often exists in several
      # retrieved laws (Art. 37/2 lives in both the Arbeidsovereenkomstenwet
      # and the Sociaal Strafwetboek). Candidates keep retrieval-rank order.
      number_candidates = Hash.new { |h, k| h[k] = [] }
      source_lookup.each_value do |info|
        info[:articles].each do |art_num, article_info|
          target_url = article_info[:url].presence ||
                       chatbot_article_href(info[:numac], normalize_article_number(art_num))
          number_candidates[art_num] << {
            url: target_url,
            # Distinctive law-name tokens for context disambiguation
            tokens: linkify_disambiguation_tokens(info),
            title: info[:law_title]
          }
        end
      end

      linkified = text.dup
      link_count = 0

      # Longest article numbers first so "37/2" is linkified before a bare
      # "37" pattern walks the same text
      number_candidates.keys.sort_by { |k| -k.length }.each do |art_num|
        candidates = number_candidates[art_num]
        # Match "Art. 37/2" / "Artikel 37/2" / "Art. 4(8)" NOT already
        # inside [...](...). A parenthesized paragraph/point stays in the
        # visible label while the target remains the enclosing article URL.
        # Lookbehind (?<!\[) skips already-linked text; trailing lookaheads
        # reject matches whose number continues (digit, :3, /2, bis).
        #
        # No paragraph folding. It was tried (2026-07-31) so that
        # "Art. VI.23.4" would link to a retrieved "Art. VI.23", and it is
        # unsafe: enumerating all 56,932 distinct article titles in the corpus
        # shows multi-level dotted numbers are ARTICLES in their own right -
        # Art.9.2.1 (3,425 of them), Art.2.2.1.1 (2,593), Art.2.6.2.2.1
        # (1,504). Folding ".N" onto a compound parent would therefore label
        # article 9.2.1 as paragraph 1 of article 9.2. Distinguishing a
        # paragraph from a deeper article requires asking the corpus whether
        # the fuller number exists, which belongs in the citation-repair work,
        # not in a regex.
        # The lookahead class covers every separator the corpus uses inside an
        # article number, so a retrieved article can never match a PREFIX of a
        # longer one and leave the remainder dangling as text. Without the
        # hyphen a retrieved "Art. 100" matched inside "Art. 100-16" (a real
        # Sociaal Strafwetboek article) and produced "[Art. 100](...)-16";
        # without the dot a retrieved "Art. 3" did the same to "Art. 3.37".
        # The gate sees reference forms this pattern deliberately does NOT,
        # and that residual gap is the SAFE direction: a gate-visible,
        # linkifier-blind reference is withheld (fail-closed). Still withheld
        # on purpose, because each is an ordinary NL/FR word that would
        # otherwise mint citations out of prose: "Arts. 37" (arts =
        # physician), "Artikelen 37" / "Artikels 37" (goods), "Articles 37"
        # (items). Recovered here relative to the pre-series baseline:
        # "Artt. 37", "Artikel 37", "Article 37", bare "Art 37" and every
        # non-ASCII space variant. See
        # docs/ops/citation-minting-defect-2026-08-04.md.
        # The LEFT BOUNDARY is not optional. The gate's patterns are \b-anchored;
        # without an equivalent here the widened prefix matches inside ordinary
        # words - "huisarts. 3", "controlearts. 3", "wetsartikelen 3" - and
        # MINTS a citation out of prose the gate cannot even see, which is the
        # one direction that can fabricate a link (Opus review, 2026-08-04:
        # "huis[arts. 3](/laws/1996012650#art-3)" passed the guard). POSIX
        # [[:alpha:]] rather than \b because Ruby's \w is ASCII-only and the
        # corpus is full of accented words ("ecarts", "departs").
        # /i restored: without it the escaped article NUMBER matched
        # case-sensitively, so a retrieved "2bis" written as "2BIS" became
        # gate-visible and linkifier-blind - the very asymmetry this pattern
        # exists to close.
        pattern = %r{(?<!\[)((?<![[:alpha:]])#{LINKIFY_ARTICLE_PREFIX_SOURCE}#{ARTICLE_SPACE_SOURCE}*#{Regexp.escape(art_num)}(?!\d)(?![/:.\-]\d)(?![[:alpha:]])(?:#{ARTICLE_SPACE_SOURCE}*\(\d+\))?)(?!\]\()}i
        linkified.gsub!(pattern) do |match|
          match_data = Regexp.last_match
          # `(?<!\[)` only protects labels that start exactly with the article
          # token. A longer valid label such as `[zie Art. 2bis Drugswet](...)`
          # must also stay intact; nesting another Markdown link corrupts both.
          next match if inside_markdown_link_label?(match_data.pre_match, match_data.post_match)
          # Never linkify inside a blockquote. The quoted statute often makes
          # its own bare cross-reference ("op grond van artikel 1478"), and
          # turning that into a link forges an attribution: QuoteGuard runs
          # BEFORE this method, so the runtime accepted the quote, but the
          # offline audit then reads the injected link as the quote's source
          # and checks the words against the wrong article. That is exactly
          # why q2507 and q2806 were reported as unsupported quotations when
          # both are verbatim (diagnosed 2026-07-31).
          next match if inside_blockquote_line?(match_data.pre_match)

          # Disambiguate by the law named around the mention ("Art. 37/2 van
          # de Arbeidsovereenkomstenwet"). Retrieval rank is not legal evidence:
          # if the same number occurs in multiple retrieved laws and the nearby
          # text identifies none of them - or identifies MORE than one - leave
          # the reference unlinked. Accent-fold the window so a Dutch mention
          # can match a French-stored regional title and vice versa.
          window = ActiveSupport::Inflector.transliterate(
            "#{match_data.pre_match.last(100)} #{match_data.post_match.first(120)}".downcase
          )
          chosen = if candidates.one?
                     candidates.first
                   else
                     matching = candidates.select { |c| c[:tokens].any? { |t| window.include?(t) } }
                     matching.one? ? matching.first : nil
                   end
          next match unless chosen

          link_count += 1
          "[#{match}](#{chosen[:url]})"
        end
      end

      Rails.logger.info("[AutoLink] Linkified #{link_count} article references") if link_count.positive?
      linkified
    end

    # Tokens too generic to disambiguate one law from another retrieved law.
    LINKIFY_GENERIC_TITLE_TOKENS =
      %w[wetboek betreffende houdende koninklijk besluit decreet ordonnantie
         gouvernement regering arrete portant relatif relative].freeze
    # The answer model refers to regional laws by platform/region shorthand
    # ("Art. 55 §1 Wallex", "Vlaamse Codex") far more often than by the stored
    # official title, which may also be in the other national language.
    LINKIFY_REGIONAL_PLATFORM_TOKENS = {
      'wallex' => %w[wallex waals waalse wallonie wallonie wallon wallonne],
      'vlaam' => %w[vlaams vlaamse vlaanderen flamand flamande],
      'brussel' => %w[brussel brusselse bruxelles bruxellois bruxelloise],
      'bruxel' => %w[brussel brusselse bruxelles bruxellois bruxelloise]
    }.freeze

    def linkify_disambiguation_tokens(info)
      title = info[:law_title].to_s
      folded_title = ActiveSupport::Inflector.transliterate(title.downcase)
      tokens = folded_title.scan(/[[:alpha:]]{6,}/)
      # Years bridge the NL/FR title-language gap ("decreet van 5 december
      # 2024" must find the French-stored "Décret ... 5 décembre 2024").
      tokens += title.scan(/\b(?:19|20)\d{2}\b/)
      tokens += info[:aliases].map { |a| ActiveSupport::Inflector.transliterate(a) }
      platform_haystack = ActiveSupport::Inflector.transliterate(
        "#{info[:platform]} #{folded_title}".downcase
      )
      LINKIFY_REGIONAL_PLATFORM_TOKENS.each do |key, words|
        tokens += words if platform_haystack.include?(key)
      end
      tokens.uniq - LINKIFY_GENERIC_TITLE_TOKENS
    end

    def inside_blockquote_line?(prefix)
      line_start = prefix.to_s.rindex("\n")
      current_line = line_start ? prefix.to_s[(line_start + 1)..] : prefix.to_s
      current_line.to_s.match?(/\A[ ]{0,3}>/)
    end

    def inside_markdown_link_label?(prefix, suffix)
      open_bracket = prefix.rindex('[')
      close_bracket = prefix.rindex(']')
      return false unless open_bracket && (close_bracket.nil? || open_bracket > close_bracket)

      suffix.match?(/\A[^\]\n]*\]\([^)\n]+\)/)
    end
  end
end
