import { Controller } from "@hotwired/stimulus";
import { restoreHeldResults } from "./turbo_cache_controller.js";
import { uiText } from "../utils/ui_translations.js";

// The address a failed search was sent to, for its Retry, only if it is on this site.
function sameOriginHref(url) {
  if (!url) return null;
  try {
    const target = new URL(String(url), window.location.href);
    return target.origin === window.location.origin ? target.href : null;
  } catch {
    return null;
  }
}

// A results frame's current content, hidden while a new search loads: each child keeps its inline display in
// data-ww-held-display and is marked data-ww-held-results; earlier loading marks go. See showImmediateLoadingUI.
export function holdResults(frame) {
  frame.querySelectorAll("[data-ww-client-loading]").forEach((el) => el.remove());
  Array.from(frame.children).forEach((child) => {
    if (child.hasAttribute("data-ww-held-results")) return;
    child.setAttribute("data-ww-held-results", "");
    child.dataset.wwHeldDisplay = child.style.display || "";
    child.style.display = "none";
  });
}

/**
 * Search Validation Controller
 * @class SearchValidationController
 * @extends Controller
 * 
 * Provides light client-side validation before form submission to ensure
 * required search criteria are selected. Does not block submission but provides
 * visual feedback, allowing the server to render translated validation messages.
 * 
 * @example
 * <!-- Usage in HTML -->
 * <form data-controller="search-validation"
 *       data-action="submit->search-validation#validate">
 *   <div data-search-validation-target="types">...</div>
 *   <div data-search-validation-target="languages">...</div>
 *   <div data-search-validation-target="scope">...</div>
 * </form>
 */
export default class extends Controller {
  /**
   * Stimulus targets for validation sections
   * @static
   * @type {string[]}
   */
  static targets = ["panel", "types", "languages", "scope"];

  connect() {
    this.element.addEventListener("turbo:before-fetch-response", this.onBeforeFetchResponse);
    this.element.addEventListener("turbo:submit-end", this.onSubmitEnd);
  }

  disconnect() {
    this.element.removeEventListener("turbo:before-fetch-response", this.onBeforeFetchResponse);
    this.element.removeEventListener("turbo:submit-end", this.onSubmitEnd);
  }

  // Turbo draws an error answer to this search over the whole page and keeps the earlier search's address. In
  // Chrome with nginx's 502 page (2026-11-11), its Retry then reloaded the earlier search, so the reader's new search
  // was lost, and its countdown is an inline script this page's policy blocks. The search never answers with an
  // error on purpose (an incomplete search is an ordinary page), so Turbo does not draw an error answer: the submit
  // ends as after a network failure, and onSubmitEnd keeps this page.
  onBeforeFetchResponse = (event) => {
    if (event.target !== this.element) return;
    if (event.detail?.fetchResponse?.succeeded === false) event.preventDefault();
  };

  // A submit that fails (a network error, an error answer) leaves this page on screen: the rows hidden for the
  // loading view come back, the loading marks go (Sol 2026-11-08 00:58:16Z: error submits), and a notice says the
  // search failed, with a Retry for the search that was sent. A successful submit leaves them to the visit, which
  // replaces the body; turbo:before-cache restores them for the snapshot.
  onSubmitEnd = (event) => {
    if (event?.detail?.success !== false) return;
    const heldRows = document.querySelector("[data-ww-held-results]") !== null;
    restoreHeldResults(document);
    this.showSearchFailed(event.detail.formSubmission?.fetchRequest?.url, heldRows);
  };

  // The notice above the results, or under the form when there are none. Its Retry is a plain link, not a Turbo
  // visit: if the server still answers with an error, the browser shows that page at the search's own address, where
  // the page's Retry and countdown repeat this search and not the earlier one.
  showSearchFailed(url, heldRows) {
    document.querySelectorAll("[data-ww-search-failed]").forEach((el) => el.remove());
    const panel = document.createElement("div");
    panel.setAttribute("data-ww-search-failed", "");
    panel.setAttribute("role", "alert");
    panel.className = "flex flex-wrap items-center gap-3 p-4 text-sm text-red-700 dark:text-red-300";
    const message = document.createElement("span");
    message.textContent = uiText("searchFailed");
    panel.appendChild(message);
    if (heldRows) {
      const previous = document.createElement("span");
      previous.textContent = uiText("previousResults");
      panel.appendChild(previous);
    }
    const target = sameOriginHref(url);
    if (target) {
      const retry = document.createElement("a");
      retry.setAttribute("href", target);
      retry.setAttribute("data-turbo", "false");
      retry.className = "underline font-medium";
      retry.textContent = uiText("retry");
      panel.appendChild(retry);
    }
    const mount = document.querySelector("#search-status-mount");
    if (mount) mount.prepend(panel);
    else this.element.after(panel);
  }

