import { Controller } from "@hotwired/stimulus"

/**
 * Praxis Link Controller
 * 
 * Handles deep linking to Praxis contract creator application.
 * Falls back to copying the law reference if Praxis is not installed.
 * 
 * @example
 * <div data-controller="praxis-link"
 *      data-praxis-link-numac-value="2024012345"
 *      data-praxis-link-title-value="Wet betreffende...">
 *   <a href="praxis://contract?ref=2024012345"
 *      data-action="click->praxis-link#openOrCopy">
 *     Praxis
 *   </a>
 * </div>
 */
export default class extends Controller {
  static values = {
    numac: String,
    title: String
  }

  /**
   * Attempts to open in Praxis, falls back to copying reference
   * @param {Event} event - Click event
   */
  openOrCopy(event) {
    // Try to open the custom URL scheme
    const praxisUrl = `praxis://contract?ref=${this.numacValue}`
    
    // Create a hidden iframe to attempt the deep link
    // This prevents the browser from showing an error if the app isn't installed
    const iframe = document.createElement('iframe')
    iframe.style.display = 'none'
    iframe.src = praxisUrl
    document.body.appendChild(iframe)
    
    // Set a timeout to check if the app opened
    // If not, fall back to copying the reference
    const startTime = Date.now()
    
    const checkAndFallback = () => {
      // If the page is still visible after 1.5s, app probably didn't open
      if (document.visibilityState === 'visible' && Date.now() - startTime > 1500) {
        this.copyReference()
      }
      // Clean up iframe
      setTimeout(() => {
        if (iframe.parentNode) {
          iframe.parentNode.removeChild(iframe)
        }
      }, 100)
    }
    
    // Check after a delay
    setTimeout(checkAndFallback, 1500)
    
    // Also listen for visibility change (app opened successfully)
    const visibilityHandler = () => {
      if (document.visibilityState === 'hidden') {
        // App opened, clean up
        document.removeEventListener('visibilitychange', visibilityHandler)
        if (iframe.parentNode) {
          iframe.parentNode.removeChild(iframe)
        }
      }
    }
    document.addEventListener('visibilitychange', visibilityHandler)
    
    // Prevent default link behavior
    event.preventDefault()
  }

  /**
   * Falls back to copying the law reference to clipboard
   */
  copyReference() {
    const locale = document.documentElement.lang || 'nl'
    const reference = `NUMAC ${this.numacValue} - ${this.titleValue}`
    
    navigator.clipboard.writeText(reference).then(() => {
      this.showToast(locale === 'fr' 
        ? 'Référence copiée (Praxis non détecté)' 
        : 'Referentie gekopieerd (Praxis niet gevonden)')
    }).catch(() => {
      // Fallback for older browsers
      this.fallbackCopy(reference, locale)
    })
  }

  /**
   * Fallback copy method for browsers without clipboard API
   * @param {string} text - Text to copy
   * @param {string} locale - Current locale
   */
  fallbackCopy(text, locale) {
    const textarea = document.createElement('textarea')
    textarea.value = text
    textarea.style.position = 'fixed'
    textarea.style.opacity = '0'
    document.body.appendChild(textarea)
    textarea.select()
    
    try {
      document.execCommand('copy')
      this.showToast(locale === 'fr' 
        ? 'Référence copiée (Praxis non détecté)' 
        : 'Referentie gekopieerd (Praxis niet gevonden)')
    } catch (err) {
      this.showToast(locale === 'fr' 
        ? 'Erreur lors de la copie' 
        : 'Fout bij kopiëren')
    }
    
    document.body.removeChild(textarea)
  }

  /**
   * Shows a toast notification
   * @param {string} message - Message to display
   */
  showToast(message) {
    // Remove existing toast if any
    const existing = document.querySelector('.praxis-toast')
    if (existing) existing.remove()

    const toast = document.createElement('div')
    toast.className = 'praxis-toast fixed bottom-4 left-1/2 transform -translate-x-1/2 bg-purple-600 text-white px-4 py-2 rounded-lg shadow-lg z-50 animate-fade-in-up'
    toast.textContent = message
    document.body.appendChild(toast)

    setTimeout(() => {
      toast.classList.add('animate-fade-out')
      setTimeout(() => toast.remove(), 300)
    }, 3000)
  }
}
