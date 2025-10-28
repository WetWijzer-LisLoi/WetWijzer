import { Controller } from "@hotwired/stimulus"

/**
 * Search Alert Controller
 * 
 * Handles the UI for subscribing to search alerts.
 * Shows a modal to enter email and frequency, then submits to API.
 * 
 * @example
 * <div data-controller="search-alert" data-search-alert-query-value="arbeidsrecht">
 *   <button data-action="click->search-alert#showModal">Subscribe</button>
 * </div>
 */
export default class extends Controller {
  static targets = ["modal", "form", "email", "frequency", "error", "success"]
  static values = {
    query: String,
    filters: Object
  }

  connect() {
    // Create modal if it doesn't exist
    if (!document.getElementById('search-alert-modal')) {
      this.createModal()
    }
  }

  /**
   * Shows the subscription modal
   */
  showModal(event) {
    event.preventDefault()
    const modal = document.getElementById('search-alert-modal')
    if (modal) {
      modal.classList.remove('hidden')
      document.getElementById('search-alert-email')?.focus()
    }
  }

  /**
   * Hides the subscription modal
   */
  hideModal() {
    const modal = document.getElementById('search-alert-modal')
    if (modal) {
      modal.classList.add('hidden')
      this.clearMessages()
    }
  }

  /**
   * Submits the subscription form
   */
  async submit(event) {
    event.preventDefault()
    
    const email = document.getElementById('search-alert-email')?.value
    const frequency = document.getElementById('search-alert-frequency')?.value || 'daily'
    
    if (!email || !this.isValidEmail(email)) {
      this.showError(this.getLocale() === 'fr' 
        ? 'Veuillez entrer une adresse e-mail valide.' 
        : 'Voer een geldig e-mailadres in.')
      return
    }

    // Get current search query from URL
    const urlParams = new URLSearchParams(window.location.search)
    const query = urlParams.get('title') || this.queryValue || ''
    
    if (!query) {
      this.showError(this.getLocale() === 'fr'
        ? 'Veuillez d\'abord effectuer une recherche.'
        : 'Voer eerst een zoekopdracht uit.')
      return
    }

    // Build filters from URL params
    const filters = {}
    const filterKeys = ['constitution', 'law', 'decree', 'ordinance', 'decision', 'misc', 
                       'lang_nl', 'lang_fr', 'date_from', 'date_to']
    filterKeys.forEach(key => {
      if (urlParams.has(key)) {
        filters[key] = urlParams.get(key)
      }
    })

    try {
      const response = await fetch('/api/search_alerts', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': this.getCSRFToken()
        },
        body: JSON.stringify({
          email: email,
          query: query,
          filters: filters,
          frequency: frequency
        })
      })

      const data = await response.json()

