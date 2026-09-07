import { Controller } from "@hotwired/stimulus"
import { prefs as prefsStore } from "../services/preferences_store"
import { ConversationCrypto } from "../services/conversation_crypto"
import {
  sanitizeRestoredMessages,
  sanitizeVisibleAssistantAnswer
} from "../services/chatbot_message_safety"
import {
  CHATBOT_STREAM_TIMEOUT_HEADER,
  browserStreamTimeoutMs
} from "../services/chatbot_stream_timeout"
import { migrateChatbotModelPreference } from "../services/chatbot_model_preference_migration"
import {
  readIntelligenceChoices,
  bestUnlockedChoice,
  proTooltipCopy,
  lockedTierCopy,
  lockedTierLead,
  escapeLockedTierText
} from "../services/chatbot_locked_tier"
import {
  formatMessage,
  renderTable,
  inlineFormat,
  messageClasses,
  detectQuestionLanguage
} from "../services/chatbot_markdown"
import {
  processingLabel,
  doneLabel,
  progressPhases,
  resolveServerProgress,
  clampProgress
} from "../services/chatbot_progress"
import {
  parseSseChunk,
  sseErrorMessage,
  heartbeatProgress,
  terminalErrorMessage,
  incompleteResponseMessage,
  disconnectMessage
} from "../services/chatbot_stream_events"
import {
  buildAskPayload,
  createRequestDeadline,
  jsonErrorDescriptor,
  sendMessage,
  mistralFollowupDowngradeMessage
} from "../services/chatbot_send_request"

// Mixins - extracted method groups for maintainability
import { settingsMethods } from "./chatbot/settings_mixin"
import { creditsMethods } from "./chatbot/credits_mixin"
import { historyMethods } from "./chatbot/history_mixin"
import { exportMethods } from "./chatbot/export_mixin"
import { layoutMethods } from "./chatbot/layout_mixin"
import { encryptedPersistenceMethods } from "./chatbot/encrypted_persistence_mixin"
import { ratingMethods } from "./chatbot/rating_mixin"

/**
 * Chatbot Controller
 * Handles the chatbot widget UI with streaming responses, conversation history,
 * and feedback mechanism.
 */
class ChatbotController extends Controller {
  static targets = [
    "settingsBody",
    "lengthHint",
    "input",
    "messages",
    "sendButton",
    "typingIndicator",
    "widget",
    "toggleButton",
    "badge",
    "fabIconChat",
    "fabIconClose",
    "languageSelect",
    "sourceSelect",
    "sourceLegislation",
    "sourceJurisprudence",
    "sourceParliamentary",
    "loading",
    "progressBar",
    "progressText",
    "profileSelect",
    "intelligenceRange",
    "reasoningRange",
    "reasoningSelector",
    "modelSelect",
    "etaPreview",
    "widgetOptionsPanel",
    "widgetProfileSelect",
    "widgetModelSelect",
    "widgetSrcLegislation",
    "widgetSrcJurisprudence",
    "widgetSrcParliamentary"
  ]

  static values = {
    open: { type: Boolean, default: false },
    loading: { type: Boolean, default: false },
    apiEndpoint: { type: String, default: "/api/chatbot/ask" },
    language: { type: String, default: "nl" },
    source: { type: String, default: "legislation" },
    intelligence: { type: String, default: "smart" },
    reasoningLevel: { type: String, default: "low" },
    modelOverride: { type: String, default: "" },
    profile: { type: String, default: "general" },
    hasCredits: { type: Boolean, default: false },
    praxisLinked: { type: Boolean, default: false },
    pro: { type: Boolean, default: false },
    pendingQuestion: { type: String, default: "" }
  }

  // In-memory ZK master key (CryptoKey) - set by history mixin methods
  _masterKey = null

  connect() {
    this.conversationHistory = []
    this.conversationId = null  // Server-side conversation token for context
    this._conversationRevisions = new Map()
    this._zkConversationIds = new Set()
    this._zkClaimTokens = new Map()
    this._zkClaimExpiresAt = new Map()
    this._zkPushStates = new Map()
    this._conversationContextEpoch = 0
    this.messageCount = 0
    this.abortController = null // For cancelling in-flight requests
    this._selectedLevelLocked = false  // Tracks if current intelligence tier is locked
    this._selectedLevelTier = 'free'   // Current tier type: free, credits, subscriber

    // Load preferences from server-side profile (async for logged-in users).
    // First pass: sync read from whatever is already in cache (may be empty).
    this.loadPreferences()

    // Second pass (async): once server prefs arrive, re-apply and re-sync UI.
    this._initPreferencesAsync()

    // Inject credit deduction animation CSS (once per page)
    if (!document.getElementById('credit-deduct-keyframes')) {
      const style = document.createElement('style')
      style.id = 'credit-deduct-keyframes'
      style.textContent = `
        @keyframes creditDeduct {
          0% { opacity: 1; transform: translateX(-50%) translateY(0); }
          80% { opacity: 0.7; }
          100% { opacity: 0; transform: translateX(-50%) translateY(-44px); }
        }
        .credit-receipt {
          font-variant-numeric: tabular-nums;
        }
      `
      document.head.appendChild(style)
    }

    // Set initial state
    if (this.hasWidgetTarget) {
      this.widgetTarget.classList.toggle("hidden", !this.openValue)
    }

    // Show the welcome message immediately, then (for consented users) replace
    // it in place with the active conversation loaded from the server. The
    // active conversation is tracked entirely server-side — nothing is stored
    // in the browser — so the widget and the full /chatbot page show the same
    // log across tabs and reloads.
    if (this.hasMessagesTarget) {
      if (this.messagesTarget.children.length === 0) {
        this.addWelcomeMessage()
      }
      this._restoreActiveConversation()
    }

    // Auto-resize textarea input
    if (this.hasInputTarget && this.inputTarget.tagName === 'TEXTAREA') {
      this.inputTarget.addEventListener('input', () => {
        this._autoResize()
        this._updateLengthHint()
      })
      this._autoResize()
      this._updateLengthHint()
    }

    // Initialize ETA preview

    // Filter model dropdown to show only models for the active intelligence tier
    this._filterModelDropdown(this.intelligenceValue || 'smart')

    // Sync slider position with saved intelligence level
    this._syncSlidersFromPreferences()

    // Sync widget intelligence pills if widget is rendered
    this._syncWidgetPills()

    // Sync source checkboxes from saved preferences (logged-in users)
    this._syncSourceCheckboxes()

    // Load sample questions (works with Turbo unlike DOMContentLoaded)
    this._loadSampleQuestions()

    // Restore persisted widget position/size from server-side profile
    this._restoreWidgetLayout()

    // Initialize zero-knowledge encryption (fetch key material, show unlock
    // prompt), then retry any *already encrypted* snapshot whose PATCH was
    // interrupted by a reload/browser crash. The outbox never contains the
    // storage password, CryptoKey, question text, or answer text.
    void Promise.resolve(this._initZeroKnowledge())
      .then(() => this._retryEncryptedOutbox?.())
      .catch(error => console.warn('[ZK] Encrypted outbox recovery failed:', error))

    // Auto-send only the hero-form handoff hash (#q=...). The fragment is
    // cleared immediately and is never copied into browser storage. In
    // particular, a rejected unauthenticated question is not persisted as
    // plaintext for post-login recovery.
    try { sessionStorage.removeItem('chatbot_pending_question') } catch { /* private browsing */ }
    const pendingQ = this._consumeHashQuestion()
    if (pendingQ) {
      setTimeout(() => {
        if (this.hasInputTarget) {
          this.inputTarget.value = pendingQ
          this._autoResize()
          this.send()
          // On mobile, scroll the PAGE to the chat area so users see
          // the "Aan het nadenken" indicator instead of the page top
          if (this.hasMessagesTarget) {
            this.messagesTarget.scrollIntoView({ behavior: 'smooth', block: 'start' })
          }
        }
      }, 300)
    }
    // Listen for external toggle requests (e.g. mobile bottom bar Chat button)
    this._boundExternalToggle = () => this.toggle()
    document.addEventListener('chatbot:toggle', this._boundExternalToggle)
    // CSP-safe: delegated click handler for [data-chatbot-toggle] buttons
    // (replaces inline onclick that CSP blocks)
    this._boundToggleClick = (e) => {
      if (e.target.closest('[data-chatbot-toggle]')) {
        e.preventDefault()
        document.dispatchEvent(new CustomEvent('chatbot:toggle'))
      }
    }
    document.addEventListener('click', this._boundToggleClick)
  }

  disconnect() {
    this.savePreferences()
    // A Turbo visit with the offer open would otherwise orphan its keydown
    // listener, which keeps this controller alive after its element is gone.
    this._closeLockedTierModal()
    // Cancel any in-flight request to prevent stuck state
    if (this.abortController) {
      this.abortController.abort()
      this.abortController = null
    }
    // Clean up timers
    this.stopProgress()
    this._stopStopwatch()
    this.loadingValue = false
    // Clean up external toggle listener
    if (this._boundExternalToggle) {
      document.removeEventListener('chatbot:toggle', this._boundExternalToggle)
    }
    // Clean up delegated click handler for [data-chatbot-toggle]
    if (this._boundToggleClick) {
      document.removeEventListener('click', this._boundToggleClick)
    }
    // Escape-key listener is bound while the widget is open — without this it
    // leaks (and holds the whole controller alive) across Turbo navigations
    this._unbindEscapeKey()
    // Mid-drag Turbo navigation would leak the FAB drag listeners
    if (this._boundFabDragMove) {
      document.removeEventListener('mousemove', this._boundFabDragMove)
      document.removeEventListener('touchmove', this._boundFabDragMove)
    }
    if (this._boundFabDragEnd) {
      document.removeEventListener('mouseup', this._boundFabDragEnd)
      document.removeEventListener('touchend', this._boundFabDragEnd)
    }
  }

  // Toggle widget open/closed with animation
  toggle() {
    this.openValue = !this.openValue
    if (this.hasWidgetTarget) {
      if (this.openValue) {
        this.widgetTarget.classList.remove("hidden", "chatbot-widget-exit")
        this.widgetTarget.classList.add("chatbot-widget-enter")
      } else {
        this.widgetTarget.classList.remove("chatbot-widget-enter")
        this.widgetTarget.classList.add("chatbot-widget-exit")
        // Hide after animation completes
        setTimeout(() => {
          if (!this.openValue) this.widgetTarget.classList.add("hidden")
        }, 200)
      }
    }
    // Swap FAB icons and update aria-expanded
    this._updateFabIcons()
    this._updateAriaExpanded()

    if (this.openValue && this.hasInputTarget) {
      setTimeout(() => this.inputTarget.focus(), 100)
    } else if (!this.openValue && this.hasToggleButtonTarget) {
      // Return focus to FAB when closing (keyboard accessibility)
      this.toggleButtonTarget.focus()
    }
    // Clear badge when opening
    if (this.openValue && this.hasBadgeTarget) {
      this.badgeTarget.classList.add("hidden")
    }
    // Stop pulse animation on first click
    if (this.hasToggleButtonTarget) {
      this.toggleButtonTarget.classList.remove('chatbot-fab-pulse')
    }
    // Manage Escape key listener for dialog
    if (this.openValue) {
      this._bindEscapeKey()
      this._trackEvent('chatbot-open')
    } else {
      this._unbindEscapeKey()
    }
  }

  // Close widget with animation + reset position (keep resize).
  // When widget is closed, opens it (like toggle). When open, closes + resets position only.
  close() {
    if (!this.openValue) {
      // Widget is closed → open it (same as toggle)
      this.toggle()
      return
    }
    this.openValue = false
    if (this.hasWidgetTarget) {
      this.widgetTarget.classList.remove("chatbot-widget-enter", "widget-expanded")
      this.widgetTarget.classList.add("chatbot-widget-exit")
      setTimeout(() => {
        if (!this.openValue) this.widgetTarget.classList.add("hidden")
      }, 200)
    }
    // Reset position only - keep user's resize dimensions
    this._resetPositionOnly()
    this._updateFabIcons()
    this._updateAriaExpanded()
    this._unbindEscapeKey()
    // Return focus to FAB (keyboard users)
    if (this.hasToggleButtonTarget) {
      this.toggleButtonTarget.focus()
    }
  }

  // Swap chat/close icons on the FAB
  _updateFabIcons() {
    if (this.hasFabIconChatTarget && this.hasFabIconCloseTarget) {
      this.fabIconChatTarget.classList.toggle('hidden', this.openValue)
      this.fabIconCloseTarget.classList.toggle('hidden', !this.openValue)
    }
  }

  // Update aria-expanded on FAB for screen readers
  _updateAriaExpanded() {
    if (this.hasToggleButtonTarget) {
      this.toggleButtonTarget.setAttribute('aria-expanded', this.openValue ? 'true' : 'false')
    }
  }

  // Escape key handler - closes widget dialog
  _handleEscapeKey(event) {
    if (event.key === 'Escape' && this.openValue) {
      event.preventDefault()
      event.stopPropagation()
      this.close()
    }
  }

  _bindEscapeKey() {
    if (!this._boundEscapeHandler) {
      this._boundEscapeHandler = this._handleEscapeKey.bind(this)
    }
    document.addEventListener('keydown', this._boundEscapeHandler)
  }

  _unbindEscapeKey() {
    if (this._boundEscapeHandler) {
      document.removeEventListener('keydown', this._boundEscapeHandler)
    }
  }

