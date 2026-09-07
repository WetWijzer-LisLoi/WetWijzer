import { Controller } from "@hotwired/stimulus"
import { proTooltipCopy } from "../services/chatbot_locked_tier"

/**
 * Hero Chatbot Controller
 * Lightweight controller for the homepage inline chatbot input.
 * Handles settings panel, intelligence pills, and submits via POST form
 * to /chatbot (question never appears in URL or client storage).
 */
export default class extends Controller {
  static targets = [
    "input",
    "settingsPanel",
    "modelSelect",
    "profileSelect",
    "srcLegislation",
    "srcJurisprudence",
    "srcParliamentary"
  ]

  static values = {
    intelligence: { type: String, default: "smart" },
    language: { type: String, default: "nl" }
  }

  connect() {
    this._syncPills()
    this._filterModelDropdown(this.intelligenceValue)

    if (this.hasInputTarget && this.inputTarget.tagName === 'TEXTAREA') {
      this.inputTarget.addEventListener('input', () => this._autoResize())
    }

    // Load sample question pills (survives Turbo navigation)
    this._loadSamplePills()

    // Listen for credit updates from the chatbot widget
    this._creditHandler = (e) => this._onCreditsUpdated(e.detail)
    document.addEventListener('chatbot:credits-updated', this._creditHandler)
  }

