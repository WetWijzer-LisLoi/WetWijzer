// Pure decision core of the chatbot send() transport (FBL-062, extracted
// verbatim): ask-payload assembly with its conditional zero-knowledge keys,
// the request-deadline state machine, the JSON error-path resolver (which
// shares the login/conflict copy with the SSE path) and the localized
// transport copy. The controller keeps fetch, abort wiring and all DOM.
// Pinned by test/javascript/chatbot_send_request_test.mjs.
import { isProviderReasoningPayload } from './chatbot_message_safety.js'
import { sseErrorMessage, withChargeNotice } from './chatbot_stream_events.js'
import { answerMetaOf } from './answer_meta.js'

// Assemble the POST /api/chatbot/ask body. The conditional keys are the
// contract: key_generation only when the ZK key is unlocked, and
// conversation_revision only for a conversation known to be zero-knowledge
// (a plaintext conversation must not send a revision).
export function buildAskPayload({
  question, language, source, sources, intelligence, reasoningEffort, researchDepth, linkedResearch,
  modelOverride, profile, lawNumac, lawHistory, conversationId, zkReady, zkKeyGeneration,
  zkConversation, conversationRevision, contextMessages
}) {
  return {
    question,
    language,
    source,
    sources,
    intelligence,
    reasoning_effort: reasoningEffort,
    ...(researchDepth ? { research_depth: researchDepth } : {}),
    ...(linkedResearch === true ? { linked_research: true } : {}),
    model_override: modelOverride || null,
    profile,
    law_numac: lawNumac || null,
    // The article-history pilot's reader context (local only), sent only when the law page shows a date.
    ...(lawHistory?.asOf ? { law_article: lawHistory.article || null, law_as_of: lawHistory.asOf,
                             law_language: lawHistory.language || null } : {}),
    conversation_id: conversationId,
    ...(zkReady ? { key_generation: zkKeyGeneration } : {}),
    ...(conversationId && zkConversation ? { conversation_revision: conversationRevision ?? null } : {}),
    context_messages: contextMessages,
    stream: true
  }
}

// A German answer on gesetzguide arrives with context_content: the French
// answer it was translated from (or shown under a note). The server reasons
// in French, so the next question's context must give it that French text,
// not the translation the reader saw; the server's history replay puts it
// in place of the German turn. Answers everywhere else carry no such field.
function contextContentOf(message) {
  const text = message?.context_content
  if (typeof text !== 'string' || text.trim() === '') return null
  // The same boundary as a shown answer: provider reasoning is never kept.
  return isProviderReasoningPayload(text) ? null : text
}

// The assistant turn the browser keeps in conversationHistory (and in the
// encrypted snapshot): the answer shown, its analytic id, the French answer
// it was made from when there is one, and the server's metadata record of
// the answer (answer_meta) when the result carries one. The record never
// goes into the follow-up context (contextMessagesFrom).
export function assistantHistoryEntry(data, analyticId) {
  const entry = { role: 'assistant', content: data.answer, analytic_id: analyticId }
  const context = contextContentOf(data)
  if (context) entry.context_content = context
  const meta = answerMetaOf(data)
  if (meta) entry.meta = meta
  return entry
}

// German answers v3: on gesetzguide a German question is translated into
// French before the server answers it, and the result carries that French
// question as question_context_content. It goes on the reader's own user
// turn (the last entry, still the question as typed) as context_content, so
// the next ask gives the server a French history, as lisloi's is. Nothing
// is shown: the turn's content stays the question the reader typed. Any
// other result carries no such field and leaves the history as it is.
export function attachQuestionContext(history, question, data) {
  const context = contextContentOf({ context_content: data?.question_context_content })
  if (!context || !Array.isArray(history) || history.length === 0) return
  const turn = history[history.length - 1]
  if (turn?.role !== 'user' || turn.content !== question) return
  turn.context_content = context
}

// context_messages for the next ask: the last six turns, role and content,
// plus a turn's context_content (the French answer of a German answer, or
// the French question of a German question).
export function contextMessagesFrom(history) {
  return (Array.isArray(history) ? history : []).slice(-6).map(message => {
    const turn = { role: message.role, content: message.content }
    const context = contextContentOf(message)
    if (context) turn.context_content = context
    return turn
  })
}

