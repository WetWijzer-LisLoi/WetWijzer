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
    #   art. 145/33       → #art_145/33
    #   artikel 49        → #art_49
    #   article 49        → #art_49
    #   art. 49 WIB 92    → #art_49
    #   art. 49 CIR 92    → #art_49
    #   art. 49, WIB 92   → #art_49
    #
    # Avoids matching when already inside an <a> tag or when the article number
    # is immediately followed by a period and another digit (e.g., "art. 49.2")
    # which should become #art_49.2 instead.
    TAX_ART_REF_PATTERN = %r{
      \b                                   # word boundary
      (art(?:ikel|icle)?\.?)               # "art." / "artikel" / "article"
      (\s+)                                # required whitespace
      (\d+                                 # article number (digits)
        (?:[./]\d+)*                       # optional sub-numbers: 145/33, 49.2
        [a-z]*                             # optional suffix: bis, ter, quater
      )
      (?:                                  # optional WIB/CIR/BTW qualifier
        (?:\s*,?\s*)
        (?:WIB|CIR|BTW|KB/WIB|KB/CIR)
        (?:\s+\d{2,4})?                    # optional year: "92", "1992"
      )?
    }ix

    # Converts tax article references in HTML text to clickable anchor links.
    # Only links to articles that actually exist on the current page.
    #
    # @param html [String] HTML content (already escaped) to process
    # @param valid_article_numbers [Set, Array] article numbers present on the page
    # @return [String] HTML with article references linked
    def linkify_tax_article_refs(html, valid_article_numbers)
      return html if html.blank? || valid_article_numbers.blank?

      # Convert to Set for O(1) lookups
      valid_set = valid_article_numbers.is_a?(Set) ? valid_article_numbers : valid_article_numbers.to_set

      html.gsub(TAX_ART_REF_PATTERN) do
        Regexp.last_match(1)
        Regexp.last_match(2)
        art_num = Regexp.last_match(3)
        full_match = Regexp.last_match(0)

        # Only link if the article exists on this page
        if valid_set.include?(art_num)
          link_classes = 'text-(--link-color) hover:text-(--link-hover-color) hover:underline'
          %(<a href="#art_#{art_num}" class="#{link_classes}" title="Art. #{art_num}">#{full_match}</a>)
        else
          full_match
        end
      end
    end
  end
end
