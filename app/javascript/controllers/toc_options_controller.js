// Simple dropdown controller for TOC options (auto-open, follow scrolling)
// Usage:
// <div data-controller="toc-options">
//   <button data-action="click->toc-options#toggle">Options</button>
//   <div data-toc-options-target="menu" class="hidden">...options...</div>
// </div>

import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["menu", "button"];

  connect() {
    this.handleClickOutside = this.handleClickOutside.bind(this);
    document.addEventListener("click", this.handleClickOutside);
  }

  disconnect() {
    document.removeEventListener("click", this.handleClickOutside);
  }

  toggle(event) {
    event.stopPropagation();
    if (this.hasMenuTarget) {
      const isHidden = this.menuTarget.classList.contains("hidden");
      if (isHidden) {
        // Position the menu relative to the button using fixed positioning
        if (this.hasButtonTarget) {
          const rect = this.buttonTarget.getBoundingClientRect();
          this.menuTarget.style.top = `${rect.bottom + 4}px`;
          this.menuTarget.style.left = `${rect.left}px`;
        }
        this.menuTarget.classList.remove("hidden");
        if (this.hasButtonTarget) {
          this.buttonTarget.setAttribute("aria-expanded", "true");
        }
      } else {
        this.menuTarget.classList.add("hidden");
        if (this.hasButtonTarget) {
          this.buttonTarget.setAttribute("aria-expanded", "false");
        }
      }
    }
  }

  handleClickOutside(event) {
    if (!this.element.contains(event.target) && this.hasMenuTarget) {
      this.menuTarget.classList.add("hidden");
      if (this.hasButtonTarget) {
        this.buttonTarget.setAttribute("aria-expanded", "false");
      }
    }
  }
}
