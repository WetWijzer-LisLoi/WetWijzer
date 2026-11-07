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
    this._connected = true
    // Apply an already-hydrated preference immediately. If the cache is empty,
    // leave the server-rendered class/default untouched until hydration.
    const stored = prefs.get('theme_accent', null)
    if (stored) {
      const theme = this._canonicalTheme(stored)
      this._applyTheme(theme)
      this._currentTheme = theme
    }

    // prefs.init() hydrates the server cache asynchronously. Re-read after it
    // completes so a full navigation does not reset a logged-in user's accent.
    // A selection made while the GET was in flight remains authoritative in
    // PreferencesStore and is therefore not overwritten here.
    this._hydratePromise = prefs.init().then(() => {
      if (!this._connected) return
      const hydrated = this._canonicalTheme(prefs.get('theme_accent', null))
      this._applyTheme(hydrated)
      this._currentTheme = hydrated
      this._highlightActiveTheme()
    }).catch(() => {})

    // Close on escape
    this._onKeydown = (e) => this.onEscape(e)
    document.addEventListener('keydown', this._onKeydown)
  }

  disconnect() {
    this._connected = false
    if (this._onKeydown) document.removeEventListener('keydown', this._onKeydown)
  }

  // Escape closes an open picker. When the focus was inside it (a colour choice, or the opener itself), it goes back
  // to the opener: it fell to the page (Sol, on live 1.1.25, 09:14:45Z: Enter, Tab to a colour, Escape, focus on
  // BODY). A picker that is closed, or one left by a click elsewhere, leaves the focus where it is.
  onEscape(event) {
    if (event?.key !== 'Escape' || !this.openValue) return
    const inside = this.element.contains(document.activeElement)
    this.close()
    if (!inside) return
    // The opener is the button that toggles the picker. The controller's "button" targets are the colour swatches:
    // 1.1.26 focused the first of them, inside the panel it had just hidden, and the focus fell to the page (Sol, on
    // live 1.1.26, 15:36:13Z).
    const opener = this.element.querySelector('button[data-action*="theme-selector#toggle"]')
    opener?.focus()
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
    const theme = this._canonicalTheme(event.params?.theme)
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

  _canonicalTheme(theme) {
    const candidate = typeof theme === 'string' ? theme : ''
    const allowed = this.buttonTargets.map(btn => btn.dataset.themeSelectorThemeParam)
    return allowed.includes(candidate) ? candidate : 'original'
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
