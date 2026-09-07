# frozen_string_literal: true

class ChatbotConversation < ChatbotRecord
  # Connection comes from ChatbotRecord / database.yml (FBL-050); the
  # previous inline establish_connection with per-PID test paths moved
  # there verbatim.

  # Override readonly - Rails marks models with establish_connection as readonly by default
  def readonly?
    false
  end

  EXPIRY_DURATION = 24.hours
  MAX_MESSAGES = 20
  MAX_TITLE_LENGTH = 100
  SCHEMA_MIGRATION_MUTEX = Mutex.new
  REQUIRED_COLUMN_CONTRACT = {
    'id' => { type: :integer, null: false }.freeze,
    'token' => { type: :string, null: false }.freeze,
    'user_id' => { type: :string }.freeze,
    'language' => { type: :string, default: 'nl' }.freeze,
    'messages' => { type: :text }.freeze,
    'context_numacs' => { type: :text }.freeze,
    'last_question' => { type: :string }.freeze,
    'message_count' => { type: :integer, default: 0 }.freeze,
    'expires_at' => { type: :datetime }.freeze,
    'created_at' => { type: :datetime, null: false }.freeze,
    'updated_at' => { type: :datetime, null: false }.freeze,
    # W7: title is `encrypts`-managed (and carries opaque ZK blobs), so the
    # stored value is a ciphertext envelope several times the plaintext
    # length. It must be TEXT: PostgreSQL enforces varchar limits that
    # SQLite ignored, and a varchar(200) title silently dropped imports.
    'title' => { type: :text }.freeze,
    'pinned' => { type: :boolean, default: false }.freeze,
    'zero_knowledge' => { type: :boolean, default: false }.freeze,
    'zk_key_generation' => { type: :string }.freeze,
    'zk_claim_token' => { type: :string }.freeze,
    'zk_claimed_at' => { type: :datetime }.freeze,
    'archived' => { type: :boolean, default: false }.freeze,
    'lock_version' => { type: :integer, null: false, default: 0 }.freeze
  }.freeze
  REQUIRED_COLUMNS = REQUIRED_COLUMN_CONTRACT.keys.freeze
  REQUIRED_INDEX_CONTRACT = [
    { columns: %w[token].freeze, unique: true }.freeze,
    { columns: %w[user_id].freeze, unique: false }.freeze,
    { columns: %w[expires_at].freeze, unique: false }.freeze
  ].freeze

  # Create table if not exists (self-initializing)
  # Uses a class-level flag to avoid repeated checks on every request
  def self.ensure_table_exists
    return if @table_verified && connection.table_exists?(:chatbot_conversations)
    return (@table_verified = true) if connection.table_exists?(:chatbot_conversations)

    # The test database can be recreated after application boot; a missing
    # table also invalidates a previously verified column set.
    @table_verified = false
    @columns_verified = false

    connection.create_table :chatbot_conversations do |t|
      t.string :token, null: false, index: { unique: true }
      t.string :user_id
      t.string :language, default: 'nl'
      t.text :messages
      t.text :context_numacs
      t.string :last_question
      t.integer :message_count, default: 0
      t.datetime :expires_at
      t.timestamps
    end
    connection.add_index :chatbot_conversations, :user_id
    connection.add_index :chatbot_conversations, :expires_at
    @table_verified = true
  rescue ActiveRecord::StatementInvalid => e
    # Table may have been created by another thread/process
    raise unless e.message.include?('already exists')

    @table_verified = connection.table_exists?(:chatbot_conversations)
    raise unless @table_verified
  end

  # Self-migrating: add title and pinned columns if missing
  def self.ensure_columns_exist
    return if @columns_verified

    attempts = 0
    begin
      SCHEMA_MIGRATION_MUTEX.synchronize do
        return if @columns_verified

        conn = connection
        added_column = false
        [
          [:title, :text, {}],
          [:pinned, :boolean, { default: false }],
          [:zero_knowledge, :boolean, { default: false }],
          [:zk_key_generation, :string, {}],
          [:zk_claim_token, :string, {}],
          [:zk_claimed_at, :datetime, {}],
          [:archived, :boolean, { default: false }],
          [:lock_version, :integer, { default: 0, null: false }]
        ].each do |name, type, options|
          next if conn.column_exists?(:chatbot_conversations, name)

          conn.add_column(:chatbot_conversations, name, type, **options)
          added_column = true
          Rails.logger.info("[ChatbotConversation] Self-migrated: added #{name} column")
        end
        # W7: legacy tables carry title as varchar(200) from the original
        # reconciler, but title stores `encrypts` ciphertext / ZK blobs and
        # the contract demands :text (PostgreSQL enforces the limit; the
        # 2026-08-18 deploy proved production still had the varchar). The
        # add-if-missing loop above can never fix a TYPE, so converge it
        # here - a one-time SQLite table rebuild, a plain ALTER elsewhere.
        title_column = conn.columns(:chatbot_conversations).find { |c| c.name == 'title' }
        if title_column && title_column.type != :text
          conn.change_column(:chatbot_conversations, :title, :text)
          added_column = true
          Rails.logger.info('[ChatbotConversation] Self-migrated: widened title to text')
        end
        reset_column_information if added_column

        missing = REQUIRED_COLUMNS.reject do |name|
          conn.column_exists?(:chatbot_conversations, name)
        end
        raise "required columns still missing: #{missing.join(', ')}" if missing.any?

        @columns_verified = true
      end
    rescue StandardError => e
      attempts += 1
      @columns_verified = false
      connection.schema_cache.clear!
      reset_column_information
      retryable = e.message.match?(/already exists|duplicate column|database (?:is )?(?:busy|locked)/i)
      if retryable && attempts < 5
        sleep(0.02 * attempts)
        retry
      end

      Rails.logger.error("[ChatbotConversation] Column migration failed: #{e.class}: #{e.message}")
      raise
    end
  end

  # Run column migration after table verification
  def self.ensure_table_and_columns_exist
    # FBL-051 drain: on PostgreSQL the schema is migration-managed
    # (chatbot:migrate_database at deploy) and the app role cannot DDL, so
    # the runtime reconciler must never attempt request-time DDL - it could
    # only 500. Trust the migrated schema. The SQLite path is unchanged.
    if connection.adapter_name.match?(/postgresql/i)
      @table_verified = true
      @columns_verified = true
      return
    end
    ensure_table_exists
    ensure_columns_exist if @table_verified
  end

  # A SQLite quick_check proves file integrity, not application schema
  # integrity. Keep the complete runtime contract here so the release task can
  # reject a legacy or partial table before Puma is restarted.
  def self.schema_contract_violations(connection: self.connection, table_name: :chatbot_conversations)
    return ["missing table #{table_name}"] unless connection.table_exists?(table_name)

    violations = []
    columns = connection.columns(table_name).index_by(&:name)
    REQUIRED_COLUMN_CONTRACT.each do |name, expected|
      column = columns[name]
      unless column
        violations << "missing column #{name}"
        next
      end

      violations << "column #{name} has type #{column.type}, expected #{expected.fetch(:type)}" if column.type != expected.fetch(:type)
      if expected.key?(:null) && column.null != expected.fetch(:null)
        violations << "column #{name} nullability is #{column.null}, expected #{expected.fetch(:null)}"
      end
      next unless expected.key?(:default)

      actual_default = normalized_schema_default(column.default, expected.fetch(:type))
      expected_default = expected.fetch(:default)
      next if actual_default == expected_default

      violations << "column #{name} default is #{actual_default.inspect}, expected #{expected_default.inspect}"
    end

    primary_key = connection.primary_key(table_name).to_s
    violations << "primary key is #{primary_key.presence || 'missing'}, expected id" unless primary_key == 'id'

    indexes = connection.indexes(table_name)
    REQUIRED_INDEX_CONTRACT.each do |expected|
      matching = indexes.any? do |index|
        index.columns == expected.fetch(:columns) &&
          index.unique == expected.fetch(:unique) && index.where.blank?
      end
      next if matching

      kind = expected.fetch(:unique) ? 'unique index' : 'index'
      violations << "missing #{kind} on #{expected.fetch(:columns).join(',')}"
    end

    violations
  end

  def self.normalized_schema_default(value, type)
    return value if value.nil?

    case type
    when :boolean
      ActiveModel::Type::Boolean.new.cast(value)
    when :integer
      value.to_i
    else
      value
    end
  end
  private_class_method :normalized_schema_default

  before_validation :generate_token, on: :create
  before_create :set_expiry

  validates :token, presence: true, uniqueness: true
  validates :language, presence: true # Allow any language - LLM responds in user's language

  # ═══════════════════════════════════════════════════════════════════
  # ZERO-KNOWLEDGE ENCRYPTION
  #
  # Two storage modes:
  # 1. ANONYMOUS: Server stores messages as Rails-encrypted JSON.
  #    Used for anonymous sessions (no user, no ZK key).
  #    Server can read via conversation_context (needed for session context).
  #
  # 2. ZERO-KNOWLEDGE: Client encrypts messages + title before sending.
  #    Server stores opaque ciphertext blobs. The server CANNOT decrypt.
  #    `zero_knowledge = true` flag marks these conversations.
  #    Client provides conversation context with each request.
  #
  # Both modes coexist: ZK for consented users, server-encrypted for anonymous.
  # ═══════════════════════════════════════════════════════════════════

  # Server-side encryption for NON-ZK conversations (anonymous sessions)
  # ZK conversations store opaque ciphertext - Rails `encrypts` is ignored
  # because the ciphertext doesn't look like valid encrypted data to Rails.
  encrypts :messages
  encrypts :last_question
  encrypts :context_numacs
  encrypts :title

  # ── Public API ──

  def self.legacy_reasoning_payload?(content)
    ChatbotAnswerSafety.provider_reasoning_payload?(content)
  end

  def self.legacy_reasoning_hidden_message(language)
    case language.to_s
    when 'fr'
      'Cette ancienne réponse a été masquée car elle pouvait contenir le raisonnement interne du modèle. Veuillez poser à nouveau la question.'
    when 'de'
      'Diese ältere Antwort wurde ausgeblendet, weil sie interne Modellüberlegungen enthalten konnte. Bitte stellen Sie die Frage erneut.'
    when 'en'
      'This older answer was hidden because it could contain internal model reasoning. Please ask the question again.'
    else
      'Dit oudere antwoord is verborgen omdat het interne modelredenering kon bevatten. Stel de vraag opnieuw.'
    end
  end

  def self.sanitize_messages_for_delivery(raw_messages, language: 'nl')
    Array(raw_messages).map do |message|
      next message unless message.respond_to?(:[])

      role = message['role'] || message[:role]
      content = message['content'] || message[:content]
      next message unless role.to_s == 'assistant' && legacy_reasoning_payload?(content)

      sanitized = message.deep_dup
      content_key = sanitized.key?('content') ? 'content' : :content
      sanitized[content_key] = legacy_reasoning_hidden_message(language)
      sanitized['legacy_reasoning_hidden'] = true
      sanitized
    end
  end

  def messages_array
    return [] if zero_knowledge?

    parsed = JSON.parse(messages || '[]')
    self.class.sanitize_messages_for_delivery(parsed, language: language)
  rescue JSON::ParserError
    []
  end

  def messages_array=(array)
    Array(array).each do |message|
      next unless message.respond_to?(:[])

      role = message['role'] || message[:role]
      content = message['content'] || message[:content]
      ChatbotAnswerSafety.validate_visible_answer!(content) if role.to_s == 'assistant'
    end
    self.messages = array.to_json
  end

  def context_numacs_array
    JSON.parse(context_numacs || '[]')
  rescue JSON::ParserError
    []
  end

  def context_numacs_array=(array)
    self.context_numacs = array.to_json
  end

  # Check if this conversation uses zero-knowledge encryption
  def zero_knowledge?
    self[:zero_knowledge] == true
  end

  # Update with client-encrypted payload (ZK mode)
  # The server stores these as opaque blobs - it cannot decrypt them.
  def update_encrypted_payload!(encrypted_messages:, encrypted_title:, message_count:, expected_revision:, key_generation:, claim_token:, numacs: [])
    unless lock_version.to_i == expected_revision.to_i && key_generation.present? &&
           (zk_key_generation.blank? || zk_key_generation == key_generation) &&
           claim_token.present? && zk_claim_token == claim_token
      raise ActiveRecord::StaleObjectError.new(self, 'update encrypted payload')
    end

    self.messages = encrypted_messages          # opaque ciphertext blob
    self.title = encrypted_title                # opaque ciphertext blob
    self.last_question = nil                    # clear residual server-readable plaintext from any prior non-ZK save
    self.message_count = message_count
    self.zero_knowledge = true
    self.zk_key_generation ||= key_generation
    self.zk_claim_token = nil
    self.zk_claimed_at = nil

    # NUMACs (article references) are NOT PII - store server-side for RAG context
    if numacs.present?
      existing = context_numacs_array
      self.context_numacs = (numacs + existing).uniq.first(10).to_json
    end

    save! # lock_version makes a concurrent snapshot write fail, never overwrite
    true
  end

  # Bind a pre-generation legacy ZK conversation to the user's current key.
  # This does not change the encrypted snapshot, so it deliberately does not
  # bump lock_version; the guarded UPDATE still requires the revision the
  # browser supplied and can only fill a NULL generation once.
  def bind_zk_key_generation!(key_generation, expected_revision:)
    return true if zk_key_generation == key_generation && lock_version.to_i == expected_revision.to_i

    updated = self.class.where(
      id: id,
      lock_version: expected_revision,
      zk_key_generation: nil
    ).update_all(
      zk_key_generation: key_generation,
      # Active Record otherwise auto-increments the locking column for
      # update_all. Binding metadata must preserve the ciphertext revision.
      lock_version: expected_revision
    )
    reload

    return true if (updated == 1 || zk_key_generation == key_generation) &&
                   zk_key_generation == key_generation &&
                   lock_version.to_i == expected_revision.to_i

    raise ActiveRecord::StaleObjectError.new(self, 'bind zero-knowledge key generation')
  end

  # Add a message to a non-ZK conversation (server-encrypted).
  # Concurrency-safe: reload + optimistic locking (lock_version) mean a
  # concurrent add_message on the same conversation retries against the fresh
  # row instead of silently overwriting the other exchange (lost update).
  def add_message(role:, content:, numacs: [])
    # ZK conversations are managed client-side - don't allow server-side writes
    if zero_knowledge?
      Rails.logger.warn('[ChatbotConversation] Attempted add_message on ZK conversation - ignored')
      return nil
    end

    attempts = 0
    begin
      # Read the LATEST committed messages right before appending. The 15-50s LLM
      # call sat between this row being loaded and now, so build on fresh state.
      reload if persisted?
      if archived?
        Rails.logger.warn('[ChatbotConversation] Attempted add_message on archived conversation - ignored')
        return nil
      end

      msgs = messages_array
      msgs << { role: role, content: content, timestamp: Time.current.iso8601 }

      # Keep only last MAX_MESSAGES
      msgs = msgs.last(MAX_MESSAGES) if msgs.length > MAX_MESSAGES

      self.messages_array = msgs
      self.message_count = msgs.length
      self.last_question = content if role == 'user'

      # Auto-generate title from first user question
      self.title = content.truncate(MAX_TITLE_LENGTH) if role == 'user' && (title.blank? || title == 'New conversation')

      # Update context NUMACs (keep unique, most recent first)
      if numacs.present?
        existing = context_numacs_array
        self.context_numacs_array = (numacs + existing).uniq.first(10)
      end

      save! # guarded by lock_version — raises StaleObjectError on a concurrent write
    rescue ActiveRecord::StaleObjectError
      # A concurrent add_message committed after our reload. Re-read and re-append.
      attempts += 1
      retry if attempts < 8
      Rails.logger.error("[ChatbotConversation] add_message gave up after #{attempts} lock retries")
      nil
    rescue ActiveRecord::RecordNotFound
      # Row deleted concurrently (e.g. cleanup_expired) between reload and save
      nil
    rescue ActiveRecord::StatementInvalid => e
      # SQLite can report a transient busy/locked error instead of reaching the
      # optimistic-lock check when two encrypted JSON writes overlap. Retry the
      # whole reload/append/save sequence so neither writer is silently lost.
      attempts += 1
      transient = e.cause.is_a?(SQLite3::BusyException) ||
                  e.message.match?(/database (?:is )?(?:busy|locked)/i) ||
                  # W7: the PostgreSQL equivalents of a transient write
                  # collision - deadlock detection and lock timeouts.
                  e.cause.class.name.match?(/DeadlockDetected|LockNotAvailable/) ||
                  e.is_a?(ActiveRecord::Deadlocked)
      if transient && attempts < 8
        sleep(0.005 * attempts)
        retry
      end

      Rails.logger.error("ChatbotConversation#add_message failed: #{e.message}")
      nil
    end
  end

  # Persist a complete standard Q&A exchange while consuming the provider
  # lease in one optimistic-lock write. A concurrent clear/revoke that fences
  # or deletes the row wins cleanly; no retry may resurrect archived history.
  def add_exchange_under_claim!(question:, answer:, numacs:, claim:)
    raise ActiveRecord::StaleObjectError.new(self, 'save claimed exchange') if zero_knowledge?

    rollback_receipt = nil
    transaction do
      reload
      unless !archived? && lock_version.to_i == claim[:claimed_revision].to_i &&
             zk_claim_token == claim[:claim_token] && zk_claimed_at.present?
        raise ActiveRecord::StaleObjectError.new(self, 'save claimed exchange')
      end

      pre_state = {
        messages: messages&.dup,
        message_count: message_count,
        last_question: last_question&.dup,
        title: title&.dup,
        context_numacs: context_numacs&.dup
      }.freeze
      exchange_timestamp = Time.current.iso8601(6)
      question_entry = { role: 'user', content: question, timestamp: exchange_timestamp }
      answer_entry = if answer.present?
                       { role: 'assistant', content: answer, timestamp: exchange_timestamp }
                     end

      msgs = messages_array
      msgs << question_entry
      msgs << answer_entry if answer_entry
      msgs = msgs.last(MAX_MESSAGES) if msgs.length > MAX_MESSAGES

      self.messages_array = msgs
      self.message_count = msgs.length
      self.last_question = question
      self.title = question.truncate(MAX_TITLE_LENGTH) if title.blank? || title == 'New conversation'
      if numacs.present?
        self.context_numacs_array = (numacs + context_numacs_array).uniq.first(10)
      end
      self.zk_claim_token = nil
      self.zk_claimed_at = nil
      save!

      # A successful history write happens before the HTTP delivery boundary.
      # Keep enough exact, request-local state to undo only this exchange if
      # render/SSE delivery later fails. The committed optimistic-lock revision
      # prevents a rollback from clobbering any concurrent history mutation.
      rollback_receipt = {
        version: 1,
        conversation_id: id,
        committed_revision: lock_version.to_i,
        delivery_entry: normalized_message_entry(answer_entry || question_entry),
        pre_state: pre_state
      }.freeze
    end
    rollback_receipt
  end

  # Undo a standard exchange that was durably written but not delivered.
  #
  # Returns:
  # - :rolled_back when the exact committed revision was restored;
  # - :absent when the paid answer is provably no longer stored;
  # - :retained when a concurrent write advanced the row while retaining it;
  # - :unknown when storage could not prove either safe outcome.
  #
  # Callers may refund only :rolled_back/:absent. A :retained/:unknown result
  # must keep the charge, because otherwise a retrievable paid answer could be
  # left in history after the balance was restored.
  def rollback_exchange_under_receipt!(receipt)
    return :unknown unless valid_exchange_rollback_receipt?(receipt)

    outcome = nil
    self.class.transaction do
      current = self.class.find_by(id: receipt[:conversation_id])
      if current.nil?
        outcome = :absent
        next
      end

      delivery_retained = current.messages_array.any? do |entry|
        normalized_message_entry(entry) == receipt[:delivery_entry]
      end
      unless delivery_retained
        outcome = :absent
        next
      end

      if current.lock_version.to_i != receipt[:committed_revision].to_i
        outcome = :retained
        next
      end

      pre_state = receipt[:pre_state]
      current.messages = pre_state[:messages]
      current.message_count = pre_state[:message_count]
      current.last_question = pre_state[:last_question]
      current.title = pre_state[:title]
      current.context_numacs = pre_state[:context_numacs]
      current.zk_claim_token = nil
      current.zk_claimed_at = nil
      current.save!
      outcome = :rolled_back
    end
    outcome || :unknown
  rescue ActiveRecord::RecordNotFound
    :absent
  rescue ActiveRecord::StaleObjectError
    persisted_delivery_outcome(receipt)
  rescue StandardError => e
    Rails.logger.error("ChatbotConversation delivery rollback failed: #{e.class}")
    :unknown
  end

  # Append a paid deep-analysis answer while consuming the same provider lease
  # used by normal chat sends. The original Q&A is already present for the
  # usual flow, so only the additional assistant turn is appended. If storage
  # consent was enabled after the original browser-only answer, bootstrap that
  # Q&A into the newly-created conversation before adding the analysis.
  def add_deep_analysis_under_claim!(question:, original_answer:, answer:, numacs:, model:, claim:)
    raise ActiveRecord::StaleObjectError.new(self, 'save claimed deep analysis') if zero_knowledge?

    transaction do
      reload
      unless !archived? && lock_version.to_i == claim[:claimed_revision].to_i &&
             zk_claim_token == claim[:claim_token] && zk_claimed_at.present?
        raise ActiveRecord::StaleObjectError.new(self, 'save claimed deep analysis')
      end

      msgs = messages_array
      if msgs.empty?
        timestamp = Time.current.iso8601
        msgs << { role: 'user', content: question, timestamp: timestamp }
        msgs << { role: 'assistant', content: original_answer, timestamp: timestamp } if original_answer.present?
      end
      msgs << {
        role: 'assistant',
        content: answer,
        timestamp: Time.current.iso8601,
        deep_analysis: true,
        deep_model: model
      }
      msgs = msgs.last(MAX_MESSAGES) if msgs.length > MAX_MESSAGES

      self.messages_array = msgs
      self.message_count = msgs.length
      self.last_question = question if last_question.blank?
      self.title = question.truncate(MAX_TITLE_LENGTH) if title.blank? || title == 'New conversation'
      if numacs.present?
        self.context_numacs_array = (numacs + context_numacs_array).uniq.first(10)
      end
      self.zk_claim_token = nil
      self.zk_claimed_at = nil
      save!
    end
    true
  end

  def normalized_message_entry(entry)
    JSON.parse(JSON.generate(entry)).slice('role', 'content', 'timestamp').freeze
  end

  def valid_exchange_rollback_receipt?(receipt)
    receipt.is_a?(Hash) &&
      receipt[:version] == 1 &&
      receipt[:conversation_id].to_i == id.to_i &&
      receipt[:committed_revision].is_a?(Integer) &&
      receipt[:delivery_entry].is_a?(Hash) &&
      receipt[:pre_state].is_a?(Hash)
  end

  def persisted_delivery_outcome(receipt)
    current = self.class.find_by(id: receipt[:conversation_id])
    return :absent unless current

    retained = current.messages_array.any? do |entry|
      normalized_message_entry(entry) == receipt[:delivery_entry]
    end
    retained ? :retained : :absent
  rescue StandardError
    :unknown
  end

  private :normalized_message_entry, :valid_exchange_rollback_receipt?, :persisted_delivery_outcome

  def expired?
    # Conversations owned by users with consent never expire
    return false if user_id.present? && user_has_consent?

    expires_at.present? && expires_at < Time.current
  end

  def extend_expiry!
    # Don't set expiry for consented users - their conversations persist
    if user_id.present? && user_has_consent?
      update!(expires_at: nil) if expires_at.present?
    else
      update!(expires_at: EXPIRY_DURATION.from_now)
    end
  rescue ActiveRecord::StaleObjectError
    # A concurrent add_message bumped lock_version. Re-read so the caller gets a
    # fresh row; expiry extension is best-effort (the next request extends it).
    reload
  rescue ActiveRecord::RecordNotFound
    nil
  end

  # List conversations for a user (metadata only - no message content).
  # Includes archived (cleared) conversations so they still appear in history.
  def self.for_user(user_id)
    where(user_id: user_id)
      .where('expires_at IS NULL OR expires_at > ?', Time.current)
      .where("message_count > 0 OR (messages IS NOT NULL AND messages != '')")
      .order(updated_at: :desc)
  end

  # The single conversation that should auto-restore on page load: the most
  # recently updated one the user hasn't cleared (archived) or let expire.
  # Lets the active conversation be tracked SERVER-SIDE — no browser storage.
  def self.active_for(user_id)
    for_user(user_id)
      .where('archived IS NULL OR archived = ?', false)
      .first
  end

  def conversation_context
    # ZK conversations: server cannot read messages
    return nil if zero_knowledge?

    # Build context string from recent messages for LLM
    msgs = messages_array.last(6) # Last 3 exchanges
    return nil if msgs.empty?

    msgs.map do |m|
      role_label = m['role'] == 'user' ? 'Gebruiker' : 'Chatbot'
      "#{role_label}: #{m['content']}"
    end.join("\n\n")
  end

  # Cleanup expired conversations (only those with an expiry set - consented user convos have nil expiry)
  def self.cleanup_expired
    where.not(expires_at: nil).where('expires_at < ?', Time.current).delete_all
  end

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end

  def set_expiry
    # Don't set expiry for consented users
    return if user_id.present? && user_has_consent?

    self.expires_at ||= EXPIRY_DURATION.from_now
  end

  # Cross-database check: look up consent in accounts DB
  # Cached per-instance to avoid repeated queries within a request
  def user_has_consent?
    return false if user_id.blank?
    return @_user_consent if defined?(@_user_consent)

    @_user_consent = begin
      user = User.find_by(id: user_id)
      user&.conversation_storage_consented? || false
    rescue StandardError => e
      Rails.logger.warn("[ChatbotConversation] Operation failed: #{e.message}")
      false
    end
  end
end
