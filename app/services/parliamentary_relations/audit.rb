# frozen_string_literal: true

require 'date'
require 'json'
require 'sqlite3'
require 'time'

module ParliamentaryRelations
  # Evidence for a human review, never an assignment producer. Run on closed,
  # standalone SQLite snapshots. Ranking walks only the covering NUMAC index;
  # every subsequent lookup has an exact index and a row limit. A truncated
  # cohort/evidence set is explicitly incomplete, never a clean audit.
  class Audit
    class Refused < StandardError; end
    class EvidenceLimit < StandardError; end

    WER = '2013A11134'
    MAX_INDEX_ROWS = 1_000_000
    MAX_DOCUMENT_ROWS = 5_000
    MAX_TOTAL_ROWS = 50_000
    HARD_DOCUMENT_ROWS = 20_000
    HARD_TOTAL_ROWS = 100_000
    REF_BYTES = 16_384
    DOSSIER_LABEL = /\A\s*(\d{1,3})[ \t\u00A0\u202F\-‑–]+(\d{1,7})\s*\z/
    DOCUMENT_COLUMNS = %w[id legislation_numac parliament legislature dossier_number document_number document_date language].freeze

    def initialize(laws_path:, chamber_path:, manifest: ParliamentaryRelations.manifest,
                   max_index_rows: MAX_INDEX_ROWS, max_document_rows: MAX_DOCUMENT_ROWS, max_total_rows: MAX_TOTAL_ROWS)
      @laws_path = laws_path.to_s
      @chamber_path = chamber_path.to_s
      @manifest = manifest
      @max_index_rows = bound(max_index_rows, MAX_INDEX_ROWS)
      @max_document_rows = bound(max_document_rows, HARD_DOCUMENT_ROWS)
      @max_total_rows = bound(max_total_rows, HARD_TOTAL_ROWS)
    end

    def call(limit: 21)
      raise Refused, 'LIMIT must be an integer from 21 to 100 (WER and at least 20 other laws)' unless limit.is_a?(Integer) && (21..100).cover?(limit)

      @total_rows = 0
      @dossier_documents = {}
      @dossier_summaries = {}
      @capture_provenance = nil
      with_snapshot(@chamber_path) do |chamber|
        with_snapshot(@laws_path) do |laws|
          check_schema(chamber, laws)
          ranking = captured_ranking(chamber, limit) || rank(chamber, limit - 1)
          cohort = [[WER, ranking.fetch('wer_count')], *ranking.fetch('highest_other_numacs')]
          evidence = cohort.map { |numac, count| law_evidence(numac, count, chamber, laws) }
          additional_candidates = additional_candidates(chamber, laws)
          errors = []
          errors << "only #{cohort.size - 1} other assigned NUMACs in this snapshot; at least 20 required" if cohort.size < 21
          complete = errors.empty? && evidence.all? { |law| law.fetch('complete') } &&
                     additional_candidates.all? { |candidate| candidate.dig('evidence', 'complete') }
          known_changes = evidence.count { |law| law.dig('projection', 'panel_would_change') }
          {
            'audit_version' => 1, 'generated_at' => Time.now.utc.iso8601, 'read_only' => true,
            'status' => complete ? 'complete' : 'incomplete', 'complete' => complete,
            'sources' => { 'laws' => source(@laws_path), 'chamber' => source(@chamber_path) },
            'bounds' => { 'index_rows' => @max_index_rows, 'documents_per_lookup' => @max_document_rows,
                          'total_evidence_rows' => @max_total_rows },
            'ranking' => ranking.except('highest_other_numacs', 'wer_count'),
            'coverage' => { 'requested_laws' => limit, 'laws' => cohort.size, 'other_laws' => cohort.size - 1,
                            'mandatory_numac' => WER, 'scope' => 'highest counts within the supplied snapshot' },
            'impact' => { 'baseline' => 'legacy automatic NUMAC/ref panel', 'proposed' => 'reviewed manifest panel',
                          'unit' => 'distinct NUMAC panels, not visits or locale cache entries',
                          'panels_would_change' => complete ? known_changes : nil,
                          'known_changed_panels' => known_changes, 'complete' => complete,
                          'current_panel_note' => 'The resolver already uses reviewed dossiers; this compares its reviewed selection with the legacy automatic selection.' },
            'errors' => errors, 'laws' => evidence, 'additional_act_candidates' => additional_candidates
          }
        end
      end
    rescue SQLite3::Exception => e
      raise Refused, "snapshot query failed: #{e.message}"
    end

    private

    def bound(value, maximum)
      raise Refused, "row bound must be an integer from 1 to #{maximum}" unless value.is_a?(Integer) && (1..maximum).cover?(value)

      value
    end

    def source(path)
      stat = File.stat(path)
      { 'path' => File.expand_path(path), 'bytes' => stat.size, 'modified_at' => stat.mtime.utc.iso8601 }
    end

    def with_snapshot(path)
      raise Refused, "snapshot not found: #{path}" unless File.file?(path)
      raise Refused, "snapshot must be a standalone file, not a symlink: #{path}" if File.symlink?(path)
      if %w[-wal -shm -journal].any? { |suffix| File.exist?(path + suffix) }
        raise Refused, "snapshot has a journal/sidecar; finish a consistent standalone backup first: #{path}"
      end

      header = File.open(path, 'rb') { |file| file.read(20) }
      raise Refused, "WAL snapshot requires a closed standalone backup: #{path}" if header && (header.getbyte(18) == 2 || header.getbyte(19) == 2)

      db = SQLite3::Database.new(path, readonly: true)
      db.busy_timeout = 2_000
      db.execute('PRAGMA query_only = ON')
      db.execute('PRAGMA temp_store = MEMORY')
      raise Refused, "WAL snapshot requires a closed standalone backup: #{path}" if db.get_first_value('PRAGMA journal_mode').to_s.downcase == 'wal'

      yield db
    ensure
      db&.close
    end

    def columns(db, table, required)
      found = db.execute("PRAGMA table_info(#{quote(table)})").map { |row| row[1] }
      missing = required - found
      raise Refused, "missing schema: #{table}.#{missing.join(', ')}" if missing.any?

      found
    end

    # An exact left-prefix index must be nonpartial. INDEXED BY makes SQLite
    # refuse any query if that evidence index disappears instead of scanning.
    def index(db, table, prefix)
      match = db.execute("PRAGMA index_list(#{quote(table)})").find do |row|
        row[4].to_i.zero? && db.execute("PRAGMA index_info(#{quote(row[1])})").map { |part| part[2] }.first(prefix.size) == prefix
      end
      raise Refused, "missing nonpartial index: #{table}(#{prefix.join(', ')})" unless match

      quote(match[1])
    end

    def quote(identifier) = "\"#{identifier.gsub('"', '""')}\""

    def check_schema(chamber, laws)
      @document_columns = columns(chamber, 'documents', DOCUMENT_COLUMNS)
      @summary_columns = columns(chamber, 'dossiers', %w[id legislature nummer titel dossier_url])
      columns(laws, 'legislation', %w[numac language_id title date parliamentary_refs])
      columns(laws, 'contents', %w[legislation_numac language_id chamber_dossier senate_dossier parliamentary_work other_external_links])
      @numac_index = index(chamber, 'documents', %w[legislation_numac])
      @document_dossier_index = index(chamber, 'documents', %w[parliament legislature dossier_number])
      @summary_index = index(chamber, 'dossiers', %w[legislature nummer])
      @law_index = index(laws, 'legislation', %w[numac])
      @content_index = index(laws, 'contents', %w[legislation_numac])
    end

    def rank(db, count)
      top = []
      scanned = 0
      distinct = 0
      invalid = 0
      wer_count = 0
      previous = nil
      occurrences = 0
      finish = lambda do
        next if previous.nil?

        distinct += 1
        if previous == WER
          wer_count = occurrences
        elsif Manifest::NUMAC.match?(previous)
          top << [previous, occurrences]
          top.sort_by! { |numac, total| [-total, numac] }
          top.pop if top.size > count
        else
          invalid += occurrences
        end
      end
      sql = "SELECT legislation_numac FROM documents INDEXED BY #{@numac_index} " \
            'WHERE legislation_numac > ? ORDER BY legislation_numac LIMIT ?'
      db.prepare(sql) do |statement|
        statement.execute('', @max_index_rows + 1) do |rows|
          rows.each do |(numac)|
            scanned += 1
            raise Refused, "NUMAC ranking exceeds #{@max_index_rows} indexed rows; highest-count cohort is unknown" if scanned > @max_index_rows

            if numac != previous
              finish.call
              previous = numac
              occurrences = 0
            end
            occurrences += 1
          end
        end
      end
      finish.call
      { 'basis' => 'complete bounded traversal of the covering documents NUMAC index', 'complete' => true,
        'indexed_assignment_rows' => scanned, 'distinct_assigned_numacs' => distinct,
        'invalid_numac_assignment_rows' => invalid, 'highest_other_numacs' => top, 'wer_count' => wer_count }
    end

    # A bounded capture contains the entire selected cohort but only part of
    # the source corpus. Its original ranking provenance must survive hydration;
    # ranking that subset would incorrectly promote incidental conflict NUMACs.
    def captured_ranking(db, limit)
      return nil unless db.get_first_value("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'audit_snapshot_provenance'")

      found = db.execute('SELECT substr(provenance, 1, 65536), length(provenance) FROM audit_snapshot_provenance LIMIT 2')
      raise Refused, 'capture must have one bounded provenance record' unless found.one? && found.first[1].to_i <= 65_536

      provenance = JSON.parse(found.first[0])
      unless provenance['format_version'] == 1 && provenance['capture_complete'] == true && provenance['ranking_complete'] == true
        raise Refused, 'captured cohort is not certified complete by its bounded capture'
      end

      cohort = provenance.fetch('cohort')
      unless cohort.is_a?(Array) && cohort.all? { |entry| entry.is_a?(Hash) && Manifest::NUMAC.match?(entry['numac'].to_s) && entry['count'].is_a?(Integer) && entry['count'] >= 0 }
        raise Refused, 'invalid capture cohort'
      end
      unless cohort.map { |entry| entry['numac'] }.uniq.size == cohort.size && cohort.any? { |entry| entry['numac'] == WER }
        raise Refused, 'capture cohort repeats NUMACs or omits WER'
      end

      other = cohort.reject { |entry| entry['numac'] == WER }.sort_by { |entry| [-entry['count'], entry['numac']] }
      raise Refused, "capture has only #{other.size} other laws, fewer than requested #{limit - 1}" if other.size < limit - 1

      @capture_provenance = provenance

      { 'basis' => 'complete bounded source-index ranking retained by capture provenance', 'complete' => true,
        'indexed_assignment_rows' => provenance.fetch('indexed_assignment_rows'),
        'distinct_assigned_numacs' => provenance.fetch('distinct_assigned_numacs'),
        'invalid_numac_assignment_rows' => provenance.fetch('invalid_numac_assignment_rows', 0),
        'capture_sources' => provenance.fetch('sources'), 'captured_at' => provenance.fetch('captured_at'),
        'highest_other_numacs' => other.first(limit - 1).map { |entry| entry.values_at('numac', 'count') },
        'wer_count' => cohort.find { |entry| entry['numac'] == WER }.fetch('count') }
    rescue JSON::ParserError, KeyError => e
      raise Refused, "invalid capture provenance: #{e.message}"
    end

    def rows(db, sql, binds, maximum, label)
      remaining = [maximum, @max_total_rows - @total_rows].min
      raise EvidenceLimit, "#{label}: total evidence row cap #{@max_total_rows} reached" unless remaining.positive?

      found = db.execute("#{sql} LIMIT ?", binds + [remaining + 1])
      @total_rows += found.size
      raise EvidenceLimit, "#{label}: evidence exceeds row cap #{remaining}" if found.size > remaining

      found
    end

    def document_select
      optional = %w[assignment_source linkage_source source_method].select { |name| @document_columns.include?(name) }
      DOCUMENT_COLUMNS.join(', ') + optional.map { |name| ", substr(#{quote(name)}, 1, 256) AS #{quote(name)}" }.join
    end

    def documents(db, where, binds, lookup_index, label)
      names = DOCUMENT_COLUMNS + %w[assignment_source linkage_source source_method].select { |name| @document_columns.include?(name) }
      rows(db, "SELECT #{document_select} FROM documents INDEXED BY #{lookup_index} WHERE #{where}",
           binds, @max_document_rows, label).map { |row| names.zip(row).to_h }
    end

    def dossier_documents(db, dossier)
      key = dossier.values_at('parliament', 'legislature', 'number')
      @dossier_documents[key] ||= begin
        number = dossier.fetch('number')
        variants = [number.to_s, number.to_s.rjust(4, '0')].uniq
        found = documents(db, "parliament = ? AND legislature = ? AND dossier_number IN (#{(['?'] * variants.size).join(', ')})",
                          [*key.first(2), *variants], @document_dossier_index, "dossier #{key.join('/')}")
        if @capture_provenance
          certification = Array(@capture_provenance['dossier_document_counts']).find do |entry|
            entry.values_at('parliament', 'legislature', 'number') == key
          end
          unless Array(@capture_provenance['reviewed_dossiers_captured']).include?(key) && certification &&
                 certification['complete'] == true && certification['count'] == found.size && certification['by_language'] == language_counts(found)
            raise EvidenceLimit, "dossier #{key.join('/')}: capture provenance does not certify all document rows"
          end
        end
        found
      end
    end

    def dossier_summary(db, dossier)
      return nil unless dossier['parliament'] == 'chamber'

      key = dossier.values_at('legislature', 'number')
      return @dossier_summaries[key] if @dossier_summaries.key?(key)

      names = %w[id legislature nummer titel dossier_url filing_date vote_date type].select { |name| @summary_columns.include?(name) }
      select = names.map { |name| %w[titel dossier_url].include?(name) ? "substr(#{quote(name)}, 1, 2000)" : quote(name) }.join(', ')
      found = rows(db, "SELECT #{select} FROM dossiers INDEXED BY #{@summary_index} WHERE legislature = ? AND nummer = ?",
                   key, 2, "dossier summary #{key.join('/')}")
      @dossier_summaries[key] = found.map { |row| names.zip(row).to_h }
    end

    def dossier(parliament, label)
      match = DOSSIER_LABEL.match(label.to_s)
      return nil unless match && match[1].to_i.positive? && match[2].to_i.positive?

      { 'parliament' => parliament, 'legislature' => match[1].to_i, 'number' => match[2].to_i }
    end

    def refs(raw)
      parsed = JSON.parse(raw.to_s.empty? ? '[]' : raw)
      raise JSON::ParserError, 'parliamentary_refs is not a list' unless parsed.is_a?(Array)

      parsed.filter_map do |ref|
        next unless ref.is_a?(String) && %w[K: S:].include?(ref[0, 2])

        dossier(ref.start_with?('K:') ? 'chamber' : 'senate', ref[2..])
      end
    end

    def date(value)
      text = value.to_s.strip
      return Date.iso8601(text) if text.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      Date.strptime(text, '%d/%m/%Y') if text.match?(%r{\A\d{2}/\d{2}/\d{4}\z})
    rescue Date::Error
      nil
    end

    def identity(row)
      dossier(row['parliament'], "#{row['legislature']}-#{row['dossier_number']}")
    end

    def grouped_documents(db, documents)
      documents.group_by { |row| row.values_at('parliament', 'legislature', 'dossier_number') }.map do |key, group|
        dates = group.filter_map { |row| date(row['document_date']) }.sort
        exact = identity(group.first)
        { 'parliament' => key[0], 'legislature' => key[1], 'dossier_number' => key[2], 'rows' => group.size,
          'document_ids' => group.map { |row| row['id'] }.sort,
          'document_numbers' => group.map { |row| row['document_number'] }.compact.uniq.sort,
          'first_document_date' => dates.first&.iso8601, 'last_document_date' => dates.last&.iso8601,
          'unparseable_document_dates' => group.count { |row| !row['document_date'].to_s.empty? && date(row['document_date']).nil? },
          'assignment_sources' => assignment_sources(group), 'dossier_summary' => exact && dossier_summary(db, exact) }
      end.sort_by { |group| [group['parliament'].to_s, group['legislature'].to_i, group['dossier_number'].to_i] }
    end

    def assignment_sources(documents)
      sources = documents.flat_map { |row| row.slice('assignment_source', 'linkage_source', 'source_method').values }.compact.reject(&:empty?).uniq.sort
      sources.empty? ? ['unknown: corpus records no assignment provenance'] : sources
    end

    def law_evidence(numac, count, chamber, laws)
      versions = rows(laws, "SELECT language_id, substr(title, 1, 10000), date, substr(parliamentary_refs, 1, #{REF_BYTES}), " \
                            "length(parliamentary_refs) FROM legislation INDEXED BY #{@law_index} WHERE numac = ?",
                      [numac], 8, "law #{numac}").map do |language, title, act_date, raw, length|
        raise EvidenceLimit, "law #{numac}: parliamentary_refs exceeds #{REF_BYTES} characters" if length.to_i > REF_BYTES

        { 'language_id' => language, 'title' => title, 'date' => act_date, 'parliamentary_refs' => raw }
      end
      contents = rows(laws, 'SELECT language_id, chamber_dossier, senate_dossier, substr(parliamentary_work, 1, 2000), ' \
                            "substr(other_external_links, 1, 2000) FROM contents INDEXED BY #{@content_index} WHERE legislation_numac = ?",
                      [numac], 8, "contents #{numac}").map do |language, chamber_ref, senate_ref, work, links|
        { 'language_id' => language, 'chamber_dossier' => chamber_ref, 'senate_dossier' => senate_ref,
          'parliamentary_work_excerpt' => work, 'other_external_links_excerpt' => links }
      end
      raw_docs = documents(chamber, 'legislation_numac = ?', [numac], @numac_index, "NUMAC #{numac}")
      raise EvidenceLimit, "#{numac}: ranking count differs from evidence rows" unless raw_docs.size == count

      issues = []
      referenced = []
      versions.each do |version|
        referenced.concat(refs(version['parliamentary_refs']))
      rescue JSON::ParserError
        issues << 'corrupt_parliamentary_refs'
      end
      referenced.uniq!
      content_dossiers = contents.flat_map do |content|
        [dossier('chamber', content['chamber_dossier']), dossier('senate', content['senate_dossier'])].compact
      end.uniq
      raw_groups = grouped_documents(chamber, raw_docs)
      reviewed = @manifest.for_law(numac)
      reviewed_dossiers = Array(reviewed&.dossiers).map { |item| item.to_h.transform_keys(&:to_s).merge('number' => item.number) }
      before_docs = raw_docs.any? ? raw_docs : referenced.flat_map { |item| dossier_documents(chamber, item) }.uniq { |row| row['id'] }
      after_docs = reviewed ? reviewed_dossiers.flat_map { |item| dossier_documents(chamber, item) }.uniq { |row| row['id'] } : before_docs
      act_dates = versions.filter_map { |version| date(version['date']) }.uniq
      issues << 'missing_act_title_or_date' if versions.empty? || versions.any? { |version| version['title'].to_s.empty? || date(version['date']).nil? }
      issues << 'different_act_dates_across_languages' if act_dates.size > 1
      issues << 'multiple_automatic_dossiers' if raw_groups.size > 1
      issues << 'raw_dossier_refs_disagree_with_contents' if referenced.any? && content_dossiers.any? && referenced != content_dossiers
      observed = raw_docs.filter_map { |row| identity(row) }.uniq
      dates_by_dossier = raw_docs.group_by { |row| identity(row) }.transform_values do |group|
        group.filter_map { |row| date(row['document_date']) }
      end
      issues << 'assigned_dossiers_disagree_with_raw_refs' if referenced.any? && observed.any? && (observed - referenced).any?
      issues << 'document_dossier_identity_missing_or_invalid' if raw_docs.any? { |row| identity(row).nil? }
      if act_dates.one?
        document_dates = raw_docs.filter_map { |row| date(row['document_date']) }
        issues << 'documents_after_act_date_review' if document_dates.any? { |item| item > act_dates.first }
        issues << 'documents_more_than_one_year_before_act_review' if document_dates.any? { |item| item < act_dates.first - 365 }
      end
      projection = projection(numac, reviewed, versions, raw_docs, before_docs, after_docs)
      issues << 'assignments_outside_reviewed_dossiers' if reviewed && projection['remove_assignment_document_ids'].any?
      issues << 'reviewed_dossier_contains_other_numac' if projection['conflicts'].any?
      candidates = (referenced + content_dossiers + observed).uniq.map do |item|
        later = dates_by_dossier.fetch(item, [])
        kind = act_dates.one? && later.any? { |item_date| item_date > act_dates.first } ? 'later_citation_or_amendment_to_review' : 'preparatory_to_enactment_to_review'
        { **item, 'verified' => false, 'relation_kind' => kind,
                  'basis' => [referenced.include?(item) && 'automatic parliamentary_refs', content_dossiers.include?(item) && 'contents dossier field',
                              observed.include?(item) && 'automatic document NUMAC'].select { |value| value },
                  'review_required' => 'Confirm this enactment and exact dossier using an official primary source; dates and titles do not verify a relation.' }
      end
      complete = !issues.include?('missing_act_title_or_date') && !issues.include?('corrupt_parliamentary_refs')
      { 'numac' => numac, 'automatic_assignment_count' => count, 'complete' => complete,
        'act_versions' => versions, 'act_fields_source' => 'legislation snapshot; official act fields not independently reverified by this audit',
        'contents' => contents, 'raw_ref_dossiers' => referenced,
        'automatic_documents' => { 'by_language' => language_counts(raw_docs), 'dossiers' => raw_groups },
        'reviewed_relation' => reviewed && { 'law' => reviewed.law, 'dossiers' => reviewed_dossiers,
                                             'evidence' => reviewed.evidence, 'reviewed_by' => reviewed.reviewed_by,
                                             'reviewed_on' => reviewed.reviewed_on.iso8601 },
        'suspicion_reasons' => issues.uniq, 'date_signal_policy' => 'Review only; dates never remove or verify a relationship.',
        'candidate_relations' => candidates, 'projection' => projection, 'errors' => [] }
    rescue EvidenceLimit => e
      { 'numac' => numac, 'automatic_assignment_count' => count, 'complete' => false,
        'suspicion_reasons' => ['evidence_incomplete'], 'candidate_relations' => [], 'projection' => nil, 'errors' => [e.message] }
    end

    def language_counts(documents) = documents.group_by { |row| row['language'].to_s }.transform_values(&:size)

    def additional_candidates(chamber, laws)
      Array(@capture_provenance && @capture_provenance['additional_act_candidates']).map do |entry|
        unless entry.is_a?(Hash) && Manifest::NUMAC.match?(entry['numac'].to_s) && entry['count'].is_a?(Integer) && entry['count'] >= 0
          raise Refused, 'invalid additional act candidate provenance'
        end

        evidence = law_evidence(entry['numac'], entry['count'], chamber, laws)
        matching = @manifest.relations.filter_map do |relation|
          exact = relation.dossiers.map { |item| { 'parliament' => item.parliament, 'legislature' => item.legislature, 'number' => item.number } }
          shared = Array(evidence['raw_ref_dossiers']) & exact
          { 'reviewed_numac' => relation.numac, 'shared_dossiers' => shared } if shared.any?
        end
        { 'numac' => entry['numac'], 'verified' => false, 'evidence' => evidence,
          'relation_kind' => 'separate_enacting_act_to_review', 'shares_reviewed_dossiers_with' => matching,
          'review_required' => 'A separate act row sharing an automatic dossier ref is a candidate relation, never an inferred alias.' }
      end
    end

    def projection(numac, reviewed, versions, raw_docs, before_docs, after_docs)
      before_ids = before_docs.map { |row| row['id'] }.sort
      after_ids = after_docs.map { |row| row['id'] }.sort
      additions = reviewed ? after_docs.reject { |row| row['legislation_numac'] == numac } : []
      conflicts = additions.select { |row| !row['legislation_numac'].to_s.empty? && !reviewed.replaces_numacs.include?(row['legislation_numac']) }
      expected_refs = reviewed&.dossiers&.map { |item| "#{item.parliament == 'senate' ? 'S' : 'K'}:#{item.label}" }&.sort&.to_json
      { 'before' => { 'basis' => raw_docs.any? ? 'automatic_numac' : 'automatic_dossier_refs', 'document_count' => before_ids.size,
                      'by_language' => language_counts(before_docs) },
        'after' => { 'basis' => reviewed ? 'reviewed_manifest' : 'unchanged_unverified', 'document_count' => after_ids.size,
                     'by_language' => language_counts(after_docs), 'dossiers' => grouped_projection_dossiers(after_docs) },
        'panel_would_change' => !reviewed.nil?, 'membership_changes' => (before_ids - after_ids).size + (after_ids - before_ids).size,
        'add_assignment_document_ids' => additions.map { |row| row['id'] }.sort,
        'remove_assignment_document_ids' => reviewed ? (raw_docs.map { |row| row['id'] } - after_ids).sort : [],
        'refs_rows_would_change' => reviewed ? versions.count { |version| version['parliamentary_refs'] != expected_refs } : 0,
        'conflicts' => conflicts.map { |row| { 'document_id' => row['id'], 'current_numac' => row['legislation_numac'], 'proposed_numac' => numac } },
        'apply_allowed_by_conflict_check' => reviewed ? conflicts.empty? : nil }
    end

    def grouped_projection_dossiers(documents)
      documents.group_by { |row| row.values_at('parliament', 'legislature', 'dossier_number') }.map do |key, group|
        { 'parliament' => key[0], 'legislature' => key[1], 'dossier_number' => key[2], 'document_ids' => group.map { |row| row['id'] }.sort }
      end
    end
  end
end