  disconnect() {
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
  // SUBMIT - open widget + inject question (inline with credit animations)
  // Falls back to POST redirect if widget is unavailable
  // ═══════════════════════════════════════════════

  submit() {
    if (!this.hasInputTarget) return
    const question = this.inputTarget.value.trim()
    if (!question) return

    // Get widget controller via Stimulus
    const widgetCtrl = this._getWidgetController()

    if (widgetCtrl) {
      // ── Widget available → send inline ──
      // 1. Apply hero settings to widget (intelligence, profile, sources)
      this._applySettingsToWidget(widgetCtrl)

      // 2. Open widget if closed
      if (!widgetCtrl.openValue) {
        widgetCtrl.toggle()
      }

      // 3. Inject question into widget input and fire send()
      if (widgetCtrl.hasInputTarget) {
        widgetCtrl.inputTarget.value = question
        if (typeof widgetCtrl._autoResize === 'function') {
          widgetCtrl._autoResize()
        }
      }

      // 4. Clear hero input + reset mapped profile (avoid stale profile on next manual question)
      this.inputTarget.value = ''
      this._mappedProfile = null
      this._autoResize()

      // 5. Send with slight delay (let widget open animation complete)
      setTimeout(() => {
        widgetCtrl.send()
      }, 150)

      return
    }

    // ── Fallback: POST form redirect to /chatbot ──
    this._submitViaForm(question)
  }

  // Apply hero chatbot settings to the widget controller before sending
  _applySettingsToWidget(widgetCtrl) {
    // Intelligence level — set override flag to prevent async loadPreferences() race
    widgetCtrl._heroOverrideActive = true
    widgetCtrl.intelligenceValue = this.intelligenceValue

    // Profile - sample question category mapping takes priority over dropdown default
    // (_mappedProfile is set when user clicks a categorized sample pill)
    const profileValue = this._mappedProfile
      || (this.hasProfileSelectTarget && this.profileSelectTarget.value)
      || null
    if (profileValue) {
      widgetCtrl.profileValue = profileValue
    }

    // Sources
    const sources = this._getSelectedSources()
    widgetCtrl.sourceValue = sources.join(',')

    // Model override
    if (this.hasModelSelectTarget && this.modelSelectTarget.value) {
      widgetCtrl.modelOverrideValue = this.modelSelectTarget.value
    }
  }

  // Get the widget chatbot controller via Stimulus
  _getWidgetController() {
    const ctrlEl = document.querySelector('[data-controller~="chatbot"]')
    if (!ctrlEl) return null

    const app = window.Stimulus || (window.Application && window.Application.application)
    if (!app) return null

    return app.getControllerForElementAndIdentifier(ctrlEl, 'chatbot') || null
  }

  // Fallback: POST form to /chatbot page
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

    // Model
    if (this.hasModelSelectTarget && this.modelSelectTarget.value) {
      const mInput = document.createElement('input')
      mInput.type = 'hidden'
      mInput.name = 'model'
      mInput.value = this.modelSelectTarget.value
      form.appendChild(mInput)
    }

    // Profile - sample question mapping takes priority
    const profileValue = this._mappedProfile
      || (this.hasProfileSelectTarget && this.profileSelectTarget.value)
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
    if (event.key === "Enter" && !event.shiftKey) {
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

    // Update the level indicator with subtitle
    const indicator = this.element.querySelector('#hero-level-indicator')
    if (indicator) {
      const label = pill.dataset.heroLabel || level
      const desc = pill.dataset.heroDesc || ''
      const lang = this.languageValue || 'nl'
      const prefixes = { nl: 'AI-Intelligentie', fr: 'Intelligence IA', de: 'KI-Intelligenz', en: 'AI Intelligence' }
      const prefix = prefixes[lang] || prefixes.nl
      indicator.innerHTML = `${prefix}: <span data-hero-active-label>${label}</span> <span data-hero-active-desc class="text-gray-300 dark:text-gray-600">| ${desc}</span>`
    }
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
  }

  // ═══════════════════════════════════════════════
  // MODEL DROPDOWN - filter by intelligence tier
  // NOTE: <option> elements cannot be hidden via CSS display:none or the hidden
  // attribute in Chrome/Safari/Edge. We must physically remove and re-insert them.
  // ═══════════════════════════════════════════════

  _filterModelDropdown(level) {
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

    for (const opt of this._allHeroModelOptions) {
      if (opt.dataset.intelligence === level) {
        select.appendChild(opt)
        if (!firstVisible) firstVisible = opt
        if (opt.dataset.default === 'true' && !opt.disabled) defaultForTier = opt
      }
    }

    const toSelect = defaultForTier || firstVisible
    if (toSelect) toSelect.selected = true
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

  // JSON-category (from chatbot_questions.json) → profile dropdown ID
  // Categories like "ARBEIDSRECHT - INDIVIDUEEL" map to profile "labor"
  static CATEGORY_TO_PROFILE = {
    // Labor law (all sub-categories)
    'ARBEIDSRECHT': 'labor',
    'ARBEIDSRECHT - INDIVIDUEEL': 'labor',
    'ARBEIDSRECHT - COLLECTIEF': 'labor',
    'ARBEIDSRECHT - ONTSLAG': 'labor',
    'ARBEIDSRECHT - LOON': 'labor',
    'ARBEIDSRECHT - VAKANTIE': 'labor',
    'ARBEIDSRECHT - ZIEKTE': 'labor',
    // Social security
    'SOCIALE ZEKERHEID': 'social',
    // Housing / real estate
    'HUURRECHT': 'real_estate',
    'VASTGOEDRECHT': 'real_estate',
    'BOUWEN': 'real_estate',
    'BURENRECHT': 'real_estate',
    'ZAKENRECHT': 'real_estate',
    // Family / inheritance
    'FAMILIERECHT': 'family',
    'ERFRECHT': 'family',
    // Criminal
    'STRAFRECHT': 'criminal',
    'DRUGS': 'criminal',
    'VERKEERSRECHT': 'criminal',
    // Tax (all sub-categories)
    'FISCAAL': 'tax',
    'FISCAAL - BTW': 'tax',
    'FISCAAL - PERSONENBELASTING': 'tax',
    'FISCAAL - REGISTRATIE': 'tax',
    // Corporate / commercial
    'VENNOOTSCHAPSRECHT': 'corporate',
    'SCHULDEN': 'corporate',
    // Consumer
    'CONSUMENTENRECHT': 'consumer',
    'INTERNET': 'consumer',
    // Migration
    'VREEMDELINGENRECHT': 'migration',
    // Administrative / government
    'BESTUURSRECHT': 'administrative',
    'OVERHEID': 'administrative',
    'MILIEU': 'administrative',
    'GRONDWET': 'administrative',
    // Privacy
    'PRIVACY': 'privacy',
    // General catch-alls
    'ALGEMEEN': 'general',
    'DIVERSE': 'general',
    'INTELLECTUEEL': 'general',
    'MEDISCH': 'general',
    'PROCEDURERECHT': 'general',
    'VERZEKERINGEN': 'general',
    'SPORT': 'general',
    'DIEREN': 'general'
  }

  clickSample(event) {
    event.preventDefault()
    const question = event.currentTarget.dataset.heroQuestion
    if (!question || !this.hasInputTarget) return

    // Read category from the button and map to profile
    const rawCategory = (event.currentTarget.dataset.heroCategory || '').toUpperCase().trim()
    if (rawCategory) {
      // Try exact match first, then prefix match (e.g. "ARBEIDSRECHT - INDIVIDUEEL" → "ARBEIDSRECHT")
      let profileId = this.constructor.CATEGORY_TO_PROFILE[rawCategory]
      if (!profileId) {
        const prefix = rawCategory.split(' - ')[0].trim()
        profileId = this.constructor.CATEGORY_TO_PROFILE[prefix]
      }
      // Store on instance so submit() can include it in the POST form
      this._mappedProfile = profileId || null
    }

    this.inputTarget.value = question
    this._autoResize()
    this.submit()
  }

  // ═══════════════════════════════════════════════
  // HIGHLIGHT FAB - draws attention to bottom-right chatbot widget
  // ═══════════════════════════════════════════════

  highlightFab(event) {
    event.preventDefault()
    event.stopPropagation()

    // Track clicks - on the 3rd click, open the widget instead of pulsing
    this._fabClickCount = (this._fabClickCount || 0) + 1

    if (this._fabClickCount >= 3) {
      this._fabClickCount = 0
      // Open the chat widget panel via Stimulus controller
      const ctrlEl = document.querySelector('[data-controller~="chatbot"]')
      if (ctrlEl) {
        const app = window.Stimulus || (window.Application && window.Application.application)
        if (app) {
          const ctrl = app.getControllerForElementAndIdentifier(ctrlEl, 'chatbot')
          if (ctrl && typeof ctrl.toggle === 'function') {
            ctrl.toggle()
            return
          }
        }
      }
      // Fallback: just click the FAB
      const fab = document.getElementById('chatbot-fab')
      if (fab) fab.click()
      return
    }

    const fab = document.getElementById('chatbot-fab')
    if (!fab) return
    if (this._fabHighlightActive) return
    this._fabHighlightActive = true

    const rect = fab.getBoundingClientRect()
    const cx = rect.left + rect.width / 2
    const cy = rect.top + rect.height / 2

    // Pulsing beacon centered on FAB
    const beacon = document.createElement('div')
    beacon.className = 'fab-beacon'
    beacon.style.top = cy + 'px'
    beacon.style.left = cx + 'px'
    document.body.appendChild(beacon)

    // Auto-dismiss after 3s
    setTimeout(() => {
      beacon.style.transition = 'opacity 0.3s ease'
      beacon.style.opacity = '0'
      setTimeout(() => beacon.remove(), 350)
      this._fabHighlightActive = false
    }, 3000)
  }

  // ═══════════════════════════════════════════════
  // CREDIT SYNC - update hero display when widget deducts credits
  // ═══════════════════════════════════════════════

  _onCreditsUpdated(creditsInfo) {
    if (!creditsInfo) return

    // Update the credit counter. The widget's _updateCreditPools already wrote
    // credits_remaining to #credits-value — subtracting credits_deducted on top
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
    this.inputTarget.style.height = 'auto'
    this.inputTarget.style.height = Math.min(this.inputTarget.scrollHeight, 80) + 'px'
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
