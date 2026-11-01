// The per-answer metadata record (schema v1) in the browser: the server's
// record for an answer (result.answer_meta, LegalChatbot::AnswerMeta), the
// record of a question that ended without an answer, and the one line every
// export prints under an answer. Pure functions; the controller and the
// export mixin keep the DOM. Pinned by test/javascript/answer_meta_test.mjs.
//
// A record keeps four parts apart: what was requested, what the last
// final-answer call did, the citation guard outcome, and what the visible
// answer is. The model is named only for a generated answer. A record from
// an import is a claimed snapshot ("imported"), never shown as verified,
// and an answer without a record (every answer before this release) says
// "not recorded" instead of borrowing today's controls.

const MAX_BYTES = 2048
const STATUSES = [
  'generated', 'verified_recovery', 'sources_only', 'withheld', 'no_model_answer', 'timeout', 'incomplete', 'error',
  'cancelled', 'not_started', 'unknown'
]

// The application's model names (ModelsConfig::AVAILABLE_MODELS and
// RETIRED_MODEL_NAMES); a historical id keeps its own name, never today's
// replacement's. test/services/legal_chatbot_answer_meta_names_test.rb keeps
// this list equal to the Ruby registry.
export const MODEL_NAMES = {
  'gpt-6-luna': 'GPT-6 Luna',
  'gpt-6.1-sol': 'GPT-6.1 Sol',
  'mistral-small': 'Mistral Small 4',
  'mistral-large-4': 'Mistral Large 4',
  'claude-haiku-5-5': 'Claude Haiku 5.5',
  'claude-sonnet-5-5': 'Claude Sonnet 5.5',
  'claude-opus-5-5': 'Claude Opus 5.5',
  'o4-mini': 'o4-mini',
  'gpt-5-mini': 'GPT-5 Mini',
  'gpt-5': 'GPT-5',
  'gpt-5.4': 'GPT-5.4',
  'gpt-5.5': 'GPT-5.5',
  'gpt-5.6-luna': 'GPT-5.6 Luna',
  'gpt-5.6-terra': 'GPT-5.6 Terra',
  'gpt-5.6-sol': 'GPT-5.6 Sol',
  'gpt-6-sol': 'GPT-6 Sol',
  'mistral-large-3': 'Mistral Large 3',
  'claude-4.5-haiku': 'Claude Haiku 4.5',
  'claude-sonnet-4-6': 'Claude Sonnet 4.6',
  'claude-opus-4-6': 'Claude Opus 4.6'
}

// As written in Profiles::CHATBOT_PROFILES (name_nl/fr/en/de), the research
// depth labels of config/locales/research_depth.yml and the reasoning levels
// of ModelsConfig::REASONING_LEVELS.
const CATEGORY_NAMES = {
  nl: { general: 'Algemeen Recht', tax: 'Fiscaal Recht ⚠️ experimenteel', labor: 'Arbeidsrecht',
        corporate: 'Vennootschapsrecht', real_estate: 'Vastgoedrecht', family: 'Familierecht', migration: 'Migratierecht',
        consumer: 'Consumentenrecht', criminal: 'Strafrecht', social: 'Sociale Zekerheid', administrative: 'Bestuursrecht',
        privacy: 'Privacyrecht' },
  fr: { general: 'Juridique Général', tax: 'Fiscal ⚠️ expérimental', labor: 'Droit du Travail',
        corporate: 'Droit des Sociétés', real_estate: 'Immobilier', family: 'Droit de la Famille', migration: 'Migration',
        consumer: 'Droit de la Consommation', criminal: 'Droit Pénal', social: 'Sécurité Sociale',
        administrative: 'Droit Administratif', privacy: 'Vie Privée' },
  en: { general: 'General Legal', tax: 'Tax ⚠️ experimental', labor: 'Labor Law', corporate: 'Corporate Law',
        real_estate: 'Real Estate', family: 'Family Law', migration: 'Migration', consumer: 'Consumer Law',
        criminal: 'Criminal Law', social: 'Social Security', administrative: 'Administrative Law', privacy: 'Privacy Law' },
  de: { general: 'Allgemeines Recht', tax: 'Steuerrecht ⚠️ experimentell', labor: 'Arbeitsrecht',
        corporate: 'Gesellschaftsrecht', real_estate: 'Immobilienrecht', family: 'Familienrecht', migration: 'Migrationsrecht',
        consumer: 'Verbraucherrecht', criminal: 'Strafrecht', social: 'Sozialversicherung', administrative: 'Verwaltungsrecht',
        privacy: 'Datenschutzrecht' }
}

