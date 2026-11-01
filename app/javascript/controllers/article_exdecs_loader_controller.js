import { Controller } from "@hotwired/stimulus";

// Controller for loading article-exdec mapping via AJAX and injecting into existing articles
// This avoids re-rendering all articles when force-loading exdec references
//
// Usage:
// <div data-controller="article-exdecs-loader" data-article-exdecs-loader-url-value="/laws/XXX/article_exdecs">
//   <button data-action="click->article-exdecs-loader#load">Load Exdecs</button>
// </div>
export default class extends Controller {
  static values = {
    url: String, // The endpoint URL to fetch exdec mapping JSON
    showLabel: String, // Localized toggle labels, passed in by the view
    hideLabel: String,
    incompleteMessage: String, // Localized notices for a partial or malformed response
    invalidMessage: String,
  };

  static targets = ["button", "loadingIndicator", "errorMessage", "successMessage", "emptyMessage", "toggleButton", "toggleButtonText", "warning"];

  initialize() {
    // Sections this controller injected, by article ID; it never touches any other section
    this.managedSections = new Map();

    // Identity of the current request: disconnect and every new load move it on, so a
    // continuation from an older request can tell it is stale
    this.requestGeneration = 0;
  }

  connect() {
    // Back on the page after a load was cancelled by leaving it, or restored from a page
    // snapshot taken mid-load (spinner showing, nothing in flight): offer the load again,
    // without an error or success claim
    const snapshotMidLoad = !this.inFlight && this.hasLoadingIndicatorTarget &&
      !this.loadingIndicatorTarget.classList.contains("hidden");
    if (this.cancelledLoad || snapshotMidLoad) {
      this.cancelledLoad = false;
      this.restoreRetryState();
    }
  }

  disconnect() {
    // Leaving the page (for example a Turbo visit to another law): invalidate this
    // controller's request first, then abort only its own fetch. Nothing is removed.
    this.requestGeneration += 1;
    const abortController = this.abortController;
    this.abortController = null;
    if (this.inFlight) {
      this.inFlight = false;
      this.cancelledLoad = true;
    }
    abortController?.abort();
  }

  // True while this request is the controller's current one and the controller is on the page
  isCurrentRequest(generation) {
    return generation === this.requestGeneration && this.element.isConnected;
  }

