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
  };

  static targets = ["button", "loadingIndicator", "errorMessage", "successMessage", "toggleButton", "toggleButtonText"];

  async load(event) {
    event.preventDefault();

    // Show loading state
    if (this.hasButtonTarget) {
      this.buttonTarget.disabled = true;
      this.buttonTarget.classList.add("opacity-50", "cursor-not-allowed");
    }

    // Show loading indicator if present
    if (this.hasLoadingIndicatorTarget) {
      this.loadingIndicatorTarget.classList.remove("hidden");
    }

    // Hide any previous error
    if (this.hasErrorMessageTarget) {
      this.errorMessageTarget.classList.add("hidden");
    }

    try {
      const response = await fetch(this.urlValue, {
        headers: {
          Accept: "application/json",
        },
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      }

      const data = await response.json();

      if (!data.success) {
        throw new Error(data.error || "Unknown error occurred");
      }

      // Inject the exdec HTML into each article
      this.injectExdecs(data.exdec_html);

      // Hide the warning box and show success message
      this.showSuccessMessage(data.count);
    } catch (error) {
      console.error("Failed to load article exdecs:", error);
      this.showErrorMessage(error.message);
    } finally {
      // Hide loading indicator
      if (this.hasLoadingIndicatorTarget) {
        this.loadingIndicatorTarget.classList.add("hidden");
      }

      // Note: Don't re-enable the "Laden" button here
      // If successful, it will be hidden by showSuccessMessage()
      // If error, it stays disabled to prevent retry confusion
    }
  }

  injectExdecs(exdecHtml) {
    // For each article ID in the mapping, find the article and inject the exdec section
    Object.entries(exdecHtml).forEach(([articleId, html]) => {
      // Find the article by its canonical ID (e.g., "art-5")
      const articleElement = document.getElementById(`art-${articleId}`);
      
      if (articleElement) {
        // Check if exdec section already exists
        const existingExdecSection = articleElement.querySelector('[data-exdec-section]');
        if (existingExdecSection) {
          existingExdecSection.remove();
        }

        // Create a container for the exdec section
        const exdecContainer = document.createElement('div');
        exdecContainer.setAttribute('data-exdec-section', '');
        exdecContainer.innerHTML = html;

        // Insert after the article content
        articleElement.appendChild(exdecContainer);
      }
    });
  }

  showSuccessMessage(count) {
    // Hide the warning box (yellow one about disabled exdecs)
    const warningBox = document.querySelector('[data-exdec-warning]');
    if (warningBox) {
      warningBox.classList.add('hidden');
    }

    // Hide any error messages
    if (this.hasErrorMessageTarget) {
      this.errorMessageTarget.classList.add('hidden');
    }

    // Show success message
    if (this.hasSuccessMessageTarget) {
      this.successMessageTarget.classList.remove('hidden');
    }

    // Show the toggle button so user can hide/show exdecs
    if (this.hasToggleButtonTarget) {
      this.toggleButtonTarget.classList.remove('hidden');
    }
  }

  showErrorMessage(message) {
    // Hide success message if it's showing
    if (this.hasSuccessMessageTarget) {
      this.successMessageTarget.classList.add('hidden');
    }

    // Show error with message
    if (this.hasErrorMessageTarget) {
      this.errorMessageTarget.textContent = message;
      this.errorMessageTarget.classList.remove("hidden");
    }

    // Re-enable the "Laden" button so user can retry
    if (this.hasButtonTarget) {
      this.buttonTarget.disabled = false;
      this.buttonTarget.classList.remove("opacity-50", "cursor-not-allowed");
    }
  }

  toggleExdecs(event) {
    event.preventDefault();

    // Find all dynamically injected exdec sections
    const exdecSections = document.querySelectorAll('[data-exdec-section]');
    
    // Check current state (if first one is hidden, we're showing; otherwise hiding)
    const isCurrentlyHidden = exdecSections[0]?.classList.contains('hidden');
    
    // Toggle visibility
    exdecSections.forEach(section => {
      if (isCurrentlyHidden) {
        section.classList.remove('hidden');
      } else {
        section.classList.add('hidden');
      }
    });

    // Update button appearance and text
    if (this.hasToggleButtonTarget) {
      if (isCurrentlyHidden) {
        // Now showing, so button should say "Hide"
        this.toggleButtonTarget.classList.remove('btn-toggle-inactive');
        this.toggleButtonTarget.classList.add('btn-toggle-active', 'btn-toggle-exdecs');
        if (this.hasToggleButtonTextTarget) {
          this.toggleButtonTextTarget.textContent = 'Verberg uitvoeringsbesluiten';
        }
      } else {
        // Now hiding, so button should say "Show"
        this.toggleButtonTarget.classList.remove('btn-toggle-active', 'btn-toggle-exdecs');
        this.toggleButtonTarget.classList.add('btn-toggle-inactive');
        if (this.hasToggleButtonTextTarget) {
          this.toggleButtonTextTarget.textContent = 'Toon uitvoeringsbesluiten';
        }
      }
    }
  }
}
