import { Controller } from "@hotwired/stimulus"
import { citationText, displayedText, fragmentUrl, reportCopyFailure, runCopy } from "../utils/article_copy.js"

// The menu of a law's articles (WW-COPY-01; the owner's design, via Sol 2026-11-21 07:00:09Z). The article number
// opens it, by a click, Enter or Space. Opening it, closing it, Escape and History write nothing to the clipboard:
// only a copy item copies, once, the article's link (language_id kept), its text as shown, or its citation text.
// History, shown for an article with history only, opens that article's picker in place through its frame's own
// step link (laws/_history_link). Escape, Tab and a copy put the focus back on the number. One menu serves every
// article; it sits at the page root so it never inherits article markup.
//
// An article is a [data-permalink] row naming its text (data-source): the live law, the dated archive and the
// Fisconet codes. Its number becomes a button here (role, tabindex, aria-haspopup, aria-expanded), on connect and on
// every frame load, so the cached article HTML (CacheVersionHelper::RENDER_CODE_FILES) and the words the copies read
// stay as they were. Until 1.1.84 a click on the number copied the link at once, before the menu opened.
//
// The menu shows the article it is open for (its label) and offers the text and citation only when the article has a
// wording (an archive date can have none). When that article's own frame renders again under it (a step, a period, a
// comparison), the menu stays open and where it is, for the article's new number, so a press already on its way lands
// on the item it was aimed at. In 1.1.86 it closed then, Turbo scrolled to the step's anchor, and on the live Judicial
// Code the press meant for the text copy reached the page instead, opened Art. 21's menu, and the copy took Art. 21
// (Sol 2026-11-21 10:09:36Z and 13:23:21Z). A copy chosen while the article's step is still on its way waits for that
// step and copies the wording the reader switched to, not the one leaving the screen.
const NUMBER = ".article-number"
const ARTICLE = "[data-permalink]"
const MARGIN = 4
// How long such a copy waits for its step. A step that failed, or has not arrived by then, copies nothing and says so.
const STEP_WAIT_MS = 5000
const STEP_ENDS = ["turbo:frame-load", "turbo:fetch-request-error", "turbo:frame-missing"]

export default class extends Controller {
  static targets = ["item", "history", "label", "wording"]
  static values = { linkCopied: String, textCopied: String, citationCopied: String, numberLabel: String }

  connect() {
    this.article = null
    this.trigger = null
    this.focusIndex = -1
    this.stepWaitMs = STEP_WAIT_MS
    // The articles' own frames with a step on its way: from its request until the frame has rendered, or failed.
    this.steps = new WeakSet()
    this.onClick = this.click.bind(this)
    this.onKeydown = this.keydown.bind(this)
    this.onStepStart = event => { if (this.articleFrame(event.target)) this.steps.add(event.target) }
    this.onStepEnd = event => this.steps.delete(event.target)
    this.onBeforeRender = event => {
      if (this.isOpen() && this.trigger && event.target?.contains?.(this.trigger)) {
        this.focusIndex = this.visibleItems().indexOf(document.activeElement)
      }
    }
    this.onFrameLoad = event => {
      this.steps.delete(event.target)
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
    const hit = this.numberAt(event.target)
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

  // The items the article offers, and the article the menu names.
  showItems(number) {
    if (this.hasHistoryTarget) this.historyTarget.hidden = !this.historyLink()
    const wording = Boolean(this.sourceElement())
    this.wordingTargets.forEach(item => { item.hidden = !wording })
    const name = (number.textContent || "").trim()
    this.element.setAttribute("aria-label", name)
    if (this.hasLabelTarget) this.labelTarget.textContent = name
  }

  // Its article's frame rendered again under the open menu: the menu stays open and where it is (see the top), now
  // for the article's new number, with the items its new wording offers and the focus back on the item it was on
  // (Turbo gave it to the step's own autofocus). False when the article itself left the page, as its whole list does
  // on another archive date.
  rebind() {
    const number = this.article?.isConnected ? this.article.querySelector(NUMBER) : null
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

  // The article's picker, opened in place by its frame's own step link; already open, the focus goes to it.
  openHistory() {
    const link = this.historyLink()
    const article = this.article
    this.close()
    if (!link) return
    if (link.getAttribute("aria-expanded") === "true") {
      article.querySelector("[data-history-picker] h4")?.focus()
      return
    }
    link.click()
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
