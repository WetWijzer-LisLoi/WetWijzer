import { Controller } from "@hotwired/stimulus"
import { mergedHistoryUrl, requestedHistoryState } from "../utils/history_links.js"

// One covered article's history frame (laws/_history_frame): before Turbo follows a step link in it (the history
// icon or a step in its picker), the link takes the other articles' current choices from the address
// (utils/history_links.js), so changing one article after another keeps both. Bound in the capture phase, before
// Turbo reads the link on its way back up, and here, not through data-action: print CSS hides [data-action], and
// this frame holds the article's text.
//
// Turbo then advances the address with the frame's response URL, which never carries a fragment (a fetch has none):
// once the frame has loaded, the step's own fragment (#art-20) is put back, with Turbo's history state kept, so the
// address names the article again and a shared link opens at it.
//
// Back and Forward between this law's steps: Turbo restores such an entry from its own record of the page, which a
// step superseded by a quicker one can leave out of step with the address (CI-1.1.84b, 2026-11-21: after Back the
// address named the older wording and the page still showed the way back's, in about half the local runs; see also
// utils/turbo_history_repairs.js). So when Back or Forward lands on this law and a frame shows something else than
// the address asks (its row's data-history-state against requestedHistoryState), the page is loaded again from that
// address, which the server renders as asked. A Turbo visit in its place did not always render (half the local runs
// on 2026-11-21 ended with the frames unchanged). A change of the fragment alone (the contents, an anchor) leaves
// every frame as asked, and leaving the law stays with Turbo. One listener for the page.
let shownLaw = null
let popBound = false

function revisitStaleFrames() {
  if (window.location.pathname !== shownLaw) return
  const href = window.location.href
  const stale = [...document.querySelectorAll("turbo-frame[data-controller~='history-links']")].some(frame => {
    const row = frame.querySelector("[data-history-state]")
    if (!row) return false
    const keys = (frame.dataset.historyKeys || "").split("|").filter(Boolean)
    return row.dataset.historyState !== requestedHistoryState(href, keys)
  })
  if (stale) window.location.reload()
}

export default class extends Controller {
  connect() {
    this.merge = this.merge.bind(this)
    this.restoreFragment = this.restoreFragment.bind(this)
    this.element.addEventListener("click", this.merge, true)
    this.element.addEventListener("turbo:frame-load", this.restoreFragment)
    shownLaw = window.location.pathname
    if (!popBound) {
      window.addEventListener("popstate", revisitStaleFrames)
      popBound = true
    }
  }

  disconnect() {
    this.element.removeEventListener("click", this.merge, true)
    this.element.removeEventListener("turbo:frame-load", this.restoreFragment)
  }

  merge(event) {
    const link = event.target.closest("a[data-history-link], a[data-history-step]")
    if (!link || !this.element.contains(link)) return
    const own = (this.element.dataset.historyKeys || "").split("|").filter(Boolean)
    link.href = mergedHistoryUrl(link.href, window.location.href, own)
    this.fragment = new URL(link.href).hash
  }

  restoreFragment() {
    const fragment = this.fragment
    this.fragment = null
    if (!fragment || window.location.hash === fragment) return
    const { pathname, search } = window.location
    window.history.replaceState(window.history.state, "", `${pathname}${search}${fragment}`)
  }
}
