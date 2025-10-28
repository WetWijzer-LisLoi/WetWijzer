import { Controller } from "@hotwired/stimulus"

/**
 * TOC Tracker Controller
 * @class TOCController
 * @extends Controller
 * 
 * Handles the table of contents (TOC) highlighting and scrolling behavior.
 * Tracks the currently active section in the viewport and updates the TOC accordingly.
 * Uses IntersectionObserver for efficient scroll tracking and includes
 * performance optimizations like throttling and debouncing.
 * 
 * @example
 * <!-- Basic usage in HTML -->
 * <div data-controller="toc-tracker">
 *   <nav>
 *     <a href="#section1" data-toc-tracker-target="link">Section 1</a>
 *     <a href="#section2" data-toc-tracker-target="link">Section 2</a>
 *   </nav>
 *   <div>
 *     <h2 id="section1">Section 1</h2>
 *     <h2 id="section2">Section 2</h2>
 *   </div>
 * </div>
 * 
 * @example
 * // Configuration with custom values
 * <div 
 *   data-controller="toc-tracker"
 *   data-toc-tracker-root-margin-value="0px 0px -70% 0px"
 *   data-toc-tracker-threshold-value="0.2"
 *   data-toc-tracker-debounce-delay-value="100"
 * ></div>
 */
export default class extends Controller {
  /**
   * Stimulus targets for this controller
   * @static
   * @type {string[]}
   * @default ['link']
   */
  static targets = ["link", "follow"]
  
  /**
   * Stimulus link targets for this controller
   * @static
   * @type {Object}
   * @property {string} link - Target for the link elements
   */
  static linkTargets = ["link"]
  
  /**
   * Configuration values for the TOC controller
   * @static
   * @type {Object}
   * @property {Object} rootMargin - Root margin for the IntersectionObserver
   * @property {string} rootMargin.type - Expected type (String)
   * @property {string} rootMargin.default - Default root margin ('0px 0px -80%')
   * @property {Object} threshold - Intersection ratio threshold for activation
   * @property {number} threshold.type - Expected type (Number)
   * @property {number} threshold.default - Default threshold (0.1)
   * @property {Object} debounceDelay - Delay in ms for debouncing scroll/resize events
   * @property {number} debounceDelay.type - Expected type (Number)
   * @property {number} debounceDelay.default - Default delay (50ms)
   */
  static values = {
    enabled: { type: Boolean, default: true },
    rootMargin: { type: String, default: '0px 0px -80%' },
    threshold: { type: Number, default: 0.1 },
    debounceDelay: { type: Number, default: 50 },
    hashPriorityMs: { type: Number, default: 1500 }
  }

  /**
   * Disable TOC links that don't resolve to a section element on the page.
   * Re-enable those that do resolve. Keeps UX clear by avoiding dead anchors.
   */
  disableBrokenTocLinks() {
    try {
      // If we haven't resolved any sections yet (e.g., before Turbo frame loaded),
      // do not disable anything to avoid flicker and false negatives on initial paint.
      if (!this.sections || this.sections.length === 0) return

      const validLinks = new Set((this.sections || []).map(s => s.link))
      const links = this.linkTargets || []
      links.forEach(link => {
        if (validLinks.has(link)) {
          // Ensure enabled
          link.removeAttribute('aria-disabled')
          if (!link.getAttribute('href')) {
            const target = link.getAttribute('data-target')
            if (target) link.setAttribute('href', `#${target}`)
          }
          link.classList.remove('opacity-60', 'pointer-events-none', 'cursor-default')
          delete link.dataset.disabled
        } else {
          // Disable hyperlinks that would lead to nowhere
          link.setAttribute('aria-disabled', 'true')
          link.dataset.disabled = 'true'
          link.removeAttribute('href')
          link.classList.add('opacity-60', 'pointer-events-none', 'cursor-default')
        }
      })
    } catch (_) { /* noop */ }
  }

  /**
   * Storage key for persisting follow/track behavior
   */
  getStorageKey() {
    return 'ww.toc.follow.enabled'
  }

  /**
   * Diagnostics: localStorage key to toggle debug logging/collection
   */
  getDebugKey() {
    return 'ww.toc.debug'
  }

  /**
   * Whether diagnostics/debug is enabled via localStorage
   * Enable with: localStorage.setItem('ww.toc.debug','1')
   * Disable with: localStorage.removeItem('ww.toc.debug')
   */
  isDebugEnabled() {
    try {
      const v = window.localStorage.getItem(this.getDebugKey())
      if (v === null) return false
      return v === '1' || v === 'true'
    } catch (_) {
      return false
    }
  }

