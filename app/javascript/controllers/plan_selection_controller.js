import { Controller } from "@hotwired/stimulus"

// Handles Free vs Pro plan card selection on the registration page.
export default class extends Controller {
  static targets = [
    "field", "intervalField",
    "proCard", "freeCard", "proCheck", "proSelected",
    "freeRadio", "proRadio"
  ]

  connect() {
    this._updateUI()
  }

  selectFree() {
    this.fieldTarget.value = "free"
    this._updateUI()
  }

  selectPro() {
    // Toggle: if already pro, switch back to free
    this.fieldTarget.value = this.fieldTarget.value === "pro" ? "free" : "pro"
    this._updateUI()
  }

  _updateUI() {
    const isPro = this.fieldTarget.value === "pro"

    // Pro card visual state
    if (isPro) {
      this.proCardTarget.classList.add("ring-2", "ring-(--accent-500)", "shadow-xl")
      this.proCardTarget.classList.remove("shadow-lg")
      this.proCheckTarget.classList.remove("hidden")
      this.proCheckTarget.classList.add("flex")
      this._slideDown(this.proSelectedTarget)
    } else {
      this.proCardTarget.classList.remove("ring-2", "ring-(--accent-500)", "shadow-xl")
      this.proCardTarget.classList.add("shadow-lg")
      this.proCheckTarget.classList.add("hidden")
      this.proCheckTarget.classList.remove("flex")
      this._slideUp(this.proSelectedTarget)
    }

    // Free card visual state
    if (this.hasFreeCardTarget) {
      if (isPro) {
        this.freeCardTarget.classList.remove("border-green-300", "dark:border-green-700")
        this.freeCardTarget.classList.add("border-gray-200", "dark:border-gray-700", "opacity-60")
      } else {
        this.freeCardTarget.classList.add("border-green-300", "dark:border-green-700")
        this.freeCardTarget.classList.remove("border-gray-200", "dark:border-gray-700", "opacity-60")
      }
    }

    // Radio indicators
    if (this.hasFreeRadioTarget) {
      this.freeRadioTarget.innerHTML = isPro
        ? ''
        : '<div class="w-2.5 h-2.5 rounded-full bg-green-500"></div>'
      this.freeRadioTarget.classList.toggle("border-green-400", !isPro)
      this.freeRadioTarget.classList.toggle("dark:border-green-500", !isPro)
      this.freeRadioTarget.classList.toggle("border-gray-300", isPro)
      this.freeRadioTarget.classList.toggle("dark:border-gray-500", isPro)
    }
    if (this.hasProRadioTarget) {
      this.proRadioTarget.innerHTML = isPro
        ? `<div class="w-2.5 h-2.5 rounded-full" style="background: var(--accent-600-solid, #2563eb)"></div>`
        : ''
      this.proRadioTarget.classList.toggle("border-gray-300", !isPro)
      this.proRadioTarget.classList.toggle("dark:border-gray-500", !isPro)
    }
  }

  _slideDown(el) {
    el.style.maxHeight = el.scrollHeight + 'px'
    el.style.opacity = '1'
  }

  _slideUp(el) {
    el.style.maxHeight = '0'
    el.style.opacity = '0'
  }
}
