import { Controller } from '@hotwired/stimulus'
import { prefs } from '../services/preferences_store.js'

// A judgment's or a parliamentary document's reading width on a large screen
// (owner's request, 2026-11-06, via Sol: at 1,550 px the text used 690 of the
// card's 1,456 px). Wide is the default from 80rem (shared/_reading_styles);
// Comfortable keeps the 80-character measure. The choice is kept as every
// interface preference is (services/preferences_store.js): for a signed-in
// reader on the server ('reading_width', UiPreferenceSchema), for a visitor
// in memory only, never in browser storage. The first 1.1.21 candidate wrote
// localStorage, against that rule and the README (Sol 11:46:57Z).
const KEY = 'reading_width'
const WIDTHS = ['wide', 'comfortable']

export default class extends Controller {
  static targets = ['body', 'control', 'option']

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
    return WIDTHS.includes(stored) ? stored : 'wide'
  }

  choose (event) {
    const width = event.params.width
    if (!WIDTHS.includes(width)) return
    this._chosen = true
    this.apply(width)
    try { prefs.set(KEY, width) } catch (_) { /* the choice holds for this page */ }
  }

  apply (width) {
    this.bodyTargets.forEach(body => { body.dataset.readingWidth = width })
    this.optionTargets.forEach(option => {
      option.setAttribute('aria-pressed', String(option.dataset.readingWidthWidthParam === width))
    })
  }
}
