import { Controller } from "@hotwired/stimulus";

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
      const mount = document.querySelector("#search-status-mount");
      const frame = document.querySelector("turbo-frame#laws_list");

      // Do not render any loading pill under the search; rely on the frame's progress bar only.
      // Clear any previous indicators below the search, including a completed pill if present
      if (mount) mount.querySelectorAll(".frame-status-progress, .frame-status-pill").forEach((el) => el.remove());

      // 2) Clear previous results and show a lightweight skeleton + top progress inside the results frame
      if (frame) {
        // Remove any previous results immediately to avoid overlap/flicker
        frame.innerHTML = "";

        // Add thin indeterminate top progress bar
        const bar = document.createElement("div");
        bar.className = "progress-top text-blue-600 dark:text-sky";
        frame.appendChild(bar);

        // Add a minimal skeleton block
        const sk = document.createElement("div");
        sk.className = "ww-client-skeleton bg-white dark:bg-midnight rounded-xl shadow-lg p-6 space-y-3";

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
      // noop — do not block submit if anything goes wrong here
    }
  }
}
