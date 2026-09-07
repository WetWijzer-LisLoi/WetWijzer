# frozen_string_literal: true

# The only source categories a chatbot client may select, and the one place
# that decides what a selection means.
#
# WHY THIS EXISTS. The API controller filtered the request array when deriving
# the single effective `source`, but then built `@selected_sources` from the
# RAW array with `map(&:to_sym)`. That raw array reached three places it had no
# business reaching:
#
#   - `sources_list` on the analytics row, a table that is content-free by
#     contract and stores no client text anywhere else;
#   - the orchestrator's per-request performance log line, which joins the
#     source list verbatim;
#   - the admin dashboard, which renders the stored value (escaped, so this was
#     a data-hygiene break rather than an injection one).
#
# Retrieval itself was never fooled: the search fan-out asks
# `sources.include?(:legislation)` and friends, so an unrecognised symbol
# simply selects nothing. That is exactly why this survived - nothing broke,
# arbitrary client strings just quietly crossed a privacy boundary.
#
# `fisconet` and `regional` are deliberately absent: they are chosen by the
# server from the question, never by the client.
module ChatbotSourceCategories
  ALL = %w[legislation jurisprudence parliamentary].freeze

  # Bounds applied BEFORE any per-item work, so an oversized array or a
  # megabyte-long entry costs nothing to reject.
  MAX_ENTRIES = 12
  MAX_ENTRY_LENGTH = 32

  # Legacy single-parameter values that are not categories themselves.
  ALL_SOURCES = :all
  CUSTOM = :custom

  module_function

  def supported?(value)
    ALL.include?(normalize(value))
  end

  # A request array reduced to canonical category codes. Invalid entries are
  # DISCARDED rather than rejected with 400: that is what the controller
  # already did when deriving the effective source, and changing it would
  # break clients that send an empty or partly stale selection.
  def canonical(raw)
    return [] unless raw.is_a?(Array)

    values = raw.first(MAX_ENTRIES)
                .filter_map { |value| normalize(value) }
                .select { |value| ALL.include?(value) }
                .uniq
    values.presence || [ALL.first]
  end

  def canonical_symbols(raw)
    canonical(raw).map(&:to_sym)
  end

  # What the legacy single `source` parameter selects. `:all` searched NOTHING
  # before this existed: it was passed through as `[:all]`, and every fan-out
  # check asks for a specific category.
  def expand_legacy(source)
    case source&.to_sym
    when ALL_SOURCES then ALL.map(&:to_sym)
    when CUSTOM then [ALL.first.to_sym]
    else
      supported?(source) ? [source.to_sym] : [ALL.first.to_sym]
    end
  end

  # The legacy single `source` parameter, validated BEFORE it becomes a symbol.
  # `:all` and `:custom` are accepted here because the controller's own
  # allowlist accepts them and they are not categories; anything else that is
  # not a category falls through to the controller's 400.
  LEGACY_EXTRAS = %i[all custom].freeze

  def legacy_symbol(value)
    # ABSENT and INVALID are different answers, and conflating them is how
    # tightening normalize quietly widened this. Once normalize started
    # returning nil for a padded prefix, an oversized string and a non-string,
    # every one of those fell into the "nothing was sent, use the default"
    # branch - so an invalid source silently became legislation instead of
    # reaching the controller's 400.
    return :legislation if absent?(value)

    normalized = normalize(value)
    return :unsupported_source if normalized.blank?
    return normalized.to_sym if ALL.include?(normalized)
    return normalized.to_sym if LEGACY_EXTRAS.map(&:to_s).include?(normalized)

    # Deliberately unknown: the controller rejects it with 400 rather than this
    # module guessing, and the value never became a symbol on the way there.
    :unsupported_source
  end

  # Nothing was sent. A value of the wrong TYPE is not nothing - it is a client
  # sending something this endpoint does not accept.
  def absent?(value)
    return true if value.nil?
    return value.to_s.strip.empty? if value.is_a?(String) || value.is_a?(Symbol)

    false
  end

  # `all` is a real, accepted value: the controller's own allowlist takes it and
  # expand_legacy turns it into every category. It was being bucketed as
  # Unknown/legacy, which told an operator that a legitimate selection was
  # corrupt data.
  ALL_SOURCES_LABEL = 'Alle bronnen'
  CUSTOM_LABEL = 'Gecombineerd'

  # The key a label table should be looked up by - the CANONICAL value, never
  # the raw one. A caller that validates one string and renders another is how
  # a padded prefix carried its tail onto the page.
  def display_key(value)
    normalize(value)
  end

  # What may be shown for a stored source when no label table matches.
  def display_label(value)
    normalized = normalize(value)
    # A value that was stored but cannot be normalized is not the same as no
    # value at all: it is something unrecognised, and saying "Onbekend"
    # (nothing recorded) would hide that a row carries a legacy value.
    return value.to_s.strip.present? ? UNKNOWN_LABEL : 'Onbekend' if normalized.blank?
    return ALL_SOURCES_LABEL if normalized == ALL_SOURCES.to_s
    return CUSTOM_LABEL if normalized == CUSTOM.to_s
    return normalized.capitalize if ALL.include?(normalized)

    UNKNOWN_LABEL
  end

  # What an account export may say a row's source was. Rows written before the
  # allowlist was enforced can hold anything, and an export is the one place
  # that hands stored values straight back to a person.
  def exported_source(value)
    # Blank is nil - there was no source. Anything else that will not normalize
    # is still SOMETHING: a legacy value, or one long enough that it cannot be
    # a category. Exporting nil for it would tell the account holder no source
    # was recorded, which is not what their row says.
    return nil if value.to_s.strip.empty?

    normalized = normalize(value)
    if normalized.present? && (ALL.include?(normalized) || LEGACY_EXTRAS.map(&:to_s).include?(normalized))
      return normalized
    end

    UNKNOWN_LABEL
  end

  # The label table used by the admin dashboard, extended with the two values
  # that are legitimate but are not categories.
  def label_for(value, short_labels)
    short_labels[display_key(value)] || display_label(value)
  end

  # Defence in depth at the writer: even if a future caller assigns
  # @selected_sources from raw input again, only category codes can persist.
  def storage_value(values)
    Array(values).filter_map { |value| normalize(value) }
                 .select { |value| ALL.include?(value) }
                 .uniq
                 .presence
                 &.join(',')
  end

  # What the admin dashboard may print for a stored value. Rows written before
  # this module existed can hold anything, so an unrecognised code becomes one
  # neutral bucket instead of echoing client text back into the page.
  UNKNOWN_LABEL = 'Unknown/legacy'

  def labels(stored_value, short_labels)
    # Entries that cannot be normalized are BUCKETED, not dropped. Dropping
    # them made a row holding only an unrecognisable value render as nothing at
    # all, which reads as "no source" rather than "a source nobody recognises".
    entries = stored_value.to_s.split(',').map(&:strip).reject(&:empty?)
    return [] if entries.empty?

    entries.map { |raw| label_for(raw, short_labels) }.uniq
  end

  # Strip and downcase BEFORE bounding the length, then reject anything still
  # too long to be a category.
  #
  # The other order was exploitable. Truncating first turned
  # "legislation" + 21 spaces + "SECRET-ECLI-TAIL" into "legislation" plus
  # padding, which stripped to exactly the supported category - so a value
  # carrying an arbitrary tail was declared valid, and the admin page then
  # printed the value it had been handed rather than the one that was
  # validated. Padding is not whitespace to be forgiven; it is a prefix
  # collision.
  #
  # The raw read is still bounded first, so a megabyte-long value costs a slice
  # rather than a full strip and downcase.
  RAW_READ_LIMIT = 512

  def normalize(value)
    return nil unless value.is_a?(String) || value.is_a?(Symbol)

    raw = value.to_s
    return nil if raw.length > RAW_READ_LIMIT

    normalized = raw.strip.downcase
    return nil if normalized.length > MAX_ENTRY_LENGTH

    normalized.presence
  end
end
