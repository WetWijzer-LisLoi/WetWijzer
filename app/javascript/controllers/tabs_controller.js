import { Controller } from "@hotwired/stimulus"

// The two states a source tab can be in.
//
// Both are managed here, symmetrically. The controller used to remove only the
// inactive classes and paint the active tab with inline styles, which left two
// problems: the first tab kept its server-rendered active classes after you
// switched away from it, so text-gray-500 and text-(--accent-600) fought over
// it in whatever order Tailwind happened to emit them; and an inline colour
// beats every hover rule, so the active tab could not respond to the pointer
// at all. Classes on both sides fix both.
const ACTIVE = ['border-(--accent-500)', 'text-(--accent-text)', 'dark:text-(--accent-400)']

// The hover here is deliberately the accent, not a lighter grey. In dark the
// theme raises muted text to --text-muted (#d1d5db), which IS gray-300, so the
// old hover target of gray-300 was the colour the tab already had: measured on
// the live site, rgb(209,213,219) -> rgb(209,213,220), one unit out of 255.
const INACTIVE = ['border-transparent', 'text-gray-500', 'hover:text-(--accent-text)',
                  'hover:border-(--accent-400)/60', 'dark:text-gray-400',
                  'dark:hover:text-(--accent-400)', 'dark:hover:border-(--accent-400)/60']

export default class extends Controller {
  static targets = ["tab", "panel"]

  // The chosen tab is kept in this page's own history entry, beside Turbo's restoration data, so Back to the page
  // shows it again (Sol, on live 1.1.21, 20:39:16Z: Back from Recent legislation's View all reopened the first tab).
  // Nothing is stored in the browser beyond that entry, and the address does not change.
  connect() {
    const kept = window.history?.state?.[this.historyKey()]
    this.showPanel(Number.isInteger(kept) && kept >= 0 && kept < this.tabTargets.length ? kept : 0)
  }

  select(event) {
    const index = parseInt(event.currentTarget.dataset.tabIndex, 10)
    this.showPanel(index)
    try {
      window.history.replaceState({ ...(window.history.state || {}), [this.historyKey()]: index }, '')
    } catch (_) { /* the tab still shows; Back then opens the first */ }
  }

  // The tab list as one Tab stop, the arrows moving between tabs and selecting as they go (WAI-ARIA tabs, automatic
  // activation; Sol, on live 1.1.21, 22:06:23Z: every tab was a Tab stop and the arrows did nothing).
  keydown(event) {
    const current = this.tabTargets.findIndex(tab => tab.getAttribute('aria-selected') === 'true')
    const last = this.tabTargets.length - 1
    const next = { ArrowRight: current + 1, ArrowLeft: current - 1, Home: 0, End: last }[event.key]
    if (next === undefined || last < 0) return
    event.preventDefault()
    const index = (next + last + 1) % (last + 1)
    this.select({ currentTarget: this.tabTargets[index] })
    this.tabTargets[index].focus?.()
  }

  historyKey() {
    return `tabs:${this.element.id || 'tabs'}`
  }

  showPanel(index) {
    this.tabTargets.forEach((tab, i) => {
      const on = i === index
      tab.classList.remove(...(on ? INACTIVE : ACTIVE))
      tab.classList.add(...(on ? ACTIVE : INACTIVE))
      tab.setAttribute('aria-selected', on ? 'true' : 'false')
      tab.setAttribute('tabindex', on ? '0' : '-1')
      // Clear the inline styles earlier versions painted, so a page that was
      // rendered before this change does not keep an unhoverable tab.
      tab.style.borderBottomColor = ''
      tab.style.color = ''
    })

    this.panelTargets.forEach((panel, i) => {
      panel.classList.toggle('hidden', i !== index)
    })
  }
}
