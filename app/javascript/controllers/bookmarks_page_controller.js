import { Controller } from "@hotwired/stimulus"

/**
 * Bookmarks Page Controller
 * 
 * Manages the bookmarks page - displays, imports, exports, and clears bookmarks.
 * Bookmarks are stored in localStorage.
 * 
 * @example
 * <div data-controller="bookmarks-page">
 *   <div data-bookmarks-page-target="list"></div>
 *   <div data-bookmarks-page-target="empty"></div>
 *   <span data-bookmarks-page-target="count"></span>
 * </div>
 */
export default class extends Controller {
  static targets = ["list", "empty", "count"]

  connect() {
    this.loadBookmarks()
  }

  /**
   * Loads and displays all bookmarks from localStorage
   */
  loadBookmarks() {
    const bookmarks = this.getBookmarks()
    const locale = this.getLocale()
    
    if (bookmarks.length === 0) {
      this.showEmpty()
      return
    }

    this.hideEmpty()
    this.updateCount(bookmarks.length)
    
    // Clear existing list
    this.listTarget.innerHTML = ''
    
    // Get the template
    const template = document.getElementById('bookmark-item-template')
    if (!template) return

    // Render each bookmark
    bookmarks.forEach(bookmark => {
      const item = template.content.cloneNode(true)
      const container = item.querySelector('.bookmark-item')
      const link = item.querySelector('.bookmark-link')
      const numac = item.querySelector('.bookmark-numac')
      const removeBtn = item.querySelector('.bookmark-remove')

      // Set data
      const title = bookmark.title || bookmark.numac
      link.textContent = title
      link.href = `/laws/${bookmark.numac}?language_id=${locale === 'fr' ? 2 : 1}`
      numac.textContent = `NUMAC ${bookmark.numac}`
      
      // Add remove handler
      removeBtn.addEventListener('click', () => this.removeBookmark(bookmark.numac))
      
      this.listTarget.appendChild(item)
    })
  }

  /**
   * Removes a bookmark by NUMAC
   * @param {string} numac - NUMAC to remove
   */
  removeBookmark(numac) {
    const bookmarks = this.getBookmarks().filter(b => b.numac !== numac)
    this.saveBookmarks(bookmarks)
    this.loadBookmarks()
    this.showToast(this.getLocale() === 'fr' ? 'Signet supprimé' : 'Bladwijzer verwijderd')
  }

  /**
   * Exports bookmarks as JSON file
   */
  exportBookmarks() {
    const bookmarks = this.getBookmarks()
    if (bookmarks.length === 0) {
      this.showToast(this.getLocale() === 'fr' ? 'Aucun signet à exporter' : 'Geen bladwijzers om te exporteren')
      return
    }

    const data = JSON.stringify(bookmarks, null, 2)
    const blob = new Blob([data], { type: 'application/json' })
    const url = URL.createObjectURL(blob)
    
    const a = document.createElement('a')
    a.href = url
    a.download = `wetwijzer-bookmarks-${new Date().toISOString().split('T')[0]}.json`
    document.body.appendChild(a)
    a.click()
    document.body.removeChild(a)
    URL.revokeObjectURL(url)
    
    this.showToast(this.getLocale() === 'fr' ? 'Signets exportés' : 'Bladwijzers geëxporteerd')
  }

