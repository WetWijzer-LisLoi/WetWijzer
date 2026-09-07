/**
 * Chatbot Controller - Layout Mixin
 *
 * Methods extracted from chatbot_controller.js for maintainability.
 * Mixed into the controller prototype - all methods use 'this' as normal.
 */

import { prefs as prefsStore } from "../../services/preferences_store"

export const layoutMethods = {
  handleFabKeydown(event) {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault()
      this.toggle()
    }
  },

  // Auto-resize widget textarea

  autoResizeWidget() {
    if (!this.hasInputTarget) return
    const el = this.inputTarget
    el.style.height = 'auto'
    el.style.height = Math.min(el.scrollHeight, 120) + 'px'
  },

  // Toggle between default and expanded size (maximize / restore)
  // NOTE: Use resetWidgetLayout() instead — this is the canonical
  // maximize/restore toggle bound to the □ button and dblclick.

  // ═══════════════════════════════════════════════
  // WIDGET DRAG & RESIZE - move and resize the floating widget
  // ═══════════════════════════════════════════════

  // Start dragging the FAB button itself (mousedown/touchstart on the circle)
  // ALL interaction is handled via mousedown→mousemove→mouseup.
  // Click event on FAB is removed - we handle open/close in mouseup.

  startFabDrag(event) {
    if (window.innerWidth < 640) {
      // Mobile: no drag, just toggle. A tap fires touchstart AND an emulated
      // mousedown (~300ms later), both bound to this handler — running toggle()
      // twice makes the widget open then immediately auto-close on reopen. On a
      // phone there is no real mouse, so ignore mousedown and act only on the tap.
      if (event.type === 'mousedown') return
      this.toggle()
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
  },

  _onFabDragEnd(event) {
    document.removeEventListener('mousemove', this._boundFabDragMove)
    document.removeEventListener('mouseup', this._boundFabDragEnd)
    document.removeEventListener('touchmove', this._boundFabDragMove)
    document.removeEventListener('touchend', this._boundFabDragEnd)
    document.body.classList.remove('widget-dragging')

    const wasDragging = this._fabDragState?.dragging
    this._fabDragState = null

    if (wasDragging) {
      // Was a drag - persist position, do NOT open/close
      this._persistWidgetLayout()
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
    }

    const onUp = () => {
      document.body.classList.remove('widget-dragging')
      document.removeEventListener('mousemove', onMove)
      document.removeEventListener('mouseup', onUp)
      document.removeEventListener('touchmove', onMove)
      document.removeEventListener('touchend', onUp)
      this._persistWidgetLayout()
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
      this._persistWidgetLayout()
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
    if (typeof this._persistWidgetLayout === 'function') this._persistWidgetLayout()
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

    // Clear stored layout prefs
    try {
      prefsStore.set('chatbot_widget', {})
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
    // controller element is the main chat container — applying a saved
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

  _persistWidgetLayout() {
    const container = this.element
    const panel = this.hasWidgetTarget ? this.widgetTarget : document.getElementById('chatbot-widget-panel')
    const layout = {}

    if (container.classList.contains('widget-custom-pos')) {
      const rect = container.getBoundingClientRect()
      layout.left = Math.round(rect.left)
      layout.top  = Math.round(rect.top)
    }

    if (panel) {
      const w = panel.style.width
      const h = panel.style.height || panel.style.maxHeight
      if (w) layout.width  = parseInt(w, 10)
      if (h) layout.height = parseInt(h, 10)
      if (panel.classList.contains('widget-expanded')) layout.expanded = true
    }

    try {
      prefsStore.set('chatbot_widget', layout)
    } catch (_) { /* save failed - silently ignore */ }
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
