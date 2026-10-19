import { Controller } from "@hotwired/stimulus"
import { proTooltipCopy } from "../services/chatbot_locked_tier"
import { prefs as prefsStore } from "../services/preferences_store"
import { migrateChatbotModelPreference } from "../services/chatbot_model_preference_migration"
import { researchDepthMethods } from "./chatbot/settings_mixin"
import {
  announceQuestionCount,
  questionCharsLeft,
  questionMaxFrom,
  questionTooLongMessage,
  renderQuestionCount
} from "../services/chatbot_question_length"

/**
 * Hero Chatbot Controller
 * Lightweight controller for the homepage inline chatbot input.
 * Handles settings panel, intelligence pills, and submits via POST form
 * to /chatbot (question never appears in URL or client storage).
 */
class HeroChatbotController extends Controller {
  static targets = [
    "input",
    "questionCount",
    "questionCountStatus",
    "settingsPanel",
    "modelSelect",
    "profileSelect",
    "srcLegislation",
    "srcJurisprudence",
    "srcParliamentary"
  ]

  static values = {
    intelligence: { type: String, default: "genius" },
    language: { type: String, default: "nl" },
    researchDepth: { type: String, default: "balanced" },
    pro: { type: Boolean, default: false }
  }

  connect() {
    this._isHeroResearchDepth = true
    this._submissionPending = false
    this._heroConnected = true
    this._heroModelChoiceTouched = false
    this._preferenceLoadToken = {}
    this._syncPills()
    this._filterModelDropdown(this.intelligenceValue)
    this._restorePendingModelPreference()
    this._refreshResearchDepthState()
    this._preferencesReady = this._initPendingModelPreference(this._preferenceLoadToken)

    if (this.hasInputTarget && this.inputTarget.tagName === 'TEXTAREA') {
      // One handler for the box's input and the window's resize, so the two
      // listeners always pair on disconnect; it also keeps the count under
      // the box (cheap on a resize, where nothing changes).
      this._inputResizeHandler = () => {
        this._autoResize()
        this._updateQuestionLength()
      }
      this._resizeInput = this.inputTarget
      this._resizeInput.addEventListener('input', this._inputResizeHandler)
      window.addEventListener('resize', this._inputResizeHandler)
      this._autoResize()
      this._updateQuestionLength()
    }

    // Load sample question pills (survives Turbo navigation)
    this._loadSamplePills()

    // Listen for credit updates from the chatbot widget
    this._creditHandler = (e) => this._onCreditsUpdated(e.detail)
    document.addEventListener('chatbot:credits-updated', this._creditHandler)
  }

  disconnect() {
    this._heroConnected = false
    this._cancelPreferenceWait?.()
    this._preferenceLoadToken = null
    this._preferencesReady = null
    if (this._inputResizeHandler) {
      this._resizeInput.removeEventListener('input', this._inputResizeHandler)
      window.removeEventListener('resize', this._inputResizeHandler)
      this._inputResizeHandler = null
      this._resizeInput = null
    }
    if (this._pillsInterval) {
      clearInterval(this._pillsInterval)
      this._pillsInterval = null
    }
    if (this._creditHandler) {
      document.removeEventListener('chatbot:credits-updated', this._creditHandler)
      this._creditHandler = null
    }
  }

  // ═══════════════════════════════════════════════
  // SUBMIT - the explicit Send/Enter action opens the full chatbot.
  // POST keeps the question out of query URLs and browser storage.
  // ═══════════════════════════════════════════════

