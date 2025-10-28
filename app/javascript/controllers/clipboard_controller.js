import { Controller } from "@hotwired/stimulus"

// Copy text to clipboard and show a temporary confirmation.
// data-controller="clipboard" on the button
// data-clipboard-text-value="text to copy"
// data-clipboard-success-value="✅ Copied!" (optional feedback text)
export default class extends Controller {
  static values = {
    text: String,
    success: { type: String, default: "✅ Gekopieerd!" }
  }

  copy() {
    navigator.clipboard.writeText(this.textValue)
    const original = this.element.textContent
    this.element.textContent = this.successValue
    setTimeout(() => { this.element.textContent = original }, 2000)
  }
}
