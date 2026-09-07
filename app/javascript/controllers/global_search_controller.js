import { Controller } from "@hotwired/stimulus"

// ═══════════════════════════════════════════════════════════════════
// Global Search - Tabbed autocomplete with instant article lookup
// Tabs: Alles | Wetgeving | Rechtspraak | Dossiers
// ═══════════════════════════════════════════════════════════════════

export default class extends Controller {
  static targets = ["input", "results", "backdrop"]
  static values = { url: String }

  connect() {
    this.timeout = null
    this.abortController = null
    this.activeTab = 'all'  // 'all', 'legislation', 'jurisprudence', 'parliamentary'
    this.lastData = null
    this.selectedIndex = -1
  }

  disconnect() {
    this.clearTimeout()
    this.abortRequest()
  }

  search() {
    const query = this.inputTarget.value.trim()

    if (query.length < 2) {
      this.hideResults()
      return
    }

    this.clearTimeout()
    this.timeout = setTimeout(() => this.performSearch(query), 180)
  }

  async performSearch(query) {
    this.abortRequest()
    this.abortController = new AbortController()

    try {
      const response = await fetch(`/api/search?q=${encodeURIComponent(query)}`, {
        signal: this.abortController.signal,
        headers: { 'Accept': 'application/json' }
      })

      if (!response.ok) throw new Error('Search failed')

      const data = await response.json()
      this.lastData = data
      // Only reset to initial tab on first search, not on every keystroke
      if (!this._tabInitialized) {
        this.activeTab = this._detectInitialTab()
        this._tabInitialized = true
      }
      this.selectedIndex = -1
      this.renderResults(data)
    } catch (e) {
      if (e.name !== 'AbortError') {
        console.error('Global search error:', e)
      }
    }
  }

  // Detect which tab to start with based on the page's source pills
  _detectInitialTab() {
    const legEl = document.querySelector('[data-source-filters-target="legislation"]')
    const jurEl = document.querySelector('[data-source-filters-target="jurisprudence"]')
    const parEl = document.querySelector('[data-source-filters-target="parliamentary"]')

    const legOn = legEl ? legEl.checked : true
    const jurOn = jurEl ? jurEl.checked : false
    const parOn = parEl ? parEl.checked : false

    const checkedCount = [legOn, jurOn, parOn].filter(Boolean).length

    // If only one source is checked, jump straight to that tab
    if (checkedCount === 1) {
      if (legOn) return 'legislation'
      if (jurOn) return 'jurisprudence'
      if (parOn) return 'parliamentary'
    }
    return 'all'
  }

  // ── Tab switching (client-side, no re-fetch) ──

  switchTab(event) {
    event.preventDefault()
    const tab = event.currentTarget.dataset.tab
    if (!tab || tab === this.activeTab) return

    this.activeTab = tab
    this.selectedIndex = -1
    if (this.lastData) this.renderResults(this.lastData)
  }

  // ── Render ──

