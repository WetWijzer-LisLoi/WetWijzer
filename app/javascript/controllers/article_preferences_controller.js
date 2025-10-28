import { Controller } from "@hotwired/stimulus"

// Manages user preferences for article display (colors and exdecs visibility)
// Stores preferences in localStorage and syncs with URL parameters
export default class extends Controller {
  static targets = ["spinner"]
  static values = {
    showColors: { type: Boolean, default: true },
    showExdecs: { type: Boolean, default: true },
    showHighlight: { type: Boolean, default: true }
  }

  connect() {
    // Load preferences from localStorage on page load
    this.loadPreferences()
    
    // Apply color preference immediately if colors are disabled
    if (!this.showColorsValue) {
      document.body.classList.add('ww-hide-ref-colors')
    }
    
    // Sync URL parameter with localStorage preference on page load
    // This ensures server-rendered HTML matches user preference
    const url = new URL(window.location.href)
    const urlShowColors = url.searchParams.get('show_colors')
    const localShowColors = this.showColorsValue.toString()
    
    // If URL param doesn't match localStorage, reload with correct param
    if (urlShowColors !== localShowColors) {
      url.searchParams.set('show_colors', localShowColors)
      window.location.href = url.toString()
      return // Stop further execution since we're reloading
    }
    
    // Apply preferences to the turbo frame if needed
    setTimeout(() => this.applyPreferencesToFrame(), 100)
    
    // Sync highlight button state with localStorage
    this.syncHighlightButton()
    
    // Listen for turbo frame events to show/hide spinner
    document.addEventListener('turbo:frame-load', this.handleFrameLoad.bind(this))
    document.addEventListener('turbo:before-fetch-request', this.handleBeforeFetch.bind(this))
  }

  disconnect() {
    document.removeEventListener('turbo:frame-load', this.handleFrameLoad.bind(this))
    document.removeEventListener('turbo:before-fetch-request', this.handleBeforeFetch.bind(this))
  }

  loadPreferences() {
    // Read from localStorage, defaulting to true if not set
    const storedColors = localStorage.getItem('ww_show_colors')
    const storedExdecs = localStorage.getItem('ww_show_exdecs')
    
    if (storedColors !== null) {
      this.showColorsValue = storedColors === 'true'
    }
    
    if (storedExdecs !== null) {
      this.showExdecsValue = storedExdecs === 'true'
    }
    
    const storedHighlight = localStorage.getItem('ww_show_highlight')
    if (storedHighlight !== null) {
      this.showHighlightValue = storedHighlight === 'true'
    }
  }

  applyPreferencesToFrame() {
    // Find the turbo frame (might be nested inside this controller's element)
    const turboFrame = this.element.querySelector('#law_articles') || 
                       document.getElementById('law_articles')
    
    if (!turboFrame) return
    
    // Don't modify if frame has already started loading or completed
    if (turboFrame.hasAttribute('busy') || turboFrame.hasAttribute('complete')) {
      return
    }
    
    // Get the frame's src attribute
    const frameSrc = turboFrame.getAttribute('src')
    if (!frameSrc) return
    
    // Build absolute URL to ensure path is preserved
    let url
    try {
      // If frameSrc is already absolute, use it directly
      if (frameSrc.startsWith('http://') || frameSrc.startsWith('https://')) {
        url = new URL(frameSrc)
      } else {
        // Otherwise, treat as relative path from current location
        url = new URL(frameSrc, window.location.href)
      }
    } catch (e) {
      console.error('Failed to parse frame src:', frameSrc, e)
      return
    }
    
    const currentShowColors = url.searchParams.get('show_colors')
    const currentShowExdecs = url.searchParams.get('show_exdecs')
    
    // Check if stored preferences differ from URL
    const needsUpdate = 
      (this.showColorsValue === false && currentShowColors !== 'false') ||
      (this.showExdecsValue === false && currentShowExdecs !== 'false')
    
    if (needsUpdate) {
      // Update URL parameters to match stored preferences
      url.searchParams.set('show_colors', this.showColorsValue.toString())
      url.searchParams.set('show_exdecs', this.showExdecsValue.toString())
      
      // Update the frame's src to load with preferences
      turboFrame.setAttribute('src', url.toString())
    }
  }

