import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="jump-select"
export default class extends Controller {
  static targets = ["menu", "button"]
  static values = { fallback: Boolean }

  connect() {
    this.boundOutside = this.handleOutsideClick.bind(this);
    this.boundKeydown = this.handleKeydown.bind(this);
    this.boundMenuClick = this.onMenuClick.bind(this);
    this.portaled = false;
    this.placeholder = null;
    this.simpleFixed = false;
    // Cache DOM refs so we can safely move the menu out of scope without breaking Stimulus target getters
    this.menuEl = this.hasMenuTarget ? this.menuTarget : null;
    this.buttonEl = this.hasButtonTarget ? this.buttonTarget : null;
    try { console.debug("jump-select: connect", { element: this.element }); } catch (_) {}
  }

  toggle(event) {
    event.preventDefault();
    if (!this.menuEl) { try { console.warn("jump-select: no menuEl"); } catch (_) {} }
    const isHidden = this.menuEl ? this.menuEl.classList.contains("hidden") : true;
    try { console.debug("jump-select: toggle", { hidden: isHidden }); } catch (_) {}
    if (isHidden) {
      this.open();
    } else {
      this.close();
    }
  }

  open() {
    try { console.debug("jump-select: open"); } catch (_) {}
    this.menuEl?.classList.remove("hidden");
    this.buttonEl?.setAttribute("aria-expanded", "true");
    document.addEventListener("click", this.boundOutside, { capture: true });
    document.addEventListener("keydown", this.boundKeydown, { capture: true });

    // Portal the menu to body to avoid any ancestor overflow/stacking issues (esp. on mobile)
    this.portalMenu();

    // Ensure clicks on menu items still navigate when portaled (Stimulus action scoping would be lost)
    this.menuEl?.addEventListener('click', this.boundMenuClick);

    // Animate in (fade + scale)
    const m = this.menuEl;
    if (m) {
      try { m.style.willChange = 'opacity, transform'; } catch (_) {}
      try { m.style.transformOrigin = 'top right'; } catch (_) {}
      try { m.style.transition = 'opacity 120ms ease-out, transform 120ms ease-out'; } catch (_) {}
      try { m.style.opacity = '0'; m.style.transform = 'scale(0.98)'; } catch (_) {}
      requestAnimationFrame(() => {
        try { m.style.opacity = '1'; m.style.transform = 'scale(1)'; } catch (_) {}
      });
    }
  }

  close() {
    try { console.debug("jump-select: close"); } catch (_) {}
    this.buttonEl?.setAttribute("aria-expanded", "false");
    document.removeEventListener("click", this.boundOutside, { capture: true });
    document.removeEventListener("keydown", this.boundKeydown, { capture: true });
    this.menuEl?.removeEventListener('click', this.boundMenuClick);

    const m = this.menuEl;
    if (m && this.portaled) {
      // Animate out then finalize close
      const done = () => {
        m.removeEventListener('transitionend', done);
        this.finalizeClose();
      };
      try { m.style.transition = 'opacity 120ms ease-in, transform 120ms ease-in'; } catch (_) {}
      try { m.style.willChange = 'opacity, transform'; } catch (_) {}
      // kick off animation next frame for reliability
      requestAnimationFrame(() => {
        try { m.style.opacity = '0'; m.style.transform = 'scale(0.98)'; } catch (_) {}
      });
      this._closeTimeout = setTimeout(done, 160);
      m.addEventListener('transitionend', done, { once: true });
    } else {
      this.finalizeClose();
    }
  }

  finalizeClose() {
    if (this._closeTimeout) { try { clearTimeout(this._closeTimeout); } catch (_) {} this._closeTimeout = null; }
    try { this.menuEl?.classList.add('hidden'); } catch (_) {}
    if (this.menuEl) {
      try {
        this.menuEl.style.transition = '';
        this.menuEl.style.willChange = '';
        this.menuEl.style.opacity = '';
        this.menuEl.style.transform = '';
      } catch (_) {}
    }
    this.unportalMenu();
  }

  handleOutsideClick(e) {
    // When portaled, the menu is not inside this.element anymore. Accept clicks inside the menu as inside.
    const clickedInsideHost = this.element.contains(e.target);
    const clickedInsideMenu = this.portaled && this.menuEl && this.menuEl.contains(e.target);
    if (!clickedInsideHost && !clickedInsideMenu) {
      this.close();
    }
  }

  handleKeydown(e) {
    if (e.key === 'Escape') {
      this.close();
      // Return focus to the trigger
      this.buttonEl?.focus();
    }
  }

  go(event) {
    event.preventDefault();
    const target = event.currentTarget.getAttribute("data-target");
    const el = document.querySelector(target);
    try { console.debug("jump-select: go", { target }); } catch (_) {}
    this.navigateToTarget(target, el);
  }

  onMenuClick(e) {
    const item = e.target.closest('[role="menuitem"][data-target]');
    if (!item || !this.menuEl?.contains(item)) return;
    e.preventDefault();
    const target = item.getAttribute('data-target');
    const el = document.querySelector(target);
    try { console.debug('jump-select: go (delegated)', { target }); } catch (_) {}
    this.navigateToTarget(target, el);
  }

  navigateToTarget(target, el) {
    this.close();
    if (el) {
      // Prefer hash update to integrate with existing hash/observer logic
      if (target.startsWith('#')) {
        window.location.hash = target;
      } else if (el.id) {
        window.location.hash = `#${el.id}`;
      } else {
        el.scrollIntoView({ behavior: 'smooth', block: 'start' });
      }
    }
  }

