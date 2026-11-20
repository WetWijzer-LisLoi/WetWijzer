import { Controller } from "@hotwired/stimulus"
import { runCopy } from "../utils/article_copy.js"

// The judgment page's Referentie (V&A) (jurisprudence/_reference): one button holds the citation and its copy icon.
// Clicking it, or Enter or Space on it, copies exactly the citation it shows (the text target), never the heading or
// the icon; the status target, a live region, then says "Gekopieerd" (runCopy also shows its toast). When the
// clipboard refuses, the citation is shown as selectable text (the manual target) and selected for a manual copy.
// The listener is bound here, not through data-action: print CSS hides [data-action], and the reference must print.
export default class extends Controller {
  static targets = ["button", "text", "manual", "status"]
  static values = { copied: String, failed: String }

  connect() {
    this.copy = this.copy.bind(this)
    if (this.hasButtonTarget) this.buttonTarget.addEventListener("click", this.copy)
  }

  disconnect() {
    if (this.hasButtonTarget) this.buttonTarget.removeEventListener("click", this.copy)
    clearTimeout(this.timer)
  }

  async copy(event) {
    event.preventDefault()
    const text = this.textTarget.textContent.replace(/\s+/g, " ").trim()
    const copied = await runCopy(this.buttonTarget, () => text, { copied: this.copiedValue })
    this.announce(copied ? this.copiedValue : this.failedValue)
    if (!copied) this.showManual()
  }

  // A repeated message is announced again: the region is emptied first.
  announce(message) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = ""
    requestAnimationFrame(() => { this.statusTarget.textContent = message })
    clearTimeout(this.timer)
    this.timer = setTimeout(() => { this.statusTarget.textContent = "" }, 5000)
  }

  showManual() {
    if (!this.hasManualTarget) return
    this.manualTarget.hidden = false
    const range = document.createRange()
    range.selectNodeContents(this.manualTarget)
    const selection = window.getSelection()
    selection.removeAllRanges()
    selection.addRange(range)
  }
}
