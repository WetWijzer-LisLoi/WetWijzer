# frozen_string_literal: true

require 'uri'

# The judgment page's reference and summary (Sol 2026-11-20 10:07:46Z, 10:10:15Z and 10:18:30Z).
#
# Summary: shown only when the source supplies a substantive summary, in full and with its source. Never a bare title
# ("Arrest nr 72.930 van 2 april 1998": 1,934 of 2,000 sampled Raad van State rows, read-only survey 2026-11-20) nor
# Juportal's placeholder ("Samenvatting(en) nog niet beschikbaar", "Résumé(s) pas encore disponible(s)"). A title
# followed by subject wording ("Advies 11.917/1 van 26 juni 1974 over ontwerp van wet ...") is the source's own title:
# kept and labelled as such, never as a summary.
#
# Reference: on the Dutch interface, Referentie (V&A) in the form of Verwijzingen en Afkortingen RS1 (vena.be/rs1, read
# in full 2026-11-20): court abbreviation, date, the number RS1 cites where the ECLI carries it (RvS 72.930, GwH
# 81/2020), the ECLI and a final period, as "RvS 2 april 1998, 72.930, ECLI:BE:RVSCE:1998:ARR.72.930.". Court names
# and abbreviations are the Dutch ones (vena.be/afkortingen-rechtscolleges, read in full 2026-11-20: "Bij verwijzingen
# naar rechtscolleges in een Nederlandse tekst worden steeds de Nederlandstalige benaming en afkorting gebruikt."). No
# reference for a court the record does not name unambiguously (a first-instance court: civil Rb. or criminal Corr.),
# an advisory opinion, an opinion of the public prosecutor (CONC) or of an authority (AVIS), or a record whose date and
# ECLI disagree.
module JurisprudenceReferenceHelper
  SUMMARY_TITLE = %r{\A(?:arrest|arr[eê]t|beschikking|ordonnance(?:\s+de\s+cassation)?|advies|avis|vonnis|jugement|
                     uitspraak|beslissing|d[ée]cision|urteil|entscheid)\s+(?:(?:nr|n[°o])\.?\s*)?[[:alnum:]][[:alnum:]./-]*\s+
                     (?:van|du|vom)\s+\d{1,2}(?:er)?\s+\p{L}+\s+\d{4}}ix
  SUMMARY_PLACEHOLDER = /\A(?:samenvatting\(en\)\s+nog\s+niet\s+beschikbaar|r[ée]sum[ée]\(s\)\s+pas\s+encore\s+disponible\(s\))\.?\z/i
  CITY = { 'Antwerpen' => 'Antwerpen', 'Bruxelles' => 'Brussel', 'Brussel' => 'Brussel', 'Gand' => 'Gent', 'Gent' => 'Gent',
           'Liège' => 'Luik', 'Mons' => 'Bergen', 'Leuven' => 'Leuven' }.freeze
  CITY_NAMES = Regexp.union(CITY.keys)
  # Not in the V&A list of abbreviations: written in full, in Dutch (RS1: "Raad voor de Journalistiek 14 november 2013").
  VICTIMS = 'Commissie voor financiële hulp aan slachtoffers van opzettelijke gewelddaden en aan de occasionele redders'
  # [pattern on the stored court name, Dutch abbreviation or full Dutch name ('%s' takes the Dutch city)].
  COURTS = [
    [/\A(?:Raad van State|Conseil d'État)\z/, 'RvS'],
    [/\A(?:Hof van Cassatie|Cour de cassation)\z/, 'Cass.'],
    [/\A(?:Grondwettelijk Hof \(Arbitragehof\)|Cour constitutionnelle \(Cour d'arbitrage\))\z/, :constitutional],
    [/\A(?:Hof van beroep van|Cour d'appel de) (#{CITY_NAMES})\z/, 'HvB %s'],
    [/\A(?:Arbeidshof van|Cour du travail de) (#{CITY_NAMES})\z/, 'Arbh. %s'],
    [/\A(?:Arbeidsrechtbank|Tribunal du travail de) (#{CITY_NAMES})\z/, 'Arbrb. %s'],
    [/\ANederlandstalige arbeidsrechtbank Brussel\z/, 'Arbrb. Brussel (Nl.)'],
    [/\ATribunal du travail francophone de Bruxelles\z/, 'Arbrb. Brussel (Fr.)'],
    [/\ATribunal du travail du Hainaut\z/, 'Arbrb. Henegouwen'],
    [/\A(?:Tribunal du travail du Brabant Wallon|Arbeidsrechtbank Waals Brabant)\z/, 'Arbrb. Waals-Brabant'],
    [/\A(?:Ondernemingsrechtbank|Tribunal de l'entreprise de) (#{CITY_NAMES})\z/, :enterprise],
    [/\A(?:Nederlandstalige ondernemingsrechtbank Brussel|Tribunal de l'entreprise néerlandophone de Bruxelles)\z/, :enterprise_nl],
    [/\AFranstalige ondernemingsrechtbank Brussel\z/, :enterprise_fr],
    [/\A(?:Gegevensbeschermingsautoriteit|Autorité de protection des données)\z/, 'GBA'],
    [/\A(?:Commissie voor de bescherming van de persoonlijke levenssfeer|Commission pour la protection de la vie privée)\z/, 'CBPL'],
    [/\ACommissie voor financiële hulp aan slachtoffers van opzettelijke gewelddaden en aan de occasionele redders\z/, VICTIMS],
    [/\ACommission pour l'aide financière aux victimes d'actes intentionnels de violence et aux sauveteurs occasionnels\z/, VICTIMS]
  ].freeze
  ECLI = /\AECLI:BE:([A-Z]+):(\d{4}):(ARR|JUG|DEC|ORD)\.([0-9A-Z.]+)\z/
  DUTCH_MONTHS = %w[januari februari maart april mei juni juli augustus september oktober november december].freeze
  SOURCE_TITLE_LABEL = { nl: 'Titel in de bron:', fr: 'Titre dans la source :', de: 'Titel in der Quelle:',
                         en: 'Title in the source:' }.freeze
  SOURCE_LABEL = { nl: 'Bron:', fr: 'Source :', de: 'Quelle:', en: 'Source:' }.freeze

  # [:empty | :placeholder | :title | :source_title | :summary, the text to show (nil unless shown)].
  def jurisprudence_summary_kind(summary)
    text = clean_jurisprudence_summary(summary, truncate: false).to_s.gsub(/\s+/, ' ').strip
    return [:empty, nil] if text.empty?
    return [:placeholder, nil] if text.match?(SUMMARY_PLACEHOLDER)

    title = text[SUMMARY_TITLE]
    return [:summary, text] unless title

    text.delete_prefix(title).sub(/\A[\s.,:;–-]+/, '').empty? ? [:title, nil] : [:source_title, text]
  end

  # The Dutch reference (Referentie (V&A)), or nil when RS1 gives no form this record can be put in.
  def jurisprudence_dutch_citation(record)
    ecli = record[:case_number].to_s.strip
    match = ECLI.match(ecli)
    day = Date.iso8601(record[:decision_date].to_s) rescue nil # rubocop:disable Style/RescueModifier
    return if match.nil? || day.nil? || match[2].to_i != day.year
    return if match[4].match?(/\A\d{8}\./) && match[4][0, 8] != day.strftime('%Y%m%d')

    court = jurisprudence_dutch_court(record[:court].to_s, day)
    return if court.nil?

    number = jurisprudence_cited_number(court, match)
    return if court == 'RvS' && number.nil?

    date = "#{day.day} #{DUTCH_MONTHS[day.month - 1]} #{day.year}"
    "#{court} #{date}, #{"#{number}, " if number}#{ecli}."
  end

  # The source's host ("juportal.be") for an https record address, else nil.
  def jurisprudence_source_host(url)
    uri = URI.parse(url.to_s)
    return unless uri.is_a?(URI::HTTPS) && uri.host.present?

    uri.host.delete_prefix('www.')
  rescue URI::InvalidURIError
    nil
  end

  # The source named beside a supplied summary or a source title: the record's own address, named only when one of
  # the page's validated external links (jurisprudence/_external_links, built from the helpers, never from the stored
  # url) is on the same host. The link itself stays in that card, once; a stored address on any other host is never
  # echoed.
  def jurisprudence_listed_source_host(url, links)
    host = jurisprudence_source_host(url)
    host if host && Array(links).any? { |link| jurisprudence_source_host(link) == host }
  end

  def jurisprudence_source_title_label = SOURCE_TITLE_LABEL.fetch(I18n.locale.to_sym, SOURCE_TITLE_LABEL[:en])
  def jurisprudence_source_label = SOURCE_LABEL.fetch(I18n.locale.to_sym, SOURCE_LABEL[:en])

  # Plain references (Sol 2026-11-20 11:57:26Z): on the French, German and English interfaces, and on the Dutch one
  # where RS1 gives no form, "<court>, <date>, <number>, <ECLI>", claiming no citation guide. The court is named only
  # where an official text names it so in that language (read 2026-11-20): French, the corpus's own French court labels
  # and French legislation ("cour d'appel d'Anvers" 80 times, "cour d'appel de Gand" 88); German, the official German
  # translations ("Kassationshof" 268, "Staatsrat" 471, "Verfassungsgerichtshof" 80, "Schiedshof" 95, "Appellationshof
  # von Brüssel" 61, "Arbeitsgerichtshof von Lüttich" 1, "Datenschutzbehörde" 251); English, the courts' own English
  # sites (en.const-court.be "Constitutional Court", cass.be/en "Court of Cassation"; the Council of State has no English
  # page). Otherwise the court is left out, as is any number the ECLI does not carry, and the court of an opinion (CONC,
  # AVIS). A date the ECLI contradicts leaves the ECLI alone.
  COURT_FR_VICTIMS = "Commission pour l'aide financière aux victimes d'actes intentionnels de violence et aux sauveteurs occasionnels"
  PLAIN_ECLI = /\AECLI:BE:([A-Z]+):(\d{4}):([A-Z]+)\.([0-9A-Z.]+)\z/
  PLAIN_LABELS = {
    nl: { heading: 'Referentie', aria: 'Kopieer referentie', copied: 'Gekopieerd',
          failed: 'Kopiëren is niet gelukt. De referentie staat hieronder geselecteerd: kopieer ze zelf.' },
    fr: { heading: 'Référence', aria: 'Copier la référence', copied: 'Copié',
          failed: 'La copie a échoué. La référence est sélectionnée ci-dessous : copiez-la vous-même.' },
    de: { heading: 'Fundstelle', aria: 'Fundstelle kopieren', copied: 'Kopiert',
          failed: 'Das Kopieren ist fehlgeschlagen. Die Fundstelle ist unten markiert: Kopieren Sie sie selbst.' },
    en: { heading: 'Citation', aria: 'Copy citation', copied: 'Copied',
          failed: 'Copying failed. The citation is selected below: copy it yourself.' }
  }.freeze
  VNA_LABELS = { heading: 'Referentie (V&A)', aria: 'Kopieer referentie', copied: 'Gekopieerd',
                 failed: 'Kopiëren is niet gelukt. De referentie staat hieronder geselecteerd: kopieer ze zelf.' }.freeze
  NUMBER_WORD = { nl: 'nr.', fr: 'n°', de: 'Nr.', en: 'No.' }.freeze
  FRENCH_CITY = { 'Antwerpen' => "d'Anvers", 'Brussel' => 'de Bruxelles', 'Bruxelles' => 'de Bruxelles', 'Gent' => 'de Gand',
                  'Gand' => 'de Gand', 'Liège' => 'de Liège', 'Mons' => 'de Mons' }.freeze
  GERMAN_APPEAL_CITY = { 'Antwerpen' => 'Antwerpen', 'Brussel' => 'Brüssel', 'Bruxelles' => 'Brüssel', 'Gent' => 'Gent',
                         'Gand' => 'Gent', 'Liège' => 'Lüttich', 'Mons' => 'Mons' }.freeze
  GERMAN_LABOUR_CITY = { 'Liège' => 'Lüttich', 'Mons' => 'Mons' }.freeze
  FRENCH_COURT_LABEL = /\A(?:Cour|Tribunal|Conseil|Commission|Autorité)\b/
  DUTCH_COURT_LABEL = /\A(?:Hof|Raad|Arbeidshof|Arbeidsrechtbank|Rechtbank|Ondernemingsrechtbank|Nederlandstalige|Commissie|Gegevensbeschermingsautoriteit|Grondwettelijk)\b/

  # { heading:, text:, aria:, copied:, failed: } for the interface language, or nil without a readable ECLI.
  def jurisprudence_reference(record, locale = I18n.locale)
    locale = locale.to_sym
    if locale == :nl && (citation = jurisprudence_dutch_citation(record))
      return VNA_LABELS.merge(text: citation)
    end

    text = jurisprudence_plain_reference(record, PLAIN_LABELS.key?(locale) ? locale : :en)
    text && PLAIN_LABELS.fetch(PLAIN_LABELS.key?(locale) ? locale : :en).merge(text: text)
  end

  def jurisprudence_plain_reference(record, locale)
    ecli = record[:case_number].to_s.strip
    match = PLAIN_ECLI.match(ecli)
    return unless match

    day = Date.iso8601(record[:decision_date].to_s) rescue nil # rubocop:disable Style/RescueModifier
    return ecli if day.nil? || match[2].to_i != day.year || (match[4].match?(/\A\d{8}\./) && match[4][0, 8] != day.strftime('%Y%m%d'))

    decision = %w[ARR JUG DEC ORD].include?(match[3])
    court = decision ? jurisprudence_plain_court(record[:court].to_s, day, locale) : nil
    number = decision ? jurisprudence_plain_number(match, day) : nil
    [court, jurisprudence_plain_day(day, locale), number && "#{NUMBER_WORD.fetch(locale)} #{number}", ecli].compact.join(', ')
  end

  private

  def jurisprudence_dutch_court(name, day)
    COURTS.each do |pattern, form|
      match = pattern.match(name)
      next unless match

      city = match[1] && CITY.fetch(match[1])
      return case form
             # V&A: "Arbitragehof (vanaf mei 2007 Grondwettelijk Hof)".
             when :constitutional then day >= Date.new(2007, 5, 1) ? 'GwH' : 'Arbitragehof'
             # V&A: "ondernemingsrechtbank (vóór november 2018 rechtbank van koophandel)".
             when :enterprise then "#{day >= Date.new(2018, 11, 1) ? 'Orb.' : 'Kh.'} #{city}"
             when :enterprise_nl then "#{day >= Date.new(2018, 11, 1) ? 'Orb.' : 'Kh.'} Brussel (Nl.)"
             when :enterprise_fr then "#{day >= Date.new(2018, 11, 1) ? 'Orb.' : 'Kh.'} Brussel (Fr.)"
             else city ? format(form, city) : form
             end
    end
    nil
  end

  # RS1 cites the Council of State's arrest number ("RvS 26 maart 2024, 259.259, ECLI:...") and the Constitutional
  # Court's "81/2020" ("GwH 4 juni 2020, 81/2020, ECLI:BE:GHCC:2020:ARR.081."); elsewhere the ECLI carries no number
  # RS1 would cite, and the reference gives the ECLI alone ("HvB Gent 24 november 2015, ECLI:...").
  def jurisprudence_cited_number(court, match)
    if court == 'RvS'
      match[3] == 'ARR' && match[1] == 'RVSCE' && match[4].match?(/\A\d{1,3}(?:\.\d{3})*\z/) ? match[4] : nil
    elsif court == 'GwH' && match[1] == 'GHCC' && match[3] == 'ARR' && match[4].match?(/\A\d{1,4}\z/)
      "#{match[4].to_i}/#{match[2]}"
    end
  end

  def jurisprudence_plain_number(match, day)
    if match[1] == 'RVSCE' && %w[ARR ORD].include?(match[3]) && match[4].match?(/\A\d{1,3}(?:\.\d{3})*\z/)
      match[4]
    elsif match[1] == 'GHCC' && match[3] == 'ARR' && match[4].match?(/\A\d{1,4}\z/) && day >= Date.new(2007, 5, 1)
      "#{match[4].to_i}/#{match[2]}"
    end
  end

  def jurisprudence_plain_day(day, locale)
    case locale
    when :fr then "#{day.day == 1 ? '1er' : day.day} #{I18n.t('date.month_names', locale: :fr)[day.month]} #{day.year}"
    when :de then "#{day.day}. #{I18n.t('date.month_names', locale: :de)[day.month]} #{day.year}"
    when :en then "#{day.day} #{I18n.t('date.month_names', locale: :en)[day.month]} #{day.year}"
    else "#{day.day} #{DUTCH_MONTHS[day.month - 1]} #{day.year}"
    end
  end

  # The court's name in the interface language, or nil when no official text in that language names it so.
  def jurisprudence_plain_court(name, day, locale)
    constitutional = name.match?(/\A(?:Grondwettelijk Hof \(Arbitragehof\)|Cour constitutionnelle \(Cour d'arbitrage\))\z/)
    since_2007 = day >= Date.new(2007, 5, 1)
    appeal = name.match(/\A(?:Hof van beroep van|Cour d'appel de) (Antwerpen|Brussel|Bruxelles|Gent|Gand|Liège|Mons)\z/)
    labour = name.match(/\A(?:Arbeidshof van|Cour du travail de) (Antwerpen|Brussel|Bruxelles|Gent|Gand|Liège|Mons)\z/)
    case locale
    when :fr
      return 'Cour constitutionnelle' if constitutional && since_2007
      return "Cour d'arbitrage" if constitutional
      return 'Conseil d\'État' if name.match?(/\A(?:Raad van State|Conseil d'État)\z/)
      return 'Cour de cassation' if name.match?(/\A(?:Hof van Cassatie|Cour de cassation)\z/)
      return "Cour d'appel #{FRENCH_CITY.fetch(appeal[1])}" if appeal
      return "Cour du travail #{FRENCH_CITY.fetch(labour[1])}" if labour
      return "Tribunal du travail d'Anvers" if name == 'Arbeidsrechtbank Antwerpen'
      return 'Tribunal du travail de Gand' if name == 'Arbeidsrechtbank Gent'
      return 'Autorité de protection des données' if name == 'Gegevensbeschermingsautoriteit'
      return 'Commission pour la protection de la vie privée' if name == 'Commissie voor de bescherming van de persoonlijke levenssfeer'
      return COURT_FR_VICTIMS if name == VICTIMS
      return nil if name.match?(/entreprise/i) && day < Date.new(2018, 11, 1)

      name if name.match?(FRENCH_COURT_LABEL)
    when :de
      return (since_2007 ? 'Verfassungsgerichtshof' : 'Schiedshof') if constitutional
      return 'Staatsrat' if name.match?(/\A(?:Raad van State|Conseil d'État)\z/)
      return 'Kassationshof' if name.match?(/\A(?:Hof van Cassatie|Cour de cassation)\z/)
      return "Appellationshof von #{GERMAN_APPEAL_CITY.fetch(appeal[1])}" if appeal
      return "Arbeitsgerichtshof von #{GERMAN_LABOUR_CITY[labour[1]]}" if labour && GERMAN_LABOUR_CITY.key?(labour[1])

      'Datenschutzbehörde' if name.match?(/\A(?:Gegevensbeschermingsautoriteit|Autorité de protection des données)\z/)
    when :en
      return 'Constitutional Court' if constitutional && since_2007

      'Court of Cassation' if name.match?(/\A(?:Hof van Cassatie|Cour de cassation)\z/)
    else
      return nil if name.match?(/onderneming/i) && day < Date.new(2018, 11, 1)

      name if name.match?(DUTCH_COURT_LABEL)
    end
  end
end
