/**
 * Shared Toast Notification Utility
 *
 * Provides a unified toast notification system for all Stimulus controllers.
 * Replaces 8 duplicate `showToast()` implementations across the codebase.
 *
 * @example
 * import { showToast } from '../utils/toast'
 * showToast('Gekopieerd!')
 * showToast('Erreur', { duration: 5000, type: 'error' })
 */

const TOAST_CLASS = 'ww-toast'
const DEFAULT_DURATION = 2000
const FADE_OUT_DURATION = 300

/**
 * Shows a toast notification at the bottom-center of the viewport.
 *
 * @param {string} message - The message to display
 * @param {Object} [options] - Configuration options
 * @param {number} [options.duration=2000] - Time in ms before the toast fades out
 * @param {string} [options.type='success'] - Toast type: 'success' | 'error' | 'info'
 */
export function showToast(message, options = {}) {
  const { duration = DEFAULT_DURATION, type = 'success' } = options

  // Remove any existing toast
  const existing = document.querySelector(`.${TOAST_CLASS}`)
  if (existing) existing.remove()

  // Create toast element
  const toast = document.createElement('div')
  toast.className = buildToastClasses(type)
  toast.textContent = message
  toast.setAttribute('role', type === 'error' ? 'alert' : 'status')
  toast.setAttribute('aria-live', type === 'error' ? 'assertive' : 'polite')

  // Apply accent color for info toasts via inline style (CSS vars can't be used in Tailwind classes)
  if (type === 'info') {
    toast.style.backgroundColor = 'var(--accent-600)'
  }

  document.body.appendChild(toast)

  // Auto-dismiss
  setTimeout(() => {
    toast.classList.add('animate-fade-out')
    setTimeout(() => toast.remove(), FADE_OUT_DURATION)
  }, duration)
}

/**
 * Builds the CSS class string for the toast based on type.
 * @param {string} type - Toast type
 * @returns {string} Space-separated CSS classes
 */
function buildToastClasses(type) {
  const base = [
    TOAST_CLASS,
    'fixed bottom-6 left-1/2 -translate-x-1/2 z-9999',
    'px-4 py-2 text-sm font-medium rounded-lg shadow-lg',
    'animate-fade-in-up'
  ]

  switch (type) {
    case 'error':
      base.push('bg-red-600 dark:bg-red-500 text-white')
      break
    case 'info':
      base.push('text-white')
      // Use accent color via inline style set below
      break
    default: // success
      base.push('bg-gray-900 dark:bg-gray-100 text-white dark:text-gray-900')
  }

  return base.join(' ')
}