const DEPTH_NAMES = {
  nl: { quick: 'Snel', balanced: 'Gebalanceerd', thorough: 'Grondig', extensive: 'Uitgebreid' },
  fr: { quick: 'Rapide', balanced: 'Équilibrée', thorough: 'Approfondie', extensive: 'Étendue' },
  en: { quick: 'Quick', balanced: 'Balanced', thorough: 'Thorough', extensive: 'Extensive' },
  de: { quick: 'Schnell', balanced: 'Ausgewogen', thorough: 'Gründlich', extensive: 'Umfassend' }
}

const EFFORT_NAMES = {
  nl: { none: 'geen', low: 'Snel', medium: 'Gebalanceerd', high: 'Diepgaand' },
  fr: { none: 'aucune', low: 'Rapide', medium: 'Équilibré', high: 'Approfondi' },
  en: { none: 'none', low: 'Fast', medium: 'Balanced', high: 'Deep' },
  de: { none: 'keine', low: 'Schnell', medium: 'Ausgewogen', high: 'Tiefgehend' }
}

const COPY = {
  nl: {
    category: 'Categorie', model: 'Model', depth: 'Zoekdiepte', effort: 'Denkwerk', requested: 'gevraagd',
    notRecorded: 'niet vastgelegd', imported: 'geïmporteerd, niet geverifieerd', historical: 'historisch, niet geverifieerd',
    version: 'versie', lastAttempt: 'laatste poging', sent: 'verzonden', notSent: 'niet verzonden', unknown: 'onbekend',
    translated: 'vertaald', mapped: 'vertaald (vaste tekst)', frenchFallback: 'Franse tekst getoond',
    status: {
      verified_recovery: 'geen modelantwoord getoond, wel een geverifieerd antwoord op basis van de bronnen',
      sources_only: 'geen modelantwoord getoond, wel een lijst van de geverifieerde bronnen',
      withheld: 'geen modelantwoord getoond, antwoord tegengehouden',
      no_model_answer: 'geen modelantwoord',
      timeout: 'geen volledig antwoord, time-out',
      incomplete: 'geen volledig antwoord van de AI-provider',
      error: 'geen antwoord, er trad een fout op',
      cancelled: 'geen antwoord, vraag geannuleerd',
      not_started: 'geen antwoord, de vraag werd niet verwerkt',
      unknown: 'onbekend'
    }
  },
  fr: {
    category: 'Catégorie', model: 'Modèle', depth: 'Profondeur', effort: 'Réflexion', requested: 'demandé',
    notRecorded: 'non enregistré', imported: 'importé, non vérifié', historical: 'historique, non vérifié',
    version: 'version', lastAttempt: 'dernière tentative', sent: 'envoyée', notSent: 'non envoyée', unknown: 'inconnu',
    translated: 'traduit', mapped: 'traduit (texte fixe)', frenchFallback: 'texte français affiché',
    status: {
      verified_recovery: 'aucune réponse du modèle affichée, mais une réponse vérifiée fondée sur les sources',
      sources_only: 'aucune réponse du modèle affichée, mais une liste des sources vérifiées',
      withheld: 'aucune réponse du modèle affichée, réponse retenue',
      no_model_answer: 'aucune réponse du modèle',
      timeout: 'pas de réponse complète, délai dépassé',
      incomplete: 'pas de réponse complète du fournisseur d’IA',
      error: 'pas de réponse, une erreur est survenue',
      cancelled: 'pas de réponse, question annulée',
      not_started: 'pas de réponse, la question n’a pas été traitée',
      unknown: 'inconnu'
    }
  },
  en: {
    category: 'Category', model: 'Model', depth: 'Research depth', effort: 'Reasoning', requested: 'requested',
    notRecorded: 'not recorded', imported: 'imported, not verified', historical: 'historical, not verified',
    version: 'version', lastAttempt: 'last attempt', sent: 'sent', notSent: 'not sent', unknown: 'unknown',
    translated: 'translated', mapped: 'translated (fixed text)', frenchFallback: 'French text shown',
    status: {
      verified_recovery: 'no model answer shown; a verified answer derived from the sources instead',
      sources_only: 'no model answer shown; a list of the verified sources instead',
      withheld: 'no model answer shown; the answer was withheld',
      no_model_answer: 'no model answer',
      timeout: 'no complete answer, timed out',
      incomplete: 'no complete answer from the AI provider',
      error: 'no answer, an error occurred',
      cancelled: 'no answer, the question was cancelled',
      not_started: 'no answer, the question was not processed',
      unknown: 'unknown'
    }
  },
  de: {
    category: 'Kategorie', model: 'Modell', depth: 'Recherchetiefe', effort: 'Denkaufwand', requested: 'angefragt',
    notRecorded: 'nicht erfasst', imported: 'importiert, nicht geprüft', historical: 'historisch, nicht geprüft',
    version: 'Version', lastAttempt: 'letzter Versuch', sent: 'gesendet', notSent: 'nicht gesendet', unknown: 'unbekannt',
    translated: 'übersetzt', mapped: 'übersetzt (fester Text)', frenchFallback: 'französischer Text angezeigt',
    status: {
      verified_recovery: 'keine Modellantwort angezeigt, sondern eine geprüfte Antwort aus den Quellen',
      sources_only: 'keine Modellantwort angezeigt, sondern eine Liste der geprüften Quellen',
      withheld: 'keine Modellantwort angezeigt, Antwort zurückgehalten',
      no_model_answer: 'keine Modellantwort',
      timeout: 'keine vollständige Antwort, Zeitüberschreitung',
      incomplete: 'keine vollständige Antwort des KI-Anbieters',
      error: 'keine Antwort, ein Fehler ist aufgetreten',
      cancelled: 'keine Antwort, Frage abgebrochen',
      not_started: 'keine Antwort, die Frage wurde nicht verarbeitet',
      unknown: 'unbekannt'
    }
  }
}

