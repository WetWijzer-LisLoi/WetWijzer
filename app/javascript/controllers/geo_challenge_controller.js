import { Controller } from "@hotwired/stimulus"

// Auto-submits the geo challenge form when the ALTCHA widget is verified.
// Replaces inline DOMContentLoaded script that broke under Turbo navigation.
//
// The widget announces "verified" before it renders its own field, so a
// submit from inside that event carried no proof, and no visitor outside the
// EU could pass (production logs, 2026-10-07: thousands of attempts, none
// verified). The proof travels in the event's detail: it is written into the
// form's own hidden field before the submit. The form submits once, because
// the proof is single-use and a second submission would spend it again.
export default class extends Controller {
  static targets = ["form", "widget"]

  connect() {
    this.submitted = false
    this._onVerified = this._handleVerified.bind(this)
    this.formTarget.addEventListener("statechange", this._onVerified)

    if (this.hasWidgetTarget) {
      this.widgetTarget.addEventListener("statechange", this._onVerified)
    }
  }

  disconnect() {
    this.formTarget.removeEventListener("statechange", this._onVerified)

    if (this.hasWidgetTarget) {
      this.widgetTarget.removeEventListener("statechange", this._onVerified)
    }
  }

  _handleVerified(e) {
    const detail = e.detail || {}
    if (detail.state !== "verified" || !detail.payload || this.submitted) return

    this.submitted = true
    let field = this.formTarget.querySelector('input[type="hidden"][name="altcha"]')
    if (!field) {
      field = document.createElement("input")
      field.type = "hidden"
      field.name = "altcha"
      this.formTarget.appendChild(field)
    }
    field.value = detail.payload
    this.formTarget.submit()
  }
}
