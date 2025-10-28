// Shows a loading indicator with a live stopwatch while the articles turbo frame loads.
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
    this._startTime = performance.now();
    this._timerInterval = null;

    // Find the turbo frame by ID
    const frameId = this.hasFrameValue ? this.frameValue : "law_articles";
    this.frame = document.getElementById(frameId);

    if (this.frame) {
      this.frame.addEventListener("turbo:frame-load", this.onFrameLoad);
    }

    // Also listen globally in case the frame doesn't exist yet
    document.addEventListener("turbo:frame-load", this.onFrameLoad);

    // Inject the stopwatch into the indicator
    this._injectStopwatch();
    this._startStopwatch();
  }

  disconnect() {
    this._stopTimer();
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
      const elapsed = this._stopTimer();
      this.hideIndicator(elapsed);
    }
  }

  _injectStopwatch() {
    if (!this.hasIndicatorTarget) return;

    // Find or create timer display inside the indicator
    let timer = this.indicatorTarget.querySelector(".loading-stopwatch");
    if (!timer) {
      timer = document.createElement("span");
      timer.className =
        "loading-stopwatch text-xs font-mono tabular-nums opacity-60 ml-1";
      timer.textContent = "0.0s";

      // Find the text element inside the indicator and append after it
      const textEl = this.indicatorTarget.querySelector("span.hidden");
      if (textEl) {
        textEl.after(timer);
        // Also show the text on mobile during loading
        textEl.classList.remove("hidden");
        textEl.classList.add("inline");
      } else {
        this.indicatorTarget.appendChild(timer);
      }
    }
  }

  _startStopwatch() {
    this._timerInterval = setInterval(() => {
      const timer = this.hasIndicatorTarget
        ? this.indicatorTarget.querySelector(".loading-stopwatch")
        : null;
      if (timer && this._startTime) {
        const sec = ((performance.now() - this._startTime) / 1000).toFixed(1);
        timer.textContent = sec + "s";
      }
    }, 100);
  }

  _stopTimer() {
    if (this._timerInterval) {
      clearInterval(this._timerInterval);
      this._timerInterval = null;
    }
    if (this._startTime) {
      const elapsed = (
        (performance.now() - this._startTime) /
        1000
      ).toFixed(1);
      this._startTime = null;
      return elapsed;
    }
    return null;
  }

  hideIndicator(elapsed) {
    if (this.hasIndicatorTarget) {
      // Update the timer to show final time before fading
      const timer =
        this.indicatorTarget.querySelector(".loading-stopwatch");
      if (timer && elapsed) {
        timer.textContent = elapsed + "s ✓";
      }

      // Replace spinner with checkmark
      const spinner = this.indicatorTarget.querySelector(".animate-spin");
      if (spinner) {
        spinner.classList.remove("animate-spin");
        spinner.innerHTML =
          '<path fill-rule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clip-rule="evenodd"/>';
      }

      // Fade out after a moment
      setTimeout(() => {
        this.indicatorTarget.classList.add(
          "opacity-0",
          "transition-opacity",
          "duration-500"
        );
        setTimeout(() => {
          this.indicatorTarget.classList.add("hidden");
        }, 500);
      }, 1500);
    }
  }
}
