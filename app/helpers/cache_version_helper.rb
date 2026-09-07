# frozen_string_literal: true

require 'digest'

# Cache-key components that move when the CONTENT moves.
#
# Every long-lived fragment in the laws views was keyed on a row COUNT: the
# number of articles, of exdecs, the bare id of a contents row. A count is not a
# content signal. The corpus updater rewrites a law's articles wholesale on
# every consolidation (an amendment rewrites Art. 5, nothing is added or
# removed), it upserts the contents row in place, and every hand repair goes in
# as raw SQL. None of that moves a count, so a 7-day fragment kept serving the
# old text while the database was already correct. That is what happened with
# the fisconet back-to-top cleanup on 2026-08-15, and the laws views had the
# same blind spot.
#
# Timestamps are no better here: the updater does not stamp contents.updated_at
# (SQLAlchemy's server_onupdate is only a marker and there is no trigger), and
# raw SQL touches nothing. The one signal that is honest under every write path
# is a digest of what the block actually renders. The controllers materialise
# those rows before the view runs, hit or miss, so hashing them costs no query
# and, measured on production, at most ~25 ms for the 28 laws over 1 MB and
# microseconds for the rest.
#
# Three signals, for three situations:
#   rows_cache_version   - rows the request has already loaded (free, exact)
#   text_cache_version   - a string the request has already loaded (free, exact)
#   laws_db_version /    - data the block reads from OTHER laws that are not
#   laws_links_version     loaded on a hit; a cheap stamp that moves when the
#                          corpus is written, at the cost of a re-render then
#
# Accepted residual: the TITLES of laws referenced from inside an article
# (link tooltips, the label of an abolished-marker link) come from other
# legislation rows the request never loads. The only global signal for them
# would re-render every law daily, so they may lag up to the 7-day TTL. That
# is a tooltip, not the legal text.
module CacheVersionHelper
  # Callable both as a mixed-in view helper (implicit receiver from ERB) and
  # as CacheVersionHelper.x from controllers and rake tasks.

  module_function

  # Unit separators, so "ab" + "c" cannot hash like "a" + "bc".
  FIELD_SEP = "\x1f"
  ROW_SEP = "\x1e"
  BOOKKEEPING_COLUMNS = %w[created_at updated_at].freeze

  # Digest over rows in their loaded order. ActiveRecord records contribute
  # every column except the bookkeeping timestamps (so a column that starts
  # being rendered later cannot fall outside the key); Hash rows contribute
  # their values. Truncated to 80 bits, which is more than a cache key needs.
  #
  # created_at/updated_at are skipped on purpose: they are never rendered, and
  # the daily merge restamps updated_at on every matched row whether or not
  # the text changed, which would re-render every re-merged law once a day
  # for a week with byte-identical output.
  #
  # Columns are read with _read_attribute rather than through #attributes:
  # measured on the 4,639-article code, building an attributes Hash per row
  # cost 114 ms per request, reading the columns directly 29 ms. The hashing
  # itself is a few ms; the per-row Ruby work is what has to stay small.
  def rows_cache_version(rows)
    digest = Digest::SHA1.new
    rows = rows.to_a
    first = rows.first
    if first.respond_to?(:_read_attribute) && first.class.respond_to?(:column_names)
      columns = first.class.column_names - BOOKKEEPING_COLUMNS
      rows.each do |row|
        columns.each { |c| digest << row._read_attribute(c).to_s << FIELD_SEP }
        digest << ROW_SEP
      end
    else
      rows.each do |row|
        values = row.respond_to?(:attributes) ? row.attributes.values : Hash(row).values
        values.each { |v| digest << v.to_s << FIELD_SEP }
        digest << ROW_SEP
      end
    end
    digest.hexdigest[0, 20]
  end

  def text_cache_version(*strings)
    Digest::SHA1.hexdigest(strings.join(ROW_SEP))[0, 20]
  end

  # Mtime of the MAIN file of the laws database. Deliberately not its -wal:
  # laws.prod.sqlite3 is the primary database and also takes app writes
  # (sample question clicks, takedown requests, document lookups), so the
  # WAL's mtime churns with user activity, and the daily merge writes the WAL
  # for hours inside one transaction while readers still see the old data.
  # The main file moves when the merge and the backups checkpoint (2-3 times
  # a day) and otherwise only once 1000 WAL pages have accumulated - so a
  # small hand repair from the sqlite3 CLI does NOT move it while Puma holds
  # its connections open. A repair that needs to reach the exdec mapping or
  # the popular-laws panel immediately should end with
  # `PRAGMA wal_checkpoint(PASSIVE)`; article text itself never depends on
  # this stamp, the row digests catch it at once.
  #
  # Use this only for data a block reads that the request has NOT loaded; for
  # loaded rows the digests above are exact and never force a needless render.
  def laws_db_version
    path = ActiveRecord::Base.connection_db_config.database.to_s
    path = Rails.root.join(path).to_s unless path.start_with?('/')
    File.mtime(path).to_i
  rescue StandardError
    0
  end

  # Stamp for the document-number links woven into article text. Those come
  # from document_number_lookups, which the weekly job rewrites, and the rows
  # are not loaded on a fragment hit. COUNT + MAX(updated_at) moves exactly
  # when the job adds or re-points a lookup (it stamps updated_at only on
  # changed rows). Memoised for a minute so the aggregate runs once per minute
  # per host, not once per request.
  def laws_links_version
    Rails.cache.fetch('cache_version/laws_links', expires_in: 60.seconds) do
      row = DocumentNumberLookup.pick(Arel.sql('COUNT(*), MAX(updated_at)'))
      "#{row&.first}-#{row&.last}"
    end
  rescue StandardError
    '0'
  end

  # Mtime stamp over arbitrary files (other corpora, YAML data files). Missing
  # files contribute 0 rather than raising: a missing corpus is already handled
  # by the block that reads it, and must not take the page down through its key.
  def files_version(*paths)
    paths.flatten.map do |p|
      File.mtime(p.to_s).to_i
    rescue StandardError
      0
    end.join('-')
  end

  # The helper files that turn article rows into the cached HTML: reference
  # linking, abolished markers, section headings, permalinks, exdec sections,
  # tax cross-links. Rails folds the TEMPLATE digest into a fragment key but
  # knows nothing about helpers, and the file store survives deploys, so a fix
  # in one of these files used to reach readers only when someone remembered
  # to bump a version literal in the view - twelve deploys touched them in the
  # last sixty days. This is a digest of their contents, computed once per
  # process, so a deploy that changes any of them re-renders on the next
  # request. Deliberately a fixed list rather than all of app/: a coarser
  # signal would cold-start every law page on deploys that cannot affect them.
  RENDER_CODE_FILES = %w[
    app/helpers/references_helper.rb
    app/helpers/references/document_linking.rb
    app/helpers/references/tax_cross_linking.rb
    app/helpers/application_helper.rb
    app/helpers/laws_helper.rb
    app/helpers/article_references_helper.rb
  ].freeze

  # The home page's popular-laws and concordance block renders through its own
  # helper, which is NOT in the list above on purpose: it has nothing to do with
  # article rendering, and putting it there would cold-start every law page
  # whenever a concordance cell changed. It needs the same protection though -
  # on 2026-09-06 a fix that made every concordance reference an unbreakable
  # token deployed green and never reached a reader, because that block's key
  # stamps the databases and the YAML files but knew nothing about the helper.
  # The two earlier fixes that day only LOOKED like they busted the cache: they
  # happened to touch the view as well, and Rails folds the template digest in.
  POPULAR_LAWS_CODE_FILES = %w[
    app/helpers/popular_laws_helper.rb
  ].freeze

  # Memoised on the module, not on `self`: as a mixed-in view helper `self` is
  # a fresh view instance per request, and the memo would be recomputed each
  # time.
  class << self
    attr_accessor :render_code_version_memo, :popular_laws_code_version_memo
  end

  def render_code_version
    CacheVersionHelper.render_code_version_memo ||= compute_code_version(RENDER_CODE_FILES)
  end

  def popular_laws_code_version
    CacheVersionHelper.popular_laws_code_version_memo ||=
      compute_code_version(POPULAR_LAWS_CODE_FILES)
  end

  def compute_code_version(files)
    digest = Digest::SHA1.new
    files.each do |rel|
      path = Rails.root.join(rel)
      digest << rel << FIELD_SEP << (File.exist?(path) ? File.binread(path) : '') << ROW_SEP
    end
    digest.hexdigest[0, 12]
  end
end