// One re-armable deadline per request: armed pre-header from the browser
// fallback, re-armed once headers advertise the server supervisor. Firing
// marks the state and aborts; clearing (on a terminal event) stops it.
export function createRequestDeadline({ onTimeout, setTimer = setTimeout, clearTimer = clearTimeout }) {
  let timeoutId
  return {
    arm(timeoutMs) {
      clearTimer(timeoutId)
      timeoutId = setTimer(onTimeout, timeoutMs)
    },
    clear() {
      clearTimer(timeoutId)
    }
  }
}

const LOGIN_REQUIRED_MESSAGES = {
  nl: `Authenticatie vereist. [Log in](/login?redirect_to=/chatbot) of [maak een gratis account aan](/signup).`,
  fr: `Authentification requise. [Connectez-vous](/login?redirect_to=/chatbot) ou [créez un compte gratuit](/signup).`,
  de: `Authentifizierung erforderlich. [Anmelden](/login?redirect_to=/chatbot) oder [kostenloses Konto erstellen](/signup).`,
  en: `Authentication required. [Log in](/login?redirect_to=/chatbot) or [create a free account](/signup).`
}

const ZK_CONFLICT_MESSAGES = {
  nl: 'De beveiligde gespreksstatus is gewijzigd of nog in gebruik. Herlaad het gesprek en probeer opnieuw.',
  fr: "L'état sécurisé de la conversation a changé ou est encore utilisé. Rechargez-la et réessayez.",
  de: 'Der sichere Gesprächsstatus hat sich geändert oder wird noch verwendet. Laden Sie das Gespräch neu.',
  en: 'The secure conversation state changed or is still in use. Reload it and try again.'
}

// The server's budget codes (render_chatbot_budget_limit); the stream path
// maps them to one capacity sentence that names no model or provider.
const BUDGET_CODES = new Set(['model_daily_cap', 'provider_monthly_cap', 'provider_budget_unavailable'])

// The site's own request limits answer 429 with code 'rate_limited', the
// window in seconds (60 for the minute limit, 3600 for the hour) and when it
// ends (config/initializers/rack_attack.rb). The request never reached the
// chatbot, so nothing was charged. Sol 2026-11-24 23:55:37Z (#1337): the real
// reset time, in the reader's language, worded apart from a credit or a model
// budget refusal.
// Sol 2026-11-25 02:51:39Z: "per hour" only for the hour's window, a neutral
// lead for any longer one (none reaches the chatbot today: the minute, the
// five minutes and the hour do, test/integration/rate_limiting_test.rb), and
// "1 seconde" in the singular.
const RATE_LIMITED = {
  nl: { hour: 'U hebt het maximum aantal vragen per uur bereikt.', burst: 'U hebt te veel vragen kort na elkaar gesteld.',
    longer: 'U hebt het maximum aantal vragen voor deze periode bereikt.',
    from: 'Vanaf {time} kunt u opnieuw vragen stellen.', retry: 'Probeer het over {wait} opnieuw.',
    second: 'seconde', seconds: 'seconden', minutes: 'minuten', free: 'Deze vraag is niet aangerekend.' },
  fr: { hour: 'Vous avez atteint le nombre maximal de questions par heure.', burst: 'Vous avez posé trop de questions en peu de temps.',
    longer: 'Vous avez atteint le nombre maximal de questions pour cette période.',
    from: 'Vous pourrez en poser de nouveau à partir de {time}.', retry: 'Réessayez dans {wait}.',
    second: 'seconde', seconds: 'secondes', minutes: 'minutes', free: 'Cette question ne vous a pas été facturée.' },
  de: { hour: 'Sie haben die Höchstzahl an Fragen pro Stunde erreicht.', burst: 'Sie haben zu viele Fragen kurz hintereinander gestellt.',
    longer: 'Sie haben die Höchstzahl an Fragen für diesen Zeitraum erreicht.',
    from: 'Ab {time} Uhr können Sie wieder Fragen stellen.', retry: 'Versuchen Sie es in {wait} erneut.',
    second: 'Sekunde', seconds: 'Sekunden', minutes: 'Minuten', free: 'Diese Frage wurde nicht berechnet.' },
  en: { hour: 'You have reached the maximum number of questions per hour.', burst: 'You have asked too many questions in a short time.',
    longer: 'You have reached the maximum number of questions for this period.',
    from: 'You can ask again from {time}.', retry: 'Please try again in {wait}.',
    second: 'second', seconds: 'seconds', minutes: 'minutes', free: 'This question was not charged.' }
}
const TIME_LOCALES = { nl: 'nl-BE', fr: 'fr-BE', de: 'de-BE', en: 'en-GB' }
const HOUR = 3600

