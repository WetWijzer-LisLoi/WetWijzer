// Shows a loading indicator while the articles turbo frame is loading.
// Hides the indicator when the frame finishes loading.
//
// Usage:
// <div data-controller="articles-loading" data-articles-loading-frame-value="law_articles">
//   <div data-articles-loading-target="indicator">Loading...</div>
// </div>

import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["indicator"];
  static values = { frame: String };

  connect() {
    this.onFrameLoad = this.onFrameLoad.bind(this);
    
    // Find the turbo frame by ID
    const frameId = this.hasFrameValue ? this.frameValue : "law_articles";
    this.frame = document.getElementById(frameId);
    
    if (this.frame) {
      this.frame.addEventListener("turbo:frame-load", this.onFrameLoad);
    }
    
    // Also listen globally in case the frame doesn't exist yet
    document.addEventListener("turbo:frame-load", this.onFrameLoad);
  }

  disconnect() {
    if (this.frame) {
      this.frame.removeEventListener("turbo:frame-load", this.onFrameLoad);
    }
    document.removeEventListener("turbo:frame-load", this.onFrameLoad);
  }

  onFrameLoad(event) {
    // Check if this is our frame
    const frameId = this.hasFrameValue ? this.frameValue : "law_articles";
    const targetFrame = event.target;
    
    if (targetFrame && targetFrame.id === frameId) {
      this.hideIndicator();
    }
  }

  hideIndicator() {
    if (this.hasIndicatorTarget) {
      // Fade out then hide
      this.indicatorTarget.classList.add("opacity-0", "transition-opacity", "duration-300");
      setTimeout(() => {
        this.indicatorTarget.classList.add("hidden");
      }, 300);
    }
  }
}