// The schema, value by value (LegalChatbot::AnswerMeta). The browser keeps a
// record only when the WHOLE object fits it: a restored, decrypted or
// imported history is untrusted, and an unknown key, value or size drops
// the record rather than carrying it as hidden data.
const SOURCES = ['live', 'imported']
const RESPONSES = ['received', 'none']
const GENERATIONS = ['valid', 'incomplete', 'empty', 'refusal', 'error']
const GUARDS = ['analysis', 'verified_sources_fallback', 'refusal']
const TRANSLATIONS = ['translated', 'mapped', 'french_fallback']
const EFFORTS = ['none', 'low', 'medium', 'high']
const DEPTHS = ['quick', 'balanced', 'thorough', 'extensive']
const INTELLIGENCES = ['smart', 'genius', 'mastermind', 'omniscient']
const CATEGORIES = Object.keys(CATEGORY_NAMES.nl)
const MODEL_IDS = Object.keys(MODEL_NAMES)
const KEYS = {
  top: ['v', 'source', 'requested', 'attempt', 'guard', 'outcome'],
  requested: ['category', 'intelligence', 'model', 'research_depth', 'reasoning_effort', 'linked_research'],
  attempt: ['model', 'dispatched', 'response', 'generation', 'calls_started'],
  outcome: ['status', 'model', 'model_version', 'category', 'research_depth', 'reasoning_effort', 'translation']
}
const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$/

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function exactKeys(value, keys) {
  if (!isObject(value)) return false
  const own = Object.keys(value).sort()
  return own.length === keys.length && [...keys].sort().every((key, index) => own[index] === key)
}

