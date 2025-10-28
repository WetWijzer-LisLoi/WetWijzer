import { Controller } from "@hotwired/stimulus"

/**
 * TOC Search Controller
 * Provides real-time text filtering for the table of contents sidebar.
 * When the user types in the search box, it hides non-matching TOC entries.
 * While filtering is active, the follow-with-scroll (toc-tracker) is paused
 * to avoid interference. Clearing the filter restores the previous state.
 */
export default class extends Controller {
  static targets = ["input", "list", "clearBtn"]

  connect() {
    this.wasFollowEnabled = null  // track previous state
  }

  filter() {
    const query = (this.inputTarget.value || "").trim().toLowerCase()
    const nav = this.listTarget
    if (!nav) return

    // Show/hide clear button
    if (this.hasClearBtnTarget) {
      this.clearBtnTarget.classList.toggle("hidden", query === "")
    }

    const items = nav.querySelectorAll("li")

    if (query === "") {
      // Show all items and restore follow-with-scroll
      items.forEach(li => { li.style.display = "" })
      this.restoreFollow()
      return
    }

    // Pause follow-with-scroll while filtering
    this.pauseFollow()

    // First pass: hide everything
    items.forEach(li => { li.style.display = "none" })

    // Show only items whose text contains the query
    items.forEach(li => {
      const text = (li.textContent || "").toLowerCase()
      li.style.display = text.includes(query) ? "" : "none"
    })
  }

  clear() {
    this.inputTarget.value = ""
    this.filter()
    this.inputTarget.focus()
  }

  /**
   * Pause the toc-tracker follow behavior so scroll doesn't fight the filter.
   */
  pauseFollow() {
    if (this.wasFollowEnabled !== null) return  // already paused
    const tracker = this.findTocTracker()
    if (tracker) {
      this.wasFollowEnabled = tracker.enabledValue
      if (tracker.enabledValue) {
        tracker.enabledValue = false
        tracker.cleanup()
        try { tracker.syncFollowCheckbox() } catch (_) { /* noop */ }
      }
    }
  }

  /**
   * Restore the toc-tracker to its previous state.
   */
  restoreFollow() {
    if (this.wasFollowEnabled === null) return
    const tracker = this.findTocTracker()
    if (tracker && this.wasFollowEnabled) {
      tracker.enabledValue = true
      tracker.initialized = false
      tracker.initialize()
      try { tracker.syncFollowCheckbox() } catch (_) { /* noop */ }
    }
    this.wasFollowEnabled = null
  }

  findTocTracker() {
    const nav = this.element.querySelector("nav[data-controller='toc-tracker']")
      || this.element.closest("[data-controller*='toc-tracker']")
    if (nav) {
      return this.application.getControllerForElementAndIdentifier(nav, "toc-tracker")
    }
    return null
  }
}
