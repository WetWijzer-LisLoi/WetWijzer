import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "toggleBtn"]

  connect() {
    // Check if there are active filters, if so show on mobile too
    const hasActiveFilters = this.element.querySelector('select option:checked:not([value=""])') ||
                            this.element.querySelector('input[type="date"]:not([value=""])')
    if (hasActiveFilters) {
      this.show()
    }
  }

  toggle() {
    if (this.contentTarget.classList.contains('hidden')) {
      this.show()
    } else {
      this.hide()
    }
  }

  show() {
    this.contentTarget.classList.remove('hidden')
    this.contentTarget.classList.add('block')
  }

  hide() {
    this.contentTarget.classList.add('hidden')
    this.contentTarget.classList.remove('block')
  }
}
