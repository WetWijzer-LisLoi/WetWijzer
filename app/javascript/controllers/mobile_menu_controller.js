import { Controller } from "@hotwired/stimulus"

/**
 * Mobile Menu Controller
 *
 * Toggles the mobile navigation menu (hamburger menu).
 * On screens < 640px, nav items collapse into a slide-down panel.
 */
export default class extends Controller {
  static targets = ["panel", "openIcon", "closeIcon", "button"]

  connect() {
    // Close menu on escape key
    this.handleEscape = (e) => {
      if (e.key === "Escape" && this.isOpen()) this.close()
    }
    document.addEventListener("keydown", this.handleEscape)
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleEscape)
  }

  toggle() {
    if (this.isOpen()) {
      this.close()
    } else {
      this.open()
    }
  }

  open() {
    this.panelTarget.classList.remove("hidden")
    // Trigger reflow then animate
    requestAnimationFrame(() => {
      this.panelTarget.classList.remove("opacity-0", "-translate-y-2")
      this.panelTarget.classList.add("opacity-100", "translate-y-0")
    })
    if (this.hasOpenIconTarget) this.openIconTarget.classList.add("hidden")
    if (this.hasCloseIconTarget) this.closeIconTarget.classList.remove("hidden")
    // FBL-047: reflect state for assistive tech and move focus into the menu.
    if (this.hasButtonTarget) this.buttonTarget.setAttribute("aria-expanded", "true")
    this.panelTarget.querySelector("a, button")?.focus()
  }

  close() {
    this.panelTarget.classList.add("opacity-0", "-translate-y-2")
    this.panelTarget.classList.remove("opacity-100", "translate-y-0")
    // Wait for animation then hide
    setTimeout(() => {
      this.panelTarget.classList.add("hidden")
    }, 150)
    // FBL-047: reflect state and return focus to the toggle so keyboard
    // users are not dropped at the top of the document.
    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-expanded", "false")
      this.buttonTarget.focus()
    }
    if (this.hasOpenIconTarget) this.openIconTarget.classList.remove("hidden")
    if (this.hasCloseIconTarget) this.closeIconTarget.classList.add("hidden")
  }

  isOpen() {
    return !this.panelTarget.classList.contains("hidden")
  }
}
