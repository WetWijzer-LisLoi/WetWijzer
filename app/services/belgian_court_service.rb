# frozen_string_literal: true

# Service providing structured metadata about Belgian courts
# Based on Belgian Constitution, Judicial Code (Gerechtelijk Wetboek)
#
# Court hierarchy:
#   Level 1: Supreme Courts (Hoogste Rechtscolleges)
#   Level 2: Appeal Courts (Hoven)
#   Level 3: First Instance Courts (Rechtbanken)
#   Level 4: Minor Courts (Lagere Rechtbanken)
class BelgianCourtService
  # Court categories
  CATEGORIES = {
    judicial: 'judicial',
    administrative: 'administrative',
    constitutional: 'constitutional'
  }.freeze

  # Court metadata with hierarchy, names, and appeal routes
  # rubocop:disable Metrics/MethodLength
  COURTS = {
    # Level 1: Supreme Courts
    hof_van_cassatie: {
      level: 1,
      category: :judicial,
      name_nl: 'Hof van Cassatie',
      name_fr: 'Cour de Cassation',
      appeal_to: nil,
      appeal_deadline_days: nil,
      description_nl: 'Hoogste rechterlijke instantie, toetst alleen rechtsvragen',
      description_fr: 'Cour suprême judiciaire, examine uniquement les questions de droit'
    },
    grondwettelijk_hof: {
      level: 1,
      category: :constitutional,
      name_nl: 'Grondwettelijk Hof',
      name_fr: 'Cour Constitutionnelle',
      appeal_to: nil,
      appeal_deadline_days: nil,
      description_nl: 'Toetst grondwettigheid van wetten, decreten en ordonnanties',
      description_fr: 'Contrôle la constitutionnalité des lois, décrets et ordonnances'
    },
    raad_van_state: {
      level: 1,
      category: :administrative,
      name_nl: 'Raad van State',
      name_fr: "Conseil d'État",
      appeal_to: nil,
      appeal_deadline_days: nil,
      description_nl: 'Hoogste administratieve rechtscollege en adviesorgaan',
      description_fr: 'Cour administrative suprême et organe consultatif'
    },

    # Level 2: Appeal Courts
    hof_van_beroep: {
      level: 2,
      category: :judicial,
      name_nl: 'Hof van Beroep',
      name_fr: "Cour d'appel",
      appeal_to: :hof_van_cassatie,
      appeal_deadline_days: 90,
      description_nl: 'Behandelt hoger beroep van rechtbanken eerste aanleg',
      description_fr: 'Traite les appels des tribunaux de première instance'
    },
    arbeidshof: {
      level: 2,
      category: :judicial,
      name_nl: 'Arbeidshof',
      name_fr: 'Cour du travail',
      appeal_to: :hof_van_cassatie,
      appeal_deadline_days: 90,
      description_nl: 'Behandelt hoger beroep van arbeidsrechtbanken',
      description_fr: 'Traite les appels des tribunaux du travail'
    },
    hof_van_assisen: {
      level: 2,
      category: :judicial,
      name_nl: 'Hof van Assisen',
      name_fr: "Cour d'assises",
      appeal_to: :hof_van_cassatie,
      appeal_deadline_days: 15,
      description_nl: 'Berecht zwaarste misdrijven met jury',
      description_fr: 'Juge les crimes les plus graves avec jury'
    },

    # Level 3: First Instance Courts
    rechtbank_eerste_aanleg: {
      level: 3,
      category: :judicial,
      name_nl: 'Rechtbank van Eerste Aanleg',
      name_fr: 'Tribunal de première instance',
      appeal_to: :hof_van_beroep,
      appeal_deadline_days: 30,
      description_nl: 'Algemene burgerlijke en strafrechtelijke bevoegdheid',
      description_fr: 'Compétence générale civile et pénale'
    },
    arbeidsrechtbank: {
      level: 3,
      category: :judicial,
      name_nl: 'Arbeidsrechtbank',
      name_fr: 'Tribunal du travail',
      appeal_to: :arbeidshof,
      appeal_deadline_days: 30,
      description_nl: 'Arbeidsgeschillen en sociale zekerheid',
      description_fr: 'Litiges du travail et sécurité sociale'
    },
    ondernemingsrechtbank: {
      level: 3,
      category: :judicial,
      name_nl: 'Ondernemingsrechtbank',
      name_fr: "Tribunal de l'entreprise",
      appeal_to: :hof_van_beroep,
      appeal_deadline_days: 30,
      description_nl: 'Handelsgeschillen, faillissementen, vennootschapsrecht',
      description_fr: 'Litiges commerciaux, faillites, droit des sociétés'
    },

    # Level 4: Minor Courts
    vredegerecht: {
      level: 4,
      category: :judicial,
      name_nl: 'Vredegerecht',
      name_fr: 'Justice de paix',
      appeal_to: :rechtbank_eerste_aanleg,
      appeal_deadline_days: 30,
      description_nl: 'Burgerlijke geschillen ≤ €5.000, huur, bewind',
      description_fr: 'Litiges civils ≤ 5.000 €, bail, administration'
    },
    politierechtbank: {
      level: 4,
      category: :judicial,
      name_nl: 'Politierechtbank',
      name_fr: 'Tribunal de police',
      appeal_to: :rechtbank_eerste_aanleg,
      appeal_deadline_days: 30,
      description_nl: 'Verkeersovertredingen, overtredingen',
      description_fr: 'Infractions routières, contraventions'
    },

    # Special courts
    beslagrechter: {
      level: 3,
      category: :judicial,
      name_nl: 'Beslagrechter',
      name_fr: 'Juge des saisies',
      appeal_to: :hof_van_beroep,
      appeal_deadline_days: 30,
      description_nl: 'Beslag- en executiegeschillen',
      description_fr: 'Saisies et litiges d\'exécution'
    },
    handhavingscollege: {
      level: 2,
      category: :administrative,
      name_nl: 'Handhavingscollege',
      name_fr: 'Collège de maintien',
      appeal_to: :raad_van_state,
      appeal_deadline_days: 60,
      description_nl: 'Vlaamse administratieve handhaving',
      description_fr: 'Exécution administrative flamande'
    }
  }.freeze
  # rubocop:enable Metrics/MethodLength

  # Bilingual terminology for legal terms (NL <-> FR)
  LEGAL_TERMINOLOGY = {
    # Judgment types
    'vonnis' => %w[jugement judgment],
    'arrest' => %w[arrêt ruling],
    'beschikking' => %w[ordonnance order],

    # Procedures
    'hoger beroep' => %w[appel appeal],
    'cassatieberoep' => ['pourvoi en cassation', 'cassation appeal'],
    'verzet' => %w[opposition objection],
    'derdenverzet' => ['tierce opposition', 'third party objection'],

    # Service/notification
    'betekening' => %w[signification service],
    'kennisgeving' => %w[notification notification],
    'dagvaarding' => %w[citation summons],

    # Parties
    'eiser' => %w[demandeur plaintiff],
    'verweerder' => %w[défendeur defendant],
    'appellant' => %w[appelant appellant],
    'geïntimeerde' => %w[intimé respondent],

    # Document types
    'conclusie' => %w[conclusions submissions],
    'verzoekschrift' => %w[requête petition],
    'memorie' => %w[mémoire brief],

    # Courts (short forms)
    'rb.' => ['trib.', 'court'],
    'hof' => %w[cour court],
    'rechtbank' => %w[tribunal court]
  }.freeze

  # Judicial districts mapping
  JUDICIAL_DISTRICTS = {
    antwerpen: { area: 'Antwerpen', divisions: %w[Antwerpen Mechelen Turnhout] },
    limburg: { area: 'Antwerpen', divisions: %w[Hasselt Tongeren] },
    brussel: { area: 'Brussel', divisions: ['Brussel'], bilingual: true },
    waals_brabant: { area: 'Brussel', divisions: ['Nijvel'], language: :fr },
    leuven: { area: 'Brussel', divisions: ['Leuven'], language: :nl },
    oost_vlaanderen: { area: 'Gent', divisions: %w[Gent Dendermonde Oudenaarde] },
    west_vlaanderen: { area: 'Gent', divisions: %w[Brugge Kortrijk Ieper Veurne] },
    luik: { area: 'Luik', divisions: %w[Luik Hoei Verviers] },
    namen: { area: 'Luik', divisions: %w[Namen Dinant] },
    luxemburg: { area: 'Luik', divisions: ['Aarlen', 'Marche-en-Famenne', 'Neufchâteau'] },
    eupen: { area: 'Luik', divisions: ['Eupen'], language: :de },
    henegouwen: { area: 'Bergen', divisions: %w[Bergen Charleroi Doornik] }
  }.freeze

  # Belgian public holidays (fixed dates)
  FIXED_HOLIDAYS = {
    [1, 1] => { nl: 'Nieuwjaar', fr: 'Nouvel An' },
    [5, 1] => { nl: 'Dag van de Arbeid', fr: 'Fête du Travail' },
    [7, 21] => { nl: 'Nationale Feestdag', fr: 'Fête Nationale' },
    [8, 15] => { nl: 'OLV Hemelvaart', fr: 'Assomption' },
    [11, 1] => { nl: 'Allerheiligen', fr: 'Toussaint' },
    [11, 11] => { nl: 'Wapenstilstand', fr: 'Armistice' },
    [12, 25] => { nl: 'Kerstmis', fr: 'Noël' }
  }.freeze

  # Judicial vacation period (Art. 50 Ger.W.)
  JUDICIAL_VACATION_START_MONTH = 7
  JUDICIAL_VACATION_START_DAY = 1
  JUDICIAL_VACATION_END_MONTH = 8
  JUDICIAL_VACATION_END_DAY = 31
  JUDICIAL_VACATION_EXTENSION_DAY = 15 # September 15

  class << self
    # Get court info by key
    def court_info(court_key)
      COURTS[court_key.to_sym]
    end

    # Get all courts at a specific hierarchy level
    def courts_at_level(level)
      COURTS.select { |_, info| info[:level] == level }
    end

    # Get courts grouped by hierarchy level
    def courts_by_level
      COURTS.group_by { |_, info| info[:level] }
             .sort_by { |level, _| level }
             .to_h
             .transform_values { |courts| courts.to_h }
    end

    # Get appeal route for a court
    def appeal_route(court_key)
      info = court_info(court_key)
      return nil unless info && info[:appeal_to]

      {
        from: court_key,
        to: info[:appeal_to],
        deadline_days: info[:appeal_deadline_days],
        to_info: court_info(info[:appeal_to])
      }
    end

    # Normalize a court name from jurisprudence to a standard key
    def normalize_court_name(court_name)
      return nil if court_name.blank?

      name = court_name.to_s.downcase

      COURTS.each do |key, info|
        return key if name.include?(info[:name_nl].downcase) ||
                      name.include?(info[:name_fr].downcase)
      end

      nil
    end

    # Get court name in specified locale
    def court_name(court_key, locale = :nl)
      info = court_info(court_key)
      return nil unless info

      locale == :fr ? info[:name_fr] : info[:name_nl]
    end

    # Get hierarchy level label
    def level_label(level, locale = :nl)
      labels = {
        1 => { nl: 'Hoogste Rechtscolleges', fr: 'Cours Suprêmes' },
        2 => { nl: 'Hoven', fr: "Cours d'appel" },
        3 => { nl: 'Rechtbanken', fr: 'Tribunaux' },
        4 => { nl: 'Lagere Rechtbanken', fr: 'Juridictions inférieures' }
      }

      labels.dig(level, locale) || "Level #{level}"
    end

    # Expand search query with bilingual synonyms
    def expand_query_with_synonyms(query)
      return [] if query.blank?

      terms = query.to_s.downcase.split(/\s+/)
      expanded = []

      LEGAL_TERMINOLOGY.each do |nl_term, translations|
        if terms.include?(nl_term) || terms.any? { |t| nl_term.include?(t) }
          expanded.concat(translations)
        end

        translations.each do |trans|
          if terms.include?(trans.downcase) || terms.any? { |t| trans.downcase.include?(t) }
            expanded << nl_term
            expanded.concat(translations - [trans])
          end
        end
      end

      expanded.uniq
    end

    # Get grouped courts for UI dropdown (jurisprudence filter)
    def grouped_courts_for_select(locale = :nl)
      {
        level_label(1, locale) => courts_at_level(1).map { |k, v| [locale == :fr ? v[:name_fr] : v[:name_nl], k] },
        level_label(2, locale) => courts_at_level(2).map { |k, v| [locale == :fr ? v[:name_fr] : v[:name_nl], k] },
        level_label(3, locale) => courts_at_level(3).map { |k, v| [locale == :fr ? v[:name_fr] : v[:name_nl], k] },
        level_label(4, locale) => courts_at_level(4).map { |k, v| [locale == :fr ? v[:name_fr] : v[:name_nl], k] }
      }
    end

    # === DEADLINE CALCULATOR ===

    # Calculate Easter Sunday for a given year (Computus algorithm)
    def easter_sunday(year)
      a = year % 19
      b = year / 100
      c = year % 100
      d = b / 4
      e = b % 4
      f = (b + 8) / 25
      g = (b - f + 1) / 3
      h = (19 * a + b - d - g + 15) % 30
      i = c / 4
      k = c % 4
      l = (32 + 2 * e + 2 * i - h - k) % 7
      m = (a + 11 * h + 22 * l) / 451
      month = (h + l - 7 * m + 114) / 31
      day = ((h + l - 7 * m + 114) % 31) + 1
      Date.new(year, month, day)
    end

    # Get all Belgian public holidays for a given year
    def public_holidays(year)
      holidays = {}

      # Fixed holidays
      FIXED_HOLIDAYS.each do |(month, day), names|
        holidays[Date.new(year, month, day)] = names
      end

      # Easter-based holidays
      easter = easter_sunday(year)
      holidays[easter] = { nl: 'Pasen', fr: 'Pâques' }
      holidays[easter + 1] = { nl: 'Paasmaandag', fr: 'Lundi de Pâques' }
      holidays[easter + 39] = { nl: 'Hemelvaart', fr: 'Ascension' }
      holidays[easter + 49] = { nl: 'Pinksteren', fr: 'Pentecôte' }
      holidays[easter + 50] = { nl: 'Pinkstermaandag', fr: 'Lundi de Pentecôte' }

      holidays
    end

    # Check if a date is a Belgian public holiday
    def public_holiday?(date)
      public_holidays(date.year).key?(date.to_date)
    end

    # Get holiday name if date is a holiday
    def holiday_name(date, locale = :nl)
      holidays = public_holidays(date.year)
      holiday = holidays[date.to_date]
      holiday ? holiday[locale] : nil
    end

    # Check if a date is during judicial vacation (July 1 - August 31)
    def during_judicial_vacation?(date)
      d = date.to_date
      vacation_start = Date.new(d.year, JUDICIAL_VACATION_START_MONTH, JUDICIAL_VACATION_START_DAY)
      vacation_end = Date.new(d.year, JUDICIAL_VACATION_END_MONTH, JUDICIAL_VACATION_END_DAY)
      d >= vacation_start && d <= vacation_end
    end

    # Check if a date is a working day (not weekend, not holiday)
    def working_day?(date)
      d = date.to_date
      return false if d.saturday? || d.sunday?
      return false if public_holiday?(d)

      true
    end

    # Get the next working day from a given date
    def next_working_day(date)
      d = date.to_date + 1
      d += 1 until working_day?(d)
      d
    end

    # Calculate appeal deadline from service/notification date
    # Implements Belgian procedural rules:
    # - Standard: deadline_days from day after service
    # - If deadline falls on weekend/holiday: extended to next working day
    # - Judicial vacation rule (Art. 50 Ger.W.): if deadline starts AND expires during vacation,
    #   extended to September 15
    #
    # @param service_date [Date] The date of service (betekening) or notification
    # @param deadline_days [Integer] Number of days for the deadline (e.g., 30, 90)
    # @param apply_vacation_rule [Boolean] Whether to apply judicial vacation extension
    # @return [Hash] { deadline: Date, extended: Boolean, reason: String, warnings: Array }
    def calculate_deadline(service_date, deadline_days, apply_vacation_rule: true)
      start_date = service_date.to_date
      # Deadline runs from day AFTER service
      raw_deadline = start_date + deadline_days

      result = {
        service_date: start_date,
        deadline_days: deadline_days,
        raw_deadline: raw_deadline,
        final_deadline: raw_deadline,
        extended: false,
        extension_reason: nil,
        warnings: [],
        holidays_in_period: []
      }

      # Collect holidays in the period for information
      (start_date..raw_deadline).each do |d|
        if public_holiday?(d)
          result[:holidays_in_period] << { date: d, name: holiday_name(d) }
        end
      end

      # Check judicial vacation rule (Art. 50 Ger.W.)
      if apply_vacation_rule && during_judicial_vacation?(start_date) && during_judicial_vacation?(raw_deadline)
        # Both start and deadline during vacation -> extend to September 15
        vacation_extension = Date.new(raw_deadline.year, 9, JUDICIAL_VACATION_EXTENSION_DAY)
        if vacation_extension > raw_deadline
          result[:final_deadline] = vacation_extension
          result[:extended] = true
          result[:extension_reason] = 'judicial_vacation'
          result[:warnings] << 'Judicial vacation rule applies (Art. 50 Ger.W.)'
        end
      end

      # If deadline falls on weekend or holiday, extend to next working day
      unless working_day?(result[:final_deadline])
        original = result[:final_deadline]
        result[:final_deadline] = next_working_day(result[:final_deadline])
        result[:extended] = true
        reason = result[:extension_reason]
        if original.saturday? || original.sunday?
          result[:extension_reason] = reason ? "#{reason}_and_weekend" : 'weekend'
        else
          holiday = holiday_name(original)
          result[:extension_reason] = reason ? "#{reason}_and_holiday" : 'holiday'
          result[:warnings] << "Falls on #{holiday}"
        end
      end

      result
    end

    # Count workdays between two dates (excluding weekends and holidays)
    # @param start_date [Date] Start date
    # @param end_date [Date] End date
    # @return [Hash] Breakdown of days
    def days_between(start_date, end_date)
      start_d = start_date.to_date
      end_d = end_date.to_date
      
      # Ensure start <= end
      start_d, end_d = end_d, start_d if start_d > end_d
      
      total_days = (end_d - start_d).to_i
      
      workdays = 0
      weekends = 0
      holidays = []
      
      (start_d...end_d).each do |d|
        if d.saturday? || d.sunday?
          weekends += 1
        elsif public_holiday?(d)
          holidays << { date: d, name: holiday_name(d) }
        else
          workdays += 1
        end
      end
      
      # Calculate weeks, months breakdown
      weeks = total_days / 7
      remaining_days = total_days % 7
      
      # Approximate months (for display)
      months = total_days / 30
      days_after_months = total_days % 30
      
      {
        total_days: total_days,
        workdays: workdays,
        weekends: weekends,
        holidays: holidays,
        holiday_count: holidays.size,
        weeks: weeks,
        remaining_days: remaining_days,
        months: months,
        days_after_months: days_after_months,
        start_date: start_d,
        end_date: end_d
      }
    end

    # Add days to a date (with workdays-only option)
    # @param start_date [Date] Start date
    # @param days [Integer] Number of days to add
    # @param workdays_only [Boolean] If true, only count workdays
    # @return [Hash] Result with end date and breakdown
    def add_days(start_date, days, workdays_only: false)
      start_d = start_date.to_date
      
      if workdays_only
        # Add workdays only (skip weekends and holidays)
        current = start_d
        days_added = 0
        skipped_weekends = 0
        skipped_holidays = []
        
        while days_added < days
          current += 1
          if current.saturday? || current.sunday?
            skipped_weekends += 1
          elsif public_holiday?(current)
            skipped_holidays << { date: current, name: holiday_name(current) }
          else
            days_added += 1
          end
        end
        
        {
          start_date: start_d,
          end_date: current,
          days_requested: days,
          actual_calendar_days: (current - start_d).to_i,
          workdays_added: days_added,
          weekends_skipped: skipped_weekends,
          holidays_skipped: skipped_holidays,
          workdays_only: true
        }
      else
        # Regular calendar days
        end_d = start_d + days
        between = days_between(start_d, end_d)
        between.merge(
          days_requested: days,
          workdays_only: false
        )
      end
    end

    # Get week number for a date (ISO 8601)
    def week_number(date)
      date.to_date.cweek
    end

    # Get day of year
    def day_of_year(date)
      date.to_date.yday
    end

    # Get courts with their appeal deadlines for the calculator UI
    def courts_for_deadline_calculator(locale = :nl)
      COURTS.map do |key, info|
        next unless info[:appeal_deadline_days]

        {
          key: key,
          name: locale == :fr ? info[:name_fr] : info[:name_nl],
          deadline_days: info[:appeal_deadline_days],
          appeal_to: info[:appeal_to] ? (locale == :fr ? COURTS[info[:appeal_to]][:name_fr] : COURTS[info[:appeal_to]][:name_nl]) : nil
        }
      end.compact
    end

    # === LAW ↔ COURT JURISDICTION LINKING ===

    # Law type patterns that indicate specific court jurisdiction
    LAW_COURT_MAPPINGS = {
      # Labor law -> Arbeidsrechtbank/Arbeidshof
      labor: {
        patterns: [
          /arbeidsovereenkomst/i, /contrat de travail/i,
          /sociale zekerheid/i, /sécurité sociale/i,
          /werkloosheid/i, /chômage/i,
          /arbeidsongevallen/i, /accidents du travail/i,
          /beroepsziekte/i, /maladie professionnelle/i,
          /cao/i, /cct/i, /collectieve arbeidsovereenkomst/i
        ],
        courts: [:arbeidsrechtbank, :arbeidshof]
      },
      # Commercial/Enterprise law -> Ondernemingsrechtbank
      commercial: {
        patterns: [
          /vennootschap/i, /société/i,
          /faillissement/i, /faillite/i,
          /handelspraktijken/i, /pratiques commerciales/i,
          /onderneming/i, /entreprise/i,
          /wetboek van vennootschappen/i, /code des sociétés/i,
          /intellectuele eigendom/i, /propriété intellectuelle/i,
          /mededinging/i, /concurrence/i
        ],
        courts: [:ondernemingsrechtbank, :hof_van_beroep]
      },
      # Administrative law -> Raad van State
      administrative: {
        patterns: [
          /administratief recht/i, /droit administratif/i,
          /stedenbouw/i, /urbanisme/i,
          /milieu/i, /environnement/i,
          /overheidsopdrachten/i, /marchés publics/i,
          /ambtenaren/i, /fonctionnaires/i
        ],
        courts: [:raad_van_state]
      },
      # Constitutional -> Grondwettelijk Hof
      constitutional: {
        patterns: [
          /grondwet/i, /constitution/i,
          /fundamentele rechten/i, /droits fondamentaux/i,
          /bevoegdheidsverdeling/i, /répartition des compétences/i
        ],
        courts: [:grondwettelijk_hof]
      },
      # Criminal -> Correctionele rechtbank / Hof van Assisen
      criminal: {
        patterns: [
          /strafwetboek/i, /code pénal/i,
          /strafvordering/i, /procédure pénale/i,
          /misdrijf/i, /infraction/i
        ],
        courts: [:rechtbank_eerste_aanleg, :hof_van_beroep, :hof_van_assisen]
      },
      # Tax law -> Various
      tax: {
        patterns: [
          /belasting/i, /impôt/i, /taxe/i,
          /btw/i, /tva/i,
          /inkomstenbelasting/i, /impôt sur le revenu/i,
          /fiscaal/i, /fiscal/i
        ],
        courts: [:rechtbank_eerste_aanleg, :hof_van_beroep]
      },
      # Family law -> Familierechtbank
      family: {
        patterns: [
          /echtscheiding/i, /divorce/i,
          /alimentatie/i, /pension alimentaire/i,
          /voogdij/i, /tutelle/i,
          /ouderlijk gezag/i, /autorité parentale/i,
          /afstamming/i, /filiation/i
        ],
        courts: [:rechtbank_eerste_aanleg]
      },
      # Rental/Lease -> Vredegerecht
      rental: {
        patterns: [
          /huur/i, /bail/i, /location/i,
          /pacht/i, /fermage/i,
          /woninghuur/i, /bail de résidence/i
        ],
        courts: [:vredegerecht]
      },
      # Traffic -> Politierechtbank
      traffic: {
        patterns: [
          /verkeer/i, /circulation/i, /roulage/i,
          /wegcode/i, /code de la route/i
        ],
        courts: [:politierechtbank]
      }
    }.freeze

    # Detect relevant courts based on law title and content
    # @param title [String] Law title
    # @param content [String, nil] Optional law content/introduction for better matching
    # @return [Array<Hash>] Array of relevant courts with reasons
    def detect_relevant_courts(title, content = nil, locale = :nl)
      text = "#{title} #{content}".to_s
      return [] if text.blank?

      matches = []

      LAW_COURT_MAPPINGS.each do |category, config|
        next unless config[:patterns].any? { |pattern| text.match?(pattern) }

        config[:courts].each do |court_key|
          info = COURTS[court_key]
          next unless info

          matches << {
            court_key: court_key,
            name: locale == :fr ? info[:name_fr] : info[:name_nl],
            level: info[:level],
            category: category,
            description: locale == :fr ? info[:description_fr] : info[:description_nl]
          }
        end
      end

      # Remove duplicates and sort by level (higher courts first)
      matches.uniq { |m| m[:court_key] }.sort_by { |m| m[:level] }
    end

    # Get a simple jurisdiction summary for display
    # @param title [String] Law title
    # @return [String, nil] Jurisdiction summary or nil
    def jurisdiction_summary(title, locale = :nl)
      courts = detect_relevant_courts(title, nil, locale)
      return nil if courts.empty?

      court_names = courts.map { |c| c[:name] }.first(3)
      if locale == :fr
        "Juridictions: #{court_names.join(', ')}"
      else
        "Bevoegde rechtbanken: #{court_names.join(', ')}"
      end
    end

    # === BELGIAN LEGAL INTEREST RATES ===
    # Source: https://financien.belgium.be/nl/particulieren/wettelijke_interestvoet
    # Updated annually by Royal Decree

    LEGAL_INTEREST_RATES = {
      # Civil/commercial rates (Art. 1153 BW / Art. 5 Wet 2 augustus 2002)
      civil: {
        2020 => 1.75,
        2021 => 1.75,
        2022 => 1.50,
        2023 => 5.25,
        2024 => 5.75,
        2025 => 4.75,
        2026 => 4.00  # Provisional
      },
      # Tax rates (slightly higher)
      tax: {
        2020 => 4.00,
        2021 => 4.00,
        2022 => 4.00,
        2023 => 7.00,
        2024 => 8.00,
        2025 => 6.75,
        2026 => 6.00  # Provisional
      },
      # Social security rates
      social: {
        2020 => 4.00,
        2021 => 4.00,
        2022 => 4.00,
        2023 => 7.00,
        2024 => 8.00,
        2025 => 6.75,
        2026 => 6.00  # Provisional
      }
    }.freeze

    # Get legal interest rates for display
    def legal_interest_rates
      current_year = Date.current.year
      years = ((current_year - 5)..current_year).to_a.reverse

      years.map do |year|
        {
          year: year,
          civil: LEGAL_INTEREST_RATES[:civil][year],
          tax: LEGAL_INTEREST_RATES[:tax][year],
          social: LEGAL_INTEREST_RATES[:social][year]
        }
      end.compact
    end

    # Calculate legal interest on a principal amount
    # @param principal [Float] The principal amount
    # @param start_date [Date] Start date for interest calculation
    # @param end_date [Date] End date (default: today)
    # @param rate_type [String] 'civil', 'tax', or 'social'
    # @return [Hash] Calculation result with breakdown
    def calculate_interest(principal, start_date, end_date = Date.current, rate_type: 'civil')
      start_d = start_date.to_date
      end_d = end_date.to_date
      start_d, end_d = end_d, start_d if start_d > end_d

      rates = LEGAL_INTEREST_RATES[rate_type.to_sym] || LEGAL_INTEREST_RATES[:civil]
      
      total_interest = 0.0
      breakdown = []

      # Calculate interest per year (rates change annually)
      current = start_d
      while current < end_d
        year = current.year
        year_end = Date.new(year, 12, 31)
        period_end = [year_end, end_d].min

        days_in_period = (period_end - current).to_i + 1
        days_in_year = Date.leap?(year) ? 366 : 365
        rate = rates[year] || rates.values.last

        # Simple interest: Principal × Rate × (Days / 365)
        period_interest = principal * (rate / 100.0) * (days_in_period.to_f / days_in_year)
        total_interest += period_interest

        breakdown << {
          year: year,
          start_date: current,
          end_date: period_end,
          days: days_in_period,
          rate: rate,
          interest: period_interest.round(2)
        }

        current = period_end + 1
      end

      {
        principal: principal,
        start_date: start_d,
        end_date: end_d,
        total_days: (end_d - start_d).to_i,
        rate_type: rate_type,
        total_interest: total_interest.round(2),
        total_amount: (principal + total_interest).round(2),
        breakdown: breakdown
      }
    end

    # === COURT FINDER ===

    # Find competent court based on case type and amount
    def find_competent_court(case_type:, amount: nil, district: nil)
      courts = []
      notes = nil

      case case_type.to_s
      when 'civil_general'
        if amount && amount <= 5000
          courts << court_result(:vredegerecht, true, 'Bedrag ≤ €5.000')
        else
          courts << court_result(:rechtbank_eerste_aanleg, true, amount ? 'Bedrag > €5.000' : nil)
          courts << court_result(:vredegerecht, false) if amount.nil?
        end
      when 'family'
        courts << court_result(:rechtbank_eerste_aanleg, true, 'Familierechtbank (afdeling)')
      when 'rental'
        courts << court_result(:vredegerecht, true, 'Exclusieve bevoegdheid huur/pacht')
      when 'small_claims'
        courts << court_result(:vredegerecht, true, 'Kleine geschillen')
      when 'commercial', 'bankruptcy', 'intellectual_property'
        courts << court_result(:ondernemingsrechtbank, true, 'Ondernemingsgeschillen')
      when 'labor', 'social_security'
        courts << court_result(:arbeidsrechtbank, true, 'Arbeids- en socialezekerheidsrecht')
      when 'criminal_minor', 'traffic'
        courts << court_result(:politierechtbank, true, 'Overtredingen en verkeer')
      when 'criminal_major'
        courts << court_result(:rechtbank_eerste_aanleg, true, 'Correctionele rechtbank')
        courts << court_result(:hof_van_assisen, false, 'Misdaden (jury)')
        notes = I18n.locale == :fr ? 'La qualification exacte détermine le tribunal compétent.' : 'De exacte kwalificatie bepaalt de bevoegde rechtbank.'
      when 'administrative'
        courts << court_result(:raad_van_state, true, 'Administratief beroep')
      when 'tax'
        courts << court_result(:rechtbank_eerste_aanleg, true, 'Fiscale geschillen')
      end

      { courts: courts, notes: notes }
    end

    def court_result(key, primary, reason = nil)
      info = COURTS[key]
      return nil unless info

      result = {
        key: key,
        name_nl: info[:name_nl],
        name_fr: info[:name_fr],
        description_nl: info[:description_nl],
        description_fr: info[:description_fr],
        level: info[:level],
        primary: primary,
        reason: reason
      }

      if info[:appeal_to]
        appeal_info = COURTS[info[:appeal_to]]
        result[:appeal_to] = { name_nl: appeal_info[:name_nl], name_fr: appeal_info[:name_fr] }
        result[:appeal_deadline] = info[:appeal_deadline_days]
      end

      result
    end

    # === LEGAL GLOSSARY ===

    LEGAL_GLOSSARY = [
      # Courts (12)
      { nl: 'Rechtbank', fr: 'Tribunal', category: 'Rechtbanken' },
      { nl: 'Hof', fr: 'Cour', category: 'Rechtbanken' },
      { nl: 'Vredegerecht', fr: 'Justice de paix', category: 'Rechtbanken' },
      { nl: 'Hof van Cassatie', fr: 'Cour de Cassation', category: 'Rechtbanken' },
      { nl: 'Raad van State', fr: "Conseil d'État", category: 'Rechtbanken' },
      { nl: 'Grondwettelijk Hof', fr: 'Cour Constitutionnelle', category: 'Rechtbanken' },
      { nl: 'Arbeidsrechtbank', fr: 'Tribunal du travail', category: 'Rechtbanken' },
      { nl: 'Ondernemingsrechtbank', fr: "Tribunal de l'entreprise", category: 'Rechtbanken' },
      { nl: 'Politierechtbank', fr: 'Tribunal de police', category: 'Rechtbanken' },
      { nl: 'Hof van Beroep', fr: "Cour d'appel", category: 'Rechtbanken' },
      { nl: 'Arbeidshof', fr: 'Cour du travail', category: 'Rechtbanken' },
      { nl: 'Hof van Assisen', fr: "Cour d'assises", category: 'Rechtbanken' },

      # Procedures (25)
      { nl: 'Dagvaarding', fr: 'Citation', category: 'Procedures' },
      { nl: 'Verzoekschrift', fr: 'Requête', category: 'Procedures' },
      { nl: 'Vonnis', fr: 'Jugement', category: 'Procedures' },
      { nl: 'Arrest', fr: 'Arrêt', category: 'Procedures' },
      { nl: 'Hoger beroep', fr: 'Appel', category: 'Procedures' },
      { nl: 'Cassatieberoep', fr: 'Pourvoi en cassation', category: 'Procedures' },
      { nl: 'Verzet', fr: 'Opposition', category: 'Procedures' },
      { nl: 'Derdenverzet', fr: 'Tierce opposition', category: 'Procedures' },
      { nl: 'Betekening', fr: 'Signification', category: 'Procedures' },
      { nl: 'Termijn', fr: 'Délai', category: 'Procedures' },
      { nl: 'Uitvoerbaarheid', fr: 'Exécution', category: 'Procedures' },
      { nl: 'Beslag', fr: 'Saisie', category: 'Procedures' },
      { nl: 'Conclusies', fr: 'Conclusions', category: 'Procedures' },
      { nl: 'Syntheseconclusie', fr: 'Conclusions de synthèse', category: 'Procedures' },
      { nl: 'Pleidooi', fr: 'Plaidoirie', category: 'Procedures' },
      { nl: 'Inleiding', fr: 'Introduction', category: 'Procedures' },
      { nl: 'Verstek', fr: 'Défaut', category: 'Procedures' },
      { nl: 'Tegensprekelijk', fr: 'Contradictoire', category: 'Procedures' },
      { nl: 'Voorlopige maatregelen', fr: 'Mesures provisoires', category: 'Procedures' },
      { nl: 'Kort geding', fr: 'Référé', category: 'Procedures' },
      { nl: 'Zoals in zake van kort geding', fr: 'Comme en référé', category: 'Procedures' },
      { nl: 'Griffie', fr: 'Greffe', category: 'Procedures' },
      { nl: 'Rolrecht', fr: 'Droit de rôle', category: 'Procedures' },
      { nl: 'Uitgifte', fr: 'Expédition', category: 'Procedures' },
      { nl: 'Grosse', fr: 'Grosse', category: 'Procedures' },

      # Parties (12)
      { nl: 'Eiser', fr: 'Demandeur', category: 'Partijen' },
      { nl: 'Verweerder', fr: 'Défendeur', category: 'Partijen' },
      { nl: 'Appellant', fr: 'Appelant', category: 'Partijen' },
      { nl: 'Geïntimeerde', fr: 'Intimé', category: 'Partijen' },
      { nl: 'Tussenkomende partij', fr: 'Partie intervenante', category: 'Partijen' },
      { nl: 'Burgerlijke partij', fr: 'Partie civile', category: 'Partijen' },
      { nl: 'Advocaat', fr: 'Avocat', category: 'Partijen' },
      { nl: 'Procureur', fr: 'Procureur', category: 'Partijen' },
      { nl: 'Rechter', fr: 'Juge', category: 'Partijen' },
      { nl: 'Raadsheer', fr: 'Conseiller', category: 'Partijen' },
      { nl: 'Deurwaarder', fr: 'Huissier de justice', category: 'Partijen' },
      { nl: 'Notaris', fr: 'Notaire', category: 'Partijen' },

      # Contracts (15)
      { nl: 'Overeenkomst', fr: 'Contrat', category: 'Contracten' },
      { nl: 'Verbintenis', fr: 'Obligation', category: 'Contracten' },
      { nl: 'Schuldeiser', fr: 'Créancier', category: 'Contracten' },
      { nl: 'Schuldenaar', fr: 'Débiteur', category: 'Contracten' },
      { nl: 'Schadevergoeding', fr: 'Dommages-intérêts', category: 'Contracten' },
      { nl: 'Aansprakelijkheid', fr: 'Responsabilité', category: 'Contracten' },
      { nl: 'Wanprestatie', fr: 'Inexécution', category: 'Contracten' },
      { nl: 'Ontbinding', fr: 'Résolution', category: 'Contracten' },
      { nl: 'Nietigheid', fr: 'Nullité', category: 'Contracten' },
      { nl: 'Ingebrekestelling', fr: 'Mise en demeure', category: 'Contracten' },
      { nl: 'Hoofdelijkheid', fr: 'Solidarité', category: 'Contracten' },
      { nl: 'Borgstelling', fr: 'Cautionnement', category: 'Contracten' },
      { nl: 'Hypotheek', fr: 'Hypothèque', category: 'Contracten' },
      { nl: 'Pand', fr: 'Gage', category: 'Contracten' },
      { nl: 'Verjaring', fr: 'Prescription', category: 'Contracten' },

      # Criminal law (15)
      { nl: 'Misdrijf', fr: 'Infraction', category: 'Strafrecht' },
      { nl: 'Overtreding', fr: 'Contravention', category: 'Strafrecht' },
      { nl: 'Wanbedrijf', fr: 'Délit', category: 'Strafrecht' },
      { nl: 'Misdaad', fr: 'Crime', category: 'Strafrecht' },
      { nl: 'Beklaagde', fr: 'Prévenu', category: 'Strafrecht' },
      { nl: 'Beschuldigde', fr: 'Accusé', category: 'Strafrecht' },
      { nl: 'Vrijspraak', fr: 'Acquittement', category: 'Strafrecht' },
      { nl: 'Veroordeling', fr: 'Condamnation', category: 'Strafrecht' },
      { nl: 'Gevangenisstraf', fr: 'Emprisonnement', category: 'Strafrecht' },
      { nl: 'Boete', fr: 'Amende', category: 'Strafrecht' },
      { nl: 'Voorhechtenis', fr: 'Détention préventive', category: 'Strafrecht' },
      { nl: 'Aanhoudingsbevel', fr: "Mandat d'arrêt", category: 'Strafrecht' },
      { nl: 'Voorwaardelijke invrijheidstelling', fr: 'Libération conditionnelle', category: 'Strafrecht' },
      { nl: 'Uitstel', fr: 'Sursis', category: 'Strafrecht' },
      { nl: 'Probatie', fr: 'Probation', category: 'Strafrecht' },

      # Family law (12)
      { nl: 'Echtscheiding', fr: 'Divorce', category: 'Familierecht' },
      { nl: 'Onderhoudsgeld', fr: 'Pension alimentaire', category: 'Familierecht' },
      { nl: 'Ouderlijk gezag', fr: 'Autorité parentale', category: 'Familierecht' },
      { nl: 'Voogdij', fr: 'Tutelle', category: 'Familierecht' },
      { nl: 'Erfenis', fr: 'Succession', category: 'Familierecht' },
      { nl: 'Testament', fr: 'Testament', category: 'Familierecht' },
      { nl: 'Huwelijkscontract', fr: 'Contrat de mariage', category: 'Familierecht' },
      { nl: 'Scheiding van tafel en bed', fr: 'Séparation de corps', category: 'Familierecht' },
      { nl: 'Wettelijke samenwoning', fr: 'Cohabitation légale', category: 'Familierecht' },
      { nl: 'Afstamming', fr: 'Filiation', category: 'Familierecht' },
      { nl: 'Adoptie', fr: 'Adoption', category: 'Familierecht' },
      { nl: 'Bewindvoering', fr: 'Administration provisoire', category: 'Familierecht' },

      # Labor law (12)
      { nl: 'Arbeidsovereenkomst', fr: 'Contrat de travail', category: 'Arbeidsrecht' },
      { nl: 'Ontslag', fr: 'Licenciement', category: 'Arbeidsrecht' },
      { nl: 'Opzeggingstermijn', fr: 'Préavis', category: 'Arbeidsrecht' },
      { nl: 'Werkgever', fr: 'Employeur', category: 'Arbeidsrecht' },
      { nl: 'Werknemer', fr: 'Travailleur', category: 'Arbeidsrecht' },
      { nl: 'Vakbond', fr: 'Syndicat', category: 'Arbeidsrecht' },
      { nl: 'Collectieve arbeidsovereenkomst', fr: 'Convention collective de travail', category: 'Arbeidsrecht' },
      { nl: 'Paritair comité', fr: 'Commission paritaire', category: 'Arbeidsrecht' },
      { nl: 'Dringende reden', fr: 'Motif grave', category: 'Arbeidsrecht' },
      { nl: 'Ontslagvergoeding', fr: 'Indemnité de licenciement', category: 'Arbeidsrecht' },
      { nl: 'Arbeidsongeval', fr: 'Accident du travail', category: 'Arbeidsrecht' },
      { nl: 'Beroepsziekte', fr: 'Maladie professionnelle', category: 'Arbeidsrecht' },

      # Commercial law (12)
      { nl: 'Vennootschap', fr: 'Société', category: 'Handelsrecht' },
      { nl: 'Faillissement', fr: 'Faillite', category: 'Handelsrecht' },
      { nl: 'Curator', fr: 'Curateur', category: 'Handelsrecht' },
      { nl: 'Aandeelhouder', fr: 'Actionnaire', category: 'Handelsrecht' },
      { nl: 'Bestuurder', fr: 'Administrateur', category: 'Handelsrecht' },
      { nl: 'Gerechtelijke reorganisatie', fr: 'Réorganisation judiciaire', category: 'Handelsrecht' },
      { nl: 'Schuldvordering', fr: 'Créance', category: 'Handelsrecht' },
      { nl: 'Bevoorrechte schuldeiser', fr: 'Créancier privilégié', category: 'Handelsrecht' },
      { nl: 'Handelsregister', fr: 'Registre du commerce', category: 'Handelsrecht' },
      { nl: 'Ondernemingsnummer', fr: "Numéro d'entreprise", category: 'Handelsrecht' },
      { nl: 'Jaarrekening', fr: 'Comptes annuels', category: 'Handelsrecht' },
      { nl: 'Commissaris', fr: 'Commissaire', category: 'Handelsrecht' },

      # Property law (10)
      { nl: 'Eigendom', fr: 'Propriété', category: 'Zakenrecht' },
      { nl: 'Huur', fr: 'Bail/Location', category: 'Zakenrecht' },
      { nl: 'Pacht', fr: 'Bail à ferme', category: 'Zakenrecht' },
      { nl: 'Erfdienstbaarheid', fr: 'Servitude', category: 'Zakenrecht' },
      { nl: 'Vruchtgebruik', fr: 'Usufruit', category: 'Zakenrecht' },
      { nl: 'Mede-eigendom', fr: 'Copropriété', category: 'Zakenrecht' },
      { nl: 'Kadaster', fr: 'Cadastre', category: 'Zakenrecht' },
      { nl: 'Stedenbouwkundige vergunning', fr: "Permis d'urbanisme", category: 'Zakenrecht' },
      { nl: 'Verkavelingsvergunning', fr: 'Permis de lotir', category: 'Zakenrecht' },
      { nl: 'Onteigening', fr: 'Expropriation', category: 'Zakenrecht' },

      # Constitutional/Administrative (12)
      { nl: 'Grondwet', fr: 'Constitution', category: 'Grondwet' },
      { nl: 'Wet', fr: 'Loi', category: 'Grondwet' },
      { nl: 'Decreet', fr: 'Décret', category: 'Grondwet' },
      { nl: 'Ordonnantie', fr: 'Ordonnance', category: 'Grondwet' },
      { nl: 'Koninklijk besluit', fr: 'Arrêté royal', category: 'Grondwet' },
      { nl: 'Ministerieel besluit', fr: 'Arrêté ministériel', category: 'Grondwet' },
      { nl: 'Omzendbrief', fr: 'Circulaire', category: 'Grondwet' },
      { nl: 'Staatsblad', fr: 'Moniteur belge', category: 'Grondwet' },
      { nl: 'Bevoegdheidsverdeling', fr: 'Répartition des compétences', category: 'Grondwet' },
      { nl: 'Prejudiciële vraag', fr: 'Question préjudicielle', category: 'Grondwet' },
      { nl: 'Nietigverklaring', fr: 'Annulation', category: 'Grondwet' },
      { nl: 'Schorsing', fr: 'Suspension', category: 'Grondwet' }
    ].freeze

    # Search glossary terms
    def search_glossary(query)
      return LEGAL_GLOSSARY if query.blank?

      query_down = query.downcase
      LEGAL_GLOSSARY.select do |term|
        term[:nl].downcase.include?(query_down) ||
          term[:fr].downcase.include?(query_down) ||
          term[:category]&.downcase&.include?(query_down)
      end
    end

    # === STATUTE OF LIMITATIONS (28 types from Praxis) ===

    STATUTE_OF_LIMITATIONS = {
      # Civil
      contractual: { years: 10, name_nl: 'Contractueel', name_fr: 'Contractuel', basis: 'Art. 2262bis BW', category: 'civil' },
      tort: { years: 5, name_nl: 'Onrechtmatige daad', name_fr: 'Responsabilité extracontractuelle', basis: 'Art. 2262bis §1, 2° BW', category: 'civil' },
      tort_personal: { years: 20, name_nl: 'Lichamelijke schade', name_fr: 'Dommages corporels', basis: 'Art. 2262bis §1, 2° BW', category: 'civil' },
      periodic: { years: 5, name_nl: 'Periodieke betalingen', name_fr: 'Paiements périodiques', basis: 'Art. 2277 BW', category: 'civil' },

      # Commercial
      commercial: { years: 10, name_nl: 'Handelszaken', name_fr: 'Affaires commerciales', basis: 'Art. 2262bis BW', category: 'commercial' },
      transport: { years: 1, name_nl: 'Vervoer (CMR)', name_fr: 'Transport (CMR)', basis: 'Art. 32 CMR-Verdrag', category: 'commercial' },
      sale_defect: { years: 1, name_nl: 'Verborgen gebreken', name_fr: 'Vices cachés', basis: 'Art. 1648 BW', category: 'commercial' },
      construction: { years: 10, name_nl: 'Bouwgebreken', name_fr: 'Vices de construction', basis: 'Art. 1792, 2270 BW', category: 'commercial' },

      # Labor
      labor: { years: 5, name_nl: 'Arbeidsovereenkomst', name_fr: 'Contrat de travail', basis: 'Art. 15 AOW', category: 'labor' },
      labor_accident: { years: 3, name_nl: 'Arbeidsongeval', name_fr: 'Accident du travail', basis: 'Art. 69 Arbeidsongevallenwet', category: 'labor' },
      social_security: { years: 3, name_nl: 'Sociale zekerheid', name_fr: 'Sécurité sociale', basis: 'Art. 174 RSZ-wet', category: 'labor' },

      # Tax
      tax_income: { years: 7, name_nl: 'Inkomstenbelasting', name_fr: 'Impôt sur le revenu', basis: 'Art. 354 WIB92', category: 'tax' },
      tax_vat: { years: 7, name_nl: 'BTW', name_fr: 'TVA', basis: 'Art. 81bis BTW-Wetboek', category: 'tax' },
      tax_registration: { years: 10, name_nl: 'Registratierechten', name_fr: 'Droits d\'enregistrement', basis: 'Art. 214 W.Reg.', category: 'tax' },
      tax_inheritance: { years: 10, name_nl: 'Successierechten', name_fr: 'Droits de succession', basis: 'Art. 137 W.Succ.', category: 'tax' },

      # Criminal
      criminal_violation: { years: 1, name_nl: 'Overtreding', name_fr: 'Contravention', basis: 'Art. 21 Sv.', category: 'criminal' },
      criminal: { years: 5, name_nl: 'Wanbedrijf', name_fr: 'Délit', basis: 'Art. 21 Sv.', category: 'criminal' },
      criminal_crime: { years: 10, name_nl: 'Misdaad (gecorr.)', name_fr: 'Crime (corr.)', basis: 'Art. 21 Sv.', category: 'criminal' },
      criminal_serious: { years: 15, name_nl: 'Misdaad (niet-gecorr.)', name_fr: 'Crime (non-corr.)', basis: 'Art. 21 Sv.', category: 'criminal' },
      criminal_sexual: { years: 15, name_nl: 'Seksuele misdrijven', name_fr: 'Infractions sexuelles', basis: 'Art. 21bis Sv.', category: 'criminal' },

      # Insurance
      insurance: { years: 3, name_nl: 'Verzekering', name_fr: 'Assurance', basis: 'Art. 88 Verzekeringswet', category: 'insurance' },
      insurance_life: { years: 30, name_nl: 'Levensverzekering', name_fr: 'Assurance vie', basis: 'Art. 88 Verzekeringswet', category: 'insurance' },

      # Property
      rent: { years: 5, name_nl: 'Huurvordering', name_fr: 'Créance locative', basis: 'Art. 2277 BW', category: 'property' },
      rent_damage: { years: 1, name_nl: 'Huurschade', name_fr: 'Dommages locatifs', basis: 'Art. 1732 BW', category: 'property' },

      # Administrative
      admin_damage: { years: 5, name_nl: 'Schade door overheid', name_fr: 'Dommages par l\'État', basis: 'Art. 100 RvS-wet', category: 'administrative' },
      urban: { years: 5, name_nl: 'Stedenbouwmisdrijf', name_fr: 'Infraction urbanistique', basis: 'Art. 6.1.1 VCRO', category: 'administrative' },

      # Family
      alimony: { years: 5, name_nl: 'Onderhoudsgeld', name_fr: 'Pension alimentaire', basis: 'Art. 2277 BW', category: 'family' },
      inheritance: { years: 30, name_nl: 'Erfenis (inkorting)', name_fr: 'Succession (réduction)', basis: 'Art. 921 BW', category: 'family' },

      # Medical
      medical: { years: 20, name_nl: 'Medische fout', name_fr: 'Faute médicale', basis: 'Art. 2262bis §1, 2° BW', category: 'medical' },
      product_liability: { years: 10, name_nl: 'Productaansprakelijkheid', name_fr: 'Responsabilité du fait des produits', basis: 'Art. 12 Productaansprakelijkheidswet', category: 'medical' }
    }.freeze

    LIMITATION_CATEGORIES = {
      civil: { name_nl: 'Burgerlijk', name_fr: 'Civil' },
      commercial: { name_nl: 'Handels', name_fr: 'Commercial' },
      labor: { name_nl: 'Arbeids', name_fr: 'Travail' },
      tax: { name_nl: 'Fiscaal', name_fr: 'Fiscal' },
      criminal: { name_nl: 'Strafrecht', name_fr: 'Pénal' },
      insurance: { name_nl: 'Verzekering', name_fr: 'Assurance' },
      property: { name_nl: 'Vastgoed', name_fr: 'Immobilier' },
      administrative: { name_nl: 'Administratief', name_fr: 'Administratif' },
      family: { name_nl: 'Familierecht', name_fr: 'Famille' },
      medical: { name_nl: 'Medisch', name_fr: 'Médical' }
    }.freeze

    # Calculate statute of limitations expiry
    def calculate_limitation(type_key, start_date)
      type_key = type_key.to_sym
      limitation = STATUTE_OF_LIMITATIONS[type_key]
      return nil unless limitation

      start_d = start_date.is_a?(Date) ? start_date : Date.parse(start_date.to_s)
      expiry = start_d + limitation[:years].years

      {
        type: type_key,
        name_nl: limitation[:name_nl],
        name_fr: limitation[:name_fr],
        years: limitation[:years],
        basis: limitation[:basis],
        category: limitation[:category],
        start_date: start_d,
        expiry_date: expiry,
        days_remaining: (expiry - Date.current).to_i,
        expired: expiry < Date.current
      }
    end

    # Get limitations by category
    def limitations_by_category
      STATUTE_OF_LIMITATIONS.group_by { |_k, v| v[:category] }.transform_values do |items|
        items.map { |k, v| v.merge(key: k) }
      end
    end

    # === SPECIAL DEADLINE TYPES (from Praxis) ===

    SPECIAL_DEADLINES = {
      # Standard
      verzet: { days: 30, name_nl: 'Verzet', name_fr: 'Opposition', basis: 'Art. 1048 Ger.W.' },
      hoger_beroep: { days: 30, name_nl: 'Hoger beroep', name_fr: 'Appel', basis: 'Art. 1051 Ger.W.' },
      cassatie: { days: 90, name_nl: 'Cassatieberoep', name_fr: 'Pourvoi en cassation', basis: 'Art. 1073 Ger.W.' },
      derdenverzet: { days: 30, name_nl: 'Derdenverzet', name_fr: 'Tierce opposition', basis: 'Art. 1122 Ger.W.' },

      # Special courts
      cassatie_assisen: { days: 15, name_nl: 'Cassatie (Assisen)', name_fr: 'Cassation (Assises)', basis: 'Art. 359 Sv.' },
      faillissement: { days: 15, name_nl: 'Beroep faillissement', name_fr: 'Appel faillite', basis: 'Art. 465 Faill.W.' },
      wco: { days: 8, name_nl: 'Beroep WCO', name_fr: 'Appel PRJ', basis: 'Art. 29 WCO' },
      jeugdzaken: { days: 15, name_nl: 'Beroep jeugdzaken', name_fr: 'Appel jeunesse', basis: 'Jeugdbeschermingswet' },

      # Administrative
      rvs_annulatie: { days: 60, name_nl: 'RvS nietigverklaring', name_fr: 'CE annulation', basis: 'Art. 14 RvS-wet' },
      rvs_schorsing: { days: 30, name_nl: 'RvS schorsing', name_fr: 'CE suspension', basis: 'Art. 17 RvS-wet' },
      rvs_udn: { days: 15, name_nl: 'RvS uiterst dringend', name_fr: 'CE extrême urgence', basis: 'Art. 17 §1 RvS-wet' },

      # Constitutional
      gwh_vernietiging: { days: 180, name_nl: 'GwH vernietiging', name_fr: 'CC annulation', basis: 'Art. 3 Bijz.Wet GwH' },
      gwh_memorie: { days: 45, name_nl: 'GwH memorie', name_fr: 'CC mémoire', basis: 'Art. 85 Bijz.Wet GwH' }
    }.freeze

    # Get all special deadlines grouped
    def special_deadlines_grouped
      {
        standard: SPECIAL_DEADLINES.slice(:verzet, :hoger_beroep, :cassatie, :derdenverzet),
        special: SPECIAL_DEADLINES.slice(:cassatie_assisen, :faillissement, :wco, :jeugdzaken),
        administrative: SPECIAL_DEADLINES.slice(:rvs_annulatie, :rvs_schorsing, :rvs_udn),
        constitutional: SPECIAL_DEADLINES.slice(:gwh_vernietiging, :gwh_memorie)
      }
    end

    # === CONCLUSION CALENDAR GENERATOR ===

    CONCLUSION_TEMPLATES = {
      standard: { name_nl: 'Standaard procedure', name_fr: 'Procédure standard', default_days: 30 },
      kort_geding: { name_nl: 'Kort geding', name_fr: 'Référé', default_days: 8 },
      arbeidsrechtbank: { name_nl: 'Arbeidsrechtbank', name_fr: 'Tribunal du travail', default_days: 30 },
      ondernemingsrechtbank: { name_nl: 'Ondernemingsrechtbank', name_fr: 'Tribunal de l\'entreprise', default_days: 30 },
      familierechtbank: { name_nl: 'Familierechtbank', name_fr: 'Tribunal de la famille', default_days: 21 },
      hof_van_beroep: { name_nl: 'Hof van Beroep', name_fr: 'Cour d\'appel', default_days: 45 }
    }.freeze

    # Generate conclusion calendar
    def generate_conclusion_calendar(intro_date:, rounds: 2, role: :plaintiff, procedure: :standard, days_per_round: nil)
      template = CONCLUSION_TEMPLATES[procedure.to_sym] || CONCLUSION_TEMPLATES[:standard]
      days = days_per_round || template[:default_days]
      intro = intro_date.is_a?(Date) ? intro_date : Date.parse(intro_date.to_s)

      calendar = []
      current_date = intro

      rounds.to_i.times do |round_num|
        round_label = round_num + 1

        if role.to_sym == :plaintiff
          # Plaintiff concludes first
          plaintiff_date = calculate_deadline(current_date, days)
          calendar << { round: round_label, party: :plaintiff, party_nl: 'Eiser', party_fr: 'Demandeur', date: plaintiff_date }
          defendant_date = calculate_deadline(plaintiff_date, days)
          calendar << { round: round_label, party: :defendant, party_nl: 'Verweerder', party_fr: 'Défendeur', date: defendant_date }
          current_date = defendant_date
        else
          # Defendant concludes first (e.g., in appeal where appellant is former defendant)
          defendant_date = calculate_deadline(current_date, days)
          calendar << { round: round_label, party: :defendant, party_nl: 'Verweerder', party_fr: 'Défendeur', date: defendant_date }
          plaintiff_date = calculate_deadline(defendant_date, days)
          calendar << { round: round_label, party: :plaintiff, party_nl: 'Eiser', party_fr: 'Demandeur', date: plaintiff_date }
          current_date = plaintiff_date
        end
      end

      # Add suggested pleading date (typically 2-4 weeks after last conclusion)
      pleading_date = calculate_deadline(current_date, 21)

      {
        intro_date: intro,
        procedure: procedure,
        procedure_name_nl: template[:name_nl],
        procedure_name_fr: template[:name_fr],
        rounds: rounds.to_i,
        days_per_round: days,
        role: role.to_sym,
        conclusions: calendar,
        suggested_pleading: pleading_date
      }
    end

    # === COURT FEES (ROLRECHTEN) ===

    COURT_FEES = {
      vredegerecht: {
        name_nl: 'Vredegerecht', name_fr: 'Justice de paix',
        rolrecht: 50, expeditie: 1.50,
        notes_nl: 'Zaken tot €5.000', notes_fr: 'Affaires jusqu\'à 5.000€'
      },
      rechtbank_eerste_aanleg: {
        name_nl: 'Rechtbank eerste aanleg', name_fr: 'Tribunal de première instance',
        rolrecht: 165, expeditie: 1.50,
        notes_nl: 'Burgerlijke en strafzaken', notes_fr: 'Affaires civiles et pénales'
      },
      arbeidsrechtbank: {
        name_nl: 'Arbeidsrechtbank', name_fr: 'Tribunal du travail',
        rolrecht: 50, expeditie: 1.50,
        notes_nl: 'Sociale zaken (vaak vrijgesteld)', notes_fr: 'Affaires sociales (souvent exonéré)'
      },
      ondernemingsrechtbank: {
        name_nl: 'Ondernemingsrechtbank', name_fr: 'Tribunal de l\'entreprise',
        rolrecht: 165, expeditie: 1.50,
        notes_nl: 'Handelszaken', notes_fr: 'Affaires commerciales'
      },
      familierechtbank: {
        name_nl: 'Familierechtbank', name_fr: 'Tribunal de la famille',
        rolrecht: 165, expeditie: 1.50,
        notes_nl: 'Familiezaken', notes_fr: 'Affaires familiales'
      },
      hof_van_beroep: {
        name_nl: 'Hof van Beroep', name_fr: 'Cour d\'appel',
        rolrecht: 400, expeditie: 1.50,
        notes_nl: 'Beroepszaken', notes_fr: 'Appels'
      },
      arbeidshof: {
        name_nl: 'Arbeidshof', name_fr: 'Cour du travail',
        rolrecht: 400, expeditie: 1.50,
        notes_nl: 'Beroep sociale zaken', notes_fr: 'Appels affaires sociales'
      },
      hof_van_cassatie: {
        name_nl: 'Hof van Cassatie', name_fr: 'Cour de cassation',
        rolrecht: 650, expeditie: 1.50,
        notes_nl: 'Cassatieberoep', notes_fr: 'Pourvoi en cassation'
      },
      raad_van_state: {
        name_nl: 'Raad van State', name_fr: 'Conseil d\'État',
        rolrecht: 200, expeditie: 0,
        notes_nl: 'Administratieve zaken', notes_fr: 'Affaires administratives'
      },
      grondwettelijk_hof: {
        name_nl: 'Grondwettelijk Hof', name_fr: 'Cour Constitutionnelle',
        rolrecht: 0, expeditie: 0,
        notes_nl: 'Geen rolrecht', notes_fr: 'Pas de droit de rôle'
      }
    }.freeze

    # === DOCUMENT CHECKLISTS ===

    DOCUMENT_CHECKLISTS = {
      litigation_civil: {
        name_nl: 'Burgerlijke procedure', name_fr: 'Procédure civile',
        documents: [
          { nl: 'Dagvaarding', fr: 'Citation', required: true },
          { nl: 'Inventaris van stukken', fr: 'Inventaire des pièces', required: true },
          { nl: 'Conclusies', fr: 'Conclusions', required: true },
          { nl: 'Syntheseconclusie', fr: 'Conclusions de synthèse', required: false },
          { nl: 'Bewijsstukken', fr: 'Pièces justificatives', required: true },
          { nl: 'Bewijs van betaling rolrecht', fr: 'Preuve de paiement droit de rôle', required: true },
          { nl: 'Machtiging advocaat', fr: 'Mandat d\'avocat', required: false }
        ]
      },
      litigation_labor: {
        name_nl: 'Arbeidsrechtelijke procedure', name_fr: 'Procédure du travail',
        documents: [
          { nl: 'Verzoekschrift', fr: 'Requête', required: true },
          { nl: 'Arbeidsovereenkomst', fr: 'Contrat de travail', required: true },
          { nl: 'Loonfiches', fr: 'Fiches de paie', required: true },
          { nl: 'C4-formulier', fr: 'Formulaire C4', required: false },
          { nl: 'Aangetekende brieven', fr: 'Lettres recommandées', required: false },
          { nl: 'Medische attesten', fr: 'Attestations médicales', required: false },
          { nl: 'Conclusies', fr: 'Conclusions', required: true }
        ]
      },
      litigation_family: {
        name_nl: 'Familieprocedure', name_fr: 'Procédure familiale',
        documents: [
          { nl: 'Verzoekschrift', fr: 'Requête', required: true },
          { nl: 'Huwelijksakte', fr: 'Acte de mariage', required: false },
          { nl: 'Geboorteaktes kinderen', fr: 'Actes de naissance enfants', required: false },
          { nl: 'Inkomensbewijzen', fr: 'Preuves de revenus', required: true },
          { nl: 'Bewijs van woonplaats', fr: 'Preuve de domicile', required: true },
          { nl: 'Inventaris roerende goederen', fr: 'Inventaire biens meubles', required: false },
          { nl: 'Eigendomsaktes', fr: 'Actes de propriété', required: false }
        ]
      },
      litigation_commercial: {
        name_nl: 'Handelsprocedure', name_fr: 'Procédure commerciale',
        documents: [
          { nl: 'Dagvaarding', fr: 'Citation', required: true },
          { nl: 'KBO-uittreksel', fr: 'Extrait BCE', required: true },
          { nl: 'Facturen', fr: 'Factures', required: true },
          { nl: 'Algemene voorwaarden', fr: 'Conditions générales', required: false },
          { nl: 'Contracten', fr: 'Contrats', required: false },
          { nl: 'Ingebrekestellingen', fr: 'Mises en demeure', required: true },
          { nl: 'Betalingsoverzicht', fr: 'Relevé de paiements', required: false }
        ]
      },
      litigation_criminal: {
        name_nl: 'Strafprocedure', name_fr: 'Procédure pénale',
        documents: [
          { nl: 'PV van verhoor', fr: 'PV d\'audition', required: true },
          { nl: 'Dagvaarding', fr: 'Citation', required: true },
          { nl: 'Burgerlijke partijstelling', fr: 'Constitution de partie civile', required: false },
          { nl: 'Medisch attest', fr: 'Attestation médicale', required: false },
          { nl: 'Getuigenverklaringen', fr: 'Témoignages', required: false },
          { nl: 'Strafregister', fr: 'Casier judiciaire', required: false }
        ]
      },
      appeal: {
        name_nl: 'Hoger beroep', name_fr: 'Appel',
        documents: [
          { nl: 'Beroepsakte', fr: 'Acte d\'appel', required: true },
          { nl: 'Vonnis eerste aanleg', fr: 'Jugement de première instance', required: true },
          { nl: 'Conclusies eerste aanleg', fr: 'Conclusions de première instance', required: true },
          { nl: 'Inventaris stukken', fr: 'Inventaire des pièces', required: true },
          { nl: 'Nieuwe bewijsstukken', fr: 'Nouvelles pièces', required: false },
          { nl: 'Beroepsconclusies', fr: 'Conclusions d\'appel', required: true }
        ]
      },
      bankruptcy: {
        name_nl: 'Faillissementsprocedure', name_fr: 'Procédure de faillite',
        documents: [
          { nl: 'Aangifte schuldvordering', fr: 'Déclaration de créance', required: true },
          { nl: 'Facturen/contracten', fr: 'Factures/contrats', required: true },
          { nl: 'Bewijs van schuldvordering', fr: 'Preuve de créance', required: true },
          { nl: 'Aangetekende ingebrekestelling', fr: 'Mise en demeure recommandée', required: false },
          { nl: 'Vonnis faillissement', fr: 'Jugement de faillite', required: true }
        ]
      }
    }.freeze

    # Check if date is in judicial vacation
    def in_judicial_vacation?(date)
      d = date.is_a?(Date) ? date : Date.parse(date.to_s)
      (d.month == 7) || (d.month == 8)
    end

    # Check if deadline needs judicial vacation extension
    def needs_vacation_extension?(start_date, deadline_date)
      start_d = start_date.is_a?(Date) ? start_date : Date.parse(start_date.to_s)
      deadline_d = deadline_date.is_a?(Date) ? deadline_date : Date.parse(deadline_date.to_s)

      in_judicial_vacation?(start_d) && in_judicial_vacation?(deadline_d)
    end

    # Get extended deadline for judicial vacation (Sept 15)
    def vacation_extended_deadline(year)
      Date.new(year, 9, 15)
    end
  end
end
