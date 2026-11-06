/**
 * Turbo Cache Controller
 * 
 * Manages Turbo's page cache to prevent stale data and improve back/forward navigation.
 * This controller addresses issues where navigating between search results and detail pages
 * can cause the index page to break after multiple back/forward navigations.
 * 
 * Features:
 * - Clears Turbo cache before caching to prevent stale data
 * - Removes temporary UI states (loading indicators, etc.)
 * - Ensures clean state for cache restoration
 * 
 * Usage:
 * Add to body or main container:
 * <div data-controller="turbo-cache">...</div>
 */
import { Controller } from "@hotwired/stimulus";

// After Back or Forward, a results frame can come back from Turbo's cache with nothing in it: Sol, on live 1.1.19
// (15:32:15Z), changed the legislation page size, went Back, and the restored page-2 list was empty with no error
// until a reload. The cause is not established (the cleanup above removes loading skeletons, and a restored frame
// marked complete is not fetched again). A frame with a source and no content after a restoration is fetched from
// its own source; a frame with rows, or a normal visit, is left alone.
export function reloadEmptyFrames(root) {
  root.querySelectorAll('turbo-frame[src]').forEach(frame => {
    if (frame.hasAttribute('busy') || frame.textContent.trim() !== '') return;
    if (typeof frame.reload === 'function') frame.reload();
  });
}

export default class extends Controller {
  connect() {
    // Listen for before-cache event to clean up before Turbo caches the page
    document.addEventListener("turbo:before-cache", this.beforeCache);
    
    // Listen for load event to ensure proper state restoration
    document.addEventListener("turbo:load", this.onLoad);
    document.addEventListener("turbo:visit", this.onVisit);
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.beforeCache);
    document.removeEventListener("turbo:load", this.onLoad);
    document.removeEventListener("turbo:visit", this.onVisit);
  }

  /**
   * Cleanup before Turbo caches the current page
   * Removes temporary states that shouldn't be cached
   */
  beforeCache = () => {
    // Remove loading skeletons
    document.querySelectorAll('.loading-skeleton').forEach(el => {
      el.remove();
    });

    // Remove progress indicators
    document.querySelectorAll('.progress-top').forEach(el => {
      el.style.display = 'none';
    });

    // Remove temporary status messages
    document.querySelectorAll('[data-frame-status-mount]').forEach(el => {
      if (el) el.innerHTML = '';
    });

    // Reset chatbot loading state to prevent stuck UI after back/forward navigation
    document.querySelectorAll('[data-chatbot-target="loading"]').forEach(el => {
      el.classList.add('hidden');
    });
    document.querySelectorAll('[data-chatbot-target="input"]').forEach(el => {
      el.disabled = false;
    });
    document.querySelectorAll('[data-chatbot-target="sendButton"]').forEach(el => {
      el.disabled = false;
    });
    document.querySelectorAll('[data-chatbot-target="typingIndicator"]').forEach(el => {
      el.classList.add('hidden');
    });

    // Reset any expanded/collapsed states that might cause issues
    document.querySelectorAll('[aria-expanded="true"]').forEach(el => {
      // Don't reset permanent elements
      if (!el.closest('[data-turbo-permanent]')) {
        el.setAttribute('aria-expanded', 'false');
      }
    });

    // Remove any stuck overlay backdrops
    document.querySelectorAll('[data-sidebar-toggle-target="backdrop"]').forEach(el => {
      if (el.classList.contains('block') || !el.classList.contains('hidden')) {
        el.classList.remove('block');
        el.classList.add('hidden');
      }
    });
  };

  /**
   * Ensure proper state on page load/restoration
   */
  onLoad = () => {
    // Ensure body overflow is reset (in case modals/sidebars left it locked)
    document.body.style.overflow = '';
    
    // Clear any lingering Turbo frame loading states
    document.querySelectorAll('turbo-frame[busy]').forEach(frame => {
      frame.removeAttribute('busy');
    });

    if (this.restoring) {
      this.restoring = false;
      reloadEmptyFrames(document);
    }
  };

  onVisit = (event) => {
    this.restoring = event?.detail?.action === 'restore';
  };
}