  async load(event) {
    event.preventDefault();

    // Ignore an action queued after this controller left the page.
    if (!this.element.isConnected) {
      return;
    }

    // One request at a time: a second click while a load is running does nothing
    if (this.inFlight) {
      return;
    }
    this.inFlight = true;

    const generation = ++this.requestGeneration;
    const abortController = new AbortController();
    this.abortController = abortController;

    // While the request runs, only the spinner shows: the "not loaded" warning
    // (which holds the button) and any earlier error or success notice are hidden
    this.warningElement()?.classList.add("hidden");
    if (this.hasErrorMessageTarget) {
      this.errorMessageTarget.textContent = "";
      this.errorMessageTarget.classList.add("hidden");
    }
    if (this.hasSuccessMessageTarget) {
      this.successMessageTarget.classList.add("hidden");
    }
    if (this.hasEmptyMessageTarget) {
      this.emptyMessageTarget.classList.add("hidden");
    }

    // Show loading state
    if (this.hasButtonTarget) {
      this.buttonTarget.disabled = true;
      this.buttonTarget.classList.add("opacity-50", "cursor-not-allowed");
    }

    // Show loading indicator if present
    if (this.hasLoadingIndicatorTarget) {
      this.loadingIndicatorTarget.classList.remove("hidden");
    }

    try {
      const response = await fetch(this.urlValue, {
        headers: {
          Accept: "application/json",
        },
        signal: abortController.signal,
      });

      // A request that was cancelled or superseded while waiting changes nothing
      if (!this.isCurrentRequest(generation)) {
        return;
      }

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      }

      let data = null;
      try {
        data = await response.json();
      } catch {
        // A body that is not JSON is handled below as an invalid response
      }

      // The same check after the body: an old law's references never reach a newer page
      if (!this.isCurrentRequest(generation)) {
        return;
      }

      // A failure the server reports keeps its reason; showErrorMessage() falls back when it is blank
      if (data?.success === false) {
        throw new Error(typeof data.error === "string" ? data.error : "");
      }

      // Anything that is not a well-formed mapping is invalid, never a success.
      // The payload itself is not echoed into the notice or the log.
      const exdecHtml = this.validExdecHtml(data);
      if (!exdecHtml) {
        this.showErrorMessage(this.invalidMessageValue);
        return;
      }

      // Sections this controller injected for articles the new mapping no longer lists are stale
      this.pruneManagedSections(exdecHtml);

      const requested = Object.keys(exdecHtml).length;
      if (requested === 0) {
        // A valid empty mapping: the load completed and there is nothing to add
        this.showNoReferencesMessage();
        return;
      }

      // Inject the exdec HTML into each article
      const applied = this.injectExdecs(exdecHtml);

      if (applied === requested) {
        // Hide the warning box and show success message
        this.showSuccessMessage(data.count);
      } else {
        // Some or all mapped articles are not on this page: keep what was applied,
        // never claim completion, and offer the retry
        this.showErrorMessage(this.incompleteMessageValue);
      }
    } catch (error) {
      // A cancelled or superseded request is silent: neither an error nor a success
      if (!this.isCurrentRequest(generation)) {
        return;
      }
      console.error("Failed to load article exdecs:", error);
      this.showErrorMessage(error.message);
    } finally {
      // Only the request that is still current settles the shared state, so an older
      // request finishing late never clears a newer one's in-flight flag or spinner
      if (this.isCurrentRequest(generation)) {
        // Hide loading indicator
        if (this.hasLoadingIndicatorTarget) {
          this.loadingIndicatorTarget.classList.add("hidden");
        }

        // The button itself is not re-enabled here: on success it stays hidden inside the
        // warning, and on failure showErrorMessage() restores the warning with a usable retry
        this.inFlight = false;
        this.abortController = null;

        // The toggle shows only when this controller has sections on the page
        this.syncToggleButton();
      }
    }
  }

  // The idle state with a usable load button, after a cancelled load; injected sections stay
  restoreRetryState() {
    if (this.hasLoadingIndicatorTarget) {
      this.loadingIndicatorTarget.classList.add("hidden");
    }

    this.warningElement()?.classList.remove("hidden");

    if (this.hasButtonTarget) {
      this.buttonTarget.disabled = false;
      this.buttonTarget.classList.remove("opacity-50", "cursor-not-allowed");
    }

    this.syncToggleButton();
  }

  // This controller's own "not loaded" warning; never a document-wide lookup
  warningElement() {
    if (this.hasWarningTarget) {
      return this.warningTarget;
    }
    return this.element.querySelector("[data-exdec-warning]");
  }

  // The exdec_html map when the payload is well formed, otherwise null: success is exactly
  // true, the map is a plain object, count is a non-negative integer equal to its entry
  // count, and every value is non-empty HTML
  validExdecHtml(data) {
    if (!data || typeof data !== "object" || data.success !== true) {
      return null;
    }

    const exdecHtml = data.exdec_html;
    if (!exdecHtml || typeof exdecHtml !== "object" || Array.isArray(exdecHtml)) {
      return null;
    }

    const entries = Object.entries(exdecHtml);
    if (!Number.isInteger(data.count) || data.count < 0 || data.count !== entries.length) {
      return null;
    }

    if (!entries.every(([, html]) => typeof html === "string" && html.trim() !== "")) {
      return null;
    }

    return exdecHtml;
  }

  // Remove the sections this controller injected for articles that are not in the mapping
  pruneManagedSections(exdecHtml) {
    this.managedSections.forEach((section, articleId) => {
      if (!Object.prototype.hasOwnProperty.call(exdecHtml, articleId)) {
        section.remove();
        this.managedSections.delete(articleId);
      }
    });
  }

  // The sections this controller injected that are still on the page
  managedSectionList() {
    return [...this.managedSections.values()].filter(section => section.isConnected);
  }

  // Returns how many mapped articles were found on the page and received their section
  injectExdecs(exdecHtml) {
    let applied = 0;

    // For each article ID in the mapping, find the article and inject the exdec section
    Object.entries(exdecHtml).forEach(([articleId, html]) => {
      // Find the article by its canonical ID (e.g., "art-5")
      const articleElement = document.getElementById(`art-${articleId}`);
      
      if (articleElement) {
        // Replace only a section this controller injected earlier; server-rendered
        // sections and other controllers' sections are left alone
        this.managedSections.get(articleId)?.remove();

        // Create a container for the exdec section
        const exdecContainer = document.createElement('div');
        exdecContainer.setAttribute('data-exdec-section', '');
        exdecContainer.innerHTML = html;

        // Insert after the article content
        articleElement.appendChild(exdecContainer);
        this.managedSections.set(articleId, exdecContainer);
        applied += 1;
      }
    });

    return applied;
  }

  showSuccessMessage(count) {
    // Keep this controller's warning box (yellow one about disabled exdecs) hidden
    this.warningElement()?.classList.add('hidden');

    // Hide any error messages
    if (this.hasErrorMessageTarget) {
      this.errorMessageTarget.classList.add('hidden');
    }

    // Show success message
    if (this.hasSuccessMessageTarget) {
      this.successMessageTarget.classList.remove('hidden');
    }

    // Show the toggle button so user can hide/show exdecs
    this.syncToggleButton();
  }

  // A completed load with an empty mapping: say so, without a success claim or a toggle
  showNoReferencesMessage() {
    this.warningElement()?.classList.add('hidden');

    if (this.hasErrorMessageTarget) {
      this.errorMessageTarget.classList.add('hidden');
    }

    if (this.hasSuccessMessageTarget) {
      this.successMessageTarget.classList.add('hidden');
    }

    if (this.hasEmptyMessageTarget) {
      this.emptyMessageTarget.classList.remove('hidden');
    }
  }

  showErrorMessage(message) {
    // Hide success message if it's showing
    if (this.hasSuccessMessageTarget) {
      this.successMessageTarget.classList.add('hidden');
    }

    // Show error with a non-empty reason
    if (this.hasErrorMessageTarget) {
      this.errorMessageTarget.textContent = typeof message === "string" && message.trim() ? message : "Unknown error occurred";
      this.errorMessageTarget.classList.remove("hidden");
    }

    // Bring back the warning, which holds the retry button
    this.warningElement()?.classList.remove("hidden");

    // Re-enable the "Laden" button so user can retry
    if (this.hasButtonTarget) {
      this.buttonTarget.disabled = false;
      this.buttonTarget.classList.remove("opacity-50", "cursor-not-allowed");
    }
  }

  // Show the toggle only while this controller has sections, labelled for their current state
  syncToggleButton() {
    if (!this.hasToggleButtonTarget) {
      return;
    }

    const exdecSections = this.managedSectionList();
    if (exdecSections.length === 0) {
      this.toggleButtonTarget.classList.add('hidden');
      return;
    }

    this.toggleButtonTarget.classList.remove('hidden');
    this.setToggleState(!exdecSections[0].classList.contains('hidden'));
  }

  // Button appearance and localized text for visible (active) or hidden sections
  setToggleState(sectionsVisible) {
    if (!this.hasToggleButtonTarget) {
      return;
    }

    if (sectionsVisible) {
      // Now showing, so button should say "Hide"
      this.toggleButtonTarget.classList.remove('btn-toggle-inactive');
      this.toggleButtonTarget.classList.add('btn-toggle-active', 'btn-toggle-exdecs');
    } else {
      // Now hiding, so button should say "Show"
      this.toggleButtonTarget.classList.remove('btn-toggle-active', 'btn-toggle-exdecs');
      this.toggleButtonTarget.classList.add('btn-toggle-inactive');
    }

    const label = sectionsVisible ? this.hideLabelValue : this.showLabelValue;
    if (this.hasToggleButtonTextTarget && label) {
      this.toggleButtonTextTarget.textContent = label;
    }
  }

  toggleExdecs(event) {
    event.preventDefault();

    // Only the sections this controller injected; with none left there is nothing to toggle
    const exdecSections = this.managedSectionList();
    if (exdecSections.length === 0) {
      this.syncToggleButton();
      return;
    }
    
    // Check current state (if first one is hidden, we're showing; otherwise hiding)
    const isCurrentlyHidden = exdecSections[0].classList.contains('hidden');
    
    // Toggle visibility
    exdecSections.forEach(section => {
      if (isCurrentlyHidden) {
        section.classList.remove('hidden');
      } else {
        section.classList.add('hidden');
      }
    });

    // Update button appearance and text
    this.setToggleState(isCurrentlyHidden);
  }
}
