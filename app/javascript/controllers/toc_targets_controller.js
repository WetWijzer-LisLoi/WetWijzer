import { Controller } from "@hotwired/stimulus"
import { planTocTargets } from "../utils/toc_targets"

// WW-UI-02: once the article frame has loaded, points every contents link at
// an element of it (planTocTargets). A link whose target the body does not
// have keeps its label as plain text: no href, so it is neither focusable nor
// announced as a link. The original href stays in data-toc-original-href, so
// an old deep link to it still finds its new target (toc-anchor).
export default class extends Controller {
  static values = { frame: { type: String, default: "law_articles" } }

  connect() {
    this.reconcile = this.reconcile.bind(this)
    document.addEventListener("turbo:frame-load", this.reconcile)
    if (this.frame?.hasAttribute("complete")) this.reconcile()
  }

  disconnect() {
    document.removeEventListener("turbo:frame-load", this.reconcile)
  }

  get frame() {
    return document.getElementById(this.frameValue)
  }

  reconcile(event) {
    const frame = this.frame
    if (!frame || (event && event.target !== frame)) return

    const links = Array.from(this.element.querySelectorAll('a[href^="#"]'))
    if (links.length === 0) return

    const ids = links.map((link) => decodeURIComponent(link.getAttribute("href").slice(1)))
    const bodyIds = Array.from(frame.querySelectorAll("[id]"), (element) => element.id)
    planTocTargets(ids, bodyIds).forEach((target, index) => {
      if (target === ids[index]) return

      const link = links[index]
      link.dataset.tocOriginalHref = link.getAttribute("href")
      if (target) {
        link.setAttribute("href", `#${target}`)
        if (link.hasAttribute("data-target")) link.setAttribute("data-target", target)
      } else {
        link.removeAttribute("href")
        link.removeAttribute("data-target")
        link.removeAttribute("data-toc-tracker-target")
        link.classList.add("pointer-events-none", "text-gray-500", "dark:text-gray-400")
      }
    })
  }
}
