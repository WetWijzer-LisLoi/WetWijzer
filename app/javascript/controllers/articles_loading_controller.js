// Shows a loading indicator with a live stopwatch while the articles turbo frame loads.
// Hides the indicator when the frame finishes loading.
//
// Usage:
// <div data-controller="articles-loading" data-articles-loading-frame-value="law_articles">
//   <div data-articles-loading-target="indicator">Loading...</div>
// </div>

import { Controller } from "@hotwired/stimulus";
import { uiText } from "../utils/ui_translations";

export default class extends Controller {
  static targets = ["indicator", "label"];
  static values = { frame: String, doneLabel: String };

  connect() {
    this.onFrameLoad = this.onFrameLoad.bind(this);
    this.onFrameFailure = this.onFrameFailure.bind(this);
    this.releaseHeading = this.releaseHeading.bind(this);
    document.addEventListener("turbo:before-cache", this.releaseHeading);
    this._startTime = performance.now();
    this._timerInterval = null;

    // Find the turbo frame by ID
    const frameId = this.hasFrameValue ? this.frameValue : "law_articles";
    this.frame = document.getElementById(frameId);

    if (this.frame) {
      this.frame.addEventListener("turbo:frame-load", this.onFrameLoad);
      // Turbo sends no frame-load when the request fails (a network failure) or is answered without the frame (an
      // error page). The pill then went on saying "loading" and the frame kept its loading message with no way to try
      // again; an error page got the page-wide fallback's notice, whose Retry took the whole page to the frame's own
      // address (Chrome, 2026-11-11, qa/probe-frame-failure-141).
      this.frame.addEventListener("turbo:fetch-request-error", this.onFrameFailure);
      this.frame.addEventListener("turbo:frame-missing", this.onFrameFailure);
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
      this.frame.removeEventListener("turbo:fetch-request-error", this.onFrameFailure);
      this.frame.removeEventListener("turbo:frame-missing", this.onFrameFailure);
    }
    document.removeEventListener("turbo:frame-load", this.onFrameLoad);
    document.removeEventListener("turbo:before-cache", this.releaseHeading);
    window.removeEventListener("resize", this.onResize);
  }

  // The law page's heading is the law's title since 1.1.30 and shares its row with this pill. When the pill left the
  // layout, the header reflowed and the page below moved, 1 to 3 s after it opened (receipt-1-1-30-b; measured in
  // Chrome on the two-line test title: the title took the pill's width and became one line, 38 px; with the title
  // held, the shorter row gave the toolbar room to go from two rows to one, 8 px). The title keeps its width and its
  // row keeps its width until the window's width changes (a phone's address bar changes only its height) or Turbo
  // caches the page.
  keepHeadingLines() {
    const row = this.headingRow;
    const heading = row?.querySelector("h1");
    const width = heading?.getBoundingClientRect().width;
    if (!width) return;
    heading.style.maxWidth = `${width}px`;
    row.style.minWidth = `${row.getBoundingClientRect().width}px`;
    this._lockedWidth = window.innerWidth;
    window.addEventListener("resize", this.onResize, { passive: true });
  }

  onResize = () => {
    if (window.innerWidth !== this._lockedWidth) this.releaseHeading();
  };

  releaseHeading() {
    window.removeEventListener("resize", this.onResize);
    const row = this.headingRow;
    const heading = row?.querySelector("h1");
    if (!heading) return;
    heading.style.maxWidth = "";
    row.style.minWidth = "";
  }

  // The pill's row, when it holds the page's heading. The heading is found here, not marked as a target: the print
  // stylesheet hides every [data-articles-loading-target] element, and a marked heading vanished from the print.
  get headingRow() {
    const row = this.hasIndicatorTarget ? this.indicatorTarget.parentElement : null;
    return row?.querySelector("h1") ? row : null;
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

  // The articles did not load: the pill says so and the frame offers to load them again, in place. An answer that
  // is a whole page without the frame (a sign-in page, say) is left to the page-wide fallback, which opens it.
  onFrameFailure(event) {
    if (!this.frame || event.target !== this.frame) return;
    if (event.type === "turbo:frame-missing") {
      if (event.detail?.response?.ok) return;
      event.preventDefault();
    }
    this._stopTimer();
    this.showFailure();
  }

  showFailure() {
    if (this.hasIndicatorTarget) {
      this._spinner ??= this.indicatorTarget.querySelector(".animate-spin");
      this._spinner?.classList.remove("animate-spin");
      const timer = this.indicatorTarget.querySelector(".loading-stopwatch");
      if (timer) timer.textContent = "";
    }
    if (this.hasLabelTarget) {
      this._loadingLabel ??= this.labelTarget.textContent;
      this.labelTarget.textContent = uiText("loadFailed");
    }

    const panel = document.createElement("div");
    panel.setAttribute("data-frame-status-error", "");
    panel.setAttribute("role", "alert");
    panel.className = "flex flex-wrap items-center gap-3 p-4 text-sm text-red-700 dark:text-red-300";
    const message = document.createElement("span");
    message.textContent = uiText("loadFailed");
    panel.appendChild(message);
    if (typeof this.frame.reload === "function") {
      const retry = document.createElement("button");
      retry.setAttribute("type", "button");
      retry.className = "underline font-medium";
      retry.textContent = uiText("retry");
      retry.addEventListener("click", () => this.retry());
      panel.appendChild(retry);
    }
    this.frame.replaceChildren(panel);
  }

  // Loads the articles again in the frame; the pill counts again, and frame-load or another failure ends it.
  retry() {
    if (this.hasLabelTarget && this._loadingLabel != null) this.labelTarget.textContent = this._loadingLabel;
    this._spinner?.classList.add("animate-spin");
    this._stopTimer();
    this._startTime = performance.now();
    this._startStopwatch();
    this.frame.reload();
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

      // WW-UI-05: the words follow the state, before the fade, so the
      // checkmark never stands beside "loading" (a polite live region).
      if (this.hasLabelTarget && this.doneLabelValue) {
        this.labelTarget.textContent = this.doneLabelValue;
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
          "duration-500",
          "motion-reduce:transition-none"
        );
        setTimeout(() => {
          this.keepHeadingLines();
          this.indicatorTarget.classList.add("hidden");
          // Theme utilities can keep an opacity-zero hidden pill as an
          // inline flex box. An inline !important declaration is the final
          // layout fence after the completion message has been announced.
          this.indicatorTarget.style.setProperty("display", "none", "important");
        }, 500);
      }, 1500);
    }
  }
}
