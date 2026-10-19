/**
 * Chatbot Controller - Settings Mixin
 *
 * Methods extracted from chatbot_controller.js for maintainability.
 * Mixed into the controller prototype - all methods use 'this' as normal.
 */


export const researchDepthMethods = {
  // The fresh default the server rendered for this surface (owner
  // 2026-10-18): the enabled default option of the rendered intelligence
  // level. A stored or unknown level falls back here, not to the first
  // option, which may be a disabled or Pro-only one.
  _freshDefaultOption(options = []) {
    const level = this.element?.dataset?.chatbotIntelligenceValue || this.element?.dataset?.heroChatbotIntelligenceValue || 'genius'
    return options.find(opt => opt.dataset.intelligence === level && opt.dataset.default === 'true' && !opt.disabled) || null
  },

  _researchDepthKeys() { return ['quick', 'balanced', 'thorough', 'extensive'] },
  _normalizedResearchDepth(value = this.researchDepthValue) {
    return this._researchDepthKeys().includes(value) ? value : 'balanced'
  },
  _depthFromLegacyReasoning(level) {
    return ({ low: 'quick', medium: 'balanced', high: 'thorough' })[level] || 'balanced'
  },
  _researchDepthControls() {
    const root = this._isHeroResearchDepth ? this.element : document
    return Array.from(root?.querySelectorAll?.('[data-research-depth-control]') || [])
      .filter(control => this._isHeroResearchDepth || !control.closest?.('[data-controller~="hero-chatbot"]'))
  },
  _researchModelSelects() {
    if (this._isHeroResearchDepth) return this.hasModelSelectTarget ? [this.modelSelectTarget] : []
    if (typeof document === 'undefined') return []
    return ['model-select', 'widget-model-select'].map(id => document.getElementById?.(id)).filter(Boolean)
  },
  _getActiveResearchCombination() {
    // The lightweight hero does not include the full chatbot's credits mixin.
    // Use its native selection without replacing the full/widget getter's
    // authoritative selection (including an intentionally missing option).
    if (typeof this._getActiveModelOption === 'function') return this._getActiveModelOption()
    return this._researchModelSelects()[0]?.selectedOptions?.[0] || null
  },
  _researchCombinationOrder(a, b) {
    const ranks = this._researchDepthKeys()
    const depthDifference = ranks.indexOf(a.dataset.researchDepth) - ranks.indexOf(b.dataset.researchDepth)
    if (depthDifference) return depthDifference
    const costDifference = Number(a.dataset.totalCredits) - Number(b.dataset.totalCredits)
    if (costDifference) return costDifference
    return (a.dataset.modelName || a.value || '').localeCompare(b.dataset.modelName || b.value || '')
      || (a.dataset.reasoningOption || '').localeCompare(b.dataset.reasoningOption || '')
  },
  _researchCombinations() {
    return Array.from(this._researchModelSelects()[0]?.options || [])
      .filter(option => option.dataset.reasoningOption)
      // Keep the full selector portfolio, including manual-only variants.
      .sort((a, b) => this._researchCombinationOrder(a, b))
  },
  _combinationOnResearchBar(option) {
    return Boolean(option && option.dataset.researchBarOption !== 'false'
      // Preserve the curated contract with older or restored option markup.
      && !(option.value === 'mistral-small' && option.dataset.reasoningOption === 'high')
      && option.value !== 'mistral-large-4')
  },
  _researchBarCombinations() {
    return this._researchCombinations().filter(option => this._combinationOnResearchBar(option))
  },
  // The full-page selector and the floating widget intentionally contain
  // separate <option> nodes.  Never compare those nodes by object identity:
  // after a response the widget can be the active selector while the ruler is
  // built from the full-page selector.  That used to add the selected choice
  // a second time and place the ruler thumb on the wrong step.
  _researchCombinationMatches(a, b) {
    return Boolean(a && b && a.value === b.value
      && a.dataset?.reasoningOption === b.dataset?.reasoningOption)
  },
  _researchChoiceIndex(choices, option) {
    return Array.from(choices || []).findIndex(candidate => this._researchCombinationMatches(candidate, option))
  },
  _hasLinkedResearchCombinations() { return this._researchCombinations().length > 0 },
  _researchRulerChoices(combinations, activeOption) {
    const choices = combinations.filter(option => this._combinationOnResearchBar(option) && this._combinationAvailable(option))
    // Preserve an explicitly saved unavailable choice without making it a
    // selectable step or silently substituting a cheaper model.
    if (activeOption && this._combinationOnResearchBar(activeOption)
      && this._researchChoiceIndex(choices, activeOption) < 0) choices.push(activeOption)
    return choices.sort((a, b) => this._researchCombinationOrder(a, b))
  },
  _researchRulerIndex(choices, option) {
    const exact = this._researchChoiceIndex(choices, option)
    if (exact >= 0) return exact
    // A manual-only choice has no tick. Use the nearest same-category price
    // solely as its keyboard anchor; never replace the selected model here.
    const sameDepth = choices.filter(candidate => candidate.dataset.researchDepth === option?.dataset.researchDepth)
    const candidates = sameDepth.length ? sameDepth : choices
    const nearest = candidates.reduce((best, candidate) => !best
      || Math.abs(Number(candidate.dataset.totalCredits) - Number(option?.dataset.totalCredits || 0))
        < Math.abs(Number(best.dataset.totalCredits) - Number(option?.dataset.totalCredits || 0)) ? candidate : best, null)
    return Math.max(0, this._researchChoiceIndex(choices, nearest))
  },
  _combinationAvailable(option) {
    if (!option) return false
    const followup = !this._isHeroResearchDepth && this.conversationHistory?.length > 0
    return !option.disabled && option.dataset.modelAvailable !== 'false'
      && !(followup && option.value === 'mistral-small' && option.dataset.reasoningOption !== 'low')
  },
  _selectResearchCombination(option) {
    if (!option || !this._combinationAvailable(option)) return
    this._researchDepthTouched = true
    this.reasoningLevelValue = option.dataset.reasoningOption === 'fixed' ? 'low' : option.dataset.reasoningOption
    this.researchDepthValue = this._normalizedResearchDepth(option.dataset.researchDepth)
    this.intelligenceValue = option.dataset.intelligence || this.intelligenceValue
    if (this._isHeroResearchDepth) {
      this._heroModelChoiceTouched = true
    } else {
      this._modelChoiceTouched = true
      this.modelOverrideValue = option.value
      this._syncModelDropdowns?.(this.intelligenceValue, option.value)
    }
    this._researchModelSelects().forEach(select => {
      const index = Array.from(select.options).findIndex(candidate => candidate.value === option.value
        && candidate.dataset.reasoningOption === option.dataset.reasoningOption)
      if (index >= 0) select.selectedIndex = index
    })
  },
  _adoptResearchCombination(option) {
    if (!option?.dataset.reasoningOption) return
    this._researchDepthTouched = true
    this.reasoningLevelValue = option.dataset.reasoningOption === 'fixed' ? 'low' : option.dataset.reasoningOption
    this.researchDepthValue = this._normalizedResearchDepth(option.dataset.researchDepth)
  },
  _syncResearchCombinations(option, hasContext) {
    if (!option?.dataset.reasoningOption) return option
    this._researchModelSelects().forEach(select => {
      Array.from(select.options).forEach(candidate => {
        const privateFollowup = hasContext && candidate.value === 'mistral-small' && candidate.dataset.reasoningOption !== 'low'
        candidate.disabled = candidate.dataset.modelAvailable === 'false'
          || candidate.dataset.combinationLocked === 'true' || privateFollowup
      })
      const index = Array.from(select.options).findIndex(candidate => candidate.value === option.value
        && (candidate.dataset.reasoningOption === this.reasoningLevelValue || candidate.dataset.reasoningOption === 'fixed'))
      if (index >= 0) select.selectedIndex = index
    })
    return this._researchModelSelects()[0]?.selectedOptions?.[0] || option
  },
  _researchReasoningForOption(option, hasContext = false) {
    if (option?.dataset.reasoningOption) {
      if (option.value === 'mistral-small' && hasContext) return 'low'
      return option.dataset.reasoningOption === 'fixed' ? 'low' : option.dataset.reasoningOption
    }
    const depth = this._normalizedResearchDepth()
    const desired = { quick: 'low', balanced: 'medium', thorough: 'high', extensive: 'high' }[depth]
    const allowed = (option?.dataset.reasoningLevels || '').split(',').filter(Boolean)
    const hasAccess = option?.dataset.researchReasoningAllowed !== 'false' && this.proValue !== false
    if (!hasAccess || option?.dataset.supportsReasoning !== 'true') return 'low'
    if (option?.value === 'mistral-small' && hasContext) return 'low'
    return allowed.includes(desired) ? desired : (allowed.includes('low') ? 'low' : (allowed[0] || 'low'))
  },
  updateResearchDepth(event) {
    this._researchDepthTouched = true
    const choices = this._researchBarCombinations().filter(option => this._combinationAvailable(option))
    if (choices.length) {
      const index = Math.max(0, Math.min(choices.length - 1, Math.round(Number(event.currentTarget.value) || 0)))
      this._selectResearchCombination(choices[index])
      this._refreshResearchDepthState(event.currentTarget)
      this.savePreferences?.()
      this._saveHeroPreferences?.()
      return
    }
    const value = Math.max(0, Math.min(3, Number(event.currentTarget.value) || 0))
    this.researchDepthValue = this._researchDepthKeys()[Math.round(value)]
    this._syncResearchDepthControls(event.currentTarget)
    this._refreshResearchDepthState(event.currentTarget)
    this.savePreferences?.()
    this._saveHeroPreferences?.()
  },
  handleResearchDepthKeydown(event) {
    const choices = this._researchBarCombinations().filter(option => this._combinationAvailable(option))
    if (choices.length) {
      const current = this._getActiveResearchCombination()
      const index = this._researchRulerIndex(choices, current)
      const next = { ArrowLeft: index - 1, ArrowDown: index - 1, ArrowRight: index + 1, ArrowUp: index + 1, Home: 0, End: choices.length - 1 }[event.key]
      if (next === undefined) return
      event.preventDefault()
      this._selectResearchCombination(choices[Math.max(0, Math.min(choices.length - 1, next))])
      this.commitResearchDepth()
      this.savePreferences?.()
      this._saveHeroPreferences?.()
      return
    }
    const index = this._researchDepthKeys().indexOf(this._normalizedResearchDepth())
    const next = { ArrowLeft: index - 1, ArrowDown: index - 1, ArrowRight: index + 1, ArrowUp: index + 1, Home: 0, End: 3 }[event.key]
    if (next === undefined) return
    event.preventDefault()
    event.currentTarget.value = Math.max(0, Math.min(3, next))
    this.updateResearchDepth(event)
    this.commitResearchDepth()
  },
  commitResearchDepth() { this._syncResearchDepthControls(); this._refreshResearchDepthState() },
  selectResearchDepth(event) {
    const choices = this._researchBarCombinations()
    if (choices.length) {
      const depth = event.currentTarget.dataset.researchDepth
      const available = choices.filter(option => option.dataset.researchDepth === depth && this._combinationAvailable(option))
      if (!available.length) return
      const current = this._getActiveResearchCombination()
      const index = this._researchChoiceIndex(available, current)
      this._selectResearchCombination(index >= 0 ? available[index] : available[0])
      this._refreshResearchDepthState()
      this.savePreferences?.()
      this._saveHeroPreferences?.()
      return
    }
    this._researchDepthTouched = true
    this.researchDepthValue = this._normalizedResearchDepth(event.currentTarget.dataset.researchDepth)
    this._syncResearchDepthControls()
    this._refreshResearchDepthState()
    this.savePreferences?.()
    this._saveHeroPreferences?.()
  },
  _syncResearchDepthControls(draggedRange = null) {
    const depth = this._normalizedResearchDepth()
    this.researchDepthValue = depth
    const index = this._researchDepthKeys().indexOf(depth)
    const combinations = this._researchCombinations()
    const linked = combinations.length > 0
    const activeOption = this._researchModelSelects()[0]?.selectedOptions?.[0]
    const total = linked ? (this._isHeroResearchDepth ? this._heroTotalCredits() : this._getActiveModelTotalCredits?.()) : null
    const choices = this._researchRulerChoices(combinations, activeOption)
    const selectedIndex = this._researchRulerIndex(choices, activeOption)
    const manual = linked && activeOption?.dataset.reasoningOption && !this._combinationOnResearchBar(activeOption)
    this._researchDepthControls().forEach(control => {
      control.classList?.toggle('research-depth-control--manual', Boolean(manual))
      const range = control.querySelector('[data-research-depth-range]')
      const active = control.querySelector('[data-research-depth="' + depth + '"]')
      if (range) {
        range.min = 0
        range.max = linked ? Math.max(1, choices.length - 1) : 3
        range.step = linked ? 1 : 0.01
        if (linked) range.disabled = choices.length <= 1 || !this._combinationAvailable(activeOption)
        if (linked || range !== draggedRange) range.value = linked ? selectedIndex : index
        range.style?.setProperty('--slider-pct', (linked ? selectedIndex / Math.max(1, choices.length - 1) : Number(range.value) / 3) * 100 + '%')
        const selectedLabel = linked ? activeOption?.textContent?.trim() || depth : active?.dataset.depthLabel || depth
        range.setAttribute('aria-valuetext', selectedLabel + (manual && control.dataset?.manualSelectionMessage ? ' · ' + control.dataset.manualSelectionMessage : ''))
        if (linked) {
          this._updateResearchDepthCreditRuler(control, total, choices, activeOption)
          this._updateResearchDepthCategoryWidths(control, choices)
        }
      }
      control.querySelectorAll('[data-research-depth]').forEach(stop => {
        stop.setAttribute('aria-pressed', String(stop.dataset.researchDepth === depth))
        if (linked && stop.tagName === 'BUTTON') stop.disabled = !choices.some(option =>
          option.dataset.researchDepth === stop.dataset.researchDepth && this._combinationAvailable(option))
      })
      const selected = control.querySelector('[data-research-depth-selected]')
      const description = control.querySelector('[data-research-depth-description]')
      if (selected) selected.textContent = active?.dataset.depthLabel || depth
      if (description) description.textContent = active?.dataset.depthDescription || ''
    })
  },
  _refreshResearchDepthState(draggedRange = null) {
    let option = this._isHeroResearchDepth
      ? this.modelSelectTarget?.options?.[this.modelSelectTarget.selectedIndex]
      : this._getActiveModelOption?.()
    const hasContext = !this._isHeroResearchDepth && Array.isArray(this.conversationHistory) && this.conversationHistory.length > 0
    if (option?.dataset.reasoningOption) this.researchDepthValue = this._normalizedResearchDepth(option.dataset.researchDepth)
    this.reasoningLevelValue = this._researchReasoningForOption(option, hasContext)
    option = this._syncResearchCombinations(option, hasContext)
    // A Small/high follow-up resolves to the low/quick combination. Update the
    // category from that actual selection, not its now-disabled high option.
    if (option?.dataset.reasoningOption) this.researchDepthValue = this._normalizedResearchDepth(option.dataset.researchDepth)
    this._refreshCreditDisplay?.()
    this._refreshHeroCreditDisplay?.()
    this._syncResearchDepthControls(draggedRange)
    this._updateResearchDepthPreview(option, hasContext)
  },
  _updateResearchDepthPreview(option = this._getActiveModelOption?.(), hasContext = false) {
    const depth = this._normalizedResearchDepth()
    const total = this._isHeroResearchDepth ? this._heroTotalCredits() : this._getActiveModelTotalCredits?.()
    this._researchDepthControls().forEach(control => {
      const active = control.querySelector('[data-research-depth="' + depth + '"]')
      const preview = control.querySelector('[data-research-depth-preview]')
      if (!option?.dataset.reasoningOption) this._updateResearchDepthCreditRuler(control, total)
      if (preview) preview.textContent = (control.dataset.previewTemplate || '')
        .replace('%{model}', option?.dataset.modelName || option?.value || '')
        .replace('%{reasoning}', option?.dataset.reasoningLabel || '')
        .replace('%{credits}', String(total ?? 0))
        .replace('%{time}', active?.dataset.depthTime || '')
        + (option?.dataset.reasoningOption && !this._combinationOnResearchBar(option)
          && control.dataset.manualSelectionMessage ? ' · ' + control.dataset.manualSelectionMessage : '')
      const capability = control.querySelector('[data-research-depth-capability]')
      if (capability) {
        const desired = option?.dataset.reasoningOption
          ? (option.dataset.reasoningOption === 'fixed' ? 'low' : option.dataset.reasoningOption)
          : { quick: 'low', balanced: 'medium', thorough: 'high', extensive: 'high' }[depth]
        capability.textContent = option?.value === 'mistral-small' && hasContext && (option?.dataset.reasoningOption || desired === 'high')
          ? control.dataset.followupReasoningMessage
          : option?.dataset.supportsReasoning !== 'true'
            ? control.dataset.fixedReasoningMessage
            : this.reasoningLevelValue !== desired ? control.dataset.limitedReasoningMessage : ''
      }
      const indicator = this._isHeroResearchDepth
        ? this.element?.querySelector('#hero-level-indicator')
        : document.getElementById('widget-level-indicator')
      if (indicator && active) indicator.textContent = active.dataset.depthLabel + ' · ' + (option?.dataset.modelName || option?.value || '')
    })
  },
  _updateResearchDepthCreditRuler(control, total, choices = null, activeOption = null) {
    const ruler = control.querySelector('[data-research-depth-credit-ruler]')
    if (!ruler) return
    if (Array.isArray(choices) && choices.length) {
      const selected = activeOption || this._getActiveModelOption?.() || this._researchModelSelects()[0]?.selectedOptions?.[0]
      const selectedIndex = this._researchChoiceIndex(choices, selected)
      const signature = JSON.stringify(choices.map(option => [option.value, option.dataset.reasoningOption, option.dataset.totalCredits]))
      const creditPrices = [...new Set(choices.map(option => Number(option.dataset.totalCredits)))]
      if (ruler.dataset.tickSignature !== signature) {
        const createTick = (kind, position, value) => {
          const tick = ruler.ownerDocument.createElement('span')
          tick.className = 'research-depth-' + kind + '-tick'
          tick.setAttribute('aria-hidden', 'true')
          if (kind === 'step') tick.dataset.stepIndex = String(value)
          else {
            tick.dataset.credit = String(value)
            tick.dataset.creditIndex = String(position)
          }
          tick.style.setProperty('--tick-position', position / Math.max(1, choices.length - 1) * 100 + '%')
          return tick
        }
        const ticks = choices.map((option, index) => createTick('step', index, index))
        for (const credit of creditPrices) {
          ticks.push(createTick('credit', choices.findIndex(option => Number(option.dataset.totalCredits) === credit), credit))
        }
        ruler.replaceChildren(...ticks)
        ruler.dataset.tickSignature = signature
        ruler.dataset.stepCount = String(choices.length)
        ruler.dataset.creditCount = String(creditPrices.length)
      }
      Array.from(ruler.children).forEach(tick => {
        const active = selectedIndex >= 0 && (tick.dataset.stepIndex !== undefined
          ? Number(tick.dataset.stepIndex) <= selectedIndex : Number(tick.dataset.creditIndex) <= selectedIndex)
        tick.classList?.toggle('research-depth-credit-tick--active', active)
      })
      return
    }
    // Compatibility for older markup without linked combination metadata.
    const maxCredits = total
    const credits = Number.isSafeInteger(Number(maxCredits)) && Number(maxCredits) >= 0 ? Number(maxCredits) : 0
    if (ruler.dataset.creditCount === String(credits)) {
      Array.from(ruler.children).forEach((tick, index) => tick.classList?.toggle('research-depth-credit-tick--active', index < Number(total)))
      return
    }
    const ticks = Array.from({ length: credits }, (_, index) => {
      const tick = ruler.ownerDocument.createElement('span')
      tick.className = 'research-depth-credit-tick' + (index < Number(total) ? ' research-depth-credit-tick--active' : '')
      tick.setAttribute('aria-hidden', 'true')
      tick.style?.setProperty('--tick-position', index / Math.max(1, credits - 1) * 100 + '%')
      return tick
    })
    ruler.replaceChildren(...ticks)
    ruler.dataset.creditCount = String(credits)
  },
  // The four research categories are summaries of the individual ruler
  // choices. Their boundaries sit halfway between adjacent ticks. Empty
  // categories get a compact disabled tail beside the actual track; scaling
  // the real track keeps its tick spacing and category proportions intact.
  _updateResearchDepthCategoryWidths(control, choices) {
    const profiles = control.querySelector?.('[data-research-depth-profiles]')
    if (!profiles || !Array.isArray(choices) || !choices.length) return

    const lastIndex = choices.length - 1
    const divisor = Math.max(1, lastIndex)
    const depths = this._researchDepthKeys()
    const indexesFor = depth => choices.reduce((indexes, option, index) => {
      if (option.dataset.researchDepth === depth) indexes.push(index)
      return indexes
    }, [])
    const midpointBefore = index => (index - .5) / divisor * 100
    const midpointAfter = index => (index + .5) / divisor * 100

    const emptyDepths = depths.filter(depth => indexesFor(depth).length === 0)
    const emptyWidth = Math.min(18, 54 / Math.max(1, emptyDepths.length))
    const availableWidth = 100 - emptyDepths.length * emptyWidth
    control.style?.setProperty('--available-track-scale', String(availableWidth / 100))
    profiles.classList?.toggle('research-depth-stops--has-empty', emptyDepths.length > 0)
    control.classList?.toggle('research-depth-control--has-empty', emptyDepths.length > 0)

    depths.forEach(depth => {
      const stop = profiles.querySelector?.('[data-research-depth="' + depth + '"]')
      if (!stop) return
      const indexes = indexesFor(depth)
      let start
      let end

      if (indexes.length) {
        const first = indexes[0]
        const last = indexes[indexes.length - 1]
        start = (first === 0 ? 0 : midpointBefore(first)) * availableWidth / 100
        end = (last === lastIndex ? 100 : midpointAfter(last)) * availableWidth / 100
        stop.classList?.remove('research-depth-stop--empty')
      } else {
        // This segment contains no choice or credit tick. Keep it outside the
        // range input, so dragging or using the keyboard cannot select it.
        start = availableWidth + emptyDepths.indexOf(depth) * emptyWidth
        end = start + emptyWidth
        stop.classList?.add('research-depth-stop--empty')
      }

      stop.style?.setProperty('--category-start', start + '%')
      stop.style?.setProperty('--category-width', Math.max(0, end - start) + '%')
    })
  }
}