  // --- Private: menu portaling to body for robust positioning on mobile ---
  portalMenu() {
    if (this.portaled) {
      this.positionPortaledMenu();
      return;
    }

    if (!this.menuEl) {
      try { console.error('jump-select: portalMenu called without menuEl'); } catch (_) {}
      return;
    }

    // Insert a placeholder to restore position later
    this.placeholder = document.createComment('jump-select-menu');
    this.menuEl?.after(this.placeholder);

    // Move to body and switch to fixed positioning
    if (this.menuEl && this.menuEl.parentNode) {
      document.body.appendChild(this.menuEl);
    }
    this.menuEl.style.position = 'fixed';
    this.menuEl.style.left = 'auto';
    this.menuEl.style.transform = 'none';
    this.menuEl.style.zIndex = this.menuEl.style.zIndex || '999';

    this.portaled = true;
    const forceFallback = this.hasFallbackValue ? this.fallbackValue : false;
    const isSmall = window.innerWidth < 768; // mobile heuristic
    if (forceFallback || isSmall) {
      this.simpleFixed = true;
      try { this.positionSimpleFixed(); } catch (_) {}
      requestAnimationFrame(() => { try { this.positionSimpleFixed(); } catch (_) {} });
      setTimeout(() => { try { this.positionSimpleFixed(); } catch (_) {} }, 50);
    } else {
      // Position after layout; do a couple of passes to account for fonts/reflow
      const schedule = () => {
        try { this.positionPortaledMenu(); } catch (_) {}
        requestAnimationFrame(() => {
          try { this.positionPortaledMenu(); } catch (_) {}
        });
        setTimeout(() => {
          try { this.positionPortaledMenu(); } catch (_) {}
        }, 50);
      };
      schedule();
    }

    // Reposition on resize/scroll to keep alignment
    this.boundReposition = () => {
      if (this.simpleFixed) {
        this.positionSimpleFixed();
      } else {
        this.positionPortaledMenu();
      }
    };
    window.addEventListener('resize', this.boundReposition);
    window.addEventListener('scroll', this.boundReposition, { passive: true });
  }

  unportalMenu() {
    if (!this.portaled || !this.menuEl) return;
    try { window.removeEventListener('resize', this.boundReposition); } catch (_) {}
    try { window.removeEventListener('scroll', this.boundReposition); } catch (_) {}

    // Restore element back near its original location
    if (this.placeholder && this.placeholder.parentNode) {
      this.placeholder.parentNode.insertBefore(this.menuEl, this.placeholder);
      this.placeholder.remove();
      this.placeholder = null;
    }

    // Cleanup inline styles applied during portaling/positioning
    try {
      this.menuEl.style.position = '';
      this.menuEl.style.left = '';
      this.menuEl.style.right = '';
      this.menuEl.style.top = '';
      this.menuEl.style.bottom = '';
      this.menuEl.style.maxHeight = '';
      this.menuEl.style.overflowY = '';
      this.menuEl.style.zIndex = '';
      this.menuEl.style.transform = '';
    } catch (_) {}

    this.portaled = false;
    this.simpleFixed = false;
  }

  positionPortaledMenu() {
    if (!this.portaled) return;
    const btn = this.buttonEl;
    if (!btn) return;
    const rect = btn.getBoundingClientRect();
    const menu = this.menuEl;

    // Align right edge of menu to right edge of button
    const gap = 10; // match mb-10 spacing
    const right = Math.max(8, window.innerWidth - rect.right);
    const menuHeight = menu.offsetHeight || menu.scrollHeight || 0;
    let top = rect.top - menuHeight - gap; // above by default
    let placed = 'above';
    if (top < 8) {
      top = rect.bottom + gap;
      placed = 'below';
    }

    // Constrain height to viewport
    const maxHeight = placed === 'below'
      ? Math.max(120, window.innerHeight - top - 8)
      : Math.max(120, rect.top - gap - 8);

    menu.style.right = `${right}px`;
    menu.style.top = `${Math.max(8, top)}px`;
    menu.style.bottom = 'auto';
    menu.style.maxHeight = `${Math.floor(maxHeight)}px`;
    menu.style.overflowY = 'auto';
    try { console.debug("jump-select: positioned", { rect, right, top, placed, menuHeight, maxHeight }); } catch (_) {}
  }

  positionSimpleFixed() {
    if (!this.portaled) return;
    const menu = this.menuEl;
    const btn = this.buttonEl;
    if (!menu || !btn) return;

    // Align to the trigger and show slightly above with a small gap
    const rect = btn.getBoundingClientRect();
    const gap = 6; // small visual gap above the button
    const safe = 8; // viewport safe margin

    // Right-align with the trigger's right edge
    const right = Math.max(safe, window.innerWidth - rect.right);

    // Measure and decide placement
    const menuHeight = menu.offsetHeight || menu.scrollHeight || 0;
    let top = rect.top - menuHeight - gap;
    let placed = 'above';
    if (top < safe) {
      top = rect.bottom + gap;
      placed = 'below';
    }

    // Constrain height for viewport
    const maxHeight = placed === 'below'
      ? Math.max(120, window.innerHeight - top - safe)
      : Math.max(120, rect.top - gap - safe);

    // Apply styles
    menu.style.position = 'fixed';
    menu.style.left = 'auto';
    menu.style.right = `${right}px`;
    menu.style.top = `${Math.max(safe, top)}px`;
    menu.style.bottom = 'auto';
    menu.style.maxHeight = `${Math.floor(maxHeight)}px`;
    menu.style.overflowY = 'auto';

    try { console.debug('jump-select: simple-fixed positioned', { rect, right, top, placed, menuHeight, maxHeight }); } catch (_) {}
  }
}
