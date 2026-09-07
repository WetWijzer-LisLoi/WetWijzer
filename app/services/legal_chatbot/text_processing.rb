# frozen_string_literal: true

# Extracted from LegalChatbotService (Product Evolution Target #1)
# UTF-8 mojibake repair, text encoding, and law title lookup
module LegalChatbot
  module TextProcessing
    extend ActiveSupport::Concern

    # Fix double-encoded UTF-8 mojibake via hardcoded lookup table.
    # All keys/values use \uXXXX escapes so the source stays pure ASCII.
    #
    # Pattern: UTF-8 char X has bytes [C3 xx]. When read as Latin-1 and
    # re-encoded to UTF-8, each byte becomes a separate character:
    # byte C3 → char U+00C3 (Ã), byte AB → char U+00AB («).
    # So "ë" (C3 AB) becomes "ë" (U+00C3 U+00AB).
    # We reverse this: replace the 2-char mojibake with the correct single char.
    MOJIBAKE_MAP = {
      # Ã + x → correct char (C3 prefix: accented lowercase)
      "\u00C3\u00A0" => "\u00E0", # Ã → à
      "\u00C3\u00A1" => "\u00E1", # á → á
      "\u00C3\u00A2" => "\u00E2", # â → â
      "\u00C3\u00A3" => "\u00E3", # ã → ã
      "\u00C3\u00A4" => "\u00E4", # ä → ä
      "\u00C3\u00A5" => "\u00E5", # Ã¥ → å
      "\u00C3\u00A6" => "\u00E6", # æ → æ
      "\u00C3\u00A7" => "\u00E7", # ç → ç
      "\u00C3\u00A8" => "\u00E8", # è → è
      "\u00C3\u00A9" => "\u00E9", # é → é
      "\u00C3\u00AA" => "\u00EA", # ê → ê
      "\u00C3\u00AB" => "\u00EB", # ë → ë
      "\u00C3\u00AC" => "\u00EC", # ì → ì
      "\u00C3\u00AD" => "\u00ED", # í → í
      "\u00C3\u00AE" => "\u00EE", # î → î
      "\u00C3\u00AF" => "\u00EF", # ï → ï
      "\u00C3\u00B0" => "\u00F0", # ð → ð
      "\u00C3\u00B1" => "\u00F1", # ñ → ñ
      "\u00C3\u00B2" => "\u00F2", # ò → ò
      "\u00C3\u00B3" => "\u00F3", # ó → ó
      "\u00C3\u00B4" => "\u00F4", # ô → ô
      "\u00C3\u00B5" => "\u00F5", # Ã µ → õ
      "\u00C3\u00B6" => "\u00F6", # ö → ö
      "\u00C3\u00B8" => "\u00F8", # ø → ø
      "\u00C3\u00B9" => "\u00F9", # ù → ù
      "\u00C3\u00BA" => "\u00FA", # ú → ú
      "\u00C3\u00BB" => "\u00FB", # û → û
      "\u00C3\u00BC" => "\u00FC", # ü → ü
      "\u00C3\u00BD" => "\u00FD", # ý → ý
      "\u00C3\u00BE" => "\u00FE", # þ → þ
      "\u00C3\u00BF" => "\u00FF", # ÿ → ÿ
      # Ã + x → correct char (C3 prefix: accented uppercase)
      "\u00C3\u0080" => "\u00C0", # À → À
      "\u00C3\u0081" => "\u00C1", # Ã → Á
      "\u00C3\u0082" => "\u00C2", # Â → Â
      "\u00C3\u0083" => "\u00C3", # Ã → Ã
      "\u00C3\u0084" => "\u00C4", # Ä → Ä
      "\u00C3\u0085" => "\u00C5", # Ã… → Å
      "\u00C3\u0086" => "\u00C6", # Æ → Æ
      "\u00C3\u0087" => "\u00C7", # Ç → Ç
      "\u00C3\u0088" => "\u00C8", # È → È
      "\u00C3\u0089" => "\u00C9", # É → É
      "\u00C3\u008A" => "\u00CA", # Ê → Ê
      "\u00C3\u008B" => "\u00CB", # Ë → Ë
      "\u00C3\u008C" => "\u00CC", # ÃŒ → Ì
      "\u00C3\u008D" => "\u00CD", # Ã → Í
      "\u00C3\u008E" => "\u00CE", # ÃŽ → Î
      "\u00C3\u008F" => "\u00CF", # Ã → Ï
      "\u00C3\u0090" => "\u00D0", # Ã → Ð
      "\u00C3\u0091" => "\u00D1", # Ã' → Ñ
      "\u00C3\u0092" => "\u00D2", # Ã' → Ò
      "\u00C3\u0093" => "\u00D3", # Ã" → Ó
      "\u00C3\u0094" => "\u00D4", # Ã" → Ô
      "\u00C3\u0095" => "\u00D5", # Õ → Õ
      "\u00C3\u0096" => "\u00D6", # Ö → Ö
      "\u00C3\u0097" => "\u00D7", # Ã- → ×
      "\u00C3\u0098" => "\u00D8", # Ø → Ø
      "\u00C3\u0099" => "\u00D9", # Ù → Ù
      "\u00C3\u009A" => "\u00DA", # Ú → Ú
      "\u00C3\u009B" => "\u00DB", # Û → Û
      "\u00C3\u009C" => "\u00DC", # Ü → Ü
      "\u00C3\u009D" => "\u00DD", # Ã → Ý
      "\u00C3\u009E" => "\u00DE", # Þ → Þ
      "\u00C3\u009F" => "\u00DF", # ß → ß
      # Â + x → correct char (C2 prefix: symbols & punctuation)
      "\u00C2\u00A0" => "\u00A0", # Â → (non-breaking space)
      "\u00C2\u00A1" => "\u00A1", # ¡ → ¡
      "\u00C2\u00A2" => "\u00A2", # ¢ → ¢
      "\u00C2\u00A3" => "\u00A3", # £ → £
      "\u00C2\u00A7" => "\u00A7", # § → §
      "\u00C2\u00A9" => "\u00A9", # © → ©
      "\u00C2\u00AB" => "\u00AB", # « → «
      "\u00C2\u00AE" => "\u00AE", # ® → ®
      "\u00C2\u00B0" => "\u00B0", # ° → °
      "\u00C2\u00B2" => "\u00B2", # ² → ²
      "\u00C2\u00B3" => "\u00B3", # ³ → ³
      "\u00C2\u00B5" => "\u00B5", # µ → µ
      "\u00C2\u00B6" => "\u00B6", # ¶ → ¶
      "\u00C2\u00B7" => "\u00B7", # · → ·
      "\u00C2\u00BB" => "\u00BB", # » → »
      "\u00C2\u00BC" => "\u00BC", # ¼ → ¼
      "\u00C2\u00BD" => "\u00BD", # ½ → ½
      "\u00C2\u00BE" => "\u00BE"  # ¾ → ¾
    }.freeze

    def ensure_utf8(text)
      return '' if text.nil?

      str = text.to_s.dup

      # Step 1: Force to UTF-8 if tagged as binary
      str.force_encoding('UTF-8') if str.encoding == Encoding::ASCII_8BIT

      # Step 2: Replace known mojibake patterns with correct characters
      # Iterate through each map entry and replace individually
      if str.valid_encoding?
        MOJIBAKE_MAP.each do |bad, good|
          str.gsub!(bad, good)
        end
      end

      # Step 3: Final safety - replace any remaining invalid bytes
      str.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
    end

    # Look up law_title with fallback to base numac (strips A/B suffix for consolidated laws)
    # This fixes the issue where consolidated law versions have contents but no legislation record
    def lookup_law_title(numac, language_id = nil)
      return nil if numac.blank?

      # First check CORE_LAW_NUMACS constant
      return CORE_LAW_NUMACS[numac] if CORE_LAW_NUMACS.key?(numac)

      lang_id = language_id || @language_id

      # Try direct lookup first
      legislation = Legislation.find_by(numac: numac, language_id: lang_id)
      return legislation.display_title if legislation&.title.present?

      # Fallback: try base numac (strip A/B suffix for consolidated versions)
      if numac =~ /^(\d{4})[AB](\d+)$/
        base_numac = "#{::Regexp.last_match(1)}#{::Regexp.last_match(2)}"
        legislation = Legislation.find_by(numac: base_numac, language_id: lang_id)
        return legislation.display_title if legislation&.title.present?
      end

      # Last resort: try any language
      legislation = Legislation.find_by(numac: numac)
      return legislation.display_title if legislation&.title.present?

      if numac =~ /^(\d{4})[AB](\d+)$/
        base_numac = "#{::Regexp.last_match(1)}#{::Regexp.last_match(2)}"
        legislation = Legislation.find_by(numac: base_numac)
        return legislation.display_title if legislation&.title.present?
      end

      # Generate descriptive fallback from numac (extract year)
      if numac =~ /^(\d{4})/
        year = ::Regexp.last_match(1)
        return "Wet van #{year} (NUMAC #{numac})"
      end

      # Ultimate fallback - never return nil
      "Wetgeving (NUMAC #{numac})"
    end

    # Canonical article-number → anchor-id fragment.
    # MUST stay in sync with ApplicationHelper#normalize_article_token, which
    # generates the ids on the law pages these anchors deep-link into:
    # downcase, [./:] → '-', strip anything else, collapse/trim dashes.
    # "37/2" → "37-2", "5:3" → "5-3", "VI.92" → "vi-92", "2.8.4.1.1§2" → "2-8-4-1-12"
    # Variant markers a Justel consolidated title may append to the article
    # number ("Art.63 TOEKOMSTIG RECHT", "Art. 39_VLAAMS_GEWEST"). They are
    # renderings of the SAME article, but they made the three slug forms
    # (stored source URL, canonical guard href, page DOM anchor) disagree, so
    # a citation matching only a variant record was structurally rejected -
    # and underscore-format titles poisoned the pair itself
    # ("63_TOEKOMSTIG_RECHT" normalizing to 63toekomstigrecht). Stripped at
    # this shared seam so every consumer (pair extraction, label and link
    # parsing, linkify) collapses variant and base to one number
    # (2026-08-04 withheld-answer mining).
    ARTICLE_VARIANT_SUFFIX = /
      [\s_.\-]*
      (?:
        toekomstig[\s_\-]*recht |
        droit[\s_\-]*futur |
        vlaams[\s_\-]*gewest |
        waals[\s_\-]*gewest |
        brussels(?:e)?[\s_\-]*(?:hoofdstedelijk[\s_\-]*)?gewest |
        r[eé]gion[\s_\-]*(?:wallonne|flamande|de[\s_\-]*bruxelles[\s_\-]*capitale)
      )
      \.?\z
    /xi

    def normalize_article_number(number)
      number.to_s.sub(ARTICLE_VARIANT_SUFFIX, '')
            .downcase.gsub(%r{[./:]+}, '-').gsub(/[^a-z0-9-]/, '').gsub(/-+/, '-').gsub(/^-|-$/, '')
    end

    # Extract article anchor from article_title for URL construction.
    # Input: "Art. 37" or "Art. 37/2" or "Artikel 1382"
    # Output: "#art-37" or "#art-37-2" or "#art-1382"
    # Returns nil if no article number found.
    def extract_article_anchor(article_title)
      return nil if article_title.blank?

      # Match "Art." or "Artikel" followed by the number
      match = article_title.match(/\bArt(?:ikel)?\.?\s*(\S+)/i)
      return nil unless match

      number = normalize_article_number(match[1])
      return nil if number.blank?

      "#art-#{number}"
    end
  end
end
