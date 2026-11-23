import { Controller } from "@hotwired/stimulus"
import { citationText, displayedText, fragmentUrl, reportCopyFailure, runCopy } from "../utils/article_copy.js"

// The menu of a law's articles (WW-COPY-01; the owner's design, via Sol 2026-11-21 07:00:09Z). The article number
// opens it, by a click, Enter or Space. Opening it, closing it, Escape and History write nothing to the clipboard:
// only a copy item copies, once, the article's link (language_id kept), its text as shown, or its citation text.
// History, shown for an article with history only, opens that article's panel in place through its frame's own
// step link (laws/_history_link), and closes it when it is open (the owner, via Sol 2026-11-23 04:35:31Z): the item
// carries the link's state as aria-expanded. Escape, Tab and a copy put the focus back on the number. One menu serves
// every article; it sits at the page root so it never inherits article markup.
//
// An article is a [data-permalink] row naming its text (data-source): the live law, the dated archive and the
// Fisconet codes. Its number becomes a button here (role, tabindex, aria-haspopup, aria-expanded), on connect and on
// every frame load, so the cached article HTML (CacheVersionHelper::RENDER_CODE_FILES) and the words the copies read
// stay as they were. Until 1.1.84 a click on the number copied the link at once, before the menu opened.
//
// The menu is named for the article it is open for (its accessible name; the visible caption went in 1.1.88, the owner
// via Sol 2026-11-21 16:40:11Z) and offers the text and citation only when the article has a wording (an archive date
// can have none). When that article's own frame renders again under it (a step, a period, a comparison), the menu stays
// open and where it is, for the article's new number, so a press already on its way lands on the item it was aimed at.
// In 1.1.86 it closed then, Turbo scrolled to the step's anchor, and on the live Judicial Code the press meant for the
// text copy reached the page instead, opened Art. 21's menu, and the copy took Art. 21 (Sol 2026-11-21 10:09:36Z and
// 13:23:21Z). A copy chosen while the article's step is still on its way waits for that step and copies the wording the
// reader switched to, not the one leaving the screen.
//
// The new wording can also move the number itself: on the live Judicial Code, Older from 021 to 006 shrank the picker
// above Art. 20 and moved its number up 40 px, so a press on the number made during the swap landed on the text and no
// menu opened (Sol 2026-11-21 16:24:50Z). Where the number stood just before its frame rendered again is kept, and a
// press on that spot during the swap, or just after it, opens that article's menu for its new number.
const NUMBER = ".article-number"
const ARTICLE = "[data-permalink]"
const MARGIN = 4
// How long such a copy waits for its step. A step that failed, or has not arrived by then, copies nothing and says so.
const STEP_WAIT_MS = 5000
const STEP_ENDS = ["turbo:frame-load", "turbo:fetch-request-error", "turbo:frame-missing"]
// How long after its frame loaded a press on a number's previous spot still counts as aimed at it, the longest a swap
// in progress keeps that spot, and the number's own hit area around it (the ::after in application.scss).
const SWAP_GRACE_MS = 400
const SWAP_LONGEST_MS = 3000
const HIT_X = 4
const HIT_Y = 6
// A press on one of these is the reader's own choice, never a press meant for the number that stood there.
const OWN_CONTROLS = 'a, button, input, select, textarea, summary, label, [role="button"], [role="menuitem"]'

export default class extends Controller {
  static targets = ["item", "history", "wording"]
  static values = { linkCopied: String, textCopied: String, citationCopied: String, numberLabel: String }

