# frozen_string_literal: true

require 'json'

module ParliamentaryRelations
  # CLI admission for every dossier-wide producer. Raw contents and scraper
  # fields cannot authorize corpus changes; Apply always uses the manifest.
  class ProducerGuard
    class Refused < StandardError; end

    def self.manifest_from_environment(environment = ENV)
      path = environment['PARLIAMENTARY_RELATIONS_MANIFEST']
      path.present? ? Manifest.load(path) : ParliamentaryRelations.manifest
    end

    def self.from_environment(environment = ENV)
      new(laws_path: environment.fetch('LAWS_DB_PATH') do
        File.expand_path(ActiveRecord::Base.connection_db_config.database, Rails.root)
      end,
          chamber_path: environment.fetch('CHAMBER_DB_PATH') { Rails.root.join('storage', 'chamber.sqlite3').to_s },
          manifest: manifest_from_environment(environment), environment: environment)
    end

    def initialize(laws_path:, chamber_path:, manifest: ParliamentaryRelations.manifest, environment: ENV,
                   cache: Rails.cache)
      @laws_path = laws_path
      @chamber_path = chamber_path
      @manifest = manifest
      @environment = environment
      @cache = cache
    end

    def write?
      @environment['APPLY'] == '1' && @environment['DRY_RUN'] != '1'
    end

    def call
      validate_write_options!
      Apply.new(laws_path: @laws_path, chamber_path: @chamber_path, manifest: @manifest,
                numacs: selected_numacs, max_changes: max_changes, cache: @cache,
                lock_path: lock_path, lock_wait: lock_wait, backup_dir: @environment['BACKUP_DIR']).call(apply: write?)
    end

    def rollback
      validate_write_options!(rollback: true)
      backup_path = required_value('BACKUP_PATH')
      backup = JSON.parse(File.read(backup_path))
      raise Refused, 'invalid rollback backup: expected a mapping of changes' unless backup.is_a?(Hash)

      changes = backup.fetch('changes')
      raise Refused, 'invalid rollback backup: changes must be a list' unless changes.is_a?(Array)

      count = changes.size
      raise Refused, "the rollback changes #{count} rows, more than MAX_CHANGES=#{max_changes}" if count > max_changes

      Apply.rollback(backup_path, apply: write?, lock_path: lock_path, lock_wait: lock_wait, cache: @cache)
    rescue JSON::ParserError, KeyError, SystemCallError => e
      raise Refused, "invalid rollback backup: #{e.message}"
    end

    private

    def validate_write_options!(rollback: false)
      return unless write?

      raise Refused, 'writes require APPLY=1 REVIEWED=1 after reviewing the audit and dry-run plan' unless @environment['REVIEWED'] == '1'

      required_value('PIPELINE_LOCK_PATH')
      required_value('MAX_CHANGES')
      required_value('BACKUP_DIR') unless rollback
    end

    def required_value(key)
      value = @environment[key]
      raise Refused, "#{key} must be explicit" if value.blank?

      value
    end

    def integer_value(key, default:, minimum:)
      value = Integer(@environment.fetch(key, default).to_s, 10)
      raise Refused, "#{key} must be at least #{minimum}" if value < minimum

      value
    rescue ArgumentError, TypeError
      raise Refused, "#{key} must be an integer"
    end

    def max_changes = integer_value('MAX_CHANGES', default: Apply::MAX_CHANGES, minimum: 1)
    def lock_wait = integer_value('LOCK_WAIT', default: 0, minimum: 0)
    def lock_path = @environment['PIPELINE_LOCK_PATH'].presence || Apply::DEFAULT_LOCK

    def selected_numacs
      return unless @environment.key?('NUMACS')

      numacs = @environment['NUMACS'].to_s.split(/[;,\s]+/).reject(&:empty?).uniq
      raise Refused, 'NUMACS must name at least one reviewed NUMAC' if numacs.empty?

      unknown = numacs.reject { |numac| @manifest.for_law(numac) }
      raise Refused, "NUMACS are not reviewed in the manifest: #{unknown.join(', ')}" if unknown.any?

      numacs
    end
  end
end
