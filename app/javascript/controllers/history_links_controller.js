import { Controller } from "@hotwired/stimulus"
import { mergedHistoryUrl, requestedHistoryState, settledHistoryUrl } from "../utils/history_links.js"

// One covered article's history frame (laws/_history_frame): before Turbo follows a step link in it (the hidden link
// the article menu's History item follows, or a step in its picker), the link takes the other articles' current
// choices from the address (utils/history_links.js). Bound in the capture phase, before Turbo reads the link on its
// way back up, and here, not through data-action: print CSS hides [data-action], and this frame holds the article's
// text.
//
// Turbo then advances the address with the step's URL, which never carries a fragment (a fetch has none) and may name
// another article's choice from before that article's own quicker step landed (Sol 2026-11-21 06:56:33Z: steps in
// two articles 38 ms apart left the address with the first article's old wording, so a reload changed the screen).
// So once a frame has loaded, the address is rebuilt from what every frame shows (settledHistoryUrl), with the
// fragment of the reader's latest step in any article and Turbo's history state kept; and every frame's step links
// are brought up to date, so copying or opening one gives the choices on the screen. After Close the focus goes back
// to the article's number, the menu's button (data-history-return-focus).
//
// Back and Forward between this law's steps: Turbo restores such an entry from its own record of the page, which a
// step superseded by a quicker one can leave out of step with the address (CI-1.1.84b, 2026-11-21; see also
// utils/turbo_history_repairs.js). So when Back or Forward lands on this law and a frame shows something else than
// the address asks (its row's data-history-state against requestedHistoryState), the page is loaded again from that
// address, which the server renders as asked. A Turbo visit in its place did not always render (half the local runs
// on 2026-11-21 ended with the frames unchanged). A change of the fragment alone leaves every frame as asked, and
// leaving the law stays with Turbo. The law's archive by date (laws/_history_archive_control) stays open through
// both, as the reader left it (Sol 2026-11-21 06:56:33Z: Back closed it). One set of listeners for the page.
const FRAMES = "turbo-frame[data-controller~='history-links']"
const STEPS = "a[data-history-link], a[data-history-step]"
const ARCHIVE = "[data-history-archive] details"
const ARCHIVE_KEY = "ww:history-archive-open"

let shownLaw = null
let pageBound = false
let latestFragment = null
let restoring = false

function keysOf(frame) {
  return (frame.dataset.historyKeys || "").split("|").filter(Boolean)
}

// Every article frame on the page with what it shows.
function shownFrames() {
  return [...document.querySelectorAll(FRAMES)].flatMap(frame => {
    const row = frame.querySelector("[data-history-state]")
    return row ? [{ frame, keys: keysOf(frame), key: row.dataset.historyRow, state: row.dataset.historyState }] : []
  })
}

function refreshStepLinks() {
  const href = window.location.href
  for (const frame of document.querySelectorAll(FRAMES)) {
    const keys = keysOf(frame)
    frame.querySelectorAll(STEPS).forEach(link => { link.href = mergedHistoryUrl(link.href, href, keys) })
  }
}

function revisitStaleFrames() {
  if (window.location.pathname !== shownLaw) return
  const href = window.location.href
  const stale = shownFrames().some(({ keys, state }) => state !== requestedHistoryState(href, keys))
  if (!stale) return
  keepArchiveOpenThroughReload()
  window.location.reload()
}

function keepArchiveOpenThroughReload() {
  try {
    if (document.querySelector(ARCHIVE)?.open) window.sessionStorage.setItem(ARCHIVE_KEY, window.location.pathname)
  } catch (_) { /* storage refused: the archive starts closed */ }
}

function reopenArchiveAfterReload() {
  try {
    if (window.sessionStorage.getItem(ARCHIVE_KEY) !== window.location.pathname) return
    window.sessionStorage.removeItem(ARCHIVE_KEY)
  } catch (_) {
    return
  }
  const details = document.querySelector(ARCHIVE)
  if (details) details.open = true
}

// Turbo's own restoration of an entry of the same law (Back, Forward) renders a new page: the archive keeps its state
// into it. Any other visit (a date, the language) renders the archive as the server sends it.
function noteVisit(event) {
  restoring = event.detail?.action === "restore"
}

function carryArchiveIntoRender(event) {
  if (!restoring || window.location.pathname !== shownLaw || !document.querySelector(ARCHIVE)?.open) return
  const next = event.detail?.newBody?.querySelector(ARCHIVE)
  if (next) next.open = true
}

export default class extends Controller {
  connect() {
    this.merge = this.merge.bind(this)
    this.landed = this.landed.bind(this)
    this.element.addEventListener("click", this.merge, true)
    this.element.addEventListener("turbo:frame-load", this.landed)
    shownLaw = window.location.pathname
    if (!pageBound) {
      window.addEventListener("popstate", revisitStaleFrames)
      document.addEventListener("turbo:visit", noteVisit)
      document.addEventListener("turbo:before-render", carryArchiveIntoRender)
      pageBound = true
    }
    reopenArchiveAfterReload()
  }

  disconnect() {
    this.element.removeEventListener("click", this.merge, true)
    this.element.removeEventListener("turbo:frame-load", this.landed)
  }

  merge(event) {
    const link = event.target.closest(STEPS)
    if (!link || !this.element.contains(link)) return
    link.href = mergedHistoryUrl(link.href, window.location.href, keysOf(this.element))
    latestFragment = new URL(link.href).hash
  }

  landed() {
    const settled = new URL(settledHistoryUrl(window.location.href, shownFrames()))
    const fragment = latestFragment || window.location.hash
    window.history.replaceState(window.history.state, "", `${settled.pathname}${settled.search}${fragment}`)
    refreshStepLinks()
    this.element.querySelector("[data-history-return-focus] .article-number[tabindex]")?.focus()
  }
}