  connect() {
    this.article = null
    this.trigger = null
    this.focusIndex = -1
    this.stepWaitMs = STEP_WAIT_MS
    // The articles' own frames with a step on its way: from its request until the frame has rendered, or failed.
    this.steps = new WeakSet()
    // Per article whose frame is rendering again: where its number stood before, and until when a press there counts.
    this.swaps = new Map()
    this.onClick = this.click.bind(this)
    this.onKeydown = this.keydown.bind(this)
    this.onStepStart = event => { if (this.articleFrame(event.target)) this.steps.add(event.target) }
    this.onStepEnd = event => this.steps.delete(event.target)
    this.onBeforeRender = event => {
      this.noteSwap(event.target)
      if (this.isOpen() && this.trigger && event.target?.contains?.(this.trigger)) {
        this.focusIndex = this.visibleItems().indexOf(document.activeElement)
      }
    }
    this.onFrameLoad = event => {
      this.steps.delete(event.target)
      this.settleSwap(event.target)
      this.enhance(event.target)
      if (this.isOpen() && this.trigger && !this.trigger.isConnected && !this.rebind()) this.close()
    }
    document.addEventListener("click", this.onClick)
    document.addEventListener("keydown", this.onKeydown)
    document.addEventListener("turbo:before-fetch-request", this.onStepStart, true)
    document.addEventListener("turbo:fetch-request-error", this.onStepEnd, true)
    document.addEventListener("turbo:frame-missing", this.onStepEnd, true)
    document.addEventListener("turbo:before-frame-render", this.onBeforeRender, true)
    // Capture: before a history frame's own load listener puts the focus back on its number (history_links).
    document.addEventListener("turbo:frame-load", this.onFrameLoad, true)
    // A kept spot is a place on the screen: any scroll (the page's or a box's) or resize makes it another place.
    this.onScroll = () => this.forgetSwaps()
    document.addEventListener("scroll", this.onScroll, true)
    window.addEventListener?.("resize", this.onScroll)
    this.enhance(document)
  }

  disconnect() {
    document.removeEventListener("click", this.onClick)
    document.removeEventListener("keydown", this.onKeydown)
    document.removeEventListener("turbo:before-fetch-request", this.onStepStart, true)
    document.removeEventListener("turbo:fetch-request-error", this.onStepEnd, true)
    document.removeEventListener("turbo:frame-missing", this.onStepEnd, true)
    document.removeEventListener("turbo:before-frame-render", this.onBeforeRender, true)
    document.removeEventListener("turbo:frame-load", this.onFrameLoad, true)
    document.removeEventListener("scroll", this.onScroll, true)
    window.removeEventListener?.("resize", this.onScroll)
  }

  enhance(root) {
    if (!root?.querySelectorAll) return
    root.querySelectorAll(`${ARTICLE} ${NUMBER}`).forEach(number => {
      if (number.getAttribute("role") === "button") return
      number.setAttribute("role", "button")
      number.setAttribute("tabindex", "0")
      number.setAttribute("aria-haspopup", "menu")
      number.setAttribute("aria-expanded", "false")
      if (this.numberLabelValue) number.setAttribute("title", this.numberLabelValue)
    })
  }

  // The number and its article row under an event target, or null.
  numberAt(target) {
    const number = target?.closest?.(NUMBER)
    const article = number?.closest(ARTICLE)
    return article && number.closest("[data-article-scope]") ? { number, article } : null
  }

  click(event) {
    const hit = this.numberAt(event.target) || this.swappedNumberAt(event)
    if (hit) {
      event.preventDefault()
      if (this.isOpen() && this.trigger === hit.number) this.close()
      else this.open(hit.number, hit.article)
      return
    }
    if (this.isOpen() && !this.element.contains(event.target)) this.close()
  }

  keydown(event) {
    if (this.isOpen() && this.menuKey(event)) return
    if (event.key !== "Enter" && event.key !== " ") return
    const hit = this.numberAt(event.target)
    if (!hit || event.target !== hit.number) return
    event.preventDefault()
    this.open(hit.number, hit.article)
  }

