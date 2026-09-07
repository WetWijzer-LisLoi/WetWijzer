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
  static targets = ["content", "icon", "button", "toggleText"];
  static values = { expanded: { type: Boolean, default: true } };

  connect() {
    // Check if DOM state matches expected state
    const currentlyCollapsed = this.element.classList.contains("is-collapsed");
    const shouldBeExpanded = this.expandedValue;
    
    // Only sync if there's a mismatch (DOM doesn't match data attribute)
    if (currentlyCollapsed === shouldBeExpanded) {
      this.syncNow();
    }
    
    // Otherwise, just update aria attributes without animation/transition
    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-expanded", shouldBeExpanded ? "true" : "false");
    }
  }

  toggle(event) {
    event?.preventDefault();
    this.expandedValue = !this.expandedValue;
    this.syncNow();
  }

  syncNow() {
    const expanded = this.expandedValue;
    
    // Toggle collapsed class on the controller element
    this.element.classList.toggle("is-collapsed", !expanded);
    
    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-expanded", expanded ? "true" : "false");
    }
    
    if (this.hasToggleTextTarget) {
      const showText = this.toggleTextTarget.dataset.collapseShowText;
      const hideText = this.toggleTextTarget.dataset.collapseHideText;
      this.toggleTextTarget.textContent = expanded ? hideText : showText;
    }
  }
}
