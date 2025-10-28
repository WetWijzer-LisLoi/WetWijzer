/**
 * Server-side Preferences Store
 * Replaces ALL localStorage/sessionStorage usage across the application.
 *
 * GDPR compliance:
 * - Anonymous users: preferences kept in-memory only (lost on page navigation)
 * - Logged-in users: preferences saved to server via /api/preferences
 * - Zero localStorage/sessionStorage usage = zero browser trace for anonymous visitors
 *
 * Usage:
 *   import { prefs } from '../services/preferences_store'
 *
 *   // Read (sync from cache, async from server)
 *   const theme = prefs.get('theme', 'light')
 *
 *   // Write (saves to server for logged-in users)
 *   prefs.set('theme', 'dark')
 *
 *   // Nested keys
 *   prefs.set('chatbot.intelligence', 'genius')
 *   const level = prefs.get('chatbot.intelligence', 'smart')
 *
 *   // Bulk update
 *   prefs.merge({ theme: 'dark', sidebar_collapsed: true })
 *
 *   // Initialize on page load (fetches from server if logged in)
 *   await prefs.init()
 */

class PreferencesStore {
  constructor() {
    this._cache = {}
    this._initialized = false
    this._saveTimer = null
    this._dirty = {}
    this._loggedIn = null
  }

  /**
   * Initialize: load preferences from server if logged in.
   * Call once on page load (e.g., in application.js or the first Stimulus controller).
   */
  async init() {
    if (this._initialized) return this._cache
    // Deduplicate concurrent init() calls: cache the in-flight promise
    if (this._initPromise) return this._initPromise
    this._initPromise = this._doInit()
    return this._initPromise
  }

  async _doInit() {
    // Check if user is logged in via DOM metadata
    this._loggedIn = this._checkLoggedIn()

    if (this._loggedIn) {
      try {
        const response = await fetch('/api/preferences', {
          credentials: 'same-origin',
          headers: { 'Accept': 'application/json' }
        })
        if (response.ok) {
          const data = await response.json()
          this._cache = data.preferences || {}
        }
      } catch (e) {
        console.warn('[PreferencesStore] Failed to load preferences:', e.message)
      }
    }

    this._initialized = true

    // Flush pending saves when the user navigates away or closes the tab.
    // pagehide fires reliably on tab close; visibilitychange on tab switch.
    if (this._loggedIn && !this._unloadBound) {
      this._unloadBound = true
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'hidden') this._flushSync()
      })
      window.addEventListener('pagehide', () => this._flushSync())
    }

    return this._cache
  }

  /**
   * Get a preference value. Supports dot-notation for nested keys.
   * Returns from in-memory cache (sync). Call init() first for server data.
   */
  get(key, defaultValue = null) {
    if (key.includes('.')) {
      const parts = key.split('.')
      let obj = this._cache
      for (const part of parts) {
        if (obj == null || typeof obj !== 'object') return defaultValue
        obj = obj[part]
      }
      return obj !== undefined ? obj : defaultValue
    }
    const val = this._cache[key]
    return val !== undefined ? val : defaultValue
  }

  /**
   * Set a preference value. Supports dot-notation for nested keys.
   * Auto-saves to server (debounced) for logged-in users.
   */
  set(key, value) {
    if (key.includes('.')) {
      const parts = key.split('.')
      let obj = this._cache
      for (let i = 0; i < parts.length - 1; i++) {
        if (obj[parts[i]] == null || typeof obj[parts[i]] !== 'object') {
          obj[parts[i]] = {}
        }
        obj = obj[parts[i]]
      }
      obj[parts[parts.length - 1]] = value
      // Track the top-level key as dirty
      this._dirty[parts[0]] = this._cache[parts[0]]
    } else {
      this._cache[key] = value
      this._dirty[key] = value
    }

    this._scheduleSave()
  }

  /**
   * Merge multiple preferences at once.
   */
  merge(updates) {
    Object.assign(this._cache, updates)
    Object.assign(this._dirty, updates)
    this._scheduleSave()
  }

  /**
   * Remove a preference key.
   */
  remove(key) {
    delete this._cache[key]
    this._dirty[key] = null
    this._scheduleSave()
  }

  /**
   * Get all preferences (shallow copy).
   */
  all() {
    return { ...this._cache }
  }

  /**
   * Check if user is logged in.
   */
  isLoggedIn() {
    if (this._loggedIn === null) {
      this._loggedIn = this._checkLoggedIn()
    }
    return this._loggedIn
  }

  // ── Internal ──

  _checkLoggedIn() {
    // Check multiple indicators
    const authEl = document.getElementById('chatbot-auth-state')
    if (authEl?.dataset?.loggedIn === 'true') return true

    // Check for user-nav or account menu
    const userNav = document.querySelector('[data-user-logged-in]')
    if (userNav) return true

    // Check meta tag
    const meta = document.querySelector('meta[name="user-logged-in"]')
    if (meta?.content === 'true') return true

    // Check if logout link exists
    const logoutLink = document.querySelector('a[href="/logout"]')
    if (logoutLink) return true

    return false
  }

  _scheduleSave() {
    if (!this._loggedIn) return // Anonymous: in-memory only
    if (this._saveTimer) clearTimeout(this._saveTimer)

    // Debounce: save after 500ms of inactivity (batches rapid changes)
    this._saveTimer = setTimeout(() => this._flush(), 500)
  }

  async _flush() {
    if (Object.keys(this._dirty).length === 0) return
    if (!this._loggedIn) return

    const toSave = { ...this._dirty }
    this._dirty = {}

    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      await fetch('/api/preferences', {
        method: 'PATCH',
        credentials: 'same-origin',
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          ...(csrfToken ? { 'X-CSRF-Token': csrfToken } : {})
        },
        body: JSON.stringify({ preferences: toSave })
      })
    } catch (e) {
      // Re-queue failed saves
      Object.assign(this._dirty, toSave)
      console.warn('[PreferencesStore] Save failed, will retry:', e.message)
    }
  }

  /**
   * Synchronous flush for page unload scenarios.
   * Uses fetch with keepalive:true so the request completes even during
   * page teardown (supported in all modern browsers).
   */
  _flushSync() {
    if (Object.keys(this._dirty).length === 0) return
    if (!this._loggedIn) return

    // Cancel any pending debounce timer
    if (this._saveTimer) {
      clearTimeout(this._saveTimer)
      this._saveTimer = null
    }

    const toSave = { ...this._dirty }
    this._dirty = {}

    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      fetch('/api/preferences', {
        method: 'PATCH',
        credentials: 'same-origin',
        keepalive: true,  // Ensures request completes even during page unload
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          ...(csrfToken ? { 'X-CSRF-Token': csrfToken } : {})
        },
        body: JSON.stringify({ preferences: toSave })
      })
    } catch (e) {
      // Re-queue if fetch setup fails (extremely rare)
      Object.assign(this._dirty, toSave)
    }
  }
}

// Singleton instance - shared across all controllers
const prefs = new PreferencesStore()

export { prefs, PreferencesStore }
export default prefs
