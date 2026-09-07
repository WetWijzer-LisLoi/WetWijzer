// Manages the "auto-open on load" preference for the sidebar.
// Stores the preference in server-side profile (no localStorage).
//
// Usage:
// <input type="checkbox" data-sidebar-auto-open-target="checkbox" data-action="change->sidebar-auto-open#toggle">

import { Controller } from "@hotwired/stimulus";
import { prefs } from "../services/preferences_store";

export default class extends Controller {
  static targets = ["checkbox"];

  connect() {
    const autoOpen = prefs.get('sidebar_auto_open', false);
    
    if (this.hasCheckboxTarget) {
      this.checkboxTarget.checked = autoOpen;
    }
    
    // Dispatch event so sidebar-toggle can read the preference
    this.dispatchPreference(autoOpen);
  }

  toggle() {
    if (!this.hasCheckboxTarget) return;
    
    const autoOpen = this.checkboxTarget.checked;
    prefs.set('sidebar_auto_open', autoOpen);
    
    // Dispatch event so sidebar-toggle can update its behavior
    this.dispatchPreference(autoOpen);
  }

  dispatchPreference(autoOpen) {
    window.dispatchEvent(new CustomEvent("sidebar-auto-open-changed", {
      detail: { autoOpen }
    }));
  }

  // Static method to check preference (can be called from other controllers)
  static isAutoOpenEnabled() {
    return prefs.get('sidebar_auto_open', false);
  }
}