  /**
   * Debug logger with consistent prefix
   */
  debugLog() {
    if (!this.isDebugEnabled()) return
    try { console.log('[TOC DEBUG]', ...arguments) } catch (_) { /* noop */ }
  }

  /**
   * Expose a global helper for quick inspection: window.wwTocDiag()
   */
  exposeDiagnostics() {
    if (!this.isDebugEnabled()) return
    try {
      const self = this
      window.wwTocDiag = function () {
        const diag = self._tocDiag || null
        if (!diag) {
          console.log('[TOC DEBUG] No diagnostics collected yet')
          return null
        }
        console.log('[TOC DEBUG] Diagnostics:', diag)
        return diag
      }
    } catch (_) { /* noop */ }
  }

  /**
   * Load persisted enabled state from localStorage
   * @return {boolean|null} true/false if present, otherwise null
   */
  loadEnabledFromStorage() {
    try {
      const v = window.localStorage.getItem(this.getStorageKey())
      if (v === null) return null
      return v === '1' || v === 'true'
    } catch (_) {
      return null
    }
  }

  /**
   * Save enabled state to localStorage
   * @param {boolean} flag
   */
  saveEnabledToStorage(flag) {
    try {
      window.localStorage.setItem(this.getStorageKey(), flag ? '1' : '0')
    } catch (_) { /* noop */ }
  }

  /**
   * Determine the effective header offset using CSS scroll-margin-top when available.
   * Falls back to 100px if not determinable.
   */
  getHeaderOffset() {
    try {
      const sample = this.sections && this.sections[0] && this.sections[0].element
      if (sample) {
        const smt = parseFloat(window.getComputedStyle(sample).scrollMarginTop)
        if (!Number.isNaN(smt) && smt > 0) return smt
      }
    } catch (_) { /* noop */ }
    return 100
  }

  /**
   * Called when the controller is connected to the DOM
   * Initializes the TOC tracker by setting up properties and starting observation
   * @return {void}
   * @example
   * // The controller will be automatically connected when the element
   * // with data-controller="toc-tracker" is added to the DOM
   */
  connect() {
    /** @type {IntersectionObserver|null} Observer for section visibility */
    this.observer = null
    
    /** @type {HTMLElement|null} Currently active TOC link */
    this.currentActiveLink = null
    
    /** @type {Array<Object>} Array of section objects being tracked */
    this.sections = []
    
    /** @type {number|null} Timeout ID for scroll events */
    this.scrollTimeout = null
    
    /** @type {number|null} Timeout ID for resize events */
    this.resizeTimeout = null
    
    /** @type {number} Last known scroll position */
    this.lastScrollTop = window.pageYOffset
    
    /** @type {number|null} RequestAnimationFrame ID */
    this.rafId = null
    
    /** @type {boolean} Whether we've initialized */
    this.initialized = false
    
    /** @type {string|null} Section id prioritized due to a recent hash navigation */
    this.hashPriorityId = null
    
    /** @type {number} Epoch ms until which hash priority should be respected */
    this.hashPriorityUntil = 0

    // Apply persisted enabled/disabled state before initialization
    try {
      const persisted = this.loadEnabledFromStorage()
      if (persisted !== null) {
        this.enabledValue = persisted
      }
    } catch (_) { /* noop */ }

    // Initialize after a short delay to ensure DOM is ready
    if (document.readyState === 'complete' || document.readyState === 'interactive') {
      setTimeout(() => this.initialize(), 100)
    } else {
      document.addEventListener('DOMContentLoaded', () => {
        setTimeout(() => this.initialize(), 100)
      })
    }

    // Ensure checkbox reflects current state (if present)
    try { this.syncFollowCheckbox() } catch (_) { /* noop */ }
    setTimeout(() => this.syncFollowCheckbox(), 150)

    // Reinitialize when Turbo frames (articles) load to pick up dynamic content
    try {
      this.handleTurboFrameLoad = (e) => {
        try {
          const target = e && e.target
          if (!target) return
          // Reinitialize when the law articles frame loads or when content within article area updates
          if (target.id === 'law_articles' || (target.closest && target.closest('.article-content'))) {
            this.refreshAfterFrameLoad()
          }
        } catch (_) { /* noop */ }
      }
      document.addEventListener('turbo:frame-load', this.handleTurboFrameLoad)
    } catch (_) { /* noop */ }
  }

