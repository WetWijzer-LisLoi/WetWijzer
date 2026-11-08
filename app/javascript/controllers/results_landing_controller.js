import { Controller } from "@hotwired/stimulus"

// A source's own pager on the combined results (judgments 1-50 to 51-100) replaces the results frame, and Turbo
// leaves the window where it was: the reader stayed near the end of the new page and had to scroll back to its start
// (Sol, on live 1.1.28, 22:54:14Z). The section whose pager was used is brought back into view once the new page has
// loaded, its heading under the fixed header (scroll-mt), and the focus goes to that heading so a keyboard reader
// starts there too. The other sections and their pages are left as they are.
export default class extends Controller {
  connect () {
    this.pending = null
    this.onClick = (event) => this.remember(event)
    this.onLoad = () => this.land()
    this.element.addEventListener('click', this.onClick)
    this.element.addEventListener('turbo:frame-load', this.onLoad)
  }

  disconnect () {
    this.element.removeEventListener('click', this.onClick)
    this.element.removeEventListener('turbo:frame-load', this.onLoad)
  }

  remember (event) {
    const link = event.target?.closest?.('a[href]')
    const section = link?.closest?.('[data-results-section]')
    this.pending = link && section && link.closest('nav') ? section.dataset.resultsSection : null
  }

  land () {
    const key = this.pending
    this.pending = null
    if (!key) return
    const section = this.element.querySelector(`[data-results-section="${key}"]`)
    if (!section) return
    section.scrollIntoView({ block: 'start' })
    section.querySelector('summary')?.focus({ preventScroll: true })
  }
}
