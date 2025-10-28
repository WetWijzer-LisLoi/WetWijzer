import { Controller } from "@hotwired/stimulus"

/**
 * Dark Mode Controller
 * @class DarkModeController
 * @extends Controller
 * 
 * Manages theme switching between light and dark modes while respecting the user's
 * system preference when no explicit choice has been made. This controller provides
 * a seamless dark/light mode experience with persistent user preferences.
 * 
 * @example
 * <!-- HTML usage -->
 * <div data-controller="dark-mode">
 *   <button data-action="click->dark-mode#toggle">Toggle Theme</button>
 * </div>
 * 
 * @example
 * // Custom configuration
 * <div 
 *   data-controller="dark-mode"
 *   data-dark-mode-storage-key-value="user-theme"
 *   data-dark-mode-dark-class-value="dark-theme"
 * ></div>
 */
export default class extends Controller {
  /**
   * Controller values configuration
   * @static
   * @type {Object}
   * @property {Object} storageKey - Configuration for theme storage key
   * @property {string} storageKey.type - Expected type (String)
   * @property {string} storageKey.default - Default storage key ('theme')
   * @property {Object} darkClass - Configuration for dark mode CSS class
   * @property {string} darkClass.type - Expected type (String)
   * @property {string} darkClass.default - Default dark class ('dark')
   */
  static values = { 
    storageKey: { type: String, default: 'theme' },
    darkClass: { type: String, default: 'dark' }
  }

  /**
   * Called when the controller is connected to the DOM
   * Sets up the initial theme and system preference listener
   * @return {void}
   */
  connect() {
    // Apply theme on initial load
    this.applyTheme()
    
    // Listen for system theme changes
    this.mediaQuery = window.matchMedia('(prefers-color-scheme: dark)')
    this.mediaQuery.addEventListener('change', this.handleSystemThemeChange.bind(this))
  }

  /**
   * Called when the controller is disconnected from the DOM
   * Cleans up event listeners to prevent memory leaks
   * @return {void}
   */
  disconnect() {
    // Clean up event listener
    if (this.mediaQuery) {
      this.mediaQuery.removeEventListener('change', this.handleSystemThemeChange.bind(this))
    }
  }

  /**
   * Toggles between light and dark themes
   * @param {Event} event - The click event that triggered the toggle
   * @return {void}
   * @example
   * // Programmatic usage
   * const controller = application.getControllerForElementAndIdentifier(
   *   document.querySelector('[data-controller="dark-mode"]'),
   *   'dark-mode'
   )
   * controller.toggle(new Event('click'))
   */
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

  /**
   * Applies the current theme to the document
   * @private
   * @return {void}
   */
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
  
  /**
   * Determines if dark theme should be used based on user preference and system settings
   * @private
   * @return {boolean} True if dark theme should be used
   */
  shouldUseDarkTheme() {
    const storedTheme = this.getStoredTheme()
    
    if (storedTheme === 'dark') return true
    if (storedTheme === 'light') return false
    
    // Fall back to system preference if no user preference is set
    return this.systemPrefersDark()
  }

  /**
   * Retrieves the stored theme preference from localStorage
   * @private
   * @return {string|null} The stored theme or null if not set or error occurs
   */
  getStoredTheme() {
    try {
      return localStorage.getItem(this.storageKeyValue)
    } catch (error) {
      console.warn('Failed to read theme from localStorage:', error)
      return null
    }
  }

  /**
   * Saves the theme preference to localStorage
   * @private
   * @param {string} theme - The theme to save ('light' or 'dark')
   * @return {void}
   */
  setTheme(theme) {
    try {
      localStorage.setItem(this.storageKeyValue, theme)
    } catch (error) {
      console.warn('Failed to save theme to localStorage:', error)
    }
  }

  /**
   * Checks if the system prefers dark color scheme
   * @private
   * @return {boolean} True if system prefers dark mode
   */
  systemPrefersDark() {
    try {
      return window.matchMedia('(prefers-color-scheme: dark)').matches
    } catch (error) {
      console.warn('Failed to check system theme preference:', error)
      return false
    }
  }

  /**
   * Handles changes to the system color scheme preference
   * @private
   * @return {void}
   */
  handleSystemThemeChange() {
    // Only apply system theme if user hasn't set an explicit preference
    if (!this.getStoredTheme()) {
      this.applyTheme()
    }
  }
}
