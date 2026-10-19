import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "card", "opener", "invitation", "step", "previous", "next", "body", "spotlight", "targetStatus"]

  connect() {
    this.currentStep = 0
    this.isDisconnecting = false
    this.previousBodyOverflow = null
    this.positionGeneration = 0
    this.rafIds = []
    this.disclosureRestorations = []
    this.disclosureAnimations = []
    this.storageKey = "wetwijzer:site-tour-seen"
    this.launchKey = "wetwijzer:site-tour-launch"
    this.seen = this.readSeen()
    this.openerTargets?.forEach((opener) => { opener.hidden = false })
    this.element.querySelector("[data-site-tour-dismiss]")?.removeAttribute("hidden")
    const firstHomepageVisit = this.hasInvitationTarget && !this.seen
    if (this.hasInvitationTarget) this.invitationTarget.hidden = !firstHomepageVisit
    // Consume the first-visit invitation immediately, but leave it visible
    // for this page view. A later Turbo visit must not show it again.
    if (firstHomepageVisit) this.rememberSeen()
    this.dialogTarget.dataset.siteTourEnhanced = "true"
    this._beforeCache = this.beforeCache.bind(this)
    document.addEventListener("turbo:before-cache", this._beforeCache)
    this.launchFromNavigation()
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this._beforeCache)
    this.isDisconnecting = true
    this.cancelNavigationOpen()
    if (this.dialogTarget.open) this.dialogTarget.close()
    this.restorePage()
    if (this.hasInvitationTarget) this.invitationTarget.hidden = true
    this.clearHighlight()
    this.restoreDisclosures()
    this.unbindViewportListeners()
    delete this.dialogTarget.dataset.siteTourEnhanced
  }

  open(event) {
    if (this.dialogTarget.open) return
    const homepage = this.homepageURL()
    if (!homepage) return // Keep the native fallback if its configuration is invalid.
    event?.preventDefault()
    if (!this.onHomepage(homepage)) return this.navigateToHomepage(homepage)
    this.openHere(event?.currentTarget || document.activeElement)
  }

  openHere(opener) {
    this.cancelNavigationOpen()
    this.opener = opener
    this.currentStep = 0
    this.render()
    this.markSeen()
    // Scroll while the page is still unlocked, before native modal focus and
    // the body lock. Footer launchers can start several screens below this.
    this.currentTarget()?.scrollIntoView({ block: "center", inline: "nearest", behavior: "instant" })
    this.previousBodyOverflow = document.body.style.overflow
    this.dialogTarget.showModal()
    this.bindViewportListeners()
    this.positionForTarget(false)
    document.body.style.overflow = "hidden"
    this.focusClose()
  }

  homepageURL() {
    try {
      const configured = this.element.querySelector("#site-tour-guide")?.dataset.siteTourHomepageUrl || "/"
      const url = new URL(configured, window.location.href)
      if (url.origin !== window.location.origin || url.pathname !== "/" || url.username || url.password) return null
      if ([...url.searchParams.keys()].some(key => key !== "locale")) return null
      const locales = url.searchParams.getAll("locale")
      if (locales.length > 1 || (locales.length === 1 && !["nl", "fr", "de", "en"].includes(locales[0]))) return null
      url.hash = ""
      return url
    } catch (_error) { return null }
  }

  onHomepage(homepage) {
    try {
      const current = new URL(window.location.href)
      if (current.origin !== homepage.origin || current.pathname !== homepage.pathname) return false
      if ([...current.searchParams.keys()].some(key => key !== "locale")) return false
      const locales = current.searchParams.getAll("locale")
      return locales.length === 0 || (locales.length === 1 && locales[0] === homepage.searchParams.get("locale"))
    } catch (_error) { return false }
  }

  navigateToHomepage(homepage) {
    this.markSeen()
    const token = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
    const intent = { token, destination: homepage.href, createdAt: Date.now() }
    try {
      window.sessionStorage.setItem(this.launchKey, JSON.stringify(intent))
      homepage.hash = `site-tour-launch-${token}`
    } catch (_error) {
      // A blocked session store cannot prove an opt-in after a full reload.
      // Go home to the native guide/permanent footer link, never auto-open.
      homepage.hash = "site-tour-guide"
    }
    if (window.Turbo?.visit) window.Turbo.visit(homepage.href)
    else window.location.assign(homepage.href)
  }

  launchFromNavigation() {
    // A preview is replaced by the fresh page: let its controller consume
    // the one-shot intent, never lose it to a transient cached body.
    if (document.documentElement?.hasAttribute("data-turbo-preview")) return
    const homepage = this.homepageURL()
    if (!homepage || !this.onHomepage(homepage)) return
    const fragment = window.location.hash || ""
    if (!fragment.startsWith("#site-tour-launch-")) return
    const token = fragment.slice("#site-tour-launch-".length)
    let intent
    try {
      intent = JSON.parse(window.sessionStorage.getItem(this.launchKey))
      window.sessionStorage.removeItem(this.launchKey)
    } catch (_error) { /* absent or unavailable storage is not an opt-in */ }
    // Consume the navigation marker, including invalid/stale markers. Back,
    // reload and manually shared URLs must not repeatedly open the Wizard.
    const current = new URL(window.location.href)
    current.hash = ""
    window.history.replaceState(window.history.state, "", `${homepage.pathname}${homepage.search}`)
    const age = Date.now() - intent?.createdAt
    if (!/^[a-z0-9-]{8,64}$/.test(token) || !intent || intent.token !== token ||
        intent.destination !== homepage.href || current.href !== homepage.href ||
        !Number.isFinite(intent.createdAt) || age < 0 || age > 60000) return
    // Stimulus connects during Turbo's render, before its anchor/restoration
    // scroll and turbo:load cleanup. Open after that lifecycle, not a render
    // microtask; full document loads use their native load event instead.
    this._navigationOpen = () => {
      this.cancelNavigationOpen()
      this._navigationRaf = requestAnimationFrame(() => {
        this._navigationRaf = null
        if (this.isDisconnecting || !this.element.isConnected || this.dialogTarget.open) return
        this.openHere(this.openerTargets?.find(element => element.dataset.siteTourLauncher === "footer"))
      })
    }
    document.addEventListener("turbo:load", this._navigationOpen)
    window.addEventListener("load", this._navigationOpen)
    const navigating = document.documentElement?.hasAttribute("data-turbo-visit-direction") ||
      document.documentElement?.getAttribute("aria-busy") === "true"
    if (document.readyState === "complete" && !navigating) this._navigationOpen()
  }

  cancelNavigationOpen() {
    if (this._navigationOpen) {
      document.removeEventListener("turbo:load", this._navigationOpen)
      window.removeEventListener("load", this._navigationOpen)
      this._navigationOpen = null
    }
    if (this._navigationRaf != null) cancelAnimationFrame(this._navigationRaf)
    this._navigationRaf = null
  }

  close() {
    if (this.dialogTarget.open) {
      this.dialogTarget.close()
      // Native `close` is queued. Restore scrolling/focus synchronously so a
      // rapid reopen cannot inherit the previous modal's locked page state.
      this.closed()
    }
  }

  cancel(event) {
    event.preventDefault()
    this.close()
  }

  closed() {
    // A queued close event can arrive after the visitor reopened the dialog.
    if (this.dialogTarget.open) return
    this.restorePage()
    this.clearHighlight()
    this.restoreDisclosures()
    this.unbindViewportListeners()
    const fallbackOpener = this.openerTargets?.find((element) => this.visibleElement(element))
    if (this.opener && !this.isDisconnecting && this.element.isConnected) {
      const focusTarget = this.visibleElement(this.opener) ? this.opener : fallbackOpener
      focusTarget?.focus({ preventScroll: true })
    }
    this.opener = null
  }

  next() {
    if (this.currentStep === this.stepTargets.length - 1) return this.close()
    this.currentStep += 1
    this.render()
  }

  previous() {
    if (this.currentStep === 0) return
    this.currentStep -= 1
    this.render()
  }

  go(event) {
    const index = Number(event.params.index)
    if (!Number.isInteger(index) || index < 0 || index >= this.stepTargets.length) return
    this.currentStep = index
    this.render()
  }

  keydown(event) {
    // Native modal inertness does not stop document shortcuts from clicking
    // underlying controls programmatically. Keep every wizard key local,
    // without preventing native button activation or Escape cancellation.
    event.stopPropagation()
    if (event.key !== "Tab") return
    const focusable = this.focusableElements()
    if (!focusable.length) return
    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }

  beforeCache() {
    this.cancelNavigationOpen()
    if (this.dialogTarget.open) this.dialogTarget.close()
    this.restorePage()
    if (this.hasInvitationTarget) this.invitationTarget.hidden = true
    this.clearHighlight()
    this.restoreDisclosures()
    this.unbindViewportListeners()
  }

  render() {
    // Each step reveals only its own controls. Keep already-open sections and
    // user-selected options intact; temporary reveals are not preferences.
    this.restoreDisclosures()
    this.stepTargets.forEach((step, index) => { step.hidden = index !== this.currentStep })
    this.previousTarget.disabled = this.currentStep === 0
    this.nextTarget.textContent = this.currentStep === this.stepTargets.length - 1
      ? this.nextTarget.dataset.siteTourFinishLabel
      : this.nextTarget.dataset.siteTourNextLabel
    this.dialogTarget.querySelectorAll("[data-site-tour-index-param]").forEach((button, index) => {
      if (index === this.currentStep) button.setAttribute("aria-current", "step")
      else button.removeAttribute("aria-current")
      button.classList.toggle("bg-(--accent-600-solid)", index === this.currentStep)
      button.classList.toggle("bg-gray-300", index !== this.currentStep)
      button.classList.toggle("dark:bg-gray-600", index !== this.currentStep)
      button.classList.toggle("text-white", index === this.currentStep)
      button.classList.toggle("text-gray-900", index !== this.currentStep)
    })
    this.bodyTarget.scrollTop = 0
    if (this.hasCardTarget) this.cardTarget.scrollTop = 0
    this.targetStatusTargets?.forEach((status, index) => { status.hidden = index !== this.currentStep })
    this.highlightTarget()
  }

  focusClose() {
    this.dialogTarget.querySelector("[data-action~='site-tour#close']")?.focus({ preventScroll: true })
  }

  focusableElements() {
    return Array.from(this.dialogTarget.querySelectorAll("button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])"))
      .filter(element => !element.hidden && element.offsetParent !== null)
  }

  restorePage() {
    if (this.previousBodyOverflow !== null) {
      document.body.style.overflow = this.previousBodyOverflow
      this.previousBodyOverflow = null
    }
  }

  readSeen() {
    try { if (window.__wetwijzerTourSeen === true) return true } catch (_error) { /* blocked globals */ }
    try { if (window.localStorage.getItem(this.storageKey) === "1") return true } catch (_error) { /* blocked storage */ }
    try { if (window.sessionStorage.getItem(this.storageKey) === "1") return true } catch (_error) { /* blocked storage */ }
    return this.sessionSeen === true
  }

  markSeen() {
    this.seen = true
    if (this.hasInvitationTarget) this.invitationTarget.hidden = true
    this.rememberSeen()
  }

  dismissInvitation() {
    if (this.hasInvitationTarget) this.invitationTarget.hidden = true
    this.rememberSeen()
  }

  rememberSeen() {
    try {
      window.localStorage.setItem(this.storageKey, "1")
    } catch (_error) {
      try { window.sessionStorage.setItem(this.storageKey, "1") } catch (_sessionError) {
        this.sessionSeen = true
        try { window.__wetwijzerTourSeen = true } catch (_memoryError) { /* blocked globals */ }
      }
    }
  }

  currentTarget() {
    const selector = this.stepTargets[this.currentStep]?.dataset.siteTourSelector
    if (!selector) return null
    try {
      return Array.from(document.querySelectorAll(selector)).find((element) => this.visibleElement(element)) || null
    } catch (_error) { return null }
  }

  visibleElement(element) {
    if (!element?.isConnected || element.hidden || element.closest?.('[hidden], [aria-hidden="true"]')) return false
    if (!element.getClientRects?.().length) return false
    if (element.checkVisibility && !element.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) return false
    const visibility = window.getComputedStyle(element).visibility
    return visibility !== "hidden" && visibility !== "collapse"
  }

  highlightTarget(preparationAttempt = 0) {
    this.clearHighlight()
    const revealed = this.prepareStepTarget()
    const target = this.currentTarget()
    if (!target) {
      // Mobile navigation's existing open() applies its visible state on the
      // next frame. Prepare nested options after that, rather than measuring
      // an invisible panel or faking the controller's state.
      if (revealed && preparationAttempt < 3) {
        const generation = this.positionGeneration
        this.rafIds.push(requestAnimationFrame(() => {
          if (generation === this.positionGeneration && this.dialogTarget.open) this.highlightTarget(preparationAttempt + 1)
        }))
      }
      if (this.hasTargetStatusTarget) this.targetStatusTargets[this.currentStep].hidden = false
      return
    }
    this.dialogTarget.classList.add("site-tour-has-target")
    target.classList.add("site-tour-highlight")
    this.highlightedTarget = target
    if (this.hasTargetStatusTarget) this.targetStatusTargets[this.currentStep].hidden = true
    this.positionForTarget()
  }

  prepareStepTarget() {
    const selector = this.stepTargets[this.currentStep]?.dataset.siteTourSelector
    if (!selector) return false
    let candidates
    try { candidates = Array.from(document.querySelectorAll(selector)) } catch (_error) { return false }
    const before = this.disclosureRestorations.length
    for (const target of candidates) {
      const ancestors = []
      let ancestor = target
      while (ancestor && ancestor !== this.element) {
        ancestors.push(ancestor)
        ancestor = ancestor.parentElement
      }
      // Reveal outer navigation/details first, then the actual options panel.
      ancestors.reverse().forEach(element => this.revealDisclosure(element))
      this.revealSourceTab(target)
      if (this.visibleElement(target)) break
    }
    return this.disclosureRestorations.length > before
  }

  controllerFor(element, identifier) {
    const owner = element.closest?.(`[data-controller~='${identifier}']`)
    return owner && this.application?.getControllerForElementAndIdentifier(owner, identifier)
  }

  revealSourceTab(target) {
    if (!target.matches?.("[data-tabs-target~='tab'][role='tab']")) return
    const controller = this.controllerFor(target, "tabs")
    if (!controller) return
    const targetIndex = controller.tabTargets.indexOf(target)
    const originalIndex = controller.tabTargets.findIndex(tab => tab.getAttribute("aria-selected") === "true")
    if (targetIndex < 0 || originalIndex < 0 || targetIndex === originalIndex) return
    const originalTab = controller.tabTargets[originalIndex]
    this.rememberDisclosure(target, () => () => {
      // Keep any later selection intact; only undo this step's temporary tab.
      const restoreIndex = controller.tabTargets.indexOf(originalTab)
      if (restoreIndex >= 0 && target.getAttribute("aria-selected") === "true") controller.showPanel(restoreIndex)
    })
    // Use the existing presentation API, not a click or a source preference.
    controller.showPanel(targetIndex)
  }

  revealDisclosure(element) {
    if (element.matches?.("details:not([open])")) {
      this.rememberDisclosure(element, () => () => { if (element.open) element.open = false })
      element.open = true
      this.animateDisclosure(element)
      return
    }
    if (element.matches?.("[data-controller~='collapse'].is-collapsed")) {
      const controller = this.controllerFor(element, "collapse")
      if (!controller) return
      const original = controller.expandedValue
      this.rememberDisclosure(element, () => () => {
        if (controller.expandedValue === true) {
          controller.expandedValue = original
          controller.syncNow()
        }
      })
      controller.expandedValue = true
      controller.syncNow()
      const content = element.querySelector("[data-collapse-target='content']")
      if (content) this.animateDisclosure(content)
      return
    }
    const panels = [
      ["[data-mobile-menu-target='panel']", "mobile-menu", "open", "close"],
      ["[data-hero-chatbot-target='settingsPanel']", "hero-chatbot", "toggleSettings", "toggleSettings"],
      ["[data-filters-toggle-target='panel']", "filters-toggle", "toggle", "toggle"],
      ["[data-theme-selector-target='panel']", "theme-selector", "open", "close"]
    ]
    for (const [selector, identifier, open, close] of panels) {
      if (!element.matches?.(selector) || !element.classList.contains("hidden")) continue
      const controller = this.controllerFor(element, identifier)
      if (!controller) return
      // A hidden desktop picker must not be opened on mobile. Its mobile
      // counterpart can first reveal the hamburger panel above.
      const button = identifier === "mobile-menu"
        ? controller.buttonTarget
        : identifier === "theme-selector"
          ? controller.element.querySelector("[data-action~='click->theme-selector#toggle']")
          : null
      if (button && !this.visibleElement(button)) return
      this.rememberDisclosure(element, () => () => {
        if (element.classList.contains("hidden")) return
        if (identifier === "mobile-menu") {
          // close() has a delayed hide that can race a rapid wizard reopen.
          // Restore only disclosure DOM, not navigation or focus preferences.
          element.classList.add("hidden", "opacity-0", "-translate-y-2")
          element.classList.remove("opacity-100", "translate-y-0")
          controller.buttonTarget.setAttribute("aria-expanded", "false")
          controller.openIconTarget?.classList.remove("hidden")
          controller.closeIconTarget?.classList.add("hidden")
        } else controller[close]()
      })
      controller[open]()
      this.animateDisclosure(element)
      return
    }
  }

  reducedMotion() {
    return window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true
  }

  animateDisclosure(element) {
    if (this.reducedMotion() || typeof element.animate !== "function") return
    const animation = element.animate([
      { maxHeight: "0px", overflow: "hidden" },
      { maxHeight: `${element.scrollHeight}px`, overflow: "hidden" }
    ], { duration: 180, easing: "ease-out" })
    this.disclosureAnimations.push(animation)
    const step = this.currentStep
    animation.finished.then(() => {
      // Nested options may still be hidden while their parent slides open.
      // The short frame retries are not a substitute for animation readiness,
      // especially in a throttled/background tab. Resume only this live reveal.
      if (!this.disclosureAnimations.includes(animation)) return
      if (this.currentStep === step && this.dialogTarget.open && !this.isDisconnecting) {
        if (this.currentTarget()) this.positionForTarget()
        else this.highlightTarget()
      }
    }).catch(() => {}) // cancellation on close/cache is expected
  }

  rememberDisclosure(element, buildRestore) {
    if (!this.disclosureRestorations.some(entry => entry.element === element)) {
      this.disclosureRestorations.push({ element, restore: buildRestore() })
    }
  }

  restoreDisclosures() {
    this.disclosureAnimations?.forEach(animation => animation.cancel())
    this.disclosureAnimations = []
    this.disclosureRestorations?.reverse().forEach(entry => {
      if (entry.element.isConnected) entry.restore()
    })
    this.disclosureRestorations = []
  }

  positionForTarget(scrollTarget = true) {
    const target = this.currentTarget()
    if (!target || !this.dialogTarget.open || !this.hasCardTarget) return
    if (this._layoutObserver && this._observedTarget !== target) {
      if (this._observedTarget) this._layoutObserver.unobserve(this._observedTarget)
      this._observedTarget = target
      this._layoutObserver.observe(target)
    }
    const generation = ++this.positionGeneration
    this.rafIds.forEach((id) => cancelAnimationFrame(id))
    this.rafIds = []
    if (scrollTarget) target.scrollIntoView({ block: "center", inline: "nearest", behavior: this.reducedMotion() ? "instant" : "smooth" })
    const move = () => {
      this.rafIds.push(requestAnimationFrame(() => {
        if (generation !== this.positionGeneration || !this.dialogTarget.open || this.currentTarget() !== target) return
        const rect = target.getBoundingClientRect()
        const dialogWidth = this.cardTarget.offsetWidth
        // scrollHeight retains the natural content height after a previous
        // placement constrained this card. This avoids resize-observer loops.
        const dialogHeight = Math.min(this.cardTarget.scrollHeight || this.cardTarget.offsetHeight, window.innerHeight - 16)
        const placement = this.placementForTarget(rect, dialogWidth, dialogHeight)
        this.cardTarget.style.maxHeight = `${placement.height}px`
        this.cardTarget.style.top = `${placement.top}px`
        this.cardTarget.style.left = `${placement.left}px`
        this.cardTarget.style.transform = "none"
        if (this.hasSpotlightTarget) {
          this.spotlightTarget.style.border = "2px solid var(--accent-500, #2563eb)"
          this.spotlightTarget.style.borderRadius = "0.75rem"
          this.spotlightTarget.style.boxShadow = "0 0 0 9999px rgb(0 0 0 / 0.56), 0 0 0 0.4rem color-mix(in srgb, var(--accent-500, #2563eb) 35%, transparent)"
          this.spotlightTarget.style.background = "transparent"
          this.spotlightTarget.style.top = `${rect.top - 8}px`
          this.spotlightTarget.style.left = `${rect.left - 8}px`
          this.spotlightTarget.style.width = `${rect.width + 16}px`
          this.spotlightTarget.style.height = `${rect.height + 16}px`
          this.spotlightTarget.hidden = false
        }
      }))
    }
    move()
  }

  placementForTarget(rect, width, height) {
    const margin = 8
    const gap = 16 // Includes the spotlight's eight-pixel halo.
    const viewportWidth = window.innerWidth
    const viewportHeight = window.innerHeight
    const right = rect.left + rect.width
    const bottom = rect.top + rect.height
    const clamp = (value, max) => Math.max(margin, Math.min(value, Math.max(margin, max)))
    const left = clamp(rect.left, viewportWidth - width - margin)
    const top = clamp(rect.top, viewportHeight - height - margin)
    const candidates = [
      { left, top: bottom + gap },
      { left, top: rect.top - height - gap },
      { left: right + gap, top },
      { left: rect.left - width - gap, top }
    ]
    const fits = candidate => candidate.left >= margin && candidate.top >= margin &&
      candidate.left + width <= viewportWidth - margin && candidate.top + height <= viewportHeight - margin
    const fullSize = candidates.find(fits)
    if (fullSize) return { ...fullSize, height }

    // Wide targets have no readable side column. Give the explanation its own
    // bounded region above/below, rather than laying it across the controls.
    const below = viewportHeight - margin - bottom - gap
    const above = rect.top - gap - margin
    const available = Math.max(below, above)
    if (available >= 128) {
      const boundedHeight = Math.min(height, available)
      return { left, top: clamp(below >= above ? bottom + gap : rect.top - gap - boundedHeight, viewportHeight - boundedHeight - margin), height: boundedHeight }
    }
    // A very short screen/very tall target cannot show both in full. Keep a
    // scrollable lower sheet with its sticky close row, leaving context above.
    const sheetHeight = Math.min(height, Math.max(128, Math.floor((viewportHeight - 2 * margin) * 0.55)))
    return { left, top: viewportHeight - margin - sheetHeight, height: sheetHeight }
  }

  clearHighlight() {
    this.positionGeneration += 1
    this.rafIds?.forEach((id) => cancelAnimationFrame(id))
    this.rafIds = []
    this.highlightedTarget?.classList.remove("site-tour-highlight")
    this.highlightedTarget = null
    this.dialogTarget?.classList?.remove("site-tour-has-target")
    if (this.hasSpotlightTarget) this.spotlightTarget.hidden = true
    if (this.hasCardTarget && this.cardTarget.style) {
      this.cardTarget.style.top = ""
      this.cardTarget.style.left = ""
      this.cardTarget.style.transform = ""
      this.cardTarget.style.maxHeight = ""
    }
  }

  bindViewportListeners() {
    this._reposition = () => this.positionForTarget(false)
    this._resize = () => {
      if (!this.dialogTarget.open) return
      // Responsive navigation has separate desktop/mobile controls. If the
      // old target disappears at a breakpoint, reveal its visible counterpart.
      if (this.currentTarget()) this.positionForTarget(false)
      else this.highlightTarget()
    }
    window.addEventListener("resize", this._resize)
    window.addEventListener("scroll", this._reposition, true)
    // Homepage samples and disclosure contents can move a target without any
    // viewport scroll/resize. Track layout only; never scroll from an observer.
    if (typeof ResizeObserver !== "undefined") {
      this._layoutObserver = new ResizeObserver(this._reposition)
      this._layoutObserver.observe(document.body)
      if (this.hasCardTarget) this._layoutObserver.observe(this.cardTarget)
    }
  }

  unbindViewportListeners() {
    this._layoutObserver?.disconnect()
    this._layoutObserver = null
    this._observedTarget = null
    if (!this._reposition) return
    window.removeEventListener("resize", this._resize)
    window.removeEventListener("scroll", this._reposition, true)
    this._reposition = null
    this._resize = null
  }
}
