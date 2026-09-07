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
  const lang = language || 'nl'
  if (parsed.error === 'login_required') return LOGIN_REQUIRED_MESSAGES[lang] || LOGIN_REQUIRED_MESSAGES.nl
  if (parsed.error === 'zero_knowledge_state_conflict') return ZK_CONFLICT_MESSAGES[lang] || ZK_CONFLICT_MESSAGES.nl
  if (parsed.error === 'bad_request') return BAD_REQUEST_MESSAGES[lang] || BAD_REQUEST_MESSAGES.nl
  return parsed.error || 'An error occurred.'
}

// Heartbeat: the LLM is still working. The bar creeps with server elapsed
// time but never past 90 - the last stretch belongs to the result event.
export function heartbeatProgress(elapsedSeconds, language) {
  const elapsed = elapsedSeconds || 0
  const label = HEARTBEAT_LABELS[language] || HEARTBEAT_LABELS.nl
  return { percent: Math.min(90, 60 + elapsed), label: `${label}... (${elapsed}s)` }
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