  toggleColors(event) {
    event.preventDefault()
    
    // Toggle the preference
    const newValue = !this.showColorsValue
    this.showColorsValue = newValue
    
    // Store in localStorage
    localStorage.setItem('ww_show_colors', newValue.toString())
    
    // Reload the page with the color preference as a URL parameter
    // This ensures the server re-renders HTML with or without color classes
    const url = new URL(window.location.href)
    url.searchParams.set('show_colors', newValue.toString())
    
    // Preserve the hash (e.g., #tekst) when reloading
    const currentHash = window.location.hash || '#tekst'
    window.location.href = url.toString() + currentHash
    
    // Update the button appearance
    const button = event.currentTarget
    
    // Determine language from current button text
    const currentText = button.textContent
    const isFrench = currentText.includes('Afficher') || currentText.includes('Masquer')
    
    if (newValue) {
      button.classList.remove('btn-toggle-inactive')
      button.classList.add('btn-toggle-active')
      // Rebuild button with "hide colors" state
      button.innerHTML = `
        <svg xmlns="http://www.w3.org/2000/svg" class="w-4 h-4" viewBox="0 0 20 20" fill="currentColor">
          <path d="M10 12a2 2 0 100-4 2 2 0 000 4z"/>
          <path fill-rule="evenodd" d="M.458 10C1.732 5.943 5.522 3 10 3s8.268 2.943 9.542 7c-1.274 4.057-5.064 7-9.542 7S1.732 14.057.458 10zM14 10a4 4 0 11-8 0 4 4 0 018 0z" clip-rule="evenodd"/>
        </svg>
        ${isFrench ? 'Masquer les couleurs' : 'Verberg kleuren'}
      `
    } else {
      button.classList.remove('btn-toggle-active')
      button.classList.add('btn-toggle-inactive')
      // Rebuild button with "show colors" state
      button.innerHTML = `
        <svg xmlns="http://www.w3.org/2000/svg" class="w-4 h-4" viewBox="0 0 20 20" fill="currentColor">
          <path fill-rule="evenodd" d="M3.707 2.293a1 1 0 00-1.414 1.414l14 14a1 1 0 001.414-1.414l-1.473-1.473A10.014 10.014 0 0019.542 10C18.268 5.943 14.478 3 10 3a9.958 9.958 0 00-4.512 1.074l-1.78-1.781zm4.261 4.26l1.514 1.515a2.003 2.003 0 012.45 2.45l1.514 1.514a4 4 0 00-5.478-5.478z" clip-rule="evenodd"/>
          <path d="M12.454 16.697L9.75 13.992a4 4 0 01-3.742-3.741L2.335 6.578A9.98 9.98 0 00.458 10c1.274 4.057 5.065 7 9.542 7 .847 0 1.669-.105 2.454-.303z"/>
        </svg>
        ${isFrench ? 'Afficher les couleurs' : 'Toon kleuren'}
      `
    }
  }

  toggleExdecs(event) {
    event.preventDefault()
    
    // Toggle the preference
    const newValue = !this.showExdecsValue
    this.showExdecsValue = newValue
    
    // Store in localStorage
    localStorage.setItem('ww_show_exdecs', newValue.toString())
    
    // Show spinner
    this.showSpinner()
    
    // Navigate to update the view
    this.navigateWithPreferences()
  }

  navigateWithPreferences() {
    // Find the turbo frame (might be nested or in parent)
    const turboFrame = this.element.querySelector('#law_articles') || 
                       this.element.closest('#tekst')?.querySelector('#law_articles') ||
                       document.getElementById('law_articles')
    
    if (!turboFrame) return
    
    const baseUrl = turboFrame.getAttribute('src') || turboFrame.getAttribute('data-src')
    if (!baseUrl) return
    
    const url = new URL(baseUrl, window.location.origin)
    
    // Update URL parameters based on current preferences
    url.searchParams.set('show_colors', this.showColorsValue.toString())
    url.searchParams.set('show_exdecs', this.showExdecsValue.toString())
    
    // Update the turbo frame src to reload with new preferences
    turboFrame.setAttribute('src', url.toString())
  }

  showSpinner() {
    if (this.hasSpinnerTarget) {
      this.spinnerTarget.classList.remove('hidden')
    }
  }

  hideSpinner() {
    if (this.hasSpinnerTarget) {
      this.spinnerTarget.classList.add('hidden')
    }
  }

  handleBeforeFetch(event) {
    // Check if this fetch is for the law_articles frame
    const frame = event.target
    if (frame && frame.id === 'law_articles') {
      this.showSpinner()
    }
  }

  handleFrameLoad(event) {
    // Check if this load is for the law_articles frame
    const frame = event.target
    if (frame && frame.id === 'law_articles') {
      this.hideSpinner()
      // Color preference is automatically applied via body class
    }
  }

