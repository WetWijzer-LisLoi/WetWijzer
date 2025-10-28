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
  # Note: 'relevance' is handled specially in apply_sort - it uses token match scoring
  SORT_OPTIONS = {
    'relevance' => nil, # Special handling - scored by token matches, then by date
    'date_desc' => 'date DESC',
    'date_asc' => 'date ASC',
    'title_asc' => 'title ASC',
    'title_desc' => 'title DESC'
  }.freeze

  # Default sort option if none or invalid sort is provided
  # Note: 'relevance' is only used when there's a search query, otherwise 'date_desc'
  DEFAULT_SORT = 'date_desc'
end
