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
    this.updateTabCounts()
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundKeyHandler)
  }

  // Tab switching
  switchTab(event) {
    const tab = event.currentTarget.dataset.tab
    this.activeTabValue = tab

    // Update tab button states
    this.tabButtonTargets.forEach(btn => {
      const isActive = btn.dataset.tab === tab
      btn.classList.toggle("unified-search__tab--active", isActive)
      btn.setAttribute("aria-selected", isActive)
    })

    // Show/hide panels
    this.tabPanelTargets.forEach(panel => {
      const shouldShow = tab === "all" || panel.dataset.source === tab
      panel.classList.toggle("hidden", !shouldShow)
      panel.setAttribute("aria-hidden", !shouldShow)
    })

    // Reset focus index
    this.focusIndexValue = -1
    this.updateVisibleResults()
  }

  // Keyboard navigation
  handleKeydown(event) {
    // Only handle when search page is focused
    if (document.activeElement?.tagName === "INPUT" && event.key !== "Escape") {
      if (event.key === "Enter") return // Let form submit
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
      case "Enter": // Open focused result
        if (this.focusIndexValue >= 0 && visibleResults[this.focusIndexValue]) {
          event.preventDefault()
          const link = visibleResults[this.focusIndexValue].querySelector("a")
          if (link) link.click()
        }
        break
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

  updateVisibleResults() {
    // Update count badge for "All" tab
    const visibleCount = this.getVisibleResults().length
    const allCountBadge = this.element.querySelector("[data-count-for='all']")
    if (allCountBadge) {
      allCountBadge.textContent = visibleCount
    }
  }

  updateTabCounts() {
    this.tabButtonTargets.forEach(btn => {
      const tab = btn.dataset.tab
      const badge = btn.querySelector("[data-count-for]")
      if (!badge) return

      if (tab === "all") {
        badge.textContent = this.resultItemTargets.length
      } else {
        const panel = this.tabPanelTargets.find(p => p.dataset.source === tab)
        if (panel) {
          badge.textContent = panel.querySelectorAll("[data-unified-search-target='resultItem']").length
        }
      }
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
