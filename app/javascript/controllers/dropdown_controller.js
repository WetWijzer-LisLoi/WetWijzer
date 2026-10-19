import { Controller } from "@hotwired/stimulus"

// Dropdown controller for menus.
//
// FBL-047 keyboard contract: Escape closes and returns focus to the button;
// ArrowDown/ArrowUp move through the items (wrapping), Home/End jump to the
// first/last item; opening focuses the first item. aria-expanded always
// mirrors the visible state.
export default class extends Controller {
  static targets = ["button", "menu", "arrow"]
  static values = { viewportFit: Boolean }

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
    if (this.viewportFitValue) {
      this.fitMenuToViewport()
      this.items()[0]?.focus({ preventScroll: true })
    } else {
      this.items()[0]?.focus()
    }
  }

  // Article menus opt in: stay below near the viewport top, but
  // avoid a clipped menu or the phone's fixed bottom bar near the bottom.
  // Other dropdowns keep their existing positioning and focus behavior.
  fitMenuToViewport() {
    const menu = this.menuTarget
    const properties = ["top", "bottom", "marginTop", "marginBottom", "maxHeight", "overflowY"]
    this.viewportMenuStyles ||= Object.fromEntries(properties.map((property) => [property, menu.style[property] || ""]))
    properties.forEach((property) => { menu.style[property] = this.viewportMenuStyles[property] })

    const button = this.buttonTarget.getBoundingClientRect()
    const menuBox = menu.getBoundingClientRect()
    const parsedGap = Number.parseFloat(window.getComputedStyle(menu).marginTop)
    const gap = Number.isFinite(parsedGap) ? Math.max(0, parsedGap) : 4
    const padding = 8
    let usableBottom = window.innerHeight - padding
    const bar = document.getElementById("mobile-bottom-bar")
    if (bar) {
      const style = window.getComputedStyle(bar)
      const box = bar.getBoundingClientRect()
      if (style.display !== "none" && style.visibility !== "hidden" && box.width > 0 && box.height > 0) {
        usableBottom = Math.min(usableBottom, box.top - padding)
      }
    }

    // Measure the rendered lower edge anchor, including the wrapper's line
    // box and CSS gap rather than assuming it equals the button's bottom.
    const below = Math.max(0, usableBottom - menuBox.top)
    // bottom: 100% opens above the positioned ancestor, which can start a
    // whole toolbar row above a wrapped trigger. Never count that row as
    // available space, or a menu that "fits" above can still cross the top.
    const parentTop = menu.offsetParent?.getBoundingClientRect?.().top
    const aboveAnchor = Number.isFinite(parentTop) ? Math.min(button.top, parentTop) : button.top
    const above = Math.max(0, aboveAnchor - gap - padding)
    const fitsBelow = menuBox.height <= below
    const fitsAbove = menuBox.height <= above
    const openAbove = !fitsBelow && (fitsAbove || above > below)
    if (openAbove) {
      menu.style.top = "auto"
      menu.style.bottom = "100%"
      menu.style.marginTop = "0px"
      menu.style.marginBottom = `${gap}px`
    }
    if (!fitsBelow && !fitsAbove) {
      menu.style.maxHeight = `${openAbove ? above : below}px`
      menu.style.overflowY = "auto"
    }
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
