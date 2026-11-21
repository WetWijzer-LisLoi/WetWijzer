import { Controller } from "@hotwired/stimulus"
import { revealCollapsedAncestors } from "../utils/reveal_target.js"

// Handles navigation to article anchors in lazy-loaded content
// Ensures articles are loaded before attempting to navigate to fragment
export default class extends Controller {
  static targets = ["frame"]
  
  connect() {
    // On page load, if URL has a fragment, ensure articles are loaded
    this.handleInitialFragment()
  }

  disconnect() {
    this.cancelPendingNavigation()
  }

  // A jump still waiting for the articles is dropped when the reader leaves the law: Turbo renders the next page in its
  // place, and the jump would write this law's anchor into that page's address as a history entry of its own (Sol
  // 2026-11-21 10:58:04Z, found going Back and Forward through another page: "/faq#art-2" kept Back on that page).
  cancelPendingNavigation() {
    if (this.pendingLoad) this.pendingLoad.frame.removeEventListener('turbo:frame-load', this.pendingLoad.handler)
    if (this.pendingFrameId) globalThis.cancelAnimationFrame?.(this.pendingFrameId)
    this.pendingLoad = null
    this.pendingFrameId = null
  }
  
  handleInitialFragment() {
    const hash = window.location.hash
    
    // No fragment = nothing to do
    if (!hash) return
    
    // Check if frame is already loaded (has content beyond loading placeholder)
    if (this.isFrameLoaded()) {
      // Articles already loaded, browser will handle scroll automatically
      return
    }
    
    // Articles not loaded yet - trigger load and navigate once ready
    this.loadFrameAndNavigate(hash)
  }
  
  // Intercepts TOC link clicks to ensure articles are loaded first
  handleClick(event) {
    const link = event.currentTarget
    const hash = link.hash
    
    // No fragment = let browser handle normally
    if (!hash) return
    
    // Check if target anchor exists in DOM
    const targetElement = document.querySelector(hash)
    
    if (targetElement) {
      // Target exists, navigate immediately
      event.preventDefault()
      this.navigateToHash(hash)
      return
    }
    
    // Target doesn't exist yet - articles not loaded
    // Prevent default, load frame, then navigate
    event.preventDefault()
    this.loadFrameAndNavigate(hash, link)
  }
  
  isFrameLoaded() {
    if (!this.hasFrameTarget) return false
    
    // Check if frame has been loaded by looking for the articles container
    // The loading placeholder has class 'border', actual content has 'bg-white'
    const articlesCard = this.frameTarget.querySelector('[data-controller*="collapse"]')
    return articlesCard !== null
  }
  
  loadFrameAndNavigate(hash, link = null) {
    if (!this.hasFrameTarget) return
    
    const frame = this.frameTarget
    const address = window.location.pathname + window.location.search
    this.cancelPendingNavigation()

    // First scroll to the loading section to show articles are loading
    this.scrollToLoadingSection()

    // Set up one-time listener for frame load
    const handleLoad = () => {
      frame.removeEventListener('turbo:frame-load', handleLoad)
      this.pendingLoad = null

      // Wait a tick for DOM to settle, then navigate to target, unless the law has left the page meanwhile, or its
      // address already has: a Back or Forward moves the address before Turbo replaces the page, also to another
      // archive date or language of the same law (Sol 2026-11-21 11:28:09Z: a query, not only a path)
      this.pendingFrameId = requestAnimationFrame(() => {
        this.pendingFrameId = null
        if (frame.isConnected === false || this.element?.isConnected === false) return
        if (window.location.pathname + window.location.search !== address) return
        this.navigateToHash(this.currentHash(hash, link))
      })
    }

    this.pendingLoad = { frame, handler: handleLoad }
    frame.addEventListener('turbo:frame-load', handleLoad)
    
    // Trigger frame load by setting src (if not already set)
    // If src already exists, reload it
    if (frame.src) {
      frame.reload()
    }
  }
  
  // Once the frame has loaded, toc-targets (WW-UI-02) may have pointed the
  // clicked link, or the link an old deep link names, at another element.
  currentHash(hash, link) {
    if (link) return link.hash || hash
    const moved = document.querySelector(`a[data-toc-original-href="${CSS.escape(hash)}"]`)
    return (moved && moved.hash) || hash
  }

  scrollToLoadingSection() {
    // Scroll to the "loading articles" section to show user that content is being loaded
    const loadingSection = document.getElementById('tekst')
    if (loadingSection) {
      loadingSection.scrollIntoView({ behavior: 'smooth', block: 'start' })
    }
  }
  
  navigateToHash(hash) {
    // The folded sections around the target open first, also when the address already names it: no hashchange
    // follows then, and the contents tracker opens them only on a hashchange (Sol, on live 1.1.25, 09:08:16Z: Book 8
    // folded at #art-8-34, then the contents link Art. 8.34-8.37 left the article hidden).
    let id = String(hash || '').replace(/^#/, '')
    try { id = decodeURIComponent(id) } catch (_) { /* the id as written */ }
    const folded = id && document.getElementById(id)
    if (folded) revealCollapsedAncestors(folded)
    // Update URL hash (this will trigger browser scroll)
    window.location.hash = hash
    
    // Fallback: manually scroll to element if browser doesn't auto-scroll
    const target = document.querySelector(hash)
    if (target) {
      target.scrollIntoView({ behavior: 'auto', block: 'start' })
    }
  }
}
