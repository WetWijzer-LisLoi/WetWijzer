import { Controller } from "@hotwired/stimulus"

// Unified Search UX Enhancement (Product Evolution Target #3)
// Handles tab-based source filtering, search highlights, and keyboard navigation
export default class extends Controller {
  static targets = ["tabButton", "tabPanel", "resultItem", "searchInput", "resultCount"]
  static values = {
    activeTab: { type: String, default: "all" },
    focusIndex: { type: Number, default: -1 }
  }

  connect() {
    this.boundKeyHandler = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.boundKeyHandler)
    // Totals belong to the server search, not to the twenty cards loaded for
    // each source. Never replace them with the number of cards on this page.
    this.tabButtonTargets.forEach(btn => {
      btn.setAttribute("tabindex", btn.dataset.tab === this.activeTabValue ? "0" : "-1")
    })
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundKeyHandler)
  }

  // Tab switching
  switchTab(event) {
    const tab = event.currentTarget.dataset.tab
    this.activeTabValue = tab

    // Update tab button states (FBL-047: roving tabindex - only the active
    // tab is in the tab order; arrows move between them).
    this.tabButtonTargets.forEach(btn => {
      const isActive = btn.dataset.tab === tab
      btn.classList.toggle("unified-search__tab--active", isActive)
      btn.setAttribute("aria-selected", isActive)
      btn.setAttribute("tabindex", isActive ? "0" : "-1")
    })

    // Show/hide panels
    this.tabPanelTargets.forEach(panel => {
      const shouldShow = tab === "all" || panel.dataset.source === tab
      panel.classList.toggle("hidden", !shouldShow)
      panel.setAttribute("aria-hidden", !shouldShow)
    })

    // Reset focus index
    this.focusIndexValue = -1
    // These controls are real links. Their normal navigation preserves the
    // source tab and page in the URL and works without JavaScript as well.
  }

  // FBL-047: WAI-ARIA tablist keyboard contract on the tab buttons.
  tablistKeydown(event) {
    const tabs = this.tabButtonTargets
    const index = tabs.indexOf(event.currentTarget)
    let next = null
    switch (event.key) {
      case "ArrowRight": next = tabs[(index + 1) % tabs.length]; break
      case "ArrowLeft": next = tabs[(index - 1 + tabs.length) % tabs.length]; break
      case "Home": next = tabs[0]; break
      case "End": next = tabs[tabs.length - 1]; break
      default: return
    }
    event.preventDefault()
    next.focus()
    next.click()
  }

  // Keyboard navigation
  handleKeydown(event) {
    if (event.defaultPrevented || event.ctrlKey || event.altKey || event.metaKey) return
    // Only handle when search page is focused
    const active = document.activeElement
    if ((["INPUT", "TEXTAREA", "SELECT"].includes(active?.tagName) || active?.isContentEditable) && event.key !== "Escape") {
      return
    }

    const visibleResults = this.getVisibleResults()

    switch (event.key) {
      case "j": // Next result
        event.preventDefault()
        this.focusIndexValue = Math.min(this.focusIndexValue + 1, visibleResults.length - 1)
        this.highlightResult(visibleResults)
        break
      case "k": // Previous result
        event.preventDefault()
        this.focusIndexValue = Math.max(this.focusIndexValue - 1, 0)
        this.highlightResult(visibleResults)
        break
      // j/k focus the primary link, so Enter already activates the focused
      // link natively. Do not hijack Enter on another action (such as Ask AI)
      // merely because that action belongs to the same result card.
      case "/": // Focus search
        event.preventDefault()
        if (this.hasSearchInputTarget) this.searchInputTarget.focus()
        break
      case "Escape":
        if (document.activeElement === this.searchInputTarget) {
          this.searchInputTarget.blur()
        }
        this.focusIndexValue = -1
        this.clearHighlights()
        break
      case "1": case "2": case "3": case "4":
        // Tab switching via number keys
        event.preventDefault()
        const tabIndex = parseInt(event.key) - 1
        if (this.tabButtonTargets[tabIndex]) {
          this.tabButtonTargets[tabIndex].click()
        }
        break
    }
  }

  highlightResult(results) {
    this.clearHighlights()
    if (this.focusIndexValue >= 0 && results[this.focusIndexValue]) {
      const item = results[this.focusIndexValue]
      item.classList.add("unified-search__result--focused")
      item.scrollIntoView({ behavior: "smooth", block: "nearest" })
      item.querySelector("a")?.focus({ preventScroll: true })
    }
  }

  clearHighlights() {
    this.resultItemTargets.forEach(item => {
      item.classList.remove("unified-search__result--focused")
    })
  }

  getVisibleResults() {
    return this.resultItemTargets.filter(item => {
      const panel = item.closest("[data-unified-search-target='tabPanel']")
      return panel && !panel.classList.contains("hidden")
    })
  }

  // Expand/collapse result preview
  togglePreview(event) {
    const card = event.currentTarget.closest("[data-unified-search-target='resultItem']")
    const preview = card?.querySelector(".unified-search__preview")
    if (preview) {
      preview.classList.toggle("hidden")
      const icon = event.currentTarget.querySelector(".preview-toggle-icon")
      if (icon) {
        icon.style.transform = preview.classList.contains("hidden") ? "" : "rotate(180deg)"
      }
    }
  }
}
