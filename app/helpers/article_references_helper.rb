# frozen_string_literal: true

##
# Article References Helper
#
# Provides methods to extract and match article references from text,
# enabling the display of executive decisions that reference specific articles.
#
module ArticleReferencesHelper
  ##
  # Extracts article numbers referenced in text
  # Handles both NL and FR patterns
  #
  # @param text [String] The text to parse for article references
  # @return [Array<String>] Array of normalized article identifiers (e.g., ["1", "2", "3bis"])
  #
  # @example
  #   extract_article_references("artikel 5 en artikel 6bis")
  #   # => ["5", "6bis"]
  #
  def extract_article_references(text)
    return [] if text.blank?

    references = []
    article_reference_patterns.each do |pattern|
      extract_references_with_pattern(text, pattern, references)
    end
    references.uniq.sort
  end

  private

  def article_reference_patterns
    [
      single_article_pattern,
      article_with_annex_pattern,
      multiple_articles_pattern,
      special_article_pattern
    ]
  end

  def single_article_pattern
    %r{
      \b(?:artikel|article|art)\.?\s+
      (\d+(?:/\d+)?(?:e?r|bis|ter|quater|quinquies|sexies|septies|octies|nonies|decies|undecies)?)
      (?:\s*,?\s*§\s*\d+)?
      # Negative lookahead: don't match if followed by special designations
      (?!(?:_|\s+)(?:WAALS|VLAAMS|BRUSSELS|TOEKOMSTIG|DROIT|GEWEST|REGION|RECHT|FUTUR))
      \b
    }ix
  end

  def article_with_annex_pattern
    /\b(?:artikel|article|art)\.?\s+([A-Z]\d*)\b/ix
  end

  def multiple_articles_pattern
    %r{
      \b(?:artikelen|articles)\.?\s+
      (\d+(?:/\d+)?(?:bis|ter|quater)?)
      \s*(?:en|et|,)\s*
      (\d+(?:/\d+)?(?:bis|ter|quater)?)
    }ix
  end

  def special_article_pattern
    # Pattern for special article designations that are part of the article ID
    # Formats:
    # - "artikel 14_WAALS_GEWEST" (underscore separator)
    # - "artikel 1_VLAAMS_GEWEST" (underscore separator)
    # - "artikel 18_BRUSSELS_HOOFDSTEDELIJK_GEWEST" (underscore separator)
    # - "artikel 17 TOEKOMSTIG RECHT" (space separator)
    # These extract the FULL identifier including the designation
    # Note: Does NOT match annexes like "N1", "N2" etc.
    %r{
      \b(?:artikel|article|art)\.?\s+
      (\d+(?:/\d+)?(?:bis|ter|quater)?)  # Number
      (?:_|\s+)  # Underscore or space separator
      ((?:WAALS|VLAAMS|BRUSSELS(?:E)?(?:_HOOFDSTEDELIJK)?)(?:_|\s+)GEWEST|
       (?:WALLON|NE|FLAMAND|E|BRUXELLOIS(?:E)?)(?:_|\s+)(?:REGION|GEWEST)|
       TOEKOMSTIG(?:_|\s+)RECHT|
       DROIT(?:_|\s+)FUTUR)
      \b
    }ix
  end

  def extract_references_with_pattern(text, pattern, references)
    text.scan(pattern) do |matches|
      next if structural_article_reference?(text, Regexp.last_match)

      # Normalize matches to array
      matches_array = Array(matches).flatten.compact

      # For special_article_pattern, combine both capture groups into full ID
      # e.g., "14" + "WAALS_GEWEST" => "art-14-waals_gewest"
      # e.g., "17" + "TOEKOMSTIG RECHT" => "art-17-toekomstig"
      if pattern == special_article_pattern && matches_array.size >= 2
        article_num = matches_array[0].downcase.strip
        variant_text = matches_array[1].upcase

        # Normalize variant to match database format (from detect_article_variant logic)
        variant = case variant_text
                  when /WAALS.*GEWEST/ then 'waals_gewest'
                  when /VLAAMS.*GEWEST/ then 'vlaams_gewest'
                  when /BRUSSELS.*GEWEST/ then 'brussels_hoofdstedelijk_gewest'
                  when /WALLON|NE.*REGION/ then 'region_wallonne'
                  when /FLAMAND|E.*REGION/ then 'region_flamande'
                  when /BRUXELLOIS.*REGION/ then 'region_bruxelles_capitale'
                  when /TOEKOMSTIG/ then 'toekomstig'
                  when /FUTUR/ then 'futur'
                  else
                    variant_text.gsub(/\s+/, '_').downcase.strip
                  end

        full_id = "art-#{article_num}-#{variant}"
        references << full_id
      else
        matches_array.each { |ref| references << ref.downcase.strip if ref.present? }
      end
    end
  end

  def structural_article_reference?(text, match)
    match_pos = match.begin(0)
    match_end = match.end(0)
    preceding_text = text[0...match_pos]
    following_text = text[match_end..] || ''

    # Skip if this is an article header (e.g., "Artikel 1. Voor de toepassing...")
    return true if at_line_start?(preceding_text) && followed_by_period?(following_text)

    # Skip if this references a DIFFERENT law (e.g., "artikel 1 van het koninklijk besluit van...")
    # These patterns indicate a reference to another specific law, not the parent law
    return true if references_other_law?(following_text)

    false
  end

  def references_other_law?(following_text)
    # Check if the reference is followed by "van het/de [law type]" indicating another law
    # Common patterns: "van het koninklijk besluit", "van de wet van [date]", "van het besluit van"
    following_text.match?(%r{
      \A\s*
      (?:,\s*§\s*\d+\s*)?  # Optional paragraph reference
      (?:,\s*(?:eerste|tweede|derde|vierde|vijfde|lid)\s*)?  # Optional lid reference
      \s*van\s+
      (?:
        het\s+(?:koninklijk|ministerieel)\s+besluit\s+van |  # KB/MB van [date]
        de\s+wet\s+van\s+\d |                                 # wet van [date]
        het\s+besluit\s+van\s+\d |                            # besluit van [date]
        de\s+verordening |                                    # EU verordening
        l[ea]\s+(?:loi|arrêté|règlement)\s+du                 # French: la loi du, l'arrêté du
      )
    }ix)
  end

  def at_line_start?(text)
    text.empty? || text.match?(/(?:\A|[\r\n])\s*\z/)
  end

  def followed_by_period?(text)
    text.match?(/\A\s*\./)
  end

  public

  ##
  # Builds a mapping of article identifiers to executive decisions that reference them
  #
  # @param main_law_numac [String] The NUMAC of the main law
  # @param exdecs [ActiveRecord::Relation<Exdec>] The executive decisions
  # @param language_id [Integer] The language ID (1 for NL, 2 for FR)
  # @return [Hash<String, Array>] Hash mapping article IDs to arrays of hashes containing exdec info
  #
  # @example
  #   mapping = build_article_exdec_mapping("1234567890", @exdecs, 1)
  #   # => { "5" => [{ exdec: <Exdec>, article: <Article>, references: ["5"] }], ... }
  #
  def build_article_exdec_mapping(_main_law_numac, exdecs, language_id)
    mapping = Hash.new { |h, k| h[k] = [] }

    return {} if exdecs.blank?

    # Log for performance monitoring (especially for large laws)
    start_time = Time.current
    Rails.logger.info("Building article-exdec mapping for #{exdecs.size} exdecs")

    # OPTIMIZATION: Use SQL to pre-filter articles that likely contain references
    # This avoids loading 100k+ articles into memory
    articles_by_numac = load_exdec_articles_with_references(exdecs, language_id)
    return {} if articles_by_numac.empty?

    total_articles = articles_by_numac.values.flatten.size
    Rails.logger.info("Loaded #{total_articles} exdec articles with references (filtered from potential #{exdecs.size * 40} articles)")

    process_exdec_articles(exdecs, articles_by_numac, mapping)

    duration = Time.current - start_time
    Rails.logger.info("Article-exdec mapping built in #{duration.round(2)}s: #{mapping.size} articles have references")

    # Convert to regular hash (remove default proc) so Rails cache can serialize it
    # .to_h on a Hash doesn't remove default proc, must use {}.merge or Hash[]
    {}.merge(mapping)
  end

  private

  def load_exdec_articles_with_references(exdecs, language_id)
    exdec_numacs = exdecs.map(&:exdec_numac).compact
    return {} if exdec_numacs.empty?

    # Build SQL pattern to match article references in both Dutch and French
    # Dutch: "artikel", "artikelen" (plural), "art.", "art "
    # French: "article", "articles" (plural), "art.", "art "
    # This filters out articles that just contain these words without a number reference
    patterns = []

    # Terms that appear in both Dutch and French legal texts
    terms = [
      'artikel ',   # Dutch singular
      'artikelen ', # Dutch plural
      'article ',   # French singular
      'articles ',  # French plural
      'art. ',      # Abbreviated with period (both languages)
      'Art. ',      # Capitalized abbreviation
      'art ' # Abbreviated without period (less common but exists)
    ]

    digits = ('0'..'9').to_a

    # Create patterns like "%artikel 1%", "%article 5%", etc.
    terms.each do |term|
      digits.each do |digit|
        patterns << "%#{term}#{digit}%"
      end
    end

    # Add special article types (regional designations and future law)
    special_article_types = [
      '%TOEKOMSTIG RECHT%', # Future law (NL)
      '%DROIT FUTUR%',                        # Future law (FR)
      '%_VLAAMS_GEWEST%',                     # Flemish Region (underscore)
      '%_WAALS_GEWEST%',                      # Walloon Region (underscore)
      '%_BRUSSELS_HOOFDSTEDELIJK_GEWEST%', # Brussels Capital Region (underscore)
      '%GEWEST%',                             # Generic GEWEST pattern
      '%REGION%'                              # Generic REGION pattern (FR)
    ]
    patterns.concat(special_article_types)

    # Create WHERE clause with OR conditions
    where_clause = patterns.map { 'article_text LIKE ?' }.join(' OR ')

    # Use SQL pattern matching to only load articles that reference article numbers
    # This is much faster than loading everything and filtering in Ruby
    exdec_articles = Article
                     .where(language_id: language_id, content_numac: exdec_numacs)
                     .where.not(article_type: 'ABO')
                     .where(where_clause, *patterns)
                     .order(:content_numac, :id)
                     .to_a

    exdec_articles.group_by(&:content_numac)
  end

  def process_exdec_articles(exdecs, articles_by_numac, mapping)
    exdecs.each do |exdec|
      next if exdec.exdec_numac.blank?

      articles = articles_by_numac[exdec.exdec_numac] || []
      process_articles_for_exdec(exdec, articles, mapping)
    end
  end

  def process_articles_for_exdec(exdec, articles, mapping)
    articles.each do |article|
      next if article.article_type == 'ABO'

      referenced_articles = extract_article_references(article.article_text)
      next if referenced_articles.empty?

      add_references_to_mapping(exdec, article, referenced_articles, mapping)
    end
  end

  def add_references_to_mapping(exdec, article, referenced_articles, mapping)
    referenced_articles.each do |ref|
      mapping[ref] << {
        exdec: exdec,
        article: article,
        references: referenced_articles
      }
    end
  end

  public

  # Finds the normalized article identifier from an article title or text
  #
  # @param article [Article] The article object
  # @return [String, nil] The normalized article identifier (e.g., "5", "6bis", "n", "1er")
  #
  def extract_article_id_from_article(article)
    return nil unless article

    text = article_text_for_extraction(article)
    extract_special_article_id(text) || extract_numeric_article_id(text) || extract_annex_article_id(text) || extract_edge_case_article_id(text)
  end

  private

  def article_text_for_extraction(article)
    text = article.article_title.to_s
    text.blank? ? article.article_text.to_s : text
  end

  def extract_special_article_id(text)
    # Match special article IDs like "14_WAALS_GEWEST" or "17 TOEKOMSTIG RECHT"
    pattern = %r{
      \A\s*(?:art(?:ikel|icle)?\.?\s*)?
      (\d+(?:/\d+)?(?:bis|ter|quater)?)
      (?:_|\s+)
      ((?:WAALS|VLAAMS|BRUSSELS(?:E)?(?:_HOOFDSTEDELIJK)?)(?:_|\s+)GEWEST|
       (?:WALLON|NE|FLAMAND|E|BRUXELLOIS(?:E)?)(?:_|\s+)(?:REGION|GEWEST)|
       TOEKOMSTIG(?:_|\s+)RECHT|
       DROIT(?:_|\s+)FUTUR)
      \b
    }ix
    return nil unless text =~ pattern

    # Combine both parts with underscore, normalize to lowercase
    "#{::Regexp.last_match(1)}_#{::Regexp.last_match(2)}".gsub(/\s+/, '_').downcase.strip
  end

  def extract_numeric_article_id(text)
    pattern = %r{
      \A\s*(?:art(?:ikel|icle)?\.?\s*)?
      (\d+(?:/\d+)?(?:e?r?|bis|ter|quater|quinquies|sexies|septies|octies|nonies|decies|undecies)?)
      \b
    }ix
    return nil unless text =~ pattern

    matched = ::Regexp.last_match(1).downcase.strip
    matched =~ /^[er]$/ ? nil : matched
  end

  def extract_annex_article_id(text)
    text =~ /\A\s*art(?:ikel|icle)?\.?\s*([A-Z]\d*)\b/i ? ::Regexp.last_match(1).downcase.strip : nil
  end

  def extract_edge_case_article_id(text)
    text =~ /\A\s*art(?:ikel|icle)?\.?\s*(\d+[A-Z]\d+)\b/i ? ::Regexp.last_match(1).downcase.strip : nil
  end
end