  renderResults(data) {
    const hasArticles = data.articles?.length > 0
    const hasLegislation = data.legislation?.length > 0
    const hasJurisprudence = data.jurisprudence?.length > 0
    const hasParliamentary = data.parliamentary?.length > 0

    if (!hasArticles && !hasLegislation && !hasJurisprudence && !hasParliamentary) {
      this.resultsTarget.innerHTML = `
        <div class="p-4 text-sm text-gray-500 dark:text-gray-400">
          ${this.noResultsText()}
        </div>
      `
      this.showResults()
      return
    }

    // Count results per tab
    const counts = {
      all: (data.articles?.length || 0) + (data.legislation?.length || 0) + (data.jurisprudence?.length || 0) + (data.parliamentary?.length || 0),
      legislation: (data.articles?.length || 0) + (data.legislation?.length || 0),
      jurisprudence: data.jurisprudence?.length || 0,
      parliamentary: data.parliamentary?.length || 0
    }

    let html = this.renderTabs(counts)

    // Filter by active tab
    const tab = this.activeTab

    if ((tab === 'all' || tab === 'legislation') && hasArticles) {
      html += this.renderSection(
        this.articleLabel(),
        data.articles,
        'article',
        null, // No "view all" for article matches
        false // No border-bottom separator needed inside
      )
    }

    if ((tab === 'all' || tab === 'legislation') && hasLegislation) {
      html += this.renderSection(
        this.legislationLabel(),
        data.legislation,
        'law',
        `/?q=${encodeURIComponent(data.query)}`,
        hasJurisprudence || hasParliamentary
      )
    }

    if ((tab === 'all' || tab === 'jurisprudence') && hasJurisprudence) {
      html += this.renderSection(
        this.jurisprudenceLabel(),
        data.jurisprudence,
        'case',
        `/jurisprudence?q=${encodeURIComponent(data.query)}`,
        hasParliamentary
      )
    }

    if ((tab === 'all' || tab === 'parliamentary') && hasParliamentary) {
      html += this.renderSection(
        this.parliamentaryLabel(),
        data.parliamentary,
        'doc',
        `/parliamentary_work?q=${encodeURIComponent(data.query)}`,
        false
      )
    }

    // Empty tab state
    if (!html.includes('gs-item')) {
      html += `<div class="p-4 text-sm text-gray-500 dark:text-gray-400">${this.noResultsText()}</div>`
    }

    this.resultsTarget.innerHTML = html
    this.showResults()

    // Bind tab clicks
    this.resultsTarget.querySelectorAll('[data-tab]').forEach(tab => {
      tab.addEventListener('click', (e) => this.switchTab(e))
    })
  }

  renderTabs(counts) {
    const tabs = [
      { key: 'all',           label: this.tabLabel('all'),           count: counts.all },
      { key: 'legislation',   label: this.tabLabel('legislation'),   count: counts.legislation },
      { key: 'jurisprudence', label: this.tabLabel('jurisprudence'), count: counts.jurisprudence },
      { key: 'parliamentary', label: this.tabLabel('parliamentary'), count: counts.parliamentary }
    ]

    const tabsHtml = tabs
      .filter(t => t.count > 0 || t.key === 'all')
      .map(t => {
        const isActive = t.key === this.activeTab
        const cls = isActive
          ? 'gs-tab gs-tab-active'
          : 'gs-tab'
        return `<button class="${cls}" data-tab="${t.key}">${t.label}${t.count > 0 ? ` <span class="gs-tab-count">${t.count}</span>` : ''}</button>`
      })
      .join('')

    return `<div class="gs-tabs">${tabsHtml}</div>`
  }

  renderSection(label, items, type, viewAllUrl, hasBorder) {
    const borderClass = hasBorder ? 'border-b border-gray-200 dark:border-gray-700' : ''
    const viewAllLink = viewAllUrl
      ? `<a href="${viewAllUrl}" class="text-xs text-(--accent-600) hover:underline">${this.viewAllText()}</a>`
      : ''

    return `
      <div class="p-2 ${borderClass}">
        <div class="flex items-center justify-between px-2">
          <span class="gs-section-label">${label}</span>
          ${viewAllLink}
        </div>
        <div class="mt-1">
          ${items.map(item => this.renderItem(item, type)).join('')}
        </div>
      </div>
    `
  }

  renderItem(item, type) {
    const icon = this.iconFor(type)
    return `
      <a href="${item.url}" class="gs-item">
        <span class="shrink-0 mt-0.5 text-gray-400">${icon}</span>
        <div class="min-w-0 flex-1">
          <div class="gs-item-title">${this.escapeHtml(item.title)}</div>
          <div class="gs-item-sub">${this.escapeHtml(item.subtitle || '')}</div>
        </div>
      </a>
    `
  }

  // ── Keyboard navigation ──

  handleKeydown(event) {
    if (event.key === 'Escape') {
      this.hideResults()
      this.inputTarget.blur()
      return
    }

    const items = this.resultsTarget.querySelectorAll('.gs-item')
    if (!items.length) return

    if (event.key === 'ArrowDown') {
      event.preventDefault()
      this.selectedIndex = Math.min(this.selectedIndex + 1, items.length - 1)
      this.highlightItem(items)
    } else if (event.key === 'ArrowUp') {
      event.preventDefault()
      this.selectedIndex = Math.max(this.selectedIndex - 1, -1)
      this.highlightItem(items)
    } else if (event.key === 'Enter' && this.selectedIndex >= 0) {
      event.preventDefault()
      items[this.selectedIndex]?.click()
    } else if (event.key === 'Enter') {
      // No item selected - let form submit, just close dropdown
      this.hideResults()
    }
  }

