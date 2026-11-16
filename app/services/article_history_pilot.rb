# frozen_string_literal: true

# Reads the article-history pilot database built by lib/wetwijzer_updater/article_history_pilot.py from Justel's
# archived versions (Sol 2026-11-16 11:23:30Z: Judicial Code part I, articles 18, 19, 20 and 42, Dutch and French).
#
# A local pilot: never in production, and only when the database file is present. Each distinct wording is stored
# once (texts); each period points at a wording or is an explicit gap (status 'unknown'). A period's start is the day
# Justel's listing gives as the previous wording's end (exclusive), or unknown; its end is the day before the next
# wording's listed start, or open. Publication (of the amending act), effective dates and capture time are kept
# apart, and every period links the exact Justel page that shows its wording.
class ArticleHistoryPilot
  Version = Struct.new(:id, :status, :body, :valid_from, :valid_from_basis, :valid_until, :valid_until_basis,
                       :inline_effective, :start_check, :introduced_by, :published, :first_version, :last_version,
                       :source_url, :captured_at, :note, :text_id, :change_kind, :not_before, keyword_init: true) do
    def text? = status == 'text'
    # The sources give two entry-into-force days for the wording (note names both): not in force as a fact.
    def disputed? = status == 'disputed'
    def current? = valid_until_basis == 'open'
    def start_known? = valid_from.present?

    # True when the period covers the ISO day. A period with an unknown start covers the days up to its end, but not
    # before its not_before bound (the previous wording's known start, or a regional variant's first day).
    def covers?(day)
      lower = valid_from || not_before
      (lower.nil? || lower <= day) && (valid_until.nil? || valid_until >= day)
    end
  end

  def self.db_path
    ENV.fetch('ARTICLE_HISTORY_PILOT_DB') { Rails.root.join('storage', 'article_history_pilot.sqlite3').to_s }
  end

  def self.available?
    !Rails.env.production? && File.file?(db_path)
  end

  def initialize(path = self.class.db_path)
    @db = SQLite3::Database.new(path, readonly: true)
    @db.results_as_hash = true
  end

  # A full page of the law: an archived version (version) or the current page (version nil). The page IS the law
  # from window_from to window_until (inclusive), as the listing establishes it; a page whose window_from falls after
  # its window_until (a later-published act applies earlier) is the law on no day. window_from also orders pages.
  Snapshot = Struct.new(:id, :version, :url, :captured_at, :act, :act_date, :published, :window_from, :window_until,
                        keyword_init: true) do
    def current? = version.nil?
    def label = current? ? 'current' : format('%03d', version)
    def exact? = window_from.present? && (window_until.nil? || window_from <= window_until)

    def covers?(day)
      exact? && window_from <= day && (window_until.nil? || window_until >= day)
    end
  end

  # One article key on one day: the period that applies (version_on), every period covering the day, and whether
  # those disagree on the text (Justel's notes aside), which happens only where a bound is unknown.
  Resolution = Struct.new(:version, :candidates, keyword_init: true) do
    def ambiguous?
      candidates.select(&:text?).map { |candidate| ArticleHistoryPilot.plain(candidate.body) }.uniq.size > 1
    end
  end

  def self.plain(body)
    body.to_s.gsub(/<[^<>]*>/, '').sub(/\A\s*Art\.\s*/, 'Art. ').gsub(/\s+/, ' ').strip
  end
  Item = Struct.new(:key, :kind, :body, :text_id, keyword_init: true) do
    def heading? = kind == 'heading'
  end
  # The article keys' variant suffixes, as lib/wetwijzer_updater/article_history_pilot.py splits them.
  VARIANT_SUFFIX = /[_ ](WAALS_GEWEST|VLAAMS_GEWEST|BRUSSELS_HOOFDSTEDELIJK_GEWEST|REGION_WALLONNE|REGION_FLAMANDE|
                         REGION_DE_BRUXELLES-CAPITALE|REGION_BRUXELLES-CAPITALE|TOEKOMSTIG\ RECHT|DROIT\ FUTUR)\z/x

  def self.split_variant(key)
    match = VARIANT_SUFFIX.match(key.to_s)
    match ? [key[0...match.begin(0)], match[1]] : [key.to_s, '']
  end

  def close = @db.close

  def covers?(numac)
    @db.get_first_value('SELECT 1 FROM sources WHERE numac = ? LIMIT 1', [numac]).present?
  end

  # The full pages, oldest archived version first and the current page last.
  def snapshots(numac, language)
    @db.execute('SELECT * FROM sources WHERE numac = ? AND language = ? AND full = 1 ' \
                'ORDER BY version IS NULL, version', [numac, language]).map do |row|
      Snapshot.new(id: row['id'], version: row['version'], url: row['url'], captured_at: row['captured_at'],
                   act: row['act'], act_date: row['act_date'], published: row['published'],
                   window_from: row['window_from'], window_until: row['window_until'])
    end
  end

  # The full page that IS the law on the ISO day, or nil when no saved page is.
  def snapshot_on(numac, language, day)
    snapshots(numac, language).find { |snapshot| snapshot.covers?(day) }
  end

  # The page that gives the archive view of a day its order and headings: the exact page when there is one, else
  # the page whose own acts all apply latest on or before the day. nil before the first such page.
  def structure_on(numac, language, day)
    snapshot_on(numac, language, day) ||
      snapshots(numac, language).select { |snapshot| snapshot.window_from.present? && snapshot.window_from <= day }
                                .max_by { |snapshot| [snapshot.window_from, snapshot.version || (10**6)] }
  end

  # The article keys ('Art.42', 'Art.42_WAALS_GEWEST') with a period covering the day.
  def keys_on(numac, language, day)
    rows = @db.execute(<<~SQL, [numac, language, day, day])
      SELECT DISTINCT article, variant FROM periods
      WHERE numac = ? AND language = ? AND (COALESCE(valid_from, not_before) IS NULL OR COALESCE(valid_from, not_before) <= ?)
        AND (valid_until IS NULL OR valid_until >= ?) AND NOT (valid_from IS NOT NULL AND valid_until IS NOT NULL AND valid_from > valid_until)
    SQL
    rows.map { |row| period_key(row['article'], row['variant']) }
  end

  # 'Art.42' with no variant; a variant joins with a space when it holds one ('Art.42 WAALS GEWEST'), else with '_'.
  def period_key(article, variant)
    return article if variant.empty?

    "#{article}#{variant.include?(' ') ? ' ' : '_'}#{variant}"
  end

  def resolve(numac, language, key, day)
    article, variant = self.class.split_variant(key)
    candidates = versions(numac, language, article, variant).select { |version| version.covers?(day) }
    return if candidates.empty?

    Resolution.new(version: version_on(numac, language, article, variant, day), candidates: candidates)
  end

  def current_snapshot(numac, language) = snapshots(numac, language).find(&:current?)

  # Headings and articles of a page, in the source's order, with their stored wordings.
  def items(snapshot)
    @db.execute('SELECT i.key, i.kind, i.text_id, t.body FROM snapshot_items i JOIN texts t ON t.id = i.text_id ' \
                'WHERE i.source_id = ? ORDER BY i.position', [snapshot.id]).map do |row|
      Item.new(key: row['key'], kind: row['kind'], body: row['body'], text_id: row['text_id'])
    end
  end

  # The selectable wordings of an article key ('Art.19', 'Art.42_WAALS_GEWEST'): its 'text' periods, each named by
  # the archived version that first shows it ('013') or 'current'. The same names hold in both languages.
  def article_versions(numac, language, key)
    article, variant = self.class.split_variant(key)
    versions(numac, language, article, variant).select(&:text?)
  end

  # The key's disputed stretches (status 'disputed'), oldest first.
  def article_disputes(numac, language, key)
    article, variant = self.class.split_variant(key)
    versions(numac, language, article, variant).select(&:disputed?)
  end

  # The days and their sources out of a disputed stretch's note: [[iso day, 'NNN' archived version or 'current'], ...].
  def self.dispute_days(note)
    note.to_s.scan(/(\d{4}-\d{2}-\d{2}) \((?:from archived version (\d{3})|(current page))\)/).map do |day, version, current|
      [day, version || (current && 'current')]
    end
  end

  def self.version_name(version) = version.first_version ? format('%03d', version.first_version) : 'current'

  # Justel's archive of the law: the latest archived version's page, which lists every version.
  def archive_url(numac, language)
    @db.get_first_value('SELECT url FROM sources WHERE numac = ? AND language = ? AND version IS NOT NULL ' \
                        'ORDER BY version DESC LIMIT 1', [numac, language])
  end

  def articles(numac, language)
    @db.execute('SELECT DISTINCT article FROM periods WHERE numac = ? AND language = ? ORDER BY article',
                [numac, language]).map { |row| row['article'] }
  end

  def variants(numac, language, article)
    @db.execute('SELECT DISTINCT variant FROM periods WHERE numac = ? AND language = ? AND article = ? ' \
                'ORDER BY variant', [numac, language, article]).map { |row| row['variant'] }
  end

  # The article's periods in time order: the stored rows are written oldest first.
  def versions(numac, language, article, variant)
    @db.execute(<<~SQL, [numac, language, article, variant]).map { |row| version_from(row, language) }
      SELECT p.*, t.body FROM periods p LEFT JOIN texts t ON t.id = p.text_id
      WHERE p.numac = ? AND p.language = ? AND p.article = ? AND p.variant = ? ORDER BY p.id
    SQL
  end

  # The wording on an ISO day: a known period first, else an unknown one, else the earliest wording whose start the
  # archive does not give (marked so by Version#start_known?).
  def version_on(numac, language, article, variant, day)
    candidates = versions(numac, language, article, variant).select { |version| version.covers?(day) }
    candidates.find { |v| v.text? && v.start_known? } || candidates.find(&:disputed?) ||
      candidates.find { |v| v.status == 'unknown' } || candidates.first
  end

  # Word-level comparison of two wordings: [[:same | :removed | :added, text], ...], whitespace kept with each word.
  def self.word_diff(old_text, new_text)
    old_words = old_text.to_s.scan(/\S+\s*/)
    new_words = new_text.to_s.scan(/\S+\s*/)
    lengths = Array.new(old_words.size + 1) { Array.new(new_words.size + 1, 0) }
    old_words.size.downto(0) do |i|
      new_words.size.downto(0) do |j|
        next if i == old_words.size || j == new_words.size

        lengths[i][j] = if old_words[i].strip == new_words[j].strip
                          lengths[i + 1][j + 1] + 1
                        else
                          [lengths[i + 1][j], lengths[i][j + 1]].max
                        end
      end
    end
    pieces = []
    i = j = 0
    while i < old_words.size || j < new_words.size
      if i < old_words.size && j < new_words.size && old_words[i].strip == new_words[j].strip
        pieces << [:same, new_words[j]]
        i += 1
        j += 1
      elsif j < new_words.size && (i == old_words.size || lengths[i][j + 1] >= lengths[i + 1][j])
        pieces << [:added, new_words[j]]
        j += 1
      else
        pieces << [:removed, old_words[i]]
        i += 1
      end
    end
    pieces.chunk_while { |a, b| a[0] == b[0] }.map { |run| [run.first[0], run.map(&:last).join] }
  end

  private

  def version_from(row, language)
    source = source_for(language, row['first_version'], row['source_id'])
    Version.new(id: row['id'], status: row['status'], body: row['body'], valid_from: row['valid_from'],
                valid_from_basis: row['valid_from_basis'], valid_until: row['valid_until'],
                valid_until_basis: row['valid_until_basis'], inline_effective: row['inline_effective'],
                start_check: row['start_check'], introduced_by: row['introduced_by'], published: row['published'],
                first_version: row['first_version'], last_version: row['last_version'], source_url: source&.fetch('url'),
                captured_at: source&.fetch('captured_at'), note: row['note'], text_id: row['text_id'],
                change_kind: row['change_kind'], not_before: row['not_before'])
  end

  # The page that shows the wording: the period's own source, else the archived version it names, else the current
  # consolidated page.
  def source_for(language, version, source_id)
    if source_id
      @db.get_first_row('SELECT url, captured_at FROM sources WHERE id = ?', [source_id])
    elsif version
      @db.get_first_row('SELECT url, captured_at FROM sources WHERE language = ? AND version = ?', [language, version])
    else
      @db.get_first_row('SELECT url, captured_at FROM sources WHERE language = ? AND version IS NULL', [language])
    end
  end
end
