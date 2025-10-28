import { Controller } from "@hotwired/stimulus"

/**
 * Theme Selector Controller
 * @class ThemeSelectorController
 * @extends Controller
 * 
 * Provides a popup interface with selectable theme swatches for accent color customization.
 * Persists user selection in localStorage and applies themes by setting CSS classes.
 * Works in conjunction with the dark-mode controller for comprehensive theming.
 * 
 * @example
 * <!-- Basic usage -->
 * <div data-controller="theme-selector">
 *   <button data-action="click->theme-selector#toggle">Select Theme</button>
 *   <div data-theme-selector-target="panel" class="hidden">
 *     <button data-action="click->theme-selector#select" 
 *             data-theme-selector-theme-param="blue">Blue</button>
 *   </div>
 * </div>
 */
export default class extends Controller {
  /**
   * Stimulus targets for UI elements
   * @static
   * @type {string[]}
   */
  static targets = ["panel", "backdrop", "button"]
  
  /**
   * Controller values configuration
   * @static
   * @type {Object}
   * @property {Object} storageKey - localStorage key for theme persistence
   * @property {Object} open - Whether the theme panel is currently open
   */
  static values = {
    storageKey: { type: String, default: 'theme-accent' },
    open: { type: Boolean, default: false }
  }

  /**
   * Called when the controller is connected to the DOM
   * Applies stored theme or default, and sets up keyboard listeners
   * @return {void}
   */
  connect() {
    // Apply stored theme on connect, default to 'original' (classic look) when none
    const stored = this._getStoredTheme()
    const theme = stored || 'original'
    this._applyTheme(theme)
    if (!stored) this._storeTheme(theme)

    // Close on escape
    this._onKeydown = (e) => {
      if (e.key === 'Escape') this.close()
    }
    document.addEventListener('keydown', this._onKeydown)
  }

  /**
   * Called when the controller is disconnected from the DOM
   * Cleans up event listeners
   * @return {void}
   */
  disconnect() {
    if (this._onKeydown) document.removeEventListener('keydown', this._onKeydown)
  }

  /**
   * Toggles the theme selector panel visibility
   * @param {Event} event - The triggering event
   * @return {void}
   */
  toggle(event) {
    event?.preventDefault()
    this.openValue ? this.close() : this.open()
  }

  /**
   * Opens the theme selector panel
   * @return {void}
   */
  open() {
    this.openValue = true
    this.panelTarget.classList.remove('hidden')
    this.backdropTarget.classList.remove('hidden')
    this._highlightActiveTheme()
  }

  /**
   * Closes the theme selector panel
   * @return {void}
   */
  close() {
    this.openValue = false
    this.panelTarget.classList.add('hidden')
    this.backdropTarget.classList.add('hidden')
  }

  /**
   * Handles theme swatch selection
   * @param {Event} event - The click event with theme param
   * @return {void}
   */
  select(event) {
    const theme = event.params?.theme
    if (!theme) return
    this._applyTheme(theme)
    this._storeTheme(theme)
    this._syncToServer(theme)
    this._highlightActiveTheme()
    this.close()

    // Dispatch an event in case other components want to react
    document.dispatchEvent(new CustomEvent('accent:change', { detail: { theme } }))
  }

  /**
   * Applies the selected theme by updating CSS classes
   * @private
   * @param {string} theme - The theme name to apply
   * @return {void}
   */
  _applyTheme(theme) {
    const root = document.documentElement

    // Remove any previous theme-xxx class
    Array.from(root.classList)
      .filter(c => c.startsWith('theme-'))
      .forEach(c => root.classList.remove(c))

    // Add the new theme class
    root.classList.add(`theme-${theme}`)
    
    // Force browser to recalculate all styles including hover states
    // This ensures all themed elements (buttons, links, etc.) update immediately
    void root.offsetHeight
    
    // Also force repaint on body to catch any lingering elements
    document.body.style.display = 'none'
    void document.body.offsetHeight
    document.body.style.display = ''
  }

  /**
   * Persists theme selection to localStorage
   * @private
   * @param {string} theme - The theme name to store
   * @return {void}
   */
  _storeTheme(theme) {
    try { localStorage.setItem(this.storageKeyValue, theme) } catch (_) {}
  }

  /**
   * Retrieves stored theme from localStorage
   * @private
   * @return {string|null} The stored theme name or null
   */
  _getStoredTheme() {
    try { return localStorage.getItem(this.storageKeyValue) } catch (_) { return null }
  }

  /**
   * Syncs theme preference to server for logged-in users
   * @private
   * @param {string} theme - The theme name to sync
   * @return {void}
   */
  _syncToServer(theme) {
    // Only sync if user appears logged in (check for session indicator)
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    if (!csrfToken) return

    fetch('/account/preferences', {
      method: 'PATCH',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': csrfToken
      },
      body: JSON.stringify({ theme_preference: theme })
    }).catch(() => {}) // Silently fail - localStorage is primary
  }

  /**
   * Highlights the currently active theme button
   * @private
   * @return {void}
   */
  _highlightActiveTheme() {
    const currentTheme = this._getStoredTheme() || 'original'
    
    // Remove active state from all buttons
    this.buttonTargets.forEach(btn => {
      btn.classList.remove('ring-2', 'ring-[var(--accent-500)]')
      btn.setAttribute('aria-pressed', 'false')
    })
    
    // Add active state to current theme button
    const activeButton = this.buttonTargets.find(btn => 
      btn.dataset.themeSelectorThemeParam === currentTheme
    )
    
    if (activeButton) {
      activeButton.classList.add('ring-2', 'ring-[var(--accent-500)]')
      activeButton.setAttribute('aria-pressed', 'true')
    }
  }
}
