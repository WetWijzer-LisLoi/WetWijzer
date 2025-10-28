import { Controller } from "@hotwired/stimulus";

// Toggles the visibility of the TOC sidebar on small screens and
// auto-shows it on desktop when the Tekst section is in view.
// Usage:
// <div data-controller="sidebar-toggle">
//   <button data-sidebar-toggle-target="button" data-action="sidebar-toggle#toggle" aria-expanded="false">...</button>
//   ...
//   <div data-sidebar-toggle-target="panel" class="hidden lg:w-80 ..."> ...sidebar... </div>
//   <div data-sidebar-toggle-target="trigger"> ...Tekst/articles section wrapper... </div>
// </div>
export default class extends Controller {
  static targets = ["panel", "button", "trigger", "backdrop"];

  connect() {
    this.sync();
    // Positioning Strategy:
    // - Mobile collapsed: fixed left-0 -translate-x-full (off-screen)
    // - Mobile expanded: fixed left-0 translate-x-0 (on-screen overlay)
    // - Desktop collapsed: fixed left-0 with custom peek transform (narrow clickable sliver)
    // - Desktop expanded: fixed left-0 top-50% translateX(0) translateY(-50%) (centered overlay)
    
    // Collapsed classes/state for each breakpoint
    this.collapsedMobileClass = "-translate-x-full";
    this.collapsedDesktopClass = "ww-peek"; // sentinel for collapsed-on-desktop state
    // Collapsed desktop sliver width (narrower)
    this.peekVisiblePx = 28;
    this.collapsedDesktopTransform = `translateX(calc(-100% + ${this.peekVisiblePx}px))`;
    // Small visual nudge (px) to align the collapsed handle exactly; override via data-sliver-nudge-y
    try {
      const n = parseInt(this.element.getAttribute('data-sliver-nudge-y') || "-2", 10);
      this.sliverNudgeYPx = Number.isFinite(n) ? n : -2;
    } catch (_) { this.sliverNudgeYPx = -2; }
    // Set up auto-show on desktop when the Tekst section is in view (lg ≥ 1024px)
    this.desktopMedia = window.matchMedia && window.matchMedia("(min-width: 1024px)");

    // Start state: desktop shows a peek aligned with main cards, mobile stays collapsed off-screen
    if (this.hasPanelTarget) {
      try {
        const isDesktop = this.desktopMedia && this.desktopMedia.matches;
        if (isDesktop) {
          this.panelTarget.classList.remove('hidden');
          this.panelTarget.classList.remove('translate-x-0');
          this.panelTarget.classList.remove(this.collapsedMobileClass);
          this.panelTarget.classList.add(this.collapsedDesktopClass);
          // Desktop collapsed: remove from flow so content can use full width; leave a slim clickable edge
          this.panelTarget.style.position = 'fixed';
          // Use consistent 50% + translateY(-50%) for vertical centering
          this.panelTarget.style.top = '50%';
          this.panelTarget.style.bottom = 'auto';  // Override class-based bottom: 0
          this.panelTarget.style.left = '0px';
          this.panelTarget.style.zIndex = '40';
          // Combine horizontal peek with vertical centering
          this.panelTarget.style.transform = `${this.collapsedDesktopTransform} translateY(-50%)`;
          // Keep pointer events on so the sliver/handle is clickable
          this.panelTarget.style.pointerEvents = '';
          // Hint that the edge can be pulled/clicked
          this.panelTarget.style.cursor = 'ew-resize';
          // Make internal TOC inert and hide internals while collapsed
          this.setCollapsedInert(true);
        } else {
          // Mobile: keep collapsed off-screen until user opens it
          this.panelTarget.classList.remove('translate-x-0');
          this.panelTarget.classList.remove(this.collapsedDesktopClass);
          this.panelTarget.classList.add(this.collapsedMobileClass);
          this.clearPeek();
          // Keep hidden until first open to avoid layout flash
          // Note: showMobilePanel will remove 'hidden' before animating in
          // Leave 'hidden' as-is from markup
          this.panelTarget.style.pointerEvents = 'none';
          const btns = this.buttonTargets && this.buttonTargets.length ? this.buttonTargets : (this.hasButtonTarget ? [this.buttonTarget] : []);
          btns.forEach((btn) => btn.style.pointerEvents = 'auto');
        }
      } catch (_) {}
      this.sync();
    }

    // Auto-open only triggers when articles turbo frame loads (not on initial page load)

    // Bind handlers
    this.handleMediaChange = this.handleMediaChange?.bind(this) || ((e) => this.onMediaChange(e));
    this.handleTurboFrameLoad = this.handleTurboFrameLoad?.bind(this) || ((e) => this.onTurboFrameLoad(e));
    this.handleKeydown = this.handleKeydown?.bind(this) || ((e) => this.onKeydown(e));
    this.handleHashChange = this.handleHashChange?.bind(this) || ((e) => this.onHashChange(e));
    this.openedOnce = false;
    // Gate auto-open on desktop to once per page load to avoid jitter
    this.autoOpenConsumed = false;
    // Track if the user has scrolled to allow auto-open
    this.didUserScroll = false;
    // Suppress auto-open on hashchange immediately after an internal TOC/jump click
    this.suppressHashOpenUntil = 0;
    this.onScroll = this.onScroll?.bind(this) || ((e) => this.handleScrollEvent(e));
    // Guard to prevent double-toggle when auto-expanding via sliver and then clicking the button
    this.suppressToggleUntil = 0;
    // Measurement and resize handling
    this.computeMeasurements = this.computeMeasurements?.bind(this) || (() => this.recomputeMeasurements());
    this.recomputeMeasurements();

    // Listen to desktop breakpoint changes and Turbo frame loads
    if (this.desktopMedia && this.desktopMedia.addEventListener) {
      this.desktopMedia.addEventListener('change', this.handleMediaChange);
    }
    document.addEventListener('turbo:frame-load', this.handleTurboFrameLoad);
    document.addEventListener('keydown', this.handleKeydown);
    window.addEventListener('hashchange', this.handleHashChange);
    window.addEventListener('scroll', this.onScroll, { passive: true });
    window.addEventListener('resize', this.computeMeasurements, { passive: true });

    // Auto-open only triggers when articles turbo frame loads (not on hash)

    // Desktop relies on normal flex/sticky layout; no extra padding needed

    // If user interacts with the collapsed panel on desktop, auto-expand so clicks work
    try {
      this.handlePanelPointerDown = (e) => {
        const isDesktop = this.desktopMedia && this.desktopMedia.matches;
        if (!isDesktop) return;
        if (!this.hasPanelTarget) return;
        // If the pointerdown originated on the explicit toggle button, let the button handle it
        if (e && e.target && e.target.closest && e.target.closest('[data-sidebar-toggle-target="button"]')) return;
        const expanded = this.panelTarget.classList.contains('translate-x-0');
        if (!expanded) {
          // Auto-expand from sliver; suppress the very next toggle for a short time to avoid re-collapse
          try { this.suppressToggleUntil = Date.now() + 400; } catch (_) {}
          this.showDesktopPanel();
          this.openedOnce = true;
        }
      };
      if (this.hasPanelTarget) this.panelTarget.addEventListener('pointerdown', this.handlePanelPointerDown, { capture: true });
      // Also allow clicking any visible part of the TOC card to expand when collapsed
      this._tocCardEl = this.element.querySelector('#toc-card-sidebar');
      if (this._tocCardEl) {
        this.handleCardPointerDown = (e) => {
          const isDesktop = this.desktopMedia && this.desktopMedia.matches;
          if (!isDesktop) return;
          if (!this.hasPanelTarget) return;
          // If clicking the explicit toggle button, let the button handle it
          if (e && e.target && e.target.closest && e.target.closest('[data-sidebar-toggle-target="button"]')) return;
          const expanded = this.panelTarget.classList.contains('translate-x-0');
          if (!expanded) {
            try { this.suppressToggleUntil = Date.now() + 400; } catch (_) {}
            this.showDesktopPanel();
            this.openedOnce = true;
            try { e.stopPropagation(); e.preventDefault(); } catch (_) {}
          }
        };
        this._tocCardEl.addEventListener('pointerdown', this.handleCardPointerDown, { capture: true });
      }
    } catch (_) {}

    // Desktop sidebar stays open - user can only close via toggle button
    // (Edge-click-to-close feature disabled to keep sidebar visible)
    try {
      this.edgeClosePx = 48; // kept for cursor feedback
      this.handlePanelClick = (e) => {
        // Desktop: no auto-close behavior, user controls via button
        // This handler is kept minimal for potential future use
      };
      // Note: click handler not attached since we don't want edge-click-to-close on desktop
    } catch (_) {}

    // Pointer cursor feedback for clickable zones
    try {
      this.handlePanelPointerMove = (e) => {
        const isDesktop = this.desktopMedia && this.desktopMedia.matches;
        if (!isDesktop) return;
        if (!this.hasPanelTarget) return;
        const expanded = this.panelTarget.classList.contains('translate-x-0');
        if (expanded) {
          // When expanded, no special cursor (edge-click-to-close disabled)
          this.panelTarget.style.cursor = '';
        } else {
          // Collapsed sliver: whole sliver is clickable to expand
          this.panelTarget.style.cursor = 'ew-resize';
        }
      };
      this.handlePanelPointerLeave = () => {
        const isDesktop = this.desktopMedia && this.desktopMedia.matches;
        if (!isDesktop) return;
        if (!this.hasPanelTarget) return;
        const expanded = this.panelTarget.classList.contains('translate-x-0');
        if (expanded) {
          this.panelTarget.style.cursor = '';
        } else {
          this.panelTarget.style.cursor = 'ew-resize';
        }
      };
      if (this.hasPanelTarget) {
        this.panelTarget.addEventListener('pointermove', this.handlePanelPointerMove, { capture: true });
        this.panelTarget.addEventListener('pointerleave', this.handlePanelPointerLeave, { capture: true });
      }
    } catch (_) {}

    // Backdrop click closes on mobile
    if (this.hasBackdropTarget) {
      this.backdropTarget.addEventListener('click', () => this.hideMobilePanel());
    }

    // Click inside panel but outside the TOC card closes on mobile
    try {
      this.handlePanelOutsideClick = (e) => {
        const isDesktop = this.desktopMedia && this.desktopMedia.matches;
        if (isDesktop) return; // only on mobile
        if (!this.hasPanelTarget) return;
        const card = this.panelTarget.querySelector('#toc-card-sidebar');
        if (!card) return;
        // If click is not within the card, close the panel
        const withinCard = e.target && (e.target === card || (e.target.closest && e.target.closest('#toc-card-sidebar')));
        if (!withinCard) this.hideMobilePanel();
      };
      if (this.hasPanelTarget) this.panelTarget.addEventListener('click', this.handlePanelOutsideClick, { capture: true });
    } catch (_) {}

    // Auto-close after using the sidebar:
    // - Desktop: keep sidebar open (don't auto-close)
    // - Mobile: close when a TOC link is clicked (jump menu on mobile is outside the sidebar)
    try {
      this.handlePanelInnerClick = (e) => {
        if (!this.hasPanelTarget) return;
        const isDesktop = this.desktopMedia && this.desktopMedia.matches;
        const anchor = e && e.target && e.target.closest && e.target.closest('#toc-card-sidebar .toc-navigation a.toc-link');

        // On mobile: only act on TOC anchor clicks
        if (!isDesktop && !anchor) return;
        // On desktop: don't auto-close, let user keep sidebar open
        if (isDesktop) return;

        // Prevent immediate auto-open on hashchange from our own click
        try { this.suppressHashOpenUntil = Date.now() + 800; } catch (_) {}
        try { this.autoOpenConsumed = true; } catch (_) {}

        // Close on mobile after letting navigation/hash update proceed
        try {
          setTimeout(() => {
            try {
              this.hideMobilePanel();
            } catch (_) {}
          }, 0);
        } catch (_) {}
      };
      if (this.hasPanelTarget) this.panelTarget.addEventListener('click', this.handlePanelInnerClick, { capture: true });
    } catch (_) {}
  }