  /**
   * Called when the controller is disconnected from the DOM
   * Cleans up event listeners and observers to prevent memory leaks
   * @return {void}
   * @example
   * // The controller will be automatically disconnected when the element
   * // with data-controller="toc-tracker" is removed from the DOM
   */
  disconnect() {
    this.cleanup()
    try { document.removeEventListener('turbo:frame-load', this.handleTurboFrameLoad) } catch (_) { /* noop */ }
  }

  // Private methods

  initialize() {
    // Respect enabled flag; do nothing if disabled
    if (!this.enabledValue) return
    if (this.initialized) return
    
    try {
      this.initializeObserver()
      this.initializeSections()
      this.setupEventListeners()
      // If a hash is present on load (deep link), activate the corresponding TOC link early
      this.activateByHash(window.location.hash)
      this.setInitialActiveSection()
      this.observeSections()
      this.initialized = true
    } catch (error) {
      console.error('TOC Tracker initialization error:', error)
    }
  }

  initializeObserver() {
    if (typeof IntersectionObserver === 'undefined') {
      console.warn('IntersectionObserver is not supported in this browser')
      return
    }

    this.observer = new IntersectionObserver(
      this.handleIntersection.bind(this),
      {
        root: null,
        rootMargin: this.rootMarginValue,
        threshold: Array.from(
          { length: 10 },
          (_, i) => i * this.thresholdValue
        )
      }
    )
  }

