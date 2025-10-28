// WetWijzer Application Entry Point

import "@hotwired/turbo-rails";
import { Turbo } from "@hotwired/turbo-rails";
import "@/controllers";
import '../stylesheets/application.scss';

// Initialize server-side preferences store for logged-in users.
// This fires the GET /api/preferences fetch early so the cache is
// populated before any Stimulus controller calls prefs.get().
import { prefs } from '../services/preferences_store';
prefs.init();

// Show the Turbo progress bar immediately when a navigation or form submission starts
// Default is 500ms; setting to 0 ensures instant visual feedback
try {
  if (Turbo && Turbo.config && Turbo.config.drive) {
    Turbo.config.drive.progressBarDelay = 0;
  } else if (typeof Turbo.setProgressBarDelay === 'function') {
    // Fallback for older Turbo versions
    Turbo.setProgressBarDelay(0);
  }
} catch (_) {
  // No-op if Turbo is not available for some reason
}

// Turbo 8 confirm method for data-turbo-confirm
// NOTE: data-turbo-confirm must be on the FORM element (not the button)
// to work reliably. Use form: { data: { turbo_confirm: "..." } } in button_to.
Turbo.config.forms.confirm = (message, _formElement, _submitter) => {
  return Promise.resolve(window.confirm(message));
};

// Global error handlers
window.addEventListener('error', (event) => {
  console.error('Global error handler:', event.error || event);
});

window.addEventListener('unhandledrejection', (event) => {
  console.error('Unhandled promise rejection:', event.reason);
});

// Ensure hash-fragment scrolling works reliably with Turbo and fixed headers
function findAnchorElementById(id) {
  if (!id) return null;
  // Try exact id
  let el = document.getElementById(id);
  if (el) return el;
  // Try with/without 'section-' prefix for backward compatibility
  if (!id.startsWith('section-')) {
    el = document.getElementById(`section-${id}`);
    if (el) return el;
  } else {
    el = document.getElementById(id.replace(/^section-/, ''));
    if (el) return el;
  }
  return null;
}

function scrollToHash(targetHash) {
  const hash = typeof targetHash === 'string' ? targetHash : window.location.hash;
  if (!hash || hash.length < 2) return;
  const id = decodeURIComponent(hash.slice(1));
  const el = findAnchorElementById(id);
  if (el) {
    // Use native behavior; scroll-mt on elements handles header offset
    el.scrollIntoView({ behavior: 'auto', block: 'start', inline: 'nearest' });
  }
}

// Track whether we've processed the initial page load
let initialLoadHandled = false;

// Run after Turbo completes rendering
window.addEventListener('turbo:load', (event) => {
  // On initial page load, browser has already scrolled to hash
  // Skip our custom scroll handling to avoid jumping back
  if (!initialLoadHandled) {
    initialLoadHandled = true;
    return;
  }
  
  // For subsequent Turbo navigations, handle hash scrolling
  // Defer to allow controllers to connect and DOM to settle
  setTimeout(() => scrollToHash(), 0);
});