  // Position the sliver overlay to be vertically centered
  updateSliverHandlePosition() {
    try {
      if (!this._sliverHandleEl) return;
      if (!this.hasPanelTarget) return;
      // Simple CSS-based centering - no DOM manipulation needed
      const isCollapsed = !this.panelTarget.classList.contains('translate-x-0');
      if (isCollapsed) {
        this._sliverHandleEl.style.display = 'flex';
        this._sliverHandleEl.style.alignItems = 'center';
        this._sliverHandleEl.style.justifyContent = 'center';
      } else {
        this._sliverHandleEl.style.display = '';
        this._sliverHandleEl.style.alignItems = '';
        this._sliverHandleEl.style.justifyContent = '';
      }
    } catch (_) {}
  }

  // REMOVED: findContentEl and flexGapPx - no longer needed since sidebar always overlays

  toggle(e) {
    if (!this.hasPanelTarget) return;
    const isDesktop = this.desktopMedia && this.desktopMedia.matches;
    // If we just auto-expanded via sliver, ignore the immediate follow-up click to prevent re-collapse
    try {
      if (e && typeof this.suppressToggleUntil === 'number' && Date.now() < this.suppressToggleUntil) {
        try { e.stopPropagation(); e.preventDefault(); } catch (_) {}
        return;
      }
    } catch (_) {}
    if (isDesktop) {
      // Desktop: slide in/out
      const expanded = this.panelTarget.classList.contains('translate-x-0');
      if (expanded) {
        this.hideDesktopPanel();
      } else {
        this.showDesktopPanel();
        this.openedOnce = true;
        try { this.panelTarget.scrollIntoView({ behavior: "smooth", block: "start", inline: "nearest" }); } catch (_) {}
      }
      // Track that user manually touched the sidebar - don't auto-open again on this page
      this.userManuallyTouched = true;
    } else {
      // Mobile: slide from the left with backdrop
      const expanded = this.panelTarget.classList.contains('translate-x-0');
      if (expanded) {
        this.hideMobilePanel();
      } else {
        this.showMobilePanel();
      }
    }
    // Clear suppression after handling a genuine toggle
    try { this.suppressToggleUntil = 0; } catch (_) {}
  }