  initializeSections() {
    // Build sections strictly from TOC links to minimize tracked elements
    const tocLinks = this.linkTargets || []
    const sections = []
    const seen = new Set()
    // Collect unresolved entries for a second pass aliasing strategy
    const pendingUnresolved = []
    // Prepare diagnostics; will be rebuilt at the end for accuracy
    const diag = this.isDebugEnabled() ? { totalLinks: tocLinks.length, resolved: [], unresolved: [] } : null

    for (let i = 0; i < tocLinks.length; i++) {
      const link = tocLinks[i]
      try {
        const raw = link.getAttribute('data-target') || (link.getAttribute('href') || '').replace(/^.*#/, '')
        if (!raw) {
          if (diag) diag.unresolved.push({ reason: 'no-target', href: link.getAttribute('href') || null, dataTarget: link.getAttribute('data-target') || null, text: (link.textContent || '').trim() })
          continue
        }

        // Preserve real section ids (which may start with 'section-'); also support legacy fallback
        const candidates = [raw]
        if (raw.startsWith('section-')) {
          candidates.push(raw.replace(/^section-/, ''))
        } else {
          candidates.push(`section-${raw}`)
        }

        let el = null
        for (const c of candidates) {
          el = document.getElementById(c)
          // Fallback: for section heading ids without suffix, try matching suffixed variants (e.g., "section-...-2")
          if (!el && /^section-/.test(c)) {
            const base = c.replace(/-\d+$/, '')
            el = document.getElementById(base) || document.querySelector(`h2[id^="${base}-"]`)
          }
          if (el) {
            const resolvedId = el.id
            if (!seen.has(resolvedId)) {
              seen.add(resolvedId)
              sections.push({ id: resolvedId, element: el, link, isIntersecting: false, intersectionRatio: 0 })
              if (diag) diag.resolved.push({ targetRaw: raw, resolvedId, href: link.getAttribute('href') || null, dataTarget: link.getAttribute('data-target') || null, text: (link.textContent || '').trim() })
            }
            break
          }
        }
        if (!el) {
          // Track for second-pass alias resolution
          pendingUnresolved.push({ index: i, link, raw, candidates })
          if (diag) diag.unresolved.push({ targetRaw: raw, candidates, href: link.getAttribute('href') || null, dataTarget: link.getAttribute('data-target') || null, text: (link.textContent || '').trim() })
        }
      } catch (_) { /* noop */ }
    }

    // Second pass: create alias anchors for unresolved section targets by pointing
    // them to the next resolved DOM element (closest following section/article)
    if (pendingUnresolved.length > 0) {
      try {
        // Map resolved links to their section entries for quick lookup
        const linkToSection = new Map(sections.map(s => [s.link, s]))

        for (const pending of pendingUnresolved) {
          const { index, link, raw } = pending
          if (!raw || !/^section-/.test(raw)) continue // only alias section-* ids

          // Find the next resolved link after this one
          let targetSection = null
          for (let j = index + 1; j < tocLinks.length; j++) {
            const nextLink = tocLinks[j]
            const sec = linkToSection.get(nextLink)
            if (sec && sec.element) {
              targetSection = sec
              break
            }
          }

          if (!targetSection || !targetSection.element || document.getElementById(raw)) {
            continue
          }

          // Create a zero-height alias anchor before the target element
          const alias = document.createElement('span')
          alias.id = raw
          alias.className = 'block h-0 overflow-hidden scroll-mt-24 !mt-0'
          const parent = targetSection.element.parentNode
          if (parent && parent.insertBefore) {
            parent.insertBefore(alias, targetSection.element)

            // Track and observe the alias as a section corresponding to the unresolved link
            sections.push({ id: alias.id, element: alias, link, isIntersecting: false, intersectionRatio: 0, aliasOf: targetSection.id })
            seen.add(alias.id)
            try { this.observer?.observe(alias) } catch (_) { /* noop */ }

            if (diag) {
              diag.resolved.push({ targetRaw: raw, resolvedId: alias.id, aliasedTo: targetSection.id, href: link.getAttribute('href') || null, dataTarget: link.getAttribute('data-target') || null, text: (link.textContent || '').trim() })
            }
            // Update map so subsequent unresolved items can chain to earlier aliases if needed
            linkToSection.set(link, { id: alias.id, element: alias, link })
          }
        }
      } catch (_) { /* noop */ }
    }

    this.sections = sections

    // Observe only the sections we actually track
    this.sections.forEach(section => {
      this.observer?.observe(section.element)
    })

    // Precompute section top offsets for fast lookup
    this.computeSectionTops()

    // Disable TOC links that don't map to any section
    this.disableBrokenTocLinks()

    // Capture and expose diagnostics (rebuild lists so counts reflect aliasing)
    if (diag) {
      try {
        const linkToSection = new Map(this.sections.map(s => [s.link, s]))
        const rebuilt = { totalLinks: tocLinks.length, resolved: [], unresolved: [] }
        for (const link of tocLinks) {
          const raw = link.getAttribute('data-target') || (link.getAttribute('href') || '').replace(/^.*#/, '')
          if (!raw) {
            rebuilt.unresolved.push({ reason: 'no-target', href: link.getAttribute('href') || null, dataTarget: link.getAttribute('data-target') || null, text: (link.textContent || '').trim() })
            continue
          }
          const s = linkToSection.get(link)
          if (s) {
            rebuilt.resolved.push({ targetRaw: raw, resolvedId: s.id, href: link.getAttribute('href') || null, dataTarget: link.getAttribute('data-target') || null, text: (link.textContent || '').trim() })
          } else {
            rebuilt.unresolved.push({ targetRaw: raw, href: link.getAttribute('href') || null, dataTarget: link.getAttribute('data-target') || null, text: (link.textContent || '').trim() })
          }
        }
        rebuilt.resolvedCount = rebuilt.resolved.length
        rebuilt.unresolvedCount = rebuilt.unresolved.length
        this._tocDiag = rebuilt
        this.debugLog(`Resolved sections: ${rebuilt.resolvedCount} / ${rebuilt.totalLinks}; Unresolved: ${rebuilt.unresolvedCount}`)
        this.exposeDiagnostics()
      } catch (_) {
        // Fallback to original diag counts
        diag.resolvedCount = diag.resolved.length
        diag.unresolvedCount = diag.unresolved.length
        this._tocDiag = diag
        this.debugLog(`Resolved sections: ${diag.resolvedCount} / ${diag.totalLinks}; Unresolved: ${diag.unresolvedCount}`)
        this.exposeDiagnostics()
      }
    }
  }

  findLinkForSection(sectionId) {
    if (!sectionId) return null
    
    // Treat only 'section-art-*' as legacy aliases for article ids
    if (sectionId.startsWith('section-')) {
      const m = sectionId.match(/^section-(art-.+)$/)
      if (m) {
        return this.findLinkForSection(m[1]) || null
      }
      // Otherwise it's a real section heading (e.g., 'section-afdeling-...'); do not strip prefix
    }
    
    // Get all potential TOC links
    const tocContainer = this.element.closest('.toc-navigation')
    const links = tocContainer ? 
      Array.from(tocContainer.querySelectorAll('a[href]')) : 
      Array.from(document.querySelectorAll('a[href]'))
    
    // Try exact match with href
    let link = links.find(link => {
      const href = link.getAttribute('href')
      return href && (href === `#${sectionId}` || href.endsWith(`#${sectionId}`))
    })
    
    if (link) return link
    
    // Try data-target attribute
    link = links.find(link => {
      const target = link.getAttribute('data-target')
      return target && (target === sectionId || target.endsWith(`#${sectionId}`))
    })
    
    if (link) return link
    
    // Try case-insensitive match
    const lowerId = sectionId.toLowerCase()
    link = links.find(link => {
      const href = link.getAttribute('href')?.toLowerCase()
      const target = link.getAttribute('data-target')?.toLowerCase()
      return (href && (href === `#${lowerId}` || href.endsWith(`#${lowerId}`))) ||
             (target && (target === lowerId || target.endsWith(`#${lowerId}`)))
    })
    
    // If still no match, try to find a link that contains the section ID
    if (!link) {
      link = links.find(link => {
        const href = link.getAttribute('href')?.toLowerCase()
        const target = link.getAttribute('data-target')?.toLowerCase()
        return (href && href.includes(lowerId)) || (target && target.includes(lowerId))
      })
    }
    
    return link || null
  }
  
  /**
   * Create a link for a section if one doesn't exist
   * @param {HTMLElement} section - The section element
   * @return {HTMLElement|null} The created link or null
   */
  createLinkForSection(section) {
    if (!section.id) return null
    
    // Create a simple link for the section
    const link = document.createElement('a')
    link.href = `#${section.id}`
    link.textContent = section.textContent.trim() || `Section ${section.id}`
    link.classList.add('toc-link')
    
    // Add to the TOC container if it exists
    const tocContainer = this.element.querySelector('.toc-container') || this.element
    tocContainer.appendChild(link)
    
    return link
  }

  /**
   * Throttle function to limit the rate at which a function can fire
   * @param {Function} func - The function to throttle
   * @param {number} limit - Time in milliseconds to throttle invocations to
   * @return {Function} Throttled function
   */
  throttle(func, limit) {
    let lastFunc
    let lastRan
    return function() {
      const context = this
      const args = arguments
      if (!lastRan) {
        func.apply(context, args)
        lastRan = Date.now()
      } else {
        clearTimeout(lastFunc)
        lastFunc = setTimeout(function() {
          if ((Date.now() - lastRan) >= limit) {
            func.apply(context, args)
            lastRan = Date.now()
          }
        }, limit - (Date.now() - lastRan))
      }
    }
  }

  /**
   * Debounce function to delay invoking a function until after wait milliseconds
   * @param {Function} func - The function to debounce
   * @param {number} wait - Time in milliseconds to wait before invoking the function
   * @return {Function} Debounced function
   */
  debounce(func, wait) {
    let timeout
    return function() {
      const context = this
      const args = arguments
      clearTimeout(timeout)
      timeout = setTimeout(() => func.apply(context, args), wait)
    }
  }

  setupEventListeners() {
    this.scrollHandler = this.throttle(this.handleScroll.bind(this), this.debounceDelayValue)
    this.resizeHandler = this.debounce(this.handleResize.bind(this), 100)
    this.hashChangeHandler = this.handleHashChange.bind(this)
    this.clickHandler = this.handleTocClick.bind(this)
    
    window.addEventListener('scroll', this.scrollHandler, { passive: true })
    window.addEventListener('resize', this.resizeHandler, { passive: true })
    window.addEventListener('hashchange', this.hashChangeHandler)
    // Delegate clicks within the TOC container to activate links immediately
    this.element.addEventListener('click', this.clickHandler)
  }

  cleanup() {
    if (this.rafId) {
      cancelAnimationFrame(this.rafId)
      this.rafId = null
    }

    if (this.observer) {
      this.observer.disconnect()
    }
    
    if (this.scrollTimeout) {
      cancelAnimationFrame(this.scrollTimeout)
      this.scrollTimeout = null
    }
    
    if (this.resizeTimeout) {
      clearTimeout(this.resizeTimeout)
    }
    
    window.removeEventListener('scroll', this.scrollHandler, { passive: true })
    window.removeEventListener('resize', this.resizeHandler, { passive: true })
    window.removeEventListener('hashchange', this.hashChangeHandler)
    this.element.removeEventListener('click', this.clickHandler)

    // Allow future calls to initialize() after cleanup (e.g., when re-enabling tracking)
    this.initialized = false
  }

  /**
   * Sync the optional checkbox target with current enabled state
   */
  syncFollowCheckbox() {
    try {
      if (this.hasFollowTarget) {
        const checked = !!this.enabledValue
        if (this.followTarget.checked !== checked) {
          this.followTarget.checked = checked
        }
      }
    } catch (_) { /* noop */ }
  }

  /**
   * Handle scroll events with requestAnimationFrame for better performance
   */
  handleScroll() {
    if (!this.enabledValue) return
    if (this.scrollTimeout) {
      cancelAnimationFrame(this.rafId)
    }

    this.rafId = requestAnimationFrame(() => {
      const scrollTop = window.pageYOffset || document.documentElement.scrollTop
      
      // Only update if scrolled more than 30px since last check
      if (Math.abs(scrollTop - this.lastScrollTop) > 30) {
        this.lastScrollTop = scrollTop
        this.updateActiveSection()
      }
    })
  }

  /**
   * Handle window resize events with debounce
   */
  handleResize() {
    if (!this.enabledValue) return
    if (this.resizeTimeout) {
      clearTimeout(this.resizeTimeout)
    }
    
    this.resizeTimeout = setTimeout(() => {
      this.computeSectionTops()
      this.updateActiveSection()
    }, 100)
  }

  /**
   * Handle URL hash changes to immediately activate matching TOC link
   */
  handleHashChange() {
    // Allow hash-based activation regardless of tracking state so manual navigation still highlights
    this.activateByHash(window.location.hash)
  }

  /**
   * Handle clicks on TOC links to activate immediately and set hash priority
   * @param {MouseEvent} event
   */
  handleTocClick(event) {
    const link = event.target && event.target.closest && event.target.closest('a.toc-link')
    if (!link || !this.element.contains(link)) return

    // Determine target id from data-target or href
    const target = link.getAttribute('data-target') || (link.getAttribute('href') || '').replace(/^.*#/, '')
    if (!target) return

    // Prefer the target as-is; support legacy alias for articles (section-art-*) and fallback for articles/sections
    const hasSectionPrefix = /^section-/.test(target)
    const preferredId = target
    const fallbackId = hasSectionPrefix ? target.replace(/^section-/, '') : `section-${target}`
    const el = document.getElementById(preferredId) || document.getElementById(fallbackId)

    if (el) {
      // Prevent native jump to avoid double-scrolling and let us control smooth scroll
      event.preventDefault()

      // Perform a single smooth scroll; scroll-margin-top on anchors handles header offset
      el.scrollIntoView({ behavior: 'smooth', block: 'start', inline: 'nearest' })

      // Update the URL without triggering a hashchange handler
      try {
        // Preserve the prefix for real section headings so hash matches data-target exactly
        const newUrl = `#${preferredId}`
        if (window.history && window.history.pushState) {
          window.history.pushState({}, '', newUrl)
        } else {
          // Fallback for very old browsers
          window.location.hash = newUrl
        }
      } catch (_) { /* noop */ }
    }

    // Activate immediately and set priority window so scroll won't override
    this.updateActiveLink(link)
    // For legacy article alias like '#section-art-6', prefer 'art-6' as the priority id; otherwise use the id as-is
    this.hashPriorityId = /^section-art-/.test(preferredId) ? preferredId.replace(/^section-/, '') : preferredId
    this.hashPriorityUntil = Date.now() + this.hashPriorityMsValue
  }

  /**
   * Activate the TOC link that matches the given hash (e.g., "#art-6" or "#section-art-6")
   * @param {string} hash
   */
  activateByHash(hash) {
    if (!hash) return
    const id = hash.replace(/^#/, '')
    const candidates = [id]
    if (id.startsWith('section-')) {
      candidates.push(id.replace(/^section-/, ''))
    } else {
      candidates.push(`section-${id}`)
    }

    // Prefer data-target match; fall back to href
    const tocContainer = this.element
    let link = null
    for (const c of candidates) {
      link = tocContainer.querySelector(`a.toc-link[data-target='${c}']`) || tocContainer.querySelector(`a.toc-link[href$='#${c}']`)
      if (link) break
    }

    if (link) {
      this.updateActiveLink(link)
      // Respect this hash as the active section briefly to avoid scroll observer overriding it immediately
      const priorityId = /^section-art-/.test(id) ? id.replace(/^section-/, '') : id
      this.hashPriorityId = priorityId
      this.hashPriorityUntil = Date.now() + this.hashPriorityMsValue
    }
  }

  /**
   * If a hash is present and the target element exists, scroll it into view.
   * This is primarily used after the articles Turbo frame finishes loading,
   * because native hash navigation happens before those elements exist.
   */
  scrollToCurrentHash() {
    try {
      const hash = window.location.hash
      if (!hash) return
      const id = hash.replace(/^#/, '')
      const candidates = [id]
      if (id.startsWith('section-')) {
        candidates.push(id.replace(/^section-/, ''))
      } else {
        candidates.push(`section-${id}`)
      }

      let el = null
      for (const c of candidates) {
        el = document.getElementById(c)
        if (el) break
      }
      if (!el) return

      // Perform a single programmatic scroll; anchors have scroll-margin-top for header offset
      el.scrollIntoView({ behavior: 'auto', block: 'start', inline: 'nearest' })

      // Maintain hash priority so observer doesn't override immediately
      const priorityId = /^section-art-/.test(id) ? id.replace(/^section-/, '') : id
      this.hashPriorityId = priorityId
      this.hashPriorityUntil = Date.now() + this.hashPriorityMsValue
    } catch (_) { /* noop */ }
  }

  /**
   * Handle intersection observer callbacks
   */
  handleIntersection(entries) {
    if (!this.enabledValue) return
    let needsUpdate = false
    
    entries.forEach(entry => {
      const section = this.sections.find(s => s.element === entry.target)
      if (section) {
        const wasIntersecting = section.isIntersecting
        section.isIntersecting = entry.isIntersecting
        section.intersectionRatio = entry.intersectionRatio
        
        if (wasIntersecting !== section.isIntersecting) {
          needsUpdate = true
        }
      }
    })
    
    if (needsUpdate) {
      this.updateActiveSection()
    }
  }

  /**
   * Update the active section in the TOC based on scroll position
   */
  updateActiveSection() {
    if (!this.enabledValue) return
    // If we recently activated via hash, keep that section active briefly
    if (this.hashPriorityId && Date.now() < this.hashPriorityUntil) {
      const targetId = this.hashPriorityId
      let section = this.sections.find(s => s.id === targetId)
      if (!section) {
        // Try legacy alias id
        section = this.sections.find(s => s.id === `section-${targetId}`)
      }
      if (section && section.link) {
        this.updateActiveLink(section.link)
        this.currentActiveSection = section
        return
      }
    }
    if (this.sections.length === 0) {
      this.initializeSections()
      if (this.sections.length === 0) return
    }

    // Use precomputed tops with binary search for O(log N) updates
    if (!this.sectionTops || this.sectionTops.length !== this.sections.length) {
      this.computeSectionTops()
    }
    const scrollTop = window.pageYOffset || document.documentElement.scrollTop
    const headerOffset = this.getHeaderOffset()
    const viewportTop = scrollTop + headerOffset
    const candidate = this.findActiveByScroll(viewportTop)
    if (candidate && candidate.link) {
      this.updateActiveLink(candidate.link)
      this.currentActiveSection = candidate
    }
  }

  /**
   * Set the initial active section based on current scroll position
   */
  setInitialActiveSection() {
    if (this.sections.length === 0) return
    
    // If a recent hash navigation is in effect, prefer that as the initial active section
    if (this.hashPriorityId && Date.now() < this.hashPriorityUntil) {
      const targetId = this.hashPriorityId
      let section = this.sections.find(s => s.id === targetId)
      if (!section) {
        section = this.sections.find(s => s.id === `section-${targetId}`)
      }
      if (section && section.link) {
        this.updateActiveLink(section.link)
        this.currentActiveSection = section
        return
      }
    }
    
    const scrollTop = window.pageYOffset || document.documentElement.scrollTop
    let activeSection = this.sections[0] // Default to first section
    
    // Find the section that's currently in view or just passed
    for (let i = this.sections.length - 1; i >= 0; i--) {
      const section = this.sections[i]
      const rect = section.element.getBoundingClientRect()
      const elementTop = rect.top + scrollTop
      
      const headerOffset = this.getHeaderOffset()
      if (elementTop <= scrollTop + headerOffset) { // align with dynamic header offset
        activeSection = section
        break
      }
    }
    
    if (activeSection) {
      this.updateActiveLink(activeSection.link)
      this.currentActiveSection = activeSection
    }
  }
  
  /**
   * Start observing all found sections
   */
  observeSections() {
    this.sections.forEach(section => {
      this.observer.observe(section.element)
    })
  }

  /**
   * Compute and cache absolute top offsets for each section; sorted ascending.
   */
  computeSectionTops() {
    try {
      const scrollTop = window.pageYOffset || document.documentElement.scrollTop
      this.sectionTops = this.sections.map(s => {
        const rect = s.element.getBoundingClientRect()
        return { top: rect.top + scrollTop, section: s }
      }).sort((a, b) => a.top - b.top)
    } catch (_) {
      this.sectionTops = []
    }
  }

  /**
   * Binary search the last section whose top <= viewportTop
   */
  findActiveByScroll(viewportTop) {
    const arr = this.sectionTops || []
    if (arr.length === 0) return null
    let lo = 0, hi = arr.length - 1, ans = -1
    while (lo <= hi) {
      const mid = (lo + hi) >> 1
      if (arr[mid].top <= viewportTop) {
        ans = mid
        lo = mid + 1
      } else {
        hi = mid - 1
      }
    }
    if (ans >= 0) return arr[ans].section
    // If none above, pick the nearest below
    return arr[0]?.section || null
  }
  
  /**
   * Handle intersection observer entries
   * @param {IntersectionObserverEntry[]} entries
   */
  // Legacy alternative selector retained for reference; not used as observer callback
  handleIntersectionLegacy(entries) {
    // intentionally unused
  }
  
  /**
   * Update the active TOC link styling
   * @param {HTMLElement} newActiveLink
   */
  updateActiveLink(newActiveLink) {
    // If it's the same link, no need to update
    if (this.currentActiveLink === newActiveLink) return;
    
    // Remove active state from current link
    if (this.currentActiveLink) {
      this.removeActiveState(this.currentActiveLink);
    }
    
    // Add active state to new link
    if (newActiveLink) {
      this.addActiveState(newActiveLink);
      this.currentActiveLink = newActiveLink;
      
      // Scroll TOC to show active link if needed
      this.scrollToActiveLink(newActiveLink);
    }
  }
  
  /**
   * Add active state styling to a TOC link
   * @param {HTMLElement} link
   */
  addActiveState(link) {
    if (!link) return;
    
    // First remove any existing active states from all links
    this.linkTargets.forEach(l => this.removeActiveState(l));
    
    // Add active class to the link; theme-aware styles are handled in CSS via variables
    link.classList.add('active');
  }
  
  /**
   * Remove active state styling from a TOC link
   * @param {HTMLElement} link
   */
  removeActiveState(link) {
    if (!link) return;
    
    // Remove only the generic active class; all visual styles derive from CSS
    link.classList.remove('active');
  }
  
  /**
   * Scroll the TOC container to show the active link
   * @param {HTMLElement} activeLink
   */
  scrollToActiveLink(activeLink) {
    const tocContainer = this.element
    const linkRect = activeLink.getBoundingClientRect()
    const containerRect = tocContainer.getBoundingClientRect()
    
    // Check if link is outside visible area
    if (linkRect.top < containerRect.top || linkRect.bottom > containerRect.bottom) {
      // Calculate scroll position to center the active link
      const linkOffsetTop = activeLink.offsetTop
      const containerHeight = tocContainer.clientHeight
      const linkHeight = activeLink.offsetHeight
      
      const scrollTop = linkOffsetTop - (containerHeight / 2) + (linkHeight / 2)
      
      tocContainer.scrollTo({
        top: Math.max(0, scrollTop),
        behavior: 'smooth'
      })
    }
  }

  /**
   * Refresh tracking after Turbo frame loads to ensure sections and observers reflect new content
   */
  refreshAfterFrameLoad() {
    if (!this.enabledValue) return
    try {
      this.cleanup()
      this.initialized = false
      // Single deferred initialization after DOM settles (prevents multiple rapid reinitializations)
      setTimeout(() => {
        this.initialize()
        this.computeSectionTops()
        this.syncFollowCheckbox()
        this.activateByHash(window.location.hash)
        this.scrollToCurrentHash()
        this.disableBrokenTocLinks()
      }, 150)
    } catch (_) { /* noop */ }
  }

  /**
   * React when enabledValue changes via Stimulus values API
   */
  enabledValueChanged() {
    try {
      if (this.enabledValue) {
        // Re-enable tracking
        this.initialize()
      } else {
        // Disable tracking and clear any active state
        this.cleanup()
        if (this.currentActiveLink) {
          this.removeActiveState(this.currentActiveLink)
          this.currentActiveLink = null
        }
      }
      // Persist and sync UI
      this.saveEnabledToStorage(!!this.enabledValue)
      this.syncFollowCheckbox()
    } catch (_) { /* noop */ }
  }

  /**
   * Handle checkbox change to toggle follow/track behavior
   * @param {Event} event
   */
  toggleFollow(event) {
    const checked = !!(event && event.target && event.target.checked)
    this.enabledValue = checked
  }
}
