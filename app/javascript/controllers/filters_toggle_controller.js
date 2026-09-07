import { Controller } from "@hotwired/stimulus";

// Controls the visibility of the filters panel rendered by
// app/views/laws/_filter_section.html.erb
// Usage (in index view):
// <div data-controller="filters-toggle"> ...
//   <button data-action="click->filters-toggle#toggle"
//           data-filters-toggle-target="button"
//           aria-controls="filters-panel"
//           aria-expanded="false">Filters</button>
//   ... partial renders <div id="filters-panel" data-filters-toggle-target="panel" ...>
// </div>
export default class extends Controller {
  static targets = ["panel", "button"]; 

  connect() {
    this.syncAria();
  }

  toggle() {
    if (!this.hasPanelTarget) return;
    this.panelTarget.classList.toggle("hidden");
    this.syncAria();
  }

  syncAria() {
    if (!this.hasPanelTarget) return;
    const expanded = !this.panelTarget.classList.contains("hidden");
    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-expanded", expanded ? "true" : "false");
    }
  }
}
