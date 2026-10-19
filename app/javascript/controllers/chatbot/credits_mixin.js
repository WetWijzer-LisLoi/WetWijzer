/**
 * Chatbot Controller - Credits Mixin
 *
 * Methods extracted from chatbot_controller.js for maintainability.
 * Mixed into the controller prototype - all methods use 'this' as normal.
 */

export const creditsMethods = {
  // ═══════════════════════════════════════════════
  // SINGLE SOURCE OF TRUTH: per-model credit cost
  // ═══════════════════════════════════════════════
  // Reads the BASE credits from the currently selected model <option> data
  // attribute. UI prices must use _getActiveModelTotalCredits() so a reasoning
  // surcharge is never omitted.

  _getActiveModelOption() {
    const widgetSelect = document.getElementById('widget-model-select')
    const mainSelect = document.getElementById('model-select')
    // A widget-only page may keep its options panel collapsed (`.hidden`) while
    // still being the sole source of truth. Prefer the main selector only when
    // it actually exists and the widget panel is hidden.
    const widgetIsVisible = widgetSelect && !widgetSelect.closest('.hidden')
    const select = widgetSelect && (!mainSelect || widgetIsVisible) ? widgetSelect : mainSelect

    return select?.options?.[select.selectedIndex] || null
  },

  _getActiveModelCredits() {
    const opt = this._getActiveModelOption()

    if (opt?.dataset.credits) {
      return parseInt(opt.dataset.credits)
    }

    // Fallback: tier-level credits from intelligence notch
    const levels = this._intelligenceLevels
    const currentLevel = levels?.find(l => l.id === this.intelligenceValue)
    return currentLevel?.credits || 1
  },

  // Read the model-aware surcharge contract rendered on each option. This is
  // intentionally independent of the full-page reasoning controls so the
  // floating widget displays exactly what the server will charge.
  _reasoningSurchargeForModelOption(option, reasoning = this.reasoningLevelValue) {
    if (!option || option.dataset.supportsReasoning !== 'true') return 0

    const supported = (option.dataset.reasoningLevels || '').split(',').filter(Boolean)
    if (!supported.includes(reasoning)) return 0

    const surcharges = Object.fromEntries(
      (option.dataset.reasoningSurcharges || '')
        .split(',')
        .filter(Boolean)
        .map(pair => {
          const [level, value] = pair.split(':')
          return [level, parseInt(value || '0')]
        })
    )
    return surcharges[reasoning] || 0
  },

  // Authoritative next-question charge used by every badge/preview. Keeping
  // base model credits and the model-specific reasoning surcharge together
  // prevents secondary UI (such as follow-up suggestions) from drifting.
  _getActiveModelTotalCredits(reasoning = this._effectiveReasoningForRequest(this.conversationHistory || [])) {
    const option = this._getActiveModelOption()
    return this._getActiveModelCredits() + this._reasoningSurchargeForModelOption(option, reasoning)
  },

  // Mistral high-reasoning continuations require the provider's private typed
  // thinking state. WetWijzer intentionally neither exposes nor stores that
  // state, so a follow-up must use the provider's none/low mode. Resolve this
  // before displaying/sending the charge; the server enforces the same rule.
  _effectiveReasoningForRequest(contextMessages = []) {
    const option = this._getActiveModelOption()
    const isMistralSmall = option?.value === 'mistral-small'
    const isFollowUp = Array.isArray(contextMessages) && contextMessages.length > 0

    return isMistralSmall && isFollowUp && this.reasoningLevelValue === 'high'
      ? 'low'
      : this.reasoningLevelValue
  },

  // Suggestions can remain visible while the user changes model or reasoning.
  // Update every rendered marker instead of leaving its creation-time price.
  _updateSuggestionCostBadges(totalCredits = this._getActiveModelTotalCredits()) {
    if (!this.hasMessagesTarget) return

    this.messagesTarget.querySelectorAll('[data-suggestion-credit-cost]').forEach(badge => {
      badge.textContent = `\u2212${totalCredits}cr`
    })
  },

  // Refresh all credit displays using the currently selected model's cost.
  // Call this whenever intelligence level OR model changes.

  _refreshCreditDisplay() {
    const totalCredits = this._getActiveModelTotalCredits()

    // Update all credit badge locations
    const badge = document.getElementById('intelligence-credit-badge')
    if (badge) badge.textContent = totalCredits

    const sendBadge = document.getElementById('send-credit-badge')
    if (sendBadge) sendBadge.textContent = `\u2212${totalCredits}cr`

    this._updateSuggestionCostBadges(totalCredits)
    this._updateDeductionPreview(totalCredits)
    this._updateResearchDepthPreview?.(this._getActiveModelOption(), Array.isArray(this.conversationHistory) && this.conversationHistory.length > 0)
  },
  _updateTotalCreditsDisplay() {
    const total = this._getActiveModelTotalCredits()
    this._updateSuggestionCostBadges(total)

    const totalEl = document.getElementById('total-credits-value')
    if (!totalEl) return

    totalEl.textContent = total
    // Also update the credit display on the intelligence button
    const activeIntBtn = document.querySelector(`.intelligence-btn[data-intelligence-level="${this.intelligenceValue}"]`)
    const creditDisplay = activeIntBtn?.querySelector('.credit-display')
    if (creditDisplay) creditDisplay.textContent = `${total}cr`
  },

  // Update profile preference

  _updateCreditPools(creditsInfo) {
    if (!creditsInfo) return false

    const version = Number(creditsInfo.balance_version)
    if (Number.isInteger(version) && version >= 0) {
      if (Number.isInteger(this._creditBalanceVersion) && version < this._creditBalanceVersion) {
        return false
      }
      this._creditBalanceVersion = version
    }

    const remaining = creditsInfo.credits_remaining

    // Update the main credit counter (full chatbot page - settings panel)
    const creditsValueEl = document.getElementById('credits-value')
    if (creditsValueEl && remaining !== undefined) {
      creditsValueEl.textContent = remaining
      // Neutral by default; orange is reserved for the genuine low-balance
      // warning, matching the server-rendered classes.
      creditsValueEl.className = creditsValueEl.className
        .replace(/text-(orange|amber)-\d+/g, '')
        .replace(/dark:text-(orange|amber)-\d+/g, '')
        .replace(/text-gray-900|dark:text-white/g, '')
      if (remaining < 5) {
        creditsValueEl.classList.add('text-orange-500', 'dark:text-orange-400')
      } else {
        creditsValueEl.classList.add('text-gray-900', 'dark:text-white')
      }
    }

    // Update the hidden total (for animation anchoring)
    const totalEl = document.getElementById('credits-remaining-value')
    if (totalEl && remaining !== undefined) {
      totalEl.textContent = remaining
    }

    // Update the widget footer credit counter ("250 credits" below send button)
    const creditsValEl = document.getElementById('widget-credits-value')
    if (creditsValEl && remaining !== undefined) {
      creditsValEl.textContent = remaining
    }

    // Update the widget options panel credit badge ("250cr" in header)
    //
    // Grouped the way the server renders it (_widget.html.erb: a Dutch reader
    // expects 1.051, not 1051). Without this the badge went from "1.051cr" to
    // "1050cr" after the first answer and stayed ungrouped until a reload.
    // ONLY this badge: #credits-value and #credits-remaining-value are read
    // back with parseInt below, and parseInt('1.050') is 1, which would show
    // a false "onvoldoende credits" on the next question.
    const widgetCreditsEl = document.getElementById('widget-credits-display')
    if (widgetCreditsEl && remaining !== undefined) {
      const separator = (this.languageValue || 'nl') === 'en' ? ',' : '.'
      const grouped = String(remaining).replace(/\B(?=(\d{3})+(?!\d))/g, separator)
      widgetCreditsEl.textContent = `${grouped}cr`
    }

    // Update the source preview label
    this._updateSourcePreview()

    // Refresh the deduction preview for the next question
    this._refreshCreditDisplay()
    return true
  },

  // Apply one server-settled credit event. Balance versions prevent an older
  // concurrent response from overwriting a newer counter; unique event ids
  // keep retry/duplicate delivery from animating the same charge twice.
  _applyCreditsInfo(creditsInfo, { visual = true } = {}) {
    if (!creditsInfo) return false

    const accepted = this._updateCreditPools(creditsInfo)
    if (accepted) {
      document.dispatchEvent(new CustomEvent('chatbot:credits-updated', { detail: creditsInfo }))
    }

    const eventId = creditsInfo.event_id
    this._seenCreditEventIds ||= new Set()
    const unseenEvent = !eventId || !this._seenCreditEventIds.has(eventId)
    if (eventId) this._seenCreditEventIds.add(eventId)
    if (visual && unseenEvent && creditsInfo.credits_deducted > 0) {
      this._animateCreditDeduction(creditsInfo)
      this._showDeductionReceipt(creditsInfo)
    }

    return accepted
  },

  // Update the source preview label to show which pool will be charged next

  _updateSourcePreview() {
    const label = document.getElementById('credit-source-label')
    if (!label) return

    const creditsVal = parseInt(document.getElementById('credits-value')?.textContent || '0')

    if (creditsVal > 0) {
      label.textContent = '← credits'
    } else {
      label.textContent = '⚠️ 0'
    }
  },

  // Show a small receipt-style confirmation below the response

  _updateDeductionPreview(cost) {
    const textEl = document.getElementById('deduction-preview-text')
    if (!textEl) return

    const creditsVal = parseInt(document.getElementById('credits-value')?.textContent || '0')
    const lang = this.languageValue || 'nl'
    const plural = cost > 1 ? 's' : ''
    const crWord = lang === 'fr' ? `crédit${plural}` : lang === 'de' ? `Credit${plural}` : `credit${plural}`
    const insufficientMsg = lang === 'fr' ? 'crédits insuffisants' : lang === 'en' ? 'insufficient credits' : lang === 'de' ? 'unzureichende Credits' : 'onvoldoende credits'
    const insufficientHtml = `<a href="/credits" class="font-semibold text-red-500 hover:text-red-600 dark:hover:text-red-400 hover:underline">⚠️ ${insufficientMsg}</a>`

    let html = ''
    if (creditsVal >= cost) {
      if (lang === 'fr') {
        html = `<span class="font-semibold text-amber-700 dark:text-amber-400">−${cost} ${crWord}</span>`
      } else {
        html = `<span class="font-semibold text-amber-700 dark:text-amber-400">−${cost}</span> ${crWord}`
      }
    } else {
      html = insufficientHtml
    }

    textEl.innerHTML = html
  },

  // Recalculate total credit cost when reasoning depth changes. The total is
  // exposed through the linked model choice, research preview and Send badge.

  _updateCreditDisplayWithReasoning(surcharge) {
    const totalCredits = this._getActiveModelCredits() + surcharge

    // Reuse _refreshCreditDisplay logic - but we already know the surcharge,
    // so we update badges directly to avoid re-detecting reasoning state
    const badge = document.getElementById('intelligence-credit-badge')
    if (badge) badge.textContent = totalCredits

    const sendBadge = document.getElementById('send-credit-badge')
    if (sendBadge) sendBadge.textContent = `\u2212${totalCredits}cr`

    this._updateSuggestionCostBadges(totalCredits)
    this._updateDeductionPreview(totalCredits)

    // Cost summary bar (only this method updates it - not in _refreshCreditDisplay)
    const costPerQuestion = document.getElementById('cost-per-question')
    if (costPerQuestion) {
      const lang = this.languageValue || 'nl'
      const perQ = lang === 'fr' ? 'cr/question' : lang === 'de' ? 'cr/Frage' : lang === 'en' ? 'cr/question' : 'cr/vraag'
      costPerQuestion.textContent = `${totalCredits} ${perQ}`
    }
  },

  // ========================
  // Conversation History (Target #4)
  // Multi-conversation management (legacy; active version is server-side below)
  // ========================
}
