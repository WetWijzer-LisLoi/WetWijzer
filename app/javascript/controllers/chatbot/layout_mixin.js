/**
 * Chatbot Controller - Layout Mixin
 *
 * Methods extracted from chatbot_controller.js for maintainability.
 * Mixed into the controller prototype - all methods use 'this' as normal.
 */

import { prefs as prefsStore } from "../../services/preferences_store"

// How far the open panel has to move to sit inside the viewport.
//
// The panel hangs up and to the left of the 56px bubble, and only the bubble
// was ever clamped to the viewport. With the bubble dragged within a panel's
// width of the left edge, or a panel's height of the top, the panel opened
// partly or wholly outside the window (bubble at top:0 = panel entirely above
// the viewport, header and its buttons included), and that position was
// persisted and re-applied on every page. The bubble stays where the user put
// it; the panel gives way instead.
export function panelNudgeIntoView(left, top, margin = 8) {
  return {
    x: left < margin ? Math.ceil(margin - left) : 0,
    y: top < margin ? Math.ceil(margin - top) : 0
  }
}

// The panel's bottom edge sits this far above the container's, straight from
// the `bottom-[4.5rem]` class on #chatbot-widget-panel.
const PANEL_BOTTOM_OFFSET = 72
// Between the bubble and its menu, and between the menu and the window edge.
const FAB_MENU_GAP = 8