  observeIfNeeded() {
    if (!this.hasTriggerTarget) return;
    if (!this.desktopMedia || !this.desktopMedia.matches) return;

    // Create IntersectionObserver to toggle panel based on Tekst visibility
    // Use a zero threshold; the trigger is a tall container (the articles area),
    // so a high intersectionRatio is never reached. We rely on its position
    // relative to the viewport to decide when to auto-open.
    const opts = { root: null, rootMargin: "0px", threshold: 0 };
    // Reset any previous observer
    if (this.io) {
      try { this.io.disconnect(); } catch (_) { /* no-op */ }
      this.io = null;
    }

    this.io = new IntersectionObserver((entries) => {
      const entry = entries[0];
      if (!this.hasPanelTarget) return;
      const isDesktop = this.desktopMedia && this.desktopMedia.matches;
      if (!isDesktop) return;
      // Avoid auto-opening immediately on load if the trigger starts in view; wait for a user scroll
      if (!this.didUserScroll) { this.sync(); return; }
      const rect = this.triggerTarget?.getBoundingClientRect?.() || { top: Infinity, bottom: -Infinity };
      const inViewport = !!(entry && entry.isIntersecting);
      const notPast = rect.bottom > 80; // keep open until we scrolled past the entire section
      if (!this.autoOpenConsumed && inViewport && notPast && this.hasEligibleSectionHeading()) {
        this.showDesktopPanel();
        this.openedOnce = true;
        this.autoOpenConsumed = true;
        this.sync();
      }
    }, opts);

    try {
      this.io.observe(this.triggerTarget);
    } catch (_) {
      // no-op
    }

    // Do not force an initial state here; we start in peek and wait for observer callbacks
  }