const oneOf = (value, list) => value === null || (typeof value === 'string' && list.includes(value))
const flag = value => value === null || value === true || value === false

// The provider ids an ACTIVE model's exact revision may be reported as
// (LegalChatbot::AnswerMeta.expected_provider_ids: the application id, its
// api_model, its Bedrock profile). A retired model has none: its id is kept
// exactly, but it never acquires a revision. Azure deployment names and
// hostnames are never revisions (GenerationTrace.safe_provider_model).
// test/services/legal_chatbot_answer_meta_names_test.rb keeps these equal to
// the Ruby registry and runs the shared revision cases on both sides.
export const EXPECTED_PROVIDER_IDS = {
  'gpt-6-luna': ['gpt-6-luna'],
  'gpt-6.1-sol': ['gpt-6.1-sol'],
  'mistral-small': ['mistral-small', 'mistral-small-2603'],
  'mistral-large-4': ['mistral-large-4'],
  'claude-haiku-5-5': ['claude-haiku-5-5', 'eu.anthropic.claude-haiku-5-5'],
  'claude-sonnet-5-5': ['claude-sonnet-5-5', 'eu.anthropic.claude-sonnet-5-5'],
  'claude-opus-5-5': ['claude-opus-5-5', 'eu.anthropic.claude-opus-5-5']
}
export const AZURE_DEPLOYMENT_NAMES = ['gpt-6-luna', 'gpt-6.1-sol']
const PROVIDER_MODEL_LIMIT = 160
const SAFE_PROVIDER_MODEL = /^[A-Za-z0-9][A-Za-z0-9._:-]*$/
const HOSTNAME_SUFFIX = /\.(com|net|org|io|ai|co|cloud|dev|local|internal)$/i

export function validModelVersion(model, version) {
  if (version === null) return true
  if (typeof version !== 'string' || version === '' || version.trim() !== version) return false
  if (version.length > PROVIDER_MODEL_LIMIT || !SAFE_PROVIDER_MODEL.test(version)) return false
  if (HOSTNAME_SUFFIX.test(version) || AZURE_DEPLOYMENT_NAMES.includes(version)) return false
  const expected = Object.hasOwn(EXPECTED_PROVIDER_IDS, model) ? EXPECTED_PROVIDER_IDS[model] : []
  return expected.some(id => version === id || ['-', '.', ':', '_'].some(separator => version.startsWith(`${id}${separator}`)))
}

// The validated, detached record, or null. The rules are the server's:
// exact keys at every level, enums and allowlists, a model named only by a
// generated outcome whose attempt was dispatched, answered and valid.
export function normalizeAnswerMeta(candidate) {
  let text
  try {
    text = JSON.stringify(candidate)
  } catch {
    return null
  }
  if (typeof text !== 'string' || text.length > MAX_BYTES) return null
  const meta = JSON.parse(text)
  if (!exactKeys(meta, KEYS.top) || meta.v !== 1 || !SOURCES.includes(meta.source)) return null
  const { requested, attempt, outcome, guard } = meta
  if (!exactKeys(requested, KEYS.requested) || !oneOf(requested.category, CATEGORIES) ||
      !oneOf(requested.intelligence, INTELLIGENCES) || !oneOf(requested.model, MODEL_IDS) ||
      !oneOf(requested.research_depth, DEPTHS) || !oneOf(requested.reasoning_effort, EFFORTS) ||
      !flag(requested.linked_research)) return null
  if (attempt !== null && (!exactKeys(attempt, KEYS.attempt) || !oneOf(attempt.model, MODEL_IDS) ||
      !flag(attempt.dispatched) || !oneOf(attempt.response, RESPONSES) || !oneOf(attempt.generation, GENERATIONS) ||
      !(attempt.calls_started === null || (Number.isInteger(attempt.calls_started) && attempt.calls_started >= 0 &&
        attempt.calls_started <= 4)) || (attempt.model !== null && attempt.dispatched !== true))) return null
  if (!oneOf(guard, GUARDS)) return null
  if (!exactKeys(outcome, KEYS.outcome) || !STATUSES.includes(outcome.status) || !oneOf(outcome.category, CATEGORIES) ||
      !oneOf(outcome.research_depth, DEPTHS) || !oneOf(outcome.reasoning_effort, EFFORTS) ||
      !oneOf(outcome.translation, TRANSLATIONS)) return null
  if (outcome.status === 'generated') {
    if (typeof outcome.model !== 'string' || !MODEL_IDS.includes(outcome.model)) return null
    if (guard !== 'analysis' || !isObject(attempt) || attempt.dispatched !== true || attempt.response !== 'received' ||
        attempt.generation !== 'valid' || attempt.model !== outcome.model) return null
    if (!validModelVersion(outcome.model, outcome.model_version)) return null
  } else if (outcome.model !== null || outcome.model_version !== null) {
    return null
  }
  return meta
}

