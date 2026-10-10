/**
 * Server-side Preferences Store
 * Replaces localStorage/sessionStorage for user-interface preferences.
 *
 * GDPR compliance:
 * - Anonymous users: preferences kept in-memory only (lost on page navigation)
 * - Logged-in users: preferences saved to server via /api/preferences
 * - This store itself never writes browser persistence for anonymous visitors.
 *   Separate, documented exceptions exist for the PWA install prompt/offline
 *   shell and the ciphertext-only zero-knowledge retry outbox.
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
    this._revisions = {}
    this._nextRevision = 0
    this._preInitChanges = {}
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
    this._seedServerThemes()

    // Bind navigation/unload flushing as soon as auth is known, before the
    // preferences GET. A fast Turbo visit must not outrun hydration and drop
    // a selection made during that request.
    if (this._loggedIn && !this._unloadBound) {
      this._unloadBound = true
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'hidden') this._flushSync()
      })
      window.addEventListener('pagehide', () => this._flushSync())
      document.addEventListener('turbo:before-visit', () => this._flushSync())
    }

    if (this._loggedIn) {
      try {
        const response = await fetch('/api/preferences', {
          credentials: 'same-origin',
          headers: { 'Accept': 'application/json' }
        })
        if (response.ok) {
          const data = await response.json()
          // A controller may have written a choice while this GET was in
          // flight. Keep those local values authoritative; otherwise the
          // late response would visibly undo the user's choice.
          this._cache = { ...(data.preferences || {}) }
        }
      } catch (e) {
        console.warn('[PreferencesStore] Failed to load preferences:', e.message)
      }
    }

    // Apply local edits after either a successful or failed GET. This keeps a
    // choice made during hydration authoritative, including over server-seeded
    // values in the document metadata.
    for (const [key, change] of Object.entries(this._preInitChanges)) {
      this._applyPath(key, change.value, change.removed)
    }

    this._initialized = true
    this._preInitChanges = {}

    // A set can happen before _doInit discovers that the visitor is logged in.
    // Do not lose that pending write merely because _loggedIn was still null.
    if (this._loggedIn && Object.keys(this._dirty).length > 0) this._scheduleSave()

    // Flush pending saves when the user navigates away or closes the tab.
    // pagehide fires reliably on tab close; visibilitychange on tab switch.
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
    const dirtyKey = key.includes('.') ? key.split('.')[0] : key
    const revision = ++this._nextRevision
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
    this._revisions[dirtyKey] = revision
    if (!this._initialized) this._preInitChanges[key] = { value, removed: false }

    this._scheduleSave()
  }

  /**
   * Merge multiple preferences at once.
   */
  merge(updates) {
    Object.entries(updates).forEach(([key, value]) => this.set(key, value))
  }

  /**
   * Remove a preference key.
   */
  remove(key) {
    const revision = ++this._nextRevision
    delete this._cache[key]
    this._dirty[key] = null
    this._revisions[key] = revision
    if (!this._initialized) this._preInitChanges[key] = { value: null, removed: true }
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

  _seedServerThemes() {
    if (!this._loggedIn) return
    const meta = document.querySelector('meta[name="theme-preferences"]')
    if (!meta?.content) return
    try {
      const parsed = JSON.parse(meta.content)
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return
      if (typeof parsed.theme_accent === 'string' && parsed.theme_accent.length > 0) {
        this._cache.theme_accent = parsed.theme_accent
      }
      if (['light', 'dark', 'system'].includes(parsed.theme)) this._cache.theme = parsed.theme
    } catch (_) {
      // Invalid metadata is ignored; the API remains the source of truth.
    }
  }

  _applyPath(key, value, removed = false) {
    const parts = key.split('.')
    let obj = this._cache
    for (let i = 0; i < parts.length - 1; i++) {
      if (obj[parts[i]] == null || typeof obj[parts[i]] !== 'object') obj[parts[i]] = {}
      obj = obj[parts[i]]
    }
    if (removed) delete obj[parts[parts.length - 1]]
    else obj[parts[parts.length - 1]] = value
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
    const revisions = Object.fromEntries(Object.keys(toSave).map(key => [key, this._revisions[key]]))
    this._dirty = {}

    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      const response = await fetch('/api/preferences', {
        method: 'PATCH',
        credentials: 'same-origin',
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          ...(csrfToken ? { 'X-CSRF-Token': csrfToken } : {})
        },
        body: JSON.stringify({ preferences: toSave })
      })
      if (!response.ok) {
        // Keep newer values already written since this flush; restore only
        // keys that still have the failed value. A failed response must never
        // be treated as persisted, but retries are left to a later flush.
        for (const [key, value] of Object.entries(toSave)) {
          if (this._revisions[key] === revisions[key]) this._dirty[key] = value
        }
      } else {
        for (const key of Object.keys(toSave)) {
          if (this._revisions[key] === revisions[key]) delete this._dirty[key]
        }
      }
    } catch (e) {
      // Re-queue failed saves
      for (const [key, value] of Object.entries(toSave)) {
        if (this._revisions[key] === revisions[key]) this._dirty[key] = value
      }
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
    const revisions = Object.fromEntries(Object.keys(toSave).map(key => [key, this._revisions[key]]))

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
      }).then(response => {
        if (!response.ok) return
        for (const key of Object.keys(toSave)) {
          if (this._revisions[key] === revisions[key]) delete this._dirty[key]
        }
      }).catch(() => {})
    } catch (e) {
      // Re-queue if fetch setup fails (extremely rare)
      for (const [key, value] of Object.entries(toSave)) {
        if (this._revisions[key] === revisions[key]) this._dirty[key] = value
      }
    }
  }
}

// Singleton instance - shared across all controllers
const prefs = new PreferencesStore()

export { prefs, PreferencesStore }
export default prefs