  disconnect() {
    if (this.io) {
      try { this.io.disconnect(); } catch (_) { /* no-op */ }
      this.io = null;
    }
    if (this.desktopMedia && this.desktopMedia.removeEventListener) {
      try { this.desktopMedia.removeEventListener('change', this.handleMediaChange); } catch (_) { /* no-op */ }
    }
    try { document.removeEventListener('turbo:frame-load', this.handleTurboFrameLoad); } catch (_) { /* no-op */ }
    try { document.removeEventListener('keydown', this.handleKeydown); } catch (_) { /* no-op */ }
    try { if (this.hasPanelTarget && this.handlePanelPointerDown) this.panelTarget.removeEventListener('pointerdown', this.handlePanelPointerDown, { capture: true }); } catch (_) { /* no-op */ }
    try { if (this.hasPanelTarget && this.handlePanelClick) this.panelTarget.removeEventListener('click', this.handlePanelClick, { capture: true }); } catch (_) { /* no-op */ }
    try { if (this.hasPanelTarget && this.handlePanelPointerMove) this.panelTarget.removeEventListener('pointermove', this.handlePanelPointerMove, { capture: true }); } catch (_) { /* no-op */ }
    try { if (this.hasPanelTarget && this.handlePanelPointerLeave) this.panelTarget.removeEventListener('pointerleave', this.handlePanelPointerLeave, { capture: true }); } catch (_) { /* no-op */ }
    try { if (this.hasPanelTarget && this.handlePanelOutsideClick) this.panelTarget.removeEventListener('click', this.handlePanelOutsideClick, { capture: true }); } catch (_) { /* no-op */ }
    try { if (this.hasPanelTarget && this.handlePanelInnerClick) this.panelTarget.removeEventListener('click', this.handlePanelInnerClick, { capture: true }); } catch (_) { /* no-op */ }
    try { if (this._tocCardEl && this.handleCardPointerDown) this._tocCardEl.removeEventListener('pointerdown', this.handleCardPointerDown, { capture: true }); } catch (_) { /* no-op */ }
    try { window.removeEventListener('hashchange', this.handleHashChange); } catch (_) { /* no-op */ }
    try { window.removeEventListener('scroll', this.onScroll, { passive: true }); } catch (_) { /* no-op */ }
    try { window.removeEventListener('resize', this.computeMeasurements, { passive: true }); } catch (_) { /* no-op */ }
    // No content offset to clear - sidebar always overlays
  }

  sync() {
    if (!this.hasPanelTarget) return;
    const expanded = this.panelTarget.classList.contains('translate-x-0');
    const value = expanded ? "true" : "false";
    if (this.buttonTargets && this.buttonTargets.length) {
      this.buttonTargets.forEach((btn) => btn.setAttribute("aria-expanded", value));
    } else if (this.hasButtonTarget) {
      // Fallback: single button target
      this.buttonTarget.setAttribute("aria-expanded", value);
    }
    // On mobile, keep the floating toggle button visible so layout doesn't shift
    try {
      const isDesktop = this.desktopMedia && this.desktopMedia.matches;
      if (!isDesktop && this.buttonTargets && this.buttonTargets.length) {
        this.buttonTargets.forEach((btn) => {
          if (btn.hasAttribute('data-sidebar-toggle-floating')) {
            btn.classList.remove('hidden');
          }
        });
      }
    } catch (_) {}
    // Rotate any arrow icons on the handle(s) to suggest direction
    try {
      const arrows = this.element.querySelectorAll('[data-sidebar-toggle-arrow]');
      arrows.forEach((el) => {
        if (expanded) {
          el.classList.remove('rotate-180'); // show "<" for closing to left
        } else {
          el.classList.add('rotate-180'); // show ">" for opening to right
        }
      });
    } catch (_) {}
  }

  applyPeek() {
    // DEPRECATED: Now handled inline with combined transforms (translateX + translateY)
    // Keeping function for backward compatibility but no longer sets transform directly
    try {
      const isDesktop = this.desktopMedia && this.desktopMedia.matches;
      if (isDesktop) {
        // Clear any accidental width overrides from previous versions
        this.panelTarget.style.width = '';
        this.panelTarget.style.minWidth = '';
        this.panelTarget.style.maxWidth = '';
      }
    } catch (_) {}
  }

  clearPeek() {
    try {
      // Clear both transform and width overrides
      this.panelTarget.style.transform = '';
      this.panelTarget.style.width = '';
      this.panelTarget.style.minWidth = '';
      this.panelTarget.style.maxWidth = '';
    } catch (_) {}
  }

  // Toggle inert/visibility for internal TOC content while collapsed on desktop
  setCollapsedInert(makeInert) {
    try {
      if (!this._tocCardEl) this._tocCardEl = this.element.querySelector('#toc-card-sidebar');
      const card = this._tocCardEl;
      if (!card) return;
      
      const nav = card.querySelector('.toc-navigation');

      if (makeInert) {
        // Prevent focus/interaction but keep the card box (shadow/border) visible
        card.setAttribute('inert', '');
        card.style.pointerEvents = 'none';
        // Allow card border/shadow to remain visible near the sliver
        this.panelTarget.style.overflow = 'hidden';
        this.panelTarget.style.background = 'transparent';
        card.style.overflow = 'hidden';
        if (nav) {
          // When collapsed, never allow the TOC list itself to capture scroll
          nav.style.overflowY = 'hidden';
          nav.style.maxHeight = '';
        }
        
        // Hide internal scrolling/visuals
        const scrollEls = card.querySelectorAll('.overflow-y-auto, .overflow-y-scroll');
        const jumpSelect = card.querySelector('[data-controller="jump-select"]');
        const followLabel = card.querySelector('label:has(input[type="checkbox"])');
        scrollEls.forEach((el) => el.style.overflow = 'hidden');
        if (nav) {
          nav.style.opacity = '0';
          nav.style.pointerEvents = 'none';
        }
        if (jumpSelect) {
          jumpSelect.style.opacity = '0';
          jumpSelect.style.pointerEvents = 'none';
        }
        if (followLabel) {
          followLabel.style.opacity = '0';
          followLabel.style.pointerEvents = 'none';
        }
        
        // Ensure sliver overlay exists
        this.ensureSliverOverlays();
        
        // Recenter on next frame
        if (this._recenterRaf) cancelAnimationFrame(this._recenterRaf);
        this._recenterRaf = requestAnimationFrame(() => {
          this._recenterRaf = null;
          this.recomputeMeasurements();
        });
      } else {
        // Restore interactivity
        card.removeAttribute('inert');
        card.style.pointerEvents = '';
        this.panelTarget.style.overflow = '';
        this.panelTarget.style.background = '';
        card.style.overflow = '';
        if (nav) {
          // When expanded, force the TOC list itself to be scrollable so wheel events
          // over the sidebar move the sidebar, not the main page.
          nav.style.overflowY = 'auto';
          nav.style.maxHeight = 'calc(100vh - 200px)';
        }
        
        const scrollEls = card.querySelectorAll('.overflow-y-auto, .overflow-y-scroll');
        const jumpSelect = card.querySelector('[data-controller="jump-select"]');
        const followLabel = card.querySelector('label:has(input[type="checkbox"])');
        scrollEls.forEach((el) => el.style.overflow = '');
        if (nav) {
          nav.style.opacity = '';
          nav.style.pointerEvents = '';
        }
        if (jumpSelect) {
          jumpSelect.style.opacity = '';
          jumpSelect.style.pointerEvents = '';
        }
        if (followLabel) {
          followLabel.style.opacity = '';
          followLabel.style.pointerEvents = '';
        }
        
        // Remove overlays
        this.removeSliverOverlays();
      }
    } catch (_) {}
  }

