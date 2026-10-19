import { Controller } from "@hotwired/stimulus"

// Only this tab's navigation visibility is remembered. No account preference,
// question, analytics event, or cross-tab/browser persistence is written.
export default class extends Controller {
  static targets = ["toggle"]

  connect() {
    this.storageKey = "wetwijzer:mobile-dock:hidden"
    this.element.open = !this.readHidden()
    this._sync = this.sync.bind(this)
    this._toggle = () => {
      this.rememberHidden(!this.element.open)
      if (!this.element.open) this.closeTransientControls()
      this.sync()
    }
    this._beforeCache = this.closeTransientControls.bind(this)
    this.element.addEventListener("toggle", this._toggle)
    window.addEventListener("resize", this._sync)
    document.addEventListener("focusin", this._sync)
    document.addEventListener("focusout", this._sync)
    document.addEventListener("turbo:before-cache", this._beforeCache)
    window.visualViewport?.addEventListener("resize", this._sync)
    window.visualViewport?.addEventListener("scroll", this._sync)
    if (typeof ResizeObserver !== "undefined") {
      this.resizeObserver = new ResizeObserver(this._sync)
      this.resizeObserver.observe(this.element)
    }
    if (typeof MutationObserver !== "undefined") {
      this.mutationObserver = new MutationObserver(this._sync)
      for (const id of ["pwa-install-banner", "chatbot-widget-panel"]) {
        const element = document.getElementById(id)
        if (element) {
          this.mutationObserver.observe(element, { attributes: true, attributeFilter: ["class", "style", "hidden"] })
          this.resizeObserver?.observe(element)
        }
      }
    }
    this.sync()
  }

  disconnect() {
    this.element.removeEventListener("toggle", this._toggle)
    window.removeEventListener("resize", this._sync)
    document.removeEventListener("focusin", this._sync)
    document.removeEventListener("focusout", this._sync)
    document.removeEventListener("turbo:before-cache", this._beforeCache)
    window.visualViewport?.removeEventListener("resize", this._sync)
    window.visualViewport?.removeEventListener("scroll", this._sync)
    this.resizeObserver?.disconnect()
    this.mutationObserver?.disconnect()
    this.closeTransientControls()
    const current = document.getElementById("mobile-bottom-bar")
    if (!current || current === this.element) {
      document.body.style.removeProperty("--mobile-dock-clearance")
      document.body.style.removeProperty("--mobile-chat-dock-clearance")
      document.body.style.removeProperty("--mobile-chat-viewport-height")
      document.body.style.removeProperty("--mobile-chat-viewport-top")
      delete document.body.dataset.mobileDockOpen
    }
  }

  readHidden() {
    try {
      const value = window.sessionStorage.getItem(this.storageKey)
      if (value !== null) return value === "1"
    } catch (_error) { /* restricted storage: retain this tab's in-memory state */ }
    return window.__wetwijzerMobileDockHidden === true
  }

  rememberHidden(hidden) {
    window.__wetwijzerMobileDockHidden = hidden
    try { window.sessionStorage.setItem(this.storageKey, hidden ? "1" : "0") } catch (_error) { /* native controls still work */ }
  }

  chat(event) {
    // Native href is the no-JS fallback and remains the action on /chatbot,
    // where no floating widget exists. Never auto-send a question.
    const widget = document.getElementById("chatbot-widget-container")
    if (!widget || widget.hidden || !widget.getClientRects().length) return
    event.preventDefault()
    event.stopPropagation()
    document.dispatchEvent(new CustomEvent("chatbot:toggle"))
  }

  navigate(event) {
    // Law-specific Go-to/contents controls act on the page behind chat. Close
    // that panel when choosing a different destination, but never when the
    // reader merely folds the dock or taps Chat to toggle it.
    const control = event.target.closest('a, button')
    if (!control || control.dataset.mobileDockLink === "chat") return
    const widget = document.getElementById("chatbot-widget-container")
    const controller = widget && this.application?.getControllerForElementAndIdentifier(widget, "chatbot")
    if (controller?.openValue) controller.close()
  }

