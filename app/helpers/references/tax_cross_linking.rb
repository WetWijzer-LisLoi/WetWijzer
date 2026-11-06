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
      (?:                                  # optional WIB/CIR/BTW qualifier
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

    # Converts tax article references in HTML text to clickable anchor links.
    # Only links to articles that actually exist on the current page.
    #
    # @param html [String] HTML content (already escaped) to process
    # @param valid_article_numbers [Set, Array] article numbers present on the page
    # @param anchors [FisconetArticleAnchors, nil] the page's rows, so a reference inside one region's text leads to that
    #   region's article
    # @param region [String, nil] the region of the row this text belongs to
    # @return [String] HTML with article references linked
    def linkify_tax_article_refs(html, valid_article_numbers, anchors: nil, region: nil)
      return html if html.blank? || valid_article_numbers.blank?

      # Compare canonical ids so references remain linkable regardless of
      # suffix case and so slash/dot forms point at their dashed DOM id.
      valid_set = tax_anchor_set(valid_article_numbers)

      html.gsub(TAX_ART_REF_PATTERN) do
        art_num = Regexp.last_match(3)
        full_match = Regexp.last_match(0)

        # Only link if the article exists on this page
        anchor_id = fisconet_article_anchor_id(art_num)
        if anchor_id && valid_set.include?(anchor_id)
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
