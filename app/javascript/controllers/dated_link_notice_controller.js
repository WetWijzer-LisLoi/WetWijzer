import { Controller } from "@hotwired/stimulus"

// A law opened with ?as_of=<day> that this site cannot show as of that day carries a notice above the law
// (laws/_dated_link_notice). A deep link (#art-19) scrolls past it once the articles frame has loaded, so a short
// copy of the notice goes at the top of the linked article, outside its copied text. Listeners are bound here, never through
// data-action: print CSS hides [data-action], and the notice must print.
export default class extends Controller {
  static targets = ["inline"]

  connect() {
    this.frame = document.getElementById("law_articles")
    this.place = this.place.bind(this)
    if (this.frame) this.frame.addEventListener("turbo:frame-load", this.place)
    window.addEventListener("hashchange", this.place)
    this.place()
  }

  disconnect() {
    if (this.frame) this.frame.removeEventListener("turbo:frame-load", this.place)
    window.removeEventListener("hashchange", this.place)
  }

  place() {
    if (!this.hasInlineTarget || !this.frame) return
    let id = String(window.location.hash || "").replace(/^#/, "")
    try { id = decodeURIComponent(id) } catch (_) { /* the id as written */ }
    const target = id && document.getElementById(id)
    if (!target || !this.frame.contains(target)) return
    // Before the article's text row, never inside it: the copy menu copies that row's text (data-source).
    const scope = target.closest("article[data-article-scope]")
    const row = scope && scope.querySelector(":scope > [data-permalink]")
    if (!row) return
    const existing = document.getElementById("dated-link-notice-inline")
    if (existing && existing.nextElementSibling === row) return
    if (existing) existing.remove()
    const note = this.inlineTarget.content.firstElementChild.cloneNode(true)
    note.id = "dated-link-notice-inline"
    row.before(note)
  }
}
