/**
 * Locale Detection Utility
 *
 * Provides a unified locale detection API for all Stimulus controllers.
 * UI copy must select all four supported locales, never use a language
 * predicate as a Dutch-versus-everything-else translation switch.
 *
 * @example
 * import { localeText } from '../utils/locale'
 * const msg = localeText({ nl: 'Gekopieerd!', fr: 'Copié !', de: 'Kopiert!', en: 'Copied!' })
 */

/**
 * Returns the current page locale from the <html> lang attribute.
 * Falls back to 'nl' (Dutch) if not set - WetWijzer's primary language.
 *
 * @returns {string} Two-letter locale code (e.g., 'nl', 'fr', 'de', 'en')
 */
export function getLocale() {
  const locale = (document.documentElement.lang || 'nl').toLowerCase().split(/[-_]/)[0]
  return ['nl', 'fr', 'de', 'en'].includes(locale) ? locale : 'nl'
}

/** Select app-owned UI copy. Source document titles and identifiers stay intact. */
export function localeText(values, locale = getLocale()) {
  return values[locale] ?? values.nl
}

/**
 * Returns true if the current page is in Dutch.
 * This predicate is not a two-language translation selector.
 *
 * @returns {boolean}
 */
export function isDutch() {
  return getLocale() === 'nl'
}

/**
 * Returns true only if the current page is in French.
 */
export function isFrench() {
  return getLocale() === 'fr'
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
