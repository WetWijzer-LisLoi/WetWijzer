/**
 * Bookmark Controller
 * 
 * Manages server-side bookmarks for laws. Requires user login.
 * Bookmarks are stored in the user's profile via /api/bookmarks.
 * No localStorage or sessionStorage is used.
 * 
 * GDPR: Bookmarks may contain sensitive legal topic information.
 * Storage requires explicit user action (clicking bookmark button).
 * Legal basis: Art. 6(1)(b) — necessary for requested service.
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
import { showToast } from '../utils/toast'
import { isDutch } from '../utils/locale'
import { prefs } from '../services/preferences_store'

export default class extends Controller {
  static targets = ["icon", "count", "list", "emptyMessage", "exportBtn", "importInput"]
  static values = {
    numac: String,
    title: String
  }

  connect() {
    // Load bookmark state from server for this numac
    this._bookmarked = false
    this._bookmarksCache = null
    
    if (prefs.isLoggedIn()) {
      this.checkBookmarkState()
    }
    
    this.updateUI()
    
    // Listen for custom bookmark events (from other controllers/components)
    this._onBookmarkUpdate = this.handleBookmarkUpdate.bind(this)
    document.addEventListener('bookmark:updated', this._onBookmarkUpdate)
  }

  disconnect() {
    document.removeEventListener('bookmark:updated', this._onBookmarkUpdate)
  }

  async toggle(event) {
    event?.preventDefault?.()
    event?.stopPropagation?.()
    
    if (!prefs.isLoggedIn()) {
      showToast(this.isDutch ? "Log in om bladwijzers te gebruiken" : "Connectez-vous pour utiliser les signets")
      return
    }
    
    const numac = this.numacValue
    if (!numac) return
    
    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      
      if (this._bookmarked) {
        // Remove bookmark via API
        const response = await fetch(`/api/bookmarks/${encodeURIComponent(numac)}`, {
          method: 'DELETE',
          credentials: 'same-origin',
          headers: {
            'Accept': 'application/json',
            ...(csrfToken ? { 'X-CSRF-Token': csrfToken } : {})
          }
        })
        if (response.ok) {
          this._bookmarked = false
          showToast(this.isDutch ? "Bladwijzer verwijderd" : "Signet supprimé")
        }
      } else {
        // Add bookmark via API
        const response = await fetch('/api/bookmarks', {
          method: 'POST',
          credentials: 'same-origin',
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            ...(csrfToken ? { 'X-CSRF-Token': csrfToken } : {})
          },
          body: JSON.stringify({
            numac: numac,
            title: this.titleValue || '',
            url: window.location.href
          })
        })
        if (response.ok) {
          this._bookmarked = true
          showToast(this.isDutch ? "Bladwijzer toegevoegd" : "Signet ajouté")
        }
      }
    } catch (e) {
      console.warn('Bookmark toggle failed:', e)
      showToast(this.isDutch ? "Fout bij opslaan" : "Erreur lors de l'enregistrement")
    }
    
    this.updateUI()
    this.dispatchUpdate()
  }

  async checkBookmarkState() {
    if (!this.numacValue) return
    
    try {
      const response = await fetch(`/api/bookmarks/check?numac=${encodeURIComponent(this.numacValue)}`, {
        credentials: 'same-origin',
        headers: { 'Accept': 'application/json' }
      })
      if (response.ok) {
        const data = await response.json()
        this._bookmarked = data.bookmarked === true
        this.updateUI()
      }
    } catch (e) {
      // Silently fail — user might not be logged in
    }
  }

  // Private methods
  
  isBookmarked() {
    return this._bookmarked
  }

  updateUI() {
    // Update icon if present
    if (this.hasIconTarget) {
      const isBookmarked = this.isBookmarked()
      this.iconTarget.classList.toggle('bookmarked', isBookmarked)
      this.iconTarget.setAttribute('aria-pressed', isBookmarked.toString())
      // Fill the SVG when bookmarked for visual clarity
      this.iconTarget.setAttribute('fill', isBookmarked ? 'currentColor' : 'none')
      // Apply accent color when bookmarked
      const btn = this.iconTarget.closest('button') || this.iconTarget.parentElement
      if (btn) {
        btn.classList.toggle('text-(--accent-500)', isBookmarked)
        btn.classList.toggle('dark:text-(--accent-400)', isBookmarked)
      }
    }
  }

  handleBookmarkUpdate() {
    if (prefs.isLoggedIn()) {
      this.checkBookmarkState()
    }
  }

  dispatchUpdate() {
    document.dispatchEvent(new CustomEvent('bookmark:updated'))
  }

  escapeHtml(str) {
    const div = document.createElement('div')
    div.textContent = str
    return div.innerHTML
  }

  get isDutch() {
    return isDutch()
  }
}
