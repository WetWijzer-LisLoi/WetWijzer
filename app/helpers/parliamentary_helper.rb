# frozen_string_literal: true

# Helper for cleaning and formatting parliamentary document content.
# Addresses common PDF extraction artifacts from Belgian parliamentary documents.
# Includes bilingual content filtering (Dutch/French) using stopword heuristics
# to strip wrong-language paragraphs from interleaved bilingual PDF extractions.
module ParliamentaryHelper
  # Capitalize the first letter of a title (handles titles starting with lowercase)
  def self.capitalize_title(title)
    return title if title.blank?

    title.sub(/\A(\s*)([a-zà-ÿ])/) { "#{::Regexp.last_match(1)}#{::Regexp.last_match(2).upcase}" }
  end

  # Format MP name from "De Block Maggie" to "De Block, Maggie"
  # The DB stores names as "FamilyName FirstName" where first name is the last word.
  def self.format_mp_name(name)
    return name if name.blank?

    parts = name.strip.split(/\s+/)
    return name if parts.size <= 1

    first_name = parts.pop
    "#{parts.join(' ')}, #{first_name}"
  end

  # ── Stopword / indicator lists for language detection ──────────────────────
  # These lists power the paragraph-level language classifier.
  # A paragraph's language is determined by counting hits from each list;
  # the language with more hits wins. Ties keep the paragraph (safe default).

  # High-frequency Dutch function words and parliamentary terms
  DUTCH_INDICATORS = %w[
    het een van der den des aan bij uit voor met tot door naar
    over ook nog als maar wel niet geen werd zijn haar hun deze
    dit dat die welke wordt worden werd werden heeft hebben gehad
    moet moeten kon kunnen zal zullen zou zouden mag mogen
    artikel artikelen wet wetten wetsvoorstel wetsontwerp
    amendement amendementen verslag verslagen commissie
    kamer senaat volksvertegenwoordigers wetgeving
    zitting legislatuur vergadering stemming goedgekeurd
    aangenomen verworpen ingediend betreffende houdende
    wijziging wijzigend gewijzigd opgeheven bijlage
    tekst aangenomen stukken ontwerp voorstel advies
    memorie toelichting bespreking hoorzitting
    behandeling eerste tweede lezing samenvattend
  ].freeze

  # High-frequency French function words and parliamentary terms
  FRENCH_INDICATORS = %w[
    les des une dans par sur avec pour aux qui que sont
    ont été dans cette cette ces mais aussi plus tout tous
    peut être avoir fait leur ses nos nos entre après sous
    est sont sera seront fait avait ayant
    projet proposition loi amendement rapport commission
    chambre sénat représentants législation
    session législature séance vote approuvé adopté
    rejeté déposé concernant portant modification modifiant
    modifié abrogé annexe texte adopté documents
    exposé motifs discussion audition examen
    première deuxième lecture résumé avis
  ].freeze

  # Bilingual header patterns: NL / FR pairs that span both columns.
  # When detected, the entire line is stripped (document_type badge shows this info).
  BILINGUAL_HEADER_PATTERNS = [
    /wetsvoorstel.*proposition\s+de\s+loi/i,
    /proposition\s+de\s+loi.*wetsvoorstel/i,
    /wetsontwerp.*projet\s+de\s+loi/i,
    /projet\s+de\s+loi.*wetsontwerp/i,
    /verslag.*rapport\s+fait/i,
    /rapport\s+fait.*verslag/i,
    /tekst\s+aangenomen.*texte\s+adopt[ée]/i,
    /texte\s+adopt[ée].*tekst\s+aangenomen/i,
    /amendementen.*amendements/i,
    /amendements.*amendementen/i,
    /memorie\s+van\s+toelichting.*expos[ée]\s+des\s+motifs/i,
    /expos[ée]\s+des\s+motifs.*memorie\s+van\s+toelichting/i,
    /belgische\s+kamer.*chambre\s+des\s+repr[ée]sentants/i,
    /chambre\s+des\s+repr[ée]sentants.*belgische\s+kamer/i,
    /belgische\s+senaat.*s[ée]nat\s+de\s+belgique/i,
    /s[ée]nat\s+de\s+belgique.*belgische\s+senaat/i,
    /commissie.*commission/i,
    /buitengewone\s+zitting.*session\s+extraordinaire/i,
    /session\s+extraordinaire.*buitengewone\s+zitting/i
  ].freeze
  # Collapse spaced-out OCR text from vector-rendered PDFs.
  # Converts "K A M E R" back to "KAMER", "c h a m b r e" to "chambre".
  # Detects runs of single characters separated by exactly one space.
  # Preserves word boundaries (double spaces, numbers, punctuation).
  #
  # @param text [String] Text possibly containing spaced-out words
  # @return [String] Text with spaced words collapsed
  def collapse_spaced_text(text)
    return text if text.blank?

    # Pattern: 3+ single letters each separated by exactly one space.
    # Word boundaries: start/end of string, double space, or non-letter char.
    # This regex matches sequences like "K A M E R" or "c h a m b r e"
    # but NOT "I am a" (since those are actual separate words in context).
    text.gsub(/(?<=[^A-Za-z\u00C0-\u00FF]|^)([A-Za-z\u00C0-\u00FF]) (?:[A-Za-z\u00C0-\u00FF] ){2,}[A-Za-z\u00C0-\u00FF](?=[^A-Za-z\u00C0-\u00FF]|$)/) do |match|
      match.gsub(' ', '')
    end
  end

  # Clean a description snippet for display in index cards.
  # Now simplified since OCR artifacts are cleaned at the scraper level
  # (parl_cleanup.py + parl_ocr_pipeline.py). Only does basic
  # whitespace normalization and truncation.
  #
  # @param desc [String, nil] Content snippet from DB
  # @return [String] Cleaned description suitable for card display
  def clean_parliamentary_description(desc, target_language: nil)
    return '' if desc.blank?

    lang = target_language || (I18n.locale == :nl ? 'nl' : 'fr')

    s = desc.to_s

    # Filter bilingual content (in case any mixed-language data remains)
    s = filter_bilingual_content(s, lang)

    # Normalize whitespace
    s = s.gsub(/\s+/, ' ').strip

    # If there's a SAMENVATTING/RÉSUMÉ marker, jump straight to it
    if (sam_match = s.match(/(?:SAMENVATTING|RÉSUMÉ)\s+(.+)/i))
      return sam_match[1].strip.truncate(250)
    end

    # Strip leading dossier/doc numbers
    s = s.sub(%r{\A\d{3,5}/\d{1,5}\s*}, '')
    s = s.sub(/\ADOC\s+\d{1,3}\s*/i, '')

    # Strip "SAMENVATTING" / "RÉSUMÉ" label
    s = s.sub(/\A(?:SAMENVATTING|RÉSUMÉ)\s*/i, '')

    s = s.gsub(/\s+/, ' ').strip
    s.present? ? s.truncate(250) : ''
  end

  # Extract voting summary from parliamentary document content.
  # Parses embedded vote results (article-by-article, amendments) and
  # extracts party names and member names involved in the debate.
  #
  # @param content [String] Full document content
  # @param language [String] 'nl' or 'fr'
  # @return [Hash] { votes: [...], parties: [...], final_result: String }
  def extract_voting_summary(content, language = 'nl')
    return nil if content.blank?

    parties = Set.new
    members = []

    # Known Belgian political parties
    party_pattern = /\A(?:N-VA|CD&V|PVDA-PTB|VB|PS|MR|Ecolo-Groen|Ecolo|Groen|Open\s*Vld|Vooruit|DéFI|cdH|LE|PVDA|PTB|sp\.a)\z/i

    # Extract party names from "(PARTY)" patterns
    content.scan(%r{\(([A-Z][A-Za-z\-/+&]{1,20}(?:-[A-Z]{2,5})?)\)}).each do |match|
      party = match[0]
      parties << party if party.match?(party_pattern)
    end

    # Extract member names with party affiliations
    # Pattern: "De heer/Mevrouw Name (PARTY)" or "M./Mme Name (PARTY)"
    if language == 'fr'
      content.scan(%r{(?:M\.|Mme|Mlle)\s+([A-Z][a-zéèêëàâïîôùûüç]+(?:\s+[A-Z][a-zéèêëàâïîôùûüç]+)*)\s+\(([A-Z][A-Za-z\-/+&]+(?:-[A-Z]+)?)\)}i).each do |name, party|
        next if name.length > 40  # skip OCR noise

        members << { name: name.strip, party: party.strip }
        parties << party.strip if party.strip.match?(party_pattern)
      end
    else
      content.scan(%r{(?:De\s+heer|Mevrouw|Mevr\.)\s+([A-Z][a-zéèêëàâïîôùûüç']+(?:\s+(?:Van\s+|De\s+|D')?[A-Z][a-zéèêëàâïîôùûüç']+)*)\s+\(([A-Z][A-Za-z\-/+&]+(?:-[A-Z]+)?)\)}i).each do |name, party|
        next if name.length > 40  # skip OCR noise

        members << { name: name.strip, party: party.strip }
        parties << party.strip if party.strip.match?(party_pattern)
      end
    end

    # Extract article-level votes (NL)
    votes = content.scan(%r{(?:Artikel|Art\.?)\s+(\d+[a-z]?(?:/\d+)?)\s+wordt\s+(eenparig\s+aangenomen|aangenomen(?:\s+met\s+[^.]+)?|verworpen(?:\s+met\s+[^.]+)?)}i).map do |art, result|
      { type: :article, ref: "Art. #{art}", result: result.strip }
    end

    # Extract amendment votes (NL)
    content.scan(/Amendement\s+nr\.\s*(\d+)\s+wordt\s+(eenparig\s+aangenomen|aangenomen(?:\s+met\s+[^.]+)?|verworpen(?:\s+met\s+[^.]+)?)/i).each do |nr, result|
      votes << { type: :amendment, ref: "Amend. #{nr}", result: result.strip }
    end

    # Extract article-level votes (FR)
    content.scan(%r{(?:L'article|Art\.?)\s+(\d+[a-z]?(?:/\d+)?)\s+est\s+(adopté(?:\s+[^.]+)?|rejeté(?:\s+[^.]+)?)}i).each do |art, result|
      votes << { type: :article, ref: "Art. #{art}", result: result.strip }
    end

    # Extract amendment votes (FR)
    content.scan(/(?:L'amendement|Amendement)\s+n[°o]\s*(\d+)\s+est\s+(adopté(?:\s+[^.]+)?|rejeté(?:\s+[^.]+)?)/i).each do |nr, result|
      votes << { type: :amendment, ref: "Amend. #{nr}", result: result.strip }
    end

    # Determine final result
    final_result = nil
    if language == 'fr'
      if content.match?(/(?:ensemble.*est\s+adopté|texte.*est\s+adopté|adopté\s+à\s+l'unanimité)/i)
        final_result = 'adopté'
      elsif content.match?(/(?:ensemble.*est\s+rejeté|texte.*est\s+rejeté)/i)
        final_result = 'rejeté'
      end
    elsif content.match?(/(?:geheel.*aangenomen|tekst.*aangenomen|eenparig\s+aangenomen\s+door)/i)
      final_result = 'aangenomen'
    elsif content.match?(/(?:geheel.*verworpen|tekst.*verworpen)/i)
      final_result = 'verworpen'
    end

    # Deduplicate members, keeping unique name+party combos
    members = members.uniq { |m| "#{m[:name]}|#{m[:party]}" }

    return nil if votes.empty? && parties.empty? && members.empty?

    {
      votes: votes,
      parties: parties.to_a.sort,
      members: members,
      final_result: final_result
    }
  end

  # Belgian Kamer seat distribution per legislature with party colors.
  # Used by the hemicycle SVG visualization.
  #
  # @param legislature [Integer] Legislature number (e.g., 55)
  # @param involved_parties [Array<String>] Parties mentioned in the document
  # @return [Array<Hash>] Party data with seat counts and colors
  PARTY_COLORS = {
    'PVDA-PTB' => '#8B0000', 'PVDA' => '#8B0000', 'PTB' => '#8B0000',
    'PS' => '#FF0000', 'Vooruit' => '#FF2D2D', 'sp.a' => '#FF2D2D',
    'Ecolo' => '#00A651', 'Groen' => '#83B81A', 'Ecolo-Groen' => '#4CAF50',
    'cdH' => '#FF8C00', 'Les Engagés' => '#00B2A9', 'LE' => '#00B2A9',
    'DéFI' => '#C8198C',
    'CD&V' => '#FF6600', 'cd&v' => '#FF6600',
    'Open Vld' => '#0087DC', 'MR' => '#0055A4',
    'N-VA' => '#FFD700', 'VB' => '#004A2F',
    'Anders' => '#888888'
  }.freeze

  LEGISLATURE_SEATS = {
    56 => {
      'N-VA' => 23, 'VB' => 20, 'MR' => 18, 'PS' => 16,
      'Les Engagés' => 15, 'PVDA-PTB' => 15, 'Vooruit' => 13,
      'cd&v' => 11, 'Groen' => 9, 'Ecolo' => 8,
      'DéFI' => 1, 'Anders' => 1
    },
    55 => {
      'N-VA' => 25, 'VB' => 18, 'PS' => 20, 'CD&V' => 12,
      'Open Vld' => 12, 'MR' => 14, 'Vooruit' => 9,
      'Ecolo' => 13, 'Groen' => 8, 'PVDA-PTB' => 12,
      'cdH' => 5, 'DéFI' => 2
    },
    54 => {
      'N-VA' => 33, 'PS' => 23, 'CD&V' => 18, 'Open Vld' => 14,
      'MR' => 20, 'sp.a' => 13, 'Ecolo' => 6, 'Groen' => 6,
      'cdH' => 9, 'PVDA-PTB' => 2, 'DéFI' => 2, 'VB' => 3,
      'LE' => 1
    },
    53 => {
      'N-VA' => 27, 'PS' => 26, 'CD&V' => 17, 'Open Vld' => 13,
      'MR' => 18, 'sp.a' => 13, 'Ecolo' => 8, 'Groen' => 5,
      'cdH' => 9, 'VB' => 12, 'DéFI' => 2
    }
  }.freeze

  def hemicycle_party_data(legislature, involved_parties = [])
    seats = LEGISLATURE_SEATS[legislature]
    return [] unless seats

    # Normalize involved party names for matching
    involved_set = involved_parties.to_set(&:downcase)

    seats.map do |party, count|
      {
        party: party,
        seats: count,
        color: PARTY_COLORS[party] || '#888888',
        involved: involved_set.include?(party.downcase) ||
          involved_set.any? { |p| party.downcase.include?(p) || p.include?(party.downcase) }
      }
    end
  end

  # Known generic placeholder titles from the dekamer.be scraper.
  # These are web page titles, not actual document titles.
  GENERIC_PARL_TITLES = [
    'Opzoeken in documenten en databanken',
    'Recherche dans les documents et banques de données',
    'Search in documents and databases'
  ].freeze

  # Clean a parliamentary title for display.
  # Strips dossier number prefixes and generic placeholder titles.
  #
  # @param title [String, nil] Raw title from DB
  # @param dossier [String, nil] Dossier number for fallback
  # @param doc [Hash, nil] Full document hash for extracting title from content
  # @return [String] Cleaned title
  def clean_parliamentary_title_display(title, dossier = nil, doc: nil)
    s = title.to_s.strip

    # Detect generic placeholder titles
    is_generic = s.blank? || GENERIC_PARL_TITLES.any? { |g| s.casecmp?(g) }

    if is_generic
      # Try to extract a meaningful title from the document content or type
      extracted = extract_title_from_content(doc) if doc
      return extracted if extracted.present?

      # Fall back to document_type + dossier
      if doc && doc[:document_type].present? && dossier.present?
        type_label = doc[:document_type].gsub('_', ' ')
        return "#{type_label.capitalize} #{dossier}"
      end

      return "Dossier #{dossier}" if dossier.present?

      return ''
    end

    # Strip "Doc ss", "Docss", "pocs2", etc.
    s = s.sub(/\A(?:Doc\s*s{0,2}|poc\s*s?\d?|oc)\s+/i, '')

    # Strip leading dossier/doc number
    s = s.sub(%r{\A\d{1,5}/\d{1,5}\s+}, '')

    # Strip "s2 " prefix
    s = s.sub(/\As\d?\s+/i, '')

    s = s.strip
    s.present? ? s : "Dossier #{dossier}"
  end

  # Extract a meaningful title from document content.
  # Looks for patterns like "WETSONTWERP tot ..." or "VOORSTEL VAN RESOLUTIE over ..."
  # in the first 500 chars of content.
  #
  # @param doc [Hash] Document hash with :description key
  # @return [String, nil] Extracted title or nil
  def extract_title_from_content(doc)
    content = doc[:description].to_s
    return nil if content.blank?

    # Collapse spaced text first
    content = collapse_spaced_text(content)
    content = content.gsub(/[\r\n]+/, ' ').gsub(/\s+/, ' ')

    # Try to find document type declarations in content
    patterns = [
      # NL patterns – broader preposition matching
      # Terminator: period/comma + space, opening paren, or end of string
      /(?:WETSONTWERP|WETSVOORSTEL)\s+(tot|houdende|betreffende|inzake|van|de|het|strekkende)\s+(.{10,150}?)(?:[.,]\s|\(|$)/i,
      /VOORSTEL\s+VAN\s+(?:RESOLUTIE|WET|BIJZONDERE\s+WET)\s+(over|teneinde|betreffende|tot|de|het|strekkende)\s+(.{10,150}?)(?:[.,]\s|\(|$)/i,
      # FR patterns
      /(?:PROJET\s+DE\s+LOI|PROPOSITION\s+DE\s+LOI)\s+(modifiant|relatif|portant|visant|de|la|le|les|en)\s+(.{10,150}?)(?:[.,]\s|\(|$)/i,
      /PROPOSITION\s+DE\s+R[ÉE]SOLUTION\s+(visant|relative|sur|de|la|le)\s+(.{10,150}?)(?:[.,]\s|\(|$)/i
    ]

    patterns.each do |pattern|
      next unless (m = content.match(pattern))

      full_match = m[0].strip
      # Clean up: strip trailing punctuation and capitalize document type
      full_match = full_match.sub(/[.,;:]+\z/, '').strip
      # Capitalize the first letter (document type names like "wetsvoorstel" → "Wetsvoorstel")
      full_match = full_match[0].upcase + full_match[1..] if full_match.length > 1
      return full_match.truncate(150) if full_match.length > 15
    end

    nil
  end

  # Clean a jurisprudence summary for display.
  # Strips thesaurus tags like "Thesaurus CAS:", "UTU-thesaurus:", extracts "Vrije woorden:".
  #
  # @param summary [String, nil] Raw summary from DB
  # @return [String] Cleaned summary
  def clean_jurisprudence_summary(summary)
    return '' if summary.blank?

    s = summary.to_s.strip

    # Strip ECLI metadata template noise (search form debug output from old scrapes)
    s = s.gsub(/^ecli_(?:input|prefixe|pays|cour|cour_old|annee|ordre|typedec|datedec|chambre|nosuite)\b[^\n]*/i, '')
    s = s.gsub(/^Invalid ECLI ID[^\n]*/i, '')
    s = s.gsub(/^Numéro ECLI invalide[^\n]*/i, '')
    s = s.gsub(/^LienECLI\b[^\n]*/i, '')
    s = s.gsub(/\n{2,}/, "\n").strip
    return '' if s.blank?

    # If it contains "Vrije woorden:", extract that part
    if (match = s.match(/Vrije woorden\s*:\s*(.+)/im))
      content = match[1].strip
      content = content.sub(/\s*Thesaurus\s+CAS\s*:.*\z/im, '').strip
      content = content.sub(/\s*UTU-thesaurus\s*:.*\z/im, '').strip
      return content.truncate(300) if content.length > 10
    end

    # Strip leading thesaurus tags
    if s.match?(/\AThesaurus\s+CAS\s*:/i)
      s = s.sub(/\AThesaurus\s+CAS\s*:\s*[^\n:]+/i, '')
      s = s.sub(/\AUTU-thesaurus\s*:\s*[^\n:]+/i, '')
      s = s.strip.sub(/\A[-:, ]+/, '').strip
    end

    # Strip "Datum van uitspraak:" metadata dumps
    if s.match?(/\ADatum van uitspraak\s*:/i)
      lines = s.split("\n")
      meaningful = lines.find { |l| l.strip.length > 50 && !l.match?(/\A(Datum|Rolnummer|Kamer|woonplaats|met als)/i) }
      return meaningful.to_s.strip.truncate(300) if meaningful
    end

    s.truncate(300)
  end

  # Clean jurisprudence full text for display.
  # Strips repeating page headers, page numbers, and OCR artifacts from scanned court decisions.
  # When rich_text with [[IMG:filename|WxH]] markers is provided, renders images inline.
  #
  # @param text [String, nil] Raw full text from DB (or rich_text with image markers)
  # @param case_number [String, nil] ECLI identifier for image URL construction
  # @return [String] Cleaned full text with HTML structure (html_safe)
  def clean_jurisprudence_full_text(text, case_number: nil)
    return '' if text.blank?

    # First pass: strip form feed characters and normalize
    text = text.gsub("\f", "\n").gsub("\r\n", "\n")

    lines = text.lines.map(&:rstrip)
    cleaned = []
    prev_blank = false
    skip_next = 0

    lines.each_with_index do |line, idx|
      # Skip lines marked for removal by lookahead
      if skip_next.positive?
        skip_next -= 1
        next
      end

      stripped = line.strip

      # Skip empty lines (but keep max 1 blank line between paragraphs)
      if stripped.empty?
        cleaned << '' unless prev_blank
        prev_blank = true
        next
      end
      prev_blank = false

      # Skip repeating page headers: "Rolnummer" / "Rolnumme1" / "Rol nummer" (OCR variations)
      next if stripped.match?(/\ARol\s*numme\w*\s*\z/i)

      # Skip "rechtbank van eerste aanleg ..." / "hof van beroep ..." / "cour d'appel ..." standalone headers
      # These are page headers that repeat on every page of the scanned document
      # Handle OCR typos: "afdeli ng" (space), "afdellng", etc.
      next if stripped.match?(/\A(?:rechtbank|hof|cour|tribunal)\s+(?:van|de|du|d')\b/i) && stripped.length < 120 &&
              (stripped.match?(/afdel\w*\s*\w*g|division|section|kamer|chambre/i) ||
               lines[idx + 1]&.strip&.match?(/\A(?:Antwerpen|Brussel|Gent|Brugge|Luik|Mons|Liège|Bruxelles|Leuven|Mechelen|Hasselt|Tongeren|Dendermonde|Kortrijk|Turnhout|Ieper|Oudenaarde|Veurne|Dinant|Marche|Namur|Arlon|Neufchâteau|Eupen|Charleroi|Verviers|Bergen)/i))

      # Skip standalone city names that are part of split court headers
      # (only when preceded by a court-like line)
      if stripped.match?(/\A(?:Antwerpen|Brussel|Gent|Brugge),?\s*(?:afdeling)?\s*\z/i) &&
         cleaned.last&.strip&.match?(/rechtbank|hof|cour|tribunal/i)
        cleaned.pop # Remove the preceding court line too
        next
      end
      # "Antwerpen" standalone after "rechtbank van eerste aanleg"
      if stripped.match?(/\A(?:Antwerpen|Brussel|Gent|Brugge|Luik|Leuven),?\s*(?:afdeling)?\s*$/i) &&
         idx.positive? && lines[idx - 1]&.strip&.match?(/rechtbank|eerste\s+aanleg|hof\s+van/i)
        next
      end

      # Skip standalone page numbers: "p. 2", "p.3", "p. 10", "p.S" (OCR), "/ p. 4"
      next if stripped.match?(%r{\A[/\s]*p\.\s*\w{1,3}\s*\z}i)

      # Skip JuPortal PDF page markers: "X-18.860-6/30", "IX-10.902-1/20", "VII-7080-1/3"
      # Format: {optional-roman}-{case_ref}-{page}/{total}  (standalone line)
      next if stripped.match?(%r{\A[IVXLC]*-?[\d.]+-\d+/\d+\z})

      # Skip JuPortal system noise: "ERROR JUPORTARobotRecordLienECLI", "RobotRecordLienECLI", etc.
      next if stripped.match?(/\A(?:ERROR\s+)?JUPORTA/i)
      next if stripped.match?(/\ARobotRecord/i)

      # Skip standalone chamber identifiers: "ACl kamer", "AC1 kamer", "KG kamer" (OCR mixes case)
      next if stripped.match?(/\A[A-Za-z]{1,4}\d?\s+[Kk]amer\s*\z/)
      # Also "Kamer ACl" / "Kamer AC1" standalone
      next if stripped.match?(/\A[Kk]amer\s+[A-Za-z]{1,4}\d?\s*\z/)

      # Skip standalone "Vonnisnr" / "Vonnisnummer" / "Vonnlsnr" (OCR) lines
      next if stripped.match?(/\AVonn[il]s\s*n(?:umme)?r\.?\s*\z/i)

      # Skip standalone "Vonnisnummer / Griffienummer" type headers
      next if stripped.match?(%r{\AVonnis(?:nummer)?\s*/\s*Griffie}i)

      # Skip standalone "/" lines (page separators)
      next if stripped.match?(%r{\A/\s*\z})

      # Skip lines that are just dots, dashes, equals or stars (separator lines)
      next if stripped.match?(/\A[·•\-=\s*_]{5,}\z/)

      # Skip "Repertorium nummer/ Europees" standalone header
      next if stripped.match?(/\ARepertorium\s+nummer/i)

      cleaned << line
    end

    # Consolidate excessive blank lines
    result = cleaned.join("\n")
    result.gsub!(/\n{3,}/, "\n\n")
    result.strip!

    # Second pass: fix hyphenation artifacts from PDF line breaks
    # "woon-\nplaats" -> "woonplaats", "ver-\nnietiging" -> "vernietiging"
    result.gsub!(/([a-zéèêëàâäùûüôöîïç])-\n([a-zéèêëàâäùûüôöîïç])/, '\1\2')

    # Strip VIexturg page markers embedded mid-paragraph (use newline to avoid joining lines)
    result.gsub!(%r{\s*V[Il]?e?xturg\s*-\s*[\d.]+\s*-\s*\d+/\d+\s*}i, "\n")

    # Strip Roman-numeral page markers embedded inline: "IX-10.902-9/20", "VII-7080-1/3"
    result.gsub!(%r{\s*[IVXLC]+-[\d.]+-\d+/\d+\s*}, "\n")

    # Collapse spaced-out letters: "A R R Ê T" → "ARRÊT", "D É C I S I O N" → "DÉCISION"
    result.gsub!(/\b((?:[A-ZÉÈÊÀÂÙÛÔÎÇÖ]\s){2,}[A-ZÉÈÊÀÂÙÛÔÎÇÖ])\b/) { |m| m.gsub(' ', '') }

    # Convert ASCII guillemets to proper French quotation marks
    result.gsub!('<<', '«')
    result.gsub!('>>', '»')

    # Third pass: build HTML with proper paragraph wrapping and section styling
    html_parts = []
    current_para = []
    section_open = false # Track if we have an open collapsible section
    @in_bullet_list = false # Track if we have an open <ul>
    intro_mode = true # Before first heading: preserve line breaks (court info, parties)
    para_style = nil # nil = normal paragraph, :blockquote = legal reasoning block
    last_ended_colon = false # Track if previous content ended with ':' (enables dash bullets)
    signature_mode = false # After "Ainsi prononcé" / "Aldus uitgesproken": preserve line breaks, centered

    flush_para = lambda do
      # Close any open bullet list before starting a paragraph
      if @in_bullet_list
        html_parts << '</ul>'
        @in_bullet_list = false
      end
      unless current_para.empty?
        joined = intro_mode || signature_mode ? current_para.join("<br>\n") : current_para.join(' ')
        # Italicize quoted text after joining (handles multi-line quotes)
        joined = joined.gsub(/«([^»]+)»/, '<em>«\1»</em>')
        joined = joined.gsub(/&quot;([^&]+)&quot;/, '<em>&quot;\1&quot;</em>')
        html_parts << if para_style == :blockquote
                        "<blockquote class=\"mb-3 pl-4 border-l-2 border-gray-300 dark:border-gray-600 text-gray-600 dark:text-gray-400 italic\">#{joined}</blockquote>"
                      elsif intro_mode
                        "<p class=\"mb-1 text-sm leading-relaxed text-gray-600 dark:text-gray-400\">#{joined}</p>"
                      elsif signature_mode
                        "<p class=\"mb-1 text-sm text-center text-gray-500 dark:text-gray-400\">#{joined}</p>"
                      else
                        "<p class=\"mb-3\">#{joined}</p>"
                      end
        current_para.clear
        para_style = nil
      end
    end

    close_section = lambda do
      if section_open
        html_parts << '</div></div>' # Close content div + collapse wrapper
        section_open = false
      end
    end

    chevron_svg = '<svg xmlns="http://www.w3.org/2000/svg" class="w-5 h-5 shrink-0 transition-transform text-gray-500 dark:text-gray-400" viewBox="0 0 20 20" fill="currentColor" data-collapse-target="icon"><path fill-rule="evenodd" d="M5.23 7.21a.75.75 0 011.06.02L10 10.94l3.71-3.71a.75.75 0 111.06 1.06l-4.24 4.24a.75.75 0 01-1.06 0L5.21 8.29a.75.75 0 01.02-1.08z" clip-rule="evenodd" /></svg>'

    # Lambda to emit a collapsible section heading (h3-level)
    emit_section_heading = lambda do |heading_html, css_classes|
      flush_para.call
      close_section.call
      intro_mode = false # First heading ends the intro section
      html_parts << '<div data-controller="collapse" data-collapse-expanded-value="true">'
      html_parts << '<button type="button" class="w-full flex items-center justify-between text-left focus:outline-hidden cursor-pointer" data-action="click->collapse#toggle" data-collapse-target="button" aria-expanded="true">'
      html_parts << "<h3 class=\"#{css_classes}\">#{heading_html}</h3>"
      html_parts << chevron_svg
      html_parts << '</button>'
      html_parts << '<div data-collapse-target="content" class="mt-2">'
      section_open = true
    end

    result.each_line do |line|
      stripped = line.strip

      if stripped.empty?
        flush_para.call
        next
      end

      # Strip VIexturg / Vlexturg page markers: "VIexturg - 21.944 - 1/34"
      next if stripped.match?(%r{\AV[Il]?e?xturg\s*-\s*[\d.]+\s*-\s*\d+/\d+}i)

      # Strip standalone page numbers: "2", "3", "4" (single digit on a line)
      next if stripped.match?(/\A\d{1,3}\z/) && stripped.length <= 3

      # Strip separator lines (dashes, dots, underscores)
      next if stripped.match?(/\A[-–=_.·•\s]{5,}\z/)

      # Strip "Print deze pagina" / "Afdrukformaat" / "Nieuwe JUPORTAL" UI artifacts
      next if stripped.match?(/\A(?:Print deze pagina|Afdrukformaat|Nieuwe JUPORTAL|Sluit Tab|Taille)/i)
      next if stripped.match?(/\A[SMLX]{1,2}\z/) # S, M, L, XL format buttons
      # "Nouvelle recherche" / "Nieuwe zoekopdracht" UI links
      next if stripped.match?(/\A(?:Nouvelle\s+recherche|Nieuwe\s+(?:JUPORTAL-)?zoekopdracht)/i)

      # Strip JuPortal system noise (ERROR, RobotRecord, page markers with Roman numerals)
      next if stripped.match?(/\A(?:ERROR\s+)?JUPORTA/i)
      next if stripped.match?(/\ARobotRecord/i)
      next if stripped.match?(%r{\A[IVXLC]*-?[\d.]+-\d+/\d+\z})
      # ECLI metadata template noise (search form debug output)
      next if stripped.match?(/\Aecli_(?:input|prefixe|pays|cour|cour_old|annee|ordre|typedec|datedec|chambre|nosuite)\b/i)
      next if stripped.match?(/\AInvalid ECLI ID/i)
      next if stripped.match?(/\ANuméro ECLI invalide/i)
      next if stripped.match?(/\ALienECLI\b/i)

      # Handle image markers: [[IMG:p7_2.jpeg|1358x722]] - both standalone and inline
      if case_number.present? && stripped.include?('[[IMG:')
        flush_para.call
        # Split line on image markers, escape text parts, render image parts
        parts = stripped.split(/(\[\[IMG:.+?\|\d+x\d+\]\])/)
        parts.each do |part|
          img_m = part.match(/\A\[\[IMG:(.+?)\|(\d+)x(\d+)\]\]\z/)
          if img_m
            img_url = "/jurisprudence/#{case_number}/image/#{ERB::Util.html_escape(img_m[1])}"
            html_parts << "<figure class=\"my-4 text-center\"><img src=\"#{img_url}\" alt=\"\" loading=\"lazy\" class=\"inline-block h-auto rounded-lg border border-gray-200 dark:border-gray-700\" style=\"max-width: min(100%, #{[img_m[2].to_i, 800].min}px); max-height: 500px;\"></figure>"
          elsif part.strip.length.positive?
            html_parts << "<p class=\"mb-3\">#{ERB::Util.html_escape(part.strip)}</p>"
          end
        end
        next
      end

      escaped = ERB::Util.html_escape(stripped)

      # === INTRO SECTION FORMATTING (before first heading) ===
      if intro_mode
        # Court name / chamber lines: mostly uppercase, >10 chars (allows "VIe", "d'", etc.)
        # Exclude reference numbers with digits/slashes (e.g., "A. 232.515/VI-21.944")
        alpha_chars = stripped.gsub(/[^a-zA-ZÀ-ÖØ-öø-ÿ]/, '')
        upper_ratio = alpha_chars.empty? ? 0 : alpha_chars.gsub(/[^A-ZÀ-ÖØ-Ý]/, '').length.to_f / alpha_chars.length
        if stripped.length >= 10 && upper_ratio > 0.75 && stripped.match?(/[A-Z]{3,}/) && !stripped.match?(/\d{2,}/)
          flush_para.call
          html_parts << "<p class=\"text-center font-bold text-gray-900 dark:text-white mb-1\">#{escaped}</p>"
          next

        # "ARRÊT" / "ARREST" / "BESCHIKKING" standalone → centered, bold, larger
        elsif stripped.match?(/\A(?:ARRÊT|ARREST|BESCHIKKING|JUGEMENT|VONNIS)\z/i)
          flush_para.call
          html_parts << "<p class=\"text-center font-bold text-lg text-gray-900 dark:text-white mt-4 mb-4\">#{escaped}</p>"
          next

        # Case number line: "n° 249.492 du 14 janvier 2021", "no 249.492..."
        elsif stripped.match?(/\A(?:n[°o]\s+|nr\.?\s+)\d/i)
          flush_para.call
          html_parts << "<p class=\"text-center text-gray-700 dark:text-gray-300 mb-4\">#{escaped}</p>"
          next

        # "En cause :" / "In zake :" / "contre :" / "tegen :" - bold labels
        elsif stripped.match?(/\A(?:En cause|In zake|contre|tegen|Partie intervenante)\s*:/i)
          flush_para.call
          html_parts << "<p class=\"font-semibold text-gray-900 dark:text-white mt-3 mb-1\">#{escaped}</p>"
          next
        end
      end

      # === SECTION HEADING DETECTION ===

      # Roman numeral sections: "I. Onderwerp van de beroepen", "II. Procédure", "III. Faits"
      if stripped.match?(/\A[IVXLC]+\.\s+\S/)
        emit_section_heading.call(escaped, 'text-base italic text-gray-900 dark:text-white')

      # Major case components (standalone, mixed-case, often italic in PDF):
      # "Het Arbitragehof,", "Het Grondwettelijk Hof,", "wijst na beraad het volgende arrest :"
      elsif stripped.match?(/\A(?:Het (?:Arbitragehof|Grondwettelijk Hof|Hof),?|wijst na beraad|In zake\s*:)/i)
        flush_para.call
        html_parts << "<p class=\"mb-3 italic text-gray-600 dark:text-gray-400\">#{escaped}</p>"

      # Court composition blocks: "samengesteld uit de voorzitters..."
      elsif stripped.match?(/\Asamengesteld uit/i)
        flush_para.call
        html_parts << "<p class=\"mb-3 text-sm italic text-gray-500 dark:text-gray-400\">#{escaped}</p>"

      # "Arrest nr. 107/98" / "Rolnummers 1182, 1183"
      elsif stripped.match?(/\A(?:Arrest\s+nr\.|Rolnummer|Arrêt\s+n°)/i)
        flush_para.call
        html_parts << "<p class=\"mb-2 font-semibold text-gray-800 dark:text-gray-200\">#{escaped}</p>"

      # All-caps section titles > 8 chars: "BESLISSING VAN HET HOF", "CASSATIEMIDDEL", etc.
      elsif stripped.match?(/\A[A-ZÉÈÊÀÂÙÛÔÎÇÖ\s\-'.]{8,}\z/) && stripped.length < 80
        emit_section_heading.call(escaped, 'text-sm font-bold uppercase tracking-wide text-gray-800 dark:text-gray-200')

      # Sub-section numbering: "V.1. Thèse de la partie requérante", "VI.2. Appréciation"
      elsif stripped.match?(/\A[IVXLC]+\.\d+\.\s+\S/)
        flush_para.call
        html_parts << "<h4 class=\"text-sm font-semibold text-gray-800 dark:text-gray-200 mt-4 mb-1 pl-4\">#{escaped}</h4>"

      # Lettered sub-sections: "A. Standpunt van de...", "B. Beoordeling"
      # Only match short standalone lines (not "M. Christian Amelynck, premier...")
      elsif stripped.match?(/\A[A-Z]\.\s+[A-ZÉÈÊÀ]/) && stripped.length < 60
        flush_para.call
        html_parts << "<h4 class=\"text-sm font-semibold text-gray-800 dark:text-gray-200 mt-4 mb-1\">#{escaped}</h4>"

      # Numbered decision points: "1. Krachtens de artikelen...", "2. De overheid..."
      elsif stripped.match?(/\A\d{1,3}\.\s+[A-ZÉÈÊÀÂÙÛÔÎÇ]/)
        flush_para.call
        dot_pos = escaped.index('.')
        num_part = escaped[0..dot_pos]
        rest_part = escaped[(dot_pos + 2)..]
        current_para << "<strong class=\"text-gray-900 dark:text-white\">#{num_part}</strong> #{rest_part}"

      # "PAR CES MOTIFS" / "OM DEZE REDENEN" / "BESLUIT" - decision header
      # Allow trailing comma, period, colon (e.g., "PAR CES MOTIFS,")
      elsif stripped.match?(/\A(?:PAR CES MOTIFS|OM DEZE REDENEN|DISPOSITIF|BESCHIKKEND GEDEELTE|BESLUIT|BESLISSING)\s*[,:.]?\s*\z/i)
        emit_section_heading.call(escaped, 'text-base font-bold text-gray-900 dark:text-white uppercase tracking-wide')

      # "LE CONSEIL D'ÉTAT DÉCIDE :" / "HET HOF BESLIST :" - decision sub-header
      elsif stripped.match?(/\A(?:LE CONSEIL D.ÉTAT DÉCIDE|L[EA] COUR|HET HOF BESLIST|DE RAAD)\s*:?\s*\z/i)
        flush_para.call
        html_parts << "<p class=\"font-bold text-center text-gray-900 dark:text-white mt-2 mb-3\">#{escaped}</p>"

      # "Article 1er." / "Article 2." / "Artikel 1." - decision article numbers
      elsif stripped.match?(/\A(?:Article|Artikel)\s+\d+(?:er|ère|e|ste|de)?\s*\.\s*\z/i)
        flush_para.call
        html_parts << "<p class=\"font-semibold text-gray-900 dark:text-white mt-4 mb-1\">#{escaped}</p>"

      # Bullet list items: "• text", "◦ text", "○ text" always; "-" only after colon or in existing list
      elsif stripped.match?(/\A[•◦○]\s+\S/) ||
            (stripped.match?(/\A-\s+\S/) && (@in_bullet_list || last_ended_colon))
        flush_para.call
        # Strip the bullet character and leading space
        bullet_text = ERB::Util.html_escape(stripped.sub(/\A[•◦○-]\s+/, ''))
        # Open a <ul> if we're not already in one
        unless @in_bullet_list
          html_parts << '<ul class="mb-3 ml-6 list-disc space-y-1 text-gray-700 dark:text-gray-300">'
          @in_bullet_list = true
        end
        html_parts << "<li>#{bullet_text}</li>"

      else
        # Close any open bullet list before regular content
        if @in_bullet_list
          html_parts << '</ul>'
          @in_bullet_list = false
        end
        # Detect signature block: "Ainsi prononcé" / "Aldus uitgesproken" / "Aldus te ... uitgesproken"
        if !signature_mode && stripped.match?(/\A(?:Ainsi\s+prononc|Aldus\s+(?:te\s+\S+\s+)?uitgesproken)/i)
          flush_para.call
          signature_mode = true
        end
        current_para << escaped
      end
      # Track if this line ends with ':' for context-aware dash bullet detection
      last_ended_colon = stripped.end_with?(':')
    end

    flush_para.call
    # Close any trailing bullet list
    if @in_bullet_list
      html_parts << '</ul>'
      @in_bullet_list = false
    end
    close_section.call
    html_parts.join("\n").html_safe
  end

  # Clean parliamentary document content for the show page.
  def clean_parliamentary_content(content, target_language: nil)
    return '' if content.blank?

    lang = target_language || (I18n.locale == :nl ? 'nl' : 'fr')

    # Step 0: Strip wetgevingstechnische nota appendix.
    # These bilingual annexes always contain garbled interleaved NL/FR text from
    # both PDF columns. Detect the start marker and truncate.
    truncated = strip_wetgevingstechnische_nota(content)

    # Step 0.5: Collapse spaced-out OCR text (e.g. "K A M E R" → "KAMER")
    truncated = collapse_spaced_text(truncated)

    # Step 1: Filter out wrong-language paragraphs
    filtered = filter_bilingual_content(truncated, lang)

    # Step 2: Line-level cleanup
    lines = filtered.lines.map(&:rstrip)
    cleaned_lines = []
    previous_lines = Set.new

    # Line-level language indicators for catching interleaved bilingual lines
    target_indicators = lang == 'fr' ? FRENCH_INDICATORS : DUTCH_INDICATORS
    opposing_indicators = lang == 'fr' ? DUTCH_INDICATORS : FRENCH_INDICATORS

    lines.each do |line|
      stripped = line.strip

      # Keep blank lines (preserve paragraph spacing from PDF)
      if stripped.empty?
        cleaned_lines << '' unless cleaned_lines.last == ''
        next
      end

      # Skip duplicate lines
      normalized = stripped.downcase.gsub(/\s+/, ' ')
      next if previous_lines.include?(normalized)

      previous_lines.add(normalized)

      # Skip noise
      next if skip_header_line?(stripped)
      next if skip_metadata_line?(stripped)
      next if skip_running_doc_header?(stripped)

      # Line-level language filter: catch single lines that are clearly wrong language.
      # Only applies to lines >40 chars with strong opposing signal (4+ indicators, 3:1 ratio).
      if stripped.length > 40
        words = stripped.downcase.scan(/[a-zéèêëàâäùûüôöîïçæœ]+/)
        t_hits = words.count { |w| target_indicators.include?(w) }
        o_hits = words.count { |w| opposing_indicators.include?(w) }
        if (t_hits + o_hits) >= 4 && o_hits > t_hits * 3
          next # Skip clearly wrong-language line
        end
      end
      # Ensure HOOFDSTUK / CHAPITRE lines start a new paragraph.
      # These are chapter headings in parliamentary documents that need their
      # own paragraph block for the HTML formatter to detect them as headings.
      cleaned_lines << '' if stripped.match?(/\A(?:HOOFDSTUK|CHAPITRE)\s+\d/i) && cleaned_lines.last != ''

      # Ensure amendment numbers start a new paragraph: "Nr. 1 VAN DE DAMES..."
      cleaned_lines << '' if stripped.match?(/\ANr\.\s*\d+\s+VAN\s/) && cleaned_lines.last != ''

      # Ensure article headings start a new paragraph: "Art. 3", "Art.5", "Artikel 1"
      cleaned_lines << '' if stripped.match?(/\AArt(?:ikel)?\.?\s*\d/i) && cleaned_lines.last != ''

      # Ensure section labels start a new paragraph: "VERANTWOORDING", "TOELICHTING", etc.
      if stripped.match?(/\A(?:VERANTWOORDING|TOELICHTING|COMMENTAIRE|JUSTIFICATION|DÉVELOPPEMENTS|RÉSUMÉ|SAMENVATTING)\z/i) && cleaned_lines.last != ''
        cleaned_lines << ''
      end

      # Ensure author name blocks start a new paragraph.
      # Pattern: "'Firstname LASTNAME (PARTY)" or "Firstname LASTNAME (PARTY)"
      if stripped.match?(/\A['\u2018]?[A-ZÉÈÊÀÂ][a-zéèêëàâäùûüôöîïç]+\s+[A-ZÉÈÊÀÂÙÛÔÎÇ]{2,}(?:\s+[A-ZÉÈÊÀÂÙÛÔÎÇ]+)*\s*\([A-Za-z\s\-.]+\)\s*\z/)
        # Only if previous line was NOT also an author name (group them together)
        prev = cleaned_lines.last&.strip
        cleaned_lines << '' if !prev&.match?(/\A['\u2018]?[A-ZÉÈÊÀÂ][a-zéèêëàâäùûüôöîïç]+\s+[A-ZÉÈÊÀÂÙÛÔÎÇ]{2,}/) && cleaned_lines.last != ''
      end

      cleaned_lines << line
    end

    # Step 3: Post-processing
    result = cleaned_lines.join("\n")

    # Fix hyphenation artifacts from PDF line breaks:
    # "woon-\nplaats" -> "woonplaats"
    result.gsub!(/([a-zéèêëàâäùûüôöîïç])-\n([a-zéèêëàâäùûüôöîïç])/, '\1\2')

    # Ensure structural markers have paragraph breaks (double newline) on both sides.
    # These patterns match lines that start with structural markers but only have
    # single newlines around them (from PDF extraction).

    # Section labels: ensure blank line after (they already have blank before from line-level rules)
    result.gsub!(/\n((?:VERANTWOORDING|TOELICHTING|COMMENTAIRE|JUSTIFICATION|DÉVELOPPEMENTS|RÉSUMÉ|SAMENVATTING)\s*)\n(?!\n)/) do
      "\n#{::Regexp.last_match(1)}\n\n"
    end

    # Amendment numbers: ensure blank line before AND after "Nr. X VAN DE..."
    # The Nr. header line ends at the next \n, so match the full line.
    result.gsub!(/(?<!\n)\n(Nr\.\s*\d+\s+VAN\s[^\n]*)\n(?!\n)/) do
      "\n\n#{::Regexp.last_match(1)}\n\n"
    end

    # Article headings: ensure blank line before AND after short "Art. 3" / "Art.5" lines
    # Only add blank after if the Art. line is short (< 60 chars) - meaning it's a standalone
    # article indicator, not "Art.5 De bepaling onder 6°..." (which is body text starting with Art.)
    result.gsub!(/\n(Art(?:ikel)?\.?\s*\d+[^\n]{0,50})\n(?!\n)/) do
      art_line = ::Regexp.last_match(1)
      if art_line.strip.length < 60
        "\n\n#{art_line}\n\n"
      else
        "\n\n#{art_line}\n"
      end
    end

    # Author name lines: ensure blank line before first author in a block
    # Pattern: "Firstname LASTNAME (PARTY)" optionally with leading quote
    result.gsub!(/(?<!\n)\n(['\u2018]?[A-ZÉÈÊÀÂ][a-zéèêëàâäùûüôöîïç]+\s+[A-ZÉÈÊÀÂÙÛÔÎÇ]{2,}(?:\s+[A-ZÉÈÊÀÂÙÛÔÎÇ]+)*\s*\([A-Za-z\s\-.]+\)\s*)\n/) do
      "\n\n#{::Regexp.last_match(1)}\n"
    end

    # Split dense paragraphs at inline section headers by injecting blank lines
    # before patterns like "II. - INLEIDENDE UITEENZETTINGEN" or "A. Vragen"
    # Case 1: Preceded by sentence-ending punctuation
    result.gsub!(/([.;:!?,])\s+((?:[IVXLC]+[.,)] ?\s*[-–]?\s+[A-ZÉÈÊÀÂÙÛÔÎÇ]{2,}))/) do
      "#{::Regexp.last_match(1)}\n\n#{::Regexp.last_match(2)}"
    end
    # Case 2: Preceded by lowercase word or digit (no punctuation) - word boundary before Roman numeral
    # Catches: "DOC 55 0477/001 II. – INLEIDENDE UITEENZETTING" and "...indienster is II. – ALGEMENE"
    # Also matches OCR-corrupted variants: Il. (lowercase L instead of I) common in PDF extraction
    # The [.,)] after the numeral is optional when followed by a dash (some OCR produces "II – ALGEMENE")
    # Uses alternation: either [.,)] with optional dash, or no punctuation with required dash
    result.gsub!(/([a-zéèêëàâäùûüôöîïç\d])\s+((?:I{1,3}|IV|VI{0,3}|IX|X{1,3}|Il{1,2}|lI{0,2}|lV)(?:[.,)]\s*[-–]?\s+|\s*[-–]\s+)[A-ZÉÈÊÀÂÙÛÔÎÇ])/) do
      "#{::Regexp.last_match(1)}\n\n#{::Regexp.last_match(2)}"
    end
    # Case 4: Numbered section headers: "1 – PROCEDURE" or "1. PROCEDURE"
    result.gsub!(/([.;:!?,a-zéèêëàâä])\s+(\d{1,2}\s*[-–.]\s+[A-ZÉÈÊÀÂ]{2,})/) do
      "#{::Regexp.last_match(1)}\n\n#{::Regexp.last_match(2)}"
    end
    # Case 3: Letter-labeled inline sections after punctuation: "...opgenomen. A. Vragen"
    result.gsub!(/([.;:!?])\s+([A-Z][.)]\s+[A-ZÉÈÊÀ][a-zéèêëàâä])/) do
      "#{::Regexp.last_match(1)}\n\n#{::Regexp.last_match(2)}"
    end
    # Case 5: Inline article headings: "...aangenomen. Art. 4 Dit artikel..."
    # Also handles "Art.5", "Artikel 4", standalone or after any text
    result.gsub!(/([.);:!?"\u201D])\s+(Art(?:ikel)?\.?\s*\d+)/) do
      "#{::Regexp.last_match(1)}\n\n#{::Regexp.last_match(2)}"
    end
    # Case 6: Amendment numbers inline: "...(N-VA) Nr. 2 VAN DE DAMES..."
    # Can appear after closing paren (party label), period, or quote
    result.gsub!(/([.);:!?"\u201D])\s+(Nr\.\s*\d+\s+VAN\s)/) do
      "#{::Regexp.last_match(1)}\n\n#{::Regexp.last_match(2)}"
    end
    # Case 7: Numbered list markers from Belgian legislation: "...voorwaarden. 1° een duidelijke..."
    # Also handles "...garantievoorwaarden." 1° or after colon
    result.gsub!(/([.);:!?"\u201D])\s+(\d{1,2}°\s)/) do
      "#{::Regexp.last_match(1)}\n\n#{::Regexp.last_match(2)}"
    end
    # Case 8: Section labels that start new blocks: "VERANTWOORDING", "TOELICHTING"
    result.gsub!(/([.);:!?"\u201D])\s+(VERANTWOORDING|TOELICHTING|COMMENTAIRE|JUSTIFICATION|DÉVELOPPEMENTS)\b/) do
      "#{::Regexp.last_match(1)}\n\n#{::Regexp.last_match(2)}"
    end
    # Case 9: Author name blocks inline: "...definitie. 'Anneleen VAN BOSSUYT (N-VA)"
    # Pattern: optional leading quote + Firstname + UPPERCASE LASTNAME + (PARTY)
    result.gsub!(/([.);:!?"\u201D])\s+(['\u2018\u201C]?[A-ZÉÈÊÀÂ][a-zéèêëàâäùûüôöîïç]+\s+[A-ZÉÈÊÀÂÙÛÔÎÇ]{2,}(?:\s+[A-ZÉÈÊÀÂÙÛÔÎÇ]+)*\s*\([A-Za-z\-.]+\))/) do
      "#{::Regexp.last_match(1)}\n\n#{::Regexp.last_match(2)}"
    end
    # Split at all-caps inline headings: "...judiciaire. DÉVELOPPEMENTS MESDAMES..."
    # Skip HOOFDSTUK/CHAPITRE - these are handled by the final-step regex below.
    result.gsub!(/([.;:!?])\s+([A-ZÉÈÊÀÂÙÛÔÎÇ]{4,}(?:\s+[A-ZÉÈÊÀÂÙÛÔÎÇ]{2,})*)\s/) do
      word_block = ::Regexp.last_match(2)
      full_match = ::Regexp.last_match(0) # Preserve original text (including any \n\n paragraph breaks)
      next full_match if word_block.match?(/\A(?:HOOFDSTUK|CHAPITRE)/)

      # Only split if the block is a short heading (< 60 chars, > 75% uppercase)
      alpha = word_block.gsub(/[^a-zA-ZÀ-ÖØ-öø-ÿ]/, '')
      upper_r = alpha.empty? ? 0 : alpha.gsub(/[^A-ZÀ-ÖØ-Ý]/, '').length.to_f / alpha.length
      if upper_r > 0.75 && word_block.length < 60
        "#{::Regexp.last_match(1)}\n\n#{word_block}\n\n"
      else
        "#{::Regexp.last_match(1)} #{word_block} "
      end
    end

    # Step 4: Rejoin headings that were split across lines by PDF extraction.
    # This must happen AFTER all splitting to repair broken headings.
    lines_arr = result.split("\n")
    rejoined = []
    i = 0
    while i < lines_arr.length
      line = lines_arr[i]

      # Find the next non-empty line (may be adjacent or separated by blank lines)
      next_non_empty_idx = nil
      blank_count = 0
      j = i + 1
      while j < lines_arr.length
        if lines_arr[j].strip.empty?
          blank_count += 1
          j += 1
        else
          next_non_empty_idx = j
          break
        end
      end

      if !line.strip.empty? && next_non_empty_idx
        stripped_line = line.strip
        stripped_next = lines_arr[next_non_empty_idx].strip

        # Case A: Dangling conjunction at end of all-caps heading.
        # "ARTIKELSGEWIJZE BESPREKING EN" + [blank?] + "STEMMINGEN ..." → join
        if blank_count <= 1 &&
           stripped_line.match?(/\A[A-ZÉÈÊÀÂÙÛÔÎÇ].*\s+(?:EN|ET|DE|DES|OF|OU|DER|VAN|DU)\z/) &&
           stripped_next.match?(/\A[A-ZÉÈÊÀÂÙÛÔÎÇ]{3,}/)
          rejoined << "#{stripped_line} #{stripped_next}"
          i = next_non_empty_idx + 1
          # Also skip a blank line that may follow
          i += 1 if lines_arr[i] && lines_arr[i].strip.empty?
          next
        end

        # NOTE: HOOFDSTUK/CHAPITRE is handled by the final-step regex at the
        # end of this method, not by the rejoin loop.
      end

      rejoined << line
      i += 1
    end
    result = rejoined.join("\n")

    # Consolidate excessive blank lines (max 2 in a row)
    result.gsub!(/\n{4,}/, "\n\n\n")

    # Final step: Ensure HOOFDSTUK/CHAPITRE headings are their own paragraphs.
    # This runs LAST so nothing else can consume the paragraph breaks.
    # Match any char before whitespace+HOOFDSTUK and inject double newlines.
    result.gsub!(/(?<=.)[ \t]*((?:HOOFDSTUK|CHAPITRE)\s+\d+)\s+/i) do
      "\n\n#{::Regexp.last_match(1)}\n\n"
    end

    # Re-consolidate after HOOFDSTUK splitting
    result.gsub!(/\n{4,}/, "\n\n\n")
    result.strip
  end

  # Filter bilingual content, keeping only paragraphs in the target language.
  # Uses stopword frequency to classify each paragraph block.
  #
  # @param text [String] Raw text potentially containing both NL and FR
  # @param target_lang [String] 'nl' or 'fr'
  # @return [String] Filtered text with only target-language paragraphs
  def filter_bilingual_content(text, target_lang = 'nl')
    return text if text.blank?

    target_lang = target_lang.to_s.downcase
    target_indicators = target_lang == 'fr' ? FRENCH_INDICATORS : DUTCH_INDICATORS
    opposing_indicators = target_lang == 'fr' ? DUTCH_INDICATORS : FRENCH_INDICATORS

    # Split into paragraph blocks (separated by 1+ blank lines)
    paragraphs = text.split(/\n\s*\n/)
    kept = []

    paragraphs.each do |para|
      stripped = para.strip
      next if stripped.empty?

      # Always strip bilingual header lines (both languages in one line)
      lines = stripped.lines.map(&:strip).reject(&:empty?)
      filtered_lines = lines.reject { |line| bilingual_header?(line) }
      next if filtered_lines.empty?

      filtered_para = filtered_lines.join("\n")

      # Short paragraphs (< 20 chars): keep by default (numbers, titles, etc.)
      if filtered_para.length < 20
        kept << filtered_para
        next
      end

      # Score the paragraph
      words = filtered_para.downcase.scan(/[a-zéèêëàâäùûüôöîïçæœ]+/)
      target_score = words.count { |w| target_indicators.include?(w) }
      opposing_score = words.count { |w| opposing_indicators.include?(w) }

      # Keep paragraph if:
      # - Target score >= opposing score (ties kept = safe default)
      # - Or paragraph is too short for reliable detection (< 5 indicator hits total)
      total_hits = target_score + opposing_score
      kept << filtered_para if total_hits < 3 || target_score >= opposing_score
      # else: paragraph is predominantly in the wrong language → dropped
    end

    kept.join("\n\n")
  end

  # Convert cleaned parliamentary text to structured HTML.
  # Detects section headers, numbered points, and wraps paragraphs in <p> tags.
  # Reuses section-detection logic from clean_jurisprudence_full_text.
  #
  # @param text [String] Cleaned plain text (output of clean_parliamentary_content)
  # @return [String] HTML-safe structured content
  def format_parliamentary_html(text)
    return '' if text.blank?

    paragraphs = text.split(/\n\s*\n/)
    html_parts = []
    in_bullet_list = false

    paragraphs.each do |para|
      stripped = para.strip
      next if stripped.empty?

      lines = stripped.lines.map(&:strip).reject(&:empty?)

      # Skip ToC-style lines (e.g. "2.Développements.....................4")
      lines.reject! { |l| l.match?(/\.{5,}/) }
      # Skip abbreviation definition blocks (e.g. "QRVA :", "CRIV :", "CRABV :")
      next if lines.length > 2 && lines.count { |l| l.match?(/\A[A-Z]{2,8}\s*:/) } > lines.length / 2
      # Skip address/contact blocks (phone, fax, email, www)
      if lines.any? { |l| l.match?(/\A(?:Tél|Fax|Tel)\s*[.:]/i) } &&
         lines.any? { |l| l.match?(/\A(?:www\.|e-mail|Commandes)/i) }
        next
      end

      next if lines.empty?

      # Check if this paragraph is a heading
      first_line = lines.first

      # --- Heading extraction for multi-line paragraphs or single long lines ---
      # If the first line looks like a heading but the paragraph has more content,
      # extract the heading and process remaining text as separate body text.
      # Also handles single very long lines where heading+body were joined by space.
      if lines.length > 2 || (lines.length >= 1 && first_line.length > 150 && first_line.match?(/\A(?:[IVXLC]+[.,)]|[A-ZÉÈÊÀÂÙÛÔÎÇ]{3,}|\d{1,2}\s*[-–.]|[A-Z][.)])\s/))
        heading_match = false
        heading_text = nil

        # Roman numeral at start: "II, - INLEIDENDE UITEENZETTINGEN"
        if first_line.match?(/\A[IVXLC]+[.,)]\s*[-–]?\s*[A-ZÉÈÊÀÂÙÛÔÎÇ]/)
          alpha = first_line.gsub(/[^a-zA-ZÀ-ÖØ-öø-ÿ]/, '')
          upper_r = alpha.empty? ? 0 : alpha.gsub(/[^A-ZÀ-ÖØ-Ý]/, '').length.to_f / alpha.length
          if first_line.length < 80 && (upper_r > 0.6 || first_line.length < 50)
            # Short heading on its own line - use directly
            heading_text = first_line.strip
            remaining_lines = lines[1..]
            heading_match = true
          elsif first_line.match(/\A([IVXLC]+[.,)]\s*[-–]?\s+[A-ZÉÈÊÀÂÙÛÔÎÇ\s\-']+?)(\s+(?:De|Het|Le|La|Les|Een|The|Dit|Bij|Op|In|Van|Voor|Kan|Wat|Zij|Er|Om|Aan|Uit|Met|Dat|Zal|Zij|Ter|Als|Hoe|Wij|Nog|Mag|Wel|Ook)\s)/)
            # Long line with heading+body - extract via transition word
            heading_text = ::Regexp.last_match(1).strip
            rest = ::Regexp.last_match(2).lstrip + first_line[(::Regexp.last_match(1).length + ::Regexp.last_match(2).length)..]
            remaining_lines = [rest] + lines[1..]
            heading_match = true
          end
        end

        # Numbered section: "1 – PROCEDURE 'Aanvankelijk..."
        if !heading_match && first_line.match?(/\A\d{1,2}\s*[-–.]\s+[A-ZÉÈÊÀÂ]/)
          if first_line.match(/\A(\d{1,2}\s*[-–.]\s+[A-ZÉÈÊÀÂÙÛÔÎÇ\s\-']+?)(\s+['\u2018\u201C(A-Z][a-zéèêëàâä])/)
            heading_text = ::Regexp.last_match(1).strip
            rest = first_line[(::Regexp.last_match(1).length)..]
            remaining_lines = [rest.lstrip] + lines[1..]
            heading_match = true
          elsif first_line.match(/\A(\d{1,2}\s*[-–.]\s+[A-ZÉÈÊÀÂÙÛÔÎÇ]{2,}(?:\s+[A-ZÉÈÊÀÂÙÛÔÎÇ]{2,})*)/)
            candidate = ::Regexp.last_match(1).strip
            if candidate.length < 60
              heading_text = candidate
              rest = first_line[(candidate.length)..]
              remaining_lines = [rest.lstrip] + lines[1..]
              heading_match = true
            end
          end
        end

        # Letter-labeled: "A. Vragen en opmerkingen van de leden Mevrouw..."
        if !heading_match && first_line.match?(/\A[A-Z][.)]\s+[A-ZÉÈÊÀ]/) && first_line.match(/\A([A-Z][.)]\s+[A-Za-zéèêëàâäùûüôöîïç\s]+?)(\s+(?:De|Het|Le|La|Les|Mevrouw|Mijnheer|Mevr\.|Mr\.|De heer)\s)/)
          heading_text = ::Regexp.last_match(1).strip
          rest = ::Regexp.last_match(2).lstrip + first_line[(::Regexp.last_match(1).length + ::Regexp.last_match(2).length)..]
          remaining_lines = [rest] + lines[1..]
          heading_match = true
        end

        # All-caps heading at start: "TOELICHTING DAMES EN HEREN" or "RÉSUMÉ"
        if !heading_match && first_line.match?(/\A[A-ZÉÈÊÀÂÙÛÔÎÇ]{3,}/)
          alpha = first_line.gsub(/[^a-zA-ZÀ-ÖØ-öø-ÿ]/, '')
          upper_r = alpha.empty? ? 0 : alpha.gsub(/[^A-ZÀ-ÖØ-Ý]/, '').length.to_f / alpha.length
          if first_line.length < 80 && upper_r > 0.75 && first_line.match?(/[A-Z]{3,}/)
            # Short all-caps heading on its own line
            heading_text = first_line.strip.sub(/[,;:]\z/, '') # trim trailing punctuation
            remaining_lines = lines[1..]
            heading_match = true
          elsif (caps_md = first_line.match(/\A([A-ZÉÈÊÀÂÙÛÔÎÇ][A-ZÉÈÊÀÂÙÛÔÎÇ\s,;:\-'.]{3,}?[,.]?)\s+([A-Z][a-zéèêëàâäùûüôöîïç])/))
            # Long line: split at uppercase-to-mixed-case transition
            candidate = caps_md[1].strip
            caps_body = caps_md[2]
            c_alpha = candidate.gsub(/[^a-zA-ZÀ-ÖØ-öø-ÿ]/, '')
            c_upper_r = c_alpha.empty? ? 0 : c_alpha.gsub(/[^A-ZÀ-ÖØ-Ý]/, '').length.to_f / c_alpha.length
            if c_upper_r > 0.75 && candidate.length >= 5 && candidate.length < 80
              heading_text = candidate
              rest = first_line[(first_line.index(caps_body))..] || ''
              remaining_lines = [rest] + lines[1..]
              heading_match = true
            end
          end
        end

        # Fallback: Roman numeral or numbered sections where specific word list didn't match
        # Split at uppercase-to-mixed-case transition
        if !heading_match && first_line.match?(/\A(?:[IVXLC]+[.,)]|\d{1,2}\s*[-–.])\s/) && first_line.match(/\A((?:[IVXLC]+[.,)]|\d{1,2}\s*[-–.])\s*[-–]?\s+[A-ZÉÈÊÀÂÙÛÔÎÇ][A-ZÉÈÊÀÂÙÛÔÎÇ\s\-']*[A-ZÉÈÊÀÂÙÛÔÎÇ])\s+([A-Z][a-zéèêëàâäùûüôöîïç])/)
          candidate = ::Regexp.last_match(1).strip
          if candidate.length < 80
            heading_text = candidate
            rest = first_line[(first_line.index(::Regexp.last_match(2)))..]
            remaining_lines = [rest] + lines[1..]
            heading_match = true
          end
        end

        if heading_match && heading_text && heading_text.length > 3
          if in_bullet_list
            html_parts << '</ul>'
            in_bullet_list = false
          end
          escaped = ERB::Util.html_escape(heading_text)
          html_parts << "<h3 class=\"text-base font-bold text-gray-900 dark:text-white mt-6 mb-2\">#{escaped}</h3>"
          # Re-process remaining lines as a new paragraph
          remaining_text = remaining_lines.reject(&:empty?).join(' ')
          unless remaining_text.strip.empty?
            escaped_body = ERB::Util.html_escape(remaining_text.strip)
            escaped_body = escaped_body.gsub(/«([^»]+)»/, '<em>«\1»</em>')
            html_parts << "<p class=\"mb-3\">#{escaped_body}</p>"
          end
          next
        end
      end

      # Roman numeral + section title: "I. RECHTSPLEGING" / "II. - INLEIDENDE UITEENZETTINGEN"
      if lines.length <= 2 && first_line.match?(/\A[IVXLC]+[.)]\s*[-–]?\s*[A-ZÉÈÊÀÂÙÛÔÎÇ]/)
        alpha = first_line.gsub(/[^a-zA-ZÀ-ÖØ-öø-ÿ]/, '')
        upper_r = alpha.empty? ? 0 : alpha.gsub(/[^A-ZÀ-ÖØ-Ý]/, '').length.to_f / alpha.length
        if upper_r > 0.6 || first_line.length < 60
          if in_bullet_list
            html_parts << '</ul>'
            in_bullet_list = false
          end
          escaped = ERB::Util.html_escape(lines.join(' '))
          html_parts << "<h3 class=\"text-base font-bold text-gray-900 dark:text-white mt-6 mb-2\">#{escaped}</h3>"
          next
        end
      end

      # All-caps section titles (standalone short lines): "DÉVELOPPEMENTS", "RÉSUMÉ"
      if lines.length == 1 && first_line.length >= 5 && first_line.length < 80
        alpha = first_line.gsub(/[^a-zA-ZÀ-ÖØ-öø-ÿ]/, '')
        upper_r = alpha.empty? ? 0 : alpha.gsub(/[^A-ZÀ-ÖØ-Ý]/, '').length.to_f / alpha.length
        if upper_r > 0.75 && first_line.match?(/[A-Z]{3,}/)
          if in_bullet_list
            html_parts << '</ul>'
            in_bullet_list = false
          end
          escaped = ERB::Util.html_escape(first_line)
          html_parts << "<h4 class=\"text-sm font-bold text-gray-800 dark:text-gray-200 mt-5 mb-2 uppercase\">#{escaped}</h4>"
          next
        end
      end

      # Letter-labeled sections: "A. Vragen en opmerkingen van de leden"
      if lines.length <= 2 && first_line.match?(/\A[A-Z][.)]\s+[A-ZÉÈÊÀ]/) && first_line.length < 100
        if in_bullet_list
          html_parts << '</ul>'
          in_bullet_list = false
        end
        escaped = ERB::Util.html_escape(lines.join(' '))
        html_parts << "<h4 class=\"text-sm font-semibold text-gray-800 dark:text-gray-200 mt-4 mb-2\">#{escaped}</h4>"
        next
      end

      # Article headings: "Art. 1." / "Artikel 1." / "ARTICLE UNIQUE" / "ARTIKEL 1"
      if lines.length <= 2 && first_line.match?(/\A(?:Art(?:ikel|icle)?\.?\s*\d+|ARTICLE\s+\w+|ARTIKEL\s+\d+)/i)
        if in_bullet_list
          html_parts << '</ul>'
          in_bullet_list = false
        end
        escaped = ERB::Util.html_escape(lines.join(' '))
        html_parts << "<p class=\"mt-4 mb-1\"><strong>#{escaped}</strong></p>"
        next
      end

      # Check if this paragraph is a dash/bullet list block
      bullet_lines = lines.grep(/\A[-–•►]\s/)
      if bullet_lines.length.positive? && bullet_lines.length >= lines.length / 2
        # Mixed: some lines are bullets, some are preamble
        preamble = []
        lines.each do |line|
          break if line.match?(/\A[-–•►]\s/)

          preamble << line
        end

        if preamble.any?
          if in_bullet_list
            html_parts << '</ul>'
            in_bullet_list = false
          end
          escaped = ERB::Util.html_escape(preamble.join(' '))
          html_parts << "<p class=\"mb-2\">#{escaped}</p>"
        end

        unless in_bullet_list
          html_parts << '<ul class="list-disc pl-6 mb-3 space-y-1">'
          in_bullet_list = true
        end

        lines.each do |line|
          next unless line.match?(/\A[-–•►]\s/)

          bullet_text = ERB::Util.html_escape(line.sub(/\A[-–•►]\s*/, ''))
          html_parts << "<li>#{bullet_text}</li>"
        end
        next
      end

      # Close any open bullet list
      if in_bullet_list
        html_parts << '</ul>'
        in_bullet_list = false
      end

      # Regular paragraph: JOIN lines with spaces (not <br>) for proper text flow
      current_para = []
      lines.each do |line|
        escaped = ERB::Util.html_escape(line)

        # Numbered points starting with capital: "1. Krachtens..."
        if line.match?(/\A\d{1,3}\.\s+[A-ZÉÈÊÀÂÙÛÔÎÇ]/) && current_para.empty?
          dot_pos = escaped.index('.')
          num_part = escaped[0..dot_pos]
          rest_part = escaped[(dot_pos + 2)..]
          current_para << "<strong>#{num_part}</strong> #{rest_part}"
        else
          current_para << escaped
        end
      end

      joined = current_para.join(' ')
      # Italicize quoted text
      joined = joined.gsub(/«([^»]+)»/, '<em>«\1»</em>')
      joined = joined.gsub(/&quot;([^&]+)&quot;/, '<em>&quot;\1&quot;</em>')

      # Split very long paragraphs at sentence boundaries for readability.
      # PDF extractions often produce single massive blocks without paragraph breaks.
      if joined.length > 600
        # Split at ". " followed by uppercase letter (sentence boundary)
        sentences = joined.split(/(?<=\.)\s+(?=[A-ZÉÈÊÀÂÙÛÔÎÇÖ"«\d])/)
        current_chunk = []
        current_len = 0
        sentences.each do |sentence|
          current_chunk << sentence
          current_len += sentence.length
          next unless current_len > 400

          html_parts << "<p class=\"mb-3\">#{current_chunk.join(' ')}</p>"
          current_chunk = []
          current_len = 0
        end
        html_parts << "<p class=\"mb-3\">#{current_chunk.join(' ')}</p>" unless current_chunk.empty?
      else
        html_parts << "<p class=\"mb-3\">#{joined}</p>"
      end
    end

    # Close any trailing open bullet list
    html_parts << '</ul>' if in_bullet_list

    html_parts.join("\n").html_safe
  end

  # Strip the wetgevingstechnische nota (legal-technical note) appendix.
  # These are bilingual annexes at the end of committee reports where both
  # NL and FR text is interleaved at the LINE level (not paragraph level),
  # making them impossible to clean with paragraph-level filtering.
  # The content is also low-value for end users (internal legislative drafting notes).
  #
  # @param text [String] Raw document content
  # @return [String] Content with the appendix stripped
  def strip_wetgevingstechnische_nota(text)
    return text if text.blank?

    # Common markers for the start of the legal-technical note appendix.
    # These appear in both NL and FR documents.
    nota_markers = [
      # NL markers
      /^\s*(?:dienst|afdeling)\s+Juridische\s+Zaken/im,
      /^\s*OPMERKINGEN\s*$/im,
      /^\s*BIJLAGE\s+BIJ\s+DE\s+ARTIKELEN/im,
      /^\s*(?:OPMERKING(?:EN)?\s+)?BIJ\s+DE\s+ARTIKELEN/im,
      /^\s*wetgevingstechnische\s+nota/im,
      # FR markers
      /^\s*(?:service|division)\s+Affaires\s+juridiques/im,
      /^\s*OBSERVATIONS?\s*$/im,
      /^\s*ANNEXE\s+AUX\s+ARTICLES/im,
      /^\s*note\s+législistique/im,
      /^\s*NOTE\s+TECHNIQUE\s+LEGISLATIVE/im,
      # Bilingual combined markers (garbled from column merging)
      /Juridische\s+Zaken.*Affaires\s+juridiques/i,
      /Affaires\s+juridiques.*Juridische\s+Zaken/i,
      /division\s+Af(?:f|fi)(?:ir|aires)\s+juridiques/i
    ]

    nota_markers.each do |marker|
      next unless (match = text.match(marker))

      # Only truncate if the match is in the latter half of the document
      # (the nota is always at the end, never at the beginning)
      pos = match.begin(0)
      return text[0...pos].rstrip if pos > text.length * 0.4
    end

    text
  end

  private

  # Check if a line is a bilingual header (contains both NL and FR text)
  def bilingual_header?(line)
    BILINGUAL_HEADER_PATTERNS.any? { |pat| line.match?(pat) }
  end

  # Check if a line is a common PDF header that should be skipped
  def skip_header_line?(line)
    downcased = line.downcase

    # Parliament names (bilingual)
    return true if downcased.include?('chambre des représentants') || downcased.include?('chambre des representants')
    return true if downcased.include?('belgische kamer van volksvertegenwoordigers')

    # Document reference headers - very specific patterns
    return true if line.match?(/^DOC\s+\d+$/i)

    # Letter-spaced headers (any 5+ single letters separated by spaces)
    return true if line.match?(/^([A-Z]\s+){4,}[A-Z]?/i)

    # Session/Legislature references with letter spacing
    return true if line.match?(/\d+\s*e?\s*S\s*E\s*S\s*S\s*I\s*O\s*N/i)
    return true if line.match?(/\d+\s*e?\s*Z\s*I\s*T\s*T\s*I\s*N\s*G/i)
    return true if line.match?(/L\s*[ÉE]\s*G\s*I\s*S\s*L\s*A\s*T\s*U\s*R/i)

    false
  end

  # Skip running document headers that repeat on every page
  # e.g. "DOC 52 0046/001" with page content
  def skip_running_doc_header?(line)
    # "DOC 52 0046/001" or "DOC 55 1234/005" with optional trailing content
    return true if line.match?(%r{\ADOC\s+\d{2,3}\s+\d{3,5}/\d{1,3}\s*\z}i)

    # "KAMER · 5e ZITTING VAN DE 55e ZITTINGSPERIODE" type running headers
    return true if line.match?(/\AKAMER\s*·/i)
    return true if line.match?(/\ACHAMBRE\s*·/i)

    # Recycled paper notice
    return true if line.match?(/gerecycleerd\s+papier/i)
    return true if line.match?(/papier\s+recycl[ée]/i)

    # "Imprimé par le Service" / "Gedrukt door de Dienst" (printing notice)
    return true if line.match?(/\A(?:Imprim|Gedrukt)\s+(?:par|door)/i)

    false
  end

  # Skip metadata noise lines
  def skip_metadata_line?(line)
    # Standalone page numbers
    return true if line.match?(/^\d{1,3}$/)
    # Standalone document numbers
    return true if line.match?(%r{^\d+/\d+$})
    # Standalone years
    return true if line.match?(/^(19|20)\d{2}$/)
    # OCR garbage
    return true if line.match?(/^Cn:\s*°\s*Tek\s+aangenomen/i)
    return true if line.match?(/^oor:\s+Wetsontwe?r?\.?\s*$/i)
    # Doc ss metadata prefix lines (standalone)
    return true if line.match?(%r{\A(?:Doc\s*s{0,2}|poc\s*s?\d?)\s+\d{1,5}/\d{1,5}\s*\z}i)
    # "Zie." / "Voir." standalone references
    return true if line.match?(/\A(?:Zie|Voir)\.\s*\z/i)
    # "021100:" type reference codes
    return true if line.match?(/\A\d{6}:\s/)

    false
  end
end
