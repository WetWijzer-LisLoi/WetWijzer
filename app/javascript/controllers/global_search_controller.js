import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "results", "backdrop"]
  static values = { url: String }
  
  connect() {
    this.timeout = null
    this.abortController = null
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
    this.timeout = setTimeout(() => this.performSearch(query), 200)
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
      this.renderResults(data)
    } catch (e) {
      if (e.name !== 'AbortError') {
        console.error('Global search error:', e)
      }
    }
  }
  
  renderResults(data) {
    const hasLegislation = data.legislation?.length > 0
    const hasJurisprudence = data.jurisprudence?.length > 0
    const hasParliamentary = data.parliamentary?.length > 0
    
    if (!hasLegislation && !hasJurisprudence && !hasParliamentary) {
      this.resultsTarget.innerHTML = `
        <div class="p-4 text-sm text-gray-500 dark:text-gray-400">
          ${this.noResultsText()}
        </div>
      `
      this.showResults()
      return
    }
    
    let html = ''
    
    if (hasLegislation) {
      html += `
        <div class="p-2 border-b border-gray-200 dark:border-gray-700">
          <div class="flex items-center justify-between px-2">
            <span class="text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide">
              ${this.legislationLabel()}
            </span>
            <a href="/?q=${encodeURIComponent(data.query)}" class="text-xs text-[var(--accent-600)] hover:underline">
              ${this.viewAllText()}
            </a>
          </div>
          <div class="mt-1">
            ${data.legislation.map(item => this.renderItem(item, 'law')).join('')}
          </div>
        </div>
      `
    }
    
    if (hasJurisprudence) {
      html += `
        <div class="p-2 ${hasParliamentary ? 'border-b border-gray-200 dark:border-gray-700' : ''}">
          <div class="flex items-center justify-between px-2">
            <span class="text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide">
              ${this.jurisprudenceLabel()}
            </span>
            <a href="/rechtspraak?q=${encodeURIComponent(data.query)}" class="text-xs text-[var(--accent-600)] hover:underline">
              ${this.viewAllText()}
            </a>
          </div>
          <div class="mt-1">
            ${data.jurisprudence.map(item => this.renderItem(item, 'case')).join('')}
          </div>
        </div>
      `
    }
    
    if (hasParliamentary) {
      html += `
        <div class="p-2">
          <div class="flex items-center justify-between px-2">
            <span class="text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide">
              ${this.parliamentaryLabel()}
            </span>
          </div>
          <div class="mt-1">
            ${data.parliamentary.map(item => this.renderItem(item, 'doc')).join('')}
          </div>
        </div>
      `
    }
    
    this.resultsTarget.innerHTML = html
    this.showResults()
  }
  
  renderItem(item, type) {
    const icon = type === 'law' ? this.lawIcon() : (type === 'case' ? this.caseIcon() : this.docIcon())
    return `
      <a href="${item.url}" class="flex items-start gap-2 px-2 py-1.5 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors">
        <span class="flex-shrink-0 mt-0.5 text-gray-400">${icon}</span>
        <div class="min-w-0 flex-1">
          <div class="text-sm text-gray-900 dark:text-gray-100 truncate">${this.escapeHtml(item.title)}</div>
          <div class="text-xs text-gray-500 dark:text-gray-400 truncate">${this.escapeHtml(item.subtitle || '')}</div>
        </div>
      </a>
    `
  }
  
  lawIcon() {
    return `<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"/></svg>`
  }
  
  caseIcon() {
    return `<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 6l3 1m0 0l-3 9a5.002 5.002 0 006.001 0M6 7l3 9M6 7l6-2m6 2l3-1m-3 1l-3 9a5.002 5.002 0 006.001 0M18 7l3 9m-3-9l-6-2m0-2v2m0 16V5m0 16H9m3 0h3"/></svg>`
  }
  
  docIcon() {
    return `<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 20H5a2 2 0 01-2-2V6a2 2 0 012-2h10a2 2 0 012 2v1m2 13a2 2 0 01-2-2V7m2 13a2 2 0 002-2V9a2 2 0 00-2-2h-2m-4-3H9M7 16h6M7 8h6v4H7V8z"/></svg>`
  }
  
  showResults() {
    this.resultsTarget.classList.remove('hidden')
    this.backdropTarget.classList.remove('hidden')
  }
  
  hideResults() {
    this.resultsTarget.classList.add('hidden')
    this.backdropTarget.classList.add('hidden')
  }
  
  close() {
    this.hideResults()
  }
  
  handleKeydown(event) {
    if (event.key === 'Escape') {
      this.hideResults()
      this.inputTarget.blur()
    }
  }
  
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
  
  // Localized strings (detect from html lang attribute)
  get locale() {
    return document.documentElement.lang || 'nl'
  }
  
  legislationLabel() {
    return this.locale === 'fr' ? 'Législation' : 'Wetgeving'
  }
  
  jurisprudenceLabel() {
    return this.locale === 'fr' ? 'Jurisprudence' : 'Rechtspraak'
  }
  
  parliamentaryLabel() {
    return this.locale === 'fr' ? 'Travaux parlementaires' : 'Parlementaire stukken'
  }
  
  viewAllText() {
    return this.locale === 'fr' ? 'Voir tout →' : 'Bekijk alle →'
  }
  
  noResultsText() {
    return this.locale === 'fr' ? 'Aucun résultat trouvé' : 'Geen resultaten gevonden'
  }
}