export const layoutMethods = {
  // Mobile has no floating launcher. Return focus to the dock's Chat link,
  // or its native reopen handle when the user has collapsed navigation.
  _focusWidgetLauncher() {
    if (this.hasWidgetTarget && this.widgetTarget.contains(document.activeElement)) {
      document.activeElement?.blur?.()
    }
    const candidates = [
      this.hasToggleButtonTarget ? this.toggleButtonTarget : null,
      document.getElementById('mobile-chat-btn'),
      document.querySelector('#mobile-bottom-bar > summary')
    ]
    for (const candidate of candidates) {
      if (candidate?.isConnected && candidate.getClientRects().length &&
          window.getComputedStyle(candidate).visibility !== 'hidden') {
        candidate.focus()
        return
      }
    }
  },

  // Nudge the open panel back on screen after the bubble was dragged.
  //
  // Measured from layout boxes, never from the panel's own rect: on open the
  // enter animation's from-keyframe (translateY(16px) scale(0.95)) still
  // applies, so the rect reads about 29px too low and the nudge would come
  // out short, leaving the header clipped.
  _fitPanelInViewport() {
    const container = document.getElementById('chatbot-widget-container')
    const panel = document.getElementById('chatbot-widget-panel')
    if (!container || !panel) return

    // Always start from the CSS anchor. close() resets the container position
    // while the panel is still on screen, so a leftover nudge would push the
    // panel away from its default corner on the next open.
    panel.style.right = ''
    panel.style.bottom = ''
    // Below 640px the panel is inset: 0 !important - nothing to fit.
    if (window.innerWidth < 640 || panel.classList.contains('hidden')) return

    const rect = container.getBoundingClientRect()
    const nudge = panelNudgeIntoView(
      rect.right - panel.offsetWidth,
      rect.bottom - PANEL_BOTTOM_OFFSET - panel.offsetHeight
    )
    // A negative `right` moves the panel rightwards, a smaller `bottom` down.
    if (nudge.x) panel.style.right = `${-nudge.x}px`
    if (nudge.y) panel.style.bottom = `${PANEL_BOTTOM_OFFSET - nudge.y}px`
  },

  // The panel is opened from six places - the bubble, the header minimise
  // button, Escape, the context toast, the docked bottom bar and the hero
  // form - and most of them sit outside this mixin. Rather than hook each
  // one, watch the single thing they all do: take `hidden` off the panel.
  _watchPanelFit() {
    const panel = document.getElementById('chatbot-widget-panel')
    if (!panel || typeof MutationObserver === 'undefined') return
    // Compared against the node, not a boolean: Stimulus reuses one controller
    // instance when its element is disconnected and reconnected (a Turbo cache
    // restore), and an "already watching" flag would leave the observers on
    // the panel node that was replaced - silently no longer fitting the panel
    // the reader is looking at.
    if (this._panelFitPanel === panel) return
    this._unwatchPanelFit()
    this._panelFitPanel = panel

    this._panelFitObserver = new MutationObserver(() => this._fitPanelInViewport())
    this._panelFitObserver.observe(panel, { attributes: true, attributeFilter: ['class'] })

    // The default panel fills the useful viewport height. A saved manual
    // resize, maximize/restore, or a viewport change can still change that
    // box without changing its class, so re-fit whenever its layout box moves.
    // Writing `right`/`bottom` cannot resize the panel, so this does not feed
    // itself.
    if (typeof ResizeObserver !== 'undefined') {
      this._panelFitSizeObserver = new ResizeObserver(() => this._fitPanelInViewport())
      this._panelFitSizeObserver.observe(panel)
    }

    // Maximizing, restoring and reset-position animate the panel's size over
    // 0.3s, so the class change above is seen while it still has the box it
    // is leaving. transitionend bubbles, hence the target check.
    this._boundPanelFitTransitionEnd = (event) => {
      if (event.target === panel) this._fitPanelInViewport()
    }
    panel.addEventListener('transitionend', this._boundPanelFitTransitionEnd)
  },

  // Same discipline as the controller's disconnect(), which removes every
  // listener it installs: these three hang off the panel node, and a Turbo
  // visit replaces it under a controller instance that is kept.
  _unwatchPanelFit() {
    this._panelFitObserver?.disconnect()
    this._panelFitObserver = null
    this._panelFitSizeObserver?.disconnect()
    this._panelFitSizeObserver = null
    if (this._panelFitPanel && this._boundPanelFitTransitionEnd) {
      this._panelFitPanel.removeEventListener('transitionend', this._boundPanelFitTransitionEnd)
    }
    this._boundPanelFitTransitionEnd = null
    this._panelFitPanel = null
  },

  handleFabKeydown(event) {
    // The context-menu key and Shift+F10 open the bubble's own menu. A browser
    // that also turns them into a contextmenu event reaches openFabMenu a
    // second time, which keeps the one menu open.
    if (event.key === 'ContextMenu' || (event.key === 'F10' && event.shiftKey)) {
      if (this.hasFabMenuTarget) {
        event.preventDefault()
        this.openFabMenu(event)
      }
      return
    }
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault()
      this.toggle()
    }
  },

  handleFabClick(event) {
    // Native button activation covers narrow-window mouse users, touch taps
    // (one synthesized click), keyboard and assistive technology. Desktop
    // pointer releases are already handled by the drag state machine.
    if (window.innerWidth < 768 || event.detail === 0) this.toggle()
  },

  // ═══════════════════════════════════════════════
  // BUBBLE MENU - right-click, the context-menu key or Shift+F10 on the bubble
  // ═══════════════════════════════════════════════

  // One action, asked for by the owner (via Sol, 2026-11-21): put the bubble
  // back at its default place. Only the position goes (_resetPositionOnly):
  // the panel's size, whether it is open and the conversation all stay. Touch
  // keeps the reset in the panel header; a long press is left to the browser,
  // because it would compete with dragging.
  openFabMenu(event) {
    if (!this.hasFabMenuTarget || !this.hasToggleButtonTarget) return
    if (event?.type === 'contextmenu' && this._fromTouch(event)) return
    event?.preventDefault?.()
    // A Mac's Ctrl+click starts as a left mousedown, so the drag machine is
    // waiting for the release and would open or close the chat on it.
    this._cancelFabDrag()

    const menu = this.fabMenuTarget
    if (menu.hidden) {
      menu.hidden = false
      this._placeFabMenu()
      this._bindFabMenuDismiss()
    }
    if (this.hasFabMenuItemTarget) this.fabMenuItemTarget.focus({ preventScroll: true })
  },

  closeFabMenu({ refocus = false } = {}) {
    this._unbindFabMenuDismiss()
    if (!this.hasFabMenuTarget || this.fabMenuTarget.hidden) return
    this.fabMenuTarget.hidden = true
    if (refocus && this.hasToggleButtonTarget) this.toggleButtonTarget.focus({ preventScroll: true })
  },

  resetBubblePosition(event) {
    event?.preventDefault?.()
    this.closeFabMenu({ refocus: true })
    this._resetPositionOnly()
    // _resetPositionOnly leaves an open panel where the old position had
    // nudged it; back at the default corner it is fitted again.
    this._fitPanelInViewport()
  },

  // A long press reports itself as touch: as a PointerEvent where the browser
  // makes contextmenu one, and through Chrome's InputDeviceCapabilities.
  _fromTouch(event) {
    return event.pointerType === 'touch' || event.sourceCapabilities?.firesTouchEvents === true
  },

  _cancelFabDrag() {
    const state = this._fabDragState
    if (!state) return
    document.removeEventListener('mousemove', this._boundFabDragMove)
    document.removeEventListener('mouseup', this._boundFabDragEnd)
    document.removeEventListener('touchmove', this._boundFabDragMove)
    document.removeEventListener('touchend', this._boundFabDragEnd)
    document.body.classList.remove('widget-dragging')
    this._fabDragState = null
    // A bubble already on the move stays where it was put.
    if (state.dragging) {
      this._persistWidgetPosition()
      this._syncResetPositionButton()
    }
  },

  // Above the bubble and aligned with its right edge, or below it when the
  // bubble was dragged to the top; always inside the window. The menu is
  // position: fixed, so it is measured once it is shown.
  _placeFabMenu() {
    const menu = this.fabMenuTarget
    const bubble = this.toggleButtonTarget.getBoundingClientRect()
    const box = menu.getBoundingClientRect()
    const width = document.documentElement?.clientWidth || window.innerWidth
    const height = document.documentElement?.clientHeight || window.innerHeight
    let top = bubble.top - FAB_MENU_GAP - box.height
    if (top < FAB_MENU_GAP) top = bubble.bottom + FAB_MENU_GAP
    top = Math.max(FAB_MENU_GAP, Math.min(top, height - box.height - FAB_MENU_GAP))
    const left = Math.max(FAB_MENU_GAP, Math.min(bubble.right - box.width, width - box.width - FAB_MENU_GAP))
    menu.style.left = `${Math.round(left)}px`
    menu.style.top = `${Math.round(top)}px`
  },

  // Bound only while the menu is open. Not closed on scroll: the bubble and
  // the menu are both fixed to the window, and an answer streaming into the
  // transcript scrolls it all the time.
  _bindFabMenuDismiss() {
    if (this._fabMenuDismissBound) return
    this._fabMenuDismissBound = true
    if (!this._boundFabMenuPress) {
      this._boundFabMenuPress = (event) => {
        if (this.hasFabMenuTarget && this.fabMenuTarget.contains(event.target)) return
        this.closeFabMenu()
      }
      this._boundFabMenuKey = (event) => {
        if (event.key === 'Escape') {
          // The menu owns Escape while it is open; the open panel's Escape
          // handler on the document would otherwise close the chat as well.
          event.preventDefault()
          event.stopImmediatePropagation()
          this.closeFabMenu({ refocus: true })
        } else if (event.key === 'Tab') {
          // Back on the bubble before the browser moves on, so Tab and
          // Shift+Tab continue from where the menu was opened.
          this.closeFabMenu({ refocus: true })
        }
      }
      // A resize or leaving the window hides the menu; a keyboard user whose focus was in it gets the bubble back.
      this._boundFabMenuAway = () => {
        const hadFocus = this.hasFabMenuTarget && this.fabMenuTarget.contains(document.activeElement)
        this.closeFabMenu({ refocus: hadFocus })
      }
    }
    document.addEventListener('pointerdown', this._boundFabMenuPress, true)
    document.addEventListener('keydown', this._boundFabMenuKey, true)
    window.addEventListener('resize', this._boundFabMenuAway)
    window.addEventListener('blur', this._boundFabMenuAway)
  },

  _unbindFabMenuDismiss() {
    if (!this._fabMenuDismissBound) return
    this._fabMenuDismissBound = false
    document.removeEventListener('pointerdown', this._boundFabMenuPress, true)
    document.removeEventListener('keydown', this._boundFabMenuKey, true)
    window.removeEventListener('resize', this._boundFabMenuAway)
    window.removeEventListener('blur', this._boundFabMenuAway)
  },

  // Auto-resize widget textarea

  autoResizeWidget() {
    if (!this.hasInputTarget) return
    const el = this.inputTarget
    el.style.height = 'auto'
    el.style.height = Math.min(el.scrollHeight, 120) + 'px'
  },

  // Toggle between default and expanded size (maximize / restore)
  // NOTE: Use resetWidgetLayout() instead; this is the canonical
  // maximize/restore toggle bound to the □ button and dblclick.

  // ═══════════════════════════════════════════════
  // WIDGET DRAG & RESIZE - move and resize the floating widget
  // ═══════════════════════════════════════════════

  // Start dragging the FAB button itself (mousedown/touchstart on the circle)
  // Desktop pointer interaction uses mousedown→mousemove→mouseup. Mobile
  // and keyboard activation use the native click handler, without dragging.

  startFabDrag(event) {
    if (window.innerWidth < 768) {
      // Do not toggle or cancel touchstart: let the button emit its one
      // native click. Mouse input is legitimate even at a phone-sized width.
      return
    }
    if (event.type === 'mousedown' && event.button !== 0) return

    const container = document.getElementById('chatbot-widget-container')
    if (!container) return

    const isTouch = event.type === 'touchstart'
    const clientX = isTouch ? event.touches[0].clientX : event.clientX
    const clientY = isTouch ? event.touches[0].clientY : event.clientY

    const rect = container.getBoundingClientRect()
    this._fabDragState = {
      startX: clientX,
      startY: clientY,
      offsetX: clientX - rect.left,
      offsetY: clientY - rect.top,
      dragging: false
    }

    this._boundFabDragMove = this._onFabDragMove.bind(this)
    this._boundFabDragEnd = this._onFabDragEnd.bind(this)

    if (isTouch) {
      document.addEventListener('touchmove', this._boundFabDragMove, { passive: false })
      document.addEventListener('touchend', this._boundFabDragEnd)
    } else {
      document.addEventListener('mousemove', this._boundFabDragMove)
      document.addEventListener('mouseup', this._boundFabDragEnd)
    }
  },

  _onFabDragMove(event) {
    if (!this._fabDragState) return
    const isTouch = event.type === 'touchmove'
    const clientX = isTouch ? event.touches[0].clientX : event.clientX
    const clientY = isTouch ? event.touches[0].clientY : event.clientY

    const dx = clientX - this._fabDragState.startX
    const dy = clientY - this._fabDragState.startY

    // Dead-zone: only start dragging after 5px of movement
    if (!this._fabDragState.dragging && Math.sqrt(dx * dx + dy * dy) < 5) return

    event.preventDefault()
    this._fabDragState.dragging = true

    const container = document.getElementById('chatbot-widget-container')
    if (!container) return

    let newLeft = clientX - this._fabDragState.offsetX
    let newTop = clientY - this._fabDragState.offsetY
    const cw = container.offsetWidth
    const ch = container.offsetHeight

    newLeft = Math.max(0, Math.min(newLeft, window.innerWidth - cw))
    newTop = Math.max(0, Math.min(newTop, window.innerHeight - ch))

    container.classList.add('widget-custom-pos')
    container.style.left = `${newLeft}px`
    container.style.top = `${newTop}px`
    document.body.classList.add('widget-dragging')
    // Dragging the bubble with the panel open moves the panel with it.
    this._fitPanelInViewport()
  },

  _onFabDragEnd(event) {
    // A tap that ends here is followed by an emulated mousedown + mouseup on the
    // same spot, and the FAB is still under it: that second pass through this
    // handler ran toggle() again, so from 640px up (tablets, phones in
    // landscape) a tap opened the widget and closed it straight away. The guard
    // native click handler covers the no-drag path below 768px. Cancelling the
    // touchend is what stops the browser emulating the mouse at all. Stateless
    // on purpose: a timestamp guard was tried and removed as unreliable.
    if (event?.type === 'touchend' && event.cancelable) event.preventDefault()

    document.removeEventListener('mousemove', this._boundFabDragMove)
    document.removeEventListener('mouseup', this._boundFabDragEnd)
    document.removeEventListener('touchmove', this._boundFabDragMove)
    document.removeEventListener('touchend', this._boundFabDragEnd)
    document.body.classList.remove('widget-dragging')

    const wasDragging = this._fabDragState?.dragging
    this._fabDragState = null

    if (wasDragging) {
      // Was a drag - persist position, do NOT open/close
      this._persistWidgetPosition()
      this._syncResetPositionButton()
    } else {
      // Was a click (no movement) - open or close+reset
      this.toggle()
    }
  },

  // Start dragging the widget (called from header mousedown/touchstart)

  startDrag(event) {
    // Ignore on mobile (< 640px) - widget is always full-width there
    if (window.innerWidth < 640) return
    // Only left-click for mouse
    if (event.type === 'mousedown' && event.button !== 0) return
    // Don't drag if click is on a button / link / select inside the header
    if (event.target.closest('button, a, select, input')) return

    event.preventDefault()

    const container = this.element // #chatbot-widget-container
    const rect = container.getBoundingClientRect()

    const startX = event.type === 'touchstart' ? event.touches[0].clientX : event.clientX
    const startY = event.type === 'touchstart' ? event.touches[0].clientY : event.clientY
    const origLeft = rect.left
    const origTop = rect.top

    document.body.classList.add('widget-dragging')

    const onMove = (e) => {
      const clientX = e.type === 'touchmove' ? e.touches[0].clientX : e.clientX
      const clientY = e.type === 'touchmove' ? e.touches[0].clientY : e.clientY
      let newLeft = origLeft + (clientX - startX)
      let newTop  = origTop  + (clientY - startY)

      // Clamp to viewport
      newLeft = Math.max(0, Math.min(newLeft, window.innerWidth - 60))
      newTop  = Math.max(0, Math.min(newTop, window.innerHeight - 60))

      container.style.left = `${newLeft}px`
      container.style.top  = `${newTop}px`
      container.classList.add('widget-custom-pos')
      // Only the 56px container is clamped above; the panel hangs up and to
      // the left of it, so without this the header (with the reset and
      // minimise buttons) is dragged straight off the top-left of the window.
      this._fitPanelInViewport()
    }

    const onUp = () => {
      document.body.classList.remove('widget-dragging')
      document.removeEventListener('mousemove', onMove)
      document.removeEventListener('mouseup', onUp)
      document.removeEventListener('touchmove', onMove)
      document.removeEventListener('touchend', onUp)
      this._persistWidgetPosition()
      this._syncResetPositionButton()
    }

    document.addEventListener('mousemove', onMove)
    document.addEventListener('mouseup', onUp)
    document.addEventListener('touchmove', onMove, { passive: false })
    document.addEventListener('touchend', onUp)
  },

  /**
   * Start resizing the widget (edge/corner handle mousedown / touchstart).
   * Resizes the panel from any edge or corner based on data-resize-dir.
   */

  startResize(event) {
    if (window.innerWidth < 640) return
    if (event.type === 'mousedown' && event.button !== 0) return
    event.preventDefault()
    event.stopPropagation()

    const panel = this.hasWidgetTarget ? this.widgetTarget : document.getElementById('chatbot-widget-panel')
    const container = this.element
    if (!panel) return

    const dir = event.currentTarget.dataset.resizeDir || 'se'
    const startX = event.type === 'touchstart' ? event.touches[0].clientX : event.clientX
    const startY = event.type === 'touchstart' ? event.touches[0].clientY : event.clientY
    const origWidth  = panel.offsetWidth
    const origHeight = panel.offsetHeight
    const containerRect = container.getBoundingClientRect()
    const origContainerLeft = containerRect.left
    const origContainerTop = containerRect.top

    document.body.classList.add('widget-resizing')

    const minW = 320, minH = 300
    const maxW = window.innerWidth - 32
    const maxH = window.innerHeight - 100

    const onMove = (e) => {
      const clientX = e.type === 'touchmove' ? e.touches[0].clientX : e.clientX
      const clientY = e.type === 'touchmove' ? e.touches[0].clientY : e.clientY

      const dx = clientX - startX
      const dy = clientY - startY

      let newW = origWidth
      let newH = origHeight

      // Width changes
      if (dir.includes('e')) {
        newW = Math.max(minW, Math.min(origWidth + dx, maxW))
      } else if (dir.includes('w')) {
        newW = Math.max(minW, Math.min(origWidth - dx, maxW))
      }

      // Height changes
      if (dir.includes('s')) {
        newH = Math.max(minH, Math.min(origHeight + dy, maxH))
      } else if (dir.includes('n')) {
        newH = Math.max(minH, Math.min(origHeight - dy, maxH))
      }

      panel.style.transition = 'none'
      panel.style.width     = `${newW}px`
      panel.style.height    = `${newH}px`
      panel.style.maxHeight = `${newH}px`

    }

    const onUp = () => {
      document.body.classList.remove('widget-resizing')
      document.removeEventListener('mousemove', onMove)
      document.removeEventListener('mouseup', onUp)
      document.removeEventListener('touchmove', onMove)
      document.removeEventListener('touchend', onUp)
      panel.style.transition = ''
      // A taller or wider panel can reach past the top-left of the window
      // from a bubble position that fitted before the resize.
      this._fitPanelInViewport()
      this._persistWidgetSize()
      this._syncResetPositionButton()
    }

    document.addEventListener('mousemove', onMove)
    document.addEventListener('mouseup', onUp)
    document.addEventListener('touchmove', onMove, { passive: false })
    document.addEventListener('touchend', onUp)
  },

  // ═══════════════════════════════════════════════
  // MAXIMIZE / RESTORE TOGGLE (the □ button in header)
  // ═══════════════════════════════════════════════

  /**
   * Toggle between default (small) and expanded (large) fixed sizes.
   * Clears any user-resized dimensions so CSS classes control the size.
   */
  resetWidgetLayout() {
    const panel = document.getElementById('chatbot-widget-panel')
    if (!panel) return

    const isExpanded = panel.classList.contains('widget-expanded')

    // Clear any user-resized dimensions so CSS classes control the size
    panel.style.width = ''
    panel.style.height = ''
    panel.style.maxHeight = ''

    // Toggle the expanded class
    panel.classList.toggle('widget-expanded', !isExpanded)

    // Swap icon: maximize (□ with inner □) ↔ restore (single □)
    const btn = document.getElementById('widget-maximize-btn')
    if (btn) {
      const svg = btn.querySelector('svg')
      if (svg) {
        if (!isExpanded) {
          // Now expanded → show restore icon (overlapping windows)
          svg.innerHTML = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 3h8a2 2 0 012 2v8M3 8h8a2 2 0 012 2v8a2 2 0 01-2 2H3a2 2 0 01-2-2v-8a2 2 0 012-2z"/>'
        } else {
          // Now restored → show maximize icon (single square)
          svg.innerHTML = '<rect x="3" y="3" width="18" height="18" rx="2" stroke-width="2"/>'
        }
      }
      // Update aria-label/title
      const maximizeLabels = { nl: 'Vergroten', fr: 'Agrandir', de: 'Vergrößern', en: 'Maximize' }
      const minimizeLabels = { nl: 'Verkleinen', fr: 'Réduire', de: 'Verkleinern', en: 'Minimize' }
      const lang = document.documentElement.lang || 'nl'
      const label = !isExpanded ? (minimizeLabels[lang] || minimizeLabels.nl) : (maximizeLabels[lang] || maximizeLabels.nl)
      btn.setAttribute('aria-label', label)
      btn.setAttribute('title', label)
    }

    // Scroll messages to bottom after expansion
    if (!isExpanded && this.hasMessagesTarget) {
      requestAnimationFrame(() => this.scrollToBottom())
    }

    // Persist layout state
    if (typeof this._persistWidgetSize === 'function') this._persistWidgetSize()
    if (typeof this._syncResetPositionButton === 'function') this._syncResetPositionButton()
  },

  // ═══════════════════════════════════════════════
  // RESET POSITION - snap bubble back to default bottom-right
  // ═══════════════════════════════════════════════

  /**
   * Reset the widget to its original position and size.
   * Clears all custom position/size, removes stored layout prefs.
   */
  resetWidgetPosition() {
    const container = document.getElementById('chatbot-widget-container')
    const panel = document.getElementById('chatbot-widget-panel')

    // Reset position
    if (container) {
      container.classList.remove('widget-custom-pos')
      container.style.left = ''
      container.style.top = ''
    }

    // Reset size
    if (panel) {
      panel.style.width = ''
      panel.style.height = ''
      panel.style.maxHeight = ''
      panel.classList.remove('widget-expanded')
    }

    // Reset maximize button icon back to maximize (single square)
    const maxBtn = document.getElementById('widget-maximize-btn')
    if (maxBtn) {
      const svg = maxBtn.querySelector('svg')
      if (svg) {
        svg.innerHTML = '<rect x="3" y="3" width="18" height="18" rx="2" stroke-width="2"/>'
      }
      const lang = document.documentElement.lang || 'nl'
      const labels = { nl: 'Vergroten', fr: 'Agrandir', de: 'Vergrößern', en: 'Maximize' }
      const label = labels[lang] || labels.nl
      maxBtn.setAttribute('aria-label', label)
      maxBtn.setAttribute('title', label)
    }

    // Back at the default corner nothing needs nudging, so this clears the
    // inline offsets the previous position left on the panel.
    this._fitPanelInViewport()

    // Clear stored layout prefs. remove() sends a null, which deletes the key
    // on the server. The empty object sent before was merged into the stored
    // layout (RFC 7396, User#merge_ui_prefs!) and changed nothing there, so a
    // signed-in reader got the old position and size back on the next page.
    try {
      prefsStore.remove('chatbot_widget')
    } catch (_) {}

    // Sync reset button state (now nothing to reset, so disable it)
    this._syncResetPositionButton()
  },

  // ═══════════════════════════════════════════════
  // WIDGET OPTIONS PANEL
  // ═══════════════════════════════════════════════

  toggleWidgetOptions() {
    if (!this.hasWidgetOptionsPanelTarget) return
    const panel = this.widgetOptionsPanelTarget
    const isHidden = panel.classList.contains('hidden')
    panel.classList.toggle('hidden', !isHidden)

    // Update aria-expanded on toggle button
    const btn = document.getElementById('widget-options-toggle')
    if (btn) btn.setAttribute('aria-expanded', isHidden ? 'true' : 'false')
  },

  // ═══════════════════════════════════════════════
  // LAYOUT PERSISTENCE
  // ═══════════════════════════════════════════════

  /**
   * Restore previously persisted widget layout (called from connect()).
   */

  _restoreWidgetLayout() {
    // connect() always calls this, which makes it the mixin's init hook; the
    // watcher has to be bound before the mobile bail-out so it is in place if
    // the window is widened later.
    this._watchPanelFit()
    // A page snapshot never brings an open bubble menu back.
    this.closeFabMenu()
    this._applySavedWidgetLayout()
  },

  // Run again once the server's copy of a signed-in reader's preferences has
  // arrived (chatbot_controller.js, _initPreferencesAsync): on a full page load
  // the store is still empty at connect, so the saved position and size only
  // came back with the next Turbo visit.
  _applySavedWidgetLayout() {
    if (window.innerWidth < 640) return // never restore on mobile

    let saved
    try {
      saved = prefsStore.get('chatbot_widget', null)
      if (typeof saved === 'string') saved = JSON.parse(saved)
    } catch (_) { return }
    if (!saved) return

    const container = this.element
    const panel = this.hasWidgetTarget ? this.widgetTarget : document.getElementById('chatbot-widget-panel')

    // Only the floating widget has a panel. On the full /chatbot page the
    // controller element is the main chat container; applying a saved
    // drag position there would shove the whole page layout around.
    if (!panel) return

    if (saved.left != null && saved.top != null) {
      // Ensure the saved position is still within the viewport
      const safeLeft = Math.max(0, Math.min(saved.left, window.innerWidth - 60))
      const safeTop  = Math.max(0, Math.min(saved.top, window.innerHeight - 60))
      container.style.left = `${safeLeft}px`
      container.style.top  = `${safeTop}px`
      container.classList.add('widget-custom-pos')
    }

    if (panel && saved.width != null) {
      panel.style.width = `${Math.min(saved.width, window.innerWidth - 32)}px`
    }
    if (panel && saved.height != null) {
      const safeH = Math.min(saved.height, window.innerHeight - 100)
      panel.style.height    = `${safeH}px`
      panel.style.maxHeight = `${safeH}px`
    }

    // Restore expanded (maximized) state
    if (panel && saved.expanded) {
      panel.classList.add('widget-expanded')
      // Swap maximize icon to restore icon
      const maxBtn = document.getElementById('widget-maximize-btn')
      if (maxBtn) {
        const svg = maxBtn.querySelector('svg')
        if (svg) {
          svg.innerHTML = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 3h8a2 2 0 012 2v8M3 8h8a2 2 0 012 2v8a2 2 0 01-2 2H3a2 2 0 01-2-2v-8a2 2 0 012-2z"/>'
        }
        const minimizeLabels = { nl: 'Verkleinen', fr: 'Réduire', de: 'Verkleinern', en: 'Minimize' }
        const lang = document.documentElement.lang || 'nl'
        maxBtn.setAttribute('aria-label', minimizeLabels[lang] || minimizeLabels.nl)
        maxBtn.setAttribute('title', minimizeLabels[lang] || minimizeLabels.nl)
      }
    }

    // Show reset button if any customisation was restored
    this._syncResetPositionButton()
  },

  /**
   * Persist current widget layout to prefsStore.
   */

  // The bubble's place: where it was dragged, or null for both coordinates once it is back at the default.
  _persistWidgetPosition() {
    const container = this.element
    if (!container.classList.contains('widget-custom-pos')) {
      this._saveWidgetLayout({ left: null, top: null })
      return
    }
    const rect = container.getBoundingClientRect()
    this._saveWidgetLayout({ left: Math.round(rect.left), top: Math.round(rect.top) })
  },

  // The panel's size: its resized width and height, null where the CSS sizes it, and whether it is maximized.
  _persistWidgetSize() {
    const panel = this._widgetPanel()
    if (!panel) return
    const w = panel.style.width
    const h = panel.style.height || panel.style.maxHeight
    this._saveWidgetLayout({ width: w ? parseInt(w, 10) : null, height: h ? parseInt(h, 10) : null,
                             expanded: panel.classList.contains('widget-expanded') ? true : null })
  },

  // Saves only the keys an action changed, each as its own nested key. The server merges a patch per RFC 7396
  // (User#merge_ui_prefs!): a key left out is kept and a null deletes it. Before the server copy of the preferences
  // arrives, the store holds and sends only these keys, and applies them over that copy when it comes
  // (PreferencesStore#_doInit): a reset made that early is not undone by the saved position, and a position change
  // never clears the saved size. Sending the whole layout did both (Sol 2026-11-22 06:00:58Z).
  _saveWidgetLayout(values) {
    // Only the floating widget has a layout to keep (see _restoreWidgetLayout).
    if (!this._widgetPanel()) return
    try {
      for (const [key, value] of Object.entries(values)) prefsStore.set(`chatbot_widget.${key}`, value)
    } catch (_) { /* save failed - silently ignore */ }
  },

  _widgetPanel() {
    return this.hasWidgetTarget ? this.widgetTarget : document.getElementById('chatbot-widget-panel')
  },

  /**
   * Sync the reset-position button: enabled when widget has custom pos/size,
   * disabled (grayed out) when widget is in its default state.
   */

  _syncResetPositionButton() {
    const resetBtn = document.getElementById('widget-reset-position-btn')
    const container = document.getElementById('chatbot-widget-container')
    const panel = document.getElementById('chatbot-widget-panel')
    if (!resetBtn) return

    const hasCustomPos = container?.classList.contains('widget-custom-pos')
    const hasCustomSize = !!(panel?.style.width || panel?.style.maxHeight)
    const isExpanded = panel?.classList.contains('widget-expanded')
    const isCustomized = hasCustomPos || hasCustomSize || isExpanded

    // Always visible, toggle enabled/disabled appearance
    resetBtn.classList.remove('hidden')

    if (isCustomized) {
      resetBtn.disabled = false
      resetBtn.classList.remove('opacity-30', 'cursor-default', 'pointer-events-none')
      resetBtn.classList.add('cursor-pointer')
    } else {
      resetBtn.disabled = true
      resetBtn.classList.add('opacity-30', 'cursor-default', 'pointer-events-none')
      resetBtn.classList.remove('cursor-pointer')
    }
  },
}
