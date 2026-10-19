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

      stripped = []
      rewritten = []
      @rejected_article_link_labels = Set.new
      text = drop_unverified_german_language(text, german_original_pairs(leg_articles), rewritten)

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
      all_sources = leg_articles + tax_articles + jur_cases + parl_docs + regional_docs + authoritative_docs
      eu_records = all_sources.filter_map do |document|
        verified_eurlex_corpus_record(document) if eurlex_corpus_source?(document)
      end
      eu_urls = eu_records.group_by { |record| source_field(record, :url, 'url') }
      allowed_external = (parl_docs + regional_docs + authoritative_docs).filter_map do |document|
        next if eurlex_corpus_source?(document)

        (document[:url] || document['url']).presence
      end.to_set
      allowed_external.merge(eu_urls.keys)

      text = normalize_relative_eurlex_links(text, eu_records)
      text = move_eu_article_prefix_into_label(text, eu_urls)

      # Providers sometimes copy an external LINK without its scheme, or add
      # a slash before the complete URL (/https://...). Both are broken local
      # paths. Resolve only the exact already-retrieved destination; neither
      # a host-shaped path nor a malformed absolute URL may bypass LinkGuard.
      text = text.gsub(/(?<!!)\[([^\]]+)\]\(([^)\s]+)\)/) do |whole|
        label = Regexp.last_match(1)
        href = Regexp.last_match(2)
        next whole unless scheme_missing_external_link?(href)

        canonical_url = retrieved_external_link_url(href, allowed_external)
        if canonical_url && (!eu_urls.key?(canonical_url) || eu_urls[canonical_url].any? { |record| eurlex_label_matches_record?(label, record) })
          rewritten << 'external scheme'
          "[#{label}](#{canonical_url})"
        else
          stripped << href
          @rejected_article_link_labels << label if numbered_legal_link_label?(label)
          label
        end
      end

      # Slug-repair lookup: fabricated /laws/<law-name> → retrieved tax code page
      tax_titles = {}
      tax_articles.each do |a|
        next if a[:numac].blank?

        tax_titles[a[:numac].to_s] = "#{a[:document_type]} #{a[:legislation_title]}".downcase
      end

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
          if canonical_id == id
            whole
          else
            rewritten << "#{id}→#{canonical_id}"
            "(/laws/#{canonical_id}#{suffix})"
          end
        elsif canonical_id != id
          rewritten << "#{id}→#{id.upcase}"
          "(#{canonical_id}#{suffix})"
        else
          stripped << "/laws/#{id}#{suffix}"
          "(#{id}#{suffix})"
        end
      end

      out = out.gsub(%r{(?<!!)\[([^\]]+)\]\((/(?:laws|jurisprudence)/([^)\s?#]+))([^)]*)\)}) do
        label = Regexp.last_match(1)
        path = Regexp.last_match(2)
        id = Regexp.last_match(3)
        suffix = Regexp.last_match(4)
        whole = Regexp.last_match(0)

        result = if path.start_with?('/jurisprudence/')
                   if allowed_ecli.include?(id) || allowed_ecli.include?(CGI.unescape(id))
                     whole
                   else
                     stripped << path
                     label
                   end
                 elsif allowed_laws.include?(id)
                   after_text = Regexp.last_match.post_match.first(120)
                   rehome_law_anchor(whole, label, id, suffix, allowed_article_pairs, rewritten, stripped, after_text)
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
        if result == label &&
           (numbered_legal_link_label?(label) || (path.start_with?('/laws/') && link_article_number(suffix).present?))
          @rejected_article_link_labels << label
        end
        result
      end

      # Empty/legacy internal destinations cannot be evidence. This covers
      # model output such as /wetgeving, /verwijzing, or the site root.
      out = out.gsub(%r{(?<!!)\[([^\]]+)\]\((?:https?://(?:www\.)?wetwijzer\.be)?/(?:wetgeving|wetten|verwijzing)?/?(?:[?#][^)]*)?\)}) do
        stripped << Regexp.last_match(0)
        Regexp.last_match(1)
      end

      # Second pass: external links. Context blocks carry a LINK only when the
      # retrieved document has a URL. Models can fabricate plausible links on
      # any host, not only the known parliament/regional hosts, so keep an
      # external Markdown citation only when that exact URL was retrieved.
      out = out.gsub(%r{(?<!!)\[([^\]]+)\]\((https?://([^/)\s]+)[^)]*)\)}) do
        label = Regexp.last_match(1)
        url = Regexp.last_match(2)
        if allowed_external.include?(url) &&
           (!eu_urls.key?(url) || eu_urls[url].any? { |record| eurlex_label_matches_record?(label, record) })
          Regexp.last_match(0)
        else
          stripped << url
          @rejected_article_link_labels << label if numbered_legal_link_label?(label)
          label
        end
      end

      Rails.logger.info("[LinkGuard] stripped=#{stripped.uniq.size} rewritten=#{rewritten.uniq.size}") if stripped.any? || rewritten.any?
      out
    end

    def numbered_legal_link_label?(label)
      label_article_number(label).present? || label.to_s.match?(AnswerGuards::EURLEX_UNIT_CITATION_PATTERN)
    end

    # An exact official URL does not make its label true. A recital or a
    # judgment paragraph must not be presented as an article, and a retrieved
    # Article 6 in one work cannot attest "Article 6" of another named work.
    # Generic document labels remain links, but numbered legal labels must
    # contain only the canonical identity and ordinary paragraph qualifiers.
    def eurlex_label_matches_record?(label, record)
      return false unless eurlex_label_classification_valid?(label, record)

      article = label.to_s.match(AnswerGuards::SINGLE_ARTICLE_CITATION_PATTERN)
      unit = label.to_s.match(AnswerGuards::EURLEX_UNIT_CITATION_PATTERN)
      return false if article && unit

      names = eurlex_record_names(record) + eurlex_canonical_short_names(record)
      canonical_label = article || unit ? eurlex_label_without_act_variants(label, record) : label.to_s
      return false unless canonical_label

      canonical_label = eurlex_label_without_source_qualifiers(canonical_label, record) if article || unit
      return false unless canonical_label

      identifiers = canonical_label.scan(%r{\b(?:ECLI:EU:[A-Z]+:\d{4}:\d+|[036]\d{4}[A-Z]{1,2}\d{4}(?:-\d{8})?|[CTF]-\d{1,5}/\d{2,4}|(?:1[89]\d{2}|20\d{2})/\d{1,5}(?:/(?:EU|EC|EG|EEG|EEC|UE|CE|CEE|EWG|EGKS))?)\b}i)
      # Generic document/holding labels are not a loophole for relabelling the
      # exact source as a different named case, ECLI or CELEX edition.
      return false unless identifiers.all? do |identifier|
        names.any? { |name| name.match?(/(?<![[:alnum:]])#{Regexp.escape(identifier)}(?![[:alnum:]])/i) }
      end
      return true unless article || unit

      kind = if article
               'article'
             elsif unit[:prefix].match?(/\A(?:overweging|consid[ée]rant|recital|Erw[aä]gungsgrund)\z/i)
               'recital'
             else
               'paragraph'
             end
      number = normalize_article_number(article ? article[:number] : unit[:number])
      return false unless kind == source_field(record, :kind, 'kind') &&
                          number == normalize_article_number(source_field(record, :unit_number, 'unit_number'))

      # Removing numeric paragraph qualifiers must not erase an explicitly
      # conflicting act/case number. "Planet49 / C-999/17" is NOT Planet49's
      # C-673/17 simply because both numbers disappear in the residue pass.

      remainder = canonical_label.dup
      names.sort_by { |name| -name.length }.each do |name|
        remainder.gsub!(/(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/i, '')
      end
      remainder.sub!(article ? article[0] : unit[0], '')
      case source_field(record, :document_type, 'document_type')
      when 'judgment'
        remainder.gsub!(/\b(?:arrest|judgment|jugement|arr[êe]t|urteil)\b/i, '')
      when 'order'
        remainder.gsub!(/\b(?:beschikking|order|ordonnance|beschluss)\b/i, '')
      when 'advocate_general_opinion'
        remainder.gsub!(/\b(?:conclusie|conclusions|opinion|Schlussantr[aä]ge)\b/i, '')
      end
      if source_field(record, :historical, 'historical') == true
        remainder.gsub!(/\b(?:historisch(?:e)?|historical|historique|historisch(?:en)?|oorspronkelijk(?:e)?|origine(?:le)?|original(?:e)?|initial(?:e)?|urspr[üu]nglich(?:e|en)?|editie|edition|fassung|bron|source|quelle)\b/i, '')
      end
      remainder.gsub!(/\b(?:par(?:agraphs?|agraphe?s?|agraaf)?|paragrafen|lid|leden|alinea|points?|punt(?:en)?|abs(?:atz|ätze)?|buchstabe|van|de|du|of|der|des|het|the|le|la|zie|see|voir|siehe|CELEX)\b/i, '')
      remainder.gsub!(%r{[§\d\s.,:;/()\[\]"'’”>—–-]}, '')
      remainder.gsub!(/\b[a-z]\b/i, '')
      remainder.blank?
    end

    # The consolidated 261/2004 title contains only its CELEX. Its reviewed
    # canonical designation is EC, never EU. This supplies a label alias only,
    # after the exact sealed legislative work has been identified; it cannot
    # supply source text, a missing article or evidence of current validity.
    CANONICAL_EURLEX_ACT_SCOPES = { '32004R0261' => 'ec' }.freeze
    # These reviewed short titles identify only these exact legislative works.
    # They do not supply text, a missing unit, a translation or current validity.
    CANONICAL_EURLEX_SHORT_NAMES = {
      '32004R0261' => ['Passagiersverordening'].freeze,
      '32022R2065' => %w[DSA digitaledienstenverordening].freeze
    }.freeze

    def eurlex_canonical_short_names(record)
      return [] unless source_field(record, :source_kind, 'source_kind') == 'legislation'

      identity = source_field(record, :celex, 'celex').to_s.match(/\A[03](\d{4}[RL]\d{4})(?:-\d{8})?\z/)
      identity ? CANONICAL_EURLEX_SHORT_NAMES.fetch("3#{identity[1]}", []) : []
    end

    def eurlex_label_without_source_qualifiers(label, record)
      return label unless source_field(record, :source_kind, 'source_kind') == 'legislation'

      language = source_field(record, :language, 'language').to_s.downcase
      remainder = label.gsub(/\((?<language>NL|FR|DE|EN)(?:-versie)?\)/i) do
        return nil unless Regexp.last_match[:language].downcase == language

        ''
      end
      remainder.gsub(/\b(?:oorspronkelijke|original|originale|urspr[üu]ngliche)\s+(?:(?<language>Nederlandstalige|Dutch|n[ée]erlandaise|niederl[aä]ndische)\s+)?(?:editie|edition|Fassung)\b/i) do
        # An unchanged original recital is still an original source even when
        # its verified certificate permits it outside the historical lane.
        return nil unless source_field(record, :celex, 'celex').to_s.match?(/\A3\d{4}[RL]\d{4}\z/) &&
                          source_field(record, :kind, 'kind') == 'recital' &&
                          source_field(record, :correction_status, 'correction_status') == 'verified_unchanged_recitals' &&
                          source_field(record, :correction_verification, 'correction_verification') == 'explicit_other_language_correction_closure'
        return nil if Regexp.last_match[:language] && language != 'nl'

        ''
      end
    end

    def eurlex_label_without_act_variants(label, record)
      # An exact official title can itself name an act that it amends. Keep
      # its existing literal-name authority; do not reinterpret that embedded
      # title text as an independently asserted identity of this article.
      remainder = label.to_s.dup
      %i[law_title title].each do |key|
        name = source_field(record, key, key.to_s).to_s
        remainder.gsub!(/(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/i, '') if name.present?
      end
      Array(source_field(record, :aliases, 'aliases')).each do |name|
        match = name.to_s.match(AnswerGuards::EURLEX_ACT_IDENTIFIER_PATTERN)
        next unless match && match[0] == name

        remainder.gsub!(/(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/i, '')
      end
      remainder.gsub(AnswerGuards::EURLEX_ACT_IDENTIFIER_PATTERN) do |variant|
        match = Regexp.last_match
        identity = source_field(record, :celex, 'celex').to_s.match(/\A[03](\d{4}[RL]\d{4})(?:-\d{8})?\z/)
        return nil unless identity && source_field(record, :source_kind, 'source_kind') == 'legislation'

        base = "3#{identity[1]}"
        return nil unless EuDiscovery.named_act_identifiers(variant) == [base]

        claimed = eurlex_named_act_identities(variant).first&.last
        return nil if match.post_match.match?(%r{\A/[[:alpha:]]})

        scopes = eurlex_record_names(record).flat_map do |name|
          name.to_s.to_enum(:scan, AnswerGuards::EURLEX_ACT_IDENTIFIER_PATTERN).filter_map do
            known = Regexp.last_match[0]
            eurlex_named_act_identities(known).first&.last if EuDiscovery.named_act_identifiers(known) == [base]
          end
        end.uniq
        scopes = [CANONICAL_EURLEX_ACT_SCOPES[base]].compact if scopes.empty?
        return nil if claimed && scopes != [claimed]

        ''
      end
    end

    def eurlex_label_classification_valid?(label, record)
      document_type = source_field(record, :document_type, 'document_type').to_s
      is_case = source_field(record, :source_kind, 'source_kind') == 'jurisprudence' ||
                %w[judgment order advocate_general_opinion].include?(document_type)
      return false if is_case && label.to_s.match?(/\A\s*(?:wet|loi|gesetz|statute|regulation|verordening|r[èe]glement|verordnung)\b/i)

      judgment_label = label.to_s.match?(/\b(?:arrest|judgment|jugement|arr[êe]t|urteil)\b/i)
      order_label = label.to_s.match?(/\b(?:beschikking|order|ordonnance|beschluss)\b/i)
      return false if document_type == 'advocate_general_opinion' && (judgment_label || order_label)
      return false if document_type == 'judgment' && order_label
      return false if document_type == 'order' && judgment_label
      return false if %w[judgment order].include?(document_type) &&
                      label.to_s.match?(/\A\s*(?:conclusie|conclusions|opinion|Schlussantr[aä]ge)\b/i)
      return false if source_field(record, :historical, 'historical') == true &&
                      label.to_s.match?(/\b(?:current|latest|actueel|huidig(?:e)?|geldend(?:e)?|bijgewerkt(?:e)?|actuel(?:le)?|aktuell(?:e)?|corrected)\b/i)

      true
    end

    def scheme_missing_external_link?(href)
      href.to_s.match?(%r{\A/{0,2}(?:[a-z0-9-]+\.)+[a-z]{2,}(?:/|\z)}i) || malformed_absolute_external_link?(href)
    end

    def malformed_absolute_external_link?(href)
      href.to_s.match?(%r{\A/+https?://}i)
    end

    def relative_eurlex_link?(href)
      href.to_s.match?(%r{\A/legal-content(?:/|[?#]|\z)}i)
    end

    # Link-only normalization can also replay an already guarded answer without
    # touching native links. Never hydrate or infer evidence from its URL. The
    # exact path, query and fragment must resolve to one sealed EU record, and
    # the label must independently identify its actual act, unit and edition.
    def normalize_relative_eurlex_links(text, sources)
      records = sources.filter_map do |source|
        verified_eurlex_corpus_record(source) if eurlex_corpus_source?(source)
      end
      urls = records.group_by { |record| source_field(record, :url, 'url') }
      text.to_s.gsub(/(?<!!)\[([^\]]+)\]\(([^)\s]+)\)/) do |whole|
        label = Regexp.last_match(1)
        href = Regexp.last_match(2)
        next whole unless relative_eurlex_link?(href)

        canonical = retrieved_relative_eurlex_link_url(href, urls)
        if canonical && urls[canonical].any? { |record| eurlex_label_matches_record?(label, record) }
          "[#{label}](#{canonical})"
        else
          (@rejected_article_link_labels ||= Set.new) << label if numbered_legal_link_label?(label)
          label
        end
      end
    end

    # "Artikel [3 lid 1](...#art_3)" was refused although the target was the
    # exact admitted unit (2026-10-17 depth runs). For a link to one verified
    # EU article whose label starts with that same article number, move the
    # "Artikel " left outside the link into its label. Points and letters are
    # never touched, and a label carrying any point or letter qualifier keeps
    # its prefix outside: "Artikel [7(1)(z) AVG](...)" is not promoted into a
    # reference (Codex review 18:24, 18:47 and 19:03).
    EU_LABEL_LETTER_QUALIFIER_PATTERN = /\(\s*\p{L}{1,4}\s*\)|(?:\A|[\s,;(])\p{L}{1,4}\)|\b(?:onder|sub|punt|punten|point|points|littera|lit|Buchstabe|Buchst|letter|alinéa|Unterabsatz|Satz)\b/iu
    def move_eu_article_prefix_into_label(text, eu_urls)
      text.to_s.gsub(/(?<prefix>\b(?:Artikel|Article|Art\.)\s)(?<!!)\[(?<label>\d+\b[^\]]*)\]\((?<href>[^)\s]+)\)/) do |whole|
        match = Regexp.last_match
        number = match[:href][/#(?:art|article)_(\d+)\z/, 1]
        next whole unless eu_urls[match[:href]].present? && number && match[:label][/\A\d+/] == number
        next whole if match[:label].match?(EU_LABEL_LETTER_QUALIFIER_PATTERN)

        "[#{match[:prefix].strip} #{match[:label]}](#{match[:href]})"
      end
    end

    def retrieved_relative_eurlex_link_url(href, eu_urls)
      candidates = eu_urls.filter_map do |url, records|
        next unless records.uniq.one?

        uri = URI.parse(url)
        next unless uri.is_a?(URI::HTTPS) && uri.host == 'eur-lex.europa.eu'

        relative = uri.request_uri
        relative += "##{uri.fragment}" if uri.fragment
        url if href == relative
      end
      candidates.one? ? candidates.first : nil
    rescue URI::InvalidURIError
      nil
    end

    def retrieved_external_link_url(href, allowed_urls)
      if malformed_absolute_external_link?(href)
        # Exactly one spurious slash, with every byte of the admitted URL
        # preserved. Do not infer a host, scheme, locale, query or fragment.
        candidate = href.delete_prefix('/')
        return candidate if candidate.match?(%r{\Ahttps?://}) && allowed_urls.include?(candidate)

        return nil
      end
      return href if allowed_urls.include?(href)
      return unless scheme_missing_external_link?(href)

      host_path = href.sub(%r{\A/{0,2}}, '')
      allowed_urls.find do |url|
        url.start_with?('https://') && url.delete_prefix('https://') == host_path
      end
    end

    # A law path with ?language_id=3, the German text of the page on
    # gesetzguide, in a Markdown link, a bare parenthesized path or prose.
    GERMAN_LANGUAGE_LAW_PATH = %r{/laws/([^)\s?#]+)\?language_id=3(#[^)\s]*)?(?=[)\s]|\z)}

    # ?language_id=3 stays only on a link to the article of a retrieved
    # binding German original (german_original_pairs). On any other target
    # the parameter is dropped and the anchor kept, so a citation of a
    # retrieved French or Dutch article that only carries the wrong parameter
    # is not blocked by CitationGuard, which verifies language 3 against the
    # same pairs. Logged under rewritten, tagged (language).
    def drop_unverified_german_language(text, german_pairs, rewritten)
      text.gsub(GERMAN_LANGUAGE_LAW_PATH) do
        whole = Regexp.last_match(0)
        id = Regexp.last_match(1)
        anchor = Regexp.last_match(2).to_s
        number = link_article_number(anchor)
        next whole if number && german_pairs.include?([id, number])

        rewritten << "#{whole}→/laws/#{id}#{anchor} (language)"
        "/laws/#{id}#{anchor}"
      end
    end

    # Canonicalize malformed internal law paths without trusting them. The
    # caller's LinkGuard validation then checks both Markdown and bare paths
    # against retrieved/known sources before they reach the renderer.
    def normalize_internal_law_links(text)
      normalized = text.gsub(%r{(?<!!)\[([^\]]+)\]\(\s*https?://(?:www\.)?wetwijzer\.be/jurisprudence/([^)\s?#]+)([^)]*)\)}) do
        label = Regexp.last_match(1)
        id = Regexp.last_match(2)
        suffix = Regexp.last_match(3)
        "[#{label}](/jurisprudence/#{id}#{suffix})"
      end

      normalized = normalized.gsub(%r{(?<!!)\[([^\]]+)\]\(\s*https?://(?:www\.)?wetwijzer\.be/(?:laws|wetgeving|wetten)/([^)\s?#]+)([^)]*)\)}) do
        label = Regexp.last_match(1)
        id = Regexp.last_match(2)
        suffix = Regexp.last_match(3)
        "[#{label}](/laws/#{id}#{suffix})"
      end

      # "https://laws/<numac>#art-35": the relative LINK with a scheme in
      # front, "laws" taken for a host (2026-10-17 depth run). No such host
      # exists; the same path is then validated like any internal link.
      normalized = normalized.gsub(%r{(?<!!)\[([^\]]+)\]\(\s*(?:https?://|/)?(?:laws|wetgeving|wetten)/([^)\s?#]+)([^)]*)\)}) do
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
    # retrieved law, with both laws legitimately in context, e.g. 'Art. 37/2 van
    # de Arbeidsovereenkomstenwet' linked to the Sociaal Strafwetboek page.
    # The numac passes the retrieval check, so verify the ANCHOR: if the
    # article is missing in this law, do not silently substitute an identically
    # numbered article from another law. Only same-law number normalization
    # is safe; changing a NUMAC changes the legal authority being claimed.
    # Generic law-name tokens that appear in many CORE_LAW_NUMACS short names
    # and cannot disambiguate on their own.
    REHOME_TOKEN_STOPLIST = %w[wetboek besluit koninklijk vlaamse waalse brussels codex decreet uitvoering].freeze

    def rehome_law_anchor(whole, label, numac, suffix, allowed_article_pairs, rewritten, stripped, after_text = nil)
      anchor_num = link_article_number(suffix)
      label_anchor = label_article_number(label)
      # Resolve the named law before consulting which law happens to contain
      # this article. Filtering candidates by article existence first erased
      # a named-but-missing law, and let another law rescue the same number.
      named_laws = label_declared_law_candidates(label)
      if named_laws.any? && !named_laws.include?(numac)
        stripped << "/laws/#{numac}#{suffix} (label law mismatch)"
        return label
      end
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

      if label_anchor.present? && label_anchor != anchor_num
        target = [numac, label_anchor]
        unless allowed_article_pairs.include?(target)
          stripped << "/laws/#{numac}#{suffix} (label article mismatch)"
          return label
        end

        target_href = chatbot_article_href(target.first, target.last)
        rewritten << "/laws/#{numac}#{suffix}→#{target_href} (label)"
        return "[#{label}](#{target_href})"
      end

      if allowed_article_pairs.include?([numac, anchor_num])
        if law_date_mismatch?(after_text, numac)
          stripped << "/laws/#{numac}#{suffix} (law date mismatch)"
          return label
        end
        return whole unless numac.start_with?('FISCONET_')

        target_href = chatbot_article_href(numac, anchor_num)
        return whole if whole.include?(target_href)

        rewritten << "/laws/#{numac}#{suffix}→#{target_href} (language)"
        return "[#{label}](#{target_href})"
      end

      stripped << "/laws/#{numac}#{suffix} (article not retrieved)"
      label
    rescue StandardError => e
      # WARN, not DEBUG: a silent rescue here hid a NameError for two deploys.
      Rails.logger.warn("[LinkGuard] anchor re-home skipped: #{e.class}")
      stripped << "/laws/#{numac}#{suffix} (validation error)"
      label
    end

    # A law named by its date in the text that follows an article link or
    # mention, within the sentence: "de la loi du 3 juillet 1978", "van de
    # wet van 3 juli 1978", "des Gesetzes vom 3. Juli 1978". The date of a
    # Belgian act is the first eight digits of its NUMAC, so a named date that
    # disagrees with the target's NUMAC names another law than the one linked,
    # and the link is withheld rather than minted or kept (German answers v4,
    # q0046: "Art. 30, § 2 de la loi du 3 juillet 1978" was linked to Art. 30
    # of the annual-holidays decree 1967033001, the one retrieved law with an
    # Art. 30; the Employment Contracts Act had not been retrieved). Only the
    # text after the mention is read, and never past a sentence end: a date
    # before it or in the next sentence may name another law. A NUMAC that
    # does not start with a date (2013A11134) is not checked.
    LAW_WORD_SOURCE = '(?:lois?|décrets?|ordonnances?|arrêtés?|wet(?:ten)?|decre+t(?:en)?|besluit(?:en)?|ordonnanties?|' \
                      'Gesetz(?:es)?|Dekret(?:s|es)?|Erlass(?:es)?|Verordnung|acts?)'
    NAMED_LAW_DATE = /
      \A(?:(?!\.\s+[[:upper:]])[^;\n]){0,60}?(?<![[:alpha:]])#{LAW_WORD_SOURCE}(?![[:alpha:]])
      (?:(?!\.\s+[[:upper:]])[^;\n]){0,40}?(?<![[:alpha:]])(?:du|van|vom|of)\s+
      (?<day>\d{1,2})(?:er|ste|de|\.)?[ \t\u00a0]+(?<month>[[:alpha:]]+)[ \t\u00a0]+(?<year>1[89]\d{2}|20\d{2})(?!\d)
    /ix
    LAW_DATE_MONTHS = {
      'janvier' => 1, 'fevrier' => 2, 'mars' => 3, 'avril' => 4, 'mai' => 5, 'juin' => 6, 'juillet' => 7, 'aout' => 8,
      'septembre' => 9, 'octobre' => 10, 'novembre' => 11, 'decembre' => 12,
      'januari' => 1, 'februari' => 2, 'maart' => 3, 'april' => 4, 'mei' => 5, 'juni' => 6, 'juli' => 7, 'augustus' => 8,
      'september' => 9, 'oktober' => 10, 'november' => 11, 'december' => 12,
      'januar' => 1, 'februar' => 2, 'marz' => 3, 'august' => 8, 'dezember' => 12,
      'january' => 1, 'february' => 2, 'march' => 3, 'may' => 5, 'june' => 6, 'july' => 7, 'october' => 10
    }.freeze

    def law_date_mismatch?(after_text, numac)
      target = numac.to_s[/\A(?:1[89]\d{2}|20\d{2})(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])/]
      return false unless target

      named = named_law_date(after_text)
      named.present? && named != target
    end

    # "YYYYMMDD" of the law the text names, nil when it names none.
    def named_law_date(text)
      match = text.to_s.match(NAMED_LAW_DATE)
      return nil unless match

      month = LAW_DATE_MONTHS[ActiveSupport::Inflector.transliterate(match[:month]).downcase]
      return nil unless month

      format('%<year>04d%<month>02d%<day>02d', year: match[:year].to_i, month: month, day: match[:day].to_i)
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
      match = label.to_s.match(%r{\b(?:Artikel|Article|Artt?)\.?\s*([[:alnum:]][\w/.:-]*)}i)
      raw = match&.[](1)
      # "Art. 6:13.9°" cites point 9° of Art. 6:13. The explicit ° is
      # essential: without it, dotted numbers remain distinct articles.
      raw = raw.sub(/\.\d+\z/, '') if raw && match.post_match.match?(/\A[[:space:]\u00A0\u2007\u202F]*°/)
      normalize_article_number(raw).presence
    end

    # If the link LABEL names both an article and a law it can be resolved to
    # (e.g. "Art. 37/2 AOW", "Artikel 15 W.Btw", "art. 1382 BW"), return
    # [numac, normalized_anchor] for that law+article, but ONLY when the law
    # is named unambiguously (exactly one abbreviation/core-law match) and it
    # actually contains that article. Returns nil otherwise (label has no law,
    # names several, or the article isn't in the named law → don't guess).
    def label_declared_target(label)
      return nil if label.blank?

      art_m = label.match(%r{\b(?:Artikel|Article|Artt?)\.?\s*([0-9][\w/.:-]*)}i)
      return nil unless art_m

      anchor = normalize_article_number(art_m[1])
      candidates = label_declared_law_candidates(label)
      hits = candidates.select { |n| !n.start_with?('FISCONET_') && law_anchor_numbers(n).include?(anchor) }
      hits.size == 1 ? [hits.first, anchor] : nil
    rescue StandardError => e
      Rails.logger.warn("[LinkGuard] label parse skipped: #{e.class}")
      nil
    end

    # Law identity is independent of whether an article is present in that
    # law. Shared with quote-attribution repair and verification.
    def label_declared_law_candidates(label)
      hay = label.to_s.downcase
      candidates = ::Set.new
      ::Search::ArticleLookupService::LAW_ABBREVIATIONS.each do |abbr, numacs|
        candidates.merge(numacs) if hay.match?(/(?<![[:alnum:]])#{Regexp.escape(abbr)}(?![[:alnum:]])/)
      end
      core_matches = {}
      ::LegalChatbot::CoreLawMappings::CORE_LAW_NUMACS.each do |core_numac, short_name|
        tokens = short_name.downcase.scan(/[[:alpha:]]{6,}/) -
                 REHOME_TOKEN_STOPLIST - LINKIFY_GENERIC_TITLE_TOKENS - LAW_DATE_MONTHS.keys -
                 %w[wijziging uitvoering betreffende inzake]
        matched = tokens.any? && tokens.all? do |token|
          hay.match?(/(?<![[:alnum:]])#{Regexp.escape(token)}(?![[:alnum:]])/)
        end
        core_matches[core_numac] = tokens.sum(&:length) if matched
      end
      # "Sociaal Strafwetboek" also contains "Strafwetboek", but it is a
      # different code. Prefer the complete, more specific title; equal
      # specificity remains ambiguous rather than choosing by catalog order.
      best_match = core_matches.values.max
      candidates.merge(core_matches.select { |_numac, score| score == best_match }.keys)
      candidates
    end

    # nil means no law was named; an empty set means a name was supplied but
    # could not be resolved. Do not collapse those states and let an unknown
    # named law borrow a different law's same-number article.
    def plain_quote_named_laws(block, attribution)
      tail = block.to_s[attribution.end(0)..].to_s
      qualifiers = tail.gsub(/\b(?:par(?:agraph|agraphe|agraaf)?|lid|alinea|point|punt|wet|loi|gesetz|act)\b/i, '')
                       .gsub(/[§\d\s.,;()\[\]"'’”>]/, '')
      return nil if qualifiers.blank?

      label_declared_law_candidates(block.to_s[attribution.begin(0)..])
    end

    # Normalized article-number set per numac (both site languages; numbering
    # is language-invariant), memoized for the duration of one answer. A
    # German row's articles (updater v0.894) have no anchor on the NL and FR
    # pages, so they never make a link.
    def law_anchor_numbers(numac)
      @law_anchor_numbers ||= {}
      @law_anchor_numbers[numac] ||= ::Article.in_site_languages.where(content_numac: numac)
                                              .where("article_title LIKE 'Art%'")
                                              .distinct.pluck(:article_title)
                                              .filter_map do |t|
                                                normalize_article_number(Regexp.last_match(1)) if t =~ /\AArt\.?\s*(\S+)/i
                                              end.to_set
    end

    def auto_linkify_articles(text, articles)
      return text if text.blank? || articles.blank?

      text = auto_linkify_eurlex_unit_lists(text, articles)
      text = auto_linkify_eurlex_units(text, articles)

      # Build a lookup by source identity. Federal/Fisconet articles use their
      # canonical local law route; hydrated regional results use the exact
      # external URL that LinkGuard already verified was retrieved this turn.
      source_lookup = {}
      articles.each do |art|
        if eurlex_corpus_source?(art)
          art = verified_eurlex_corpus_record(art)
          next unless art && source_field(art, :kind, 'kind') == 'article'
        end

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
          eu_record: eurlex_corpus_source?(art) ? art : nil,
          articles: {}
        }
        art_title = (art[:article_title] || art['article_title']).to_s
        # Extract article number: "Art.37/2" → "37/2"
        art_num = art[:article_number] || art['article_number']
        art_num ||= art.dig(:metadata, :article_number) if art.respond_to?(:dig)
        art_num ||= art.dig(:metadata, 'article_number') if art.respond_to?(:dig)
        art_num ||= art.dig('metadata', :article_number) if art.respond_to?(:dig)
        art_num ||= art.dig('metadata', 'article_number') if art.respond_to?(:dig)
        art_num = art_num.presence || art_title.match(%r{Art\.?\s*([[:alnum:]][\w/.:-]*)}i)&.[](1)
        # Importer-shaped titles end in sentence punctuation ("Art. 2bis.").
        # Keep meaningful internal separators such as 37/2 and VI.47, but do
        # not require the answer model to reproduce the terminal full stop.
        art_num = art_num.to_s.sub(/\.+\z/, '') if art_num.present?
        # Variant-titled records ("Art. 63_TOEKOMSTIG_RECHT") must linkify
        # the BASE article number the answer actually writes; the underscore
        # form otherwise captures the whole tail and matches nothing.
        art_num = art_num.to_s.sub(TextProcessing::ARTICLE_VARIANT_SUFFIX, '') if art_num.present?
        next unless art_num.present?

        source_lookup[source_key][:articles][art_num] = {
          title: art_title,
          url: regional_url
        }
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
            source_key: info[:numac].presence || "external:#{article_info[:url]}",
            url: target_url,
            # Distinctive law-name tokens for context disambiguation
            tokens: linkify_disambiguation_tokens(info),
            title: info[:law_title],
            eu_record: info[:eu_record]
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
        pattern = %r{(?<!\[)((?<![[:alpha:]])#{LINKIFY_ARTICLE_PREFIX_SOURCE}#{ARTICLE_SPACE_SOURCE}*#{Regexp.escape(art_num)}(?!\d)(?![/:.-]\d)(?![[:alpha:]])(?:#{ARTICLE_SPACE_SOURCE}*\(\d+\))?)(?!\]\()}i
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
          # LinkGuard removed an explicit law/article claim. Its now-bare
          # label must not be minted into a different authority solely because
          # another retrieved law has the same number. Repeated identical
          # labels fail closed too; a regeneration can supply an exact link.
          next match if rejected_article_link_label?(match_data)

          # Disambiguate by the law named around the mention ("Art. 37/2 van
          # de Arbeidsovereenkomstenwet"). Retrieval rank is not legal evidence:
          # if the same number occurs in multiple retrieved laws and the nearby
          # text identifies none of them - or identifies MORE than one - leave
          # the reference unlinked. Accent-fold the window so a Dutch mention
          # can match a French-stored regional title and vice versa.
          # A named law after this mention binds it. A different citation
          # earlier in the paragraph must not bind every subsequent number.
          nearby_prefix = match_data.pre_match.last(100).split(/;|\n/).last.to_s
          named_tail = match_data.post_match.split(/;|\n|(?<![[:alpha:]])(?:Artikel|Article|Artt?)\.?\s*[[:alnum:]]/i).first.to_s.first(120)
          window = ActiveSupport::Inflector.transliterate("#{nearby_prefix} #{named_tail}".downcase)
          named_laws = label_declared_law_candidates("#{match} #{named_tail}")
          identified_sources = source_lookup.filter_map do |key, info|
            key if linkify_disambiguation_tokens(info).any? do |token|
              window.match?(/(?<![[:alnum:]])#{Regexp.escape(token)}(?![[:alnum:]])/)
            end
          end
          eligible = candidates.select do |candidate|
            (named_laws.empty? || candidate[:source_key].start_with?('external:') ||
              named_laws.include?(candidate[:source_key])) &&
              (identified_sources.empty? || identified_sources.include?(candidate[:source_key]))
          end
          chosen = if eligible.one?
                     eligible.first
                   else
                     matching = eligible.select { |c| c[:tokens].any? { |t| window.include?(t) } }
                     matching.one? ? matching.first : nil
                   end
          next match unless chosen
          next match if chosen[:eu_record] &&
                        !eurlex_plain_reference_compatible?(match, named_tail, chosen[:eu_record])
          # The law the text names by its date right after the mention must
          # be the target's (law_date_mismatch?).
          next match if law_date_mismatch?(match_data.post_match.first(120), chosen[:url].to_s[%r{/laws/([^#?]+)}, 1])

          link_count += 1
          "[#{match}](#{chosen[:url]})"
        end
      end

      Rails.logger.info("[AutoLink] Linkified #{link_count} article references") if link_count.positive?
      linkified
    end

    def auto_linkify_eurlex_units(text, sources)
      records = sources.filter_map do |source|
        record = verified_eurlex_corpus_record(source) if eurlex_corpus_source?(source)
        record if record && %w[recital paragraph].include?(source_field(record, :kind, 'kind'))
      end
      return text if records.empty?

      text.gsub(AnswerGuards::EURLEX_UNIT_CITATION_PATTERN) do |mention|
        match = Regexp.last_match
        next mention if inside_markdown_link_label?(match.pre_match, match.post_match) ||
                        inside_markdown_link_destination?(match.pre_match, match.post_match) ||
                        match.pre_match.match?(%r{https?://[^\s)]*\z}i) || inside_blockquote_line?(match.pre_match)
        next mention if rejected_article_link_label?(match)

        kind = match[:prefix].match?(/\A(?:overweging|consid[ée]rant|recital|Erw[aä]gungsgrund)\z/i) ? 'recital' : 'paragraph'
        number = normalize_article_number(match[:number])
        tail = match.post_match.gsub(/\b(nr|no)\.(?=\s*\d)/i, '\\1')
                    .split(/[.;\n]|#{AnswerGuards::EURLEX_UNIT_PREFIX}\s*\d+/i, 2).first.to_s.first(120)
        candidates = records.select do |record|
          source_field(record, :kind, 'kind') == kind &&
            normalize_article_number(source_field(record, :unit_number, 'unit_number')) == number &&
            eurlex_plain_reference_compatible?(mention, tail, record) &&
            eurlex_label_classification_valid?("#{match.pre_match.last(60)} #{mention}", record)
        end
        next mention unless candidates.map { |record| source_field(record, :url, 'url') }.uniq.one?

        "[#{mention}](#{source_field(candidates.first, :url, 'url')})"
      end
    end

    # Plural prefixes remain unsafe for generic prose ("artikelen" can mean
    # goods). Repair a simple list only when its immediate explicit EU act
    # binds every member to one verified edition/language and exact unit URL.
    EURLEX_RECITAL_LIST_PATTERN = Regexp.new(
      '(?<![[:alpha:]])(?:overweging(?:en)?|recitals?|consid[ée]rants?|Erw[aä]gungsgr(?:und|ünde|ünden|unde|unden))' \
      "#{Orchestrator::ARTICLE_SPACE_SOURCE}*(?<numbers>#{Orchestrator::ARTICLE_CITATION_ITEM_SOURCE}" \
      "(?:#{Orchestrator::ARTICLE_LIST_SEPARATOR_SOURCE}#{Orchestrator::ARTICLE_CITATION_ITEM_SOURCE})*)", Regexp::IGNORECASE
    ).freeze

    def auto_linkify_eurlex_unit_lists(text, sources)
      records = sources.filter_map do |source|
        record = verified_eurlex_corpus_record(source) if eurlex_corpus_source?(source)
        record if record && source_field(record, :source_kind, 'source_kind') == 'legislation' &&
                  %w[article recital].include?(source_field(record, :kind, 'kind'))
      end
      return text if records.empty?

      text.gsub(Regexp.union(Orchestrator::ARTICLE_CITATION_SEQUENCE_PATTERN, EURLEX_RECITAL_LIST_PATTERN)) do |sequence|
        match = Regexp.last_match
        next sequence if inside_markdown_link_label?(match.pre_match, match.post_match) ||
                         inside_markdown_link_destination?(match.pre_match, match.post_match) ||
                         inside_blockquote_line?(match.pre_match) || rejected_article_link_label?(match)

        numbers = match[:numbers].scan(Orchestrator::ARTICLE_NUMBER_TOKEN_PATTERN)
        next sequence unless numbers.length.between?(2, 12) && numbers.all? { |number| number.match?(/\A\d+[a-z]*\z/i) }

        residue = match[:numbers].gsub(Orchestrator::ARTICLE_NUMBER_TOKEN_PATTERN, '')
                                 .gsub(/#{Orchestrator::ARTICLE_PREFIX_SOURCE}/, '').gsub(/\b(?:en|et|and|und|of|ou)\b/i, '')
        next sequence unless residue.match?(/\A[[:space:]\u00A0\u2007\u202F,]*\z/)

        kind = sequence.match?(/\A#{Orchestrator::ARTICLE_PREFIX_SOURCE}/) ? 'article' : 'recital'
        prefix = if kind == 'article'
                   sequence.match?(/\AArticles?\b/i) ? 'Article' : 'Artikel'
                 elsif sequence.match?(/\Arecital/i)
                   'Recital'
                 elsif sequence.match?(/\Aconsid/i)
                   'Considérant'
                 elsif sequence.match?(/\AErw/i)
                   'Erwägungsgrund'
                 else
                   'Overweging'
                 end

        # A reviewed short name is an identity only at this immediate list
        # boundary. It cannot borrow an act named elsewhere in the answer.
        short_names = CANONICAL_EURLEX_SHORT_NAMES.values.flatten.sort_by { |name| -name.length }
        short_pattern = Regexp.union(short_names.map { |name| /(?<![[:alnum:]_-])#{Regexp.escape(name)}(?![[:alnum:]_-])/i })
        act = [match.post_match.match(AnswerGuards::EURLEX_ACT_IDENTIFIER_PATTERN),
               match.post_match.match(short_pattern)].compact.min_by { |candidate| candidate.begin(0) }
        next sequence unless act&.pre_match&.match?(/\A[[:space:],]*(?:(?:van|of|du|de|des|der)\s+(?:(?:de|het|the|le|la|des)\s+)?)?\z/i)
        # Do not shorten a made-up title such as "DSA-wet" or "DSA Wet" to
        # the known acronym. The short binding must end at punctuation/end;
        # other prose remains for explicit-link regeneration, not guessing.
        next sequence if act.regexp == short_pattern && !act.post_match.match?(/\A\s*(?:\z|[.,;:)\]])/)

        scope_tail = act.post_match.split(/[.;\n]|#{Orchestrator::ARTICLE_PREFIX_SOURCE}\s*\d+|#{AnswerGuards::EURLEX_UNIT_PREFIX}\s*\d+/i, 2).first.to_s.first(160)
        next sequence if scope_tail.match?(AnswerGuards::EURLEX_ACT_IDENTIFIER_PATTERN) ||
                         EuDiscovery.named_act_identifiers(scope_tail).any? || scope_tail.match?(short_pattern) ||
                         EuDiscovery::ALIASES.any? { |pattern, _identity| scope_tail.match?(pattern) } ||
                         scope_tail.match?(%r{\b(?:CELEX|ECLI)\s*:|\b[CTF]-\d+/\d+}i)

        selected = numbers.map do |number|
          candidates = records.select do |record|
            source_field(record, :kind, 'kind') == kind &&
              (kind == 'article' || (record[:correction_status] == 'verified_unchanged_recitals' &&
                                    record[:correction_verification] == 'explicit_other_language_correction_closure')) &&
              normalize_article_number(source_field(record, :unit_number, 'unit_number')) == normalize_article_number(number) &&
              eurlex_label_matches_record?("#{prefix} #{number} #{act[0]}", record)
          end
          candidates.first if candidates.map { |record| source_field(record, :url, 'url') }.uniq.one?
        end
        next sequence if selected.any?(&:nil?)
        next sequence unless selected.map { |record| [record[:celex], record[:language]] }.uniq.one?

        numbers.zip(selected).map { |number, record| "[#{prefix} #{number}](#{source_field(record, :url, 'url')})" }.join(', ')
      end
    end

    def eurlex_plain_reference_compatible?(mention, tail, record)
      # A numbering abbreviation is not the end of the act designation.
      identity = tail.to_s.gsub(/\b(nr|no)\.(?=\s*\d)/i, '\\1').strip.split(/[.;\n]/, 2).first.to_s
      # The source name ends before its claim, not after it: "Artikel 17 van
      # de DSA verplicht ..." must not treat the verb/prose as an invented act
      # title. Cut only after a complete explicit identity that the existing
      # typed-label verifier accepts. A predicate alone never supplies identity
      # or validates the surrounding legal claim.
      operative = identity.match(AnswerGuards::EURLEX_OPERATIVE_CLAIM_PATTERN)
      if operative
        prefix = operative.pre_match.strip
        names = eurlex_record_names(record) + eurlex_canonical_short_names(record)
        explicit = names.any? { |name| prefix.match?(/(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/i) } ||
                   eurlex_named_act_identities(prefix).any?
        identity = prefix if explicit && eurlex_label_matches_record?("#{mention} #{prefix}", record)
      end
      identity = identity.split(/\b(?:geldt|vereist|bepaalt|regelt|voorziet|requires|provides|applies|states|imposes|exige|pr[ée]voit|dispose|gilt|verlangt|regelt)\b/i, 2).first.to_s.strip
      return true if identity.blank?

      named = identity.match?(/\A(?:van|of|du|de la|des|der)\b/i) ||
              identity.match?(/\A\(?\p{Lu}[[:alpha:]\d_-]+/u) ||
              (eurlex_record_names(record) + eurlex_canonical_short_names(record)).any? do |name|
                identity.match?(/\A\(?#{Regexp.escape(name)}(?![[:alnum:]])/i)
              end
      return true unless named

      eurlex_label_matches_record?("#{mention} #{identity}", record)
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
      current_line.to_s.match?(/\A {0,3}>/)
    end

    def rejected_article_link_label?(match_data)
      Array(@rejected_article_link_labels).any? do |label|
        prefix = match_data.pre_match.last(label.length)
        window = "#{prefix}#{match_data[0]}#{match_data.post_match.first(label.length)}"
        index = window.index(label)
        while index
          return true if index <= prefix.length && index + label.length >= prefix.length + match_data[0].length

          index = window.index(label, index + 1)
        end
        false
      end
    end

    def inside_markdown_link_destination?(prefix, suffix)
      opening = prefix.to_s.rindex('](')
      closing = prefix.to_s.rindex(')')
      opening && (closing.nil? || closing < opening) && suffix.to_s.match?(/\A[^)\n]*\)/)
    end

    def inside_markdown_link_label?(prefix, suffix)
      open_bracket = prefix.rindex('[')
      close_bracket = prefix.rindex(']')
      return false unless open_bracket && (close_bracket.nil? || open_bracket > close_bracket)

      suffix.match?(/\A[^\]\n]*\]\([^)\n]+\)/)
    end
  end
end
