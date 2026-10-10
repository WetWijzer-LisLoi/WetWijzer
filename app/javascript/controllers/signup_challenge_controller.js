import { Controller } from "@hotwired/stimulus"

// WW-ABUSE-01 (ABUSE-05): the registration form. When the server asks for a
// proof of work, the ALTCHA widget solves it on load; until it is solved the
// submit button stays focusable but unavailable (aria-disabled), and each
// step is announced in a polite live region. In every state the form submits
// once: a second press while the first request runs does nothing.
//
// The layout morphs same-URL renders (turbo_refreshes_with :morph), so the
// challenge state arrives inside the form this controller already runs on:
// the widget is followed through its target callbacks, never in connect().
export default class extends Controller {
  static targets = ["widget", "submit", "status"]
  static values = { ready: String, verifying: String, failed: String, expired: String, wait: String }

  initialize() {
    this.solved = true
    this.submitting = false
    this.onStateChange = this.stateChanged.bind(this)
  }

  widgetTargetConnected(widget) {
    this.solved = false
    widget.addEventListener("statechange", this.onStateChange)
    this.setAvailable(false)
  }

  widgetTargetDisconnected(widget) {
    widget.removeEventListener("statechange", this.onStateChange)
    if (this.hasWidgetTarget) return

    this.solved = true
    this.setAvailable(true)
  }

  stateChanged(event) {
    const state = event.detail && event.detail.state
    if (state === "verifying") {
      this.announce(this.verifyingValue)
    } else if (state === "verified") {
      this.solved = true
      this.setAvailable(true)
      this.announce(this.readyValue)
    } else if (state === "expired" || state === "error") {
      this.solved = false
      this.setAvailable(false)
      this.announce(state === "expired" ? this.expiredValue : this.failedValue)
    }
  }

  submit(event) {
    if (this.submitting || !this.solved) {
      event.preventDefault()
      if (!this.solved) this.announce(this.waitValue)
      return
    }
    this.submitting = true
  }

  // Every finished request, including a failed one, frees the form again.
  reset() {
    this.submitting = false
  }

  setAvailable(available) {
    if (!this.hasSubmitTarget) return
    if (available) {
      this.submitTarget.removeAttribute("aria-disabled")
      this.submitTarget.classList.remove("opacity-50", "cursor-not-allowed")
    } else {
      this.submitTarget.setAttribute("aria-disabled", "true")
      this.submitTarget.classList.add("opacity-50", "cursor-not-allowed")
    }
  }

  announce(message) {
    if (this.hasStatusTarget && message) this.statusTarget.textContent = message
  }
}
