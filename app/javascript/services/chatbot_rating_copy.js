// Localized copy for the 10-star answer rating (RAT-005).
//
// One map for every string the control shows, so the controller and the mixin
// cannot drift apart on wording, and so a translator has a single file to
// work in. Pure data plus one lookup helper: no DOM, no state, no imports.
//
// The reason CODES are the stable database values from
// ChatbotRating::Configuration and must never be translated - only their
// labels are.

const COPY = {
  rate: { nl: "Beoordeel", fr: "Évaluer", de: "Bewerten", en: "Rate" },
  question: {
    nl: "Hoe nuttig was dit antwoord?",
    fr: "Dans quelle mesure cette réponse a-t-elle été utile ?",
    de: "Wie hilfreich war diese Antwort?",
    en: "How useful was this answer?"
  },
  // Usefulness, deliberately not correctness: a star score is subjective
  // product feedback, never a claim that legal advice was right.
  thanks: { nl: "Bedankt", fr: "Merci", de: "Danke", en: "Thanks" },
  saved: { nl: "Opgeslagen", fr: "Enregistré", de: "Gespeichert", en: "Saved" },
  notSaved: {
    nl: "Niet opgeslagen — opnieuw proberen",
    fr: "Non enregistré — réessayer",
    de: "Nicht gespeichert — erneut versuchen",
    en: "Not saved — retry"
  },
  retry: { nl: "Opnieuw", fr: "Réessayer", de: "Erneut", en: "Retry" },
  reasonPrompt: {
    nl: "Optioneel: wat viel op?",
    fr: "Facultatif : qu'est-ce qui ressort ?",
    de: "Optional: Was ist aufgefallen?",
    en: "Optional: what stood out?"
  },
  maxReasons: {
    nl: "Maximaal drie keuzes",
    fr: "Trois choix maximum",
    de: "Höchstens drei Auswahlen",
    en: "Maximum three choices"
  },
  close: { nl: "Sluiten", fr: "Fermer", de: "Schließen", en: "Close" }
}

// "8 out of 10" in each language, for the radio's accessible name. The star
// glyph is decorative; this label is what assistive technology announces.
const SCORE_LABEL = {
  nl: (n, max) => `${n} van ${max}`,
  fr: (n, max) => `${n} sur ${max}`,
  de: (n, max) => `${n} von ${max}`,
  en: (n, max) => `${n} out of ${max}`
}

const REASON_LABELS = {
  incorrect: { nl: "Onjuist", fr: "Incorrect", de: "Falsch", en: "Incorrect" },
  incomplete: { nl: "Onvolledig", fr: "Incomplet", de: "Unvollständig", en: "Incomplete" },
  weak_sources: { nl: "Zwakke bronnen", fr: "Sources faibles", de: "Schwache Quellen", en: "Weak sources" },
  unclear: { nl: "Onduidelijk", fr: "Peu clair", de: "Unklar", en: "Unclear" },
  too_long: { nl: "Te lang", fr: "Trop long", de: "Zu lang", en: "Too long" },
  too_slow: { nl: "Te traag", fr: "Trop lent", de: "Zu langsam", en: "Too slow" },
  clear_practical: { nl: "Duidelijk en praktisch", fr: "Clair et pratique", de: "Klar und praktisch", en: "Clear & practical" },
  complete: { nl: "Volledig", fr: "Complet", de: "Vollständig", en: "Complete" },
  strong_sources: { nl: "Sterke bronnen", fr: "Sources solides", de: "Starke Quellen", en: "Strong sources" },
  fast: { nl: "Snel", fr: "Rapide", de: "Schnell", en: "Fast" }
}

const DEFAULT_LANGUAGE = "nl"

export function ratingText(key, language = DEFAULT_LANGUAGE) {
  const entry = COPY[key]
  if (!entry) return ""
  return entry[language] || entry[DEFAULT_LANGUAGE]
}

export function scoreLabel(score, language = DEFAULT_LANGUAGE, max = 10) {
  const builder = SCORE_LABEL[language] || SCORE_LABEL[DEFAULT_LANGUAGE]
  return builder(score, max)
}

export function reasonLabel(code, language = DEFAULT_LANGUAGE) {
  const entry = REASON_LABELS[code]
  // An unknown code falls back to its own value rather than empty text, so a
  // server-side allowlist addition degrades to something readable instead of
  // rendering a blank chip.
  if (!entry) return code
  return entry[language] || entry[DEFAULT_LANGUAGE]
}

export function knownReasonCodes() {
  return Object.keys(REASON_LABELS)
}
