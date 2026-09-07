// Pure progress-display logic for the chatbot (FBL-062, extracted from
// chatbot_controller.js). Data and decisions only - the controller keeps the
// timers and the two target writes. The monotonic clamp exists because
// simulated phases, server progress events and heartbeats write the same bar
// and can arrive out of order; a bar that jumps backwards (or to 0 when an
// event omits `percent`) reads as "stuck at zero".

const PROCESSING_LABELS = { nl: "Verwerken...", fr: "Traitement...", de: "Verarbeitung...", en: "Processing..." }
const DONE_LABELS = { nl: "Voltooid", fr: "Terminé", de: "Fertig", en: "Done" }

const PHASES = {
  fr: [
    { progress: 15, text: "Génération embedding", duration: 1000 },
    { progress: 30, text: "Recherche base de données", duration: 2000 },
    { progress: 50, text: "Recherche articles", duration: 4000 },
    { progress: 70, text: "Analyse des résultats", duration: 5000 },
    { progress: 85, text: "Construction contexte", duration: 4000 },
    { progress: 95, text: "Génération réponse", duration: 3000 }
  ],
  en: [
    { progress: 15, text: "Generating embedding", duration: 1000 },
    { progress: 30, text: "Searching database", duration: 2000 },
    { progress: 50, text: "Finding articles", duration: 4000 },
    { progress: 70, text: "Analyzing results", duration: 5000 },
    { progress: 85, text: "Building context", duration: 4000 },
    { progress: 95, text: "Generating answer", duration: 3000 }
  ],
  de: [
    { progress: 15, text: "Embedding generieren", duration: 1000 },
    { progress: 30, text: "Datenbank durchsuchen", duration: 2000 },
    { progress: 50, text: "Artikel suchen", duration: 4000 },
    { progress: 70, text: "Ergebnisse analysieren", duration: 5000 },
    { progress: 85, text: "Kontext aufbauen", duration: 4000 },
    { progress: 95, text: "Antwort generieren", duration: 3000 }
  ],
  nl: [
    { progress: 15, text: "Embedding genereren", duration: 1000 },
    { progress: 30, text: "Database doorzoeken", duration: 2000 },
    { progress: 50, text: "Artikelen zoeken", duration: 4000 },
    { progress: 70, text: "Resultaten analyseren", duration: 5000 },
    { progress: 85, text: "Context opbouwen", duration: 4000 },
    { progress: 95, text: "Antwoord genereren", duration: 3000 }
  ]
}

// `verifying` and `refining` are the phases that actually consume the time on
// a slow answer: the citation guard checks every reference, and a rejected
// answer is regenerated in full. Measured on a real 78-second ask, the
// provider ran THREE times and two answers were discarded - all of it behind
// a bar frozen at 95%. These steps sit above `generating` so the bar keeps
// creeping forward across retries instead of appearing stuck.
const STEP_PERCENT = { searching: 30, analyzing: 60, generating: 85, verifying: 90, refining: 92 }
const STEP_LABEL = {
  searching: { nl: "Database doorzoeken", fr: "Recherche base de données", de: "Datenbank durchsuchen", en: "Searching database" },
  analyzing: { nl: "Resultaten analyseren", fr: "Analyse des résultats", de: "Ergebnisse analysieren", en: "Analyzing results" },
  generating: { nl: "Antwoord genereren", fr: "Génération réponse", de: "Antwort generieren", en: "Generating answer" },
  verifying: { nl: "Bronverwijzingen controleren", fr: "Vérification des références", de: "Quellenangaben prüfen", en: "Checking citations" },
  refining: { nl: "Antwoord verfijnen", fr: "Affinage de la réponse", de: "Antwort verfeinern", en: "Refining answer" }
}

// A retry is shown as "Antwoord verfijnen (1/2)" so a long wait reads as work
// in progress rather than a stall.
function stepLabelWithAttempt(step, lang, parsed) {
  const base = STEP_LABEL[step] && (STEP_LABEL[step][lang] || STEP_LABEL[step].nl)
  if (!base) return null
  if (!parsed.attempt) return base

  const total = parsed.max_attempts ? `/${parsed.max_attempts}` : ""
  return `${base} (${parsed.attempt}${total})`
}

export function processingLabel(language) {
  return PROCESSING_LABELS[language] || PROCESSING_LABELS.nl
}

export function doneLabel(language) {
  return DONE_LABELS[language] || DONE_LABELS.nl
}

export function progressPhases(language) {
  return PHASES[language] || PHASES.nl
}

// Translate a server progress event into { percent, label }. The server sends
// only a step name (`{type:'progress', step:'searching'}`); an event without a
// usable percent keeps the bar where it is instead of slamming it to 0.
export function resolveServerProgress(parsed, language, currentProgress) {
  const lang = language || "nl"
  let pct = typeof parsed.percent === "number" ? parsed.percent : STEP_PERCENT[parsed.step]
  // Nudge the bar forward on each successive retry so two regenerations do
  // not both render at the same width, which reads as frozen.
  if (parsed.step === "refining" && parsed.attempt) pct = Math.min(97, STEP_PERCENT.refining + (parsed.attempt * 2))

  const label = parsed.message || stepLabelWithAttempt(parsed.step, lang, parsed) || processingLabel(lang)
  return { percent: pct ?? currentProgress, label }
}

// Monotonic 0..100 clamp for the bar.
export function clampProgress(next, current) {
  return Math.min(100, Math.max(Number(next) || 0, current || 0))
}