  async submit(event) {
    event?.preventDefault()
    if (!this.hasInputTarget || this._submissionPending || this._preferenceSubmissionWaiting) return
    // Before any wait: a question too long for the server is not handed over.
    if (this._blockOverlongQuestion()) return
    // A saved Claude choice may arrive after the default option renders. Wait
    // before an untouched-default Send, so it cannot silently use a cheap model.
    if (this._preferencesReady && !this._heroModelChoiceTouched) {
      const token = this._preferenceLoadToken
      let ready
      this._preferenceSubmissionWaiting = true
      try {
        ready = await this._waitForPreferenceHydration()
      } finally {
        this._preferenceSubmissionWaiting = false
      }
      if (this._heroConnected === false || token !== this._preferenceLoadToken) return
      if (!ready && !this._heroModelChoiceTouched) {
        const notice = this.element.querySelector('#hero-model-availability-notice')
        if (notice) {
          notice.textContent = notice.dataset.preferencesLoadingMessage
          notice.hidden = false
        }
        return
      }
    }
    const question = this.inputTarget.value.trim()
    if (!question) return
    if (this.updateModelAvailability()) return

    // A rapid second click must not create another handoff/request while the
    // browser is leaving. Reconnect resets this guard after back navigation.
    this._submissionPending = true
    try {
      this._submitViaForm(question)
    } catch (error) {
      this._submissionPending = false
      throw error
    }
  }

  // Get the widget chatbot controller via Stimulus
  _getWidgetController() {
    const ctrlEl = document.querySelector('[data-controller~="chatbot"]')
    if (!ctrlEl) return null

    // Use the application's own controller reference. The window.Stimulus
    // debug handle is deliberately absent from production bundles.
    const app = this.application
    if (!app) return null

    return app.getControllerForElementAndIdentifier(ctrlEl, 'chatbot') || null
  }

  // POST form to /chatbot; its response transports settings in a transient
  // hash fragment, consumed once by the full-page controller before sending.
  _submitViaForm(question) {
    const form = document.createElement('form')
    form.method = 'POST'
    form.action = '/chatbot'
    form.style.display = 'none'

    // CSRF token
    const csrfMeta = document.querySelector('meta[name="csrf-token"]')
    if (csrfMeta) {
      const csrfInput = document.createElement('input')
      csrfInput.type = 'hidden'
      csrfInput.name = 'authenticity_token'
      csrfInput.value = csrfMeta.content
      form.appendChild(csrfInput)
    }

    // Question
    const qInput = document.createElement('input')
    qInput.type = 'hidden'
    qInput.name = 'q'
    qInput.value = question
    form.appendChild(qInput)

    // Intelligence
    const intInput = document.createElement('input')
    intInput.type = 'hidden'
    intInput.name = 'intelligence'
    intInput.value = this.intelligenceValue
    form.appendChild(intInput)

    const depthInput = document.createElement('input')
    depthInput.type = 'hidden'
    depthInput.name = 'research_depth'
    depthInput.value = this._normalizedResearchDepth()
    form.appendChild(depthInput)

    if (this._hasLinkedResearchCombinations?.()) {
      for (const [name, value] of [['linked_research', 'true'], ['reasoning_effort', this.reasoningLevelValue]]) {
        const setting = document.createElement('input')
        setting.type = 'hidden'
        setting.name = name
        setting.value = value
        form.appendChild(setting)
      }
    }

    // Model
    if (this.hasModelSelectTarget && this.modelSelectTarget.value) {
      const mInput = document.createElement('input')
      mInput.type = 'hidden'
      mInput.name = 'model'
      mInput.value = this.modelSelectTarget.value
      form.appendChild(mInput)
    }

    // Only the reader's selected profile travels with the explicit Send.
    const profileValue = (this.hasProfileSelectTarget && this.profileSelectTarget.value)
      || null
    if (profileValue) {
      const pInput = document.createElement('input')
      pInput.type = 'hidden'
      pInput.name = 'profile'
      pInput.value = profileValue
      form.appendChild(pInput)
    }

    // Sources
    const sources = this._getSelectedSources()
    const sInput = document.createElement('input')
    sInput.type = 'hidden'
    sInput.name = 'sources'
    sInput.value = sources.join(',')
    form.appendChild(sInput)

    document.body.appendChild(form)
    form.submit()
  }