  // Escape anywhere closes; inside the menu the arrows, Home and End move between its items, and Tab leaves it at
  // the number (the menu sits at the end of the page, so the next Tab goes on from the article).
  menuKey(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      this.close({ focus: true })
      return true
    }
    if (!this.element.contains(event.target)) return false
    const items = this.visibleItems()
    const index = items.indexOf(document.activeElement)
    const moves = {
      ArrowDown: () => items[(index + 1) % items.length],
      ArrowUp: () => items[(index - 1 + items.length) % items.length],
      Home: () => items[0],
      End: () => items[items.length - 1]
    }
    if (moves[event.key]) {
      event.preventDefault()
      moves[event.key]()?.focus()
      return true
    }
    if (event.key === "Tab") {
      event.preventDefault()
      this.close({ focus: true })
      return true
    }
    return false
  }

  open(number, article) {
    if (this.isOpen()) this.close()
    this.trigger = number
    this.article = article
    this.showItems(number)
    this.element.classList.remove("hidden")
    this.place(number)
    number.setAttribute("aria-expanded", "true")
    this.visibleItems()[0]?.focus({ preventScroll: true })
  }

  // The items the article offers, and the article the menu is named for.
  showItems(number) {
    if (this.hasHistoryTarget) {
      const link = this.historyLink()
      this.historyTarget.hidden = !link
      if (link) this.historyTarget.setAttribute("aria-expanded", String(link.getAttribute("aria-expanded") === "true"))
      else this.historyTarget.removeAttribute("aria-expanded")
    }
    const wording = Boolean(this.sourceElement())
    this.wordingTargets.forEach(item => { item.hidden = !wording })
    this.element.setAttribute("aria-label", (number.textContent || "").trim())
  }

  // Its article's frame rendered again under the open menu: the menu stays open and where it is (see the top), now
  // for the article's new number, with the items its new wording offers and the focus back on the item it was on
  // (Turbo gave it to the step's own autofocus). False when the article itself left the page, as its whole list does
  // on another archive date.
  rebind() {
    const number = this.article?.isConnected ? this.visibleNumber(this.article) : null
    const focusIndex = this.focusIndex
    this.focusIndex = -1
    if (!number) return false
    this.trigger = number
    number.setAttribute("aria-expanded", "true")
    this.showItems(number)
    const items = this.visibleItems()
    if (focusIndex >= 0 && items.length) items[Math.min(focusIndex, items.length - 1)].focus({ preventScroll: true })
    return true
  }

  // An article's number as shown: a comparison keeps the chosen wording, with its own number, hidden for the copy.
  visibleNumber(article) {
    const numbers = Array.from(article.querySelectorAll(NUMBER))
    return numbers.find(number => !number.closest("[hidden]")) || numbers[0] || null
  }

  // Its frame is about to render again: where the article's number stands now, which a press during the swap may
  // still aim at (see the top). Kept until the frame loads plus SWAP_GRACE_MS, and never longer than SWAP_LONGEST_MS;
  // any scroll or resize drops every kept spot, since the spot is a place on the screen (Sol 2026-11-21 17:19:12Z).
  noteSwap(frame) {
    const article = this.articleFrame(frame) ? frame.closest(ARTICLE) : null
    const number = article && this.visibleNumber(article)
    const rect = number?.getBoundingClientRect()
    if (!rect || !(rect.width > 0 && rect.height > 0)) return
    this.swaps.set(article, { rect, until: this.now() + SWAP_LONGEST_MS })
  }

  // Its frame has loaded: the spot counts SWAP_GRACE_MS longer, never past the time it was first given.
  settleSwap(frame) {
    const swap = this.swaps.get(frame?.closest?.(ARTICLE))
    if (swap) swap.until = Math.min(swap.until, this.now() + SWAP_GRACE_MS)
  }

  forgetSwaps() {
    this.swaps.clear()
  }

  // The article whose number stood under this press until its frame rendered again, with its number now. Only a press
  // inside that same article counts, so another article's text or a place outside every article never opens it; a
  // press that matches more than one kept spot is declined. Null as well for a press on a control of its own, inside
  // the menu, outside every kept spot, or after its time.
  swappedNumberAt(event) {
    if (!this.swaps.size || !Number.isFinite(event.clientX) || !Number.isFinite(event.clientY)) return null
    if (this.element.contains(event.target) || event.target?.closest?.(OWN_CONTROLS)) return null
    const pressed = event.target?.closest?.(ARTICLE)
    const now = this.now()
    const matches = []
    for (const [article, swap] of this.swaps) {
      if (!article.isConnected || now > swap.until) {
        this.swaps.delete(article)
        continue
      }
      const { left, right, top, bottom } = swap.rect
      if (event.clientX < left - HIT_X || event.clientX > right + HIT_X) continue
      if (event.clientY < top - HIT_Y || event.clientY > bottom + HIT_Y) continue
      matches.push(article)
    }
    if (matches.length !== 1 || matches[0] !== pressed) return null
    const number = this.visibleNumber(pressed)
    return number ? { number, article: pressed } : null
  }

  now() {
    return globalThis.performance?.now?.() ?? Date.now()
  }

  // Below the number, or above it when the screen ends first; never past either side of the screen.
  place(number) {
    const rect = number.getBoundingClientRect()
    const width = this.element.offsetWidth
    const height = this.element.offsetHeight
    const below = rect.bottom + MARGIN
    const top = below + height > window.innerHeight && rect.top - MARGIN - height >= 0 ? rect.top - MARGIN - height : below
    const left = Math.max(MARGIN, Math.min(rect.left, window.innerWidth - width - MARGIN))
    this.element.style.top = `${top}px`
    this.element.style.left = `${left}px`
  }

  close({ focus = false } = {}) {
    const trigger = this.trigger
    this.element.classList.add("hidden")
    this.trigger = null
    if (!trigger) return
    trigger.setAttribute("aria-expanded", "false")
    if (focus && trigger.isConnected) trigger.focus({ preventScroll: true })
  }

  isOpen() {
    return !this.element.classList.contains("hidden")
  }

  visibleItems() {
    return this.itemTargets.filter(item => !item.hidden)
  }

  historyLink() {
    return this.article?.querySelector("a[data-history-link]") || null
  }

  // The article's history panel, opened in place by its frame's own step link, or closed by it when it is open:
  // the link's step is the opposite of what the frame shows (laws/_history_link). The frame then takes the focus
  // without scrolling: the panel's heading after opening, the article's number after closing (history_links).
  openHistory() {
    const link = this.historyLink()
    this.close()
    link?.click()
  }

  copyLink() {
    this.copyWith(article => fragmentUrl(window.location, article?.dataset.permalink), this.linkCopiedValue)
  }

  copyText() {
    this.copyWith(article => displayedText(this.sourceOf(article)), this.textCopiedValue)
  }

  copyCitation() {
    this.copyWith(article => citationText(this.sourceOf(article)), this.citationCopiedValue)
  }

  // The text is taken and written within the reader's press (runCopy reads it before its first await), unless the
  // article's own step is still on its way: then the copy waits for that step, takes the wording the reader switched
  // to and puts the focus on the article's new number. Either way it is the article the menu named at the press.
  copyWith(produce, copied) {
    const article = this.article
    const step = this.pendingStep(article)
    if (!step) {
      runCopy(null, () => produce(article), { copied })
      this.close({ focus: true })
      return
    }
    this.close()
    this.afterStep(step, () => {
      runCopy(null, () => produce(article), { copied })
      article.querySelector(NUMBER)?.focus({ preventScroll: true })
    })
  }

  // A frame inside an article (its history frame), or null; the law's own frames are not an article's step.
  articleFrame(target) {
    return target?.matches?.("turbo-frame") && target.closest(ARTICLE) ? target : null
  }

  pendingStep(article) {
    const frame = article?.querySelector("turbo-frame")
    return frame && this.steps.has(frame) ? frame : null
  }

  // `then` runs once the step's frame has rendered, after the frame's own load listeners have settled the address;
  // a failed step, or one not there within stepWaitMs, copies nothing and the reader is told.
  afterStep(frame, then) {
    let timer = null
    const finish = event => {
      clearTimeout(timer)
      STEP_ENDS.forEach(name => frame.removeEventListener(name, finish))
      if (event?.type === "turbo:frame-load") setTimeout(then, 0)
      else reportCopyFailure()
    }
    STEP_ENDS.forEach(name => frame.addEventListener(name, finish))
    timer = setTimeout(finish, this.stepWaitMs)
  }

  sourceElement() {
    return this.sourceOf(this.article)
  }

  sourceOf(article) {
    const source = article?.dataset.source
    if (!source) return null
    try {
      return document.querySelector(source)
    } catch (_) {
      return null
    }
  }
}