// The server's record of an answer (result.answer_meta), validated and
// detached, or null.
export function answerMetaOf(data) {
  return normalizeAnswerMeta(data?.answer_meta)
}

// A legacy deep-analysis turn's stored model id, kept only when it is a
// plain id.
export function safeDeepModel(value) {
  return typeof value === 'string' && SAFE_ID.test(value) ? value : null
}

// What the browser asked for, from the ask payload it sent, each value kept
// only when it is in its allowlist.
export function requestedFromPayload(payload) {
  const pick = (value, list) => (typeof value === 'string' && list.includes(value) ? value : null)
  return {
    category: pick(payload?.profile, CATEGORIES),
    intelligence: pick(payload?.intelligence, INTELLIGENCES),
    model: pick(payload?.model_override, MODEL_IDS),
    research_depth: pick(payload?.research_depth, DEPTHS),
    reasoning_effort: pick(payload?.reasoning_effort, EFFORTS),
    linked_research: payload?.linked_research === true ? true : null
  }
}

// The record of a question that ended without an answer. The server's
// provenance decides when its event carried one (including its explicit
// "not_started" for an ask refused before the answer service existed); the
// browser's own deadline gives "timeout"; anything else, a dropped
// connection, a cut stream or a body that did not parse, is "unknown": no
// progress event is no proof that nothing ran.
export function errorTurnMeta({ requested, provenance, timedOut = false }) {
  const cleanRequested = requested && exactKeys(requested, KEYS.requested) ? { ...requested } : requestedFromPayload(null)
  const outcome = { status: timedOut ? 'timeout' : 'unknown', model: null, model_version: null, category: null,
                    research_depth: null, reasoning_effort: null, translation: null }
  const fallback = { v: 1, source: 'live', requested: cleanRequested, attempt: null, guard: null, outcome }
  if (isObject(provenance)) {
    const fromServer = normalizeAnswerMeta({ v: 1, source: 'live', requested: cleanRequested,
                                             attempt: provenance.attempt ?? null, guard: provenance.guard ?? null,
                                             outcome: provenance.outcome })
    if (fromServer) return fromServer
  }
  return normalizeAnswerMeta(fallback) || fallback
}

function copyFor(language) {
  return COPY[language] || COPY.nl
}

// Only allowlisted ids and labels are ever printed; the validator already
// refused anything else, and the formatter does not trust that either.
function modelName(id) {
  return typeof id === 'string' && Object.hasOwn(MODEL_NAMES, id) ? MODEL_NAMES[id] : null
}

function named(map, language, value) {
  const labels = map[language] || map.nl
  return typeof value === 'string' && Object.hasOwn(labels, value) ? labels[value] : null
}

