/**
 * Application Entry Point
 * 
 * This is the main JavaScript entry point for the WetWijzer application.
 * It initializes Turbo Drive for fast page navigation and imports all controllers
 * and styles required by the application.
 * 
 * @module application
 * @see https://github.com/hotwired/turbo-rails
 * @see https://stimulus.hotwired.dev/
 */

// Import Turbo Drive for SPA-like navigation
// Turbo Drive intercepts all clicks on <a> links and updates the page without a full reload
import "@hotwired/turbo-rails";
import { Turbo } from "@hotwired/turbo-rails";

// Import all Stimulus controllers from the controllers directory
// This automatically registers them with the Stimulus application
import "@/controllers";

// Import the main application stylesheet
// This includes all the Tailwind CSS styles and custom SCSS
import '../stylesheets/application.scss';

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

// You can add any additional JavaScript initialization code here
// For example:
// - Setting up global event listeners
// - Initializing third-party libraries
// - Configuring application-wide settings

// Example: Add a global error handler
window.addEventListener('error', (event) => {
  console.error('Global error handler:', event.error || event);
});

// Example: Add a global unhandled promise rejection handler
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

