import { Controller } from '@hotwired/stimulus'
import { prefs } from '../services/preferences_store.js'

// The reading width of a judgment, a parliamentary document and a law's text
// (owner's requirement of 2026-11-07, via Sol 08:17:34Z): Full screen (the
// card's full width), Wide (64rem) or Comfortable (80 characters), centred
// (shared/_reading_styles). Full is the width when nothing is saved; a saved
// choice stands. The choice is one preference for every reader, kept as every
// interface preference is (services/preferences_store.js): for a signed-in
// reader on the server ('reading_width', UiPreferenceSchema), so it comes back
// on every reader and after a reload; for a visitor in memory only, never in
// browser storage. The first 1.1.21 candidate wrote localStorage, against that
// rule and the README (Sol 11:46:57Z).
const KEY = 'reading_width'
const WIDTHS = ['full', 'wide', 'comfortable']
const DEFAULT_WIDTH = 'full'

export default class extends Controller {
  // head: the heading row above a judgment's or parliamentary document's text,
  // which takes the same measure (Sol 06:57:39Z).
  static targets = ['body', 'head', 'control', 'option']

  connect () {
    this._connected = true
    this._chosen = false
    this.apply(this.storedWidth())
    if (this.hasControlTarget) this.controlTarget.hidden = false
    // The server's value arrives after the first paint; a choice made in the
    // meantime stands.
    Promise.resolve()
      .then(() => prefs.init())
      .then(() => { if (this._connected && !this._chosen) this.apply(this.storedWidth()) })
      .catch(() => {})
  }

  disconnect () {
    this._connected = false
  }

  storedWidth () {
    let stored = null
    try { stored = prefs.get(KEY, null) } catch (_) { stored = null }
    return WIDTHS.includes(stored) ? stored : DEFAULT_WIDTH
  }

  choose (event) {
    const width = event.params.width
    if (!WIDTHS.includes(width)) return
    this._chosen = true
    this.apply(width)
    try { prefs.set(KEY, width) } catch (_) { /* the choice holds for this page */ }
  }

  apply (width) {
    ;[...this.bodyTargets, ...(this.headTargets || [])].forEach(node => { node.dataset.readingWidth = width })
    this.optionTargets.forEach(option => {
      option.setAttribute('aria-pressed', String(option.dataset.readingWidthWidthParam === width))
    })
  }
}
