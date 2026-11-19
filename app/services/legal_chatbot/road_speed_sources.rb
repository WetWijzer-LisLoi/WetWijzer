# frozen_string_literal: true

module LegalChatbot
  # The three regional versions of the traffic code's speed article (Art. 11
  # of the Royal Decree of 1 December 1975), fetched by exact title for a road
  # speed question (FocusedTopicSourceScope.road_speed_question?).
  #
  # Live v1.1.70 (Sol 2026-11-19 07:43:14Z): "Wat is de maximumsnelheid in de
  # bebouwde kom?" showed the general, Flemish and Walloon versions of Art. 11
  # but not the Brussels one, so the answer gave Brussels the 50 km/h of the
  # others. The Brussels version says 30 ("beperkt tot [2 30]2 km per uur").
  # Ordinary retrieval may rank any of the near-identical versions out; this
  # group does not depend on it.
  #
  # Each entry is [numac, { language_id => number }, region]: the NL and FR
  # titles of a regional row differ (11_BRUSSELS_HOOFDSTEDELIJK_GEWEST,
  # 11_REGION_DE_BRUXELLES-CAPITALE). A named region gets its own row, no
  # region all three.
  module RoadSpeedSources
    TRAFFIC_CODE = '1975120109'
    REGION_TARGETS = {
      'vlaamse_codex' => [TRAFFIC_CODE, { 1 => '11_VLAAMS_GEWEST', 2 => '11_REGION_FLAMANDE' }],
      'wallex' => [TRAFFIC_CODE, { 1 => '11_WAALS_GEWEST', 2 => '11_REGION_WALLONNE' }],
      'brussels' => [TRAFFIC_CODE, { 1 => '11_BRUSSELS_HOOFDSTEDELIJK_GEWEST', 2 => '11_REGION_DE_BRUXELLES-CAPITALE' }]
    }.freeze

    # The deployment readiness contract of the group, in GeneralNoiseScope's
    # form: each row in ITS language with ITS title, and the built-up-area
    # rule its text must still hold, so a Brussels row that lost its 30 fails
    # the gate. lib/wetwijzer_updater/import_missing_popular_laws.py
    # (load_language_article_targets) reads this block literally.
    READINESS_TARGETS = [
      ['1975120109', 1, '11_VLAAMS_GEWEST', 'Binnen de bebouwde kommen is de snelheid beperkt tot 50 km per uur'],
      ['1975120109', 2, '11_REGION_FLAMANDE', 'Dans les agglomérations, la vitesse est limitée à 50 km'],
      ['1975120109', 1, '11_WAALS_GEWEST', 'Binnen de bebouwde kommen is de snelheid beperkt tot 50 km per uur'],
      ['1975120109', 2, '11_REGION_WALLONNE', 'Dans les agglomérations, la vitesse est limitée à 50 km'],
      ['1975120109', 1, '11_BRUSSELS_HOOFDSTEDELIJK_GEWEST', 'Binnen de bebouwde kommen is de snelheid beperkt tot [2 30]2 km per uur'],
      ['1975120109', 2, '11_REGION_DE_BRUXELLES-CAPITALE', 'Dans les agglomérations, la vitesse est limitée à [2 30]2 km']
    ].freeze

    # Every [numac, number] pair, both languages, for
    # LegislationSearch::GOVERNING_GROUP_TARGETS.
    GOVERNING_PAIRS = REGION_TARGETS.values.flat_map { |numac, numbers| numbers.values.map { |number| [numac, number] } }
                                    .uniq.freeze

    # Room beside the group for the sources a road speed question keeps
    # (the general Art. 11, a named zone or road), as GeneralNoiseScope does.
    EXTRA_ROOM = 2

    module_function

    def asked?(question)
      FocusedTopicSourceScope.road_speed_question?(question)
    end

    def named_regions(question)
      RegionalSearch.named_regions(question) & RegionalSearch::REGION_SOURCES
    end

    # [numac, number, region name] for this question and search language.
    def targets(question, language_id)
      return [] unless asked?(question)

      language = language_id == 2 ? 'fr' : 'nl'
      regions = named_regions(question).presence || RegionalSearch::REGION_SOURCES
      regions.map do |region|
        numac, numbers = REGION_TARGETS.fetch(region)
        [numac, numbers.fetch(language_id == 2 ? 2 : 1), GeneralNoiseScope::REGION_NAMES.fetch(language).fetch(region)]
      end
    end

    def pack_size(question)
      group = targets(question, 1).length
      group.positive? ? group + EXTRA_ROOM : 0
    end
  end
end