  /**
   * Validates form before submission
   * Checks for required selections and provides visual feedback
   * @param {Event} event - The form submit event
   * @return {void}
   */
  validate(event) {
    const missing = [];

    const typesOk = this.anyChecked(this.typesTarget);
    if (!typesOk) missing.push({ key: "types", el: this.typesTarget });

    const langsOk = this.anyChecked(this.languagesTarget);
    if (!langsOk) missing.push({ key: "languages", el: this.languagesTarget });

    const scopeOk = this.scopeSelected(this.scopeTarget);
    if (!scopeOk) missing.push({ key: "scope", el: this.scopeTarget });

    // Do not prevent submit; allow server to render translated validation messages.
    // Optionally add a brief visual hint before navigation begins.
    if (missing.length > 0) {
      // Briefly highlight each missing section
      missing.forEach((m) => this.highlight(m.el));
    }

    // Immediately show loading UI feedback while Turbo navigates.
    // This reduces perceived latency before the new page renders.
    this.showImmediateLoadingUI();
  }

  // Note: panel is opened server-side on validation failure via @validation_failed
  // openPanel() is no longer used to avoid blocking submit.

  /**
   * Checks if any checkbox is checked within a container
   * @param {HTMLElement} container - The container element
   * @return {boolean} True if at least one checkbox is checked
   */
  anyChecked(container) {
    if (!container) return false;
    const boxes = container.querySelectorAll('input[type="checkbox"]');
    for (const box of boxes) {
      if (box.checked) return true;
    }
    return false;
  }

  /**
   * Checks if at least one search scope is selected
   * @param {HTMLElement} container - The scope container element
   * @return {boolean} True if title or text search is selected
   */
  scopeSelected(container) {
    if (!container) return false;
    const title = container.querySelector('input[name="search_in_title"]');
    const text = container.querySelector('input[name="search_in_text"]');
    // search_in_title defaults to checked unless explicitly turned off
    const titleOn = !!(title && title.checked);
    const textOn = !!(text && text.checked);
    return titleOn || textOn;
  }

  /**
   * Highlights an element to indicate missing selection
   * @param {HTMLElement} el - The element to highlight
   * @return {void}
   */
  highlight(el) {
    if (!el) return;
    // Very thin, darker red rectangle with small offset to avoid overlapping content
    el.classList.add(
      "ring-1",
      "ring-red-700",
      "dark:ring-red-700",
      "ring-offset-2",
      "ring-offset-white",
      "dark:ring-offset-midnight"
    );
    setTimeout(() => {
      el.classList.remove(
        "ring-1",
        "ring-red-700",
        "dark:ring-red-700",
        "ring-offset-2",
        "ring-offset-white",
        "dark:ring-offset-midnight"
      );
    }, 1500);
  }

  /**
   * Shows immediate loading UI feedback during form submission
   * Clears previous status and displays skeleton loader
   * @return {void}
   */
  showImmediateLoadingUI() {
    try {
      document.querySelectorAll("[data-ww-search-failed]").forEach((el) => el.remove());
      const mount = document.querySelector("#search-status-mount");
      const frame = document.querySelector("turbo-frame#laws_list");

      // Do not render any loading pill under the search; rely on the frame's progress bar only.
      // Clear any previous indicators below the search, including a completed pill if present
      if (mount) mount.querySelectorAll(".frame-status-progress, .frame-status-pill").forEach((el) => el.remove());

      // 2) Hide the previous results and show a lightweight skeleton + top progress inside the results frame
      if (frame) {
        // The previous results are hidden, not removed: Turbo caches this page as it leaves it, and Back showed the
        // emptied frame, marked complete, with nothing in it (Sol, on live 1.1.28, 23:41:13Z, task 77).
        // turbo_cache_controller#restoreHeldResults shows them again and removes the loading marks before the
        // snapshot is taken.
        holdResults(frame);

        // Add thin indeterminate top progress bar
        const bar = document.createElement("div");
        bar.setAttribute("data-ww-client-loading", "");
        bar.className = "progress-top";
        bar.style.color = "var(--accent-600)";
        frame.appendChild(bar);

        // Add a minimal skeleton block
        const sk = document.createElement("div");
        sk.setAttribute("data-ww-client-loading", "");
        sk.className = "ww-client-skeleton bg-white dark:bg-gray-900 rounded-xl shadow-lg p-6 space-y-3";

        const lines = [
          "h-5 w-2/3",
          "h-4 w-5/6",
          "h-4 w-1/2",
          "h-5 w-1/2",
          "h-4 w-2/3",
          "h-4 w-1/3",
        ];
        lines.forEach((c) => {
          const d = document.createElement("div");
          d.className = `skeleton ${c} rounded`;
          sk.appendChild(d);
        });

        frame.appendChild(sk);
      }
    } catch (_) {
      // noop - do not block submit if anything goes wrong here
    }
  }
}
