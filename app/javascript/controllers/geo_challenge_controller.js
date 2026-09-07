import { Controller } from "@hotwired/stimulus"

// Auto-submits the geo challenge form when the ALTCHA widget is verified.
// Replaces inline DOMContentLoaded script that broke under Turbo navigation.
export default class extends Controller {
  static targets = ["form", "widget"]

  connect() {
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
    if (e.detail && e.detail.state === "verified") {
      this.formTarget.submit()
    }
  }
}