      if (response.ok && data.success) {
        this.showSuccess(data.message)
        setTimeout(() => this.hideModal(), 3000)
      } else {
        this.showError(data.errors?.join(', ') || data.error || 'Unknown error')
      }
    } catch (error) {
      this.showError(this.getLocale() === 'fr'
        ? 'Erreur de connexion. Veuillez réessayer.'
        : 'Verbindingsfout. Probeer het opnieuw.')
    }
  }

  /**
   * Creates the modal HTML and appends to body
   */
  createModal() {
    const locale = this.getLocale()
    const modal = document.createElement('div')
    modal.id = 'search-alert-modal'
    modal.className = 'hidden fixed inset-0 z-50 overflow-y-auto'
    modal.setAttribute('aria-modal', 'true')
    modal.setAttribute('role', 'dialog')
    
    modal.innerHTML = `
      <div class="flex items-center justify-center min-h-screen px-4 pt-4 pb-20 text-center sm:p-0">
        <div class="fixed inset-0 bg-gray-500 bg-opacity-75 transition-opacity" data-action="click->search-alert#hideModal"></div>
        
        <div class="relative bg-white dark:bg-navy rounded-lg text-left overflow-hidden shadow-xl transform transition-all sm:my-8 sm:max-w-lg sm:w-full">
          <div class="px-4 pt-5 pb-4 sm:p-6 sm:pb-4">
            <div class="sm:flex sm:items-start">
              <div class="mx-auto flex-shrink-0 flex items-center justify-center h-12 w-12 rounded-full bg-[var(--accent-100)] dark:bg-[var(--accent-900)] sm:mx-0 sm:h-10 sm:w-10">
                <svg class="h-6 w-6 text-[var(--accent-600)]" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9" />
                </svg>
              </div>
              <div class="mt-3 text-center sm:mt-0 sm:ml-4 sm:text-left flex-1">
                <h3 class="text-lg leading-6 font-medium text-gray-900 dark:text-mist">
                  ${locale === 'fr' ? 'Alertes de recherche' : 'Zoekwaarschuwingen'}
                </h3>
                <div class="mt-2">
                  <p class="text-sm text-gray-500 dark:text-gray-400">
                    ${locale === 'fr' 
                      ? 'Recevez un e-mail lorsque de nouvelles lois correspondent à cette recherche.' 
                      : 'Ontvang een e-mail wanneer nieuwe wetten aan deze zoekopdracht voldoen.'}
                  </p>
                </div>
                
                <form id="search-alert-form" class="mt-4 space-y-4" data-action="submit->search-alert#submit">
                  <div>
                    <label for="search-alert-email" class="block text-sm font-medium text-gray-700 dark:text-mist">
                      ${locale === 'fr' ? 'E-mail' : 'E-mail'}
                    </label>
                    <input type="email" id="search-alert-email" name="email" required
                           class="mt-1 block w-full rounded-md border-gray-300 dark:border-gray-600 dark:bg-midnight dark:text-mist shadow-sm focus:border-[var(--accent-500)] focus:ring-[var(--accent-500)] sm:text-sm"
                           placeholder="${locale === 'fr' ? 'votre@email.com' : 'uw@email.com'}">
                  </div>
                  
                  <div>
                    <label for="search-alert-frequency" class="block text-sm font-medium text-gray-700 dark:text-mist">
                      ${locale === 'fr' ? 'Fréquence' : 'Frequentie'}
                    </label>
                    <select id="search-alert-frequency" name="frequency"
                            class="mt-1 block w-full rounded-md border-gray-300 dark:border-gray-600 dark:bg-midnight dark:text-mist shadow-sm focus:border-[var(--accent-500)] focus:ring-[var(--accent-500)] sm:text-sm">
                      <option value="daily">${locale === 'fr' ? 'Quotidien' : 'Dagelijks'}</option>
                      <option value="weekly">${locale === 'fr' ? 'Hebdomadaire' : 'Wekelijks'}</option>
                    </select>
                  </div>
                  
                  <div id="search-alert-error" class="hidden text-sm text-red-600 dark:text-red-400"></div>
                  <div id="search-alert-success" class="hidden text-sm text-green-600 dark:text-green-400"></div>
                </form>
              </div>
            </div>
          </div>
          
          <div class="bg-gray-50 dark:bg-midnight px-4 py-3 sm:px-6 sm:flex sm:flex-row-reverse gap-2">
            <button type="submit" form="search-alert-form"
                    class="w-full sm:w-auto inline-flex justify-center rounded-md border border-transparent shadow-sm px-4 py-2 bg-[var(--accent-600)] text-base font-medium text-white hover:bg-[var(--accent-700)] focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-[var(--accent-500)] sm:text-sm">
              ${locale === 'fr' ? 'S\'abonner' : 'Abonneren'}
            </button>
            <button type="button" data-action="click->search-alert#hideModal"
                    class="mt-3 sm:mt-0 w-full sm:w-auto inline-flex justify-center rounded-md border border-gray-300 dark:border-gray-600 shadow-sm px-4 py-2 bg-white dark:bg-navy text-base font-medium text-gray-700 dark:text-mist hover:bg-gray-50 dark:hover:bg-gray-800 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-[var(--accent-500)] sm:text-sm">
              ${locale === 'fr' ? 'Annuler' : 'Annuleren'}
            </button>
          </div>
        </div>
      </div>
    `
    
    document.body.appendChild(modal)
  }

  /**
   * Shows an error message
   */
  showError(message) {
    this.clearMessages()
    const el = document.getElementById('search-alert-error')
    if (el) {
      el.textContent = message
      el.classList.remove('hidden')
    }
  }

  /**
   * Shows a success message
   */
  showSuccess(message) {
    this.clearMessages()
    const el = document.getElementById('search-alert-success')
    if (el) {
      el.textContent = message
      el.classList.remove('hidden')
    }
  }

  /**
   * Clears all messages
   */
  clearMessages() {
    const error = document.getElementById('search-alert-error')
    const success = document.getElementById('search-alert-success')
    if (error) {
      error.classList.add('hidden')
      error.textContent = ''
    }
    if (success) {
      success.classList.add('hidden')
      success.textContent = ''
    }
  }

  /**
   * Validates email format
   */
  isValidEmail(email) {
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)
  }

  /**
   * Gets current locale from HTML lang attribute
   */
  getLocale() {
    return document.documentElement.lang || 'nl'
  }

  /**
   * Gets CSRF token from meta tag
   */
  getCSRFToken() {
    return document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || ''
  }
}