export const settingsMethods = {
  updateSource(event) {
    this.sourceValue = event.target.value
    this.savePreferences()
  },

  // Update sources from checkboxes

  updateSources() {
    const sources = []

    if (this.hasSourceLegislationTarget && this.sourceLegislationTarget.checked) {
      sources.push('legislation')
    }
    // A disabled box is a Pro-only source this account may not use; never
     // collect it, so a stale saved preference cannot send it to the API.
    if (this.hasSourceJurisprudenceTarget && this.sourceJurisprudenceTarget.checked && !this.sourceJurisprudenceTarget.disabled) {
      sources.push('jurisprudence')
    }
    if (this.hasSourceParliamentaryTarget && this.sourceParliamentaryTarget.checked && !this.sourceParliamentaryTarget.disabled) {
      sources.push('parliamentary')
    }

    // Convert to source value: single source or 'all' for multiple
    if (sources.length === 0) {
      // Default to legislation if nothing selected
      this.sourceValue = 'legislation'
      if (this.hasSourceLegislationTarget) {
        this.sourceLegislationTarget.checked = true
      }
    } else if (sources.length === 1) {
      this.sourceValue = sources[0]
    } else {
      // Multiple sources selected - use custom format
      this.sourceValue = sources.join(',')
    }

    this._trackEvent('chatbot-source-change', { source: this.sourceValue })
    this.savePreferences()
  },

  // Get currently selected sources as array

  getSelectedSources() {
    // Full-page settings panel present: read its checkboxes directly.
    if (this.hasSourceLegislationTarget) {
      const sources = []
      if (this.sourceLegislationTarget.checked) sources.push('legislation')
      if (this.hasSourceJurisprudenceTarget && this.sourceJurisprudenceTarget.checked && !this.sourceJurisprudenceTarget.disabled) sources.push('jurisprudence')
      if (this.hasSourceParliamentaryTarget && this.sourceParliamentaryTarget.checked && !this.sourceParliamentaryTarget.disabled) sources.push('parliamentary')
      return sources.length > 0 ? sources : ['legislation']
    }
    // Widget (settings panel not rendered on non-/chatbot pages): sourceValue is
    // the synced source of truth, maintained by updateWidgetSources from the
    // #widget-src-* checkboxes. Reading the absent full-page targets here would
    // silently drop a jurisprudence/parliamentary selection.
    const fromValue = (this.sourceValue || 'legislation').split(',').map((s) => s.trim()).filter(Boolean)
    // Case law and parliamentary documents via the chatbot are Pro-only; the
    // server rejects them anyway, so do not spend a request on a saved value.
    const allowed = this.proValue ? fromValue : fromValue.filter((s) => s === 'legislation')
    return allowed.length > 0 ? allowed : ['legislation']
  },

  // Sync source checkboxes from saved preferences (called on connect).
  // Ensures logged-in users see their previously selected sources restored.

  _syncSourceCheckboxes() {
    const saved = this.sourceValue
    if (!saved) return

    const sources = saved.split(',').map(s => s.trim())

    // Full-page settings panel checkboxes
    if (this.hasSourceLegislationTarget) {
      this.sourceLegislationTarget.checked = sources.includes('legislation')
    }
    if (this.hasSourceJurisprudenceTarget && !this.sourceJurisprudenceTarget.disabled) {
      this.sourceJurisprudenceTarget.checked = sources.includes('jurisprudence')
    }
    if (this.hasSourceParliamentaryTarget && !this.sourceParliamentaryTarget.disabled) {
      this.sourceParliamentaryTarget.checked = sources.includes('parliamentary')
    }

    // Widget checkboxes
    const widgetLeg = document.getElementById('widget-src-leg')
    const widgetJur = document.getElementById('widget-src-jur')
    const widgetParl = document.getElementById('widget-src-parl')
    if (widgetLeg) widgetLeg.checked = sources.includes('legislation')
    if (widgetJur && !widgetJur.disabled) widgetJur.checked = sources.includes('jurisprudence')
    if (widgetParl && !widgetParl.disabled) widgetParl.checked = sources.includes('parliamentary')
  },

  // ═══════════════════════════════════════════════
  // NOTE: Legacy updateIntelligenceSlider (data-max-unlocked based)
  // was removed - the correct version below reads locked state from
  // individual notch buttons. See _intelligenceLevels getter.

  // ═══════════════════════════════════════════════
  // SLIDER HANDLERS - Intelligence + Reasoning
  // ═══════════════════════════════════════════════

  // Intelligence level keys (must match server order)
  get _intelligenceLevels() {
    const notches = document.querySelectorAll('#intelligence-slider-section .notch-label[data-intelligence-level]')
    if (!notches.length) {
      const options = this._allModelOptions || this._allWidgetModelOptions || Array.from(document.querySelectorAll('#model-select option, #widget-model-select option'))
      const seen = new Set()
      return options.filter(option => { const level = option.dataset.intelligence; if (seen.has(level)) return false; seen.add(level); return true }).map(option => ({ id: option.dataset.intelligence, credits: parseInt(option.dataset.credits || '1'), locked: option.disabled && option.dataset.modelAvailable !== 'false', tier: option.dataset.tier || 'free' }))
    }
    return Array.from(notches).map(n => ({
      id: n.dataset.intelligenceLevel,
      credits: parseInt(n.dataset.intelligenceCredits || '1'),
      locked: n.dataset.intelligenceLocked === 'true',
      tier: n.dataset.intelligenceTier || 'free',
      supportsReasoning: n.dataset.supportsReasoning === 'true',
      defaultReasoning: n.dataset.defaultReasoning || 'low'
    }))
  },

  // Reasoning level keys
  get _reasoningLevels() {
    const notches = document.querySelectorAll('#reasoning-controls .notch-label[data-reasoning-level]')
    return Array.from(notches).map(n => ({
      id: n.dataset.reasoningLevel,
      surcharge: parseInt(n.dataset.surcharge || '0'),
      estimatedSeconds: parseInt(n.dataset.estimatedSeconds || '15')
    }))
  },

  // Apply the model-specific reasoning enum advertised by the server. Most
  // models support low/medium/high; Mistral Small supports only low/high
  // (provider none/high), while Mistral Large exposes no reasoning control.
  // Unsupported saved values are reset to low so they are neither sent nor charged.
  _applyModelReasoningCapabilities(option, preferredLevel = this.reasoningLevelValue) {
    if (this._researchDepthControls().length) {
      this._refreshResearchDepthState()
      return option?.dataset.supportsReasoning === 'true'
    }
    const controls = document.getElementById('reasoning-controls')
    const levels = this._reasoningLevels
    const advertised = (option?.dataset.reasoningLevels || '')
      .split(',')
      .map(level => level.trim())
      .filter(Boolean)
    const allowed = option?.dataset.supportsReasoning === 'true' ? advertised : []
    const supportsReasoning = allowed.length > 0

    if (controls) controls.style.display = supportsReasoning ? '' : 'none'

    const notches = document.querySelectorAll('#reasoning-controls .notch-label[data-reasoning-level]')
    notches.forEach(notch => {
      const isAllowed = allowed.includes(notch.dataset.reasoningLevel)
      notch.classList.toggle('hidden', !isAllowed)
      notch.hidden = !isAllowed
      notch.setAttribute('aria-hidden', String(!isAllowed))
    })

    let effectiveLevel = preferredLevel
    if (!supportsReasoning || !allowed.includes(effectiveLevel)) {
      effectiveLevel = allowed.includes('low') ? 'low' : (allowed[0] || 'low')
    }
    this.reasoningLevelValue = effectiveLevel

    const slider = document.getElementById('reasoning-range')
    const effectiveIdx = levels.findIndex(level => level.id === effectiveLevel)
    const allowedIndices = levels
      .map((level, index) => allowed.includes(level.id) ? index : null)
      .filter(index => index !== null)
    if (slider) {
      slider.min = allowedIndices.length ? Math.min(...allowedIndices) : 0
      slider.max = allowedIndices.length ? Math.max(...allowedIndices) : Math.max(levels.length - 1, 0)
      // low/high are indices 0/2, so a step of 2 makes medium unreachable by
      // mouse, touch, and keyboard while preserving the shared visual track.
      slider.step = allowedIndices.length === 2 ? Math.abs(allowedIndices[1] - allowedIndices[0]) : 1
      slider.value = effectiveIdx >= 0 ? effectiveIdx : 0
      this._updateSliderFill(slider, parseInt(slider.value), Math.max(levels.length - 1, 1))
      this._updateNotchHighlight('#reasoning-controls', parseInt(slider.value))
    }

    const selected = levels.find(level => level.id === effectiveLevel)
    const surcharge = typeof this._reasoningSurchargeForModelOption === 'function'
      ? this._reasoningSurchargeForModelOption(option, effectiveLevel)
      : (selected?.surcharge || 0)
    this._updateCreditDisplayWithReasoning(supportsReasoning ? surcharge : 0)
    return supportsReasoning
  },

  // Called when intelligence range slider is moved

  updateIntelligenceSlider(event) {
    const slider = event.currentTarget
    const idx = parseInt(slider.value)
    const levels = this._intelligenceLevels
    if (idx >= levels.length) return

    const level = levels[idx]
    this._modelChoiceTouched = true

    // Allow selection of locked levels - blocked at send time instead
    // Track locked state for send-time validation
    this._selectedLevelLocked = level.locked
    this._selectedLevelTier = level.tier || 'free'

    this.intelligenceValue = level.id
    this.reasoningLevelValue = level.defaultReasoning
    this._trackEvent('chatbot-intelligence-change', { intelligence: level.id })

    // Update slider fill
    this._updateSliderFill(slider, idx, levels.length - 1)

    // Update notch highlights
    this._updateNotchHighlight('#intelligence-slider-section', idx)

    // Update the subtitle indicator (matches widget's footer indicator)
    this._updateIntelligenceSubtitle(idx)

    // Filter model dropdown (MUST happen before credit refresh so per-model credits resolve)
    const selectedOpt = this._syncModelDropdowns(level.id, this.modelOverrideValue)

    // Apply the selected model's exact provider capability before calculating
    // the displayed credit cost.
    this._applyModelReasoningCapabilities(selectedOpt, level.defaultReasoning)
    this._refreshCreditDisplay()
    this.savePreferences()
  },

  // Click a notch label to jump the intelligence slider

  clickNotch(event) {
    const notch = event.currentTarget
    const idx = parseInt(notch.dataset.notchIndex)
    const locked = notch.dataset.intelligenceLocked === 'true'

    // Show pro tooltip for locked tiers
    if (locked) {
      this._showProTooltip(notch)
    }

    // Allow clicking locked notches - selection is free, blocked at send time
    const slider = document.getElementById('intelligence-range')
    if (slider) {
      slider.value = idx
      slider.dispatchEvent(new Event('input', { bubbles: true }))
    }
  },

  // Click on a locked source checkbox (e.g. Rechtspraak for non-Pro users)

  handleLockedSource(event) {
    event.preventDefault()
    event.stopPropagation()
    this._showProTooltip(event.currentTarget)
  },

  // Called when reasoning range slider is moved

  updateReasoningSlider(event) {
    const slider = event.currentTarget
    const idx = parseInt(slider.value)
    const levels = this._reasoningLevels
    if (idx >= levels.length) return

    const level = levels[idx]
    const activeOption = typeof this._getActiveModelOption === 'function' ? this._getActiveModelOption() : null
    const allowed = (activeOption?.dataset.reasoningLevels || '').split(',').filter(Boolean)
    if (!allowed.includes(level.id)) {
      this._applyModelReasoningCapabilities(activeOption, level.id)
      this.savePreferences()
      return
    }

    this.reasoningLevelValue = level.id
    this._trackEvent('chatbot-reasoning-change', { reasoning: level.id, intelligence: this.intelligenceValue })
    this.savePreferences()

    this._updateSliderFill(slider, idx, levels.length - 1)
    this._updateNotchHighlight('#reasoning-controls', idx)

    // Recalculate total credits (base + reasoning surcharge)
    this._updateCreditDisplayWithReasoning(
      this._reasoningSurchargeForModelOption(activeOption, level.id)
    )
  },

  // Click a reasoning notch label

  clickReasoningNotch(event) {
    const notch = event.currentTarget
    if (notch.hidden || notch.classList.contains('hidden') || notch.getAttribute('aria-hidden') === 'true') return

    const idx = parseInt(notch.dataset.notchIndex)
    const slider = document.getElementById('reasoning-range')
    if (slider && !slider.disabled) {
      slider.value = idx
      slider.dispatchEvent(new Event('input', { bubbles: true }))
    }
  },

  // Update the CSS variable that controls the filled track gradient

  _updateSliderFill(slider, value, max) {
    const pct = max > 0 ? (value / max * 100) : 0
    slider.style.setProperty('--slider-pct', `${pct}%`)
  },

  // Highlight the active notch label text

  _updateNotchHighlight(containerSelector, activeIdx) {
    const container = document.querySelector(containerSelector)
    if (!container) return
    container.querySelectorAll('.notch-label').forEach((notch, i) => {
      const textEl = notch.querySelector('.notch-text')
      if (!textEl) return
      if (i === activeIdx) {
        textEl.classList.remove('text-gray-500', 'dark:text-gray-400')
        textEl.classList.add('text-gray-900', 'dark:text-white')
      } else {
        textEl.classList.remove('text-gray-900', 'dark:text-white')
        textEl.classList.add('text-gray-500', 'dark:text-gray-400')
      }
    })
  },

  // Update the intelligence subtitle indicator on the main chatbot page
  // Reads label + description from the active notch's data attributes

  _updateIntelligenceSubtitle(activeIdx) {
    const subtitle = document.getElementById('intelligence-level-subtitle')
    if (!subtitle) return

    const notches = document.querySelectorAll('#intelligence-slider-section .notch-label[data-intelligence-level]')
    const notch = notches[activeIdx]
    if (!notch) return

    const lang = this.languageValue || 'nl'
    const label = notch.dataset[`label${lang.charAt(0).toUpperCase() + lang.slice(1)}`] || notch.dataset.labelNl || ''
    const desc = notch.dataset[`desc${lang.charAt(0).toUpperCase() + lang.slice(1)}`] || notch.dataset.descNl || ''
    const locked = notch.dataset.intelligenceLocked === 'true'
    const proTag = locked ? ' <span class="text-amber-400 font-semibold">PRO</span>' : ''

    subtitle.innerHTML = `<span data-active-label>${label}${proTag}</span> <span data-active-desc class="text-gray-500">| ${desc}</span>`
  },

  // Sync slider positions from saved preferences (called on connect)

  _syncSlidersFromPreferences() {
    const levels = this._intelligenceLevels
    const savedLevel = this.intelligenceValue || 'genius'
    const savedModel = this.modelOverrideValue
    const idx = levels.findIndex(l => l.id === savedLevel)
    if (idx < 0 && levels.length) return

    const slider = document.getElementById('intelligence-range')
    if (slider) {
      slider.value = idx
      this._updateSliderFill(slider, idx, levels.length - 1)
      this._updateNotchHighlight('#intelligence-slider-section', idx)
      this._updateIntelligenceSubtitle(idx)
    }

    // Restore one model selection across both controls. Filtering used to reset
    // the full-page selector to the tier default before the saved model could be
    // restored, leaving request state, displayed price, and the widget divergent.
    const selectedModelOption = this._syncModelDropdowns(savedLevel, savedModel)

    // Sync profile dropdown (full-page)
    if (this.profileValue && this.hasProfileSelectTarget) {
      this.profileSelectTarget.value = this.profileValue
    }

    // Sync widget profile dropdown
    if (this.profileValue) {
      const wps = document.getElementById('widget-profile-select')
      if (wps) wps.value = this.profileValue
    }

    // Sync widget source checkboxes
    if (this.sourceValue) {
      const sources = this.sourceValue.split(',')
      const legCb = document.getElementById('widget-src-leg')
      const jurCb = document.getElementById('widget-src-jur')
      const parlCb = document.getElementById('widget-src-parl')
      if (legCb) legCb.checked = sources.includes('legislation')
      if (jurCb && !jurCb.disabled) jurCb.checked = sources.includes('jurisprudence')
      // Same guard as the box above. A preference saved while the account was
      // Pro ticked the disabled box, and _syncSourceCheckboxes skips disabled
      // boxes, so nothing could untick it: "Parl." stayed ticked and greyed
      // out for a source that is never searched.
      if (parlCb && !parlCb.disabled) parlCb.checked = sources.includes('parliamentary')
    }

    // Restore only a reasoning value supported by the selected provider model.
    this._applyModelReasoningCapabilities(selectedModelOption, this.reasoningLevelValue || 'low')

    // Use shared credit refresh (reads per-model credits from the selected <option>)
    this._refreshResearchDepthState()
    this._refreshCreditDisplay()
  },

  // Legacy: keep updateIntelligence for backward compat (old button approach)

  updateIntelligence(event) {
    const button = event.currentTarget
    const level = button.dataset.intelligenceLevel
    if (!level) return

    if (button.dataset.intelligenceLocked === 'true') {
      this._showProTooltip(button)
      return
    }

    this._modelChoiceTouched = true
    this.intelligenceValue = level
    this.reasoningLevelValue = button.dataset.defaultReasoning || 'low'
    this._trackEvent('chatbot-intelligence-change', { intelligence: level })

    // Keep the full-page and widget selectors on exactly the same model.
    const selectedOpt = this._syncModelDropdowns(level, this.modelOverrideValue)

    // Apply the selected model's exact provider reasoning enum.
    this._applyModelReasoningCapabilities(selectedOpt, this.reasoningLevelValue)
    this.savePreferences()
  },

  // Update model (Pro model picker dropdown)

  updateModel(event) {
    const select = event.currentTarget
    const modelId = select.value
    if (!modelId) return
    this._modelChoiceTouched = true
    this._adoptResearchCombination(select.options?.[select.selectedIndex])

    const selectedOption = this._syncModelDropdowns(this.intelligenceValue, modelId)
    this._trackEvent('chatbot-model-change', { model: modelId, intelligence: this.intelligenceValue })

    // Per-model capability controls both the visible choices and the surcharge.
    this._applyModelReasoningCapabilities(selectedOption, this.reasoningLevelValue)

    this.savePreferences()

    // Refresh credit display for the newly selected model's cost
    this._refreshCreditDisplay()
  },

  // When intelligence tier changes, auto-select the default model for that tier
  // NOTE: <option> elements cannot be hidden via CSS display:none or the hidden
  // attribute in Chrome/Safari/Edge. We must physically remove and re-insert them.

  _filterModelDropdown(level, preferredModel = null) {
    const select = document.getElementById('model-select')
    if (!select) return

    // Cache all options on first call (survives tier switches)
    if (!this._allModelOptions) {
      this._allModelOptions = Array.from(select.querySelectorAll('option'))
    }

    // Clear the select and re-insert only matching options
    select.innerHTML = ''
    let firstVisible = null
    let defaultForTier = null
    let preferredForTier = null

    for (const opt of this._allModelOptions) {
      {
        select.appendChild(opt)
        if (!firstVisible && !opt.disabled) firstVisible = opt
        if (opt.dataset.intelligence === level && opt.dataset.default === 'true' && !opt.disabled) {
          defaultForTier = opt
        }
        if (opt.value === preferredModel && (!opt.disabled || opt.dataset.modelAvailable === 'false')
          && (!preferredForTier || opt.dataset.reasoningOption === this.reasoningLevelValue)) preferredForTier = opt
      }
    }

    // Preserve an explicit/saved selection when it belongs to the tier;
    // otherwise use the server-rendered default of that tier, then the fresh
    // default rendered on this surface, never a disabled option.
    const toSelect = preferredForTier || defaultForTier || this._freshDefaultOption(this._allModelOptions) || firstVisible
    if (toSelect) {
      toSelect.selected = true
    }
    return toSelect
  },

  // Filter and mirror both model selectors as one state transition. The main
  // panel and floating widget can coexist on /chatbot; independently resetting
  // either selector made the visible model, request model, and credit badge drift.
  _syncModelDropdowns(level, preferredModel = this.modelOverrideValue) {
    let mainOption = this._filterModelDropdown(level, preferredModel)
    let widgetOption = this._filterWidgetModelDropdown(level, preferredModel)
    let selected = [mainOption, widgetOption].find(option => option?.value === preferredModel)
      || mainOption
      || widgetOption

    if (!selected) return null

    if (mainOption && mainOption.value !== selected.value) {
      mainOption = this._filterModelDropdown(level, selected.value)
    }
    if (widgetOption && widgetOption.value !== selected.value) {
      widgetOption = this._filterWidgetModelDropdown(level, selected.value)
    }

    selected = mainOption || widgetOption || selected
    this.modelOverrideValue = selected.value
    this.intelligenceValue = selected.dataset.intelligence || level
    this._selectedLevelLocked = selected.disabled && selected.dataset.modelAvailable !== 'false'
    this._selectedLevelTier = selected.dataset.tier || 'pro'
    this._refreshModelAvailability(selected)
    return selected
  },

  // A pending saved choice stays explicit and visible: never substitute a
  // cheaper tier default, and never treat a Pro preview as provider access.
  _unavailableModelOption(modelId = this.modelOverrideValue) {
    const options = [
      ...(this._allModelOptions || []), ...(this._allWidgetModelOptions || []),
      ...Array.from(document.getElementById('model-select')?.options || []),
      ...Array.from(document.getElementById('widget-model-select')?.options || [])
    ]
    const option = modelId ? options.find(candidate => candidate.value === modelId) : this._getActiveModelOption?.()
    return option?.dataset.modelAvailable === 'false' ? option : null
  },

  _refreshModelAvailability(option) {
    const pending = option?.dataset.modelAvailable === 'false'
    for (const id of ['model-availability-notice', 'widget-model-availability-notice']) {
      const notice = document.getElementById(id)
      if (!notice) continue
      notice.hidden = !pending
      notice.textContent = pending ? option.dataset.comingSoonMessage : ''
    }
  },

  _blockUnavailableModelRequest(modelId = this.modelOverrideValue) {
    const option = this._unavailableModelOption(modelId)
    if (!option) return false
    this._refreshModelAvailability(option)
    this._showToast?.(option.dataset.comingSoonMessage, 'info')
    return true
  },

  async _prepareModelPreferenceForSend() {
    const token = this._modelPreferenceLoadToken
    let timer
    let cancel
    this._modelPreferenceSendWaiting = true
    try {
      const stopped = new Promise(resolve => {
        cancel = () => resolve(false)
        this._cancelModelPreferenceWait = cancel
        timer = setTimeout(cancel, 5000)
      })
      const ready = await Promise.race([this._modelPreferencesReady.then(loaded => loaded === true, () => false), stopped])
      if (this._modelPreferencesConnected === false || token !== this._modelPreferenceLoadToken) return false
      if (ready || this._modelChoiceTouched || this._heroOverrideActive) return true
      for (const id of ['model-availability-notice', 'widget-model-availability-notice']) {
        const notice = document.getElementById(id)
        if (!notice) continue
        notice.textContent = notice.dataset.preferencesLoadingMessage
        notice.hidden = false
      }
      return false
    } finally {
      clearTimeout(timer)
      if (this._cancelModelPreferenceWait === cancel) this._cancelModelPreferenceWait = null
      this._modelPreferenceSendWaiting = false
    }
  },

  // Show a non-intrusive inline toast when user clicks a locked tier

  _showUpgradeToast(levelOrButton) {
    // Remove any existing toast
    const existing = document.getElementById('upgrade-toast')
    if (existing) existing.remove()

    const lang = this.languageValue
    // Accept either a string (level name) or a DOM element (button)
    const level = typeof levelOrButton === 'string'
      ? levelOrButton
      : (levelOrButton.querySelector('.btn-label')?.textContent?.trim() || levelOrButton.dataset.intelligenceLevel || 'dit niveau')

    const messages = {
      nl: { text: `${level} is beschikbaar met WetWijzer Pro.`, link: 'Ontdek Pro →', sub: 'Rechtspraak & parlementaire stukken via de chatbot, alle AI-niveaus & 30% korting' },
      fr: { text: `${level} est disponible avec WetWijzer Pro.`, link: 'Découvrir Pro →', sub: 'Jurisprudence & documents parlementaires via le chatbot, tous les niveaux IA & 30% de réduction' },
      de: { text: `${level} ist mit WetWijzer Pro verfügbar.`, link: 'Pro entdecken →', sub: 'Rechtsprechung & Parlamentsdokumente über den Chatbot, alle KI-Stufen & 30% Rabatt' },
      en: { text: `${level} is available with WetWijzer Pro.`, link: 'Discover Pro →', sub: 'Case law & parliamentary documents via the chatbot, all AI levels & 30% off packs' }
    }
    const msg = messages[lang] || messages.nl

    const toast = document.createElement('div')
    toast.id = 'upgrade-toast'
    toast.className = 'flex items-center gap-3 mt-1.5 px-3 py-2 rounded-lg text-xs font-medium cursor-pointer ' +
      'bg-gradient-to-r from-amber-50 to-orange-50 dark:from-amber-900/30 dark:to-orange-900/20 ' +
      'text-amber-800 dark:text-amber-300 ' +
      'border border-amber-200 dark:border-amber-700/40 ' +
      'hover:shadow-md transition-all duration-300'
    toast.innerHTML = `
      <span>${msg.text} <span class="opacity-60 text-[10px]">${msg.sub}</span></span>
      <a href="/pricing" class="ml-auto bg-amber-500 hover:bg-amber-600 text-white px-3 py-1 rounded font-semibold whitespace-nowrap text-[11px] transition-colors shadow-sm">${msg.link}</a>
    `
    toast.addEventListener('click', (e) => {
      if (e.target.tagName !== 'A') window.location.href = '/pricing'
    })

    // Insert after the intelligence slider container
    const container = typeof levelOrButton === 'string'
      ? document.getElementById('model-controls')?.parentElement
      : levelOrButton.closest('.intelligence-slider')?.parentElement?.parentElement
    if (container) {
      container.after(toast)
    } else {
      // Fallback: insert at top of chat area
      document.querySelector('.chatbot-messages, .chat-area')?.prepend(toast)
    }

    // Auto-dismiss after 6s (longer to give time to read)
    setTimeout(() => {
      toast.style.opacity = '0'
      setTimeout(() => toast.remove(), 300)
    }, 6000)
  },

  // Update reasoning level

  updateReasoning(event) {
    const button = event.currentTarget
    const level = button.dataset.reasoningLevel
    if (!level) return

    this.reasoningLevelValue = level
    this._trackEvent('chatbot-reasoning-change', { reasoning: level, intelligence: this.intelligenceValue })
    this.savePreferences()

    // Update button styles
    this._updateReasoningButtons(level)

    // Update warning/recommended indicators
    this._updateReasoningIndicators(this.intelligenceValue, level)

    // Update total credits display
    this._updateTotalCreditsDisplay()
  },

  // Show/hide reasoning selector row

  _showReasoningSelector(show) {
    if (this.hasReasoningSelectorTarget) {
      this.reasoningSelectorTarget.classList.toggle('hidden', !show)
    }
    // Also show/hide total credits display
    const totalDisplay = document.getElementById('total-credits-display')
    if (totalDisplay) totalDisplay.classList.toggle('hidden', !show)
  },

  // Update reasoning button active states

  _updateReasoningButtons(activeLevel) {
    document.querySelectorAll('.reasoning-btn').forEach(btn => {
      const isActive = btn.dataset.reasoningLevel === activeLevel
      if (isActive) {
        btn.className = btn.className.replace(
          /bg-gray-50 dark:bg-gray-900 text-gray-500 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-700/g,
          'bg-(--accent-600-solid) text-white'
        )
        if (!btn.className.includes('bg-(--accent-600-solid)')) {
          btn.className = btn.className.replace(
            /bg-\(--accent-600-solid\) text-white/g, ''
          )
          btn.classList.add('bg-(--accent-600-solid)', 'text-white')
          btn.classList.remove('bg-gray-50', 'dark:bg-gray-900', 'text-gray-500', 'dark:text-gray-400', 'hover:bg-gray-100', 'dark:hover:bg-gray-700')
        }
      } else {
        btn.classList.remove('bg-(--accent-600-solid)', 'text-white')
        btn.classList.add('bg-gray-50', 'dark:bg-gray-900', 'text-gray-500', 'dark:text-gray-400', 'hover:bg-gray-100', 'dark:hover:bg-gray-700')
      }
    })
  },

  // Update warning/recommended indicators based on current intelligence + reasoning

  _updateReasoningIndicators(intelligence, reasoning) {
    const warningEl = document.getElementById('reasoning-warning')
    const recommendedEl = document.getElementById('reasoning-recommended')
    if (!warningEl || !recommendedEl) return

    // Find the active reasoning button to check its data attributes
    const activeBtn = document.querySelector(`.reasoning-btn[data-reasoning-level="${reasoning}"]`)
    if (!activeBtn) return

    const warningFor = (activeBtn.dataset.warningFor || '').split(',')
    const recommendedFor = (activeBtn.dataset.recommendedFor || '').split(',')

    const showWarning = warningFor.includes(intelligence)
    const showRecommended = recommendedFor.includes(intelligence)

    warningEl.classList.toggle('hidden', !showWarning)
    recommendedEl.classList.toggle('hidden', !showRecommended)
  },

  // Update total credit cost display

  updateProfile(event) {
    this.profileValue = event.target.value
    this.savePreferences()

    // Reverse-sync: highlight the matching category pill if the sample panel is visible
    this._syncPillToProfile(event.target.value)
  },

  // ═══════════════════════════════════════════════
  // WIDGET EXPAND - toggle between compact and expanded mode
  // ═══════════════════════════════════════════════

  selectWidgetIntelligence(event) {
    this._modelChoiceTouched = true
    const pill = event.currentTarget
    const level = pill.dataset.widgetLevel
    const credits = pill.dataset.widgetCredits
    const locked = pill.dataset.widgetLocked === 'true'
    const label = pill.dataset.widgetLabel

    // Show pro tooltip for locked tiers
    if (locked) {
      this._showProTooltip(pill)
    }

    // Track locked state - enforced at send time, not click time
    // This lets users browse tiers and see models even when locked
    this._selectedLevelLocked = locked
    this._selectedLevelTier = pill.dataset.widgetLockedTier || 'subscriber'

    // Update the intelligence value
    this.intelligenceValue = level
    this._trackEvent('chatbot-intelligence-change', { intelligence: level, source: 'widget', locked })

    // Update pill visual states
    this._syncWidgetPills()

    // Update the bottom indicator
    const indicator = document.getElementById('widget-level-indicator')
    if (indicator) {
      const aiPrefix = this._aiIntelligencePrefix()
      const desc = pill.dataset.widgetDesc || ''
      const proTag = locked ? ' <span class="text-amber-400 font-semibold">PRO</span>' : ''
      indicator.innerHTML = `<span data-widget-active-label>${aiPrefix}: ${label}${proTag}</span> <span data-widget-active-desc class="text-gray-300 dark:text-gray-600">- ${desc}</span>`
    }

    // Resolve one model across widget and full-page controls. A selection is
    // preserved when it belongs to this tier; switching tiers falls back to
    // that tier's server-rendered default.
    const selectedWidgetOption = this._syncModelDropdowns(level, this.modelOverrideValue)
    this._applyModelReasoningCapabilities(
      selectedWidgetOption,
      pill.dataset.widgetDefaultReasoning || selectedWidgetOption?.dataset.defaultReasoning || 'low'
    )

    // Sync with full-page slider if it exists
    const slider = document.getElementById('intelligence-range')
    if (slider) {
      const levels = this._intelligenceLevels
      const idx = levels.findIndex(l => l.id === level)
      if (idx >= 0) {
        slider.value = idx
        this._updateSliderFill(slider, idx, levels.length - 1)
        this._updateNotchHighlight('#intelligence-slider-section', idx)
        this._updateIntelligenceSubtitle(idx)
      }
    }

    this._refreshCreditDisplay()
    this.savePreferences()
  },

  // Filter the widget model dropdown to show only models for the selected intelligence level
  // NOTE: <option> elements cannot be hidden via CSS - must remove/re-insert.

  _filterWidgetModelDropdown(level, preferredModel = null) {
    const select = document.getElementById('widget-model-select')
    if (!select) return

    // Cache all widget options on first call
    if (!this._allWidgetModelOptions) {
      this._allWidgetModelOptions = Array.from(select.querySelectorAll('option'))
    }

    // Check if this tier is locked
    const activePill = document.querySelector(`#widget-intelligence-pills .widget-intel-pill[data-widget-level="${level}"]`)
    const tierLocked = activePill?.dataset.widgetLocked === 'true'

    // Clear and re-insert only matching options
    select.innerHTML = ''
    let firstVisible = null
    let defaultForTier = null
    let preferredForTier = null

    for (const opt of this._allWidgetModelOptions) {
      {
        // When browsing a locked tier, temporarily enable options so they're selectable
        // Entitlements stay server-rendered; research depth never unlocks a model.
        select.appendChild(opt)
        if (!firstVisible) firstVisible = opt
        if (opt.dataset.intelligence === level && opt.dataset.default === 'true' && !opt.disabled) defaultForTier = opt
        if (opt.value === preferredModel && (!opt.disabled || opt.dataset.modelAvailable === 'false')
          && (!preferredForTier || opt.dataset.reasoningOption === this.reasoningLevelValue)) preferredForTier = opt
      }
    }

    const toSelect = preferredForTier || defaultForTier || this._freshDefaultOption(this._allWidgetModelOptions) || firstVisible
    if (toSelect) {
      toSelect.selected = true
    }

    // Apply locked visual style to the select element
    if (tierLocked) {
      select.classList.add('ring-1', 'ring-amber-400/50', 'opacity-70')
    } else {
      select.classList.remove('ring-1', 'ring-amber-400/50', 'opacity-70')
    }

    return toSelect
  },

  // Sync widget intelligence pills to reflect the current intelligenceValue

  updateWidgetProfile(event) {
    this.profileValue = event.target.value
    this.savePreferences()

    // Sync with full-page profile select if it exists
    const mainSelect = document.getElementById('profile-select')
    if (mainSelect) {
      mainSelect.value = event.target.value
    }
  },

  // Update model from the widget model dropdown

  updateWidgetModel(event) {
    const modelId = event.target.value
    if (!modelId) return
    this._modelChoiceTouched = true

    const opt = event.target.selectedOptions[0]
    this._adoptResearchCombination(opt)
    const level = opt?.dataset.intelligence || this.intelligenceValue
    const selectedOption = this._syncModelDropdowns(level, modelId)
    this._trackEvent('chatbot-model-change', { model: modelId, source: 'widget' })

    // Also find the intelligence level this model belongs to and sync
    if (opt && opt.dataset.intelligence) {
      this.intelligenceValue = opt.dataset.intelligence
      // Sync widget pills
      this._syncWidgetPills()
    }

    this._applyModelReasoningCapabilities(selectedOption, opt?.dataset.defaultReasoning || 'low')

    // Refresh credit display for per-model costs
    this._refreshCreditDisplay()
    this.savePreferences()
  },

  // Update sources from widget checkboxes

  updateWidgetSources() {
    const sources = []
    const legEl = document.getElementById('widget-src-leg')
    const jurEl = document.getElementById('widget-src-jur')
    const parlEl = document.getElementById('widget-src-parl')

    if (legEl && legEl.checked) sources.push('legislation')
    if (jurEl && jurEl.checked) sources.push('jurisprudence')
    if (parlEl && parlEl.checked) sources.push('parliamentary')

    if (sources.length === 0) {
      this.sourceValue = 'legislation'
      if (legEl) legEl.checked = true
    } else {
      this.sourceValue = sources.join(',')
    }

    this._trackEvent('chatbot-source-change', { source: this.sourceValue })
    this.savePreferences()

    // Sync with full-page source checkboxes if they exist
    if (this.hasSourceLegislationTarget) this.sourceLegislationTarget.checked = legEl?.checked || false
    if (this.hasSourceJurisprudenceTarget && !this.sourceJurisprudenceTarget.disabled) {
      this.sourceJurisprudenceTarget.checked = jurEl?.checked || false
    }
    if (this.hasSourceParliamentaryTarget && !this.sourceParliamentaryTarget.disabled) {
      this.sourceParliamentaryTarget.checked = parlEl?.checked || false
    }
  },

  // Clear conversation history and messages (widget trash button)

  // What makes two sources the same line: the law (or ruling, or document) AND
  // the part of it that was retrieved. The server sends one source per article,
  // so a key of the law title alone kept only the first article of each law: an
  // answer citing Art. 80, 81 and 95 showed "Verberg bronnen (1)", and the
  // exports, which copy this block, lost the same articles. Empty means the
  // source has nothing to show and is skipped.

  _sourceDedupKey(source) {
    const base = String(source.law_title || source.title || source.ecli || source.numac || '').trim()
    if (!base) return ''
    const part = [source.article_title || source.article_number, source.dossier, source.document_number]
      .filter(Boolean).join('/')
    return `${base}|${part}`
  },

  // Splits a bare article designation into its number and its variant:
  // "Art.80" -> 80, "Art.VI.92" -> VI.92, "Art. 2:5" -> 2:5,
  // "Art.1714_WAALS_GEWEST" -> 1714 + "WAALS GEWEST". The old pattern wanted a
  // digit right after "Art.", so the books of the WER fell to the raw
  // fallback, and it took the storage key whole, which put
  // "Artikel 1714_WAALS_GEWEST" on the card.
  // Returns null for anything that is not an article number after all: a
  // heading row, a synthesized label ("Artikel 1, WIB 92 (inkomsten 2026)",
  // whose income year rebuilding from the number alone would drop), and the
  // Justel annex keys Art.N, Art.N1, Art.N2. Those last ones are the most
  // common keys in the corpus after the plain numbers, and the digit is not
  // the annex's own number (Art.N1 of one Flemish order is "Bijlage 2"), so
  // "Artikel N1" would both invent an article and name the wrong annex. The
  // caller prints all of these whole.

  _sourceArticleParts(articleTitle) {
    const m = String(articleTitle || '')
      .match(/^\s*(?:Art\.|Art(?:ikel|icle)?(?=[\s\d]))\s*([0-9A-Za-z][^\s_]*)(?:_(\S+))?\s*$/i)
    if (!m) return null
    const number = m[1].replace(/[.,;:]+$/, '')
    if (!number || !/\d/.test(number) || /^N/i.test(number)) return null
    return { number, variant: (m[2] || '').replace(/_+/g, ' ').trim() }
  },

  // The visible text of one source line, HTML-escaped. `t` is the label set.
  // Identifier first, then a neutral separator, then the title as stored. The
  // line used to be a sentence with one fixed preposition per language, which
  // no title survives: Justel titles open with their date ("Artikel 80 van de
  // 2 APRIL 2009. - Decreet ...") and the gender is wrong for most of the rest
  // ("van de Wetboek", "de la Code civil", "des Verfassung").

  _sourceDisplayText(source, t) {
    const esc = (value) => this._escapeHtml(String(value))
    const rawTitle = String(source.law_title || source.title || source.ecli || source.numac || "Source")
      .replace(/\s*\(NOTA\s*:[\s\S]*?\)/g, '')
      .replace(/\s*\[NOTA\s*:[\s\S]*?\]/g, '')
      .trim()
    const title = esc(rawTitle)

    // A ruling carries no title at all, so the line was the bare ECLI. The
    // court and the date come with it and are what a reader recognises, in the
    // order a Belgian citation puts them ("Cass. 14 januari 2019, ECLI:...").
    if (!source.law_title && !source.title && source.ecli) {
      const ruling = [source.court, source.date].filter(Boolean).map(esc).join(', ')
      return ruling ? `${ruling} · ${esc(source.ecli)}` : esc(source.ecli)
    }

    // Regional hits carry article_number and no article_title. Without this
    // every article of one decree printed as the same bare decree title.
    const articleTitle = source.article_title || (source.article_number ? `Art. ${source.article_number}` : null)
    if (articleTitle) {
      const parts = this._sourceArticleParts(articleTitle)
      // Registration/succession duties and parts of WIB 92 are regionalised, so a
      // tax source can be a Flemish/Walloon/Brussels variant rather than the federal
      // article. The scope MUST survive into the card, or the reader sees one
      // region's rule presented as the article. Tax sources send it display-ready
      // as jurisdiction_label; Justel rows only have the variant in their title.
      const scopeText = source.jurisdiction_label || (parts && parts.variant)
      const scope = scopeText ? ` (${esc(scopeText)})` : ""
      if (!parts) return `${esc(articleTitle)}${scope} · ${title}`
      return `${t.article} ${esc(parts.number)}${scope} · ${title}`
    }

    // Parliamentary documents of one dossier often share their title; the
    // dossier reference is what tells them apart
    const dossier = [source.dossier, source.document_number].filter(Boolean).join('/')
    return dossier ? `${esc(dossier)} · ${title}` : title
  },

  createSourcesElement(sources) {
    const div = document.createElement("div")
    div.className = "message-sources mt-2 pt-2 border-t border-gray-200 dark:border-gray-600 text-xs"

    // Translations for source labels. The interface language picks the set,
    // like it does for the answer, the meta row and every control around this
    // block. It used to be the client-side guess at the question's language,
    // whose word lists read Dutch "die", "werden" or "coördinator" as German:
    // a Dutch answer then sat above "Quellen ausblenden (3)" and "Text
    // zeigen". The four sets are the four the answer can be written in: the
    // request carries the interface language and the server clamps it to
    // these, so a Russian or Arabic set would only ever label Dutch text.
    const labels = {
      nl: { sources: "Bronnen", article: "Artikel", showMore: "Toon tekst", showLess: "Verberg", showSources: "Toon bronnen", hideSources: "Verberg bronnen" },
      fr: { sources: "Sources", article: "Article", showMore: "Voir texte", showLess: "Masquer", showSources: "Afficher les sources", hideSources: "Masquer les sources" },
      en: { sources: "Sources", article: "Article", showMore: "Show text", showLess: "Hide", showSources: "Show sources", hideSources: "Hide sources" },
      de: { sources: "Quellen", article: "Artikel", showMore: "Text zeigen", showLess: "Ausblenden", showSources: "Quellen anzeigen", hideSources: "Quellen ausblenden" }
    }
    // Final fallback based on domain (lisloi.be → fr, wetwijzer.be → nl)
    const domainLang = window.location.hostname.includes('lisloi') ? 'fr' : 'nl'
    const t = labels[this.languageValue] || labels[domainLang]

    // Deduplicate sources per law AND article (keep first occurrence, highest
    // relevance). Also filters out empty/invalid sources with no meaningful content
    const seen = new Set()
    const uniqueSources = sources.filter(source => {
      const key = this._sourceDedupKey(source)
      if (!key || seen.has(key)) return false
      seen.add(key)
      return true
    })

    const sourcesListId = `sources-list-${this.messageCount}`

    // Collapsed toggle header - NO inline onclick (CSP compliance)
    let html = `<button type="button" class="sources-toggle-btn flex items-center gap-1.5 text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-(--accent-400) transition-colors font-medium cursor-pointer"
                        data-target-list="${sourcesListId}"
                        data-show-text="${t.showSources} (${uniqueSources.length})"
                        data-hide-text="${t.hideSources} (${uniqueSources.length})">
      <svg class="sources-chevron w-3 h-3 transition-transform duration-200" style="transform: rotate(90deg)" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7"/></svg>
      <span class="sources-label">${t.hideSources} (${uniqueSources.length})</span>
    </button>`

    html += `<div id="${sourcesListId}" class="mt-1.5">`

    uniqueSources.forEach((source, index) => {
      const relevance = source.relevance ? ` (${Math.min(100, (source.relevance * 100)).toFixed(0)}%)` : ""

      // Format: "Artikel X · Law Title" or just "Law Title" if no article
      const displayText = this._sourceDisplayText(source, t)

      // Build the source entry with link and optional excerpt
      const excerptId = `excerpt-${this.messageCount}-${index}`
      // Sanitize URL (only allow http/https and relative paths)
      const safeUrl = source.url && /^(https?:\/\/|\/)/.test(source.url) ? this._escapeHtml(source.url) : null

      if (safeUrl) {
        html += `<div class="source-entry mb-1">
          <div class="text-(--accent-600) dark:text-(--accent-400) hover:underline">
            <a href="${safeUrl}" target="_blank" rel="noopener noreferrer">${index + 1}. ${displayText}${relevance}</a>`

        // Add toggle button if excerpt available - NO inline onclick (CSP compliance)
        if (source.excerpt) {
          html += ` <button type="button" class="excerpt-toggle text-gray-400 hover:text-gray-600 dark:hover:text-(--accent-400) text-[10px] ml-1"
                            data-excerpt-id="${excerptId}"
                            data-show-text="${t.showMore}"
                            data-hide-text="${t.showLess}">${t.showMore}</button>`
        }

        html += `</div>`

        // Add collapsible excerpt
        if (source.excerpt) {
          const safeExcerpt = this._escapeHtml(source.excerpt)
          html += `<div id="${excerptId}" class="hidden mt-1 ml-4 p-2 bg-gray-50 dark:bg-gray-900 rounded text-[11px] text-gray-600 dark:text-gray-400 italic border-l-2 border-(--accent-300) dark:border-(--accent-600)">${safeExcerpt}</div>`
        }

        html += `</div>`
      } else {
        html += `<div class="text-gray-600 dark:text-gray-300">${index + 1}. ${displayText}${relevance}</div>`
      }
    })

    html += `</div>`

    div.innerHTML = html

    // Attach event listeners (CSP-safe, no inline handlers)
    const toggleBtn = div.querySelector('.sources-toggle-btn')
    if (toggleBtn) {
      toggleBtn.addEventListener('click', () => {
        const listId = toggleBtn.dataset.targetList
        const list = document.getElementById(listId)
        if (!list) return
        const hidden = list.classList.toggle('hidden')
        const chevron = toggleBtn.querySelector('.sources-chevron')
        const label = toggleBtn.querySelector('.sources-label')
        if (chevron) chevron.style.transform = hidden ? '' : 'rotate(90deg)'
        if (label) label.textContent = hidden ? toggleBtn.dataset.showText : toggleBtn.dataset.hideText
      })
    }

    div.querySelectorAll('.excerpt-toggle').forEach(btn => {
      btn.addEventListener('click', () => {
        const excerptEl = document.getElementById(btn.dataset.excerptId)
        if (!excerptEl) return
        excerptEl.classList.toggle('hidden')
        btn.textContent = excerptEl.classList.contains('hidden') ? btn.dataset.showText : btn.dataset.hideText
      })
    })

    return div
  },

  // Create metadata element with feedback buttons and copy/save/export

  _syncPillToProfile(profileId) {
    const panel = document.getElementById('sample-questions-panel')
    if (!panel) return

    const sampleCat = this.constructor.PROFILE_TO_SAMPLE[profileId] || 'all'

    const isDark = document.documentElement.classList.contains('dark') ||
                   window.matchMedia('(prefers-color-scheme: dark)').matches
    // Reset all pills to inactive styling
    panel.querySelectorAll('.sample-cat-btn').forEach(b => {
      b.style.backgroundColor = 'transparent'
      b.style.color = isDark ? '#9ca3af' : '#6b7280'
      b.style.borderColor = isDark ? '#374151' : '#d1d5db'
    })

    // Activate the matching pill
    const matchingPill = panel.querySelector(`.sample-cat-btn[data-category="${sampleCat}"]`)
    if (matchingPill) {
      matchingPill.style.backgroundColor = 'var(--accent-100)'
      matchingPill.style.color = 'var(--accent-700)'
      matchingPill.style.borderColor = 'var(--accent-300)'
    }

    // Show/hide category groups
    panel.querySelectorAll('.sample-category-group').forEach(group => {
      if (sampleCat === 'all' || group.dataset.sampleCategory === sampleCat) {
        group.style.display = ''
        if (sampleCat !== 'all') {
          const body = group.querySelector('.sample-category-body')
          const chevron = group.querySelector('.sample-chevron')
          if (body) body.style.display = ''
          if (chevron) chevron.style.transform = 'rotate(0deg)'
        }
      } else {
        group.style.display = 'none'
      }
    })
  },

  // NOTE: _syncSlidersFromPreferences is defined above (single canonical version)
  // and handles: intelligence slider fill, model/profile dropdowns, widget sources,
  // reasoning controls, and credit display refresh.

  // NOTE: _restoreConversation() and _saveConversation() are now no-ops
  // defined in the server-side persistence section below.
  // No sessionStorage or localStorage is used.

  // NOTE: updateWidgetModel(), updateWidgetProfile(), and updateWidgetSources()
  // are defined earlier in this file (around L719-L786) with full implementations
  // including analytics tracking, intelligence pill sync, and credit cost refresh.
  // DO NOT redefine them here: JS object literal property overwriting means only
  // the LAST definition survives.


  // Auto-resize widget textarea

  async saveConversationToProfile(event) {
    event?.stopPropagation()
    // This is now a no-op since conversations auto-save
    this.saveChatToHistory()
  },

  // Small toast notification helper

  // Localized "AI Intelligence" prefix for level indicator labels
  _aiIntelligencePrefix() {
    const lang = this.languageValue || 'nl'
    const prefixes = { nl: 'AI-Intelligentie', fr: 'Intelligence IA', de: 'KI-Intelligenz', en: 'AI Intelligence' }
    return prefixes[lang] || prefixes.nl
  },

}

Object.defineProperties(settingsMethods, Object.getOwnPropertyDescriptors(researchDepthMethods))
