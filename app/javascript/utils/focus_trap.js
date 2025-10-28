/**
 * Focus Trap Utility
 *
 * Provides reusable focus trapping for modal dialogs.
 * Traps Tab/Shift+Tab within a container, restores focus on release.
 *
 * @example
 * import { trapFocus, releaseFocus } from '../utils/focus_trap'
 * trapFocus(modalElement)  // starts trapping
 * releaseFocus()           // restores focus to trigger
 */

const FOCUSABLE_SELECTOR = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled]):not([type="hidden"])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
].join(', ')

let _trapState = null

/**
 * Activates a focus trap within the given container element.
 * Stores the currently focused element so it can be restored later.
 *
 * @param {HTMLElement} container - The modal/dialog element to trap focus within
 */
export function trapFocus(container) {
  if (!container) return

  // Store trigger element for restoration
  const triggerElement = document.activeElement

  _trapState = {
    container,
    triggerElement,
    handler: (e) => _handleTab(e, container),
  }

  document.addEventListener('keydown', _trapState.handler)

  // Move focus to first focusable element inside the container
  requestAnimationFrame(() => {
    const first = container.querySelector(FOCUSABLE_SELECTOR)
    if (first) first.focus()
  })
}

/**
 * Releases the focus trap and restores focus to the trigger element.
 */
export function releaseFocus() {
  if (!_trapState) return

  document.removeEventListener('keydown', _trapState.handler)

  // Restore focus to the element that opened the modal
  if (_trapState.triggerElement && _trapState.triggerElement.focus) {
    requestAnimationFrame(() => {
      _trapState.triggerElement.focus()
      _trapState = null
    })
  } else {
    _trapState = null
  }
}

/**
 * Handles Tab/Shift+Tab to cycle focus within the container.
 * Also handles Escape to release the trap.
 */
function _handleTab(event, container) {
  if (event.key === 'Escape') {
    releaseFocus()
    return
  }

  if (event.key !== 'Tab') return

  const focusable = Array.from(container.querySelectorAll(FOCUSABLE_SELECTOR))
  if (focusable.length === 0) return

  const first = focusable[0]
  const last = focusable[focusable.length - 1]

  if (event.shiftKey) {
    // Shift+Tab: wrap from first to last
    if (document.activeElement === first) {
      event.preventDefault()
      last.focus()
    }
  } else {
    // Tab: wrap from last to first
    if (document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }
}
