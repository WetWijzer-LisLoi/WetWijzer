import { Controller } from "@hotwired/stimulus"
import { prefs } from "../services/preferences_store"

/**
 * Theme Selector Controller
 * @class ThemeSelectorController
 * @extends Controller
 * 
 * Provides a popup interface with selectable theme swatches for accent color customization.
 * Persists user selection in server-side profile (no localStorage).
 * Works in conjunction with the dark-mode controller for comprehensive theming.
 *
 * Privacy: Zero browser storage. Anonymous visitors get default theme on each visit.
 */
export default class extends Controller {
  static targets = ["panel", "backdrop", "button"]
  
  static values = {
    storageKey: { type: String, default: 'theme-accent' },
    open: { type: Boolean, default: false }
  }

  connect() {
    // Apply stored theme on connect, default to 'original' (classic look) when none
    const stored = prefs.get('theme_accent', null)
    const theme = stored || 'original'
    this._applyTheme(theme)
    this._currentTheme = theme

    // Close on escape
    this._onKeydown = (e) => {
      if (e.key === 'Escape') this.close()
    }
    document.addEventListener('keydown', this._onKeydown)
  }

  disconnect() {
    if (this._onKeydown) document.removeEventListener('keydown', this._onKeydown)
  }

  toggle(event) {
    event?.preventDefault()
    this.openValue ? this.close() : this.open()
  }

  open() {
    this.openValue = true
    this.panelTarget.classList.remove('hidden')
    this.backdropTarget.classList.remove('hidden')
    this._highlightActiveTheme()
  }

  close() {
    this.openValue = false
    this.panelTarget.classList.add('hidden')
    this.backdropTarget.classList.add('hidden')
  }

  select(event) {
    const theme = event.params?.theme
    if (!theme) return
    this._applyTheme(theme)
    this._currentTheme = theme
    prefs.set('theme_accent', theme)
    this._highlightActiveTheme()
    this.close()

    // Dispatch an event in case other components want to react
    document.dispatchEvent(new CustomEvent('accent:change', { detail: { theme } }))
  }

  _applyTheme(theme) {
    const root = document.documentElement

    // Remove any previous theme-xxx class
    Array.from(root.classList)
      .filter(c => c.startsWith('theme-'))
      .forEach(c => root.classList.remove(c))

    // Add the new theme class
    root.classList.add(`theme-${theme}`)
    
    // Force browser to recalculate all styles including hover states
    void root.offsetHeight
    
    // Also force repaint on body to catch any lingering elements
    document.body.style.display = 'none'
    void document.body.offsetHeight
    document.body.style.display = ''
  }

  _highlightActiveTheme() {
    const currentTheme = this._currentTheme || 'original'
    
    // Remove active state from all buttons
    this.buttonTargets.forEach(btn => {
      btn.classList.remove('ring-2', 'ring-(--accent-500)')
      btn.setAttribute('aria-pressed', 'false')
    })
    
    // Add active state to current theme button
    const activeButton = this.buttonTargets.find(btn => 
      btn.dataset.themeSelectorThemeParam === currentTheme
    )
    
    if (activeButton) {
      activeButton.classList.add('ring-2', 'ring-(--accent-500)')
      activeButton.setAttribute('aria-pressed', 'true')
    }
  }
}
