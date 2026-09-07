/**
 * Chatbot Controller - History Mixin
 *
 * Methods extracted from chatbot_controller.js for maintainability.
 * Mixed into the controller prototype - all methods use 'this' as normal.
 */

import { ConversationCrypto } from "../../services/conversation_crypto"

export const historyMethods = {
  // NOTE: every method in this object literal must be defined exactly once —
  // JS object literal property overwriting means only the LAST definition
  // survives (this silently killed renderHistoryList/getConversationHistory
  // duplicates in the past).

  // Toggle history sidebar visibility

  toggleHistory() {
    let sidebar = this.element.querySelector(".chat-history-sidebar")

    if (!sidebar) {
      sidebar = this._createHistorySidebar()
      // Insert before the messages area
      const widget = this.hasWidgetTarget ? this.widgetTarget : this.element
      widget.insertBefore(sidebar, widget.firstChild)
    }

    sidebar.classList.toggle("hidden")
    if (!sidebar.classList.contains("hidden")) {
      this.renderHistoryList()
    }
  },

  // Update consent flag (mirrors server state onto the auth-state element)

  _setConsentState(consented) {
    const el = document.getElementById('chatbot-auth-state')
    if (el) el.dataset.consent = consented ? 'true' : 'false'
    this._hasConsent = consented
    this._syncHistoryConsentControls?.()
  },

  // Check if we should persist conversations server-side

  async getConversationHistory() {
    if (!this._isLoggedIn()) return []

    try {
      const response = await fetch('/api/chatbot/conversations')
      if (!response.ok) return []
      const data = await response.json()

      // Update consent state from server response
      if (data.consent !== undefined) {
        this._setConsentState(data.consent)
      }

      return data.conversations || []
    } catch (e) {
      console.warn('Failed to fetch conversation history:', e)
      return []
    }
  },

  // Save current conversation to history - no-op since server auto-saves

  saveToHistory() {
    // Server already persists via add_message() on each Q&A exchange
  },

  // Load a conversation from server by token

  async loadFromHistory(event) {
    const id = event.currentTarget?.dataset?.conversationHistoryId
    if (!id) return

    // A provider result, typewriter animation, or encrypted CAS save may own a
    // live ZK lease for the current conversation. Switching history would
    // invalidate the response epoch and strand that paid answer until the
    // server lease expires, so keep the current conversation selected until
    // the complete send-and-save operation settles.
    const activeId = this.conversationId
    const activePush = activeId ? this._zkPushStates?.get(activeId) : null
    const activeClaim = activeId && this._zkClaimTokens?.has(activeId)
    if (this._sendInProgress || this._animatingMessage || this.loadingValue ||
        activeClaim || activePush?.running || activePush?.pending) {
      this._showToast?.(
        { nl: 'Wacht tot het huidige antwoord veilig is opgeslagen.', fr: "Attendez que la réponse actuelle soit enregistrée en toute sécurité.", de: 'Warten Sie, bis die aktuelle Antwort sicher gespeichert ist.', en: 'Wait until the current answer is safely saved.' }[this.languageValue] || 'Wacht tot het huidige antwoord veilig is opgeslagen.',
        'error'
      )
      return
    }

    // A late result/typewriter from the previous conversation must never land
    // in the history entry we are about to install. The epoch also lets the
    // live response path stop work that had already moved beyond fetch().
    const contextEpoch = (this._conversationContextEpoch || 0) + 1
    this._conversationContextEpoch = contextEpoch
    if (this.abortController) {
      this._userAborted = true
      this.abortController.abort()
      this.abortController = null
    }
    this._finishLoading?.()

    // If this controller is still saving the selected conversation, wait for
    // that CAS write before fetching it. Otherwise a slow decrypt could install
    // the pre-save ciphertext while the revision map already points past it.
    const pendingSave = this._zkPushStates?.get(id)?.completion
    if (pendingSave) {
      try {
        await pendingSave
      } catch (_) {
        this._showToast?.(
          { nl: 'Het beveiligde gesprek wordt nog niet veilig opgeslagen. Probeer opnieuw.', fr: "La conversation sécurisée n'est pas encore enregistrée. Réessayez.", de: 'Das sichere Gespräch wurde noch nicht gespeichert. Versuchen Sie es erneut.', en: 'The secure conversation has not been saved yet. Try again.' }[this.languageValue] || 'Het beveiligde gesprek wordt nog niet veilig opgeslagen. Probeer opnieuw.',
          'error'
        )
        return
      }
      if (contextEpoch !== (this._conversationContextEpoch || 0)) return
    }

    try {
      const response = await fetch(`/api/chatbot/conversations/${id}`)
      if (!response.ok) return

      const data = await response.json()
      if (contextEpoch !== (this._conversationContextEpoch || 0)) return

      // ZK history is fail-closed. Never fall back to the server's empty
      // `messages` shape: doing so would install an empty, writable snapshot
      // and the next save could overwrite valid ciphertext.
      let messages = data.messages || []
      if (data.zero_knowledge) {
        if (!data.encrypted_messages || !this._isZkReady()) {
          this._showZkUnlockPrompt?.()
          this._showToast?.(
            { nl: 'Ontgrendel eerst uw beveiligde geschiedenis.', fr: "Déverrouillez d'abord votre historique sécurisé.", de: 'Entsperren Sie zuerst Ihren sicheren Verlauf.', en: 'Unlock your secure history first.' }[this.languageValue] || 'Ontgrendel eerst uw beveiligde geschiedenis.',
            'error'
          )
          return
        }

        try {
          messages = await ConversationCrypto.decryptPayload(
            data.encrypted_messages,
            this._masterKey
          )
        } catch (decryptErr) {
          console.warn('[ZK] Failed to decrypt conversation:', decryptErr)
          this._showToast?.(
            { nl: 'Dit beveiligde gesprek kon niet worden ontsleuteld.', fr: "Cette conversation sécurisée n'a pas pu être déchiffrée.", de: 'Dieses sichere Gespräch konnte nicht entschlüsselt werden.', en: 'This secure conversation could not be decrypted.' }[this.languageValue] || 'Dit beveiligde gesprek kon niet worden ontsleuteld.',
            'error'
          )
          return
        }

        const revision = data.revision ?? data.encrypted_revision
        const knownRevision = this._conversationRevisions?.get(data.id)
        if (!Array.isArray(messages) || messages.length === 0 ||
            !Number.isInteger(revision) || revision < 0 ||
            (Number.isInteger(knownRevision) && revision < knownRevision) ||
            !this._validZkKeyGeneration(data.key_generation) ||
            (this._zkKeyGeneration && this._zkKeyGeneration !== data.key_generation)) {
          this._showToast?.(
            { nl: 'De beveiligde gespreksgegevens zijn ongeldig of verouderd.', fr: 'Les données sécurisées de la conversation sont invalides ou obsolètes.', de: 'Die sicheren Gesprächsdaten sind ungültig oder veraltet.', en: 'The secure conversation data is invalid or stale.' }[this.languageValue] || 'De beveiligde gespreksgegevens zijn ongeldig of verouderd.',
            'error'
          )
          return
        }
        data.revision = revision
      }

      if (contextEpoch !== (this._conversationContextEpoch || 0)) return
      if (data.zero_knowledge) {
        const latestKnownRevision = this._conversationRevisions?.get(data.id)
        if (Number.isInteger(latestKnownRevision) && data.revision < latestKnownRevision) return
      }

      const restoredMessages = this._sanitizeRestoredMessages
        ? this._sanitizeRestoredMessages(messages)
        : messages

      if (data.zero_knowledge && (!Array.isArray(restoredMessages) || restoredMessages.length === 0)) return

      // Publish the conversation and its protocol state only after successful
      // decryption/sanitization. Until this point the prior conversation stays
      // intact and cannot accidentally be saved under the selected token.
      this.conversationHistory = restoredMessages
      // Archived rows are immutable history. They remain useful as context,
      // but the next question must create a fresh active branch instead of
      // silently writing back into the archived row.
      this.conversationId = data.archived === true ? null : data.id
      this.messageCount = data.message_count || 0
      if (Number.isInteger(data.revision) && data.revision >= 0) {
        this._conversationRevisions ||= new Map()
        this._conversationRevisions.set(data.id, data.revision)
      }
      this._zkConversationIds ||= new Set()
      if (data.zero_knowledge) {
        this._zkKeyGeneration = data.key_generation
        this._zkConversationIds.add(data.id)
      } else {
        this._zkConversationIds.delete(data.id)
      }

      // Re-render messages from data
      if (this.hasMessagesTarget && this.conversationHistory.length > 0) {
        this._renderMessagesFromData(this.conversationHistory)
        this.scrollToBottom()
      }

      if (data.archived === true) {
        this._showToast?.(
          { nl: 'Gearchiveerd gesprek geladen als context. Uw volgende vraag start een nieuw gesprek.', fr: 'Conversation archivée chargée comme contexte. Votre prochaine question démarrera une nouvelle conversation.', de: 'Archiviertes Gespräch als Kontext geladen. Ihre nächste Frage startet ein neues Gespräch.', en: 'Archived conversation loaded as context. Your next question will start a new conversation.' }[this.languageValue] || 'Gearchiveerd gesprek geladen als context. Uw volgende vraag start een nieuw gesprek.',
          'info'
        )
      }

      // Close history sidebar
      this.toggleHistory()
    } catch (e) {
      console.error('Failed to load conversation:', e)
    }
  },

  // Re-render messages from conversation data (replaces HTML restore)

  async _resetConversationAfterArchive(commitReset) {
    // Deep analysis has no server-side conversation lease, so aborting it after
    // Clear/New can still leave a charged answer that the browser never shows.
    // Keep the current conversation intact until that paid result is consumed.
    if (this._deepAnalysisInProgress) {
      this._showToast?.(
        {
          nl: 'Wacht tot de diepere analyse klaar is voordat u een nieuw gesprek start.',
          fr: "Attendez la fin de l'analyse approfondie avant de démarrer une nouvelle conversation.",
          de: 'Warten Sie, bis die tiefere Analyse abgeschlossen ist, bevor Sie eine neue Unterhaltung beginnen.',
          en: 'Wait for the deep analysis to finish before starting a new conversation.'
        }[this.languageValue] || 'Wacht tot de diepere analyse klaar is voordat u een nieuw gesprek start.',
        'error'
      )
      return false
    }

    if (this._conversationResetInFlight) return this._conversationResetInFlight

    const reset = (async () => {
      // The server archive/cancel is the commit point. Until it succeeds, keep
      // the response epoch, request and UI untouched so an in-flight paid
      // answer can still finish normally when the network archive fails.
      if (!await this._archiveActiveConversation()) return false

      this._conversationContextEpoch = (this._conversationContextEpoch || 0) + 1
      if (this.abortController) {
        this._userAborted = true
        this.abortController.abort()
        this.abortController = null
      }
      this._finishLoading?.()
      await commitReset()
      return true
    })()

    this._conversationResetInFlight = reset
    try {
      return await reset
    } finally {
      if (this._conversationResetInFlight === reset) this._conversationResetInFlight = null
    }
  },

  async newConversation() {
    return this._resetConversationAfterArchive(async () => {
      this.conversationHistory = []
      this.conversationId = null
      this.messageCount = 0
      if (this.hasMessagesTarget) {
        this.messagesTarget.innerHTML = ''
        this.addWelcomeMessage()
        // Reset scroll position to top so welcome message is visible
        this.messagesTarget.scrollTop = 0
      }
      this._clearSavedConversation()

      // Scroll the chatbot area into view
      this.element.scrollIntoView({ behavior: 'smooth', block: 'start' })

      // Close history sidebar if open
      const sidebar = this.element.querySelector(".chat-history-sidebar")
      if (sidebar && !sidebar.classList.contains("hidden")) {
        sidebar.classList.add("hidden")
      }

      if (this.hasInputTarget) this.inputTarget.focus()
    })
  },

  // Delete a conversation from server

  async deleteFromHistory(event) {
    event?.stopPropagation()
    const id = event.currentTarget?.dataset?.conversationHistoryId
    if (!id) return

    try {
      const response = await fetch(`/api/chatbot/conversations/${encodeURIComponent(id)}`, {
        method: 'DELETE',
        headers: { 'X-CSRF-Token': this.csrfToken }
      })
      let result = null
      try { result = await response.json() } catch (_) { /* validated below */ }
      if (!response.ok || result?.success !== true) {
        throw new Error(result?.error || `HTTP ${response.status || 'error'}`)
      }

      this._conversationRevisions?.delete(id)
      this._zkClaimTokens?.delete(id)
      this._zkClaimExpiresAt?.delete(id)
      this._zkConversationIds?.delete(id)
      this._zkPushStates?.delete(id)

      // Deleting the selected row must not leave a stale token/revision that
      // makes the next ZK question target a conversation which no longer exists.
      if (this.conversationId === id) {
        this._conversationContextEpoch = (this._conversationContextEpoch || 0) + 1
        this.conversationHistory = []
        this.conversationId = null
        this.messageCount = 0
        this._clearSavedConversation?.()
        if (this.hasMessagesTarget) {
          this.messagesTarget.innerHTML = ''
          this.messagesTarget.classList?.add('chatbot-messages--empty')
          this.addWelcomeMessage?.()
          this.messagesTarget.scrollTop = 0
        }
      }

      await this.renderHistoryList()
      return true
    } catch (e) {
      console.error('Delete conversation failed:', e)
      this._showToast?.(
        { nl: 'Het gesprek kon niet worden verwijderd. Probeer opnieuw.', fr: "La conversation n'a pas pu être supprimée. Réessayez.", de: 'Das Gespräch konnte nicht gelöscht werden. Versuchen Sie es erneut.', en: 'The conversation could not be deleted. Please try again.' }[this.languageValue] || 'Het gesprek kon niet worden verwijderd. Probeer opnieuw.',
        'error'
      )
      return false
    }
  },

  _syncHistoryConsentControls() {
    const enabled = Boolean(this._hasConsent)
    this.element?.querySelectorAll?.('[data-history-storage-actions]').forEach(element => {
      element.classList.toggle('hidden', !enabled)
    })
  },

  _conversationStorageMutationInFlight() {
    const pushRunning = Array.from(this._zkPushStates?.values?.() || [])
      .some(state => state?.running || state?.pending)
    return Boolean(
      this.loadingValue || this._sendInProgress || this._animatingMessage ||
      this._encryptedPersistenceInFlight || pushRunning
    )
  },

  _setHistoryRevocationBusy(busy) {
    this.element?.querySelectorAll?.('[data-history-disable-control]').forEach(button => {
      button.disabled = busy
      if (busy) button.setAttribute('aria-busy', 'true')
      else button.removeAttribute('aria-busy')
    })
  },

  _resetConversationStorageClientState() {
    this._conversationContextEpoch = (this._conversationContextEpoch || 0) + 1
    if (this.abortController) {
      this._userAborted = true
      this.abortController.abort()
      this.abortController = null
    }
    this._finishLoading?.()

    this._masterKey = null
    this._zkKeyMaterial = null
    this._zkKeyGeneration = null
    this._zkConversationIds?.clear()
    this._zkClaimTokens?.clear()
    this._zkClaimExpiresAt?.clear()
    this._conversationRevisions?.clear()
    this._zkPushStates?.clear()
    this._clearEncryptedOutbox?.()
    this._encryptedPersistenceInFlight = null
    this._consentDialogShown = false
    this._setConsentState(false)

    this.conversationHistory = []
    this.conversationId = null
    this.messageCount = 0
    this._currentLawNumac = null
    this._privacyFooterShown = false
    this._clearSavedConversation?.()

    if (this.hasMessagesTarget) {
      this.messagesTarget.innerHTML = ''
      this.messagesTarget.classList?.add('chatbot-messages--empty')
      this.addWelcomeMessage?.()
      this.messagesTarget.scrollTop = 0
    }
  },

  // Explicit, destructive GDPR consent withdrawal. This is also the recovery
  // path when a zero-knowledge storage password is lost: no password is needed
  // to delete ciphertext owned by the authenticated account.
  async disableAndDeleteHistory(event) {
    event?.preventDefault?.()
    event?.stopPropagation?.()
    if (this._historyRevocationInFlight) return this._historyRevocationInFlight
    if (!this._shouldPersist()) return false

    if (this._conversationStorageMutationInFlight()) {
      this._showToast?.(
        { nl: 'Wacht tot het huidige antwoord veilig is opgeslagen.', fr: "Attendez que la réponse actuelle soit enregistrée en toute sécurité.", de: 'Warten Sie, bis die aktuelle Antwort sicher gespeichert ist.', en: 'Wait until the current answer is safely saved.' }[this.languageValue] || 'Wacht tot het huidige antwoord veilig is opgeslagen.',
        'error'
      )
      return false
    }

    const warning = {
      nl: 'Dit verwijdert permanent al uw opgeslagen gesprekken en schakelt geschiedenis uit. Een vergeten opslagwachtwoord kan niet worden hersteld. Doorgaan?',
      fr: "Cette action supprime définitivement toutes vos conversations enregistrées et désactive l’historique. Un mot de passe de stockage oublié ne peut pas être récupéré. Continuer ?",
      de: 'Dadurch werden alle gespeicherten Gespräche dauerhaft gelöscht und der Verlauf deaktiviert. Ein vergessenes Speicherpasswort kann nicht wiederhergestellt werden. Fortfahren?',
      en: 'This permanently deletes all saved conversations and disables history. A forgotten storage password cannot be recovered. Continue?'
    }[this.languageValue] || 'Dit verwijdert permanent al uw opgeslagen gesprekken en schakelt geschiedenis uit. Doorgaan?'
    if (!window.confirm(warning)) return false

    const request = (async () => {
      this._setHistoryRevocationBusy(true)
      try {
        const response = await fetch('/api/chatbot/conversations/consent', {
          method: 'DELETE',
          headers: { 'X-CSRF-Token': this.csrfToken }
        })
        let result = null
        try { result = await response.json() } catch (_) { /* validated below */ }
        if (!response.ok || result?.success !== true) {
          throw new Error(result?.error || `HTTP ${response.status || 'error'}`)
        }

        // Destructive local reset happens only after the server explicitly
        // confirms success. A timeout/HTML response never destroys the key.
        this._resetConversationStorageClientState()
        this._showToast?.(
          { nl: 'Gespreksgeschiedenis uitgeschakeld en verwijderd.', fr: 'Historique désactivé et supprimé.', de: 'Gesprächsverlauf deaktiviert und gelöscht.', en: 'Conversation history disabled and deleted.' }[this.languageValue] || 'Gespreksgeschiedenis uitgeschakeld en verwijderd.',
          'success'
        )
        await this.renderHistoryList?.()
        return true
      } catch (error) {
        console.error('[History] Consent withdrawal failed:', error)
        this._showToast?.(
          { nl: 'Geschiedenis kon niet veilig worden verwijderd. Uw instellingen zijn niet gewijzigd.', fr: "L’historique n’a pas pu être supprimé en toute sécurité. Vos réglages n’ont pas changé.", de: 'Der Verlauf konnte nicht sicher gelöscht werden. Ihre Einstellungen wurden nicht geändert.', en: 'History could not be deleted safely. Your settings were not changed.' }[this.languageValue] || 'Geschiedenis kon niet veilig worden verwijderd. Uw instellingen zijn niet gewijzigd.',
          'error'
        )
        return false
      } finally {
        this._setHistoryRevocationBusy(false)
      }
    })()

    this._historyRevocationInFlight = request
    try {
      return await request
    } finally {
      if (this._historyRevocationInFlight === request) this._historyRevocationInFlight = null
    }
  },

  // Render conversation history in sidebar (fetches from server)

  async renderHistoryList() {
    // The list container lives inside the lazily-created history sidebar
    const container = this.element.querySelector('.chat-history-list')
    if (!container) return

    if (!this._isLoggedIn()) {
      const _t = (map) => map[this.languageValue] || map.nl
      container.innerHTML = `
        <div class="p-4 text-center text-sm text-gray-500 dark:text-gray-400">
          <svg class="w-8 h-8 mx-auto mb-2 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"/>
          </svg>
          ${_t({
            nl: 'Log in om uw gespreksgeschiedenis op te slaan',
            fr: 'Connectez-vous pour sauvegarder votre historique',
            de: 'Melden Sie sich an, um Ihren Verlauf zu speichern',
            en: 'Log in to save your conversation history'
          })}
          <a href="/login?redirect_to=/chatbot" class="block mt-2 text-blue-500 hover:text-blue-600 font-medium">${_t({ nl: 'Inloggen', fr: 'Se connecter', de: 'Anmelden', en: 'Log in' })}</a>
        </div>
      `
      return
    }

    // ZK-encrypted history fetched but master key not yet unlocked:
    // show the password prompt instead of an undecryptable list
    if (this._zkKeyMaterial && !this._masterKey) {
      this._showZkUnlockPrompt()
      return
    }

    // Show loading
    container.innerHTML = '<div class="p-4 text-center"><div class="animate-spin w-5 h-5 border-2 border-gray-300 border-t-blue-500 rounded-full mx-auto"></div></div>'

    const history = await this.getConversationHistory()

    if (!this._shouldPersist()) {
      const _t = (map) => map[this.languageValue] || map.nl
      container.innerHTML = `
        <div class="p-4 text-center text-sm text-gray-500 dark:text-gray-400">
          ${_t({
            nl: 'Geschiedenis is niet ingeschakeld',
            fr: "L'historique n'est pas activé",
            de: 'Verlauf ist nicht aktiviert',
            en: 'History is not enabled'
          })}
          <button type="button" class="block mt-2 mx-auto text-blue-500 hover:text-blue-600 font-medium text-sm"
                  data-action="click->chatbot#showConsentDialog">
            ${_t({ nl: 'Inschakelen', fr: 'Activer', de: 'Aktivieren', en: 'Enable' })}
          </button>
        </div>
      `
      return
    }

    if (history.length === 0) {
      const _t = (map) => map[this.languageValue] || map.nl
      container.innerHTML = `
        <div class="p-4 text-center text-sm text-gray-500 dark:text-gray-400">
          ${_t({
            nl: 'Nog geen gesprekken opgeslagen',
            fr: 'Aucune conversation sauvegardée',
            de: 'Noch keine Gespräche gespeichert',
            en: 'No conversations saved yet'
          })}
        </div>
      `
      return
    }

    // Decrypt ZK-encrypted titles if master key is available
    const decryptedHistory = await Promise.all(history.map(async (conv) => {
      let title = conv.title || 'Conversation'
      if (conv.zero_knowledge && conv.encrypted_title && this._isZkReady()) {
        try {
          title = await ConversationCrypto.decryptPayload(conv.encrypted_title, this._masterKey) || title
        } catch { /* use server title as fallback */ }
      }
      return { ...conv, title }
    }))

    container.innerHTML = decryptedHistory.map(conv => {
      const name = this._escapeHtml(conv.title || 'Conversation')
      const date = new Date(conv.updated_at || conv.created_at)
      const timeStr = date.toLocaleDateString(this.languageValue === 'nl' ? 'nl-BE' : this.languageValue === 'fr' ? 'fr-BE' : 'en-GB', { day: 'numeric', month: 'short' })
      const msgCount = conv.message_count || 0

      return `
        <div class="group flex items-center gap-2 p-2.5 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700/50 cursor-pointer transition-colors"
             data-action="click->chatbot#loadFromHistory"
             data-conversation-history-id="${conv.id}">
          <div class="flex-1 min-w-0">
            <p class="text-sm font-medium text-gray-700 dark:text-gray-300 truncate">${name}</p>
            <p class="text-xs text-gray-400 dark:text-gray-500">${timeStr} · ${msgCount} msg</p>
          </div>
          <button type="button"
                  data-action="click->chatbot#deleteFromHistory"
                  data-conversation-history-id="${conv.id}"
                  class="opacity-0 group-hover:opacity-100 p-1 text-gray-400 hover:text-red-500 transition-all"
                  title="Delete">
            <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
            </svg>
          </button>
        </div>
      `
    }).join("")
  },

  // Explicit save button - no longer needed (auto-saved server-side)

  saveChatToHistory() {
    const _t = (map) => map[this.languageValue] || map.nl
    if (!this._isLoggedIn()) {
      this._showToast(_t({
        nl: 'Log in om gesprekken op te slaan',
        fr: 'Connectez-vous pour sauvegarder',
        de: 'Melden Sie sich an zum Speichern',
        en: 'Log in to save conversations'
      }), 'info')
      return
    }
    if (!this._shouldPersist()) {
      this.showConsentDialog()
      return
    }
    this._showToast(_t({
      nl: 'Gesprekken worden automatisch opgeslagen',
      fr: 'Les conversations sont sauvegardées automatiquement',
      de: 'Gespräche werden automatisch gespeichert',
      en: 'Conversations are saved automatically'
    }), 'success')
  },

  // ────────────────────────────────────────────────────────────
  //  GDPR Consent Dialog
  // ────────────────────────────────────────────────────────────

  // ────────────────────────────────────────────────────────────
  //  ZERO-KNOWLEDGE KEY MANAGEMENT
  //  _masterKey (CryptoKey) lives as a class field on the controller.
  // ────────────────────────────────────────────────────────────

  async _initZeroKnowledge() {
    if (!this._isLoggedIn() || !ConversationCrypto.isAvailable()) return

    try {
      const response = await fetch('/api/chatbot/zk_key_material')
      if (!response.ok) return
      const data = await response.json()

      if (!data.zero_knowledge) {
        this._masterKey = null
        this._zkKeyMaterial = null
        this._zkKeyGeneration = null
        this._zkConversationIds?.clear()
        this._zkClaimTokens?.clear()
        this._zkClaimExpiresAt?.clear()
        this._conversationRevisions?.clear()
        return
      }
      if (!data.encrypted_master_key || !data.key_derivation_salt ||
          !this._validZkKeyGeneration(data.key_generation)) {
        this._masterKey = null
        this._zkKeyMaterial = null
        this._zkKeyGeneration = null
        this._zkConversationIds?.clear()
        this._zkClaimTokens?.clear()
        this._zkClaimExpiresAt?.clear()
        this._conversationRevisions?.clear()
        return
      }

      // A reconnect or another tab may have revoked/re-granted consent. Never
      // pair an already-unwrapped old master key with the newly fetched
      // generation: that would produce ciphertext no password can recover.
      if ((this._masterKey || this._zkKeyGeneration) &&
          this._zkKeyGeneration !== data.key_generation) {
        this._masterKey = null
        this._zkConversationIds?.clear()
        this._zkClaimTokens?.clear()
        this._zkClaimExpiresAt?.clear()
        this._conversationRevisions?.clear()
      }

      // Store key material for later unwrapping (user needs to enter password)
      this._zkKeyMaterial = {
        encryptedMasterKey: data.encrypted_master_key,
        salt: data.key_derivation_salt,
        keyGeneration: data.key_generation
      }
      this._zkKeyGeneration = data.key_generation

      // Show inline password unlock prompt
      this._showZkUnlockPrompt()
    } catch (e) {
      console.warn('[ZK] Failed to fetch key material:', e)
    }
  },

  // Derive wrapping key from password + unwrap master key

  async _unlockMasterKey(password) {
    if (!this._zkKeyMaterial || !this._validZkKeyGeneration(this._zkKeyMaterial.keyGeneration)) return false

    try {
      const wrappingKey = await ConversationCrypto.deriveWrappingKey(
        password,
        this._zkKeyMaterial.salt
      )
      const masterKey = await ConversationCrypto.unwrapMasterKey(
        this._zkKeyMaterial.encryptedMasterKey,
        wrappingKey
      )
      this._masterKey = masterKey
      this._zkKeyGeneration = this._zkKeyMaterial.keyGeneration
      // Clear stored material once unlocked
      this._zkKeyMaterial = null
      return true
    } catch (e) {
      console.warn('[ZK] Master key unwrap failed (wrong password?):', e)
      return false
    }
  },

  // Generate new ZK key material during consent flow

  async _generateZkKeyMaterial(password) {
    if (!ConversationCrypto.isAvailable()) return null

    const masterKey = await ConversationCrypto.generateMasterKey()
    const salt = ConversationCrypto.generateSalt()
    const wrappingKey = await ConversationCrypto.deriveWrappingKey(password, salt)
    const encryptedMasterKey = await ConversationCrypto.wrapMasterKey(masterKey, wrappingKey)

    // Keep the candidate key local to this consent attempt. Publishing it on
    // the controller before the server confirms ZK mode creates a race where
    // an unconfirmed or older attempt can encrypt with the wrong key.
    return { masterKey, encrypted_master_key: encryptedMasterKey, key_derivation_salt: salt }
  },

  _validZkKeyGeneration(value) {
    return typeof value === 'string' && /^[a-f0-9]{64}$/.test(value)
  },

  async _fetchExistingZkKeyMaterial() {
    const response = await fetch('/api/chatbot/zk_key_material')
    if (!response.ok) throw new Error(`Existing zero-knowledge key could not be fetched (${response.status})`)

    const data = await response.json()
    if (data?.zero_knowledge !== true || !data.encrypted_master_key ||
        !data.key_derivation_salt || !this._validZkKeyGeneration(data.key_generation)) {
      throw new Error('Existing zero-knowledge key material is incomplete')
    }
    return {
      encryptedMasterKey: data.encrypted_master_key,
      salt: data.key_derivation_salt,
      keyGeneration: data.key_generation
    }
  },

  async _unwrapZkKeyMaterial(material, password) {
    const wrappingKey = await ConversationCrypto.deriveWrappingKey(password, material.salt)
    return ConversationCrypto.unwrapMasterKey(material.encryptedMasterKey, wrappingKey)
  },

  // Consent submission is single-flight. Apart from preventing duplicate
  // grants, the attempt token makes key publication conditional on the exact
  // request whose response confirmed the storage mode.

  showConsentDialog() {
    const modal = document.getElementById('consent-modal')
    if (!modal) return
    modal.classList.remove('hidden')

    // FBL-047: modal focus contract - remember the opener, move focus in,
    // trap Tab inside the dialog, close on Escape.
    this._consentPreviousFocus = document.activeElement
    const focusables = () => Array.from(modal.querySelectorAll(
      'button:not([disabled]), input:not([disabled]), a[href]'
    )).filter((el) => el.offsetParent !== null)
    focusables()[0]?.focus()

    this._consentTrapHandler = (event) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        this.declineConsentDialog()
        return
      }
      if (event.key !== 'Tab') return
      const items = focusables()
      if (items.length === 0) return
      const first = items[0]
      const last = items[items.length - 1]
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
    }
    modal.addEventListener('keydown', this._consentTrapHandler)
  },

  _teardownConsentTrap(modal) {
    if (this._consentTrapHandler && modal) {
      modal.removeEventListener('keydown', this._consentTrapHandler)
      this._consentTrapHandler = null
    }
    this._consentPreviousFocus?.focus?.()
    this._consentPreviousFocus = null
  },

  async acceptConsentDialog() {
    if (this._consentRequestInFlight) return this._consentRequestInFlight

    const acceptButton = document.getElementById('consent-accept-btn')
    const wasDisabled = Boolean(acceptButton?.disabled)
    if (acceptButton) {
      acceptButton.disabled = true
      acceptButton.setAttribute('aria-busy', 'true')
    }

    const attempt = Symbol('consent-attempt')
    this._activeConsentAttempt = attempt
    const submission = this._submitConsentDialog(attempt)
    this._consentRequestInFlight = submission

    try {
      return await submission
    } finally {
      if (this._consentRequestInFlight === submission) {
        this._consentRequestInFlight = null
        this._activeConsentAttempt = null
        if (acceptButton) {
          acceptButton.disabled = wasDisabled
          acceptButton.removeAttribute('aria-busy')
        }
      }
    }
  },

  async _submitConsentDialog(attempt) {
    const modal = document.getElementById('consent-modal')
    const passwordInput = document.getElementById('consent-password-input')
    const passwordConfirmationInput = document.getElementById('consent-password-confirmation-input')
    const password = passwordInput?.value
    const passwordConfirmation = passwordConfirmationInput?.value

    // Leaving the field empty is the user's explicit choice to use standard,
    // server-readable history. Once a password is supplied, never silently
    // downgrade to that mode if browser crypto or ZK consent setup fails.
    if (!password && !passwordConfirmation) {
      return this._acceptConsentFallback(modal, attempt)
    }

    if (!password || password !== passwordConfirmation) {
      this._showToast(
        { nl: 'De opslagwachtwoorden komen niet overeen.', fr: 'Les mots de passe de stockage ne correspondent pas.', de: 'Die Speicherpasswörter stimmen nicht überein.', en: 'The storage passwords do not match.' }[this.languageValue] || 'De opslagwachtwoorden komen niet overeen.',
        'error'
      )
      passwordConfirmationInput?.focus()
      return false
    }

    // The server only receives a salt and password-wrapped key, so password
    // strength must be enforced before PBKDF2 runs in the browser. A minimum
    // length materially raises the cost of offline guessing if those values are
    // ever exposed. Existing histories remain unlockable with their old value.
    const minimumStoragePasswordLength = 12
    if (Array.from(password).length < minimumStoragePasswordLength || password.trim().length === 0) {
      this._showToast(
        {
          nl: 'Gebruik een uniek opslagwachtwoord of een unieke wachtzin van minstens 12 tekens.',
          fr: 'Utilisez un mot de passe de stockage ou une phrase secrète unique d’au moins 12 caractères.',
          de: 'Verwenden Sie ein einzigartiges Speicherpasswort oder eine Passphrase mit mindestens 12 Zeichen.',
          en: 'Use a unique storage password or passphrase of at least 12 characters.'
        }[this.languageValue] || 'Gebruik een uniek opslagwachtwoord of een unieke wachtzin van minstens 12 tekens.',
        'error'
      )
      passwordInput?.focus()
      return false
    }

    try {
      if (!ConversationCrypto.isAvailable()) {
        throw new Error('Web Crypto is unavailable')
      }

      const zkMaterial = await this._generateZkKeyMaterial(password)
      if (!zkMaterial?.masterKey || !zkMaterial?.encrypted_master_key || !zkMaterial?.key_derivation_salt) {
        throw new Error('Zero-knowledge key material is incomplete')
      }

      // Send consent + ZK key material to server. A successful HTTP response
      // is insufficient: the server must explicitly confirm that it stored the
      // history as zero-knowledge, otherwise plaintext-readable consent would
      // have been enabled contrary to the user's password choice.
      const res = await fetch('/api/chatbot/conversations/consent', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': this.csrfToken
        },
        body: JSON.stringify({
          encrypted_master_key: zkMaterial.encrypted_master_key,
          key_derivation_salt: zkMaterial.key_derivation_salt
        })
      })
      let result = null
      try { result = await res.json() } catch (_) { /* handled by status/contract below */ }

      // Another tab/request may have committed a different generated key first.
      // The server key is authoritative: fetch and unlock that key with the
      // entered password, and never publish this request's losing candidate.
      if (res.status === 409 && result?.error === 'conversation_storage_mode_conflict') {
        const modeError = new Error('Existing standard history must be deleted before enabling zero-knowledge storage')
        modeError.code = 'conversation_storage_mode_conflict'
        throw modeError
      }

      if (res.status === 409 && result?.error === 'zero_knowledge_state_conflict' &&
          this._validZkKeyGeneration(result?.key_generation)) {
        const existingMaterial = await this._fetchExistingZkKeyMaterial()
        const existingMasterKey = await this._unwrapZkKeyMaterial(existingMaterial, password)
        if (this._activeConsentAttempt !== attempt) return false

        this._masterKey = existingMasterKey
        this._zkKeyGeneration = existingMaterial.keyGeneration
        this._zkKeyMaterial = null
        this._setConsentState(true)
        if (modal) modal.classList.add('hidden')
        if (passwordInput) passwordInput.value = ''
        if (passwordConfirmationInput) passwordConfirmationInput.value = ''
        this._showToast(
          { nl: '🔒 Bestaande beveiligde geschiedenis ontgrendeld', fr: '🔒 Historique sécurisé existant déverrouillé', de: '🔒 Bestehender sicherer Verlauf entsperrt', en: '🔒 Existing secure history unlocked' }[this.languageValue] || '🔒 Bestaande beveiligde geschiedenis ontgrendeld',
          'success'
        )
        this.renderHistoryList()
        return true
      }

      if (!res.ok || result?.zero_knowledge !== true ||
          !this._validZkKeyGeneration(result?.key_generation)) {
        throw new Error(`Zero-knowledge consent was not confirmed (${res.status})`)
      }
      if (this._activeConsentAttempt !== attempt) return false

      // Publish only the key belonging to the matching confirmed request.
      this._masterKey = zkMaterial.masterKey
      this._zkKeyGeneration = result.key_generation
      this._zkKeyMaterial = null
      this._setConsentState(true)
      if (modal) modal.classList.add('hidden')
      if (passwordInput) passwordInput.value = ''
      if (passwordConfirmationInput) passwordConfirmationInput.value = ''
      this._showToast(
        { nl: '🔒 Zero-knowledge gespreksgeschiedenis ingeschakeld', fr: '🔒 Historique zero-knowledge activé', de: '🔒 Zero-Knowledge-Verlauf aktiviert', en: '🔒 Zero-knowledge history enabled' }[this.languageValue] || '🔒 Zero-knowledge gespreksgeschiedenis ingeschakeld',
        'success'
      )
      this.renderHistoryList()
      return true
    } catch (e) {
      console.error('[ZK] Secure history setup failed:', e)
      this._showToast(
        (e?.code === 'conversation_storage_mode_conflict'
          ? {
              nl: 'Schakel eerst uw bestaande geschiedenis uit en verwijder die voordat u beveiligde geschiedenis inschakelt.',
              fr: "Désactivez et supprimez d’abord votre historique existant avant d’activer l’historique sécurisé.",
              de: 'Deaktivieren und löschen Sie zuerst den bestehenden Verlauf, bevor Sie den sicheren Verlauf aktivieren.',
              en: 'Disable and delete your existing history before enabling secure history.'
            }
          : {
              nl: 'Veilige geschiedenis kon niet worden ingeschakeld. Er is niets opgeslagen. Probeer opnieuw.',
              fr: "L'historique sécurisé n'a pas pu être activé. Rien n'a été enregistré. Réessayez.",
              de: 'Der sichere Verlauf konnte nicht aktiviert werden. Es wurde nichts gespeichert. Versuchen Sie es erneut.',
              en: 'Secure history could not be enabled. Nothing was saved. Please try again.'
            })[this.languageValue] || 'Veilige geschiedenis kon niet worden ingeschakeld. Er is niets opgeslagen. Probeer opnieuw.',
        'error'
      )
      passwordInput?.focus()
      return false
    }
  },

  // Standard (non-ZK) consent. Do not report success until the server confirms
  // that any prior wrapped key was cleared and storage is no longer ZK.

  async _acceptConsentFallback(modal, attempt) {
    try {
      const res = await fetch('/api/chatbot/conversations/consent', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': this.csrfToken
        },
        body: JSON.stringify({})
      })
      const result = res.ok ? await res.json() : null

      if (!res.ok || result?.zero_knowledge !== false) {
        throw new Error(`Standard consent was not confirmed (${res.status})`)
      }
      if (this._activeConsentAttempt !== attempt) return false

      this._masterKey = null
      this._zkKeyMaterial = null
      this._zkKeyGeneration = null
      this._zkConversationIds?.clear()
      this._zkClaimTokens?.clear()
      this._zkClaimExpiresAt?.clear()
      this._conversationRevisions?.clear()
      this._setConsentState(true)
      if (modal) modal.classList.add('hidden')
      const passwordInput = document.getElementById('consent-password-input')
      const passwordConfirmationInput = document.getElementById('consent-password-confirmation-input')
      if (passwordInput) passwordInput.value = ''
      if (passwordConfirmationInput) passwordConfirmationInput.value = ''
      this._showToast(
        { nl: 'Gespreksgeschiedenis ingeschakeld', fr: 'Historique activé', de: 'Verlauf aktiviert', en: 'History enabled' }[this.languageValue] || 'Gespreksgeschiedenis ingeschakeld',
        'success'
      )
      this.renderHistoryList()
      return true
    } catch (e) {
      console.error('[History] Standard consent failed:', e)
      this._showToast(
        {
          nl: 'Gespreksgeschiedenis kon niet worden ingeschakeld. Probeer opnieuw.',
          fr: "L'historique n'a pas pu être activé. Réessayez.",
          de: 'Der Verlauf konnte nicht aktiviert werden. Versuchen Sie es erneut.',
          en: 'History could not be enabled. Please try again.'
        }[this.languageValue] || 'Gespreksgeschiedenis kon niet worden ingeschakeld. Probeer opnieuw.',
        'error'
      )
      return false
    }
  },

  declineConsentDialog() {
    if (this._consentRequestInFlight) return

    const modal = document.getElementById('consent-modal')
    if (modal) modal.classList.add('hidden')
    this._teardownConsentTrap(modal)
    const passwordInput = document.getElementById('consent-password-input')
    const passwordConfirmationInput = document.getElementById('consent-password-confirmation-input')
    if (passwordInput) passwordInput.value = ''
    if (passwordConfirmationInput) passwordConfirmationInput.value = ''
    this._activeConsentAttempt = null
    this._setConsentState(false)
  },

  // Check consent on first message and show dialog if needed
}