  /**
   * Imports bookmarks from JSON file
   * @param {Event} event - File input change event
   */
  importBookmarks(event) {
    const file = event.target.files[0]
    if (!file) return

    const reader = new FileReader()
    reader.onload = (e) => {
      try {
        const imported = JSON.parse(e.target.result)
        if (!Array.isArray(imported)) {
          throw new Error('Invalid format')
        }

        // Merge with existing bookmarks (avoid duplicates)
        const existing = this.getBookmarks()
        const existingNumacs = new Set(existing.map(b => b.numac))
        
        let added = 0
        imported.forEach(bookmark => {
          if (bookmark.numac && !existingNumacs.has(bookmark.numac)) {
            existing.push({
              numac: bookmark.numac,
              title: bookmark.title || bookmark.numac,
              addedAt: bookmark.addedAt || new Date().toISOString()
            })
            added++
          }
        })

        this.saveBookmarks(existing)
        this.loadBookmarks()
        
        const locale = this.getLocale()
        this.showToast(locale === 'fr' 
          ? `${added} signet(s) importé(s)` 
          : `${added} bladwijzer(s) geïmporteerd`)
      } catch (error) {
        this.showToast(this.getLocale() === 'fr' 
          ? 'Fichier invalide' 
          : 'Ongeldig bestand')
      }
    }
    reader.readAsText(file)
    
    // Reset file input
    event.target.value = ''
  }

  /**
   * Clears all bookmarks after confirmation
   */
  clearAll() {
    const confirmMsg = this.getLocale() === 'fr' 
      ? 'Supprimer tous les signets ?' 
      : 'Alle bladwijzers verwijderen?'
    
    if (!confirm(confirmMsg)) return

    this.saveBookmarks([])
    this.loadBookmarks()
    this.showToast(this.getLocale() === 'fr' ? 'Signets supprimés' : 'Bladwijzers verwijderd')
  }

  /**
   * Gets bookmarks from localStorage
   * @returns {Array} Array of bookmark objects
   */
  getBookmarks() {
    try {
      const data = localStorage.getItem('wetwijzer_bookmarks')
      if (!data) return []
      
      const parsed = JSON.parse(data)
      // Handle both old format (array of numacs) and new format (array of objects)
      if (Array.isArray(parsed)) {
        return parsed.map(item => {
          if (typeof item === 'string') {
            return { numac: item, title: item, addedAt: null }
          }
          return item
        })
      }
      return []
    } catch {
      return []
    }
  }

  /**
   * Saves bookmarks to localStorage
   * @param {Array} bookmarks - Array of bookmark objects
   */
  saveBookmarks(bookmarks) {
    localStorage.setItem('wetwijzer_bookmarks', JSON.stringify(bookmarks))
  }

  /**
   * Updates the bookmark count display
   * @param {number} count - Number of bookmarks
   */
  updateCount(count) {
    if (this.hasCountTarget) {
      const locale = this.getLocale()
      const label = locale === 'fr' ? 'signets' : 'bladwijzers'
      this.countTarget.textContent = `${count} ${label}`
    }
  }

  /**
   * Shows the empty state
   */
  showEmpty() {
    if (this.hasEmptyTarget) {
      this.emptyTarget.classList.remove('hidden')
    }
    if (this.hasListTarget) {
      this.listTarget.classList.add('hidden')
    }
    this.updateCount(0)
  }

  /**
   * Hides the empty state
   */
  hideEmpty() {
    if (this.hasEmptyTarget) {
      this.emptyTarget.classList.add('hidden')
    }
    if (this.hasListTarget) {
      this.listTarget.classList.remove('hidden')
    }
  }

  /**
   * Shows a toast notification
   * @param {string} message - Message to display
   */
  showToast(message) {
    const existing = document.querySelector('.bookmarks-toast')
    if (existing) existing.remove()

    const toast = document.createElement('div')
    toast.className = 'bookmarks-toast fixed bottom-4 left-1/2 transform -translate-x-1/2 bg-gray-800 text-white px-4 py-2 rounded-lg shadow-lg z-50 animate-fade-in-up'
    toast.textContent = message
    document.body.appendChild(toast)

    setTimeout(() => {
      toast.classList.add('animate-fade-out')
      setTimeout(() => toast.remove(), 300)
    }, 2500)
  }

  /**
   * Gets current locale
   * @returns {string} 'nl' or 'fr'
   */
  getLocale() {
    return document.documentElement.lang || 'nl'
  }
}
