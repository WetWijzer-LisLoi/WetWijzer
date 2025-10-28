import { Controller } from "@hotwired/stimulus"
import { prefs } from "../services/preferences_store"

/**
 * Dark Mode Controller
 * @class DarkModeController
 * @extends Controller
 * 
 * Manages theme switching between light and dark modes while respecting the user's
 * system preference when no explicit choice has been made. This controller provides
 * a seamless dark/light mode experience with persistent user preferences.
 * 
 * Privacy: Uses server-side preference storage for logged-in users.
 * Anonymous visitors: theme resets to system default on each visit (no browser trace).
 * 
 * @example
 * <!-- HTML usage -->
 * <div data-controller="dark-mode">
 *   <button data-action="click->dark-mode#toggle">Toggle Theme</button>
 * </div>
 */
export default class extends Controller {
  static values = { 
    storageKey: { type: String, default: 'theme' },
    darkClass: { type: String, default: 'dark' }
  }

  connect() {
    // Apply theme on initial load
    this.applyTheme()
    
    // Listen for system theme changes
    this.mediaQuery = window.matchMedia('(prefers-color-scheme: dark)')
    this.mediaQuery.addEventListener('change', this.handleSystemThemeChange.bind(this))
  }

  disconnect() {
    if (this.mediaQuery) {
      this.mediaQuery.removeEventListener('change', this.handleSystemThemeChange.bind(this))
    }
  }

  toggle(event) {
    event?.preventDefault()

    try {
      const isDark = document.documentElement.classList.contains(this.darkClassValue)
      const newTheme = isDark ? 'light' : 'dark'
      
      this.setTheme(newTheme)
      this.applyTheme()
    } catch (error) {
      console.warn('Failed to toggle theme:', error)
    }
  }

  applyTheme() {
    try {
      const shouldUseDark = this.shouldUseDarkTheme()
      
      if (shouldUseDark) {
        document.documentElement.classList.add(this.darkClassValue)
      } else {
        document.documentElement.classList.remove(this.darkClassValue)
      }
      
      // Dispatch custom event for other components to react to theme changes
      document.dispatchEvent(
        new CustomEvent('theme:change', { 
          detail: { 
            theme: shouldUseDark ? 'dark' : 'light',
            darkMode: shouldUseDark 
          } 
        })
      )
    } catch (error) {
      console.warn('Failed to apply theme:', error)
    }
  }

  // Private methods
  
  shouldUseDarkTheme() {
    const storedTheme = this.getStoredTheme()
    
    if (storedTheme === 'dark') return true
    if (storedTheme === 'light') return false
    
    // Fall back to system preference if no user preference is set
    return this.systemPrefersDark()
  }

  /**
   * Retrieves the stored theme preference from server-side profile
   */
  getStoredTheme() {
    return prefs.get('theme', null)
  }

  /**
   * Saves the theme preference to server-side profile
   */
  setTheme(theme) {
    prefs.set('theme', theme)
    // Also set in-memory for immediate same-page reads
    this._currentTheme = theme
  }

  systemPrefersDark() {
    try {
      return window.matchMedia('(prefers-color-scheme: dark)').matches
    } catch (error) {
      console.warn('Failed to check system theme preference:', error)
      return false
    }
  }

  handleSystemThemeChange() {
    // Only apply system theme if user hasn't set an explicit preference
    if (!this.getStoredTheme()) {
      this.applyTheme()
    }
  }
}
