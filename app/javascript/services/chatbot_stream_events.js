// Pure decision core of the chatbot SSE stream (FBL-062, extracted verbatim
// from _handleSSEResponse): frame parsing with chunk-boundary buffering, the
// localized transport/error copy, the heartbeat progress clamp and the
// terminal-error message choice. The controller keeps the reader loop and
// every side effect. Pinned by test/javascript/chatbot_stream_events_test.mjs.

// Accumulate a decoded chunk onto the carry buffer and split out complete
// SSE frames ("data: {...}\n\n"). The incomplete tail stays in the buffer -
// an event split across two network chunks must survive the boundary.
// Frames without a data: line and frames with malformed JSON are skipped,
// exactly as the inline parser always did.
export function parseSseChunk(buffer, chunkText) {
  const frames = (buffer + chunkText).split("\n\n")
  const rest = frames.pop()
  const events = []
  for (const frame of frames) {
    const dataMatch = frame.match(/^data:\s*(.+)$/m)
    if (!dataMatch) continue
    try {
      events.push(JSON.parse(dataMatch[1]))
    } catch {
      // skip malformed frame
    }
  }
  return { buffer: rest, events }
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

const BAD_REQUEST_MESSAGES = {
  nl: 'Uw verzoek kon niet worden verwerkt. Pas uw vraag aan en probeer opnieuw.',
  fr: "Votre demande n'a pas pu être traitée. Ajustez votre question et réessayez.",
  de: 'Ihre Anfrage konnte nicht verarbeitet werden. Passen Sie Ihre Frage an und versuchen Sie es erneut.',
  en: 'Your request could not be processed. Adjust your question and try again.'
}

// Every browser request streams, so the server's refusals arrive as bare
// machine codes on an open stream and never reach the localized JSON 402/429
// copy. Without these tables a free account that had spent its starter
// credits got a red bubble reading "insufficient_credits" in all four
// languages. Wording follows config/locales (chatbot.insufficient_credits,
// chatbot.capacity_limit) and services/chatbot_locked_tier.js.
const INSUFFICIENT_CREDITS_COPY = {
  nl: { head: 'Onvoldoende credits.', detail: (cost, balance) => `Deze vraag kost ${cost}, u heeft ${balance}.`, buy: 'Credits kopen', units: ['credit', 'credits'] },
  fr: { head: 'Crédits insuffisants.', detail: (cost, balance) => `Cette question coûte ${cost}, vous avez ${balance}.`, buy: 'Acheter des crédits', units: ['crédit', 'crédits'] },
  de: { head: 'Unzureichende Credits.', detail: (cost, balance) => `Diese Frage kostet ${cost}, Sie haben ${balance}.`, buy: 'Credits kaufen', units: ['Credit', 'Credits'] },
  en: { head: 'Insufficient credits.', detail: (cost, balance) => `This question costs ${cost}, you have ${balance}.`, buy: 'Buy credits', units: ['credit', 'credits'] }
}

const SSE_CODE_MESSAGES = {
  upgrade_required: {
    nl: 'Dit niveau hoort bij WetWijzer Pro. [Bekijk WetWijzer Pro](/pricing)',
    fr: 'Ce niveau fait partie de WetWijzer Pro. [Découvrir WetWijzer Pro](/pricing)',
    de: 'Diese Stufe gehört zu WetWijzer Pro. [WetWijzer Pro ansehen](/pricing)',
    en: 'This level is part of WetWijzer Pro. [See WetWijzer Pro](/pricing)'
  },
  // tier "purchased": a credit purchase unlocks it too, as the send-time
  // dialog says. Calling it Pro-only here would contradict that dialog.
  upgrade_required_purchased: {
    nl: 'Dit niveau werkt met credits of met WetWijzer Pro. [Credits kopen](/credits) of [bekijk WetWijzer Pro](/pricing).',
    fr: 'Ce niveau fonctionne avec des crédits ou avec WetWijzer Pro. [Acheter des crédits](/credits) ou [découvrir WetWijzer Pro](/pricing).',
    de: 'Diese Stufe funktioniert mit Credits oder mit WetWijzer Pro. [Credits kaufen](/credits) oder [WetWijzer Pro ansehen](/pricing).',
    en: 'This level runs on credits or on WetWijzer Pro. [Buy credits](/credits) or [see WetWijzer Pro](/pricing).'
  },
  capacity_limit: {
    nl: 'De chatbot heeft tijdelijk zijn capaciteitslimiet bereikt. Probeer het later opnieuw.',
    fr: 'Le chatbot a temporairement atteint sa limite de capacité. Veuillez réessayer plus tard.',
    de: 'Der Chatbot hat vorübergehend sein Kapazitätslimit erreicht. Bitte versuchen Sie es später erneut.',
    en: 'The chatbot has temporarily reached its capacity limit. Please try again later.'
  },
  billing_reconciliation_unavailable: {
    nl: 'Uw creditsaldo kon niet worden gecontroleerd. Er is niets aangerekend. Probeer het over enkele ogenblikken opnieuw.',
    fr: "Votre solde de crédits n'a pas pu être vérifié. Rien n'a été débité. Réessayez dans quelques instants.",
    de: 'Ihr Credit-Guthaben konnte nicht geprüft werden. Es wurde nichts abgebucht. Versuchen Sie es in wenigen Augenblicken erneut.',
    en: 'Your credit balance could not be checked. Nothing was charged. Please try again in a moment.'
  },
  // "Nothing was charged" holds only while no paid AI request was sent; a
  // fence after one keeps the question's single charge (owner policy
  // 2026-10-18) and the server then sends charge_notice instead.
  account_inactive: {
    nl: 'Dit account is niet meer actief.',
    fr: "Ce compte n'est plus actif.",
    de: 'Dieses Konto ist nicht mehr aktiv.',
    en: 'This account is no longer active.'
  },
  generic: {
    nl: 'Er is een fout opgetreden. Probeer opnieuw.',
    fr: "Une erreur s'est produite. Veuillez réessayer.",
    de: 'Ein Fehler ist aufgetreten. Bitte versuchen Sie es erneut.',
    en: 'An error occurred. Please try again.'
  }
}

const NOTHING_CHARGED = {
  nl: 'Er is niets aangerekend.',
  fr: "Rien n'a été débité.",
  de: 'Es wurde nichts abgebucht.',
  en: 'Nothing was charged.'
}

// A code-only error event or body says in its own words whether this
// question's credits came back. The server states a retained charge in
// `charge_notice`, already localized, exactly once; it is appended as sent.
// Without it, a code that used to promise "nothing was charged" (a fence
// after the model ran) still does, truthfully, when the payload reports no
// deduction.
export function withChargeNotice(message, parsed, language) {
  const lang = language || 'nl'
  const notice = typeof parsed?.charge_notice === 'string' ? parsed.charge_notice.trim() : ''
  if (notice) return `${message}\n\n${notice}`
  if (parsed?.error === 'account_inactive' && !(parsed.credits_info && parsed.credits_info.credits_deducted > 0)) {
    return `${message} ${NOTHING_CHARGED[lang] || NOTHING_CHARGED.nl}`
  }
  return message
}

// The three budget codes share one sentence: which cap tripped is an
// operator detail, and the copy never names models or providers.
const SSE_CODE_ALIASES = {
  model_daily_cap: 'capacity_limit',
  provider_monthly_cap: 'capacity_limit',
  provider_budget_unavailable: 'capacity_limit'
}

// "1 credits" reads as a bug; French also takes the singular for 0.
function creditAmount(count, units, language) {
  const singular = language === 'fr' ? count < 2 : count === 1
  return `${count} ${singular ? units[0] : units[1]}`
}

function insufficientCreditsMessage(parsed, language) {
  const lang = INSUFFICIENT_CREDITS_COPY[language] ? language : 'nl'
  const copy = INSUFFICIENT_CREDITS_COPY[lang]
  const cost = Number(parsed.credits_required)
  const balance = Number(parsed.credits_available)
  const known = parsed.credits_required != null && parsed.credits_available != null &&
    Number.isFinite(cost) && Number.isFinite(balance)
  const detail = known ? ` ${copy.detail(creditAmount(cost, copy.units, lang), creditAmount(balance, copy.units, lang))}` : ''
  // /credits is where the composer's own "insufficient credits" warning links.
  return `${copy.head}${detail} [${copy.buy}](/credits)`
}

const HEARTBEAT_LABELS = { nl: "AI denkt na", fr: "L'IA réfléchit", de: "KI denkt nach", en: "AI is thinking" }

const INCOMPLETE_MESSAGES = {
  nl: "Het serverantwoord was onvolledig. Probeer opnieuw.",
  fr: "La réponse du serveur était incomplète. Réessayez.",
  de: "Die Serverantwort war unvollständig. Versuchen Sie es erneut.",
  en: "The server response was incomplete. Please try again."
}

const DISCONNECT_MESSAGES = {
  nl: "De verbinding met de server is verbroken.",
  fr: "La connexion au serveur a été interrompue.",
  de: "Die Verbindung zum Server wurde unterbrochen.",
  en: "The connection to the server was interrupted."
}

// Message for a server-side `type: "error"` event.
export function sseErrorMessage(parsed, language) {
  return withChargeNotice(sseErrorSentence(parsed, language), parsed, language)
}

function sseErrorSentence(parsed, language) {
  const lang = language || 'nl'
  if (parsed.error === 'login_required') return LOGIN_REQUIRED_MESSAGES[lang] || LOGIN_REQUIRED_MESSAGES.nl
  if (parsed.error === 'zero_knowledge_state_conflict') return ZK_CONFLICT_MESSAGES[lang] || ZK_CONFLICT_MESSAGES.nl
  if (parsed.error === 'bad_request') return BAD_REQUEST_MESSAGES[lang] || BAD_REQUEST_MESSAGES.nl
  if (parsed.error === 'insufficient_credits') return insufficientCreditsMessage(parsed, lang)
  const code = parsed.error === 'upgrade_required' && parsed.tier === 'purchased'
    ? 'upgrade_required_purchased'
    : (SSE_CODE_ALIASES[parsed.error] || parsed.error)
  const table = Object.prototype.hasOwnProperty.call(SSE_CODE_MESSAGES, code) ? SSE_CODE_MESSAGES[code] : null
  if (table) return table[lang] || table.nl
  // source_requires_pro puts an already localized sentence in `error`, so
  // human text passes through. A bare code we do not know (server_error, or
  // one added later) must never be the bubble text; the server's `message`
  // is Dutch only, so it is not used either.
  if (typeof parsed.error === 'string' && parsed.error && !/^[a-z0-9_]+$/.test(parsed.error)) return parsed.error
  return SSE_CODE_MESSAGES.generic[lang] || SSE_CODE_MESSAGES.generic.nl
}

// Heartbeat: the LLM is still working. The bar creeps with server elapsed
// time but never past 90 - the last stretch belongs to the result event.
// The label carries no "(20s)": updateProgressBar appends the live stopwatch
// to every label, and the server value only moves every 10 s, so the line
// read "AI denkt na... (20s) 27.3s" with two timers that disagreed.
export function heartbeatProgress(elapsedSeconds, language) {
  const elapsed = elapsedSeconds || 0
  const label = HEARTBEAT_LABELS[language] || HEARTBEAT_LABELS.nl
  return { percent: Math.min(90, 60 + elapsed), label: `${label}...` }
}

// A terminal timeout is a normal result payload: the server already refunded
// and supplies a localized explanation in `answer`. Never show the internal
// machine code (`timeout`) in the UI.
export function terminalErrorMessage(data) {
  return data.error === 'timeout' ? (data.answer || data.error) : data.error
}

export function incompleteResponseMessage(language) {
  return INCOMPLETE_MESSAGES[language] || INCOMPLETE_MESSAGES.nl
}

export function disconnectMessage(language) {
  return DISCONNECT_MESSAGES[language] || DISCONNECT_MESSAGES.nl
}