  // Create/update overlays: a content cover inside the card and a transparent, clickable sliver on the panel
  ensureSliverOverlays() {
    try {
      if (!this._tocCardEl) this._tocCardEl = this.element.querySelector('#toc-card-sidebar');
      const card = this._tocCardEl;
      if (!card || !this.hasPanelTarget) return;
      const cs = window.getComputedStyle(card);
      const bg = cs.backgroundColor || 'white';
      const br = cs.borderRadius || '';
      // Some themes apply border-color via variables; fallback handled by browser
      const borderColor = cs.borderColor || 'rgba(0,0,0,0.1)';

      // Add a cover to hide the card's internal content but keep the card's shell visual
      if (!this._sliverCoverEl) {
        const cover = document.createElement('div');
        cover.className = 'ww-sliver-cover';
        cover.style.position = 'absolute';
        cover.style.top = '0';
        cover.style.left = '0';
        cover.style.bottom = '0';
        cover.style.right = `${this.peekVisiblePx}px`;
        cover.style.zIndex = '1000'; // below handle overlay but above TOC content
        cover.style.pointerEvents = 'none';
        // Match card background to avoid visible seams
        cover.style.backgroundColor = bg;
        // Match card rounding
        cover.style.borderRadius = br;
        // Ensure card can host absolutely positioned children
        if (getComputedStyle(card).position === 'static') card.style.position = 'relative';
        card.insertBefore(cover, card.firstChild);
        this._sliverCoverEl = cover;
      } else {
        try {
          this._sliverCoverEl.style.right = `${this.peekVisiblePx}px`;
          this._sliverCoverEl.style.backgroundColor = bg;
          this._sliverCoverEl.style.borderRadius = br;
        } catch (_) {}
      }

      // Sliver overlay: visible clickable edge anchored to the panel (full height)
      if (!this._sliverHandleEl) {
        const sliver = document.createElement('div');
        sliver.className = 'ww-sliver-handle';
        sliver.style.position = 'absolute';
        sliver.style.top = '0';
        sliver.style.right = '0';
        sliver.style.bottom = '0';
        sliver.style.width = `${this.peekVisiblePx}px`;
        sliver.style.zIndex = '1001';
        sliver.style.cursor = 'pointer';
        // Transparent so the real card edge (border/shadow) remains visible
        sliver.style.background = 'transparent';
        sliver.style.borderLeft = 'none';
        // Clicking the sliver opens immediately with suppression of immediate re-toggle
        sliver.addEventListener('pointerdown', (e) => {
          const isDesktop = this.desktopMedia && this.desktopMedia.matches;
          if (!isDesktop) return;
          try { this.suppressToggleUntil = Date.now() + 400; } catch (_) {}
          this.showDesktopPanel();
          this.openedOnce = true;
          try { e.stopPropagation(); e.preventDefault(); } catch (_) {}
        }, { capture: true });
        // Append to the panel
        this.panelTarget.appendChild(sliver);
        this._sliverHandleEl = sliver;
      }
      // Keep sliver in sync with width and theme
      try {
        this._sliverHandleEl.style.width = `${this.peekVisiblePx}px`;
        this._sliverHandleEl.style.backgroundColor = 'transparent';
        this._sliverHandleEl.style.borderLeft = 'none';
        this._sliverHandleEl.style.zIndex = '1001';
      } catch (_) {}

      // Update sliver position
      this.updateSliverHandlePosition();

      // Right-side internal mask: hides any content under the sliver while preserving the outer border/shadow
      if (!this._sliverRightMaskEl) {
        const mask = document.createElement('div');
        mask.className = 'ww-sliver-right-mask';
        mask.style.position = 'absolute';
        mask.style.top = '0';
        mask.style.right = '0';
        mask.style.bottom = '0';
        mask.style.width = `${this.peekVisiblePx}px`;
        mask.style.backgroundColor = bg;
        mask.style.pointerEvents = 'none';
        mask.style.zIndex = '1000';
        if (getComputedStyle(card).position === 'static') card.style.position = 'relative';
        card.appendChild(mask);
        this._sliverRightMaskEl = mask;
      } else {
        try {
          this._sliverRightMaskEl.style.width = `${this.peekVisiblePx}px`;
          this._sliverRightMaskEl.style.backgroundColor = bg;
          this._sliverRightMaskEl.style.zIndex = '1000';
        } catch (_) {}
      }
    } catch (_) {}
  }

