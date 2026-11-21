import { Controller } from "@hotwired/stimulus"
import { citationText, displayedText, fragmentUrl, runCopy } from "../utils/article_copy.js"

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
const NUMBER = ".article-number"
const ARTICLE = "[data-permalink]"
const MARGIN = 4

export default class extends Controller {
  static targets = ["item", "history"]
  static values = { linkCopied: String, textCopied: String, citationCopied: String, numberLabel: String }

  connect() {
    this.article = null
    this.trigger = null
    this.onClick = this.click.bind(this)
    this.onKeydown = this.keydown.bind(this)
    this.onFrameLoad = event => this.enhance(event.target)
    document.addEventListener("click", this.onClick)
    document.addEventListener("keydown", this.onKeydown)
    // Capture: before a history frame's own load listener puts the focus back on its number (history_links).
    document.addEventListener("turbo:frame-load", this.onFrameLoad, true)
    this.enhance(document)
  }

  disconnect() {
    document.removeEventListener("click", this.onClick)
    document.removeEventListener("keydown", this.onKeydown)
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
    if (this.hasHistoryTarget) this.historyTarget.hidden = !this.historyLink()
    this.element.setAttribute("aria-label", (number.textContent || "").trim())
    this.element.classList.remove("hidden")
    this.place(number)
    number.setAttribute("aria-expanded", "true")
    this.visibleItems()[0]?.focus({ preventScroll: true })
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
    this.copyWith(() => fragmentUrl(window.location, this.article?.dataset.permalink), this.linkCopiedValue)
  }

  copyText() {
    this.copyWith(() => displayedText(this.sourceElement()), this.textCopiedValue)
  }

  copyCitation() {
    this.copyWith(() => citationText(this.sourceElement()), this.citationCopiedValue)
  }

  // The text is taken and written within the reader's press (runCopy reads it before its first await).
  copyWith(produce, copied) {
    runCopy(null, produce, { copied })
    this.close({ focus: true })
  }

  sourceElement() {
    const source = this.article?.dataset.source
    if (!source) return null
    try {
      return document.querySelector(source)
    } catch (_) {
      return null
    }
  }
}
