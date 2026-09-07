import { ConversationCrypto } from "../../services/conversation_crypto"

// Zero-knowledge conversation persistence: the protocol-state recorder, the
// localStorage encrypted outbox (the ONLY localStorage in the chatbot,
// capped to the last five envelopes), envelope delivery/retry, snapshot
// push serialization and the unlock/consent prompts. Extracted verbatim
// from chatbot_controller.js (FBL-062 step 3); every method keeps its name
// and `this` receiver. test/javascript/chatbot_zk_consent_test.mjs binds
// here via the ConversationCrypto import seam - keep that import line
// byte-identical to the one the test rewrites.
export const encryptedPersistenceMethods = {
  _isZkReady() {
    return this._masterKey !== null &&
      this._validZkKeyGeneration(this._zkKeyGeneration) &&
      ConversationCrypto.isAvailable()
  },

  // Record the server's optimistic-lock state before publishing a conversation
  // token locally. ZK responses without the full protocol tuple are unsafe to
  // persist and therefore fail closed.
  _recordConversationProtocolState(data, requireClaim = false) {
    const conversationId = data?.conversation_id || data?.id
    if (!conversationId) return false

    this._zkConversationIds ||= new Set()
    if (data.zero_knowledge !== true) {
      if (requireClaim && this._isZkReady()) {
        console.error('[ZK] Server attempted to downgrade an encrypted chat response')
        return false
      }
      this._zkConversationIds.delete(conversationId)
      this._zkClaimTokens?.delete(conversationId)
      this._zkClaimExpiresAt?.delete(conversationId)
      return true
    }

    const revision = data.revision ?? data.encrypted_revision
    const currentRevision = this._conversationRevisions?.get(conversationId)
    const claimExpiresAt = Date.parse(data.claim_expires_at || '')
    if (!Number.isInteger(revision) || revision < 0 ||
        !this._validZkKeyGeneration(data.key_generation) ||
        data.key_generation !== this._zkKeyGeneration ||
        (Number.isInteger(currentRevision) && revision < currentRevision) ||
        (requireClaim && (!/^[0-9a-f]{64}$/.test(data.claim_token || '') ||
          !Number.isFinite(claimExpiresAt) || claimExpiresAt <= Date.now()))) {
      console.error('[ZK] Server returned incomplete or mismatched conversation state')
      return false
    }

    this._conversationRevisions ||= new Map()
    this._conversationRevisions.set(conversationId, revision)
    this._zkConversationIds.add(conversationId)
    this._zkClaimTokens ||= new Map()
    this._zkClaimExpiresAt ||= new Map()
    if (requireClaim) {
      this._zkClaimTokens.set(conversationId, data.claim_token)
      this._zkClaimExpiresAt.set(conversationId, claimExpiresAt)
    }
    return true
  },

  _encryptedOutboxStorageKey() {
    const host = globalThis.location?.hostname || 'wetwijzer'
    return `wetwijzer_zk_encrypted_outbox_v1:${host}`
  },

  _readEncryptedOutbox() {
    if (typeof globalThis.localStorage === 'undefined') return []

    const key = this._encryptedOutboxStorageKey()
    try {
      const parsed = JSON.parse(globalThis.localStorage.getItem(key) || '[]')
      if (!Array.isArray(parsed)) {
        globalThis.localStorage.removeItem(key)
        return []
      }
      const now = Date.now()
      const valid = parsed.filter(entry =>
        entry && typeof entry === 'object' &&
        typeof entry.conversationId === 'string' &&
        /^[A-Za-z0-9_-]{16,128}$/.test(entry.conversationId) &&
        typeof entry.encryptedMessages === 'string' &&
        typeof entry.encryptedTitle === 'string' &&
        Number.isInteger(entry.messageCount) && entry.messageCount > 0 &&
        Number.isInteger(entry.expectedRevision) && entry.expectedRevision >= 0 &&
        this._validZkKeyGeneration(entry.keyGeneration) &&
        /^[0-9a-f]{64}$/.test(entry.claimToken || '') &&
        Number.isInteger(entry.createdAt) && entry.createdAt <= now &&
        Number.isInteger(entry.expiresAt) && entry.expiresAt > now &&
        entry.createdAt < entry.expiresAt
      ).slice(-5)
      if (valid.length !== parsed.length) {
        if (valid.length === 0) globalThis.localStorage.removeItem(key)
        else globalThis.localStorage.setItem(key, JSON.stringify(valid))
      }
      return valid
    } catch (_) {
      // Corrupt or unreadable retry state can never be sent safely. Make the
      // documented cleanup guarantee fail closed instead of reparsing the same
      // invalid bytes on every app start. Storage removal itself can fail in a
      // locked-down browser, so keep that secondary failure contained.
      try { globalThis.localStorage.removeItem(key) } catch (_) { /* unavailable */ }
      return []
    }
  },

  _writeEncryptedOutbox(entries) {
    if (typeof globalThis.localStorage === 'undefined') return false

    try {
      const key = this._encryptedOutboxStorageKey()
      if (entries.length === 0) globalThis.localStorage.removeItem(key)
      else globalThis.localStorage.setItem(key, JSON.stringify(entries.slice(-5)))
      return true
    } catch (error) {
      console.warn('[ZK] Ciphertext outbox is unavailable:', error)
      return false
    }
  },

  _rememberEncryptedOutbox(envelope) {
    const entries = this._readEncryptedOutbox().filter(entry =>
      entry.conversationId !== envelope.conversationId &&
      entry.claimToken !== envelope.claimToken
    )
    entries.push(envelope)
    const stored = this._writeEncryptedOutbox(entries)
    if (stored && Number.isInteger(envelope.expiresAt)) {
      const delay = Math.max(0, envelope.expiresAt - Date.now()) + 25
      const timer = globalThis.setTimeout?.(
        () => this._forgetEncryptedOutbox(envelope.conversationId, envelope.claimToken),
        delay
      )
      // Node's regression runner must not stay alive for a browser expiry timer.
      timer?.unref?.()
    }
    return stored
  },

  _forgetEncryptedOutbox(conversationId, claimToken) {
    const entries = this._readEncryptedOutbox().filter(entry =>
      entry.conversationId !== conversationId || entry.claimToken !== claimToken
    )
    this._writeEncryptedOutbox(entries)
  },

  _clearEncryptedOutbox() {
    return this._writeEncryptedOutbox([])
  },

  async _deliverEncryptedEnvelope(envelope) {
    if (!Number.isInteger(envelope.expiresAt) || envelope.expiresAt <= Date.now()) {
      this._forgetEncryptedOutbox(envelope.conversationId, envelope.claimToken)
      const error = new Error('Encrypted conversation save failed: claim expired')
      error.status = 409
      error.serverError = 'zero_knowledge_state_conflict'
      throw error
    }

    const response = await fetch(`/api/chatbot/conversations/${encodeURIComponent(envelope.conversationId)}/encrypted`, {
      method: 'PATCH',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': this.csrfToken
      },
      body: JSON.stringify({
        encrypted_messages: envelope.encryptedMessages,
        encrypted_title: envelope.encryptedTitle,
        message_count: envelope.messageCount,
        expected_revision: envelope.expectedRevision,
        key_generation: envelope.keyGeneration,
        claim_token: envelope.claimToken
      })
    })

    let result = null
    try { result = await response.json() } catch (_) { /* validated below */ }
    const revision = result?.revision ?? result?.encrypted_revision
    if (!response.ok || result?.success !== true || result?.zero_knowledge !== true ||
        !Number.isInteger(revision) || revision !== envelope.expectedRevision + 1 ||
        result?.key_generation !== envelope.keyGeneration) {
      const detail = result?.error || `HTTP ${response.status || 'error'}`
      const error = new Error(`Encrypted conversation save failed: ${detail}`)
      error.status = response.status
      error.serverError = result?.error
      throw error
    }

    this._conversationRevisions ||= new Map()
    this._conversationRevisions.set(envelope.conversationId, revision)
    this._zkClaimTokens?.delete(envelope.conversationId)
    this._zkClaimExpiresAt?.delete(envelope.conversationId)
    this._forgetEncryptedOutbox(envelope.conversationId, envelope.claimToken)
    return true
  },

  async _retryEncryptedOutbox() {
    if (!this._validZkKeyGeneration(this._zkKeyGeneration)) return false

    const entries = this._readEncryptedOutbox()
      .filter(entry => entry.keyGeneration === this._zkKeyGeneration)
    let recovered = false
    for (const envelope of entries) {
      try {
        await this._deliverEncryptedEnvelope(envelope)
        recovered = true
      } catch (error) {
        // A stale/mismatched claim cannot ever be replayed safely. Auth, CSRF
        // and transient failures retain ciphertext for a later reload.
        if ([404, 409, 410].includes(error?.status)) {
          this._forgetEncryptedOutbox(envelope.conversationId, envelope.claimToken)
        }
      }
    }
    return recovered
  },

  // Encrypt and persist one immutable snapshot. The revision is read just
  // before PATCH so a preceding save for the same conversation can advance it.
  async _persistEncryptedSnapshot(snapshot) {
    if (!/^[0-9a-f]{64}$/.test(snapshot.claimToken || '')) {
      throw new Error('Encrypted conversation save blocked: missing claim token')
    }
    if (!Number.isInteger(snapshot.claimExpiresAt) || snapshot.claimExpiresAt <= Date.now()) {
      throw new Error('Encrypted conversation save blocked: claim expired')
    }
    const [encryptedMessages, encryptedTitle] = await Promise.all([
      ConversationCrypto.encryptPayload(snapshot.messages, snapshot.masterKey),
      ConversationCrypto.encryptPayload(snapshot.title, snapshot.masterKey)
    ])
    const expectedRevision = this._conversationRevisions?.get(snapshot.conversationId)
    if (!Number.isInteger(expectedRevision) || expectedRevision < 0) {
      throw new Error('Encrypted conversation save blocked: missing revision')
    }
    if (snapshot.claimExpiresAt <= Date.now()) {
      throw new Error('Encrypted conversation save blocked: claim expired')
    }

    const envelope = {
      conversationId: snapshot.conversationId,
      encryptedMessages,
      encryptedTitle,
      messageCount: snapshot.messages.length,
      expectedRevision,
      keyGeneration: snapshot.keyGeneration,
      claimToken: snapshot.claimToken,
      createdAt: Date.now(),
      expiresAt: snapshot.claimExpiresAt
    }
    this._rememberEncryptedOutbox(envelope)
    return this._deliverEncryptedEnvelope(envelope)
  },

  // Drain one conversation independently. Requests for that conversation are
  // serialized and queued snapshots coalesce to the newest complete history;
  // a failure in conversation A never rejects callers saving conversation B.
  async _drainEncryptedPushState(conversationId, state) {
    while (state.pending) {
      const snapshot = state.pending
      state.pending = null

      try {
        await this._persistEncryptedSnapshot(snapshot)
        snapshot.waiters.forEach(waiter => waiter.resolve(true))
        if (state.pending?.claimToken === snapshot.claimToken) {
          const redundant = state.pending
          state.pending = null
          if (JSON.stringify(redundant.messages) === JSON.stringify(snapshot.messages)) {
            redundant.waiters.forEach(waiter => waiter.resolve(true))
          } else {
            const error = new Error('Encrypted conversation claim was already committed')
            redundant.waiters.forEach(waiter => waiter.reject(error))
          }
        }
      } catch (error) {
        if (state.pending) {
          state.pending.waiters.unshift(...snapshot.waiters)
        } else {
          snapshot.waiters.forEach(waiter => waiter.reject(error))
        }
      }
    }

    // No await occurs between observing an empty queue and clearing `running`,
    // so another call cannot fall into a completion-gap race on this JS turn.
    state.running = false
    if (!state.pending && this._zkPushStates?.get(conversationId) === state) {
      this._zkPushStates.delete(conversationId)
    }
  },

  // Queue a client-encrypted history snapshot for persistence. Each caller's
  // promise follows its own conversation and, when coalesced, the newer save
  // that subsumed it.
  _pushEncryptedConversation(explicitSnapshot = null) {
    const conversationId = explicitSnapshot?.conversationId || this.conversationId
    const masterKey = explicitSnapshot?.masterKey || this._masterKey
    const keyGeneration = explicitSnapshot?.keyGeneration || this._zkKeyGeneration
    const claimToken = explicitSnapshot?.claimToken || this._zkClaimTokens?.get(conversationId)
    const claimExpiresAt = explicitSnapshot?.claimExpiresAt || this._zkClaimExpiresAt?.get(conversationId)
    const history = explicitSnapshot?.messages || this.conversationHistory

    if (!masterKey || !this._validZkKeyGeneration(keyGeneration) || !ConversationCrypto.isAvailable()) {
      return explicitSnapshot
        ? Promise.reject(new Error('Encrypted conversation save blocked: invalid key state'))
        : false
    }
    if (!conversationId) {
      return Promise.reject(new Error('Encrypted conversation save blocked: missing conversation id'))
    }
    if (!Array.isArray(history) || history.length === 0) return false

    // Deep-copy the JSON-safe history before any asynchronous encryption. A
    // subsequent answer mutates the live history while this save is waiting.
    const messages = JSON.parse(JSON.stringify(history))
    const firstUserMsg = messages.find(message => message.role === 'user')
    const snapshot = {
      conversationId,
      masterKey,
      keyGeneration,
      claimToken,
      claimExpiresAt,
      messages,
      title: firstUserMsg?.content?.substring(0, 100) || 'Conversation',
      waiters: []
    }

    this._zkPushStates ||= new Map()
    let state = this._zkPushStates.get(snapshot.conversationId)
    if (!state) {
      state = { running: false, pending: null }
      this._zkPushStates.set(snapshot.conversationId, state)
    }

    const completion = new Promise((resolve, reject) => {
      snapshot.waiters.push({ resolve, reject })
    })
    state.completion = completion
    if (state.pending) snapshot.waiters.unshift(...state.pending.waiters)
    state.pending = snapshot

    if (!state.running) {
      state.running = true
      // The drain catches individual snapshot failures and settles every
      // waiter, so launching it without awaiting cannot leak a rejection.
      void this._drainEncryptedPushState(snapshot.conversationId, state)
    }

    return completion
  },

  // Show a small inline password prompt to unlock ZK encryption.
  // Renders into the history sidebar list; if the sidebar hasn't been opened
  // yet this no-ops and renderHistoryList() shows the prompt on first open.
  _showZkUnlockPrompt() {
    const container = this.element.querySelector('.chat-history-list')
    if (!container) return

    const _t = (map) => map[this.languageValue] || map.nl
    container.innerHTML = `
      <div class="p-4 text-center">
        <div class="w-10 h-10 mx-auto mb-2 rounded-full bg-amber-100 dark:bg-amber-900/40 flex items-center justify-center">
          <svg class="w-5 h-5 text-amber-600 dark:text-amber-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"/>
          </svg>
        </div>
        <p class="text-xs text-gray-600 dark:text-gray-400 mb-3">
          ${_t({
            nl: 'Voer uw wachtwoord in om opgeslagen gesprekken te ontsleutelen',
            fr: 'Entrez votre mot de passe pour déchiffrer les conversations',
            de: 'Geben Sie Ihr Passwort ein, um gespeicherte Gespräche zu entschlüsseln',
            en: 'Enter your password to decrypt saved conversations'
          })}
        </p>
        <form id="zk-unlock-form" class="flex gap-2">
          <input type="password" id="zk-unlock-password"
                 class="flex-1 text-xs px-3 py-2 rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:outline-none focus:ring-2 focus:ring-blue-500"
                 placeholder="${_t({ nl: 'Wachtwoord', fr: 'Mot de passe', de: 'Passwort', en: 'Password' })}"
                 autocomplete="current-password" />
          <button type="submit"
                  class="px-3 py-2 text-xs font-medium rounded-lg bg-blue-600 text-white hover:bg-blue-700 transition-colors">
            🔓
          </button>
        </form>
        <p id="zk-unlock-error" class="hidden mt-2 text-xs text-red-500"></p>
        <button type="button"
                data-action="click->chatbot#disableAndDeleteHistory"
                data-history-disable-control
                class="mt-3 block w-full text-[10px] font-medium text-red-600 dark:text-red-400 hover:underline">
          ${_t({ nl: 'Opslagwachtwoord vergeten? Verwijder alle opgeslagen geschiedenis', fr: 'Mot de passe de stockage oublié ? Supprimer tout l’historique enregistré', de: 'Speicherpasswort vergessen? Gesamten gespeicherten Verlauf löschen', en: 'Forgot the storage password? Delete all saved history' })}
        </button>
        <button type="button" id="zk-skip-unlock"
                 class="mt-2 text-[10px] text-gray-400 hover:text-gray-600 dark:hover:text-(--accent-400)">
          ${_t({ nl: 'Nu niet', fr: 'Pas maintenant', de: 'Nicht jetzt', en: 'Not now' })}
        </button>
      </div>
    `

    // Handle form submit
    const form = document.getElementById('zk-unlock-form')
    form?.addEventListener('submit', async (e) => {
      e.preventDefault()
      const passwordInput = document.getElementById('zk-unlock-password')
      const errorEl = document.getElementById('zk-unlock-error')
      const password = passwordInput?.value

      if (!password) return

      const success = await this._unlockMasterKey(password)
      if (success) {
        this._showToast(
          { nl: '🔓 Gesprekken ontsleuteld', fr: '🔓 Conversations déchiffrées', de: '🔓 Gespräche entschlüsselt', en: '🔓 Conversations decrypted' }[this.languageValue] || '🔓 Gesprekken ontsleuteld',
          'success'
        )
        this.renderHistoryList()
        // Now that the master key is unlocked, the active ZK conversation can
        // be decrypted and rendered into the shared log.
        this._restoreActiveConversation()
      } else {
        if (errorEl) {
          errorEl.textContent = { nl: 'Onjuist wachtwoord', fr: 'Mot de passe incorrect', de: 'Falsches Passwort', en: 'Incorrect password' }[this.languageValue] || 'Onjuist wachtwoord'
          errorEl.classList.remove('hidden')
        }
        passwordInput?.focus()
      }
    })

    // Closing the prompt must not discard wrapped key material. Reopening the
    // history sidebar therefore always lets the user retry the password.
    document.getElementById('zk-skip-unlock')?.addEventListener('click', () => {
      this.element.querySelector('.chat-history-sidebar')?.classList.add('hidden')
    })
  },

  // ────────────────────────────────────────────────────────────
  //  GDPR Consent Dialog (ZK-aware)
  // ────────────────────────────────────────────────────────────

  _checkConsentBeforeChat() {
    if (!this._isLoggedIn()) return // Anonymous - no consent needed
    if (this._shouldPersist()) return // Already consented
    if (this._consentDialogShown) return // Only show once per session

    this._consentDialogShown = true
    this.showConsentDialog()
  }
}
