/**
 * Keyboard Shortcuts Controller
 * 
 * Provides keyboard navigation and shortcuts throughout the application.
 * 
 * Shortcuts:
 * - / or Ctrl+K : Focus search input
 * - j/k : Navigate up/down in search results
 * - Enter : Open selected result
 * - b : Toggle bookmark on current law
 * - Escape : Close modals/dropdowns
 * - ? : Show help modal
 * - g h : Go home
 * - g b : Go to bookmarks
 * 
 * @example
 * <body data-controller="keyboard-shortcuts">
 */
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["helpModal"]
  static values = {
    enabled: { type: Boolean, default: true }
  }

  connect() {
    this.selectedIndex = -1
    this.pendingKey = null
    this.pendingTimeout = null
    
    // Bind handlers
    this.handleKeyDown = this.handleKeyDown.bind(this)
    document.addEventListener('keydown', this.handleKeyDown)
  }

  disconnect() {
    document.removeEventListener('keydown', this.handleKeyDown)
    if (this.pendingTimeout) clearTimeout(this.pendingTimeout)
  }

  handleKeyDown(event) {
    if (!this.enabledValue) return
    
    // Ignore if typing in input, textarea, or contenteditable
    const target = event.target
    const isInputField = target.tagName === 'INPUT' || 
                         target.tagName === 'TEXTAREA' || 
                         target.isContentEditable ||
                         target.closest('[contenteditable="true"]')
    
    // Some shortcuts work even in input fields
    const key = event.key
    
    // Escape always works
    if (key === 'Escape') {
      this.handleEscape(event)
      return
    }
    
    // Skip other shortcuts if in input field
    if (isInputField) {
      // Ctrl+K works in inputs to focus search
      if ((event.ctrlKey || event.metaKey) && key === 'k') {
        event.preventDefault()
        this.focusSearch()
      }
      return
    }
    
    // Handle two-key sequences (g + something)
    if (this.pendingKey === 'g') {
      this.clearPending()
      switch (key) {
        case 'h':
          event.preventDefault()
          window.location.href = '/'
          return
        case 'b':
          event.preventDefault()
          this.goToBookmarks()
          return
      }
    }
    
    // Single key shortcuts
    switch (key) {
      case '/':
        event.preventDefault()
        this.focusSearch()
        break
        
      case 'k':
        if (event.ctrlKey || event.metaKey) {
          event.preventDefault()
          this.focusSearch()
        } else {
          this.navigateResults(-1)
        }
        break
        
      case 'j':
        this.navigateResults(1)
        break
        
      case 'Enter':
        this.openSelectedResult()
        break
        
      case 'b':
        this.toggleBookmark()
        break
        
      case '?':
        if (event.shiftKey) {
          event.preventDefault()
          this.showHelp()
        }
        break
        
      case 'g':
        this.setPending('g')
        break
        
      case 'p':
        // Print shortcut
        if (event.ctrlKey || event.metaKey) {
          // Let browser handle
        }
        break
    }
  }

  focusSearch() {
    const searchInput = document.querySelector('input[name="q"], input[type="search"], #search-input')
    if (searchInput) {
      searchInput.focus()
      searchInput.select()
    }
  }

  navigateResults(direction) {
    const results = document.querySelectorAll('[data-law-result], .law-result, article[data-numac]')
    if (results.length === 0) return
    
    // Remove previous selection
    results.forEach(r => r.classList.remove('keyboard-selected'))
    
    // Update index
    this.selectedIndex += direction
    if (this.selectedIndex < 0) this.selectedIndex = results.length - 1
    if (this.selectedIndex >= results.length) this.selectedIndex = 0
    
    // Highlight new selection
    const selected = results[this.selectedIndex]
    if (selected) {
      selected.classList.add('keyboard-selected')
      selected.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
    }
  }

  openSelectedResult() {
    const selected = document.querySelector('.keyboard-selected')
    if (!selected) return
    
    // Find link in result
    const link = selected.querySelector('a[href*="/laws/"]') || selected.querySelector('a')
    if (link) {
      link.click()
    }
  }

  toggleBookmark() {
    // Find bookmark button on current page
    const bookmarkBtn = document.querySelector('[data-controller="bookmark"] [data-action*="bookmark#toggle"]') ||
                        document.querySelector('[data-action*="bookmark#toggle"]')
    if (bookmarkBtn) {
      bookmarkBtn.click()
    }
  }

  handleEscape(event) {
    // Close help modal if open
    if (this.hasHelpModalTarget && !this.helpModalTarget.classList.contains('hidden')) {
      event.preventDefault()
      this.hideHelp()
      return
    }
    
    // Close any open dropdowns
    const openDropdowns = document.querySelectorAll('[data-dropdown-target="menu"]:not(.hidden), [aria-expanded="true"]')
    openDropdowns.forEach(dropdown => {
      dropdown.classList.add('hidden')
      const button = dropdown.previousElementSibling
      if (button) button.setAttribute('aria-expanded', 'false')
    })
    
    // Clear search selection
    document.querySelectorAll('.keyboard-selected').forEach(el => el.classList.remove('keyboard-selected'))
    this.selectedIndex = -1
    
    // Blur active element if it's an input
    if (document.activeElement?.tagName === 'INPUT' || document.activeElement?.tagName === 'TEXTAREA') {
      document.activeElement.blur()
    }
  }

  showHelp() {
    // Create modal if it doesn't exist
    let modal = document.getElementById('keyboard-shortcuts-modal')
    if (!modal) {
      modal = this.createHelpModal()
      document.body.appendChild(modal)
    }
    modal.classList.remove('hidden')
    modal.querySelector('[data-dismiss]')?.focus()
  }

  hideHelp() {
    const modal = document.getElementById('keyboard-shortcuts-modal')
    if (modal) modal.classList.add('hidden')
  }

  goToBookmarks() {
    // Navigate to bookmarks page or open bookmarks panel
    const bookmarksLink = document.querySelector('a[href*="bookmarks"]')
    if (bookmarksLink) {
      bookmarksLink.click()
    } else {
      // Open bookmarks dropdown/panel if exists
      const bookmarksBtn = document.querySelector('[data-bookmarks-toggle]')
      if (bookmarksBtn) bookmarksBtn.click()
    }
  }

  setPending(key) {
    this.pendingKey = key
    if (this.pendingTimeout) clearTimeout(this.pendingTimeout)
    this.pendingTimeout = setTimeout(() => this.clearPending(), 1000)
  }

  clearPending() {
    this.pendingKey = null
    if (this.pendingTimeout) {
      clearTimeout(this.pendingTimeout)
      this.pendingTimeout = null
    }
  }

  createHelpModal() {
    const isFrench = document.documentElement.lang === 'fr'
    
    const shortcuts = [
      { key: '/', desc: isFrench ? 'Rechercher' : 'Zoeken' },
      { key: 'Ctrl+K', desc: isFrench ? 'Rechercher (dans champ)' : 'Zoeken (in veld)' },
      { key: 'j / k', desc: isFrench ? 'Naviguer résultats' : 'Navigeer resultaten' },
      { key: 'Enter', desc: isFrench ? 'Ouvrir sélection' : 'Open selectie' },
      { key: 'b', desc: isFrench ? 'Ajouter/supprimer signet' : 'Bladwijzer aan/uit' },
      { key: 'Esc', desc: isFrench ? 'Fermer / Annuler' : 'Sluiten / Annuleren' },
      { key: 'g h', desc: isFrench ? 'Aller à l\'accueil' : 'Ga naar home' },
      { key: 'g b', desc: isFrench ? 'Aller aux signets' : 'Ga naar bladwijzers' },
      { key: '?', desc: isFrench ? 'Afficher aide' : 'Toon hulp' },
    ]
    
    const modal = document.createElement('div')
    modal.id = 'keyboard-shortcuts-modal'
    modal.className = 'fixed inset-0 z-[9999] flex items-center justify-center p-4 bg-black/50 backdrop-blur-sm'
    modal.innerHTML = `
      <div class="bg-white dark:bg-navy rounded-xl shadow-2xl max-w-md w-full max-h-[80vh] overflow-auto border border-gray-200 dark:border-gray-700">
        <div class="flex items-center justify-between p-4 border-b border-gray-200 dark:border-gray-700">
          <h2 class="text-lg font-semibold text-gray-900 dark:text-white">
            ${isFrench ? 'Raccourcis clavier' : 'Sneltoetsen'}
          </h2>
          <button type="button" 
                  class="p-1 text-gray-400 hover:text-gray-600 dark:hover:text-gray-300 transition-colors"
                  data-dismiss
                  onclick="document.getElementById('keyboard-shortcuts-modal').classList.add('hidden')">
            <svg xmlns="http://www.w3.org/2000/svg" class="w-5 h-5" viewBox="0 0 20 20" fill="currentColor">
              <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd"/>
            </svg>
          </button>
        </div>
        <div class="p-4 space-y-2">
          ${shortcuts.map(s => `
            <div class="flex items-center justify-between py-1">
              <span class="text-sm text-gray-600 dark:text-gray-300">${s.desc}</span>
              <kbd class="px-2 py-1 text-xs font-mono bg-gray-100 dark:bg-gray-800 border border-gray-300 dark:border-gray-600 rounded text-gray-700 dark:text-gray-300">${s.key}</kbd>
            </div>
          `).join('')}
        </div>
        <div class="p-4 border-t border-gray-200 dark:border-gray-700 text-center">
          <button type="button" 
                  class="px-4 py-2 text-sm font-medium text-white bg-[var(--accent-600)] hover:bg-[var(--accent-700)] rounded-lg transition-colors"
                  onclick="document.getElementById('keyboard-shortcuts-modal').classList.add('hidden')">
            ${isFrench ? 'Fermer' : 'Sluiten'}
          </button>
        </div>
      </div>
    `
    
    // Close on backdrop click
    modal.addEventListener('click', (e) => {
      if (e.target === modal) modal.classList.add('hidden')
    })
    
    return modal
  }
}
