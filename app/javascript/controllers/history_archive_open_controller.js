import { Controller } from "@hotwired/stimulus"

// Tekst → History (the owner, via Sol 2026-11-21 07:01:30Z): the law's archive by date, near the top of the page
// (laws/_history_archive_control, the details named by aria-controls), opened where it stands, with the focus in its
// date field. There is one date form: this button only opens it, and says whether it is open (aria-expanded). An
// article's own history is in that article's menu (article_copy_menu_controller.js).
export default class extends Controller {
  connect() {
    this.sync = this.sync.bind(this)
    this.details = this.archive()
    this.details?.addEventListener("toggle", this.sync)
    this.sync()
  }

  disconnect() {
    this.details?.removeEventListener("toggle", this.sync)
  }

  archive() {
    return document.getElementById(this.element.getAttribute("aria-controls") || "")
  }

  sync() {
    this.element.setAttribute("aria-expanded", String(Boolean(this.details?.open)))
  }

  open(event) {
    event.preventDefault()
    if (!this.details?.isConnected) {
      this.details?.removeEventListener("toggle", this.sync)
      this.details = this.archive()
      this.details?.addEventListener("toggle", this.sync)
    }
    const details = this.details
    if (!details) return
    details.open = true
    this.sync()
    details.scrollIntoView({ block: "center" })
    const field = details.querySelector('input[name="as_of"]') || details.querySelector("summary")
    field?.focus({ preventScroll: true })
  }
}
