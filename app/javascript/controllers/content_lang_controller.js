import { Controller } from "@hotwired/stimulus"

/**
 * Content Language Controller
 *
 * Manages the LexLibera content language preference (NL/FR).
 * Shows a modal for first-time selection, provides a header toggle,
 * and persists the choice via cookie.
 *
 * Only active on LexLibera (EN locale).
 */
export default class extends Controller {
  static targets = ["modal", "label"]

  connect() {
    // Listen for cookie consent acceptance to show the language chooser
    this._onConsent = () => this.showModal()
    document.addEventListener("cookie-consent:accepted", this._onConsent)
  }

  disconnect() {
    document.removeEventListener("cookie-consent:accepted", this._onConsent)
  }

  showModal() {
    const modal = this.hasModalTarget ? this.modalTarget : document.getElementById("content-lang-modal")
    if (modal) {
      modal.classList.remove("hidden")
      modal.setAttribute("aria-hidden", "false")
    }
  }

  hideModal() {
    const modal = this.hasModalTarget ? this.modalTarget : document.getElementById("content-lang-modal")
    if (modal) {
      modal.classList.add("hidden")
      modal.setAttribute("aria-hidden", "true")
    }
  }

  /**
   * Select a content language (called from modal buttons)
   * @param {Event} event - Click event with data-lang attribute
   */
  select(event) {
    const lang = event.currentTarget.dataset.lang
    if (lang !== "nl" && lang !== "fr") return

    this.setCookie("content_lang", lang, 365)

    // Show loading state on the clicked button
    this._showButtonLoading(event.currentTarget)
    // Trigger the top progress bar
    this._showProgress()

    // Short delay for visual feedback, then reload
    requestAnimationFrame(() => {
      window.location.reload()
    })
  }

  /**
   * Toggle between NL and FR (called from header button)
   */
  toggle() {
    const current = this.getCurrentLang()
    const next = current === "nl" ? "fr" : "nl"
    this.setCookie("content_lang", next, 365)

    // Show loading state on the toggle button
    this._showProgress()

    // Update label immediately for instant feedback
    if (this.hasLabelTarget) {
      this.labelTarget.textContent = next.toUpperCase()
    }

    requestAnimationFrame(() => {
      window.location.reload()
    })
  }

  getCurrentLang() {
    const match = document.cookie.match(/content_lang=(\w+)/)
    return match ? match[1] : "nl"
  }

  setCookie(name, value, days) {
    let expires = ""
    if (days > 0) {
      const date = new Date()
      date.setTime(date.getTime() + (days * 24 * 60 * 60 * 1000))
      expires = "; expires=" + date.toUTCString()
    }
    document.cookie = name + "=" + value + expires + "; path=/; SameSite=Lax"
  }

  /**
   * Show a spinner on the clicked button
   */
  _showButtonLoading(btn) {
    btn.disabled = true
    btn.style.opacity = "0.7"
    btn.style.pointerEvents = "none"

    // Add a small spinner after the flag emoji
    const spinner = document.createElement("span")
    spinner.className = "inline-block w-4 h-4 ml-2 border-2 border-white/30 border-t-white rounded-full animate-spin"
    spinner.style.verticalAlign = "middle"
    btn.appendChild(spinner)
  }

  /**
   * Trigger the fallback progress bar (defined in application layout)
   */
  _showProgress() {
    // Try to trigger the existing fallback progress bar
    let bar = document.getElementById("fallback-progress-bar")
    if (!bar) {
      bar = document.createElement("div")
      bar.id = "fallback-progress-bar"
      bar.setAttribute("aria-hidden", "true")
      bar.style.cssText = "position:fixed;top:0;left:0;height:3px;width:20%;z-index:99999;transition:width .3s ease;"
      bar.style.background = getComputedStyle(document.documentElement).getPropertyValue("--accent-600-solid").trim() || "#2563eb"
      bar.style.boxShadow = "0 0 10px rgba(37,99,235,.7)"
      document.body.appendChild(bar)
    }
    bar.style.width = "20%"
    setTimeout(() => { bar.style.width = "80%" }, 50)
  }
}
