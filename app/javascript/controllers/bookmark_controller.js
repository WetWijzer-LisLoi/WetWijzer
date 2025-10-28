/**
 * Bookmark Controller
 * 
 * Manages localStorage-based bookmarks for laws without requiring user login.
 * Bookmarks are stored locally in the browser and can be exported/imported as JSON.
 * 
 * @example
 * <button data-controller="bookmark" 
 *         data-bookmark-numac-value="2024001234"
 *         data-bookmark-title-value="Wet van 15 januari 2024"
 *         data-action="click->bookmark#toggle">
 *   <span data-bookmark-target="icon">☆</span>
 * </button>
 */
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["icon", "count", "list", "emptyMessage", "exportBtn", "importInput"]
  static values = {
    numac: String,
    title: String,
    storageKey: { type: String, default: "wetwijzer_bookmarks" }
  }

  connect() {
    this.updateUI()
    
    // Listen for storage changes from other tabs
    window.addEventListener('storage', this.handleStorageChange.bind(this))
    
    // Listen for custom bookmark events
    document.addEventListener('bookmark:updated', this.handleBookmarkUpdate.bind(this))
  }

  disconnect() {
    window.removeEventListener('storage', this.handleStorageChange.bind(this))
    document.removeEventListener('bookmark:updated', this.handleBookmarkUpdate.bind(this))
  }

  toggle(event) {
    event?.preventDefault?.()
    event?.stopPropagation?.()
    
    const bookmarks = this.getBookmarks()
    const numac = this.numacValue
    const existingIndex = bookmarks.findIndex(b => b.numac === numac)
    
    if (existingIndex > -1) {
      // Remove bookmark
      bookmarks.splice(existingIndex, 1)
      this.showToast(this.isFrench ? "Signet supprimé" : "Bladwijzer verwijderd")
    } else {
      // Add bookmark
      bookmarks.push({
        numac: numac,
        title: this.titleValue || '',
        addedAt: new Date().toISOString(),
        url: window.location.href
      })
      this.showToast(this.isFrench ? "Signet ajouté" : "Bladwijzer toegevoegd")
    }
    
    this.saveBookmarks(bookmarks)
    this.dispatchUpdate()
  }

  remove(event) {
    event?.preventDefault?.()
    const numac = event.currentTarget.dataset.numac
    if (!numac) return
    
    const bookmarks = this.getBookmarks()
    const filteredBookmarks = bookmarks.filter(b => b.numac !== numac)
    this.saveBookmarks(filteredBookmarks)
    this.dispatchUpdate()
    this.showToast(this.isFrench ? "Signet supprimé" : "Bladwijzer verwijderd")
  }

  clearAll(event) {
    event?.preventDefault?.()
    const confirmMsg = this.isFrench 
      ? "Supprimer tous les signets ?" 
      : "Alle bladwijzers verwijderen?"
    
    if (confirm(confirmMsg)) {
      this.saveBookmarks([])
      this.dispatchUpdate()
      this.showToast(this.isFrench ? "Tous les signets supprimés" : "Alle bladwijzers verwijderd")
    }
  }

  exportBookmarks(event) {
    event?.preventDefault?.()
    const bookmarks = this.getBookmarks()
    
    if (bookmarks.length === 0) {
      this.showToast(this.isFrench ? "Aucun signet à exporter" : "Geen bladwijzers om te exporteren")
      return
    }
    
    const data = JSON.stringify(bookmarks, null, 2)
    const blob = new Blob([data], { type: 'application/json' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `wetwijzer-bookmarks-${new Date().toISOString().slice(0,10)}.json`
    document.body.appendChild(a)
    a.click()
    document.body.removeChild(a)
    URL.revokeObjectURL(url)
    
    this.showToast(this.isFrench ? "Signets exportés" : "Bladwijzers geëxporteerd")
  }

  importBookmarks(event) {
    const file = event.target.files[0]
    if (!file) return
    
    const reader = new FileReader()
    reader.onload = (e) => {
      try {
        const imported = JSON.parse(e.target.result)
        if (!Array.isArray(imported)) throw new Error("Invalid format")
        
        const existingBookmarks = this.getBookmarks()
        const existingNumacs = new Set(existingBookmarks.map(b => b.numac))
        
        let addedCount = 0
        imported.forEach(bookmark => {
          if (bookmark.numac && !existingNumacs.has(bookmark.numac)) {
            existingBookmarks.push({
              numac: bookmark.numac,
              title: bookmark.title || '',
              addedAt: bookmark.addedAt || new Date().toISOString(),
              url: bookmark.url || ''
            })
            addedCount++
          }
        })
        
        this.saveBookmarks(existingBookmarks)
        this.dispatchUpdate()
        
        const msg = this.isFrench 
          ? `${addedCount} signet(s) importé(s)` 
          : `${addedCount} bladwijzer(s) geïmporteerd`
        this.showToast(msg)
      } catch (err) {
        this.showToast(this.isFrench ? "Fichier invalide" : "Ongeldig bestand")
      }
    }
    reader.readAsText(file)
    
    // Reset input so same file can be imported again
    event.target.value = ''
  }

  // Private methods
  
  getBookmarks() {
    try {
      const data = localStorage.getItem(this.storageKeyValue)
      return data ? JSON.parse(data) : []
    } catch (e) {
      console.warn('Failed to read bookmarks:', e)
      return []
    }
  }

  saveBookmarks(bookmarks) {
    try {
      localStorage.setItem(this.storageKeyValue, JSON.stringify(bookmarks))
    } catch (e) {
      console.warn('Failed to save bookmarks:', e)
    }
  }

  isBookmarked() {
    if (!this.numacValue) return false
    const bookmarks = this.getBookmarks()
    return bookmarks.some(b => b.numac === this.numacValue)
  }

  updateUI() {
    // Update icon if present
    if (this.hasIconTarget) {
      const isBookmarked = this.isBookmarked()
      this.iconTarget.classList.toggle('bookmarked', isBookmarked)
      this.iconTarget.setAttribute('aria-pressed', isBookmarked.toString())
    }
    
    // Update count if present
    if (this.hasCountTarget) {
      const count = this.getBookmarks().length
      this.countTarget.textContent = count
    }
    
    // Update list if present
    if (this.hasListTarget) {
      this.renderList()
    }
    
    // Update empty message visibility
    if (this.hasEmptyMessageTarget) {
      const isEmpty = this.getBookmarks().length === 0
      this.emptyMessageTarget.classList.toggle('hidden', !isEmpty)
    }
    
    // Update export button state
    if (this.hasExportBtnTarget) {
      const isEmpty = this.getBookmarks().length === 0
      this.exportBtnTarget.disabled = isEmpty
      this.exportBtnTarget.classList.toggle('opacity-50', isEmpty)
    }
  }

  renderList() {
    if (!this.hasListTarget) return
    
    const bookmarks = this.getBookmarks()
    
    if (bookmarks.length === 0) {
      this.listTarget.innerHTML = ''
      return
    }
    
    // Sort by most recent first
    bookmarks.sort((a, b) => new Date(b.addedAt) - new Date(a.addedAt))
    
    this.listTarget.innerHTML = bookmarks.map(bookmark => `
      <div class="flex items-start justify-between gap-2 p-3 rounded-lg bg-gray-50 dark:bg-gray-800/50 border border-gray-200 dark:border-gray-700">
        <a href="/laws/${bookmark.numac}" class="flex-1 min-w-0 text-sm font-medium text-[var(--accent-600)] dark:text-[var(--accent-400)] hover:underline truncate">
          ${this.escapeHtml(bookmark.title || bookmark.numac)}
        </a>
        <button type="button" 
                class="shrink-0 p-1 text-gray-400 hover:text-red-500 dark:hover:text-red-400 transition-colors"
                data-action="click->bookmark#remove"
                data-numac="${bookmark.numac}"
                title="${this.isFrench ? 'Supprimer' : 'Verwijderen'}">
          <svg xmlns="http://www.w3.org/2000/svg" class="w-4 h-4" viewBox="0 0 20 20" fill="currentColor">
            <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd"/>
          </svg>
        </button>
      </div>
    `).join('')
  }

  handleStorageChange(event) {
    if (event.key === this.storageKeyValue) {
      this.updateUI()
    }
  }

  handleBookmarkUpdate() {
    this.updateUI()
  }

  dispatchUpdate() {
    document.dispatchEvent(new CustomEvent('bookmark:updated'))
  }

  showToast(message) {
    const existingToast = document.querySelector('.bookmark-toast')
    if (existingToast) existingToast.remove()

    const toast = document.createElement('div')
    toast.className = 'bookmark-toast fixed bottom-6 left-1/2 -translate-x-1/2 z-[9999] px-4 py-2 bg-gray-900 dark:bg-gray-100 text-white dark:text-gray-900 text-sm font-medium rounded-lg shadow-lg animate-fade-in-up'
    toast.textContent = message
    toast.setAttribute('role', 'status')
    toast.setAttribute('aria-live', 'polite')

    document.body.appendChild(toast)

    setTimeout(() => {
      toast.classList.add('animate-fade-out')
      setTimeout(() => toast.remove(), 300)
    }, 2000)
  }

  escapeHtml(str) {
    const div = document.createElement('div')
    div.textContent = str
    return div.innerHTML
  }

  get isFrench() {
    return document.documentElement.lang === 'fr'
  }
}
