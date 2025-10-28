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
    this.onFrameLoad = this.onFrameLoad.bind(this);
    this.onFrameRequestStart = this.onFrameRequestStart.bind(this);
    this.element.addEventListener("turbo:before-fetch-request", this.onFrameRequestStart);
    this.element.addEventListener("turbo:frame-load", this.onFrameLoad);
  }

  disconnect() {
    this.element.removeEventListener("turbo:before-fetch-request", this.onFrameRequestStart);
    this.element.removeEventListener("turbo:frame-load", this.onFrameLoad);
  }

  onFrameLoad() {
    // Replace any loading pill with the completed pill
    this.showCompletedPill();
  }

  onFrameRequestStart() {
    // If status is persistent (duration <= 0), keep it visible during loading.
    // Otherwise, clear and rely on the frame's progress bar during loading.
    const target = this.mountTarget();
    if (this.hasDurationValue && this.durationValue <= 0) {
      // Keep the current completed pill until the new content finishes loading.
      return;
    }
    this.clearExisting(target);
    // Intentionally do not render a loading pill; the top progress bar provides feedback
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

  // Show an inline loading pill to provide immediate feedback
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

    const dot = document.createElement("span");
    dot.setAttribute("aria-hidden", "true");
    dot.className = "inline-block w-2 h-2 rounded-full bg-gray-500 dark:bg-gray-400 animate-pulse";

    const text = document.createElement("span");
    const loadingText = this.hasLoadingValue ? this.loadingValue : (this.hasCompletedValue ? this.completedValue : "Loading...");
    text.textContent = loadingText;

    wrap.appendChild(dot);
    wrap.appendChild(text);

    const first = target.firstElementChild;
    if (first) {
      target.insertBefore(wrap, first);
    } else {
      target.appendChild(wrap);
    }
  }

  showCompletedPill() {
    const target = this.mountTarget();
    this.clearExisting(target);

    // Detect if we're using a professional theme
    const htmlEl = document.documentElement;
    const isProfessional = htmlEl.classList.contains('theme-slate') || 
                          htmlEl.classList.contains('theme-indigo') ||
                          htmlEl.classList.contains('theme-sky') ||
                          htmlEl.classList.contains('theme-teal') ||
                          htmlEl.classList.contains('theme-cyan') ||
                          htmlEl.classList.contains('theme-green') ||
                          htmlEl.classList.contains('theme-purple') ||
                          htmlEl.classList.contains('theme-red');
    
    const wrap = document.createElement("div");
    if (isProfessional) {
      // Professional themes: neutral gray
      wrap.className = [
        "frame-status-pill",
        "not-prose",
        "flex items-center justify-start gap-2 w-full",
        "px-4 py-2 rounded-md",
        "text-sm font-medium",
        "bg-gray-100 text-gray-700 border border-gray-300",
        "dark:bg-gray-800 dark:text-gray-200 dark:border-gray-700",
        "my-4",
      ].join(" ");
    } else {
      // Vibrant themes: green (matches production)
      wrap.className = [
        "frame-status-pill",
        "not-prose",
        "flex items-center justify-start gap-2 w-full",
        "px-4 py-2 rounded-md",
        "text-sm font-medium",
        "bg-green-50 text-green-800 border border-green-200",
        "dark:bg-emerald-900/30 dark:text-emerald-200 dark:border-emerald-700/50",
        "my-4",
      ].join(" ");
    }
    wrap.setAttribute("role", "status");
    wrap.setAttribute("aria-live", "polite");

    const icon = document.createElement("span");
    icon.setAttribute("aria-hidden", "true");
    if (isProfessional) {
      icon.className = "inline-block w-2 h-2 rounded-full bg-gray-500 dark:bg-gray-400";
    } else {
      icon.className = "inline-block w-2 h-2 rounded-full bg-green-500";
    }
    const text = document.createElement("span");
    text.className = "flex-1";
    text.textContent = this.buildMessageText();

    // Close button
    const closeBtn = document.createElement("button");
    closeBtn.setAttribute("type", "button");
    closeBtn.setAttribute("aria-label", "Close");
    if (isProfessional) {
      closeBtn.className = "ml-auto p-1 rounded hover:bg-gray-200 dark:hover:bg-gray-700 text-gray-500 dark:text-gray-400 transition-colors";
    } else {
      closeBtn.className = "ml-auto p-1 rounded hover:bg-green-100 dark:hover:bg-emerald-800/50 text-green-600 dark:text-emerald-300 transition-colors";
    }
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
