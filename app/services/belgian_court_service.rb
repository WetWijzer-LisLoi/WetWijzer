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

  class << self
    # Get court info by key
    def court_info(court_key)
      COURTS[court_key.to_sym]
    end

    # Get court name in specified locale
    def court_name(court_key, locale = :nl)
      info = court_info(court_key)
      return nil unless info

      locale == :nl ? info[:name_nl] : info[:name_fr]
    end

    # Get hierarchy level label
    def level_label(level, locale = :nl)
      labels = {
        1 => { nl: 'Hoogste Rechtscolleges', fr: 'Cours Supr\u00eames' },
        2 => { nl: 'Hoven', fr: "Cours d'appel" },
        3 => { nl: 'Rechtbanken', fr: 'Tribunaux' },
        4 => { nl: 'Lagere Rechtbanken', fr: 'Juridictions inf\u00e9rieures' }
      }

      labels.dig(level, locale) || "Level #{level}"
    end
  end
end
