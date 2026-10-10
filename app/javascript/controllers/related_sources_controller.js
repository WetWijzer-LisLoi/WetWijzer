import { Controller } from "@hotwired/stimulus"

// WW-LINK-03: the related-source buttons of a law page and a Fisconet page.
// Without scripts each button submits an ordinary GET form to the full
// related-sources page. With scripts each is a disclosure button: the first
// activation loads its panel in place, later ones show or hide it without a
// second request. aria-expanded and aria-controls say what the button does,
// and a polite status reports loading, success and failure. The button is
// never disabled while it loads, which would throw keyboard focus to the
// page; a failed request leaves the panel closed and the next activation
// tries again.
export default class extends Controller {
  static targets = ["button", "panel", "status"]
  static values = { url: String, loading: String, failed: String }

  connect() {
    this.pending = new Set()
    this.buttonTargets.forEach((button) => {
      const panel = this.panelFor(button)
      button.setAttribute("aria-expanded", panel && !panel.hidden ? "true" : "false")
    })
  }

  toggle(event) {
    event.preventDefault()
    const button = event.currentTarget
    const panel = this.panelFor(button)
    if (!panel) return

    if (panel.dataset.loaded === "true") {
      this.announce("")
      this.show(button, panel, panel.hidden)
    } else {
      this.load(button, panel, event.params)
    }
  }

  async load(button, panel, { type, loaded }) {
    if (this.pending.has(type)) return

    this.pending.add(type)
    button.setAttribute("aria-busy", "true")
    this.announce(this.loadingValue)
    try {
      const url = new URL(this.urlValue, window.location.href)
      url.searchParams.set("type", type)
      const response = await fetch(url, { headers: { Accept: "text/html" } })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)

      panel.innerHTML = await response.text()
      panel.dataset.loaded = "true"
      this.show(button, panel, true)
      this.announce(loaded)
    } catch {
      this.show(button, panel, false)
      this.announce(this.failedValue)
    } finally {
      this.pending.delete(type)
      button.removeAttribute("aria-busy")
    }
  }

  show(button, panel, open) {
    panel.hidden = !open
    button.setAttribute("aria-expanded", open ? "true" : "false")
  }

  announce(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text || ""
  }

  panelFor(button) {
    const id = button.getAttribute("aria-controls")
    return this.panelTargets.find((panel) => panel.id === id)
  }
}
