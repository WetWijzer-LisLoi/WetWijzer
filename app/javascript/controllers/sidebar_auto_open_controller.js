// Manages the "auto-open on load" preference for the sidebar.
// Stores the preference in localStorage and syncs with the sidebar-toggle controller.
//
// Usage:
// <input type="checkbox" data-sidebar-auto-open-target="checkbox" data-action="change->sidebar-auto-open#toggle">

import { Controller } from "@hotwired/stimulus";

const STORAGE_KEY = "wetwijzer_sidebar_auto_open";

export default class extends Controller {
  static targets = ["checkbox"];

  connect() {
    // Load saved preference from localStorage
    const saved = localStorage.getItem(STORAGE_KEY);
    const autoOpen = saved === "1";
    
    if (this.hasCheckboxTarget) {
      this.checkboxTarget.checked = autoOpen;
    }
    
    // Dispatch event so sidebar-toggle can read the preference
    this.dispatchPreference(autoOpen);
  }

  toggle() {
    if (!this.hasCheckboxTarget) return;
    
    const autoOpen = this.checkboxTarget.checked;
    localStorage.setItem(STORAGE_KEY, autoOpen ? "1" : "0");
    
    // Dispatch event so sidebar-toggle can update its behavior
    this.dispatchPreference(autoOpen);
  }

  dispatchPreference(autoOpen) {
    // Dispatch a custom event that sidebar-toggle can listen to
    window.dispatchEvent(new CustomEvent("sidebar-auto-open-changed", {
      detail: { autoOpen }
    }));
  }

  // Static method to check preference (can be called from other controllers)
  static isAutoOpenEnabled() {
    return localStorage.getItem(STORAGE_KEY) === "1";
  }
}