  // Handle Enter key in textarea
  handleKeydown(event) {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault()
      this.submit()
    }
  }

  // ═══════════════════════════════════════════════
  // SETTINGS PANEL - gear icon toggle
  // ═══════════════════════════════════════════════

  toggleSettings() {
    if (!this.hasSettingsPanelTarget) return
    const panel = this.settingsPanelTarget
    const toggle = this.element.querySelector('#hero-settings-toggle')

    const isHidden = panel.classList.contains('hidden')
    panel.classList.toggle('hidden', !isHidden)

    if (toggle) {
      toggle.setAttribute('aria-expanded', isHidden ? 'true' : 'false')

      if (isHidden) {
        toggle.classList.remove('text-gray-400', 'dark:text-gray-500')
        toggle.classList.add('text-gray-700', 'dark:text-gray-200')
      } else {
        toggle.classList.remove('text-gray-700', 'dark:text-gray-200')
        toggle.classList.add('text-gray-400', 'dark:text-gray-500')
      }
    }
  }

  // ═══════════════════════════════════════════════
  // INTELLIGENCE PILLS
  // ═══════════════════════════════════════════════

  selectIntelligence(event) {
    this._heroModelChoiceTouched = true
    const pill = event.currentTarget
    const level = pill.dataset.heroLevel
    const locked = pill.dataset.heroLocked === 'true'

    // Show pro tooltip for locked tiers, but still let the UI update so they can preview
    if (locked) {
      this._showProTooltip(pill)
    }

    this.intelligenceValue = level
    this._syncPills()
    this._filterModelDropdown(level)

  }

  // Sync pill visual states
  _syncPills() {
    const level = this.intelligenceValue
    const pills = this.element.querySelectorAll('.hero-intel-pill')

    pills.forEach(p => {
      if (p.dataset.heroLevel === level) {
        p.classList.add('bg-white', 'dark:bg-gray-700', 'shadow-sm', 'ring-1', 'ring-gray-200', 'dark:ring-gray-600', 'text-gray-900', 'dark:text-white')
        p.classList.remove('text-gray-500', 'dark:text-gray-400')
      } else {
        p.classList.remove('bg-white', 'dark:bg-gray-700', 'shadow-sm', 'ring-1', 'ring-gray-200', 'dark:ring-gray-600', 'text-gray-900', 'dark:text-white')
        p.classList.add('text-gray-500', 'dark:text-gray-400')
      }
    })
    const active = Array.from(pills).find(pill => pill.dataset.heroLevel === level)
    const indicator = this.element.querySelector('#hero-level-indicator')
    if (indicator && active) {
      const label = active.dataset.heroLabel || level
      const desc = active.dataset.heroDesc || ''
      const prefixes = { nl: 'AI-Intelligentie', fr: 'Intelligence IA', de: 'KI-Intelligenz', en: 'AI Intelligence' }
      const prefix = prefixes[this.languageValue || 'nl'] || prefixes.nl
      indicator.innerHTML = `${prefix}: <span data-hero-active-label>${label}</span> <span data-hero-active-desc class="text-gray-600 dark:text-gray-300">| ${desc}</span>`
    }
  }

  // ═══════════════════════════════════════════════
  // MODEL DROPDOWN - filter by intelligence tier
  // NOTE: <option> elements cannot be hidden via CSS display:none or the hidden
  // attribute in Chrome/Safari/Edge. We must physically remove and re-insert them.
  // ═══════════════════════════════════════════════

  _filterModelDropdown(level, preferredModel = null) {
    if (!this.hasModelSelectTarget) return
    const select = this.modelSelectTarget

    // Cache all options on first call
    if (!this._allHeroModelOptions) {
      this._allHeroModelOptions = Array.from(select.querySelectorAll('option'))
    }

    // Clear and re-insert only matching options
    select.innerHTML = ''
    let firstVisible = null
    let defaultForTier = null
    let preferredForTier = null

    for (const opt of this._allHeroModelOptions) {
      {
        select.appendChild(opt)
        if (!firstVisible && !opt.disabled) firstVisible = opt
        if (opt.dataset.intelligence === level && opt.dataset.default === 'true' && !opt.disabled) defaultForTier = opt
        if (opt.value === preferredModel && (!opt.disabled || opt.dataset.modelAvailable === 'false')
          && (!preferredForTier || opt.dataset.reasoningOption === this.reasoningLevelValue)) preferredForTier = opt
      }
    }

    const toSelect = preferredForTier || defaultForTier || this._freshDefaultOption?.(this._allHeroModelOptions) || firstVisible
    if (toSelect) { toSelect.selected = true; this.intelligenceValue = toSelect.dataset.intelligence || level }
    this.updateModelAvailability()
  }

  updateModelAvailability(event) {
    if (event) this._heroModelChoiceTouched = true
    this._refreshResearchDepthState()
    const select = this.hasModelSelectTarget ? this.modelSelectTarget : null
    const option = select?.options?.[select.selectedIndex]
    const pending = option?.dataset.modelAvailable === 'false'
    const notice = this.element?.querySelector?.('#hero-model-availability-notice')
    if (notice) {
      notice.hidden = !pending
      notice.textContent = pending ? option.dataset.comingSoonMessage : ''
    }
    return pending
  }

  _restorePendingModelPreference() {
    if (this._heroModelChoiceTouched || !this.hasModelSelectTarget) return
    const migration = migrateChatbotModelPreference(prefsStore.get('chatbot', null))
    const preference = migration.preferences
    if (!this._heroModelChoiceTouched && preference?.reasoningLevel) this.reasoningLevelValue = preference.reasoningLevel
    const option = this._allHeroModelOptions?.find(candidate =>
      candidate.value === preference?.model && (!candidate.disabled || candidate.dataset.modelAvailable === 'false'))
    if (!this._researchDepthTouched) this.researchDepthValue = preference?.researchDepth
      ? this._normalizedResearchDepth(preference.researchDepth)
      : (preference?.reasoningLevel ? this._depthFromLegacyReasoning(preference.reasoningLevel) : 'balanced')
    if (!option) { this._refreshResearchDepthState(); return }
    this.intelligenceValue = option.dataset.intelligence
    this._syncPills()
    this._filterModelDropdown(this.intelligenceValue, option.value)
    if (migration.migrated) prefsStore.set('chatbot', preference)
  }

  async _initPendingModelPreference(token) {
    try {
      await prefsStore.init()
      if (prefsStore.hydrated !== true || !this._heroConnected || token !== this._preferenceLoadToken) return false
      this._heroPreferencesHydrated = true
      this._restorePendingModelPreference()
      this._refreshResearchDepthState()
      if (this._researchDepthTouched) this._saveHeroPreferences()
      return true
    } catch (_) {
      // An untouched default is unsafe when the reader's saved choice is unknown.
      // Deliberate manual choices still bypass the hydration wait in submit().
      return false
    }
  }

  _waitForPreferenceHydration() {
    let timer
    let cancel
    const stopped = new Promise(resolve => {
      cancel = () => resolve(false)
      this._cancelPreferenceWait = cancel
      timer = setTimeout(cancel, 5000)
    })
    return Promise.race([this._preferencesReady.then(ready => ready === true, () => false), stopped]).finally(() => {
      clearTimeout(timer)
      if (this._cancelPreferenceWait === cancel) this._cancelPreferenceWait = null
    })
  }


  updateModel(event) {
    this._heroModelChoiceTouched = true
    const option = event.currentTarget.options[event.currentTarget.selectedIndex]
    this._adoptResearchCombination(option)
    if (option) this.intelligenceValue = option.dataset.intelligence || this.intelligenceValue
    this.updateModelAvailability()
    this._saveHeroPreferences()
  }

  _heroTotalCredits() {
    const option = this.hasModelSelectTarget ? this.modelSelectTarget.options?.[this.modelSelectTarget.selectedIndex] : null
    const surcharges = Object.fromEntries((option?.dataset.reasoningSurcharges || '').split(',').filter(Boolean).map(pair => {
      const [level, value] = pair.split(':'); return [level, Number(value) || 0]
    }))
    return (Number(option?.dataset.credits) || 1) + (surcharges[this.reasoningLevelValue] || 0)
  }

  _refreshHeroCreditDisplay() {
    const total = this._heroTotalCredits()
    const badge = this.element?.querySelector('#hero-send-credit-badge')
    if (badge) badge.textContent = '−' + total + 'cr'
    const send = this.element?.querySelector('#hero-chat-send')
    if (send) send.setAttribute?.('title', total + ' credits')
  }

  _saveHeroPreferences() {
    if (!this._heroPreferencesHydrated && !this._heroModelChoiceTouched) return
    const current = prefsStore.get('chatbot', {}) || {}
    prefsStore.set('chatbot', { ...current, intelligence: this.intelligenceValue,
      model: this.modelSelectTarget?.value, reasoningLevel: this.reasoningLevelValue,
      researchDepth: this._normalizedResearchDepth() })
  }

  // ═══════════════════════════════════════════════
  // SOURCES
  // ═══════════════════════════════════════════════

  _getSelectedSources() {
    const sources = []
    if (this.hasSrcLegislationTarget && this.srcLegislationTarget.checked) sources.push('legislation')
    if (this.hasSrcJurisprudenceTarget && this.srcJurisprudenceTarget.checked) sources.push('jurisprudence')
    if (this.hasSrcParliamentaryTarget && this.srcParliamentaryTarget.checked) sources.push('parliamentary')
    return sources.length > 0 ? sources : ['legislation']
  }

  // ═══════════════════════════════════════════════
  // SAMPLE QUESTION CLICKS
  // ═══════════════════════════════════════════════

  clickSample(event) {
    event.preventDefault()
    const question = event.currentTarget.dataset.heroQuestion
    if (!question || !this.hasInputTarget) return

    // A suggestion is an editable draft, not permission to spend credits or
    // change the reader's chosen model, tier, profile or sources.
    this.inputTarget.value = question
    this._autoResize()
    this._updateQuestionLength()
    this.inputTarget.focus()
  }

  // ═══════════════════════════════════════════════
  // OPEN CHAT - the hero icon is a direct launcher, including on mobile
  // ═══════════════════════════════════════════════

  openChatbot(event) {
    event.preventDefault()
    event.stopPropagation()
    const widget = this._getWidgetController()
    if (widget) {
      if (!widget.openValue) widget.toggle()
      else if (widget.hasInputTarget) widget.inputTarget.focus()
    } else {
      // The adjacent full-page link remains usable if widget enhancement
      // is unavailable; never target an absent/hidden floating button.
      this.element.querySelector('#hero-chatbot-icon-btn + a')?.click()
    }
  }

  // ═══════════════════════════════════════════════
  // CREDIT SYNC - update hero display when widget deducts credits
  // ═══════════════════════════════════════════════

  _onCreditsUpdated(creditsInfo) {
    if (!creditsInfo) return

    // Update the credit counter. The widget's _updateCreditPools already wrote
    // credits_remaining to #credits-value; subtracting credits_deducted on top
    // of that displayed a double deduction. Prefer the server's absolute value.
    if (creditsInfo.credits_deducted > 0) {
      const el = document.getElementById('credits-value')
      if (el) {
        if (creditsInfo.credits_remaining !== undefined) {
          el.textContent = creditsInfo.credits_remaining
        } else {
          el.textContent = Math.max(0, parseInt(el.textContent || '0') - creditsInfo.credits_deducted)
        }
        el.style.transition = 'color 0.2s, transform 0.2s'
        el.style.color = '#ef4444'
        el.style.transform = 'scale(1.3)'
        setTimeout(() => { el.style.color = ''; el.style.transform = '' }, 700)
      }
    }

    // Floating deduction badge anchored near the hero credit breakdown
    const breakdownEl = document.getElementById('hero-credit-breakdown')
    if (breakdownEl && creditsInfo.credits_deducted > 0) {
      const badge = document.createElement('span')
      badge.textContent = `−${creditsInfo.credits_deducted}cr`
      badge.style.cssText = `
        position: fixed;
        font-size: 12px;
        font-weight: 700;
        color: #ef4444;
        pointer-events: none;
        z-index: 9999;
        white-space: nowrap;
        text-shadow: 0 1px 3px rgba(0,0,0,0.15);
        animation: creditDeduct 1.6s ease-out forwards;
      `
      const rect = breakdownEl.getBoundingClientRect()
      badge.style.left = `${rect.left + rect.width / 2}px`
      badge.style.top = `${rect.top - 4}px`
      badge.style.transform = 'translateX(-50%)'
      document.body.appendChild(badge)
      setTimeout(() => badge.remove(), 1800)
    }
  }

  // ═══════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════

  _autoResize() {
    if (!this.hasInputTarget || this.inputTarget.tagName !== 'TEXTAREA') return
    // Remove the old scrollbar before measuring the new value. Otherwise a
    // cleared question measures its placeholder in the scrollbar's narrower
    // width and can unnecessarily keep that same scrollbar alive.
    this.inputTarget.style.overflowY = 'hidden'
    this.inputTarget.style.height = 'auto'
    this.inputTarget.style.height = Math.min(this.inputTarget.scrollHeight, 80) + 'px'
    // Only a genuinely long question needs a scrollbar. An empty one-line
    // box previously showed the native arrows because its line-height did
    // not fit its rows=1 height; mobile now has a full-width reading area.
    this.inputTarget.style.overflowY = this.inputTarget.scrollHeight > this.inputTarget.clientHeight ? 'auto' : 'hidden'
  }

  // The characters the question may still take before the server refuses it
  // (LegalChatbotService::MAX_QUESTION_LENGTH, carried by the counter as
  // data-max), written under the box and said once typing pauses.
  _updateQuestionLength({ announceNow = false } = {}) {
    if (!this.hasInputTarget || !this.hasQuestionCountTarget) return null
    const count = renderQuestionCount(this.inputTarget, this.questionCountTarget, this.languageValue)
    if (this.hasQuestionCountStatusTarget) {
      announceQuestionCount(this.questionCountStatusTarget, count.text, announceNow ? 0 : undefined)
    }
    return count
  }

  // A question too long for the server stays in the box: the count turns red
  // and says by how much, and a screen reader hears what to do. The handoff
  // would otherwise cut it on the server.
  _blockOverlongQuestion() {
    const max = questionMaxFrom(this.hasQuestionCountTarget ? this.questionCountTarget : null)
    if (questionCharsLeft(this.inputTarget.value, max) >= 0) return false
    this._updateQuestionLength()
    if (this.hasQuestionCountStatusTarget) {
      announceQuestionCount(this.questionCountStatusTarget,
        questionTooLongMessage(this.inputTarget.value, this.languageValue, max), 0)
    }
    this.inputTarget.focus()
    return true
  }

  _showProTooltip(el) {
    // Remove existing
    const existing = this.element.querySelector('.hero-pro-toast')
    if (existing) existing.remove()

    // Same voice as the chatbot's own upsell: what the level adds, not what
    // this account is missing. The pill carries its label and description, so
    // the toast can name the level rather than the restriction.
    const msg = proTooltipCopy(this.languageValue, {
      name: el?.dataset?.heroLabel || '',
      desc: el?.dataset?.heroDesc || ''
    })

    const toast = document.createElement('div')
    toast.className = 'hero-pro-toast flex items-center justify-center gap-2 mt-1.5 px-3 py-1.5 rounded-lg text-xs font-medium ' +
      'bg-gradient-to-r from-amber-50 to-orange-50 dark:from-amber-900/30 dark:to-orange-900/20 ' +
      'text-amber-800 dark:text-amber-300 border border-amber-200 dark:border-amber-700/40 transition-opacity'
    toast.innerHTML = `
      <span>${msg.text}</span>
      <a href="/pricing" class="ml-1 bg-amber-500 hover:bg-amber-600 text-white px-2 py-0.5 rounded font-semibold text-[10px] transition-colors no-underline">Pro →</a>
    `

    // Insert after the pills row
    const pillsRow = el.closest('.flex') || el.parentElement
    if (pillsRow && pillsRow.parentElement) {
      pillsRow.parentElement.insertBefore(toast, pillsRow.nextSibling)
    }

    setTimeout(() => {
      toast.style.opacity = '0'
      setTimeout(() => toast.remove(), 300)
    }, 4000)
  }

  // ═══════════════════════════════════════════════
  // SAMPLE PILLS - loaded from chatbot_questions.json
  // ═══════════════════════════════════════════════

  _loadSamplePills() {
    const container = document.getElementById('hero-sample-pills')
    if (!container) return

    const langKey = this.languageValue || 'nl'
    this._pillsContainer = container
    this._allQuestions = []
    this._currentPillSet = []

    container.style.transition = 'opacity 0.25s ease'
    container.style.opacity = '1'

    fetch('/chatbot_questions.json')
      .then(r => r.json())
      .then(data => {
        // Prefer questions with a native translation; fall back to nl if too few exist
        let candidates = langKey !== 'nl'
          ? data.filter(item => item[langKey]).map(item => ({ text: item[langKey], category: item.category || '' }))
          : []
        if (candidates.length < 10) {
          candidates = data.map(item => ({ text: item.nl, category: item.category || '' }))
        }
        this._allQuestions = candidates
          .filter(q => q.text && q.text.length > 10 && q.text.length < 80)

        if (this._allQuestions.length === 0) return
        this._rotatePills()
        this._pillsInterval = setInterval(() => this._rotatePills(), 30000)
      })
      .catch(() => { /* silently fail - pills are a nice-to-have */ })
  }

  _rotatePills() {
    if (!this._allQuestions || this._allQuestions.length === 0) return
    const current = this._currentPillSet || []
    let pool = this._allQuestions.filter(q => !current.some(c => c.text === q.text))
    if (pool.length < 3) pool = this._allQuestions
    this._currentPillSet = pool.sort(() => 0.5 - Math.random()).slice(0, 3)
    this._renderPills(this._currentPillSet)
  }

  _renderPills(questions) {
    const container = this._pillsContainer
    if (!container) return
    container.style.opacity = '0'
    setTimeout(() => {
      container.innerHTML = ''
      questions.forEach(q => {
        const btn = document.createElement('button')
        btn.type = 'button'
        btn.className = 'px-3 py-1.5 text-xs font-medium rounded-full bg-white/80 dark:bg-gray-800/60 border border-gray-200 dark:border-gray-600/50 text-gray-600 dark:text-gray-300 hover:bg-(--accent-100) hover:border-(--accent-400) hover:text-(--accent-700) hover:shadow-md dark:hover:bg-(--accent-500)/20 dark:hover:border-(--accent-400) dark:hover:text-(--accent-400) transition-all hover:scale-[1.03] cursor-pointer'
        btn.setAttribute('data-action', 'click->hero-chatbot#clickSample')
        btn.setAttribute('data-hero-question', q.text)
        btn.setAttribute('data-hero-category', q.category)
        btn.textContent = '\u201c' + q.text + '\u201d'
        container.appendChild(btn)
      })
      container.style.opacity = '1'
    }, 250)
  }
}

Object.defineProperties(HeroChatbotController.prototype, Object.getOwnPropertyDescriptors(researchDepthMethods))
export default HeroChatbotController
