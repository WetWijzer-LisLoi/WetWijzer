/**
 * Locale Detection Utility
 *
 * Provides a unified locale detection API for all Stimulus controllers.
 * Uses NL-primary checks: isDutch() returns true for wetwijzer.be,
 * false for lisloi.be (FR) and gesetzguide.be (DE).
 *
 * @example
 * import { getLocale, isDutch } from '../utils/locale'
 * const msg = isDutch() ? 'Gekopieerd!' : 'Copié!'
 */

/**
 * Returns the current page locale from the <html> lang attribute.
 * Falls back to 'nl' (Dutch) if not set — WetWijzer's primary language.
 *
 * @returns {string} Two-letter locale code (e.g., 'nl', 'fr', 'de', 'en')
 */
export function getLocale() {
  return document.documentElement.lang || 'nl'
}

/**
 * Returns true if the current page is in Dutch.
 * Used for NL-primary UI branching: DE falls back to FR.
 *
 * @returns {boolean}
 */
export function isDutch() {
  return getLocale() === 'nl'
}

/**
 * @deprecated Use isDutch() instead. Kept for backward compatibility.
 * Returns true if the current page is NOT Dutch (i.e., FR or DE).
 */
export function isFrench() {
  return getLocale() !== 'nl'
}

/**
 * Returns true if the current page is in German.
 * Used for GesetzGuide integration.
 *
 * @returns {boolean}
 */
export function isGerman() {
  return getLocale() === 'de'
}
