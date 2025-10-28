# frozen_string_literal: true

# Provides constants used by LawSearchService
module LawSearchConstants
  # Maps document types to their corresponding database IDs for each language
  TYPE_MAPPING = {
    nl: {
      constitution: '1', # Grondwet
      law: '2',          # Wet
      decree: '3',       # Decreet
      ordinance: '4',    # Ordonnantie
      decision: '5',     # Besluit
      misc: '11'         # Varia (miscellaneous)
    }.freeze,
    fr: {
      constitution: '6', # Constitution
      law: '7',          # Loi
      decree: '8',       # Décret
      ordinance: '9',    # Ordonnance
      decision: '10',    # Arrêté
      misc: '11'         # Divers (miscellaneous)
    }.freeze
  }.freeze

  # Available sort options with their corresponding SQL order clauses
  SORT_OPTIONS = {
    'title_asc' => 'title ASC',
    'title_desc' => 'title DESC',
    'date_asc' => 'date ASC',
    'date_desc' => 'date DESC',
    'year_asc' => 'year ASC',
    'year_desc' => 'year DESC'
  }.freeze

  # Default sort option if none or invalid sort is provided
  DEFAULT_SORT = 'date_desc'
end
