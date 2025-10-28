import { Controller } from "@hotwired/stimulus"

// Handles navigation to article anchors in lazy-loaded content
// Ensures articles are loaded before attempting to navigate to fragment
export default class extends Controller {
  static targets = ["frame"]
  
  connect() {
    // On page load, if URL has a fragment, ensure articles are loaded
    this.handleInitialFragment()
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
    this.loadFrameAndNavigate(hash)
  }
  
  isFrameLoaded() {
    if (!this.hasFrameTarget) return false
    
    // Check if frame has been loaded by looking for the articles container
    // The loading placeholder has class 'border', actual content has 'bg-white'
    const articlesCard = this.frameTarget.querySelector('[data-controller*="collapse"]')
    return articlesCard !== null
  }
  
  loadFrameAndNavigate(hash) {
    if (!this.hasFrameTarget) return
    
    const frame = this.frameTarget
    
    // First scroll to the loading section to show articles are loading
    this.scrollToLoadingSection()
    
    // Set up one-time listener for frame load
    const handleLoad = () => {
      frame.removeEventListener('turbo:frame-load', handleLoad)
      
      // Wait a tick for DOM to settle, then navigate to target
      requestAnimationFrame(() => {
        this.navigateToHash(hash)
      })
    }
    
    frame.addEventListener('turbo:frame-load', handleLoad)
    
    // Trigger frame load by setting src (if not already set)
    // If src already exists, reload it
    if (frame.src) {
      frame.reload()
    }
  }
  
  scrollToLoadingSection() {
    // Scroll to the "loading articles" section to show user that content is being loaded
    const loadingSection = document.getElementById('tekst')
    if (loadingSection) {
      loadingSection.scrollIntoView({ behavior: 'smooth', block: 'start' })
    }
  }
  
  navigateToHash(hash) {
    // Update URL hash (this will trigger browser scroll)
    window.location.hash = hash
    
    // Fallback: manually scroll to element if browser doesn't auto-scroll
    const target = document.querySelector(hash)
    if (target) {
      target.scrollIntoView({ behavior: 'auto', block: 'start' })
    }
  }
}
