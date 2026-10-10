# frozen_string_literal: true

# == GermanTextProvenance
#
# What a German text (legislation.language_id 3) is and who published it.
# The German lane (lib/wetwijzer_updater/german_lane.py, updater v0.894) stores
# a text only after the provenance test of
# docs/ops/german-corpus-plan-2026-09-27.md section 2.3, and records the
# outcome in legislation.source_method as one of the eight values below.
# Section 5 of the plan gives the label the German site shows for each one
# (config/locales/de.yml, german_text.labels).
#
# The German site serves a German row only when its source_method is one of
# these values (Legislation.german_with_provenance), so no German page can be
# shown without saying whether its text is an official translation, an
# unofficial coordination or consolidation, or an original, and who
# published it. A row without one is treated as absent: the French text is
# shown instead, labelled as French.
module GermanTextProvenance
  # source_method => the de.yml label key under german_text.labels
  LABEL_KEYS = {
    'staatsblatt_de:official_translation' => :official_translation,
    'staatsblatt_de:official_translation_extracts' => :official_translation_extracts,
    'staatsblatt_de:unofficial_coordination' => :unofficial_coordination,
    'staatsblatt_de:unofficial_coordination_extracts' => :unofficial_coordination_extracts,
    'staatsblatt_de:original' => :original,
    # A decree of the German-speaking Community or of its government in its
    # original German publication in the Staatsblatt (the lane's
    # staatsblatt_dg source, todo 7.4 (b)): the official German original,
    # of which the Dutch and French texts are translations (law of 31
    # December 1983, NUMAC 1984023027, art. 47 and 53).
    'staatsblatt_dg_original' => :dg_original,
    'zddu:unofficial_consolidation' => :zddu_consolidation,
    'dg_ministry:coordinated_nonbinding' => :dg_coordinated
  }.freeze

  SOURCE_METHODS = LABEL_KEYS.keys.freeze

  # The part of source_method before the colon names the publisher, the
  # de.yml key under german_text.sources; a value without a colon names it
  # here.
  SOURCE_BY_METHOD = {
    'staatsblatt_dg_original' => 'staatsblatt_de'
  }.freeze

  SOURCES = %w[staatsblatt_de zddu dg_ministry].freeze

  # The source methods whose German text IS the law rather than a
  # translation, coordination or consolidation of it: the binding originals.
  # The German index embeds them as themselves, and the German site's chatbot
  # may quote and cite them as German law (owner decision 2026-09-28). Every
  # other value is a translation or an unofficial text and is never evidence.
  #
  # The same list lives in lib/wetwijzer_updater/german_lane.py
  # (ORIGINAL_METHODS, the source of truth) and, vendored because the
  # embeddings venv cannot import german_lane.py, in
  # lib/wetwijzer_updater/german_article_map.py
  # (BINDING_ORIGINAL_SOURCE_METHODS). test/models/german_text_provenance_binding_test.rb
  # parses both files and fails when the three drift apart.
  BINDING_ORIGINAL_SOURCE_METHODS = %w[staatsblatt_de:original staatsblatt_dg_original].freeze

  module_function

  # @param source_method [String, nil]
  # @return [Boolean] true only for a binding German original
  def binding_original?(source_method)
    BINDING_ORIGINAL_SOURCE_METHODS.include?(source_method.to_s)
  end

  # @param source_method [String, nil]
  # @return [Boolean] true for one of the eight values the lane writes
  def known?(source_method)
    LABEL_KEYS.key?(source_method.to_s)
  end

  # @param source_method [String, nil]
  # @return [Symbol, nil] the label key, nil for an unknown value
  def label_key(source_method)
    LABEL_KEYS[source_method.to_s]
  end

  # @param source_method [String, nil]
  # @return [String, nil] 'staatsblatt_de', 'zddu' or 'dg_ministry'
  def source(source_method)
    return nil unless known?(source_method)

    SOURCE_BY_METHOD.fetch(source_method.to_s) { source_method.to_s.split(':', 2).first }
  end
end