  closeTransientControls() {
    const jump = this.element.querySelector('[data-controller~="jump-select"]')
    if (jump) {
      const controller = this.application?.getControllerForElementAndIdentifier(jump, "jump-select")
      controller?.close({ immediate: true })
      // Turbo takes its snapshot synchronously; never leave a menu portalled
      // to body while a normal close animation is waiting to finish.
      controller?.finalizeClose?.()
    }
    if (window.matchMedia("(max-width: 767px)").matches) {
      const host = this.element.closest('[data-controller~="sidebar-toggle"]')
      if (host) this.application?.getControllerForElementAndIdentifier(host, "sidebar-toggle")?.hideMobilePanel()
    }
  }

  sync() {
    const mobile = window.matchMedia("(max-width: 767px)").matches
    const viewport = window.visualViewport
    const editing = document.activeElement?.matches?.('input, textarea, select, [contenteditable="true"]')
    const keyboard = mobile && editing && viewport && window.innerHeight - viewport.height > 150
    this.element.toggleAttribute("data-keyboard-active", !!keyboard)
    const banner = document.getElementById("pwa-install-banner")
    const bannerVisible = banner && window.getComputedStyle(banner).display !== "none" && window.getComputedStyle(banner).visibility !== "hidden"
    const bannerHeight = mobile && bannerVisible ? Math.ceil(banner.getBoundingClientRect().height) : 0
    // Keep navigation above the on-screen keyboard instead of removing it.
    // Some browsers resize the layout viewport; others only resize/pan the
    // visual viewport. This inset handles both without counting the keyboard
    // twice or waiting for a delayed focus/blur event.
    const visualMobile = mobile && viewport && viewport.scale === 1
    const keyboardInset = visualMobile ? Math.max(0, window.innerHeight - viewport.offsetTop - viewport.height) : 0
    this.element.style.bottom = `${bannerHeight + keyboardInset}px`
    // A standalone PWA can have a narrower visual viewport than its layout.
    // Keep both the full dock and the compact native handle inside it.
    // CSS applies these in either native details state: hide/show still fits
    // if scripting becomes unavailable after this controller has connected.
    if (visualMobile) {
      this.element.style.setProperty("--mobile-dock-viewport-left", `${viewport.offsetLeft}px`)
      this.element.style.setProperty("--mobile-dock-viewport-width", `${viewport.width}px`)
      this.element.style.setProperty("--mobile-dock-handle-right", `${Math.max(0, window.innerWidth - viewport.offsetLeft - viewport.width) + 8}px`)
      document.body.style.setProperty("--mobile-chat-viewport-height", `${viewport.height}px`)
      document.body.style.setProperty("--mobile-chat-viewport-top", `${viewport.offsetTop}px`)
    } else {
      for (const property of ["--mobile-dock-viewport-left", "--mobile-dock-viewport-width", "--mobile-dock-handle-right"]) this.element.style.removeProperty(property)
      document.body.style.removeProperty("--mobile-chat-viewport-height")
      document.body.style.removeProperty("--mobile-chat-viewport-top")
    }
    const rect = this.element.getBoundingClientRect()
    const visible = mobile && window.getComputedStyle(this.element).visibility !== "hidden" && rect.height > 0
    const clearance = visible ? Math.ceil(rect.height) + bannerHeight + 8 : 0
    // Page content needs an extra breathing gap above navigation; a chat
    // covering the page must meet the dock without revealing text underneath.
    const chatClearance = visible ? Math.ceil(rect.height) + bannerHeight : 0
    const open = visible && this.element.open
    document.body.style.setProperty("--mobile-dock-clearance", `${clearance}px`)
    document.body.style.setProperty("--mobile-chat-dock-clearance", `${chatClearance}px`)
    document.body.dataset.mobileDockOpen = String(open)
    this.toggleTarget.setAttribute("aria-expanded", String(this.element.open))
    const state = `${open}:${visible}:${clearance}`
    if (state !== this.lastState) {
      this.lastState = state
      document.dispatchEvent(new CustomEvent("mobile-dock:change", { detail: { open, visible, clearance } }))
    }
  }
}
