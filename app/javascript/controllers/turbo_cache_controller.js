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
// marked complete is not fetched again). A frame Turbo marked complete (loaded, not loading: Turbo removes the mark
// when a load starts) that comes back with a source and no content is fetched from its own source; a frame with
// rows, a frame Turbo is still loading, or a normal visit is left alone. The "busy" mark is no guide here: onLoad
// clears every one first, as a restored page carries them from the cache (Sol 16:44:13Z).
//
// The cause, found 2026-11-08 (Sol, on live 1.1.28, 23:41:13Z, task 77, reproduced in Chrome): a search submit emptied
// the legislation frame for its loading skeleton (search_validation_controller#showImmediateLoadingUI) before Turbo
// cached the page, so the snapshot held an empty frame marked complete. The submit now only hides the rows, and
// restoreHeldResults shows them again before the snapshot. And this repair never ran: Turbo replaces the body on a
// restore, so the controller that saw the restore visit was gone when the page loaded and its successor never knew;
// the restore is now remembered by the module (restoreVisitPending).
let restoreVisitPending = false;

// The rows a search submit hid (search_validation_controller#holdResults), shown again, and its loading marks removed,
// so the page Turbo caches is the page the reader saw.
export function restoreHeldResults(root) {
  root.querySelectorAll('[data-ww-client-loading]').forEach(el => el.remove());
  root.querySelectorAll('[data-ww-held-results]').forEach(el => {
    el.style.display = el.dataset.wwHeldDisplay || '';
    el.removeAttribute('data-ww-held-results');
    delete el.dataset.wwHeldDisplay;
  });
}

export function reloadEmptyFrames(root) {
  root.querySelectorAll('turbo-frame[src]').forEach(frame => {
    if (!frame.hasAttribute('complete') || frame.textContent.trim() !== '') return;
    if (typeof frame.reload === 'function') frame.reload();
  });
}

// Turbo caches a page as it is when the reader leaves it, so a search form changed for the next search came back on
// Back showing the next search's choices over this page's results (Sol, on live 1.1.21, 21:44:02Z: Kamer / Verslag /
// Nederlands / 2026 results under four "Alle" selects; and earlier, source boxes unticked after Back). Every GET
// form, which on this site is a search or filter form, is reset to what the server rendered for this page before
// the snapshot. Other forms (the chat, account forms) keep what the reader typed.
export function resetSearchForms(root) {
  root.querySelectorAll('form').forEach(form => {
    const method = (form.getAttribute('method') || 'get').toLowerCase();
    if (method === 'get' && typeof form.reset === 'function') form.reset();
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
    restoreHeldResults(document);
    resetSearchForms(document);
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
    // A section button (collapse) is left alone: its section's open or folded state is in the snapshot, and Turbo
    // dispatches this on the page still on screen, where open sections then said aria-expanded="false" (Sol
    // 02:20:35Z).
    document.querySelectorAll('[aria-expanded="true"]').forEach(el => {
      // Don't reset permanent elements
      if (!el.closest('[data-turbo-permanent]') && !el.matches?.('[data-collapse-target="button"]')) {
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

    if (restoreVisitPending) {
      restoreVisitPending = false;
      reloadEmptyFrames(document);
    }
  };

  onVisit = (event) => {
    restoreVisitPending = event?.detail?.action === 'restore';
  };
}