  highlightItem(items) {
    items.forEach((el, i) => {
      el.classList.toggle('gs-item-active', i === this.selectedIndex)
    })
    if (this.selectedIndex >= 0) {
      items[this.selectedIndex]?.scrollIntoView({ block: 'nearest' })
    }
  }

  // ── Visibility ──

  showResults() {
    this.resultsTarget.classList.remove('hidden')
    if (this.hasBackdropTarget) this.backdropTarget.classList.remove('hidden')
  }

  hideResults() {
    this.resultsTarget.classList.add('hidden')
    if (this.hasBackdropTarget) this.backdropTarget.classList.add('hidden')
  }

  close() {
    this.hideResults()
  }

  // ── Helpers ──

  clearTimeout() {
    if (this.timeout) {
      clearTimeout(this.timeout)
      this.timeout = null
    }
  }

  abortRequest() {
    if (this.abortController) {
      this.abortController.abort()
      this.abortController = null
    }
  }

  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }

  // ── Icons ──

  iconFor(type) {
    switch (type) {
      case 'article': return this.articleIcon()
      case 'law':     return this.lawIcon()
      case 'case':    return this.caseIcon()
      case 'doc':     return this.docIcon()
      default:        return this.lawIcon()
    }
  }

  articleIcon() {
    return `<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 21h10a2 2 0 002-2V9.414a1 1 0 00-.293-.707l-5.414-5.414A1 1 0 0012.586 3H7a2 2 0 00-2 2v14a2 2 0 002 2z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 3v5a1 1 0 001 1h5"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 13h6m-6 4h4"/></svg>`
  }

  lawIcon() {
    return `<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"/></svg>`
  }

  caseIcon() {
    return `<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 6l3 1m0 0l-3 9a5.002 5.002 0 006.001 0M6 7l3 9M6 7l6-2m6 2l3-1m-3 1l-3 9a5.002 5.002 0 006.001 0M18 7l3 9m-3-9l-6-2m0-2v2m0 16V5m0 16H9m3 0h3"/></svg>`
  }

  docIcon() {
    return `<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4"/></svg>`
  }

  // ── Localized strings ──

  get locale() {
    return document.documentElement.lang || 'nl'
  }

  tabLabel(key) {
    const labels = {
      nl: { all: 'Alles', legislation: 'Wetgeving', jurisprudence: 'Rechtspraak', parliamentary: 'Dossiers' },
      fr: { all: 'Tout', legislation: 'Législation', jurisprudence: 'Jurisprudence', parliamentary: 'Dossiers' },
      de: { all: 'Alle', legislation: 'Gesetzgebung', jurisprudence: 'Rechtsprechung', parliamentary: 'Dossiers' },
      en: { all: 'All', legislation: 'Legislation', jurisprudence: 'Case law', parliamentary: 'Dossiers' }
    }
    return (labels[this.locale] || labels.nl)[key] || key
  }

  articleLabel() {
    return this.locale === 'fr' ? 'Articles' : 'Artikelen'
  }

  legislationLabel() {
    return this.locale === 'nl' ? 'Wetgeving' : (this.locale === 'fr' ? 'Législation' : 'Legislation')
  }

  jurisprudenceLabel() {
    return this.locale === 'nl' ? 'Rechtspraak' : (this.locale === 'fr' ? 'Jurisprudence' : 'Case law')
  }

  parliamentaryLabel() {
    return this.locale === 'nl' ? 'Parlementaire stukken' : (this.locale === 'fr' ? 'Travaux parlementaires' : 'Parliamentary work')
  }

  viewAllText() {
    return this.locale === 'nl' ? 'Bekijk alle →' : (this.locale === 'fr' ? 'Voir tout →' : 'View all →')
  }

  noResultsText() {
    return this.locale === 'nl' ? 'Geen resultaten gevonden' : (this.locale === 'fr' ? 'Aucun résultat trouvé' : 'No results found')
  }
}