  // Remove sliver overlays when expanding or switching to mobile
  removeSliverOverlays() {
    try {
      // Remove overlay elements
      if (this._sliverHandleEl?.parentNode) {
        this._sliverHandleEl.parentNode.removeChild(this._sliverHandleEl);
        this._sliverHandleEl = null;
      }
      if (this._sliverCoverEl?.parentNode) {
        this._sliverCoverEl.parentNode.removeChild(this._sliverCoverEl);
        this._sliverCoverEl = null;
      }
      if (this._sliverRightMaskEl?.parentNode) {
        this._sliverRightMaskEl.parentNode.removeChild(this._sliverRightMaskEl);
        this._sliverRightMaskEl = null;
      }
    } catch (_) {}
  }

  // No guard needed; sidebar remains in normal flow on desktop

  // Ensure behavior is correct when switching between desktop and mobile
  onMediaChange(e) {
    if (!this.hasPanelTarget) return;
    if (e && e.matches) {
      // Entered desktop: re-observe and show as peek until trigger is intersecting
      // Clear any one-time locks before centering
      this._lockTopOnce = undefined;
      this.panelTarget.classList.remove('hidden');
      this.panelTarget.classList.remove('translate-x-0');
      this.panelTarget.classList.remove(this.collapsedMobileClass);
      this.panelTarget.classList.add(this.collapsedDesktopClass);
      // Desktop collapsed default: fixed peek, out of flow
      try {
        this.panelTarget.style.position = 'fixed';
        // Use consistent 50% + translateY(-50%) for vertical centering
        this.panelTarget.style.top = '50%';
        this.panelTarget.style.bottom = 'auto';  // Override class-based bottom: 0
        this.panelTarget.style.left = '0px';
        this.panelTarget.style.zIndex = '40';
        // Combine horizontal peek with vertical centering
        this.panelTarget.style.transform = `${this.collapsedDesktopTransform} translateY(-50%)`;
        // Keep pointer events on so the sliver/handle is clickable
        this.panelTarget.style.pointerEvents = '';
        // Hint that the edge can be pulled/clicked
        this.panelTarget.style.cursor = 'ew-resize';
      } catch (_) {}
      // Keep the handle overlay aligned with the card
      try { this.updateSliverHandlePosition(); } catch (_) {}
      if (this.hasBackdropTarget) this.backdropTarget.classList.add('hidden');
      // Auto-open only triggers when articles turbo frame loads
      // Collapsed on desktop -> inert
      this.setCollapsedInert(true);
      this.sync();
    } else {
      // Left desktop -> mobile: collapse off-screen by default
      // Clear any one-time locks
      this._lockTopOnce = undefined;
      // Keep hidden to avoid visual flash; showMobilePanel will remove it
      // Ensure hidden is present
      if (!this.panelTarget.classList.contains('hidden')) this.panelTarget.classList.add('hidden');
      if (this.io) {
        try { this.io.disconnect(); } catch (_) { /* no-op */ }
        this.io = null;
      }
      // Mobile collapsed off-screen
      this.panelTarget.classList.remove('translate-x-0');
      this.panelTarget.classList.remove(this.collapsedDesktopClass);
      this.panelTarget.classList.add(this.collapsedMobileClass);
      this.clearPeek();
      // Clear any desktop-fixed overrides
      try {
        this.panelTarget.style.position = '';
        this.panelTarget.style.top = '';
        this.panelTarget.style.bottom = '';
        this.panelTarget.style.left = '';
        this.panelTarget.style.zIndex = '';
      } catch (_) {}
      // On mobile, suppress pointer events while collapsed so it doesn't block page
      try {
        this.panelTarget.style.pointerEvents = 'none';
        const btns = this.buttonTargets && this.buttonTargets.length ? this.buttonTargets : (this.hasButtonTarget ? [this.buttonTarget] : []);
        btns.forEach((btn) => btn.style.pointerEvents = 'auto');
      } catch (_) {}
      // No content offset needed - sidebar overlays content
      // No inline padding on mobile
      if (this.hasBackdropTarget) this.backdropTarget.classList.add('hidden');
      // Leaving desktop -> ensure not inert on mobile
      this.setCollapsedInert(false);
      this.sync();
    }
  }

  // Auto-open sidebar when articles turbo frame finishes loading (if preference enabled)
  onTurboFrameLoad(e) {
    const target = e && e.target;
    if (target && (target.id === 'law_articles')) {
      // Auto-open based on localStorage preference - only when articles load
      if (this.isAutoOpenEnabled() && !this.autoOpenConsumed) {
        try {
          const isDesktop = this.desktopMedia && this.desktopMedia.matches;
          if (isDesktop && this.hasEligibleSectionHeading()) {
            this.showDesktopPanel();
            this.openedOnce = true;
            this.autoOpenConsumed = true;
            this.sync();
          }
        } catch (_) {}
      }
    }
  }

  // Auto-open sidebar when articles load if there's TOC content with section headings
  autoOpenIfToc(e) {
    try {
      const isDesktop = this.desktopMedia && this.desktopMedia.matches;
      if (!isDesktop) return;
      
      // Only auto-open once when page loads (openedOnce check handles this)
      if (this.openedOnce) return;
      
      // Only auto-open if we have eligible section headings (not just BIJLAGE entries)
      if (this.hasEligibleSectionHeading()) {
        this.showDesktopPanel();
        this.openedOnce = true;
        this.sync();
      }
    } catch (err) {
      // Silent error handling
    }
  }

