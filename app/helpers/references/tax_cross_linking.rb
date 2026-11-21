# frozen_string_literal: true

# Tax Article Cross-Reference Linking
# Converts inline references like "art. 49 WIB 92", "art. 33 CIR 92",
# "artikel 49", or plain "art. 49" in FiscoNet article text into clickable
# in-page anchor links (#art_49).
#
# These are same-page links because all articles of a tax code are rendered
# on a single page in _fisconet_show.html.erb.
module References
  module TaxCrossLinking
    extend ActiveSupport::Concern

    # Pattern matches:
    #   art. 49           → #art_49
    #   art. 49bis        → #art_49bis
    #   art. 145/33       → #art_145-33
    #   artikel 49        → #art_49
    #   article 49        → #art_49
    #   art. 49 WIB 92    → #art_49
    #   art. 49 CIR 92    → #art_49
    #   art. 49, WIB 92   → #art_49
    #
    # Avoids matching when already inside an <a> tag or when the article number
    # is immediately followed by a period and another digit (e.g., "art. 49.2")
    # which should become #art_49-2 instead.
    #
    # A number followed by a colon and a digit ("artikel 1:24") is an article of another code, such as the Code of
    # companies and associations; it is not linked at all. Sol, on live 1.1.16 (/laws/FISCONET_1): "artikel 1:24" was
    # linked as "artikel 1" to this code's article 1. The number is matched atomically, so it cannot give back digits
    # to slip past that check ("12:3" is not read as "1").
    TAX_ART_REF_PATTERN = %r{
      \b                                   # word boundary
      (art(?:ikel|icle)?\.?)               # "art." / "artikel" / "article"
      (\s+)                                # required whitespace
      ((?>\d+                              # article number (digits), taken whole
        (?:[./]\d+)*                       # optional sub-numbers: 145/33, 49.2
        [a-z]*                             # optional suffix: bis, ter, quater
      ))
      (?!:\d)                              # not "1:24": another code's article
      (?:<sup>(\d+)</sup>)?                # "145<sup>1</sup>": Fisconet's 145/1 (Sol, on live 1.1.18)
      (                                    # optional WIB/CIR/BTW qualifier (group 5, read by tax_named_code)
        (?:\s*,?\s*)
        (?:WIB|CIR|BTW|KB/WIB|KB/CIR)
        (?:\s+\d{2,4})?                    # optional year: "92", "1992"
      )?
    }ix

    # Canonical Fisconet article anchor. Keep this transformation in sync with
    # LegalChatbot::TextProcessing#normalize_article_number: law-page ids,
    # generated chatbot URLs, TOC links, and clipboard selectors must resolve
    # to the exact same fragment.
    def fisconet_article_anchor_id(article_number)
      normalized = article_number.to_s.downcase
                                 .gsub(%r{[./:]+}, '-')
                                 .gsub(/[^a-z0-9-]/, '')
                                 .gsub(/-+/, '-')
                                 .gsub(/^-|-$/, '')
      normalized.present? ? "art_#{normalized}" : nil
    end

    # The ids of this page's rows, for the contents and the bodies alike (FisconetArticleAnchors).
    def fisconet_article_anchors(articles)
      FisconetArticleAnchors.new(articles) { |number| fisconet_article_anchor_id(number) }
    end

    # The canonical anchor ids on the page, built ONCE per page. This helper
    # runs once per article, and it used to derive the ids of every article on
    # every call: 1,697 x 1,697 derivations for the registration-duties code,
    # six seconds of its thirty-second cold render. Memoised by the identity of
    # the collection the view hands in, which is one Set for the whole render.
    def tax_anchor_set(valid_article_numbers)
      @tax_anchor_sets ||= {}.compare_by_identity
      @tax_anchor_sets[valid_article_numbers] ||=
        valid_article_numbers.filter_map { |number| fisconet_article_anchor_id(number) }.to_set
    end

    # An article of another act is that act's article, never this code's. Sol, on live 1.1.75 (2026-11-20 14:33:02Z,
    # #663): the applicability note of WIB 92 art. 131, "(art. 2, 1°, en 4, 1ste lid, W 15.07.2026 - B.S. 29.07.2026;
    # Numac: 2026005724)", linked its "art. 2" to article 2 of WIB 92. Such a reference stays text, and the note's
    # NUMAC link still opens the act. A reference is another act's when it stands
    #   - in a source note: a parenthesis whose own text cites a publication (B.S., M.B., Numac), as Fisconet's notes
    #     on where a provision comes from and since when it applies do;
    #   - before a dated act, with nothing in between but its own parts and further numbers: "art. 2, 1°, en 4, 1ste
    #     lid, W 15.07.2026", "art. 22, al. 2; Lprog 18.07.2025", "art. 38 et 44, AR 09.12.2019";
    #   - before the name of another kind of act, the same way: "artikel 38 van de wet van 29.02.2024", "art. 3, 6°,
    #     7° et 8° de la loi spéciale du 16 janv. 1989", "art. 31 van het Vlaams Decreet van 19 dec. 2014", a
    #     directive, a regulation, a treaty, the Constitution, a code that is never a Fisconet page here (the Civil,
    #     Judicial and Criminal Codes, the companies code, the Flemish tax codex). A "(...)" between counts as a part.
    # "Dit besluit", "la présente loi", "hetzelfde besluit", "voormeld besluit" and the like can name the page's own act,
    # and a code ("Wetboek", "Code") can be this one: those references are linked as before. Measured on every
    # Fisconet row on 2026-11-20 (10,707 provision texts): 19,279 of 65,703 article links named another act's article.
    TAX_INVISIBLE_SPACES = [0x00a0, 0x200b].pack('U*').freeze # no-break space, zero-width space
    TAX_SOURCE_NOTE_MARK = /B\.[[:space:]]?S\.|M\.[[:space:]]?B\.|(?<![[:alpha:]])N(?:umac|UMAC)(?![[:alpha:]])/
    TAX_REF_PARTS = %r{
      \A(?>(?:[[:space:],]*
        (?:\((?:\.{3}|…)\)|alinéa|al\.|al|lid|en|et|tot|à|of|ou|t/m|§+
          |\d+(?:[./]\d+)*(?:[[:space:]]?(?:°|er|ère)|ste|de|e)?
          |[a-z]\)|eerste|tweede|derde|vierde|vijfde|zesde|premier|première|deuxième|troisième|quatrième|cinquième|sixième
          |inleidende[[:space:]]+zin|phrase[[:space:]]+liminaire)
        (?![[:alnum:]]))*)
    }ix
    TAX_DATED_ACT = /
      \A[[:space:],;]*[[:upper:]][[:alpha:]]{0,9}(?:\.?[[:space:]]?[[:upper:]][[:alpha:]]{0,9}){0,2}\.?
      [[:space:]]*\d{1,2}\.\d{1,2}\.\d{4}(?!\d)
    /x
    # Codes that are never a Fisconet page here.
    TAX_OTHER_CODE = [
      'burgerlijk[[:space:]]+wetboek', 'gerechtelijk[[:space:]]+wetboek', 'strafwetboek',
      'wetboek[[:space:]]+van[[:space:]]+(?:strafvordering|vennootschappen|economisch[[:space:]]+recht|koophandel)', 'codex',
      "code[[:space:]]+(?:civil|judiciaire|pénal|d['’]instruction[[:space:]]+criminelle|des[[:space:]]+sociétés|de[[:space:]]+droit[[:space:]]+" \
      'économique|de[[:space:]]+commerce|flamand[[:space:]]+de[[:space:]]+la[[:space:]]+fiscalité)'
    ].join('|').freeze
    TAX_ACT_NAME = %r{
      \A[[:space:],]*(?<lead>(?:van|de|du|des|der)(?:[[:space:]]+[[:alpha:]-]+|[[:space:]]+l['’]){0,3}?)[[:space:]]*(?<![[:alpha:]])
      (?:[[:alpha:]]*(?:wet|besluit|decreet)|wetten|loi|lois|arrêté|décret|ordonnantie|ordonnance|richtlijn|directive|verordening|règlement
        |verdrag|convention|constitution|samenwerkingsakkoord|accord|kb|ar|k\.b\.|a\.r\.|#{TAX_OTHER_CODE})
      (?![[:alpha:]/])
    }ix
    TAX_OWN_ACT_WORD = /
      (?<![[:alpha:]])
      (?:dit|deze|huidige?|onderhavige?|présente?|cette|cet|ce|hetzelfde|dezelfde|zelfde|même|ledit|ladite|dudit|voormelde?|voornoemde?)
      (?![[:alpha:]])
    /ix

    # A tax code named right after a reference (the #663 follow-up, surveyed on production on 2026-11-20: 76 links): on
    # the WIB 92 pages "artikel 4, KB/WIB 92" is the royal decree's article, on the KB/WIB 92 pages "art. 202, WIB 1992"
    # the code's. In an annex the year runs into the next word ("WIB 92Onderafdeling"). A bare WIB or CIR names the
    # income tax code.
    TAX_CODE_QUALIFIER = %r{
      \A[[:space:],]*(?:(?:van|de|du|des|der|in|het|la|le)[[:space:]]+|l['’][[:space:]]?){0,3}
      (?<code>
        (?:K\.?[[:space:]]?B\.?|A\.?[[:space:]]?R\.?)[[:space:]]?/[[:space:]]?(?:W\.?[[:space:]]?I\.?[[:space:]]?B\.?|C\.?[[:space:]]?I\.?[[:space:]]?R\.?)
       |W\.?[[:space:]]?I\.?[[:space:]]?B\.?|C\.?[[:space:]]?I\.?[[:space:]]?R\.?
       |W\.?[[:space:]]?B\.?[[:space:]]?T\.?[[:space:]]?W\.?|BTW-?wetboek|C\.?[[:space:]]?T\.?[[:space:]]?V\.?[[:space:]]?A\.?
       |W\.?[[:space:]]?Reg\.?|C\.?[[:space:]]?Enr\.?|W\.?[[:space:]]?Succ\.?|C\.?[[:space:]]?Succ\.?
       |(?:K\.?[[:space:]]?B\.?|A\.?[[:space:]]?R\.?)[[:space:]]?(?:nr\.?|n[°o]\.?)[[:space:]]?20(?!\d)
      )
      (?:[[:space:]]*(?:19)?(?<year>92|64)(?!\d)|(?![[:alpha:]]))
    }ix
    # The page code each named code is (the stored base code or document type of the Fisconet legislation); a code of
    # 1964 is never a page here.
    TAX_CODE_FAMILIES = {
      'KB/WIB 92' => %r{\A(?:KB|AR)/(?:WIB|CIR)\z},
      'WIB 92' => /\A(?:WIB|CIR)\z/,
      'BTW' => /\A(?:WBTW|BTW-?WETBOEK|CTVA)\z/,
      'W.Reg.' => /\A(?:WREG|CENR)\z/,
      'W.Succ.' => /\A(?:WSUCC|CSUCC)\z/,
      'KB 20' => /\A(?:KB|AR)(?:NR|N°|NO)20\z/
    }.freeze

    # Which rule makes the reference at match (a TAX_ART_REF_PATTERN match in html) another act's: :source_note,
    # :dated_act, :other_code or :act_name; nil when it may be this page's own article. notes: tax_source_notes(html);
    # code: the page's own tax code (a TAX_CODE_FAMILIES key), when known.
    def tax_other_act_reference(html, match, notes, code: nil)
      start = match.begin(0)
      return :source_note if notes.any? { |note| note.cover?(start) }

      rest = tax_reference_rest(html, match.end(0))
      return :dated_act if rest.match?(TAX_DATED_ACT)

      named_code = tax_named_code("#{match[5]}#{rest}")
      return :other_code if code && named_code && named_code != code

      named = rest.match(TAX_ACT_NAME)
      :act_name if named && !named[:lead].match?(TAX_OWN_ACT_WORD)
    end

    # The tax code the text after a reference names first ("KB/WIB 92", "CIR 1992", "W.Reg."), as a TAX_CODE_FAMILIES
    # key ('WIB 64' for the code of 1964); nil when it names none.
    def tax_named_code(rest)
      found = rest.match(TAX_CODE_QUALIFIER)
      return unless found

      family = found[:code].upcase.delete('.').gsub(/[[:space:]]/, '')
      name = TAX_CODE_FAMILIES.find { |_name, pattern| family.match?(pattern) }&.first
      name && found[:year] == '64' ? name.sub('92', '64') : name
    end

    # The text after a reference, without tags or entities, from the end of its own parts.
    def tax_reference_rest(html, from)
      text = html[from, 400].to_s.gsub(/<[^>]*>?/, '')
      text = CGI.unescapeHTML(text) if text.include?('&')
      text.tr(TAX_INVISIBLE_SPACES, '  ').squeeze(' ').sub(TAX_REF_PARTS, '')[0, 160]
    end

    # The ranges of html's source notes: each parenthesis whose own text, nested parentheses left out, cites a
    # publication. Unbalanced parentheses (the "a)" of an enumeration) open or close nothing.
    # A publication mark belongs to the innermost parenthesis open where it stands. Two fast scans, merged in order:
    # the marks, then the parentheses (none when the text has no mark).
    def tax_source_notes(html)
      marks = []
      html.scan(TAX_SOURCE_NOTE_MARK) { marks << Regexp.last_match.begin(0) }
      return [] if marks.empty?

      notes = []
      opened = [] # [position, cites a publication]
      mark = 0
      html.scan(/[()]/) do
        paren = Regexp.last_match
        position = paren.begin(0)
        while mark < marks.size && marks[mark] < position
          opened.last[1] = true if opened.any?
          mark += 1
        end
        if paren[0] == '('
          opened << [position, false]
        else
          open, cites = opened.pop
          notes << (open..position) if cites
        end
      end
      notes
    end

    # Converts tax article references in HTML text to clickable anchor links.
    # Only links to articles that actually exist on the current page.
    #
    # @param html [String] HTML content (already escaped) to process
    # @param valid_article_numbers [Set, Array] article numbers present on the page
    # @param anchors [FisconetArticleAnchors, nil] the page's rows, so a reference inside one region's text leads to that
    #   region's article
    # @param region [String, nil] the region of the row this text belongs to
    # @param code [String, nil] the page's own tax code (a TAX_CODE_FAMILIES key): a reference naming another code stays
    #   text
    # @return [String] HTML with article references linked
    def linkify_tax_article_refs(html, valid_article_numbers, anchors: nil, region: nil, code: nil)
      return html if html.blank? || valid_article_numbers.blank?

      # Compare canonical ids so references remain linkable regardless of
      # suffix case and so slash/dot forms point at their dashed DOM id.
      valid_set = tax_anchor_set(valid_article_numbers)

      notes = nil
      html.gsub(TAX_ART_REF_PATTERN) do
        match = Regexp.last_match
        art_num = match[3]
        # A numeric superscript is part of the number: 145 with superscript 1 is stored as 145/1. With no such article
        # on the page the reference stays text rather than lead to article 145.
        art_num = "#{art_num}/#{match[4]}" if match[4]
        full_match = match[0]

        # Only link if the article exists on this page and is this page's own: another act's article stays text
        anchor_id = fisconet_article_anchor_id(art_num)
        if anchor_id && valid_set.include?(anchor_id) && !tax_other_act_reference(html, match, notes ||= tax_source_notes(html), code: code)
          link_classes = 'text-(--link-color) hover:text-(--link-hover-color) hover:underline'
          target = anchors ? anchors.target(anchor_id, region, number: art_num) : anchor_id
          %(<a href="##{target}" class="#{link_classes}" title="Art. #{art_num}">#{full_match}</a>)
        else
          full_match
        end
      end
    end
  end
end