// The sentence for a 'rate_limited' body, or null when the body names neither
// a valid reset nor a wait (the server's own text then stays).
function rateLimitedMessage(data, lang) {
  const words = RATE_LIMITED[lang] || RATE_LIMITED.nl
  const period = Number(data.period)
  const resetAt = new Date(data.reset_at)
  let when = null
  if (period === HOUR && typeof data.reset_at === 'string' && !Number.isNaN(resetAt.getTime())) {
    const time = resetAt.toLocaleTimeString(TIME_LOCALES[lang] || 'nl-BE', { hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Brussels' })
    when = words.from.replace('{time}', time)
  } else {
    const seconds = Math.ceil(Number(data.retry_after))
    if (Number.isFinite(seconds) && seconds > 0) {
      const wait = seconds === 1 ? `1 ${words.second}`
        : seconds < 120 ? `${seconds} ${words.seconds}` : `${Math.ceil(seconds / 60)} ${words.minutes}`
      when = words.retry.replace('{wait}', wait)
    }
  }
  if (!when) return null
  const lead = period === HOUR ? words.hour : period > HOUR ? words.longer : words.burst
  return `${lead} ${when} ${words.free}`
}

const UPSELL_HEADER = { nl: '🔓 Blijf juridische vragen stellen:', fr: '🔓 Continuez à poser des questions juridiques :', de: '🔓 Stellen Sie weiterhin juristische Fragen:', en: '🔓 Keep asking legal questions:' }
const UPSELL_BUY_LABEL = { nl: '💳 Credits Kopen', fr: '💳 Acheter des Crédits', de: '💳 Credits Kaufen', en: '💳 Buy Credits' }
const UPSELL_PRO_LABEL = { nl: '⚡ Ontdek Praxis Pro', fr: '⚡ Découvrez Praxis Pro', de: '⚡ Entdecken Sie Praxis Pro', en: '⚡ Discover Praxis Pro' }
const UPSELL_PRO_DESC = { nl: 'Onbeperkt vragen met Praxis', fr: 'Questions illimitées avec Praxis', de: 'Unbegrenzte Fragen mit Praxis', en: 'Unlimited questions with Praxis' }

// Resolve the non-stream (JSON) error path into a render descriptor:
// { message } always; { upsell } additionally on 402 so the controller can
// build the buy-credits card without owning any copy. A body that reports a
// retained charge (charge_notice, sent once by the server) shows it under
// the sentence, exactly as the stream path does; the branches that cannot
// follow a paid request (rate limit, login) append nothing.
export function jsonErrorDescriptor(status, data, language) {
  const lang = language || 'nl'
  if (status === 409 && data.error === 'zero_knowledge_state_conflict') {
    return { message: withChargeNotice(ZK_CONFLICT_MESSAGES[language] || ZK_CONFLICT_MESSAGES.nl, data, lang) }
  }
  if (status === 429) {
    // A budget stop is a machine code, and it can follow a paid request
    // (the embedding was sent, then the generation's budget was refused):
    // the stream's capacity sentence, with the charge notice when there is
    // one. An ordinary rate limit keeps its text and retry hint.
    if (BUDGET_CODES.has(data.error)) return { message: sseErrorMessage(data, lang) }
    const limited = data.code === 'rate_limited' ? rateLimitedMessage(data, lang) : null
    if (limited) return { message: limited }
    const retryAfter = data.retry_after ? ` (${Math.ceil(data.retry_after / 60)} min)` : ""
    return { message: withChargeNotice(data.error + retryAfter, data, lang) }
  }
  if (status === 401 && data.login_required) {
    return { message: LOGIN_REQUIRED_MESSAGES[language] || LOGIN_REQUIRED_MESSAGES.nl }
  }
  if (status === 403 && data.error === 'account_inactive') {
    // The account fence is a machine code in JSON too: the stream sentence,
    // with the charge notice or the truthful "nothing charged" suffix.
    return { message: sseErrorMessage(data, lang) }
  }
  if (status === 402) {
    return {
      message: withChargeNotice(data.error, data, lang),
      upsell: {
        buyUrl: data.buy_credits_url || '/pricing',
        praxisUrl: data.praxis_url || 'https://praxislegal.be',
        header: UPSELL_HEADER[lang] || UPSELL_HEADER.nl,
        buyLabel: UPSELL_BUY_LABEL[lang] || UPSELL_BUY_LABEL.nl,
        proLabel: UPSELL_PRO_LABEL[lang] || UPSELL_PRO_LABEL.nl,
        // Verbatim quirk: unlike the labels, the description historically had
        // NO nl fallback - an unknown language renders it empty.
        proDesc: data.praxis_upsell || UPSELL_PRO_DESC[language]
      }
    }
  }
  return { message: withChargeNotice(data.error, data, lang) }
}

const SEND_MESSAGES = {
  zk_unlock_first: {
    nl: 'Ontgrendel eerst uw beveiligde geschiedenis.',
    fr: "Déverrouillez d'abord votre historique sécurisé.",
    de: 'Entsperren Sie zuerst Ihren sicheren Verlauf.',
    en: 'Unlock your secure history first.'
  },
  zk_retry_save_first: {
    nl: 'Sla eerst het vorige beveiligde antwoord opnieuw op of herlaad het gesprek.',
    fr: "Enregistrez d'abord à nouveau la réponse sécurisée précédente ou rechargez la conversation.",
    de: 'Speichern Sie zuerst die vorherige sichere Antwort erneut oder laden Sie das Gespräch neu.',
    en: 'Save the previous secure answer again or reload the conversation first.'
  },
  mistral_followup_downgrade: {
    nl: 'Mistral diepgaand redeneren is alleen beschikbaar voor de eerste vraag; deze vervolgvraag gebruikt Snel.',
    fr: 'Le raisonnement approfondi de Mistral est réservé à la première question ; cette question de suivi utilise Rapide.',
    de: 'Mistral-Tiefdenken ist nur für die erste Frage verfügbar; diese Folgefrage nutzt Schnell.',
    en: 'Mistral deep reasoning is available only for the first question; this follow-up uses Fast.'
  },
  protocol_state_changed: {
    nl: 'De beveiligde gespreksstatus is gewijzigd. Herlaad het gesprek.',
    fr: "L'état sécurisé de la conversation a changé. Rechargez la conversation.",
    de: 'Der sichere Gesprächsstatus hat sich geändert. Laden Sie das Gespräch neu.',
    en: 'The secure conversation state changed. Reload the conversation.'
  },
  encrypted_save_failed: {
    nl: 'De beveiligde gespreksgeschiedenis kon niet worden opgeslagen. Probeer het opnieuw.',
    fr: "L'historique sécurisé n'a pas pu être enregistré. Veuillez réessayer.",
    de: 'Der sichere Gesprächsverlauf konnte nicht gespeichert werden. Bitte versuchen Sie es erneut.',
    en: 'Secure conversation history could not be saved. Please try again.'
  },
  request_timed_out: {
    nl: "Verzoek verlopen. De server reageert te traag. Probeer opnieuw.",
    fr: "La requête a expiré. Le serveur met trop de temps à répondre. Réessayez.",
    de: "Zeitüberschreitung. Der Server antwortet zu langsam. Versuchen Sie es erneut.",
    en: "Request timed out. The server is responding too slowly. Please try again."
  },
  connection_error: {
    nl: "Verbindingsfout. Probeer opnieuw.",
    fr: "Erreur de connexion. Veuillez réessayer.",
    de: "Verbindungsfehler. Bitte versuchen Sie es erneut.",
    en: "Connection error. Please try again."
  }
}

export function sendMessage(key, language) {
  const table = SEND_MESSAGES[key]
  if (!table) throw new Error(`unknown send message key: ${key}`)
  return table[language] || table.nl
}

// The historical mistral-downgrade toast used a SHORTER nl fallback for
// unknown languages than its nl entry; preserved verbatim.
export function mistralFollowupDowngradeMessage(language) {
  return SEND_MESSAGES.mistral_followup_downgrade[language] || 'Deze vervolgvraag gebruikt Snel.'
}
