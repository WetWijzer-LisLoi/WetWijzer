import { Controller } from "@hotwired/stimulus"
import { mergedHistoryUrl, noteHistoryStep, requestedHistoryState, settledHistoryUrl } from "../utils/history_links.js"
import { keepFragmentRestorationsInPlace } from "../utils/turbo_history_repairs.js"

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
// fragment and the step (history_focus) of the reader's latest step in any article and Turbo's history state kept; and
// every frame's step links
// are brought up to date, so copying or opening one gives the choices on the screen. After Close the focus goes back
// to the article's number, the menu's button (data-history-return-focus); after any other step it goes to the step
// just taken or the panel's heading (data-history-autofocus). Neither scrolls the page, and the step is noted so that
// the page's turbo:load handlers leave the page where it is too (utils/history_links.js, noteHistoryStep): the
// article's number and the panel stay in place at every step (the owner, via Sol 2026-11-23 04:31:08Z).
//
// Back and Forward between this law's steps: Turbo restores such an entry from its own record of the page, which a
// step superseded by a quicker one can leave out of step with the address (CI-1.1.84b, 2026-11-21; see also
// utils/turbo_history_repairs.js). So when Back or Forward lands on this law and a frame shows something else than
// the address asks (its row's data-history-state against requestedHistoryState), the page is loaded again from that
// address, which the server renders as asked. A Turbo visit in its place did not always render (half the local runs
// on 2026-11-21 ended with the frames unchanged). A Back or Forward that changes the fragment alone (an anchor, the
// contents) keeps the page as it is: its frames are the entry's own, and with two pickers open the address names only
// one (Sol 2026-11-21 10:09:36Z: 1.1.85 reloaded the page). Turbo, which would fetch the address and render the page
// again for it, keeps the page too (utils/turbo_history_repairs.js, keepFragmentRestorationsInPlace); its popstate
// listener runs before this one, so it compares with the address shown before the Back. Leaving the law stays with
// Turbo. The law's archive by date (laws/_history_archive_control) stays open through
// both, as the reader left it (Sol 2026-11-21 06:56:33Z: Back closed it). One set of listeners for the page.
const FRAMES = "turbo-frame[data-controller~='history-links']"
const STEPS = "a[data-history-link], a[data-history-step]"
const ARCHIVE = "[data-history-archive] details"
const ARCHIVE_KEY = "ww:history-archive-open"

let shownLaw = null
let pageBound = false
let latestFragment = null
let latestFocus = null
// The frame of the reader's latest step: only its landing may move the focus (see focusAfterStep)
let latestStepFrame = null
let shownSearch = null
let connectedFrames = 0
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

// The same law and query as the page on screen, with its article frames still there: a page Turbo rendered in its place
// (another page, another law) leaves no frames, and leaving the law clears shownLaw (Sol 2026-11-21 10:58:04Z: Back
// from another page to the law's address kept the other page on screen).
function fragmentOnly(location) {
  return shownLaw !== null && location.pathname === shownLaw && location.search === shownSearch &&
    document.querySelector(FRAMES) !== null
}

function revisitStaleFrames() {
  if (window.location.pathname !== shownLaw) return
  const sameAddress = fragmentOnly(window.location)
  shownSearch = window.location.search
  if (sameAddress) return
  const href = window.location.href
  const stale = shownFrames().some(({ keys, state }) => state !== requestedHistoryState(href, keys))
  if (!stale) return
  // Turbo has begun restoring this entry itself (its listener runs first); a render of it before the reload lands
  // would let that page take the note keeping the archive open, so the reloaded page found none.
  window.Turbo?.session?.navigator?.stop?.()
  keepArchiveOpenThroughReload()
  window.location.reload()
}

function keepArchiveOpenThroughReload() {
  try {
    if (document.querySelector(ARCHIVE)?.open) window.sessionStorage.setItem(ARCHIVE_KEY, window.location.pathname)
  } catch (_) { /* storage refused: the archive starts closed */ }
}

// Only the page the reload brings takes the note, never a page Turbo rendered before it.
function loadedByReload() {
  try {
    return window.performance.getEntriesByType("navigation")[0]?.type === "reload"
  } catch (_) {
    return true
  }
}

function reopenArchiveAfterReload() {
  if (!loadedByReload()) return
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
    connectedFrames += 1
    this.merge = this.merge.bind(this)
    this.landed = this.landed.bind(this)
    this.element.addEventListener("click", this.merge, true)
    this.element.addEventListener("turbo:frame-load", this.landed)
    shownLaw = window.location.pathname
    shownSearch = window.location.search
    if (!pageBound) {
      window.addEventListener("popstate", revisitStaleFrames)
      keepFragmentRestorationsInPlace(window.Turbo, fragmentOnly)
      document.addEventListener("turbo:visit", noteVisit)
      document.addEventListener("turbo:before-render", carryArchiveIntoRender)
      pageBound = true
    }
    reopenArchiveAfterReload()
    // A page loaded with a panel open (a shared link, a reload): the focus the autofocus attribute used to give
    this.element.querySelector("[data-history-autofocus]")?.focus({ preventScroll: true })
  }

  disconnect() {
    this.element.removeEventListener("click", this.merge, true)
    this.element.removeEventListener("turbo:frame-load", this.landed)
    connectedFrames = Math.max(0, connectedFrames - 1)
    if (connectedFrames === 0) {
      shownLaw = null
      shownSearch = null
    }
  }

  merge(event) {
    const link = event.target.closest(STEPS)
    if (!link || !this.element.contains(link)) return
    link.href = mergedHistoryUrl(link.href, window.location.href, keysOf(this.element))
    const step = new URL(link.href)
    latestFragment = step.hash
    latestFocus = step.searchParams.get("history_focus")
    latestStepFrame = this.element
  }

  landed() {
    noteHistoryStep(this.element.src)
    const settled = new URL(settledHistoryUrl(window.location.href, shownFrames(), latestFocus))
    const fragment = latestFragment || window.location.hash
    window.history.replaceState(window.history.state, "", `${settled.pathname}${settled.search}${fragment}`)
    shownSearch = settled.search
    refreshStepLinks()
    this.focusAfterStep()
  }

  // The focus moves only to the frame of the reader's latest step, and only while the reader's focus is not elsewhere
  // (Sol 2026-11-23 10:08:33Z: a slower step in one article must not take the focus from a later choice in another,
  // nor from where the reader has tabbed): on nothing, inside this frame (the step pressed, now replaced), or on the
  // article menu's History item once the menu has closed (it closes before it follows the step). While the menu is
  // open it keeps the focus (article_copy_menu_controller.js, rebind).
  focusAfterStep() {
    if (latestStepFrame && latestStepFrame !== this.element) return
    const active = document.activeElement
    const menu = active?.closest?.("[data-controller~='article-copy-menu']")
    if (menu && !menu.classList.contains("hidden")) return
    const free = !active || active === document.body || active === document.documentElement || this.element.contains(active) ||
      Boolean(menu)
    if (!free) return
    const target = this.element.querySelector("[data-history-return-focus] .article-number[tabindex]") ||
      this.element.querySelector("[data-history-autofocus]")
    target?.focus({ preventScroll: true })
  }
}