  syncHighlightButton() {
    const button = this.element.querySelector('[data-highlight-toggle]')
    if (!button) return
    
    const showHighlight = this.showHighlightValue
    
    // Determine language from document
    const isFrench = document.documentElement.lang === 'fr'
    
    if (showHighlight) {
      button.classList.remove('btn-toggle-inactive')
      button.classList.add('btn-toggle-active')
      button.innerHTML = `
        <svg xmlns="http://www.w3.org/2000/svg" class="w-4 h-4" viewBox="0 0 20 20" fill="currentColor">
          <path d="M10 2a1 1 0 011 1v1a1 1 0 11-2 0V3a1 1 0 011-1zm4 8a4 4 0 11-8 0 4 4 0 018 0zm-.464 4.95l.707.707a1 1 0 001.414-1.414l-.707-.707a1 1 0 00-1.414 1.414zm2.12-10.607a1 1 0 010 1.414l-.706.707a1 1 0 11-1.414-1.414l.707-.707a1 1 0 011.414 0zM17 11a1 1 0 100-2h-1a1 1 0 100 2h1zm-7 4a1 1 0 011 1v1a1 1 0 11-2 0v-1a1 1 0 011-1zM5.05 6.464A1 1 0 106.465 5.05l-.708-.707a1 1 0 00-1.414 1.414l.707.707zm1.414 8.486l-.707.707a1 1 0 01-1.414-1.414l.707-.707a1 1 0 011.414 1.414zM4 11a1 1 0 100-2H3a1 1 0 000 2h1z"/>
        </svg>
        ${isFrench ? 'Masquer le surlignage' : 'Verberg markering'}
      `
    } else {
      button.classList.remove('btn-toggle-active')
      button.classList.add('btn-toggle-inactive')
      button.innerHTML = `
        <svg xmlns="http://www.w3.org/2000/svg" class="w-4 h-4" viewBox="0 0 20 20" fill="currentColor">
          <path d="M17.293 13.293A8 8 0 016.707 2.707a8.001 8.001 0 1010.586 10.586z"/>
        </svg>
        ${isFrench ? 'Afficher le surlignage' : 'Toon markering'}
      `
    }
  }

  toggleHighlight(event) {
    event.preventDefault()
    
    // Toggle the preference
    const newValue = !this.showHighlightValue
    this.showHighlightValue = newValue
    
    // Store in localStorage
    localStorage.setItem('ww_show_highlight', newValue.toString())
    
    // Update the button appearance
    const button = event.currentTarget
    
    // Determine language from current button text
    const currentText = button.textContent
    const isFrench = currentText.includes('Afficher') || currentText.includes('Masquer')
    
    if (newValue) {
      button.classList.remove('btn-toggle-inactive')
      button.classList.add('btn-toggle-active')
      button.innerHTML = `
        <svg xmlns="http://www.w3.org/2000/svg" class="w-4 h-4" viewBox="0 0 20 20" fill="currentColor">
          <path d="M10 2a1 1 0 011 1v1a1 1 0 11-2 0V3a1 1 0 011-1zm4 8a4 4 0 11-8 0 4 4 0 018 0zm-.464 4.95l.707.707a1 1 0 001.414-1.414l-.707-.707a1 1 0 00-1.414 1.414zm2.12-10.607a1 1 0 010 1.414l-.706.707a1 1 0 11-1.414-1.414l.707-.707a1 1 0 011.414 0zM17 11a1 1 0 100-2h-1a1 1 0 100 2h1zm-7 4a1 1 0 011 1v1a1 1 0 11-2 0v-1a1 1 0 011-1zM5.05 6.464A1 1 0 106.465 5.05l-.708-.707a1 1 0 00-1.414 1.414l.707.707zm1.414 8.486l-.707.707a1 1 0 01-1.414-1.414l.707-.707a1 1 0 011.414 1.414zM4 11a1 1 0 100-2H3a1 1 0 000 2h1z"/>
        </svg>
        ${isFrench ? 'Masquer le surlignage' : 'Verberg markering'}
      `
    } else {
      button.classList.remove('btn-toggle-active')
      button.classList.add('btn-toggle-inactive')
      button.innerHTML = `
        <svg xmlns="http://www.w3.org/2000/svg" class="w-4 h-4" viewBox="0 0 20 20" fill="currentColor">
          <path d="M17.293 13.293A8 8 0 016.707 2.707a8.001 8.001 0 1010.586 10.586z"/>
        </svg>
        ${isFrench ? 'Afficher le surlignage' : 'Toon markering'}
      `
    }
  }

  // Value changed callbacks (optional, for debugging)
  showColorsValueChanged() {
    // Silent
  }

  showExdecsValueChanged() {
    // Silent
  }

  showHighlightValueChanged() {
    // Silent
  }
}