  hashTargetsArticle() {
    try {
      const h = window.location.hash || "";
      // Recognize canonical and legacy article fragments generated by helpers:
      // - canonical:  #art-<token> where token matches ApplicationHelper.article_id_from_toc_line
      //               e.g., art-3-5-1, art-28-1, art-4bis, art-m, art-a-1
      // - legacy:     #section-art-<token> (alias anchors inserted inside article content)
      // - section:    #tekst (top of the articles section wrapper)
      if (/^#tekst$/i.test(h)) return true;
      return /^#(?:art-[a-z0-9]+(?:-[a-z0-9]+)*|section-art-[a-z0-9]+(?:-[a-z0-9]+)*)$/i.test(h);
    } catch (_) {
      return false;
    }
  }

  onHashChange(e) {
    // Auto-open only triggers when articles turbo frame loads (not on hash change)
  }

  // Fallback: evaluate visibility on scroll in case IO doesn't fire on some platforms
  handleScrollEvent(_) {
    const isDesktop = this.desktopMedia && this.desktopMedia.matches;
    if (!isDesktop) return;
    // Mark that the user scrolled so IO and evaluations are allowed
    this.didUserScroll = true;
    if (!this.hasTriggerTarget || !this.hasPanelTarget) return;
    // Throttle with rAF
    if (this.scrollTick) return;
    this.scrollTick = window.requestAnimationFrame(() => {
      this.scrollTick = null;
      // Auto-open only triggers when articles turbo frame loads (not on scroll)
      // Note: Sidebar position is fixed and centered via CSS, no need to update on scroll
      // This reduces performance overhead significantly
    });
  }

  evaluateTriggerVisibility() {
    try {
      if (!this.hasTriggerTarget || !this.hasPanelTarget) return;
      const rect = this.triggerTarget?.getBoundingClientRect?.() || { top: Infinity, bottom: -Infinity };
      // Basic in-viewport check
      const inViewport = rect.bottom > 0 && rect.top < window.innerHeight;
      const notPast = rect.bottom > 80;
      if (!this.autoOpenConsumed && inViewport && notPast && this.hasEligibleSectionHeading()) {
        this.showDesktopPanel();
        this.openedOnce = true;
        this.autoOpenConsumed = true;
        this.sync();
      }
    } catch (_) {}
  }

  // Returns true if the page has at least one section heading in the TOC that is not a BIJLAGE/BIJLAGEN entry.
  // This mirrors the product rule: only auto-show the TOC on desktop when there are real section headings.
  hasEligibleSectionHeading() {
    try {
      // Look within the sidebar TOC card first; fallback to any visible TOC navigation
      const container = this.element.querySelector('#toc-card-sidebar .toc-navigation')
        || document.querySelector('#toc-card-sidebar .toc-navigation')
        || this.element.querySelector('.toc-navigation')
        || document.querySelector('.toc-navigation');
      if (!container) return false;

      // Section headings in the TOC are rendered with font-medium (see app/views/laws/_toc.html.erb)
      const links = Array.from(container.querySelectorAll('a.toc-link.font-medium'));
      if (!links.length) return false;

      // Exclude headings that are purely BIJLAGE/BIJLAGEN (case-insensitive). Allow other headings.
      const excludedRx = /^\s*(BIJLAGE|BIJLAGEN)\b/i;
      return links.some((a) => {
        const txt = (a.textContent || '').trim();
        return !excludedRx.test(txt);
      });
    } catch (_) {
      return false;
    }
  }

  // Check if auto-open is enabled via localStorage preference
  isAutoOpenEnabled() {
    try {
      return localStorage.getItem("wetwijzer_sidebar_auto_open") === "1";
    } catch (_) {
      return false;
    }
  }

  // Helpers (duplicates cleaned)

// Re-observe when Turbo frame for articles finishes loading
  // Duplicated methods removed (see earlier definitions above)

showMobilePanel() {
  if (!this.hasPanelTarget) return;
  // Prepare - clear any desktop fixed positioning first
  try {
    this.panelTarget.style.position = '';
    this.panelTarget.style.top = '';
    this.panelTarget.style.bottom = '';
    this.panelTarget.style.left = '';
    this.panelTarget.style.transform = '';
  } catch (_) {}
  this.panelTarget.classList.remove('hidden');
  // Force reflow so transition applies after class change
  void this.panelTarget.offsetWidth;
  this.panelTarget.classList.remove(this.collapsedMobileClass);
  this.panelTarget.classList.remove(this.collapsedDesktopClass);
  this.clearPeek();
  this.panelTarget.classList.add('translate-x-0');
  if (this.hasBackdropTarget) this.backdropTarget.classList.remove('hidden');
  try { this.panelTarget.style.pointerEvents = ''; } catch (_) {}
  this.sync();
}

hideMobilePanel() {
  if (!this.hasPanelTarget) return;
  // Clear any desktop fixed positioning first
  try {
    this.panelTarget.style.position = '';
    this.panelTarget.style.top = '';
    this.panelTarget.style.bottom = '';
    this.panelTarget.style.left = '';
    this.panelTarget.style.transform = '';
  } catch (_) {}
  this.panelTarget.classList.remove('translate-x-0');
  // Mobile collapsed: slide fully off-screen
  this.panelTarget.classList.remove(this.collapsedDesktopClass);
  this.panelTarget.classList.add(this.collapsedMobileClass);
  this.clearPeek();
  if (this.hasBackdropTarget) this.backdropTarget.classList.add('hidden');
  try {
    this.panelTarget.style.pointerEvents = 'none';
    const btns = this.buttonTargets && this.buttonTargets.length ? this.buttonTargets : (this.hasButtonTarget ? [this.buttonTarget] : []);
    btns.forEach((btn) => btn.style.pointerEvents = 'auto');
  } catch (_) {}
  this.sync();
}

onKeydown(e) {
  const isDesktop = this.desktopMedia && this.desktopMedia.matches;
  if (isDesktop) return;
  if (e.key === 'Escape') {
    this.hideMobilePanel();
  }
}

// Desktop slide helpers (no backdrop)
showDesktopPanel() {
  if (!this.hasPanelTarget) return;
  
  const panel = this.panelTarget;
  
  // Step 1: Disable CSS transition to prevent any animated jumps during setup
  panel.style.transition = 'none';
  
  // Step 2: Set up positioning FIRST while transition is disabled
  // Use 'auto' for bottom to override the class-based 'bottom: 0' from inset-y-0
  panel.style.position = 'fixed';
  panel.style.left = '0px';
  panel.style.top = '50%';
  panel.style.bottom = 'auto';  // IMPORTANT: 'auto' overrides class, '' does not
  panel.style.zIndex = '40';
  panel.style.pointerEvents = '';
  panel.style.cursor = '';
  // Set the STARTING position (collapsed) explicitly
  panel.style.transform = `${this.collapsedDesktopTransform} translateY(-50%)`;
  
  // Step 3: Update classes
  panel.classList.remove('hidden');
  panel.classList.remove(this.collapsedMobileClass);
  panel.classList.remove(this.collapsedDesktopClass);
  
  // Step 4: Force layout recalculation to commit the starting position
  void panel.offsetWidth;
  
  // Step 5: Re-enable transition and trigger animation using double-rAF
  // Double requestAnimationFrame ensures browser has fully painted before animating
  requestAnimationFrame(() => {
    panel.style.transition = '';
    requestAnimationFrame(() => {
      panel.style.transform = 'translateX(0) translateY(-50%)';
      panel.classList.add('translate-x-0');
    });
  });
  
  // Expanded: re-enable internal content
  this.setCollapsedInert(false);
  this.sync();
}

hideDesktopPanel(skipTransition = false) {
  if (!this.hasPanelTarget) return;
  this.panelTarget.classList.remove('translate-x-0');
  // Desktop collapsed: keep panel visible as a peeked sliver
  this.panelTarget.classList.remove(this.collapsedMobileClass);
  this.panelTarget.classList.add(this.collapsedDesktopClass);
  
  // Desktop collapsed: make it a fixed overlay sliver so content uses full width
  try {
    this.panelTarget.style.position = 'fixed';
    this.panelTarget.style.left = '0px';
    this.panelTarget.style.top = '50%';
    this.panelTarget.style.bottom = 'auto';  // Override class-based bottom: 0
    this.panelTarget.style.zIndex = '40';
    this.panelTarget.style.pointerEvents = '';
    this.panelTarget.style.cursor = 'ew-resize';
    // Combine horizontal peek with vertical centering
    this.panelTarget.style.transform = `${this.collapsedDesktopTransform} translateY(-50%)`;
  } catch (_) {}
  
  // Align the handle to card for collapsed state
  try { this.updateSliverHandlePosition(); } catch (_) {}
  // No content offset needed - sidebar overlays content
  // Ensure internal content is inert/hidden when collapsed
  this.setCollapsedInert(true);
  this.sync();
}

// Measurement helpers and positioning for desktop behavior
  recomputeMeasurements() {
    try {
      // If we're currently in a desktop state, update positions to reflect new measurements
      const isDesktop = this.desktopMedia && this.desktopMedia.matches;
      if (!isDesktop || !this.hasPanelTarget) return;
      const expanded = this.panelTarget.classList.contains('translate-x-0');
      if (expanded) {
        this.updateExpandedFixedPosition();
      } else {
        // Collapsed sliver: keep centered vertically using consistent method
        this.panelTarget.style.top = '50%';
        this.panelTarget.style.bottom = 'auto';  // Override class-based bottom: 0
        this.panelTarget.style.transform = `${this.collapsedDesktopTransform} translateY(-50%)`;
        // And keep the handle aligned to the card within the panel
        try { this.updateSliverHandlePosition(); } catch (_) {}
      }
    } catch (_) {}
  }

readCurrentTop() {
  try {
    if (!this.hasPanelTarget) return 0;
    const styleTop = this.panelTarget.style.top;
    const parsed = parseInt(styleTop, 10);
    if (Number.isFinite(parsed)) return parsed;
    const rect = this.panelTarget.getBoundingClientRect?.() || { top: 0 };
    return Math.max(0, Math.round(rect.top || 0));
  } catch (_) {
    return 0;
  }
}

updateExpandedFixedPosition() {
  try {
    if (!this.hasPanelTarget) return;
    // Use CSS for centering - combine with horizontal translate-x-0 from Tailwind
    if (typeof this._lockTopOnce === 'number') {
      // Lock position on first expand to avoid jump
      this.panelTarget.style.left = '0px';
      this.panelTarget.style.top = `${this._lockTopOnce}px`;
      this.panelTarget.style.bottom = 'auto';  // Override class-based bottom: 0
      this.panelTarget.style.transform = 'translateX(0)';
      this._lockTopOnce = undefined;
    } else {
      // Use CSS-based centering for better performance
      // Combine translateX(0) with translateY(-50%) for centered overlay
      this.panelTarget.style.left = '0px';
      this.panelTarget.style.top = '50%';
      this.panelTarget.style.bottom = 'auto';  // Override class-based bottom: 0
      this.panelTarget.style.transform = 'translateX(0) translateY(-50%)';
    }
    // Sidebar overlays content - no offset needed
  } catch (_) {}
}
}
