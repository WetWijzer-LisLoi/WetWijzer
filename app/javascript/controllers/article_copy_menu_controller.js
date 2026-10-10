import { Controller } from "@hotwired/stimulus"
import { citationText, displayedText, fragmentUrl, runCopy } from "../utils/article_copy.js"

// The copy menu of a Justel law's articles (WW-COPY-01). A click on an
// article number copies that article's link at once and opens this menu
// beside the number: its link, its text as shown, or its citation text. One
// menu serves every article; it sits at the page root so it never inherits
// article markup. This replaces two inline scripts that each kept their own
// copy logic: the menu's link dropped language_id, the number's link reported
// a failed copy as copied, and both added a document listener on every visit.
export default class extends Controller {
  static values = { linkCopied: String, textCopied: String, citationCopied: String }

  connect() {
    this.permalink = null
    this.source = null
    this.onClick = this.click.bind(this)
    document.addEventListener("click", this.onClick)
  }

  disconnect() {
    document.removeEventListener("click", this.onClick)
  }

  click(event) {
    const number = event.target.closest?.(".article-number")
    const scope = number?.closest("[data-article-scope]")
    if (scope) {
      const permalink = permalinkOf(scope)
      if (permalink) runCopy(number, () => fragmentUrl(window.location, permalink), { copied: this.linkCopiedValue })
      const article = number.closest("[data-permalink]")
      if (article) {
        event.preventDefault()
        this.open(number, article)
        return
      }
    }
    if (!this.element.contains(event.target)) this.close()
  }

  open(number, article) {
    this.permalink = article.dataset.permalink
    this.source = article.dataset.source
    const rect = number.getBoundingClientRect()
    this.element.style.top = `${rect.bottom + 4}px`
    this.element.style.left = `${rect.left}px`
    this.element.classList.remove("hidden")
  }

  close() {
    this.element.classList.add("hidden")
  }

  copyLink() {
    this.copyWith(() => fragmentUrl(window.location, this.permalink), this.linkCopiedValue)
  }

  copyText() {
    this.copyWith(() => displayedText(this.sourceElement()), this.textCopiedValue)
  }

  copyCitation() {
    this.copyWith(() => citationText(this.sourceElement()), this.citationCopiedValue)
  }

  copyWith(produce, copied) {
    runCopy(null, produce, { copied })
    this.close()
  }

  sourceElement() {
    if (!this.source) return null
    try {
      return document.querySelector(this.source)
    } catch (_) {
      return null
    }
  }
}

// An article's permalink, else the id or heading anchor of its scope.
function permalinkOf(scope) {
  return scope.querySelector("[data-permalink]")?.dataset.permalink || scope.id ||
    scope.dataset.sectionHeading || null
}
