/**
 * Timing Utilities
 *
 * Shared debounce and throttle functions for Stimulus controllers.
 * Replaces inline implementations in toc_tracker_controller.js.
 *
 * @example
 * import { debounce, throttle } from '../utils/timing'
 * this.scrollHandler = throttle(this.handleScroll.bind(this), 50)
 * this.resizeHandler = debounce(this.handleResize.bind(this), 100)
 */

/**
 * Creates a debounced version of a function that delays execution
 * until after `wait` ms have elapsed since the last call.
 *
 * @param {Function} func - Function to debounce
 * @param {number} wait - Delay in milliseconds
 * @returns {Function} Debounced function
 */
export function debounce(func, wait) {
  let timeout
  return function (...args) {
    clearTimeout(timeout)
    timeout = setTimeout(() => func.apply(this, args), wait)
  }
}

/**
 * Creates a throttled version of a function that executes at most
 * once per `limit` ms interval.
 *
 * @param {Function} func - Function to throttle
 * @param {number} limit - Minimum interval in milliseconds
 * @returns {Function} Throttled function
 */
export function throttle(func, limit) {
  let inThrottle
  return function (...args) {
    if (!inThrottle) {
      func.apply(this, args)
      inThrottle = true
      setTimeout(() => { inThrottle = false }, limit)
    }
  }
}
