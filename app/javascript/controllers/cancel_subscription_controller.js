import { Controller } from "@hotwired/stimulus"

// Handles the cancel subscription show/hide toggle on /subscriptions.
// Replaces inline DOMContentLoaded script that broke under Turbo navigation.
export default class extends Controller {
  static targets = ["showBtn", "dismissBtn", "form"]

  show() {
    this.formTarget.style.display = "block"
    this.showBtnTarget.style.display = "none"
  }

  dismiss() {
    this.formTarget.style.display = "none"
    this.showBtnTarget.style.display = "inline"
  }
}