  // Handle FAB-specific keyboard events (Enter/Space already handled by <button>)
  handleKeydown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.send()
    }
    // Auto-grow after keydown too (for Shift+Enter new lines)
    requestAnimationFrame(() => this._autoGrowTextarea(event.target))
  }

  // Auto-grow textarea as user types (widget + main page)
  _autoGrowTextarea(textarea) {
    if (!textarea || textarea.tagName !== 'TEXTAREA') return
    textarea.style.height = 'auto'
    const maxHeight = parseInt(getComputedStyle(textarea).maxHeight, 10) || 100
    textarea.style.height = Math.min(textarea.scrollHeight, maxHeight) + 'px'
  }

  // Update language preference
  updateLanguage(event) {
    this.languageValue = event.target.value
    this.savePreferences()
  }

  // Update source preference (legacy dropdown)
  _resetPositionOnly() {
    const container = document.getElementById('chatbot-widget-container')
    if (container) {
      container.classList.remove('widget-custom-pos')
      container.style.left = ''
      container.style.top = ''
    }
    // Persist: keep size but clear position from saved prefs
    this._persistWidgetLayout()
    this._syncResetPositionButton()
  }
  _syncWidgetPills() {
    const level = this.intelligenceValue || 'smart'
    const pills = document.querySelectorAll('#widget-intelligence-pills .widget-intel-pill')
    if (!pills.length) return

    pills.forEach(p => {
      const isActive = p.dataset.widgetLevel === level
      const isLocked = p.dataset.widgetLocked === 'true'
      if (isActive) {
        p.classList.add('bg-white', 'dark:bg-gray-700', 'shadow-sm', 'ring-1', 'ring-gray-200', 'dark:ring-gray-600', 'text-gray-900', 'dark:text-white')
        p.classList.remove('text-gray-500', 'dark:text-gray-400')
        // Track locked state for send-time enforcement
        this._selectedLevelLocked = isLocked
        this._selectedLevelTier = p.dataset.widgetLockedTier || 'free'
      } else {
        p.classList.remove('bg-white', 'dark:bg-gray-700', 'shadow-sm', 'ring-1', 'ring-gray-200', 'dark:ring-gray-600', 'text-gray-900', 'dark:text-white')
        p.classList.add('text-gray-500', 'dark:text-gray-400')
      }
    })

    // Sync the bottom indicator
    const indicator = document.getElementById('widget-level-indicator')
    const activePill = document.querySelector(`#widget-intelligence-pills .widget-intel-pill[data-widget-level="${level}"]`)
    if (indicator && activePill) {
      const label = activePill.dataset.widgetLabel || 'Slim'
      const desc = activePill.dataset.widgetDesc || ''
      const aiPrefix = this._aiIntelligencePrefix()
      const isLocked = activePill.dataset.widgetLocked === 'true'
      const proTag = isLocked ? ' <span class="text-amber-400 font-semibold">PRO</span>' : ''
      indicator.innerHTML = `<span data-widget-active-label>${aiPrefix}: ${label}${proTag}</span> <span data-widget-active-desc class="text-gray-300 dark:text-gray-600">- ${desc}</span>`
    }

    // Also filter widget model dropdown
    this._filterWidgetModelDropdown(level)
  }

  // Load sample questions from JSON - Turbo-safe (fires on every connect, not just DOMContentLoaded)
  _loadSampleQuestions() {
    const questionsList = document.getElementById('questions-list')
    if (!questionsList) return // Not on full chatbot page (widget doesn't have questions sidebar)

    // Guard against double-loading if questions are already rendered
    if (questionsList.querySelector('.sample-question')) return

    // Mobile lazy load: defer fetch until sidebar scrolls into view
    const isMobile = window.innerWidth < 1024
    if (isMobile && 'IntersectionObserver' in window) {
      const observer = new IntersectionObserver((entries) => {
        if (entries[0].isIntersecting) {
          observer.disconnect()
          this._fetchSampleQuestions(questionsList)
        }
      }, { rootMargin: '200px' })
      observer.observe(questionsList)
    } else {
      this._fetchSampleQuestions(questionsList)
    }
  }

  _fetchSampleQuestions(questionsList) {
    // Timeout fallback: if loading takes > 8s, show empty state
    const loadingTimeout = setTimeout(() => {
      if (!questionsList.querySelector('.sample-question')) {
        questionsList.innerHTML = '<div class="p-4 text-center text-gray-400 text-sm">Geen vragen beschikbaar</div>'
      }
    }, 8000)

    fetch('/chatbot_questions.json', { cache: 'default' })
      .then(r => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`)
        return r.json()
      })
      .then(data => {
        clearTimeout(loadingTimeout)
        // Store globally for the inline script's renderQuestions/filterQuestions
        window.allQuestions = data
        if (typeof window.filterQuestions === 'function') {
          window.filterQuestions()
        }
        // The inline script in index.html.erb handles all rendering,
        // category dropdown population, and click handlers.

        const countEl = document.getElementById('question-count')
        if (countEl) countEl.textContent = data.length

      })
      .catch(err => {
        clearTimeout(loadingTimeout)
        console.error('Failed to load sample questions:', err)
        questionsList.innerHTML = '<div class="p-4 text-center text-red-500">Fout bij laden vragen</div>'
      })
  }

  // Show/hide the settings body under the top bar. The caret and
  // aria-expanded mirror the visibility for assistive tech.
  // Long questions are where the fast model's material legal errors
  // concentrate, so once a question looks multi-part we point users on the
  // fast tier at the model picker. Advisory only: it never switches models,
  // and it disappears for anyone already on a stronger tier.
  static LENGTH_HINT_CHARS = 280

  // Stimulus fires this whenever the tier changes (slider, pills, restored
  // preferences), so the hint disappears the moment someone upgrades.
  intelligenceValueChanged() {
    this._updateLengthHint()
  }

  _updateLengthHint() {
    if (!this.hasLengthHintTarget || !this.hasInputTarget) return
    const level = this.intelligenceValue || 'smart'
    const long = (this.inputTarget.value || '').trim().length >= this.constructor.LENGTH_HINT_CHARS
    this.lengthHintTarget.classList.toggle('hidden', !(long && level === 'smart'))
  }

  openModelSettings(event) {
    if (event) event.preventDefault()
    this._setSettingsPanelOpen(true)
    if (this.hasSettingsBodyTarget) {
      this.settingsBodyTarget.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
    }
  }

  toggleSettingsPanel(event) {
    if (!this.hasSettingsBodyTarget) return
    this._setSettingsPanelOpen(this.settingsBodyTarget.classList.contains("hidden"))
  }

  _setSettingsPanelOpen(open) {
    if (!this.hasSettingsBodyTarget) return
    this.settingsBodyTarget.classList.toggle("hidden", !open)
    const toggle = document.querySelector(".chat-topbar-toggle")
    if (toggle) {
      toggle.setAttribute("aria-expanded", open ? "true" : "false")
      toggle.classList.toggle("chat-topbar-toggle--open", open)
    }
  }

  // Update profile/category from the widget dropdown
  async clearChat() {
    return this._resetConversationAfterArchive(async () => {
      // Clear history only after the server has archived/cancelled it.
      this.conversationHistory = []
      this.conversationId = null
      this.messageCount = 0
      this._privacyFooterShown = false

      this._clearSavedConversation()

      // Clear messages UI and restore empty state
      if (this.hasMessagesTarget) {
        this.messagesTarget.innerHTML = ''
        this.messagesTarget.classList.add("chatbot-messages--empty")
        this._setSettingsPanelOpen(true)
        this.addWelcomeMessage()
        // Reset scroll position to top so welcome message is visible
        this.messagesTarget.scrollTop = 0
      }

      // Also scroll the page itself to the top of the chatbot area
      this.element.scrollIntoView({ behavior: 'smooth', block: 'start' })

      this._trackEvent('chatbot-clear')
    })
  }

  _syncMainPageIntelligence(level) {
    // If we're on the full chatbot page, sync the range slider
    if (this.hasIntelligenceRangeTarget) {
      const levels = ['smart', 'genius', 'mastermind', 'omniscient']
      const idx = levels.indexOf(level)
      if (idx >= 0) {
        this.intelligenceRangeTarget.value = idx
        // Trigger the change event so labels update
        this.intelligenceRangeTarget.dispatchEvent(new Event('input', { bubbles: true }))
      }
    }
  }

  // Send message
  async send() {
    // Block while a request is in flight OR while the previous answer is
    // still animating in (loading clears before the typewriter finishes)
    if (this.loadingValue || this._animatingMessage || this._sendInProgress) return

    const question = this.inputTarget.value.trim()
    if (!question) return

    // ── Locked tier gate: block send if user selected a tier they can't use ──
    if (this._selectedLevelLocked) {
      this._showLockedTierModal(this._selectedLevelTier || 'subscriber')
      return
    }

    // The account advertises encrypted storage but its key has not been
    // unlocked in this tab. Sending would incur model cost for an answer that
    // cannot be encrypted or saved, so fail closed before touching credits.
    if (this._zkKeyGeneration && !this._isZkReady()) {
      this._showZkUnlockPrompt?.()
      this._showToast(sendMessage('zk_unlock_first', this.languageValue), 'error')
      return
    }

    // A prior answer may have reached the browser while its encrypted PATCH
    // failed. Retry that already-claimed snapshot before starting (and paying
    // for) another model request.
    if (this.conversationId && this._zkClaimTokens?.has(this.conversationId)) {
      this._sendInProgress = true
      try {
        await this._pushEncryptedConversation()
      } catch (error) {
        console.error('[ZK] Outstanding encrypted save retry failed:', error)
        this._showToast(sendMessage('zk_retry_save_first', this.languageValue), 'error')
        return
      } finally {
        this._sendInProgress = false
      }
    }

    // Track question submission
    this._trackEvent('chatbot-question', {
      intelligence: this.intelligenceValue,
      source: this.sourceValue,
      language: this.languageValue
    })

    const contextMessages = this.conversationHistory.slice(-6).map(message => ({
      role: message.role,
      content: message.content
    }))
    const requestReasoningEffort = this._effectiveReasoningForRequest(contextMessages)
    if (requestReasoningEffort !== this.reasoningLevelValue) {
      this.reasoningLevelValue = requestReasoningEffort
      const option = this._getActiveModelOption()
      this._applyModelReasoningCapabilities(option, requestReasoningEffort)
      this.savePreferences()
      this._showToast(mistralFollowupDowngradeMessage(this.languageValue), 'info')
    }

    // Add user message to UI
    this.addMessage("user", question)
    this.inputTarget.value = ""
    this._autoResize()  // Reset textarea to single line

    // Add to conversation history
    this.conversationHistory.push({ role: "user", content: question })

    // Reset any stale user-abort flag from a prior request (e.g. one cleared
    // during its typewriter animation, where no catch consumed the flag) so it
    // can't suppress THIS request's genuine timeout/error message.
    this._userAborted = false

    // Show loading state
    this.loadingValue = true
    this.updateLoadingState()
    this.startProgress()

    // One stream supervisor applies to every model/reasoning combination. Keep
    // the browser deadline later so the server gets first chance to send its
    // timeout result and refund the up-front credit reservation.
    if (this.abortController) this.abortController.abort()
    const abortController = new AbortController()
    this.abortController = abortController
    const requestState = {
      timedOut: false,
      conversationContextEpoch: this._conversationContextEpoch || 0,
      skipEncryptedPersistence: false
    }
    const deadline = createRequestDeadline({
      onTimeout: () => {
        requestState.timedOut = true
        abortController.abort()
      }
    })
    requestState.clearDeadline = deadline.clear
    // Protect the pre-header phase too. Once headers arrive, re-arm from the
    // server-advertised supervisor plus a fixed delivery/refund grace window.
    deadline.arm(browserStreamTimeoutMs())

    let responseDelivered = false  // Track whether the answer was shown to the user

    // NOTE: the pending-question store is written ONLY when the server
    // rejects with login_required (see below). Storing on every send meant a
    // reload/navigation during an in-flight query left the question behind,
    // and the next page's widget consumed it and silently re-asked it —
    // deducting credits twice.

    this._sendInProgress = true
    try {
      const endpoint = this.apiEndpointValue

      const response = await fetch(endpoint, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken
        },
        signal: abortController.signal,
        // Payload assembly (incl. the conditional zero-knowledge keys) lives
        // in services/chatbot_send_request.js. context_messages: recent turns
        // so follow-ups work WITHOUT server-side storage; processed in-memory
        // server-side, never persisted unless the user consented.
        body: JSON.stringify(buildAskPayload({
          question: this._enrichQuestionWithLawContext(question),
          language: this.languageValue,
          source: this.sourceValue,
          sources: this.getSelectedSources(),
          intelligence: this.intelligenceValue,
          reasoningEffort: requestReasoningEffort,
          modelOverride: this.modelOverrideValue,
          profile: this.profileValue,
          lawNumac: document.querySelector('meta[name="chatbot-context"]')?.dataset?.lawNumac,
          conversationId: this.conversationId,
          zkReady: this._isZkReady(),
          zkKeyGeneration: this._zkKeyGeneration,
          zkConversation: this._zkConversationIds?.has(this.conversationId),
          conversationRevision: this._conversationRevisions?.get(this.conversationId),
          contextMessages
        }))
      })

      deadline.arm(browserStreamTimeoutMs(response.headers.get(CHATBOT_STREAM_TIMEOUT_HEADER)))
      // Handle SSE streaming response (text/event-stream)
      if (response.headers.get('content-type')?.includes('text/event-stream')) {
        // Keep the simulated phases running. The server emits only a couple of
        // progress events, so cancelling here left the bar frozen for the whole
        // query. Server events raise the bar past the simulation
        // (updateProgressBar is monotonic); stopProgress() clears the timer.
        responseDelivered = await this._handleSSEResponse(response, question, requestState)
      } else {
        // Standard JSON - loading complete as soon as response is received
        this._finishLoading()
        // Standard JSON response
        let data
        try {
          data = await response.json()
          requestState.clearDeadline()
        } catch (parseError) {
          console.error("Failed to parse response:", parseError)
          throw new Error("Invalid server response")
        }

        const guardedAnswer = sanitizeVisibleAssistantAnswer(data.answer, this.languageValue)
        if (guardedAnswer.blocked) {
          data.answer = guardedAnswer.content
          data.error = guardedAnswer.content
          data.error_code = guardedAnswer.errorCode
          console.error('[AnswerSafety] Blocked an unsafe assistant payload')
        }

        if (data.error) {
          requestState.skipEncryptedPersistence = true
          this._applyCreditsInfo?.(data.credits_info, { visual: false })
          // Handle specific error types with user-friendly messages
          // Status-to-copy resolution lives in services/chatbot_send_request.js.
          const errorView = jsonErrorDescriptor(response.status, data, this.languageValue)
          this.addMessage("error", errorView.message)
          if (errorView.upsell) {
            // Logged-in user out of credits - buy credits + Pro upsell card.
            const upsell = errorView.upsell
            const card = document.createElement('div')
            card.className = 'mt-3 mb-1 rounded-xl border border-amber-200 dark:border-amber-800 bg-gradient-to-br from-amber-50 to-orange-50 dark:from-amber-900/20 dark:to-orange-900/20 p-4 shadow-sm animate-entrance'
            card.innerHTML = `
              <p class="text-xs font-semibold text-gray-800 dark:text-gray-200 mb-3">${upsell.header}</p>
              <div class="flex flex-col gap-2">
                <a href="${upsell.buyUrl}" class="text-center bg-gradient-to-r from-amber-500 to-orange-500 hover:from-amber-600 hover:to-orange-600 text-white px-4 py-2.5 rounded-lg font-semibold text-xs transition-all shadow-md hover:shadow-lg">${upsell.buyLabel}</a>
                <a href="${upsell.praxisUrl}" target="_blank" rel="noopener" class="text-center bg-gradient-to-r from-blue-600 to-indigo-600 hover:from-blue-700 hover:to-indigo-700 text-white px-4 py-2.5 rounded-lg font-semibold text-xs transition-all shadow-md hover:shadow-lg">${upsell.proLabel}</a>
                <p class="text-[10px] text-gray-500 dark:text-gray-400 text-center mt-1">${typeof upsell.proDesc === 'string' ? upsell.proDesc : ''}</p>
              </div>
            `
            this.messagesTarget.appendChild(card)
            this.scrollToBottom()
          }
        } else {
          if (data.conversation_id) {
            if (this._recordConversationProtocolState(data, true)) {
              this.conversationId = data.conversation_id
            } else {
              requestState.skipEncryptedPersistence = true
              this._showToast(sendMessage('protocol_state_changed', this.languageValue), 'error')
            }
          }

          // Track analytic_id for feedback linking
          this.lastAnalyticId = data.analytic_id || null

          this.lastQuestionLang = this.detectQuestionLanguage(question)

          // Stage the encrypted save before the typewriter animation. Credits
          // pay for the generated answer, while optional history is a separate
          // browser-encrypted PATCH; starting it here minimizes the delivery-to-
          // persistence window and records ciphertext before lengthy UI work.
          if (data.zero_knowledge === true && !requestState.skipEncryptedPersistence &&
              this._isZkReady()) {
            const stagedMessages = [
              ...this.conversationHistory,
              { role: 'assistant', content: data.answer, analytic_id: this.lastAnalyticId }
            ].slice(-50)
            const stagedPersistence = this._pushEncryptedConversation({
              conversationId: this.conversationId,
              masterKey: this._masterKey,
              keyGeneration: this._zkKeyGeneration,
              claimToken: this._zkClaimTokens?.get(this.conversationId),
              claimExpiresAt: this._zkClaimExpiresAt?.get(this.conversationId),
              messages: stagedMessages
            })
            stagedPersistence?.catch?.(() => {})
            requestState.encryptedPersistencePromise = stagedPersistence
          }

          const rendered = await this.streamMessage("assistant", data.answer, data.sources, data.response_time, data.token_usage, requestState, data.rating_token)
          if (!rendered) return
          responseDelivered = true
          // Add to conversation history (cap at 50 messages to prevent memory leaks)
          this.conversationHistory.push({ role: "assistant", content: data.answer, analytic_id: this.lastAnalyticId })
          if (this.conversationHistory.length > 50) {
            this.conversationHistory = this.conversationHistory.slice(-50)
          }

          // Post-response UI updates - guarded so failures don't show a false "connection error"
          try {
            // Animate credit deduction + update pool counters
            this._applyCreditsInfo?.(data.credits_info)

            if (data.suggestions && data.suggestions.length > 0) {
              this.showSuggestions(data.suggestions)
            }

            // Privacy footer - appears once per conversation, after first answer
            if (!this._privacyFooterShown) {
              this._privacyFooterShown = true
              this._showPrivacyFooter()
            }
          } catch (uiError) {
            console.warn('Post-response UI update failed (answer was delivered):', uiError.message)
          }
        }
      }

      // Push encrypted payload to server (zero-knowledge mode)
      if (this._isZkReady() && !requestState.skipEncryptedPersistence &&
          requestState.conversationContextEpoch === (this._conversationContextEpoch || 0)) {
        try {
          const encryptedPersistence = requestState.encryptedPersistencePromise || this._pushEncryptedConversation()
          this._encryptedPersistenceInFlight = encryptedPersistence
          await encryptedPersistence
        } catch (persistenceError) {
          // The answer itself was delivered, but the user explicitly enabled
          // saved history. Surface that distinct failure instead of silently
          // pretending the encrypted snapshot reached the server.
          console.error('[ZK] Failed to persist encrypted conversation:', persistenceError)
          this._showToast(sendMessage('encrypted_save_failed', this.languageValue), 'error')
        } finally {
          this._encryptedPersistenceInFlight = null
        }
      }
    } catch (error) {
      deadline.clear()
      this._finishLoading()

      // A history switch or clear intentionally invalidates this request. Its
      // late abort/error belongs to the old conversation and must stay silent.
      if (requestState.conversationContextEpoch !== (this._conversationContextEpoch || 0)) return

      // If the answer was already shown, a post-delivery error should not alarm the user
      if (responseDelivered) {
        console.warn('Post-delivery error (answer was shown successfully):', error.message)
        return
      }

      console.error("Chatbot error:", error)

      // Distinguish timeout/abort from other errors
      if (requestState.timedOut || error.name === "AbortError") {
        // User-initiated abort (clearChat) — not a timeout; stay silent.
        if (this._userAborted) { this._userAborted = false; return }
        this.addMessage("error", sendMessage('request_timed_out', this.languageValue))
      } else {
        this.addMessage("error", sendMessage('connection_error', this.languageValue))
      }
    } finally {
      deadline.clear()
      this._sendInProgress = false
      // Only clear if a newer send hasn't replaced the controller
      if (this.abortController === abortController) this.abortController = null
    }
  }

  // Centralized loading cleanup (prevents forgetting to reset state)
  _finishLoading() {
    this.stopProgress()
    this.loadingValue = false
    this.updateLoadingState()
  }

  // Add message to chat
  addMessage(role, content, sources = null, responseTime = null, tokenUsage = null) {
    // Exit empty state when a real user message arrives
    if (role === "user" && this.hasMessagesTarget) {
      this.messagesTarget.classList.remove("chatbot-messages--empty")
      const welcomeWrap = this.messagesTarget.querySelector(".chatbot-welcome-wrap")
      if (welcomeWrap) welcomeWrap.remove()
      // Settings are open while the transcript is empty (so the options are
      // discoverable) and step aside once a conversation exists, so the chat
      // - not the control panel - owns the page.
      this._setSettingsPanelOpen(false)
    }

    const messageDiv = document.createElement("div")
    messageDiv.className = this.getMessageClasses(role)
    messageDiv.dataset.messageId = ++this.messageCount

    const contentDiv = document.createElement("div")
    contentDiv.className = "message-content"
    contentDiv.innerHTML = this.formatMessage(content)
    messageDiv.appendChild(contentDiv)

    // Add sources if present (only for NL/FR - others get inline sources from LLM)
    if (sources && sources.length > 0) {
      const sourcesDiv = this.createSourcesElement(sources)
      if (sourcesDiv) {
        messageDiv.appendChild(sourcesDiv)
      }
    }

    // Add metadata (response time, feedback)
    if (role === "assistant") {
      const metaDiv = this.createMetaElement(responseTime, this.messageCount, tokenUsage)
      messageDiv.appendChild(metaDiv)
    }

    this.messagesTarget.appendChild(messageDiv)
    this.scrollToBottom()
  }

  // Stream message with chunked rendering for better UX
  // Uses chunk-based approach instead of per-character re-parse to avoid O(n²) DOM thrashing
  async streamMessage(role, content, sources = null, responseTime = null, tokenUsage = null, requestState = null, ratingToken = null) {
    // Block send() while the typewriter animation runs: loading is already
    // cleared at this point, and an interleaved send would corrupt the
    // question/answer pairing in conversationHistory.
    this._animatingMessage = true
    try {
      const isCurrentConversation = () => !requestState ||
        requestState.conversationContextEpoch === (this._conversationContextEpoch || 0)
      if (!isCurrentConversation()) return false

      const messageDiv = document.createElement("div")
      messageDiv.className = this.getMessageClasses(role)
      messageDiv.dataset.messageId = ++this.messageCount

      const contentDiv = document.createElement("div")
      contentDiv.className = "message-content"
      messageDiv.appendChild(contentDiv)

      this.messagesTarget.appendChild(messageDiv)

      // Stream in chunks: append several characters at once, only reformat periodically
      const chunkSize = 3
      const reformatInterval = 20 // Only re-parse markdown every N characters
      let displayed = ""

      for (let i = 0; i < content.length; i += chunkSize) {
        displayed += content.slice(i, i + chunkSize)

        // Full markdown re-parse only at intervals and at the end
        if (i % reformatInterval < chunkSize || i + chunkSize >= content.length) {
          contentDiv.innerHTML = this.formatMessage(displayed)
        }

        // Scroll every few chunks
        if (i % 30 < chunkSize) {
          this.scrollToBottom()
        }

        // Small delay for streaming effect (faster for longer messages)
        const delay = content.length > 500 ? 3 : 10
        await new Promise(resolve => setTimeout(resolve, delay))
        if (!isCurrentConversation()) {
          messageDiv.remove()
          return false
        }
      }

      // Final render to ensure complete formatting
      contentDiv.innerHTML = this.formatMessage(displayed)

      // Add sources after streaming (only for NL/FR - others get inline sources from LLM)
      if (sources && sources.length > 0) {
        const sourcesDiv = this.createSourcesElement(sources)
        if (sourcesDiv) {
          messageDiv.appendChild(sourcesDiv)
        }
      }

      // Add metadata
      const metaDiv = this.createMetaElement(responseTime, this.messageCount, tokenUsage, ratingToken)
      messageDiv.appendChild(metaDiv)

      this.scrollToBottom()
      return true
    } finally {
      this._animatingMessage = false
    }
  }

  // Create sources element with translated labels based on detected language
  // Sources are collapsed by default and deduplicated
  // data-turn-index is the position this answer WILL occupy in
  // conversationHistory: the user turn is already pushed when metadata is
  // built, the assistant turn is pushed right after the render returns. It
  // exists so a per-answer action resolves the turn it was clicked on rather
  // than the newest one - the same mistake the old Good/Bad handler made.
  createMetaElement(responseTime, messageId, tokenUsage = null, ratingToken = null) {
    const div = document.createElement("div")
    div.className = "message-meta mt-2 flex items-center justify-between text-xs text-gray-400"

    let timeText = responseTime ? `${responseTime}s` : ""
    // Token usage is logged to console for debugging only - not shown to users
    if (tokenUsage?.total) {
      console.debug(`Token usage: ${tokenUsage.total.toLocaleString()}`)
    }
    const _t = (map) => map[this.languageValue] || map.nl
    const reportText = _t({ nl: "Melden", fr: "Signaler", de: "Melden", en: "Report" })
    const reportWarning = _t({
      nl: "Uw vraag en antwoord worden zichtbaar voor de beheerder",
      fr: "Votre question et réponse seront visibles par l'administrateur",
      de: "Ihre Frage und Antwort werden für den Administrator sichtbar",
      en: "Your question and answer will be visible to the administrator"
    })
    const copyText = _t({ nl: "Kopiëren", fr: "Copier", de: "Kopieren", en: "Copy" })
    const saveText = _t({ nl: "Opslaan", fr: "Sauvegarder", de: "Speichern", en: "Save" })

    const exportText = _t({ nl: "Export", fr: "Export", de: "Export", en: "Export" })

    div.innerHTML = `
      <span>${timeText}</span>
      <div class="feedback-buttons flex gap-1.5 items-center" data-message-id="${messageId}" data-turn-index="${this.conversationHistory.length}">
        <button type="button"
                class="copy-btn hover:text-(--accent-500) transition-colors p-1 rounded"
                data-action="click->chatbot#copyAnswer"
                title="${copyText}">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                  d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/>
          </svg>
        </button>
        <div class="relative">
          <button type="button"
                  class="export-single-btn hover:text-(--accent-500) transition-colors p-1 rounded flex items-center gap-0.5"
                  data-action="click->chatbot#toggleSingleExportMenu"
                  data-export-menu-id="export-single-menu-${messageId}"
                  title="${exportText}">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"/>
            </svg>
          </button>
          <div id="export-single-menu-${messageId}" class="hidden absolute right-0 bottom-full mb-1 w-40 bg-white dark:bg-[#0f172a] rounded-lg shadow-lg border border-gray-200 dark:border-[#1e293b] py-1 z-50">
            <button type="button" data-action="click->chatbot#exportPDFSingle"
                    class="w-full text-left px-3 py-2 text-xs text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 flex items-center gap-2">
              <span>📄</span> PDF
            </button>
            <button type="button" data-action="click->chatbot#exportWord"
                    class="w-full text-left px-3 py-2 text-xs text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 flex items-center gap-2">
              <span>📝</span> Word (.doc)
            </button>
          </div>
        </div>
        <span class="text-gray-300 dark:text-gray-600">|</span>
        <button type="button"
                class="save-btn hover:text-yellow-500 transition-colors p-1 rounded"
                data-action="click->chatbot#saveAnswer"
                title="${saveText}">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                  d="M5 5a2 2 0 012-2h10a2 2 0 012 2v16l-7-3.5L5 21V5z"/>
          </svg>
        </button>
        ${this.praxisLinkedValue ? `
        <button type="button"
                class="dossier-btn hover:text-indigo-500 transition-colors p-1 rounded"
                data-action="click->chatbot#saveToDossier"
                title="${_t({ nl: 'Opslaan in dossier', fr: 'Sauvegarder dans le dossier', de: 'Im Dossier speichern', en: 'Save to dossier' })}">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                  d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4"/>
          </svg>
        </button>
        ` : ''}
        ${this.ratingControlMarkup(ratingToken)}
        <span class="text-gray-300 dark:text-gray-600">|</span>
        <button type="button"
                class="report-btn hover:text-amber-500 transition-colors p-1 rounded flex items-center gap-0.5"
                data-action="click->chatbot#reportFailed"
                title="${reportWarning}">
          <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                  d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.34 16.5c-.77.833.192 2.5 1.732 2.5z"/>
          </svg>
        </button>
      </div>
    `

    return div
  }

  _addFullPageWelcomeCard() {
    // Mirror BrandingHelper#site_name so the rebuilt card carries the same
    // per-site brand as the server-rendered welcome (LisLoi/GesetzGuide/…).
    const siteName = {
      'lisloi.be': 'LisLoi',
      'gesetzguide.be': 'GesetzGuide',
      'lexlibera.be': 'LexLibera'
    }[location.hostname.replace(/^www\./, '')] || 'WetWijzer'
    const copy = {
      nl: {
        eyebrow: `${siteName} · juridische chatbot`,
        title: 'Waarmee kan ik u helpen?',
        body: `Stel uw vraag in uw eigen woorden. ${siteName} doorzoekt wetgeving, rechtspraak en parlementaire stukken.`,
        prompt: 'Probeer bijvoorbeeld',
        hint: 'Of typ hieronder uw eigen vraag.',
        questions: [
          ['arbeidsrecht', 'Wat zijn mijn rechten bij ontslag?'],
          ['huurrecht', 'Mag mijn verhuurder de huurprijs verhogen?'],
          ['familierecht', 'Hoe verloopt een nalatenschap zonder testament?']
        ]
      },
      fr: {
        eyebrow: `${siteName} · chatbot juridique`,
        title: 'Comment puis-je vous aider ?',
        body: `Posez votre question en langage courant. ${siteName} consulte la législation, la jurisprudence et les travaux parlementaires.`,
        prompt: 'Essayez par exemple',
        hint: 'Ou saisissez votre propre question ci-dessous.',
        questions: [
          ['arbeidsrecht', 'Quels sont mes droits en cas de licenciement ?'],
          ['huurrecht', 'Mon bailleur peut-il augmenter le loyer ?'],
          ['familierecht', 'Comment se règle une succession sans testament ?']
        ]
      },
      de: {
        eyebrow: `${siteName} · juristischer Chatbot`,
        title: 'Wobei kann ich Ihnen helfen?',
        body: `Stellen Sie Ihre Frage in eigenen Worten. ${siteName} durchsucht Gesetzgebung, Rechtsprechung und parlamentarische Dokumente.`,
        prompt: 'Zum Beispiel',
        hint: 'Oder geben Sie unten Ihre eigene Frage ein.',
        questions: [
          ['arbeidsrecht', 'Welche Rechte habe ich bei einer Kündigung?'],
          ['huurrecht', 'Darf mein Vermieter die Miete erhöhen?'],
          ['familierecht', 'Wie wird ein Nachlass ohne Testament geregelt?']
        ]
      },
      en: {
        eyebrow: `${siteName} · legal chatbot`,
        title: 'How can I help?',
        body: `Ask your question in your own words. ${siteName} searches legislation, case law, and parliamentary documents.`,
        prompt: 'Try asking',
        hint: 'Or type your own question below.',
        questions: [
          ['arbeidsrecht', 'What are my rights if I am dismissed?'],
          ['huurrecht', 'Can my landlord increase the rent?'],
          ['familierecht', 'How is an estate settled without a will?']
        ]
      }
    }[this.languageValue] || null
    if (!copy) return false

    const wrap = document.createElement('div')
    wrap.className = 'chatbot-welcome-wrap'

    // Same shape as the server-rendered empty state: one assistant bubble
    // with the intro line, then tappable starter chips.
    const card = document.createElement('div')
    card.className = 'message chatbot-welcome-card message-fade-in'

    const body = document.createElement('p')
    body.className = 'chatbot-welcome-copy'
    body.textContent = copy.body
    card.appendChild(body)

    const starterGrid = document.createElement('div')
    starterGrid.className = 'chatbot-starter-grid'
    copy.questions.forEach(([category, question]) => {
      const button = document.createElement('button')
      button.type = 'button'
      button.className = 'chatbot-starter-question'
      button.dataset.action = 'click->chatbot#clickStarterSuggestion'
      button.dataset.sampleCategory = category
      button.dataset.question = question
      const label = document.createElement('span')
      label.textContent = question
      button.appendChild(label)
      starterGrid.appendChild(button)
    })
    card.appendChild(starterGrid)
    wrap.appendChild(card)

    this.messagesTarget.appendChild(wrap)
    return true
  }

  // Add welcome message (no feedback/action buttons - it's not a real Q&A)
  addWelcomeMessage() {
    const isWidget = !!this.element.closest('#chatbot-widget-container')
    if (!isWidget && this._addFullPageWelcomeCard()) {
      this.scrollToBottom()
      return
    }

    // Use page translations if available, otherwise fallback
    const t = window.chatbotTranslations && window.chatbotTranslations[this.languageValue]
    let welcome = t ? t.welcome : null

    if (!welcome) {
      if (this.languageValue === "fr") {
        const settingsHint = isWidget
          ? "⚙ Réglez le niveau d'intelligence via l'icône d'engrenage en bas à gauche."
          : "⚙ Réglez le niveau d'intelligence via le panneau de configuration ci-dessus."
        welcome = `Bonjour! Je suis le chatbot juridique LisLoi. Posez votre question juridique!\n\n${settingsHint}\n\n🔒 **Confidentialité:** Par défaut, nous n'enregistrons pas vos conversations. Avec un mot de passe de stockage, seul l'historique enregistré est chiffré dans votre navigateur et nous ne pouvons pas le déchiffrer sans ce mot de passe ; votre question actuelle et le contexte pertinent sont néanmoins traités temporairement en clair afin de répondre. Plus d'infos sur notre [page sécurité IA](/ai-security).`
      } else if (this.languageValue === "en") {
        const settingsHint = isWidget
          ? "⚙ Adjust the intelligence level via the gear icon at the bottom left."
          : "⚙ Adjust the intelligence level via the settings panel above."
        welcome = `Hello! I'm the LexLibera Legal Chatbot. Ask your legal question!\n\n${settingsHint}\n\n🔒 **Privacy:** By default we do not store your conversations. With a storage password, only saved history is encrypted in your browser and we cannot decrypt it without that password; your current question and relevant context are still processed temporarily in readable form to answer. More info on our [AI security page](/ai-security).`
      } else if (this.languageValue === "de") {
        const settingsHint = isWidget
          ? "⚙ Die Intelligenzstufe können Sie über das Zahnrad-Symbol unten links einstellen."
          : "⚙ Die Intelligenzstufe können Sie über das Einstellungsfeld oben einstellen."
        welcome = `Hallo! Ich bin der juristische Chatbot von GesetzGuide. Stellen Sie Ihre juristische Frage!\n\n${settingsHint}\n\n🔒 **Datenschutz:** Standardmäßig speichern wir Ihre Gespräche nicht. Mit einem Speicherpasswort wird nur der gespeicherte Verlauf im Browser verschlüsselt und kann von uns ohne dieses Passwort nicht entschlüsselt werden; Ihre aktuelle Frage und der relevante Kontext werden zur Beantwortung dennoch vorübergehend im Klartext verarbeitet. Weitere Infos auf unserer [KI-Sicherheitsseite](/ai-security).`
      } else {
        const settingsHint = isWidget
          ? "⚙ Het intelligentieniveau kunt u aanpassen via het tandwielpictogram linksonder."
          : "⚙ Het intelligentieniveau kunt u aanpassen via het instellingenpaneel hierboven."
        welcome = `Hallo! Ik ben de WetWijzer Juridische Chatbot. Stel uw juridische vraag!\n\n${settingsHint}\n\n🔒 **Privacy:** Standaard slaan wij uw gesprekken niet op. Met een opslagwachtwoord wordt alleen de opgeslagen geschiedenis in uw browser versleuteld en kunnen wij die zonder dat wachtwoord niet ontsleutelen; uw actuele vraag en relevante context worden voor beantwoording wel tijdelijk in leesbare vorm verwerkt. Meer info op onze [AI-beveiligingspagina](/ai-security).`
      }
    }

    // Context-aware greeting: detect if user is on a law page
    const ctxMeta = document.querySelector('meta[name="chatbot-context"]')
    if (ctxMeta) {
      const lawTitle = ctxMeta.dataset.lawTitle
      if (lawTitle) {
        let ctxLine = ''
        if (this.languageValue === 'fr') {
          ctxLine = `📜 Je vois que vous consultez **${lawTitle}**. Posez-moi vos questions à ce sujet!\n\n`
        } else if (this.languageValue === 'en') {
          ctxLine = `📜 I see you're viewing **${lawTitle}**. Ask me anything about it!\n\n`
        } else if (this.languageValue === 'de') {
          ctxLine = `📜 Ich sehe, dass Sie **${lawTitle}** ansehen. Stellen Sie mir Ihre Fragen dazu!\n\n`
        } else {
          ctxLine = `📜 Ik zie dat u **${lawTitle}** bekijkt. Stel mij gerust uw vragen hierover!\n\n`
        }
        welcome = ctxLine + welcome
      }
    }

    // Render directly without meta/feedback buttons
    const messageDiv = document.createElement("div")
    messageDiv.className = this.getMessageClasses("assistant")
    messageDiv.dataset.messageId = ++this.messageCount

    const contentDiv = document.createElement("div")
    contentDiv.className = "message-content"
    contentDiv.setAttribute("data-translate", "welcome")
    contentDiv.innerHTML = this.formatMessage(welcome)
    messageDiv.appendChild(contentDiv)

    this.messagesTarget.appendChild(messageDiv)
    this.scrollToBottom()
  }

  // Show follow-up suggestions as clickable buttons
  showSuggestions(suggestions) {
    // Remove any existing suggestions
    const existing = this.messagesTarget.querySelector(".suggestions-container")
    if (existing) existing.remove()

    const container = document.createElement("div")
    container.className = "suggestions-container flex flex-wrap gap-2 mt-3 mb-2 px-2"

    suggestions.forEach(suggestion => {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = "suggestion-btn text-xs px-3 py-1.5 rounded-full transition-colors border flex items-center gap-1.5"
      btn.style.backgroundColor = 'var(--accent-50)'
      btn.style.color = 'var(--accent-700)'
      btn.style.borderColor = 'var(--accent-200)'
      btn.dataset.question = suggestion  // Clean text for extraction (avoids badge text leaking)

      // Suggestion text
      const textSpan = document.createElement("span")
      textSpan.textContent = suggestion
      btn.appendChild(textSpan)

      // Credit cost badge
      const costBadge = document.createElement("span")
      costBadge.className = "inline-flex items-center gap-0.5 text-[9px] font-semibold px-1.5 py-0.5 rounded-full"
      costBadge.style.backgroundColor = 'var(--accent-100)'
      costBadge.style.color = 'var(--accent-600)'
      costBadge.dataset.suggestionCreditCost = 'true'
      btn.appendChild(costBadge)

      btn.addEventListener("click", () => {
        // Remove suggestions when clicked
        container.remove()
        // Set the input value and submit
        this.inputTarget.value = suggestion
        this.send()
      })
      container.appendChild(btn)
    })

    this.messagesTarget.appendChild(container)
    // Populate from the same live base + reasoning total as every other badge.
    // Later model/reasoning refreshes update this marker in place.
    this._updateSuggestionCostBadges()
    this.scrollToBottom()
  }

  // Handle click on server-rendered starter suggestion buttons in the welcome message
  clickStarterSuggestion(event) {
    const btn = event.currentTarget
    const question = btn.dataset.question
    if (!question) return

    // Auto-select the matching category profile before sending
    const sampleCat = btn.dataset.sampleCategory ||
      btn.closest("[data-sample-category]")?.dataset?.sampleCategory ||
      'general'
    if (sampleCat !== 'general') {
      const profileId = this.constructor.SAMPLE_TO_PROFILE[sampleCat] || 'general'
      const profileSelect = document.getElementById('profile-select')
      if (profileSelect && profileSelect.value !== profileId) {
        profileSelect.value = profileId
        profileSelect.dispatchEvent(new Event('change', { bubbles: true }))
      }
    }

    // Remove the entire sample questions panel
    const panel = btn.closest(".chatbot-starter-panel") || btn.closest(".suggestions-container")
    if (panel) panel.remove()

    // Fire-and-forget anonymous click tracking (no cookies, no user data)
    try {
      // sendBeacon cannot set headers, so the CSRF token travels in the
      // body; Rails checks params.authenticity_token (FBL-043).
      const csrf = document.querySelector('meta[name="csrf-token"]')?.content
      const trackData = JSON.stringify({ question, category: sampleCat, language: document.documentElement.lang || 'nl', authenticity_token: csrf })
      if (navigator.sendBeacon) {
        navigator.sendBeacon('/api/sample_question_clicks', new Blob([trackData], { type: 'application/json' }))
      } else {
        fetch('/api/sample_question_clicks', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: trackData, keepalive: true }).catch(() => {})
      }
    } catch(e) { /* tracking is best-effort */ }

    // Set input and send
    this.inputTarget.value = question
    this.send()
  }

  // Mapping from sample-question category IDs → profile dropdown IDs
  static SAMPLE_TO_PROFILE = {
    arbeidsrecht:       'labor',
    huurrecht:          'real_estate',
    familierecht:       'family',
    erfrecht:           'family',        // Inheritance falls under family profile
    strafrecht:         'criminal',
    fiscaal:            'tax',
    vennootschapsrecht: 'corporate',
    consumentenrecht:   'consumer',
    vreemdelingenrecht: 'migration',
    'sociale zekerheid':'social',
    bestuursrecht:      'administrative',
    privacy:            'privacy',
    all:                'general'
  }

  // Reverse mapping: profile dropdown value -> sample pill category ID
  static PROFILE_TO_SAMPLE = {
    labor:          'arbeidsrecht',
    real_estate:    'huurrecht',
    family:         'familierecht',
    criminal:       'strafrecht',
    tax:            'fiscaal',
    corporate:      'vennootschapsrecht',
    consumer:       'consumentenrecht',
    migration:      'vreemdelingenrecht',
    social:         'sociale zekerheid',
    administrative: 'bestuursrecht',
    privacy:        'privacy',
    general:        'all'
  }

  // Highlight the category pill matching a profile dropdown value
  filterSampleCategory(event) {
    const btn = event.currentTarget
    const category = btn.dataset.category
    if (!category) return

    const panel = btn.closest(".sample-questions-panel")
    if (!panel) return

    // Tactile click feedback - brief scale pulse
    btn.style.transform = "scale(0.93)"
    setTimeout(() => { btn.style.transform = "" }, 120)

    // Update active button styling with per-category colors
    const isDark = document.documentElement.classList.contains('dark') ||
                   window.matchMedia('(prefers-color-scheme: dark)').matches
    panel.querySelectorAll(".sample-cat-btn").forEach(b => {
      b.style.backgroundColor = "transparent"
      b.style.color = isDark ? "#9ca3af" : "#6b7280"
      b.style.borderColor = isDark ? "#374151" : "#d1d5db"
      b.style.borderWidth = ""
      b.style.boxShadow = ""
    })
    // Use per-category color if available (from data attributes), else accent
    if (btn.dataset.catBg && category !== 'all') {
      btn.style.backgroundColor = isDark ? btn.dataset.catDarkBg : btn.dataset.catBg
      btn.style.color = isDark ? btn.dataset.catDarkText : btn.dataset.catText
      btn.style.borderColor = isDark ? btn.dataset.catDarkBorder : btn.dataset.catBorder
      btn.style.borderWidth = '1.5px'
      btn.style.boxShadow = `0 1px 3px ${isDark ? btn.dataset.catDarkBorder : btn.dataset.catBorder}40`
    } else {
      btn.style.backgroundColor = "var(--accent-100)"
      btn.style.color = "var(--accent-700)"
      btn.style.borderColor = "var(--accent-300)"
      btn.style.borderWidth = '1.5px'
    }

    // Sync the Categorie dropdown at the top
    const profileId = this.constructor.SAMPLE_TO_PROFILE[category] || 'general'
    const profileSelect = document.getElementById('profile-select')
    if (profileSelect && profileSelect.value !== profileId) {
      profileSelect.value = profileId
      // Fire the change event so chatbot#updateProfile stores the preference
      profileSelect.dispatchEvent(new Event('change', { bubbles: true }))

      // Brief highlight flash on the dropdown to draw attention
      profileSelect.style.transition = 'box-shadow 0.3s ease, border-color 0.3s ease'
      profileSelect.style.boxShadow = '0 0 0 2px var(--accent-300)'
      profileSelect.style.borderColor = 'var(--accent-500)'
      setTimeout(() => {
        profileSelect.style.boxShadow = ''
        profileSelect.style.borderColor = ''
      }, 1200)
    }

    // Show/hide category groups
    const groups = panel.querySelectorAll(".sample-category-group")
    groups.forEach(group => {
      if (category === "all" || group.dataset.sampleCategory === category) {
        group.style.display = ""
        // Auto-expand when filtering to a single category
        if (category !== "all") {
          const body = group.querySelector(".sample-category-body")
          const chevron = group.querySelector(".sample-chevron")
          if (body) body.style.display = ""
          if (chevron) chevron.style.transform = "rotate(0deg)"
        }
      } else {
        group.style.display = "none"
      }
    })
  }

  // Toggle collapse/expand of a sample question category
  toggleSampleCategory(event) {
    const header = event.currentTarget
    const group = header.closest(".sample-category-group")
    if (!group) return

    const body = group.querySelector(".sample-category-body")
    const chevron = group.querySelector(".sample-chevron")
    if (!body) return

    const isHidden = body.style.display === "none"
    body.style.display = isHidden ? "" : "none"
    if (chevron) {
      chevron.style.transform = isHidden ? "rotate(0deg)" : "rotate(-90deg)"
    }
  }

  // Markdown rendering moved to services/chatbot_markdown.js (FBL-062).
  // These delegates keep every internal and mixin call site unchanged.
  formatMessage(content) {
    return formatMessage(content)
  }

  _renderTable(rows) {
    return renderTable(rows)
  }

  _inlineFormat(text) {
    return inlineFormat(text)
  }

  getMessageClasses(role) {
    return messageClasses(role)
  }

  // Update loading state
  updateLoadingState() {
    if (this.hasSendButtonTarget) {
      this.sendButtonTarget.disabled = this.loadingValue
    }
    if (this.hasLoadingTarget) {
      this.loadingTarget.classList.toggle("hidden", !this.loadingValue)
    }
    if (this.hasTypingIndicatorTarget) {
      if (this.loadingValue) {
        // Move typing indicator into messages area so it appears as an inline chat bubble
        if (this.hasMessagesTarget) {
          this.messagesTarget.appendChild(this.typingIndicatorTarget)
        }
        this.typingIndicatorTarget.classList.remove("hidden")
        this.scrollToBottom()
      } else {
        this.typingIndicatorTarget.classList.add("hidden")
      }
    }
    if (this.hasInputTarget) {
      this.inputTarget.disabled = this.loadingValue
    }
  }

  // Scroll to the newest content. The transcript is part of the page scroll
  // (no internal scrollbox), so follow the conversation by scrolling the
  // window; the element assignment stays as a no-op fallback for any embed
  // that does constrain the container.
  scrollToBottom() {
    if (!this.hasMessagesTarget) return
    this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
    const bottom = this.messagesTarget.getBoundingClientRect().bottom + window.scrollY
    window.scrollTo({ top: bottom - window.innerHeight + 120, behavior: "smooth" })
  }

  // Get CSRF token
  get csrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.content : ""
  }

  // NOTE: savePreferences() and loadPreferences() are defined in the
  // server-side persistence section of the settings_mixin. Browser storage is
  // limited to a rejected-login question handoff and a short-lived ciphertext-
  // only ZK save outbox; saved preferences/history remain server-backed.

  // Progress bar simulation (client-side)
  startProgress() {
    this.currentProgress = 0
    this._progressStartTime = performance.now()

    // Start the live stopwatch timer (now includes ETA)
    this._startStopwatch()

    // Start with visible progress immediately
    this.updateProgressBar(5, processingLabel(this.languageValue))

    // Simulate progress over expected ~20 second duration
    // (phase tables live in services/chatbot_progress.js, FBL-062)
    const phases = progressPhases(this.languageValue)

    let currentPhase = 0
    const advancePhase = () => {
      if (currentPhase < phases.length && this.progressInterval) {
        const phase = phases[currentPhase]
        this.updateProgressBar(phase.progress, `${phase.text}...`)
        currentPhase++
        this.progressInterval = setTimeout(advancePhase, phase.duration)
      }
    }

    this.progressInterval = setTimeout(advancePhase, 500)
  }

  stopProgress() {
    if (this.progressInterval) {
      clearTimeout(this.progressInterval)
      this.progressInterval = null
    }

    // Stop the stopwatch and show final time
    const elapsedStr = this._stopStopwatch()
    const finishedLabel = doneLabel(this.languageValue)

    // Show final bar
    if (this.hasProgressBarTarget) {
      this.progressBarTarget.style.width = '100%'
    }
    if (this.hasProgressTextTarget) {
      this.progressTextTarget.innerHTML = `✓ ${finishedLabel} <span class="font-mono tabular-nums text-xs ml-1 text-green-500">${elapsedStr}</span>`
    }

    setTimeout(() => {
      this.currentProgress = 0
    }, 300)
  }

  // Localized "Processing..." - shown when a progress event carries no label.
  _processingLabel() {
    return processingLabel(this.languageValue)
  }

  // Server progress events resolve in services/chatbot_progress.js
  // (FBL-062); an event without a usable percent keeps the bar in place.
  _applyServerProgress(parsed) {
    const { percent, label } = resolveServerProgress(parsed, this.languageValue, this.currentProgress)
    this.updateProgressBar(percent, label)
  }

  updateProgressBar(progress, text, elapsed = null) {
    // Monotonic clamp lives in services/chatbot_progress.js (FBL-062).
    const pct = clampProgress(progress, this.currentProgress)
    this.currentProgress = pct
    if (this.hasProgressBarTarget) {
      this.progressBarTarget.style.width = `${pct}%`
      this.progressBarTarget.setAttribute("aria-valuenow", String(Math.round(pct)))
    }
    if (this.hasProgressTextTarget) {
      const label = text || this._processingLabel()
      const rawSec = this._progressStartTime ? ((performance.now() - this._progressStartTime) / 1000).toFixed(1) : ""
      let timerStr
      if (elapsed !== null) {
        timerStr = elapsed
      } else if (rawSec) {
        timerStr = `${rawSec}s`
      } else {
        timerStr = ""
      }
      this.progressTextTarget.innerHTML = timerStr
        ? `${label} <span class="font-mono tabular-nums text-xs opacity-70 ml-1">${timerStr}</span>`
        : label
    }
  }

  // Live stopwatch - ticks every 100ms during loading, shows elapsed time
  _startStopwatch() {
    this._stopStopwatch() // clear any previous
    this._progressStartTime = performance.now()
    this._stopwatchInterval = setInterval(() => {
      if (!this._progressStartTime) return
      const sec = ((performance.now() - this._progressStartTime) / 1000).toFixed(1)
      // Update just the timer portion inside progressText
      if (this.hasProgressTextTarget) {
        const timerSpan = this.progressTextTarget.querySelector(".font-mono")
        if (timerSpan) {
          timerSpan.textContent = `${sec}s`
        }
      }
    }, 100)
  }

  _stopStopwatch() {
    if (this._stopwatchInterval) {
      clearInterval(this._stopwatchInterval)
      this._stopwatchInterval = null
    }
    if (this._progressStartTime) {
      const elapsed = ((performance.now() - this._progressStartTime) / 1000).toFixed(1) + "s"
      this._progressStartTime = null
      return elapsed
    }
    return null
  }

  // Auto-resize textarea to fit content (max 120px height)
  _autoResize() {
    if (!this.hasInputTarget) return
    const el = this.inputTarget
    el.style.height = 'auto'
    el.style.height = Math.min(el.scrollHeight, 120) + 'px'
  }

  // Language detection moved to services/chatbot_markdown.js (FBL-062).
  detectQuestionLanguage(text) {
    return detectQuestionLanguage(text, this.languageValue)
  }

  // ========================
  // Conversation Persistence
  // ========================

  // NOTE: _saveConversation(), _restoreConversation(), and _clearSavedConversation()
  // are defined in the server-side persistence section of the history_mixin.
  // Conversation history persists server-side; only an encrypted, short-lived
  // ZK PATCH outbox may be retained locally until the server acknowledges it.

  // Re-attach click handlers to suggestion buttons after HTML restoration
  _reattachSuggestionHandlers() {
    const container = this.messagesTarget.querySelector(".suggestions-container")
    if (!container) return
    container.querySelectorAll(".suggestion-btn").forEach(btn => {
      btn.addEventListener("click", () => {
        container.remove()
        // Use data-question attribute (clean text) to avoid credit badge text leaking into input
        this.inputTarget.value = btn.dataset.question || btn.querySelector('span:first-child')?.textContent || btn.textContent
        this.send()
      })
    })
  }

  // ========================
  // SSE Streaming Handler
  // ========================

  // Handle Server-Sent Events response from the backend
  async _handleSSEResponse(response, question, requestState = {}) {
    const reader = response.body.getReader()
    const decoder = new TextDecoder()
    let buffer = ""
    let resultReceived = false

    try {
      while (true) {
        const { done, value } = await reader.read()
        if (done) break

        // Frame parsing (chunk-boundary buffering, malformed-frame
        // skipping) lives in services/chatbot_stream_events.js (FBL-062).
        const chunk = parseSseChunk(buffer, decoder.decode(value, { stream: true }))
        buffer = chunk.buffer

        for (const parsed of chunk.events) {
          if (parsed.type === "error") {
            // Server-side error (e.g., login_required, insufficient_credits)
            requestState.clearDeadline?.()
            requestState.skipEncryptedPersistence = true
            this._applyCreditsInfo?.(parsed.credits_info, { visual: false })
            this._finishLoading()
            this.addMessage('error', sseErrorMessage(parsed, this.languageValue))
            resultReceived = true
          } else if (parsed.type === "progress") {
            // Real-time progress from server (raises the simulated bar)
            this._applyServerProgress(parsed)
            } else if (parsed.type === "heartbeat") {
            // Server heartbeat - LLM is still processing, keep connection alive
            // Update progress text to show elapsed time from server
            const heartbeat = heartbeatProgress(parsed.elapsed, this.languageValue)
            this.updateProgressBar(heartbeat.percent, heartbeat.label)
          } else if (parsed.type === "result") {
            // Final result received
            resultReceived = true
            // The complete terminal payload is now in the browser. Stop the
            // network deadline before typewriter/UI work so a long answer is
            // not mislabeled as a timeout after it was already delivered.
            requestState.clearDeadline?.()
            const data = parsed.data
            const guardedAnswer = sanitizeVisibleAssistantAnswer(data?.answer, this.languageValue)
            if (guardedAnswer.blocked) {
              data.answer = guardedAnswer.content
              data.error = guardedAnswer.content
              data.error_code = guardedAnswer.errorCode
              console.error('[AnswerSafety] Blocked an unsafe assistant payload')
            }
            this._finishLoading()

            if (data.error) {
              requestState.skipEncryptedPersistence = true
              this._applyCreditsInfo?.(data.credits_info, { visual: false })
              // A terminal timeout is a normal result payload: the server has
              // already refunded the reservation and supplies a localized
              // explanation in `answer`. Do not replace it with the internal
              // machine code (`timeout`) in the UI.
              this.addMessage("error", terminalErrorMessage(data))
            } else {
              if (requestState.conversationContextEpoch !== undefined &&
                  requestState.conversationContextEpoch !== (this._conversationContextEpoch || 0)) {
                return false
              }
              if (data.conversation_id) {
                if (this._recordConversationProtocolState(data, true)) {
                  this.conversationId = data.conversation_id
                } else {
                  requestState.skipEncryptedPersistence = true
                }
              }

              // Track analytic_id for feedback linking
              this.lastAnalyticId = data.analytic_id || null

              this.lastQuestionLang = this.detectQuestionLanguage(question)

              // Start encryption/persistence before the typewriter animation.
              // A reload after delivery can then retry the exact claimed
              // revision from the ciphertext-only outbox.
              if (data.zero_knowledge === true && !requestState.skipEncryptedPersistence &&
                  this._isZkReady()) {
                const stagedMessages = [
                  ...this.conversationHistory,
                  { role: 'assistant', content: data.answer, analytic_id: this.lastAnalyticId }
                ].slice(-50)
                const stagedPersistence = this._pushEncryptedConversation({
                  conversationId: this.conversationId,
                  masterKey: this._masterKey,
                  keyGeneration: this._zkKeyGeneration,
                  claimToken: this._zkClaimTokens?.get(this.conversationId),
                  claimExpiresAt: this._zkClaimExpiresAt?.get(this.conversationId),
                  messages: stagedMessages
                })
                stagedPersistence?.catch?.(() => {})
                requestState.encryptedPersistencePromise = stagedPersistence
              }

              const rendered = await this.streamMessage(
                "assistant",
                data.answer,
                data.sources,
                data.response_time,
                data.token_usage,
                requestState,
                data.rating_token
              )
              if (!rendered) return false

              this.conversationHistory.push({ role: "assistant", content: data.answer, analytic_id: this.lastAnalyticId })
              if (this.conversationHistory.length > 50) {
                this.conversationHistory = this.conversationHistory.slice(-50)
              }

              // Post-response UI updates - guarded so failures don't crash the SSE handler
              try {
                // Animate credit deduction + update pool counters
                this._applyCreditsInfo?.(data.credits_info)

                if (data.suggestions && data.suggestions.length > 0) {
                  this.showSuggestions(data.suggestions)
                }
              } catch (uiError) {
                console.warn('Post-result UI update failed (SSE, answer was delivered):', uiError.message)
              }
            }
          }
        }
      }

      // Safety net: if stream ended without a 'result' event, clean up loading state
      if (this.loadingValue) {
        this._finishLoading()
        this.addMessage("error", incompleteResponseMessage(this.languageValue))
      }
    } catch (streamError) {
      // User-initiated abort (clearChat/newConversation): the read was cancelled
      // on purpose. Every request is stream:true, so the abort surfaces HERE (not
      // in send()'s catch). Stay silent and consume the flag so it can't leak
      // into a later real timeout.
      if (this._userAborted) {
        this._userAborted = false
        this._finishLoading()
        return resultReceived
      }
      // A request deadline is handled by send() so users get the same timeout
      // message whether the abort happened before or after SSE headers arrived.
      if (requestState.timedOut && !resultReceived) throw streamError
      // Only show error if we never received the result - stream close after
      // a successful response is normal and should not alarm the user.
      if (resultReceived) {
        console.warn("Post-result stream close (harmless):", streamError.message)
        if (this.loadingValue) this._finishLoading()
      } else {
        console.error("SSE stream error:", streamError)
        this._finishLoading()
        this.addMessage("error", disconnectMessage(this.languageValue))
      }
    }

    return resultReceived
  }

  // Animate a floating deduction badge from the credit counter
  // creditsInfo: { credits_deducted, credits_remaining }
  _animateCreditDeduction(creditsInfo) {
    if (!creditsInfo?.credits_deducted || creditsInfo.credits_deducted <= 0) return

    const lang = this.languageValue || 'nl'
    const creditsL = lang === 'fr' ? 'crédits' : lang === 'en' ? 'credits' : 'credits'
    const pools = [{ amount: creditsInfo.credits_deducted, label: creditsL, anchor: 'credits-value', color: '#f59e0b' }]


    pools.forEach((pool, idx) => {
      const anchor = document.getElementById(pool.anchor) || document.getElementById('credits-remaining-value')
      if (!anchor) return

      const badge = document.createElement('span')
      badge.textContent = `−${pool.amount} ${pool.label}`
      badge.style.cssText = `
        position: fixed;
        font-size: 12px;
        font-weight: 700;
        color: ${pool.color};
        pointer-events: none;
        z-index: 9999;
        white-space: nowrap;
        text-shadow: 0 1px 3px rgba(0,0,0,0.15);
        animation: creditDeduct 1.6s ease-out forwards;
        animation-delay: ${idx * 0.2}s;
        opacity: 0;
      `

      const rect = anchor.getBoundingClientRect()
      // Start clear ABOVE the counter: anchoring at rect.top - 4 made the
      // badge sit directly on top of the number it reports, so the first
      // frames rendered "-1 credits" overlapping "494 credits".
      badge.style.left = `${rect.left + rect.width / 2}px`
      badge.style.top = `${rect.top - 22}px`
      badge.style.transform = 'translateX(-50%)'
      document.body.appendChild(badge)

      // Flash the specific pool counter
      anchor.style.transition = 'color 0.2s, transform 0.2s'
      const origColor = anchor.style.color
      anchor.style.color = '#ef4444'
      anchor.style.transform = 'scale(1.3)'
      setTimeout(() => {
        anchor.style.color = origColor || ''
        anchor.style.transform = ''
      }, 700)

      setTimeout(() => badge.remove(), 1800)
    })
  }

  // Privacy footer - once per conversation, after first answer
  _showPrivacyFooter() {
    const lang = this.languageValue || 'nl'
    const loggedIn = this._isLoggedIn()

    const msgs = loggedIn ? {
      nl: '🔒 Standaard bewaren wij geen chatgeschiedenis. Met Geschiedenis wordt zij serverversleuteld opgeslagen en kan WetWijzer ze technisch lezen; met een opslagwachtwoord wordt zij eerst in uw browser versleuteld en kunnen wij ze niet ontsleutelen. Uw actuele vraag en relevante context worden tijdelijk verwerkt door WetWijzer en de gekozen AI-provider. Credits betalen het gegenereerde antwoord; het bewaren van geschiedenis is een afzonderlijke stap.',
      fr: '🔒 Par défaut, nous ne conservons pas l\'historique. Avec Historique, il est chiffré sur le serveur mais reste techniquement lisible par WetWijzer ; avec un mot de passe de stockage, il est d\'abord chiffré dans votre navigateur et nous ne pouvons pas le déchiffrer. Votre question actuelle et le contexte pertinent sont traités temporairement par WetWijzer et le fournisseur d\'IA choisi. Les crédits paient la réponse générée ; l\'enregistrement de l\'historique est une étape distincte.',
      de: '🔒 Standardmäßig speichern wir keinen Chatverlauf. Mit Verlauf wird er serverseitig verschlüsselt, bleibt für WetWijzer aber technisch lesbar; mit Speicherpasswort wird er zuerst im Browser verschlüsselt und kann von uns nicht entschlüsselt werden. Ihre aktuelle Frage und der relevante Kontext werden vorübergehend von WetWijzer und dem gewählten KI-Anbieter verarbeitet. Credits bezahlen die erzeugte Antwort; das Speichern des Verlaufs ist ein separater Schritt.',
      en: '🔒 By default, we do not save chat history. With History, it is encrypted on the server but remains technically readable by WetWijzer; with a storage password, it is first encrypted in your browser and we cannot decrypt it. Your current question and relevant context are temporarily processed by WetWijzer and the selected AI provider. Credits pay for the generated answer; saving history is a separate step.'
    } : {
      nl: '🔒 Er wordt geen chatgeschiedenis bewaard. Uw actuele vraag en relevante context worden tijdelijk verwerkt door WetWijzer en de gekozen AI-provider om het antwoord te maken; beperkte technische metadata kan worden gelogd.',
      fr: '🔒 Aucun historique de conversation n\'est conservé. Votre question actuelle et le contexte pertinent sont traités temporairement par WetWijzer et le fournisseur d\'IA choisi pour produire la réponse ; des métadonnées techniques limitées peuvent être journalisées.',
      de: '🔒 Es wird kein Chatverlauf gespeichert. Ihre aktuelle Frage und der relevante Kontext werden zur Erstellung der Antwort vorübergehend von WetWijzer und dem gewählten KI-Anbieter verarbeitet; begrenzte technische Metadaten können protokolliert werden.',
      en: '🔒 No chat history is saved. Your current question and relevant context are temporarily processed by WetWijzer and the selected AI provider to produce the answer; limited technical metadata may be logged.'
    }

    const footer = document.createElement('div')
    footer.className = 'mt-2 mb-1 px-3 py-2 text-[10px] text-gray-400 dark:text-gray-500 text-center leading-relaxed select-none'
    footer.textContent = msgs[lang] || msgs.nl

    this.messagesTarget.appendChild(footer)
    this.scrollToBottom()
  }

  // Update individual credit pool counters with values from server
  _showDeductionReceipt(creditsInfo) {
    if (!creditsInfo?.credits_deducted) return

    const lang2 = this.languageValue || 'nl'
    const creditsL2 = lang2 === 'fr' ? 'crédits' : lang2 === 'en' ? 'credits' : 'credits'
    const deductionText = `${creditsInfo.credits_deducted} ${creditsL2}`
    const remaining = creditsInfo.credits_remaining || 0
    const remainText = lang2 === 'fr' ? `restant: ${remaining}`
      : lang2 === 'en' ? `remaining: ${remaining}`
      : lang2 === 'de' ? `verbleibend: ${remaining}`
      : `resterend: ${remaining}`

    const receipt = document.createElement('div')
    receipt.className = 'text-[10px] text-gray-400 dark:text-gray-500 text-right mt-1 flex items-center justify-end gap-1.5 credit-receipt'

    let html = `<span style="color: #ef4444;">−${deductionText}</span> <span class="opacity-60">|</span> <span>${remainText}</span>`

    const lang = this.languageValue || 'nl'
    const isPro = this.proValue

    // Low-credits upsell CTA (≤ 3 remaining)
    if (remaining <= 3) {
      if (!isPro) {
        const upgradeText = lang === 'fr' ? 'Passez à Pro' : lang === 'en' ? 'Upgrade to Pro' : lang === 'de' ? 'Auf Pro upgraden' : 'Upgrade naar Pro'
        const buyText = lang === 'fr' ? 'Achetez des crédits' : lang === 'en' ? 'Buy credits' : lang === 'de' ? 'Credits kaufen' : 'Koop credits'
        html += ` <span class="opacity-40">|</span> <a href="/pricing" class="text-amber-500 hover:text-amber-400 hover:underline font-medium">${upgradeText}</a> <span class="opacity-30">·</span> <a href="/credits" class="hover:underline">${buyText}</a>`
      } else {
        const buyText = lang === 'fr' ? 'Achetez des crédits' : lang === 'en' ? 'Buy credits' : lang === 'de' ? 'Credits kaufen' : 'Koop credits'
        html += ` <span class="opacity-40">|</span> <a href="/credits" class="text-amber-500 hover:text-amber-400 hover:underline font-medium">${buyText}</a>`
      }
    }

    receipt.innerHTML = html

    // Fade in
    receipt.style.opacity = '0'
    receipt.style.transition = 'opacity 0.4s'

    if (this.hasMessagesTarget) {
      this.messagesTarget.appendChild(receipt)
      requestAnimationFrame(() => { receipt.style.opacity = '1' })
    }
  }

  // Build the slide-in history sidebar shell (contents render via history_mixin)
  _createHistorySidebar() {
    const _t = (map) => map[this.languageValue] || map.nl
    const sidebar = document.createElement("div")
    sidebar.className = "chat-history-sidebar hidden absolute top-0 left-0 w-72 h-full bg-white dark:bg-gray-800 border-r border-gray-200 dark:border-gray-700 z-50 flex flex-col shadow-xl rounded-l-xl overflow-hidden"

    const headerTitle = _t({ nl: "Gesprekken", fr: "Conversations", de: "Gespräche", en: "Conversations" })
    const newBtnLabel = _t({ nl: "Nieuw", fr: "Nouveau", de: "Neu", en: "New" })
    const disableHistoryLabel = _t({
      nl: 'Geschiedenis uitschakelen en alles verwijderen',
      fr: "Désactiver l’historique et tout supprimer",
      de: 'Verlauf deaktivieren und alles löschen',
      en: 'Disable history and delete all'
    })
    const storageActionsVisibility = this._shouldPersist() ? '' : 'hidden'

    sidebar.innerHTML = `
      <div class="flex items-center justify-between p-3 border-b border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-900/50">
        <h3 class="text-sm font-semibold text-gray-700 dark:text-gray-300">${headerTitle}</h3>
        <div class="flex gap-1">
          <button type="button" data-action="click->chatbot#newConversation"
                  class="text-xs px-2.5 py-1 rounded-lg bg-(--accent-600-solid) text-white hover:bg-(--accent-700-solid) transition-colors">
            + ${newBtnLabel}
          </button>
          <button type="button" data-action="click->chatbot#toggleHistory"
                  class="p-1 text-gray-400 hover:text-gray-600 dark:hover:text-(--accent-400)">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
            </svg>
          </button>
        </div>
      </div>
      <div class="chat-history-list flex-1 overflow-y-auto p-2 space-y-1"></div>
      <div data-history-storage-actions class="${storageActionsVisibility} shrink-0 border-t border-gray-200 dark:border-gray-700 p-2">
        <button type="button"
                data-action="click->chatbot#disableAndDeleteHistory"
                data-history-disable-control
                class="w-full px-2 py-2 text-[11px] font-medium text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950/30 rounded-lg transition-colors">
          ${disableHistoryLabel}
        </button>
      </div>
    `
    return sidebar
  }

  // The clicked control, described in the interface language, when it is an
  // intelligence level. Notches and pills carry different attribute names for
  // the same two facts.
  _lockedAnchorSubject(anchor) {
    if (!anchor?.dataset) return null

    const lang = this.languageValue || 'nl'
    const labelKey = { nl: 'labelNl', fr: 'labelFr', de: 'labelDe', en: 'labelEn' }[lang] || 'labelNl'
    const descKey = { nl: 'descNl', fr: 'descFr', de: 'descDe', en: 'descEn' }[lang] || 'descNl'

    if (anchor.dataset.intelligenceLevel) {
      return {
        name: anchor.dataset[labelKey] || anchor.querySelector?.('.notch-text')?.textContent?.trim() || '',
        desc: anchor.dataset[descKey] || ''
      }
    }
    if (anchor.dataset.widgetLevel) {
      return { name: anchor.dataset.widgetLabel || '', desc: anchor.dataset.widgetDesc || '' }
    }
    return null
  }

  _showProTooltip(anchor) {
    // Remove any existing tooltip
    const existing = document.getElementById('pro-upgrade-tooltip')
    if (existing) { existing.remove(); return }

    const lang = this.languageValue || 'nl'
    // Named from the anchor when it is an intelligence level, so the tooltip
    // says what that level does rather than what the account lacks. A locked
    // source has no such description and gets the general line.
    const msg = proTooltipCopy(lang, this._lockedAnchorSubject(anchor))

    const tooltip = document.createElement('div')
    tooltip.id = 'pro-upgrade-tooltip'
    tooltip.className = 'px-4 py-3 bg-gray-900 text-white text-xs rounded-lg shadow-xl border border-amber-500/30'
    tooltip.style.cssText = 'position:fixed; z-index:9999; min-width:220px; max-width:280px; animation: fadeIn 0.15s ease-out; pointer-events:auto;'
    tooltip.innerHTML = `
      <p class="mb-2">${msg.text}</p>
      <a href="/pricing" class="text-amber-400 hover:text-amber-300 font-medium underline underline-offset-2">${msg.link}</a>
      <div class="absolute top-full left-1/2 -translate-x-1/2 border-4 border-transparent border-t-gray-900"></div>
    `

    // Position above anchor using fixed coordinates (no layout shift)
    document.body.appendChild(tooltip)
    const rect = anchor.getBoundingClientRect()
    const tooltipRect = tooltip.getBoundingClientRect()
    tooltip.style.left = `${rect.left + rect.width / 2 - tooltipRect.width / 2}px`
    tooltip.style.top = `${rect.top - tooltipRect.height - 8}px`

    // Auto-dismiss after 5s or on click-outside
    const dismiss = (e) => {
      if (e && tooltip.contains(e.target)) return
      tooltip.remove()
      document.removeEventListener('click', dismiss)
    }
    setTimeout(() => document.addEventListener('click', dismiss), 100)
    setTimeout(() => { if (document.getElementById('pro-upgrade-tooltip')) tooltip.remove() }, 5000)
  }

  // The intelligence levels this page offers, in server order. Parsing lives
  // in the service so what the user is offered can be tested without a browser.
  _intelligenceChoices() {
    return readIntelligenceChoices(document, this.languageValue || 'nl')
  }

  _bestUnlockedChoice(choices, excludeId) {
    return bestUnlockedChoice(choices, excludeId)
  }

  // Switch the selection through the control that is actually on screen, so
  // the slider, the pills, the model dropdown, the credit display and the
  // saved preference all move together - rather than the value changing behind
  // a UI still showing the locked level.
  _selectIntelligenceChoice(choice) {
    const slider = document.getElementById('intelligence-range')
    if (slider) {
      slider.value = choice.index
      slider.dispatchEvent(new Event('input', { bubbles: true }))
    } else {
      choice.element?.click()
    }

    // The gate decides whether a question may be sent at all, so it is set
    // here rather than trusted to come back from the handler above.
    this._selectedLevelLocked = false
    this._selectedLevelTier = choice.tier
    this.intelligenceValue = choice.id
  }

  // Shown when a question is sent with an intelligence level the account
  // cannot use. This is the ONE moment where someone has already written a
  // question and pressed send, which makes it the worst possible place for a
  // dead end - and a dead end is what it was: it announced "<level> requires
  // Pro", offered a pricing link, and left the question sitting in the box
  // behind the overlay with the locked level still selected, so pressing send
  // again reopened the same wall.
  //
  // It now leads with what the locked level would add, and always offers an
  // answer NOW: one click drops to the best level this account does have and
  // sends the question. Upgrading stays the prominent path, it is simply no
  // longer the only one.
  _showLockedTierModal(tier) {
    // Reopening used to remove the old overlay by id and leave its keydown
    // listener bound to a detached node forever.
    this._closeLockedTierModal()

    const lang = this.languageValue || 'nl'
    const isPurchasedTier = tier === 'purchased'
    const escape = escapeLockedTierText

    const choices = this._intelligenceChoices()
    const current = choices.find(choice => choice.id === this.intelligenceValue)
    const fallback = this._bestUnlockedChoice(choices, this.intelligenceValue)
    const levelName = escape(current?.name || this.intelligenceValue)
    const levelDesc = escape(current?.desc || '')

    const msg = lockedTierCopy(lang, { purchasable: isPurchasedTier })

    const lead = lockedTierLead(levelName, levelDesc, msg.availability)

    const overlay = document.createElement('div')
    overlay.id = 'locked-tier-modal'
    overlay.style.cssText = 'position:fixed; inset:0; z-index:9999; display:flex; align-items:center; justify-content:center; background:rgba(0,0,0,0.5); backdrop-filter:blur(4px); animation:fadeIn 0.15s ease-out;'

    const buyBtnHtml = isPurchasedTier
      ? `<a href="/credits" data-locked-tier-action="credits"
             class="w-full text-center px-4 py-2.5 rounded-lg font-semibold text-sm transition-all shadow-md hover:shadow-lg
                    bg-gradient-to-r from-blue-600 to-indigo-600 hover:from-blue-700 hover:to-indigo-700 text-white">${msg.buyBtn}</a>`
      : ''

    // Offered only when the account actually has a level to fall back to.
    const continueBtnHtml = fallback
      ? `<button type="button" id="locked-tier-modal-continue"
                 class="w-full text-center px-4 py-2.5 rounded-lg font-medium text-sm transition-colors
                        border border-gray-200 dark:border-gray-600 text-gray-700 dark:text-gray-200
                        hover:bg-gray-50 dark:hover:bg-gray-700/60">${msg.continueBtn(escape(fallback.name))}</button>`
      : ''

    // The card must NOT carry .animate-entrance. That class sets opacity:0 and
    // relies on its own forwards-filled animation to bring the element back,
    // but an inline animation shorthand overrides the class animation AND
    // resets fill-mode to none - so the card faded in over 0.2s and then
    // dropped straight back to opacity 0. Measured on the live page: a dimmed,
    // blurred screen with no dialog on it. That was "the Pro popup is broken".
    // The both fill-mode keeps the final frame whatever a future class adds.
    overlay.innerHTML = `
      <div role="dialog" aria-modal="true"
           aria-labelledby="locked-tier-modal-title" aria-describedby="locked-tier-modal-lead"
           class="bg-white dark:bg-gray-800 rounded-2xl shadow-2xl border border-gray-200 dark:border-gray-700 p-6 max-w-sm w-full mx-4" style="animation: fadeIn 0.2s ease-out both;">
        <div class="text-center mb-4">
          <div class="w-14 h-14 mx-auto mb-3 rounded-full bg-amber-100 dark:bg-amber-900/40 flex items-center justify-center">
            <span class="text-2xl">${isPurchasedTier ? '&#128179;' : '&#10024;'}</span>
          </div>
          <h3 id="locked-tier-modal-title" class="text-base font-bold text-gray-900 dark:text-white mb-1">${msg.title}</h3>
          <p id="locked-tier-modal-lead" class="text-sm text-gray-600 dark:text-gray-400">${lead}</p>
        </div>
        <div class="flex flex-col gap-2 mb-3">
          ${buyBtnHtml}
          <a href="/pricing" data-locked-tier-action="pro"
             class="w-full text-center px-4 py-2.5 rounded-lg font-semibold text-sm transition-all shadow-md hover:shadow-lg
                    bg-gradient-to-r from-amber-500 to-amber-600 hover:from-amber-600 hover:to-amber-700 text-white">${msg.proBtn}</a>
          ${continueBtnHtml}
        </div>
        <button type="button" id="locked-tier-modal-close"
                class="w-full text-center text-xs text-gray-400 dark:text-gray-500 hover:text-gray-600 dark:hover:text-(--accent-400) py-1 transition-colors cursor-pointer">
          ${msg.close}
        </button>
      </div>
    `

    // FBL-047 modal contract, the same one the consent dialog follows: remember
    // the opener, move focus in, trap Tab, close on Escape, put focus back.
    // Captured BEFORE the overlay is attached, or the opener has already lost
    // focus to the document.
    this._lockedTierPreviousFocus = document.activeElement
    document.body.appendChild(overlay)
    this._trackEvent('chatbot-locked-tier-offer', { tier: tier, level: this.intelligenceValue })

    const focusables = () => Array.from(overlay.querySelectorAll(
      'a[href], button:not([disabled])'
    )).filter((element) => element.offsetParent !== null)

    const keyHandler = (event) => {
      if (event.key === 'Escape') {
        // Stopped here on purpose: the chatbot's own Escape handler would
        // otherwise close the whole widget behind this dialog, losing the
        // question the user just typed.
        event.preventDefault()
        event.stopPropagation()
        close()
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
      } else if (!overlay.contains(document.activeElement)) {
        // Focus escaped some other way (a browser gesture, a stale target):
        // pull it back rather than letting Tab walk the page behind.
        event.preventDefault()
        first.focus()
      }
    }

    // Idempotent: close runs from the button, the backdrop, Escape, the
    // fallback action and disconnect, and any of them can arrive twice.
    const close = () => {
      overlay.remove()
      this._lockedTierClose = null
      if (this._lockedTierKeyHandler) {
        document.removeEventListener('keydown', this._lockedTierKeyHandler, true)
        this._lockedTierKeyHandler = null
      }
      const opener = this._lockedTierPreviousFocus
      this._lockedTierPreviousFocus = null
      if (opener?.isConnected && typeof opener.focus === 'function') {
        opener.focus({ preventScroll: true })
        return
      }
      // A Turbo visit can replace the opener while the dialog is open. Leaving
      // focus on a detached node drops the caret to the top of the document,
      // which for a keyboard user means starting the page again.
      this._focusChatbotFallback()
    }
    this._lockedTierClose = close

    overlay.querySelector('#locked-tier-modal-close').addEventListener('click', close)
    overlay.addEventListener('click', (e) => { if (e.target === overlay) close() })
    // Capture phase, so the trap sees Tab and Escape before anything the page
    // behind the dialog has bound.
    this._lockedTierKeyHandler = keyHandler
    document.addEventListener('keydown', keyHandler, true)

    overlay.querySelectorAll('[data-locked-tier-action]').forEach((link) => {
      link.addEventListener('click', () => {
        this._trackEvent('chatbot-locked-tier-upgrade', { target: link.dataset.lockedTierAction, level: this.intelligenceValue })
      })
    })

    overlay.querySelector('#locked-tier-modal-continue')?.addEventListener('click', () => {
      this._trackEvent('chatbot-locked-tier-fallback', { from: this.intelligenceValue, to: fallback.id })
      close()
      this._selectIntelligenceChoice(fallback)
      this.send()
    })

    // The offer is why the modal is here, so it takes focus - after the
    // overlay is on screen, and without scrolling the page behind it. The card
    // itself is the fallback, so focus can never be left outside the dialog.
    const initial = overlay.querySelector('[data-locked-tier-action="pro"]') || focusables()[0]
    if (initial) {
      initial.focus({ preventScroll: true })
    } else {
      const card = overlay.querySelector('[role="dialog"]')
      card?.setAttribute('tabindex', '-1')
      card?.focus({ preventScroll: true })
    }
  }

  // Somewhere sensible and still connected, in descending order of usefulness:
  // the question box the user was typing in, the send button beside it, then
  // the chatbot container itself.
  _focusChatbotFallback() {
    const candidates = [
      this.hasInputTarget ? this.inputTarget : null,
      document.querySelector('[data-chatbot-target="input"]'),
      document.querySelector('[data-action*="chatbot#send"]'),
      this.element
    ].filter((node) => node?.isConnected && typeof node.focus === 'function')

    // Try each and CHECK. On most pages the widget is collapsed, so the
    // question box and the send button are display:none - calling focus() on
    // them succeeds silently and leaves the caret on <body>, which is the
    // outcome this fallback exists to prevent. Only the browser can say
    // whether a node actually took focus, so ask it.
    for (const node of candidates) {
      if (node === this.element && !node.hasAttribute('tabindex')) node.setAttribute('tabindex', '-1')
      node.focus({ preventScroll: true })
      if (document.activeElement === node) return
    }
  }

  // One teardown for every path, including Turbo disconnect. Safe to call when
  // no modal is open.
  _closeLockedTierModal() {
    if (this._lockedTierClose) {
      const close = this._lockedTierClose
      this._lockedTierClose = null
      close()
      return
    }
    document.getElementById('locked-tier-modal')?.remove()
    if (this._lockedTierKeyHandler) {
      document.removeEventListener('keydown', this._lockedTierKeyHandler, true)
      this._lockedTierKeyHandler = null
    }
  }

  // Umami event tracking helper - no-op if Umami is not loaded (dev/staging)
  _trackEvent(name, data = {}) {
    try {
      if (typeof umami !== 'undefined') {
        umami.track(name, data)
      }
    } catch (_) { /* Umami not available */ }
  }
  loadPreferences() {
    try {
      const savedPreferences = prefsStore.get('chatbot', null)
      if (!savedPreferences) return

      // Preserve the user's intended model family across portfolio upgrades.
      // Generic dropdown fallback would silently select another model in the
      // same tier (for example GPT-5 instead of Terra).
      const migration = migrateChatbotModelPreference(savedPreferences)
      const chatPrefs = migration.preferences
      if (migration.migrated) prefsStore.set('chatbot', chatPrefs)

      // Skip intelligence if hero just applied an override (prevents async race)
      if (chatPrefs.intelligence && !this._heroOverrideActive) this.intelligenceValue = chatPrefs.intelligence
      if (chatPrefs.model) this.modelOverrideValue = chatPrefs.model
      // Profile/category intentionally NOT restored — always starts at "general"
      // and auto-sets when user clicks a sample question.
      if (chatPrefs.source) this.sourceValue = chatPrefs.source
      if (chatPrefs.reasoningLevel) this.reasoningLevelValue = chatPrefs.reasoningLevel
    } catch (e) {
      // Corrupted prefs - ignore
    }
  }

  savePreferences() {
    try {
      prefsStore.set('chatbot', {
        intelligence: this.intelligenceValue,
        model: this.modelOverrideValue,
        // Profile/category intentionally NOT saved — resets to "general" each session.
        source: this.sourceValue,
        reasoningLevel: this.reasoningLevelValue
      })
    } catch (e) {
      // Profile save failed - ignore
    }
  }

  // Wait for server-side preferences to load, then re-sync everything.
  // Called once from connect(). The eager prefs.init() in application.js
  // starts the fetch; this just awaits its completion.
  async _initPreferencesAsync() {
    try {
      await prefsStore.init()
      // Re-load values now that the server cache is populated
      this.loadPreferences()
      // Re-sync all UI controls to match loaded preferences
      this._syncSlidersFromPreferences()
      this._syncWidgetPills()
      this._syncSourceCheckboxes()
    } catch (e) {
      // Server unreachable - continue with defaults
    }
  }

  // Sync sliders/dropdowns to match loaded preferences
  _getAuthState() {
    const el = document.getElementById('chatbot-auth-state')
    if (!el) return { loggedIn: false, consent: false }
    return {
      loggedIn: el.dataset.loggedIn === 'true',
      consent: el.dataset.consent === 'true'
    }
  }

  // Update consent state in the DOM (after user accepts)
  _shouldPersist() {
    if (this._hasConsent !== undefined) return this._hasConsent
    const { loggedIn, consent } = this._getAuthState()
    this._hasConsent = loggedIn && consent
    return this._hasConsent
  }

  _isLoggedIn() {
    const { loggedIn } = this._getAuthState()
    return loggedIn
  }

  // Read and consume a pending question from the URL hash fragment (#q=...).
  // Also reads &profile= if present (from hero sample question clicks).
  // Hash fragments are never sent to the server, never in referrer headers,
  // never in server logs - truly zero traces for anonymous users.
  // Enrich question with law page context when user is viewing a specific law.
  // This ensures FAISS search finds the correct law articles when the user asks
  // questions like "wanneer treedt deze wet in werking?" (when does THIS law take effect).
  // The enrichment is invisible to the user - they see their original question in the UI.
  // Only enriches when: (1) on a law page, (2) first question or deictic reference detected.
  _enrichQuestionWithLawContext(question) {
    const ctxMeta = document.querySelector('meta[name="chatbot-context"]')
    if (!ctxMeta) return question

    const lawTitle = ctxMeta.dataset.lawTitle
    if (!lawTitle) return question

    // Always prepend context for the first question in the conversation
    // For follow-ups, only enrich if the question contains deictic references
    // ("deze wet", "cette loi", "this law", "dieses Gesetz", "het", "er", "ils", etc.)
    const isFirstQuestion = !this.conversationId
    const deicticPatterns = /\b(deze\s+wet|dit\s+wetboek|dit\s+decreet|deze\s+wet\b|hierover|hierin|hierboven|cette\s+loi|ce\s+code|this\s+law|this\s+act|dieses\s+gesetz)\b/i
    const hasDeicticRef = deicticPatterns.test(question)

    if (isFirstQuestion || hasDeicticRef) {
      return `[Context: de gebruiker bekijkt momenteel "${lawTitle}"]\n\n${question}`
    }

    return question
  }

  _consumeHashQuestion() {
    const hash = window.location.hash
    if (!hash || hash.length < 3) return null

    // Parse hash fragment as key=value pairs (e.g. #q=question&profile=social)
    const params = {}
    hash.slice(1).split('&').forEach(part => {
      const [key, ...rest] = part.split('=')
      // A malformed %-sequence throws URIError — this runs inside connect(),
      // so an uncaught throw would abort the whole controller setup
      if (key) {
        try {
          params[key] = decodeURIComponent(rest.join('='))
        } catch {
          /* skip undecodable value */
        }
      }
    })

    const q = (params.q || '').trim()
    if (!q) return null

    // Pre-select profile if provided
    const profile = (params.profile || '').trim()
    if (profile) {
      const profileSelect = document.getElementById('profile-select')
      if (profileSelect) {
        // Verify the option exists before setting
        const optionExists = Array.from(profileSelect.options).some(o => o.value === profile)
        if (optionExists) {
          profileSelect.value = profile
          this.profileValue = profile
          profileSelect.dispatchEvent(new Event('change', { bubbles: true }))
        }
      }
    }

    // Clear the hash fragment from the URL bar without triggering navigation
    history.replaceState(null, '', window.location.pathname + window.location.search)
    return q
  }

  // Reset the active conversation in memory. Nothing is stored client-side,
  // so there is no browser storage to clear here — the server-side "archive"
  // (see clearChat) is what makes a cleared conversation stop auto-restoring.
  _clearSavedConversation() {
    this.conversationHistory = []
    this.conversationId = null
    this.messageCount = 0
    this._currentLawNumac = null
  }

  // ── Server-tracked shared conversation (widget ↔ full page) ──
  // ZERO browser storage: the active conversation is tracked entirely
  // server-side. On page load we ask the server for the consented user's
  // active (non-archived) conversation and render it, so the widget and the
  // full /chatbot page always show the same log. Async; degrades silently to
  // the welcome screen on any failure. Skips if a conversation is in progress.
  async _restoreActiveConversation() {
    if (!this._shouldPersist()) return
    if (this.conversationId && this.conversationHistory?.length) return
    const contextEpoch = this._conversationContextEpoch || 0

    try {
      const response = await fetch('/api/chatbot/active_conversation')
      if (!response.ok) return

      const data = await response.json()
      if (!data.active) return

      let messages = data.messages || []

      // Zero-knowledge conversations are ciphertext server-side; only render
      // once the master key is unlocked, otherwise leave the welcome screen.
      if (data.zero_knowledge) {
        if (data.encrypted_messages && this._isZkReady()) {
          messages = (await ConversationCrypto.decryptPayload(data.encrypted_messages, this._masterKey)) || []
        } else {
          return
        }
      }

      if (!Array.isArray(messages) || !messages.length) return

      // Re-check AFTER the awaits: the user may have started a conversation
      // during the fetch (hash auto-send, or fast typing). Rendering here
      // would clobber the in-flight question/answer and wipe the DOM.
      if (this.loadingValue) return
      if (this.conversationId && this.conversationHistory?.length) return
      if (contextEpoch !== (this._conversationContextEpoch || 0)) return

      if (!this._recordConversationProtocolState(data)) return

      const safeMessages = sanitizeRestoredMessages(messages, this.languageValue)
      if (!safeMessages.length) return
      this.conversationId = data.id
      this.conversationHistory = safeMessages
      this.messageCount = data.message_count || safeMessages.length
      if (this.hasMessagesTarget) {
        this._renderMessagesFromData(safeMessages)
        this.scrollToBottom()
      }
    } catch (e) {
      // Network error — keep the welcome screen, no user-facing failure.
    }
  }

  // Archive the current conversation server-side so it stops auto-restoring
  // (it stays in history). Called from clearChat. No-op without an active
  // conversation or consent.
  async _archiveActiveConversation() {
    if (!this._shouldPersist() || !this.conversationId) return true
    const token = this.conversationId
    try {
      const response = await fetch(`/api/chatbot/conversations/${encodeURIComponent(token)}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': this.csrfToken },
        body: JSON.stringify({ archived: true, cancel_active_claim: true })
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      this._zkClaimTokens?.delete(token)
      this._zkClaimExpiresAt?.delete(token)
      this._conversationRevisions?.delete(token)
      this._zkConversationIds?.delete(token)
      return true
    } catch (error) {
      console.error('[History] Failed to archive active conversation:', error)
      this._showToast(
        { nl: 'Het gesprek kon niet veilig worden gewist. Probeer opnieuw.', fr: "La conversation n'a pas pu être effacée en toute sécurité. Réessayez.", de: 'Das Gespräch konnte nicht sicher gelöscht werden. Versuchen Sie es erneut.', en: 'The conversation could not be cleared safely. Try again.' }[this.languageValue] || 'Het gesprek kon niet veilig worden gewist. Probeer opnieuw.',
        'error'
      )
      return false
    }
  }

  // Add law context notification when user navigates to a new law page
  // with an existing conversation. Instead of clearing chat, adds a
  // context-switch message.
  _addLawContextIfNew() {
    const ctxMeta = document.querySelector('meta[name="chatbot-context"]')
    if (!ctxMeta) return // Not a law page

    const lawTitle = ctxMeta.dataset.lawTitle
    const lawNumac = ctxMeta.dataset.lawNumac
    if (!lawTitle) return

    // Skip if we're still on the same law
    if (this._currentLawNumac === lawNumac) return
    this._currentLawNumac = lawNumac

    // Build context notification
    const _t = (msgs) => msgs[this.languageValue] || msgs.nl
    const ctxMsg = _t({
      nl: `📜 U bekijkt nu **${lawTitle}**. Stel gerust uw vragen hierover!`,
      fr: `📜 Vous consultez maintenant **${lawTitle}**. Posez-moi vos questions!`,
      en: `📜 You're now viewing **${lawTitle}**. Ask me anything about it!`,
      de: `📜 Sie sehen jetzt **${lawTitle}**. Stellen Sie mir Ihre Fragen dazu!`
    })

    // Add as a system/assistant notification (not a real Q&A)
    const messageDiv = document.createElement('div')
    messageDiv.className = this.getMessageClasses('assistant')
    messageDiv.dataset.messageId = ++this.messageCount
    messageDiv.dataset.contextSwitch = 'true'

    const contentDiv = document.createElement('div')
    contentDiv.className = 'message-content'
    contentDiv.innerHTML = this.formatMessage(ctxMsg)
    messageDiv.appendChild(contentDiv)

    if (this.hasMessagesTarget) {
      this.messagesTarget.appendChild(messageDiv)
      this.scrollToBottom()
    }
  }

  // Re-attach event handlers to interactive elements after HTML restoration
  _reattachRestoredHandlers() {
    if (!this.hasMessagesTarget) return

    // Re-attach suggestion button handlers
    this._reattachSuggestionHandlers()

    // NOTE: feedback buttons use Stimulus data-action attributes, which
    // rebind automatically on restored HTML — no manual rebinding needed.

    // Re-attach deep analysis button handlers
    this.messagesTarget.querySelectorAll('[data-deep-analysis-btn]').forEach(btn => {
      const newBtn = btn.cloneNode(true)
      btn.replaceWith(newBtn)
      newBtn.addEventListener('click', (e) => this.deepAnalysis(e))
    })
  }
  _renderMessagesFromData(messages) {
    if (!this.hasMessagesTarget) return
    this.messagesTarget.innerHTML = ''

    for (const msg of sanitizeRestoredMessages(messages, this.languageValue)) {
      if (msg.role === 'user') {
        this._addMessageToUI('user', msg.content)
      } else if (msg.role === 'assistant') {
        this._addMessageToUI('assistant', msg.content)
      }
    }
  }

  _sanitizeRestoredMessages(messages) {
    return sanitizeRestoredMessages(messages, this.languageValue)
  }

  // Helper: add a rendered message bubble to the UI
  _addMessageToUI(role, content) {
    if (!this.hasMessagesTarget) return

    const wrapper = document.createElement('div')
    wrapper.className = role === 'user'
      ? 'flex justify-end mb-4'
      : 'flex justify-start mb-4'

    const bubble = document.createElement('div')
    if (role === 'user') {
      bubble.className = 'max-w-[85%] sm:max-w-[75%] px-4 py-3 rounded-2xl rounded-br-md bg-blue-600 text-white text-sm leading-relaxed'
      bubble.textContent = content
    } else {
      bubble.className = 'max-w-[85%] sm:max-w-[75%] px-4 py-3 rounded-2xl rounded-bl-md bg-gray-100 dark:bg-gray-700 text-gray-900 dark:text-gray-100 text-sm leading-relaxed prose dark:prose-invert prose-sm max-w-none'
      // Stored assistant content is raw markdown — render through the same
      // escaping formatter as the live path (never raw innerHTML)
      bubble.innerHTML = this.formatMessage(content)
    }

    wrapper.appendChild(bubble)
    this.messagesTarget.appendChild(wrapper)
  }

  // Transient status toast
  _showToast(message, type = 'info') {
    const toast = document.createElement('div')
    const colors = {
      success: 'bg-green-600',
      error: 'bg-red-600',
      info: 'bg-gray-700'
    }
    toast.className = `fixed bottom-20 left-1/2 -translate-x-1/2 ${colors[type] || colors.info} text-white text-sm px-4 py-2 rounded-lg shadow-lg z-[9999] transition-opacity duration-300`
    toast.textContent = message
    document.body.appendChild(toast)
    setTimeout(() => {
      toast.style.opacity = '0'
      setTimeout(() => toast.remove(), 300)
    }, 2000)
  }

  // HTML escape helper
}

// Apply mixins to the controller prototype.
// Methods use `this` and behave identically to class methods.
// NOTE: must copy property descriptors, not values — Object.assign would
// invoke accessor properties (get _intelligenceLevels() etc.) once at module
// evaluation time and freeze their snapshot onto the prototype.
for (const mixin of [settingsMethods, creditsMethods, historyMethods, exportMethods, layoutMethods, encryptedPersistenceMethods, ratingMethods]) {
  Object.defineProperties(ChatbotController.prototype, Object.getOwnPropertyDescriptors(mixin))
}

export default ChatbotController
