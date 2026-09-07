import { Controller } from "@hotwired/stimulus"

// Dropdown controller for menus.
//
// FBL-047 keyboard contract: Escape closes and returns focus to the button;
// ArrowDown/ArrowUp move through the items (wrapping), Home/End jump to the
// first/last item; opening focuses the first item. aria-expanded always
// mirrors the visible state.
export default class extends Controller {
  static targets = ["button", "menu", "arrow"]

  connect() {
    // Close dropdown when clicking outside
    this.clickOutsideHandler = this.clickOutside.bind(this)
    document.addEventListener("click", this.clickOutsideHandler)
    this.keydownHandler = this.handleKeydown.bind(this)
    this.element.addEventListener("keydown", this.keydownHandler)
  }

  disconnect() {
    document.removeEventListener("click", this.clickOutsideHandler)
    this.element.removeEventListener("keydown", this.keydownHandler)
  }

  toggle(event) {
    event.stopPropagation()
    const isHidden = this.menuTarget.classList.contains("hidden")

    if (isHidden) {
      this.open()
    } else {
      this.close()
    }
  }

  open() {
    this.menuTarget.classList.remove("hidden")
    this.buttonTarget.setAttribute("aria-expanded", "true")
    if (this.hasArrowTarget) {
      this.arrowTarget.classList.add("rotate-180")
    }
    this.items()[0]?.focus()
  }

  close({ restoreFocus = false } = {}) {
    this.menuTarget.classList.add("hidden")
    this.buttonTarget.setAttribute("aria-expanded", "false")
    if (this.hasArrowTarget) {
      this.arrowTarget.classList.remove("rotate-180")
    }
    if (restoreFocus) this.buttonTarget.focus()
  }

  clickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.close()
    }
  }

  handleKeydown(event) {
    if (this.menuTarget.classList.contains("hidden")) return

    const items = this.items()
    const index = items.indexOf(document.activeElement)

    switch (event.key) {
      case "Escape":
        event.preventDefault()
        this.close({ restoreFocus: true })
        break
      case "ArrowDown":
        event.preventDefault()
        items[(index + 1) % items.length]?.focus()
        break
      case "ArrowUp":
        event.preventDefault()
        items[(index - 1 + items.length) % items.length]?.focus()
        break
      case "Home":
        event.preventDefault()
        items[0]?.focus()
        break
      case "End":
        event.preventDefault()
        items[items.length - 1]?.focus()
        break
    }
  }

  items() {
    return Array.from(
      this.menuTarget.querySelectorAll("a[href], button:not([disabled])")
    ).filter((el) => el.offsetParent !== null)
  }
}