// "known value", else "requested value (gevraagd)", else "niet vastgelegd".
function knownOrRequested(copy, known, requested) {
  if (known) return known
  if (requested) return `${requested} (${copy.requested})`
  return copy.notRecorded
}

function attemptNote(copy, attempt) {
  if (!isObject(attempt)) return null
  if (attempt.dispatched === true) return `${copy.lastAttempt}: ${copy.sent}`
  if (attempt.dispatched === false) return `${copy.lastAttempt}: ${copy.notSent}`
  return `${copy.lastAttempt}: ${copy.unknown}`
}

function modelText(copy, meta) {
  const outcome = meta.outcome
  if (outcome.status === 'generated') {
    const name = modelName(outcome.model) || copy.unknown
    const version = typeof outcome.model_version === 'string' && SAFE_ID.test(outcome.model_version)
      ? ` (${copy.version}: ${outcome.model_version})` : ''
    const translation = { translated: copy.translated, mapped: copy.mapped, french_fallback: copy.frenchFallback }[outcome.translation]
    return `${name}${version}${translation ? `, ${translation}` : ''}`
  }
  const notes = []
  const requestedModel = modelName(meta.requested?.model)
  if (requestedModel) notes.push(`${copy.requested}: ${requestedModel}`)
  const attempt = attemptNote(copy, meta.attempt)
  if (attempt) notes.push(attempt)
  const status = copy.status[outcome.status] || copy.status.unknown
  return notes.length ? `${status} (${notes.join('; ')})` : status
}

// The line every export prints under an answer, from what the history holds
// for it: { meta } for an answer of this release, { deep_model } for a legacy
// deep-analysis turn, or nothing. The record is validated again here: an
// invalid one prints as not recorded.
export function answerMetaLine(item, language = 'nl') {
  const copy = copyFor(language)
  const meta = normalizeAnswerMeta(item?.meta)
  if (!meta) {
    const deepModel = safeDeepModel(item?.deep_model)
    if (deepModel) {
      return `${copy.category}: ${copy.notRecorded} | ${copy.model}: ${modelName(deepModel) || deepModel} (${copy.historical})` +
        ` | ${copy.depth}: ${copy.notRecorded} | ${copy.effort}: ${copy.notRecorded}`
    }
    return `${copy.category}: ${copy.notRecorded} | ${copy.model}: ${copy.notRecorded}` +
      ` | ${copy.depth}: ${copy.notRecorded} | ${copy.effort}: ${copy.notRecorded}`
  }
  const outcome = meta.outcome
  const requested = meta.requested
  const category = knownOrRequested(copy, named(CATEGORY_NAMES, language, outcome.category),
                                    named(CATEGORY_NAMES, language, requested.category))
  const depth = knownOrRequested(copy, named(DEPTH_NAMES, language, outcome.research_depth),
                                 named(DEPTH_NAMES, language, requested.research_depth))
  const effort = knownOrRequested(copy, named(EFFORT_NAMES, language, outcome.reasoning_effort),
                                  named(EFFORT_NAMES, language, requested.reasoning_effort))
  const imported = meta.source === 'imported' ? ` (${copy.imported})` : ''
  return `${copy.category}: ${category} | ${copy.model}: ${modelText(copy, meta)}${imported}` +
    ` | ${copy.depth}: ${depth} | ${copy.effort}: ${effort}`
}

// A restored, decrypted or imported history message: a record that does not
// validate and a deep_model that is not a plain id are dropped; the message
// itself is kept.
export function sanitizeMessageMeta(message) {
  if (!isObject(message)) return message
  if (!('meta' in message) && !('deep_model' in message)) return message
  const { meta, deep_model: deepModel, ...rest } = message
  const cleanMeta = 'meta' in message ? normalizeAnswerMeta(meta) : null
  const cleanDeepModel = 'deep_model' in message ? safeDeepModel(deepModel) : null
  return {
    ...rest,
    ...(cleanMeta ? { meta: cleanMeta } : {}),
    ...(cleanDeepModel ? { deep_model: cleanDeepModel } : {})
  }
}
