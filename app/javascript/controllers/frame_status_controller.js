// Shows a brief, localized "Completed" status when a Turbo Frame finishes loading.
// Attach via: data-controller="frame-status" on the <turbo-frame> element
// Optional values:
//   data-frame-status-completed-value: localized string for the completed label
//   data-frame-status-results-value: optional localized string (e.g., "X results found.")
//   data-frame-status-duration-value: duration in ms before auto-hide (default 1200). If <= 0, stays visible.

import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static values = {
    completed: String,
    results: String,
    loading: String,
    duration: { type: Number, default: 1200 },
    mountSelector: String,
  };

  connect() {
    this._timerInterval = null;
    this._startTime = null;
    this.onFrameLoad = this.onFrameLoad.bind(this);
    this.onFrameRequestStart = this.onFrameRequestStart.bind(this);
    this.element.addEventListener("turbo:before-fetch-request", this.onFrameRequestStart);
    this.element.addEventListener("turbo:frame-load", this.onFrameLoad);

    // Auto-start timer if the frame has a src attribute (loading on page render).
    // The turbo:before-fetch-request event may fire before the controller connects,
    // so we start the timer eagerly here.
    if (this.element.tagName === 'TURBO-FRAME' && this.element.getAttribute('src')) {
      this.onFrameRequestStart();
    }
  }

  disconnect() {
    this._stopTimer();
    this.element.removeEventListener("turbo:before-fetch-request", this.onFrameRequestStart);
    this.element.removeEventListener("turbo:frame-load", this.onFrameLoad);
  }

  onFrameLoad() {
    // Stop the stopwatch and show completed pill with elapsed time
    const elapsed = this._stopTimer();
    this.showCompletedPill(elapsed);
  }

  onFrameRequestStart() {
    // Start the stopwatch and show the loading pill
    this._startTime = performance.now();
    const target = this.mountTarget();
    this.clearExisting(target);
    this.showLoadingPill(target);
    this._startStopwatch();
  }

  _startStopwatch() {
    this._stopTimer();
    // Delay showing the timer value until 0.5s to avoid the jarring "0.0s" flash
    this._timerDelay = setTimeout(() => {
      const el = this.mountTarget().querySelector('.frame-status-timer');
      if (el) el.style.visibility = 'visible';
    }, 500);
    this._timerInterval = setInterval(() => {
      const el = this.mountTarget().querySelector('.frame-status-timer');
      if (el && this._startTime) {
        const sec = ((performance.now() - this._startTime) / 1000).toFixed(1);
        el.textContent = sec + 's';
      }
    }, 100);
  }

  _stopTimer() {
    if (this._timerDelay) {
      clearTimeout(this._timerDelay);
      this._timerDelay = null;
    }
    if (this._timerInterval) {
      clearInterval(this._timerInterval);
      this._timerInterval = null;
    }
    if (this._startTime) {
      const elapsed = ((performance.now() - this._startTime) / 1000).toFixed(1);
      this._startTime = null;
      return elapsed;
    }
    return null;
  }

  mountTarget() {
    if (this.hasMountSelectorValue) {
      try {
        const el = document.querySelector(this.mountSelectorValue);
        if (el) return el;
      } catch (_) {
        // ignore selector errors
      }
    }
    return this.element;
  }

  clearExisting(target) {
    const selectors = [".frame-status-progress", ".frame-status-pill"];
    selectors.forEach((sel) => {
      const el = target.querySelector(sel);
      if (el) el.remove();
    });
  }

  buildMessageText() {
    const completed = this.hasCompletedValue ? this.completedValue : "";
    let results = "";
    if (this.hasResultsValue && this.resultsValue) {
      results = this.resultsValue;
    } else {
      // Fallback: look for hidden marker inside the frame content
      const marker = this.element.querySelector('[data-frame-status-results]');
      if (marker) results = marker.textContent.trim();
    }
    // If we have a results string, prefer showing only that (e.g., "1 resultaat gevonden.")
    if (results) return results;
    // Otherwise fall back to the completed label
    return completed;
  }

  // Show an inline loading pill with live stopwatch
  showLoadingPill(target) {
    const wrap = document.createElement("div");
    wrap.className = [
      "frame-status-progress",
      "not-prose",
      "flex items-center justify-start gap-2 w-full",
      "px-4 py-2 rounded-md",
      "text-sm font-medium",
      "bg-gray-100 text-gray-700 border border-gray-300",
      "dark:bg-gray-800 dark:text-gray-200 dark:border-gray-700",
      "my-4",
    ].join(" ");
    wrap.setAttribute("role", "status");
    wrap.setAttribute("aria-live", "polite");

    // Pulsing dot
    const dot = document.createElement("span");
    dot.setAttribute("aria-hidden", "true");
    dot.className = "inline-block w-2 h-2 rounded-full bg-gray-500 dark:bg-gray-400 animate-pulse";

    // Loading text
    const text = document.createElement("span");
    text.className = "flex-1";
    const loadingText = this.hasLoadingValue ? this.loadingValue : (this.hasCompletedValue ? this.completedValue : "Loading...");
    text.textContent = loadingText;

    // Live stopwatch counter
    const timer = document.createElement("span");
    timer.className = "frame-status-timer text-xs font-mono tabular-nums text-gray-400 dark:text-gray-500";
    timer.style.visibility = "hidden";
    timer.textContent = "0.0s";

    wrap.appendChild(dot);
    wrap.appendChild(text);
    wrap.appendChild(timer);

    const first = target.firstElementChild;
    if (first) {
      target.insertBefore(wrap, first);
    } else {
      target.appendChild(wrap);
    }
  }

  showCompletedPill(elapsedSec = null) {
    const target = this.mountTarget();
    this.clearExisting(target);

    const wrap = document.createElement("div");
    wrap.className = [
      "frame-status-pill",
      "not-prose",
      "flex items-center justify-start gap-2 w-full",
      "px-4 py-2 rounded-md",
      "text-sm font-medium",
      "my-4",
    ].join(" ");
    // Use accent theme colors via CSS variables
    wrap.style.backgroundColor = "color-mix(in srgb, var(--accent-500) 10%, transparent)";
    wrap.style.color = "var(--accent-700)";
    wrap.style.borderWidth = "1px";
    wrap.style.borderStyle = "solid";
    wrap.style.borderColor = "color-mix(in srgb, var(--accent-500) 25%, transparent)";
    wrap.setAttribute("role", "status");
    wrap.setAttribute("aria-live", "polite");

    const icon = document.createElement("span");
    icon.setAttribute("aria-hidden", "true");
    icon.className = "inline-block w-2 h-2 rounded-full";
    icon.style.backgroundColor = "var(--accent-500)";

    const text = document.createElement("span");
    text.className = "flex-1";
    let msg = this.buildMessageText();
    if (elapsedSec) msg += ` (${elapsedSec}s)`;
    text.textContent = msg;

    // Close button
    const closeBtn = document.createElement("button");
    closeBtn.setAttribute("type", "button");
    closeBtn.setAttribute("aria-label", "Close");
    closeBtn.className = "ml-auto p-1 rounded transition-colors";
    closeBtn.style.color = "var(--accent-600)";
    closeBtn.innerHTML = '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>';
    closeBtn.addEventListener("click", () => wrap.remove());

    wrap.appendChild(icon);
    wrap.appendChild(text);
    wrap.appendChild(closeBtn);

    const first = target.firstElementChild;
    if (first) {
      target.insertBefore(wrap, first);
    } else {
      target.appendChild(wrap);
    }

    // Auto-hide only if duration > 0
    if (!this.hasDurationValue || this.durationValue > 0) {
      window.setTimeout(() => {
        wrap.classList.add("opacity-0");
        window.setTimeout(() => wrap.remove(), 300);
      }, this.durationValue || 1200);
    }
  }

  escape(str) {
    return String(str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }
}
