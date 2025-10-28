import { Controller } from "@hotwired/stimulus";

// A generic collapsible section controller.
// Usage:
// <div data-controller="collapse">
//   <button data-action="collapse#toggle" data-collapse-target="button" aria-expanded="true">
//     <svg data-collapse-target="icon">...</svg>
//   </button>
//   <div data-collapse-target="content"> ... </div>
// </div>
export default class extends Controller {
  static targets = ["content", "icon", "button"];
  static values = { expanded: { type: Boolean, default: true } };

  connect() {
    this.sync();
  }

  toggle(event) {
    this.expandedValue = !this.expandedValue;
    this.sync();
  }

  sync() {
    const expanded = this.expandedValue;
    
    // Toggle collapsed class on the controller element
    this.element.classList.toggle("is-collapsed", !expanded);
    
    if (this.hasContentTarget) {
      // Content visibility is handled by CSS based on is-collapsed class
    }
    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-expanded", expanded ? "true" : "false");
    }
    if (this.hasIconTarget) {
      // Icon rotation is handled by CSS based on aria-expanded
    }
  }
}
