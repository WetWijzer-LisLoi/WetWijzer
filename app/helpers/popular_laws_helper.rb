# frozen_string_literal: true

# == Popular Laws Helper
#
# Batch lookup and path generation for frequently-referenced Belgian laws.
# Extracted from ApplicationHelper to isolate the 120+ title strings and
# caching logic from the core rendering pipeline.
module PopularLawsHelper
  # Batch lookup of popular laws - fetches all in a single query and caches
  # @param titles [Array<String>] Array of law titles to look up
  # @param language_id [Integer] The language ID (1 for NL, 2 for FR)
  # @return [Hash] Hash mapping search title (lowercase) => numac
  def batch_popular_law_lookup(titles, language_id = nil)
    language_id ||= current_language_id
    cache_key = "popular_laws/batch/#{language_id}/#{titles.map(&:downcase).sort.join('|')}"

    Rails.cache.fetch(cache_key, expires_in: 1.hour) do
      result = {}

      titles.each do |search_title|
        law = Legislation
              .where(language_id: language_id)
              .where('LOWER(title) LIKE ?', "%#{search_title.downcase}%")
              .where.not(tags: [nil, ''])
              .order(:numac)
              .select(:numac)
              .first

        result[search_title.downcase] = law&.numac if law
      end

      result
    end
  end

  # Memoized access to the batch lookup for current request
  # This ensures we only do the batch query once per page render
  def popular_laws_lookup
    @popular_laws_lookup ||= begin
      titles = popular_law_titles_for_locale
      batch_popular_law_lookup(titles)
    end
  end

  # Generates a path to a popular law, preferring direct links to the original law
  # Falls back to search results if the law isn't found
  # @param title [String] The law title to search for
  # @param language_id [Integer] The language ID (1 for NL, 2 for FR)
  # @return [String] Path to the law page or search results
  def popular_law_path(title, language_id = nil)
    language_id ||= current_language_id

    numac = popular_laws_lookup[title.downcase]

    if numac
      law_path(numac, language_id: language_id)
    else
      laws_path(title: title)
    end
  end

  private

  def popular_law_titles_for_locale
    if I18n.locale == :nl
      popular_law_titles_nl
    else
      # German falls back to French (Ostbelgien is in Wallonia)
      popular_law_titles_fr
    end
  end

  def popular_law_titles_nl
    [
      # Civil Law
      'Burgerlijk Wetboek',
      '[OUD] BURGERLIJK WETBOEK',
      'BURGERLIJK WETBOEK - BOEK I',
      'BURGERLIJK WETBOEK - BOEK II',
      'BURGERLIJK WETBOEK - BOEK III',
      # Nieuw Burgerlijk Wetboek
      'Burgerlijk Wetboek. Boek 1',
      'Burgerlijk Wetboek. Boek 2',
      'Burgerlijk Wetboek. Boek 3',
      'Burgerlijk Wetboek. Boek 4',
      'Burgerlijk Wetboek. Boek 5',
      'Burgerlijk Wetboek, boek 6',
      'Burgerlijk Wetboek. Boek 8',
      'Burgerlijk Wetboek. Boek 9',
      'Gerechtelijk Wetboek',
      'GERECHTELIJK WETBOEK - Eerste deel',
      'GERECHTELIJK WETBOEK - Deel II',
      'GERECHTELIJK WETBOEK - Deel III',
      'GERECHTELIJK WETBOEK - Deel IV',
      'GERECHTELIJK WETBOEK - Deel V',
      'GERECHTELIJK WETBOEK - Deel VI',
      'GERECHTELIJK WETBOEK - ZEVENDE DEEL',
      'Gerechtelijk Wetboek - Deel V',
      'Gerechtelijk Wetboek - Deel VI',
      'Gerechtelijk Wetboek. - ZEVENDE DEEL',
      # Criminal Law
      'Strafwetboek',
      'WETBOEK VAN STRAFVORDERING',
      'Wet Strafprocesrecht I',
      'Sociaal Strafwetboek',
      # Constitutional
      'Grondwet',
      'KIESWETBOEK',
      # Nationality
      'Wetboek van de Belgische nationaliteit',
      # Corporate & Economic
      'Wetboek van vennootschappen',
      'Vennootschappenwetboek',
      'Wetboek van economisch recht',
      # Intellectual Property
      'verlening van Europese octrooien',
      # Social & Labor
      'Sociaal Wetboek',
      'Arbeidswet',
      'Wet betreffende de arbeidsovereenkomsten',
      'Welzijnswet',
      'Jaarlijkse vakantie',
      'Uitvoeringsbesluit vakantiegeld',
      'Klein verlet',
      'Wet betreffende de collectieve arbeidsovereenkomsten',
      'Loonbeschermingswet',
      'Feestdagen',
      'Uitzendarbeid',
      'Tijdskrediet',
      'Geboorteverlof',
      'Arbeidsongevallen',
      # Social Security
      'Werkloosheidsbesluit',
      'Wet ziekteverzekering',
      'Leefloonwet',
      'Kinderbijslag',
      # Discrimination
      'Genderwet',
      'Antidiscriminatiewet',
      # Tax
      'Wetboek van de inkomstenbelastingen',
      'CODE des impôts sur les revenus',
      'Wetboek van de belasting over de toegevoegde waarde',
      'Wetboek der registratie',
      'Wetboek der successierechten',
      'Vlaamse Codex Fiscaliteit',
      # Housing
      'Vlaamse Codex Wonen',
      'Vlaams Woninghuurdecreet',
      'Brusselse Huisvestingscode',
      'Handelshuurwet',
      # Immigration
      'Vreemdelingenwet',
      # Insurance & Liability
      'verplichte aansprakelijkheidsverzekering inzake motorrijtuigen',
      # Pensions
      'hervorming van de pensioenen',
      # Other
      'Consulair Wetboek',
      'Drugswet',
      'Camerawet'
    ]
  end

  def popular_law_titles_fr
    [
      # Civil Law
      'Code civil',
      '[ANCIEN] CODE CIVIL',
      'CODE CIVIL - LIVRE I',
      'CODE CIVIL - LIVRE II',
      'CODE CIVIL - LIVRE III',
      # Nouveau Code civil
      'CODE CIVIL - LIVRE 1',
      'CODE CIVIL - LIVRE 2',
      'CODE CIVIL - LIVRE 3',
      'CODE CIVIL - LIVRE 4',
      'CODE CIVIL - LIVRE 5',
      'Code civil, livre 6',
      'CODE CIVIL - LIVRE 8',
      'Code civil, Livre 9',
      'Code judiciaire',
      'CODE JUDICIAIRE - Première partie',
      'CODE JUDICIAIRE - Deuxième partie',
      'CODE JUDICIAIRE - Troisième partie',
      'CODE JUDICIAIRE - Quatrième partie',
      'CODE JUDICIAIRE - Cinquième partie',
      'CODE JUDICIAIRE - Sixième partie',
      'CODE JUDICIAIRE - Septième partie',
      'Code judiciaire - Cinquième partie',
      'Code judiciaire - Sixième partie',
      'Code judiciaire - Septième partie',
      # Criminal Law
      'Code pénal',
      "CODE D'INSTRUCTION CRIMINELLE",
      'Loi Procédure pénale I',
      'Code pénal social',
      # Constitutional
      'Constitution',
      'Code électoral',
      # Nationality
      'Code de la nationalité belge',
      # Corporate & Economic
      'Code des sociétés',
      'Code de droit économique',
      # Intellectual Property
      'convention sur la délivrance de brevets européens',
      # Social & Labor
      'Code social',
      'Code du travail',
      'Loi relative aux contrats de travail',
      'Loi sur le bien-être',
      'Vacances annuelles',
      'Arrêté royal pécule de vacances',
      'Petit chômage',
      'conventions collectives de travail',
      'protection de la rémunération',
      'jours fériés',
      'travail intérimaire',
      'crédit-temps',
      'congé de naissance',
      'accidents du travail',
      # Social Security
      'assurance chômage',
      'assurance maladie-invalidité',
      'droit à l\'intégration sociale',
      'allocations familiales',
      # Discrimination
      'Loi genre',
      'Loi anti-discrimination',
      # Tax
      'Code des impôts sur les revenus',
      'CODE des impôts sur les revenus',
      'Code de la taxe sur la valeur ajoutée',
      "Code de l'enregistrement",
      'Code des droits de succession',
      # Housing
      'Code flamand du Logement',
      'bail d\'habitation',
      'Code bruxellois du Logement',
      'bail commercial',
      # Immigration
      'Loi sur les étrangers',
      # Insurance & Liability
      'assurance obligatoire de la responsabilité en matière de véhicules automoteurs',
      # Pensions
      'réforme des pensions',
      # Other
      'Code consulaire',
      'Loi sur les stupéfiants',
      'Loi caméras'
    ]
  end

  # Converts concordance article references into clickable links to WetWijzer law pages.
  # Handles formats:
  #   "Art. 193"          → link to /laws/NUMAC#art-193
  #   "Art. 247 (N3)"     → link, strips the (N3) from the anchor
  #   "Art. 1:5, §1"      → link to /laws/NUMAC#art-1-5
  #   "2.3.1"             → link to /laws/NUMAC#art-2-3-1  (BW bare numbers)
  #   "/"                 → no link (means "abolished/geen equivalent")
  #   "-"                 → no link (means "new article, no old equivalent")
  #   "Afgeschaft - ..."  → no link
  # @param text [String] the concordance cell text (e.g. "Art. 193", "2.3.1", "Art. 247 (N3)")
  # @param numac [String, nil] the NUMAC of the target law; nil disables linking
  # @return [ActiveSupport::SafeBuffer] HTML with article numbers wrapped in <a> tags
  def linkify_concordance_article(text, numac)
    return ERB::Util.html_escape(text.to_s) if numac.blank? || text.blank? || text.strip == '/' || text.strip == '-' || text.strip == ' '
    return ERB::Util.html_escape(text.to_s) if text.to_s.match?(/\A(Volledige wet|-)/i)

    # Split by ";" to handle multi-article refs, process each segment
    segments = text.to_s.split(/(?=;)/)
    result = segments.map do |segment|
      linkify_segment(segment) { |_num| numac }
    end.join

    result.html_safe
  end

  # Routes an old BW article number to the correct NUMAC.
  # The old Burgerlijk Wetboek is split across 6 NUMACs by article range:
  #   Boek I:  art. 1–515       → 1804032150
  #   Boek II: art. 516–710bis  → 1804032151
  #   Boek III T.I-II: art. 711–1100  → 1804032152
  #   Boek III T.III-V: art. 1101–1581 → 1804032153
  #   Boek III T.VI-XIII: art. 1582–2010 → 1804032154
  #   Boek III T.XIV-XX: art. 2011–2281 → 1804032155
  OLD_BW_RANGES = [
    {
      (1..515) => '1804032150',
      (516..710) => '1804032151',
      (711..1100) => '1804032152',
      (1101..1581) => '1804032153',
      (1582..2010) => '1804032154',
      (2011..2281) => '1804032155'
    }
  ].flat_map(&:to_a).freeze

  def old_bw_numac_for_article(article_text)
    # Extract the leading number from the article text (e.g. "1387" from "1387", "353-15" → 353)
    num = article_text.to_s[/\d+/]&.to_i
    return nil unless num

    OLD_BW_RANGES.each do |range, numac|
      return numac if range.include?(num)
    end
    nil
  end

  # Like linkify_concordance_article, but resolves each article's NUMAC
  # individually from the old BW range map.
  def linkify_concordance_article_bw_old(text)
    return ERB::Util.html_escape(text.to_s) if text.blank? || text.strip == '/' || text.strip == '-' || text.strip == ' '
    return ERB::Util.html_escape(text.to_s) if text.to_s.match?(/\A(Volledige wet|-)/i)

    segments = text.to_s.split(/(?=;)/)
    result = segments.map do |segment|
      linkify_segment(segment) { |num| old_bw_numac_for_article(num) }
    end.join

    result.html_safe
  end

  # Shared: link article numbers in a single segment (no ";" inside).
  # Splits at first §/lid/al./alinea - only links the article part before it.
  # The block receives the matched number and must return a NUMAC (or nil to skip).
  def linkify_segment(segment)
    # Split at first § / lid / al. / alinea
    article_part, suffix = segment.split(/(?=\s*(?:§|\blid\b|\bal\.|\balinea\b))/i, 2)
    return ERB::Util.html_escape(segment) if article_part.blank?

    escaped = ERB::Util.html_escape(article_part)
    escaped_suffix = suffix ? ERB::Util.html_escape(suffix) : ''

    linked = escaped.gsub(%r{
      (?:Art\.?\s*)?(                           # optional "Art. " prefix
        (?<!N)                                  # NOT preceded by N (strafniveau like N3, N4)
        \d+[a-z]*                               # base number, optional bis/ter/quater
        (?:[.:/]\d+[a-z]*)*                     # dotted/colon/slash sub-numbers
        (?:-\d{1,2}[a-z]*(?!\.))?              # hyphen sub-number (1-2 digits only, not ranges)
        (?:\s*/\d+[a-z]*)*                      # optional slash sub-numbers
      )
    }ix) do |match|
      num = Regexp.last_match(1)
      numac = yield(num)
      if numac
        anchor = "art-#{num.strip.downcase.gsub(%r{[./:]+}, '-').gsub(/[^a-z0-9-]/, '').gsub(/-+/, '-').gsub(/\A-|-\z/, '')}"
        href = "/laws/#{numac}##{anchor}"
        %(<a href="#{href}" target="_blank" rel="noopener noreferrer" style="text-decoration:none" class="hover:text-(--accent-600) dark:hover:text-(--accent-400) transition-colors">#{match}</a>)
      else
        match
      end
    end

    linked + escaped_suffix
  end
end
