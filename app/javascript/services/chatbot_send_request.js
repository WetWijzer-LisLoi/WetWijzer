// Pure decision core of the chatbot send() transport (FBL-062, extracted
// verbatim): ask-payload assembly with its conditional zero-knowledge keys,
// the request-deadline state machine, the JSON error-path resolver (which
// shares the login/conflict copy with the SSE path) and the localized
// transport copy. The controller keeps fetch, abort wiring and all DOM.
// Pinned by test/javascript/chatbot_send_request_test.mjs.

// Assemble the POST /api/chatbot/ask body. The conditional keys are the
// contract: key_generation only when the ZK key is unlocked, and
// conversation_revision only for a conversation known to be zero-knowledge
// (a plaintext conversation must not send a revision).
export function buildAskPayload({
  question, language, source, sources, intelligence, reasoningEffort,
  modelOverride, profile, lawNumac, conversationId, zkReady, zkKeyGeneration,
  zkConversation, conversationRevision, contextMessages
}) {
  return {
    question,
    language,
    source,
    sources,
    intelligence,
    reasoning_effort: reasoningEffort,
    model_override: modelOverride || null,
    profile,
    law_numac: lawNumac || null,
    conversation_id: conversationId,
    ...(zkReady ? { key_generation: zkKeyGeneration } : {}),
    ...(conversationId && zkConversation ? { conversation_revision: conversationRevision ?? null } : {}),
    context_messages: contextMessages,
    stream: true
  }
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

const UPSELL_HEADER = { nl: '🔓 Blijf juridische vragen stellen:', fr: '🔓 Continuez à poser des questions juridiques :', de: '🔓 Stellen Sie weiterhin juristische Fragen:', en: '🔓 Keep asking legal questions:' }
const UPSELL_BUY_LABEL = { nl: '💳 Credits Kopen', fr: '💳 Acheter des Crédits', de: '💳 Credits Kaufen', en: '💳 Buy Credits' }
const UPSELL_PRO_LABEL = { nl: '⚡ Ontdek Praxis Pro', fr: '⚡ Découvrez Praxis Pro', de: '⚡ Entdecken Sie Praxis Pro', en: '⚡ Discover Praxis Pro' }
const UPSELL_PRO_DESC = { nl: 'Onbeperkt vragen met Praxis', fr: 'Questions illimitées avec Praxis', de: 'Unbegrenzte Fragen mit Praxis', en: 'Unlimited questions with Praxis' }

// Resolve the non-stream (JSON) error path into a render descriptor:
// { message } always; { upsell } additionally on 402 so the controller can
// build the buy-credits card without owning any copy.
export function jsonErrorDescriptor(status, data, language) {
  const lang = language || 'nl'
  if (status === 409 && data.error === 'zero_knowledge_state_conflict') {
    return { message: ZK_CONFLICT_MESSAGES[language] || ZK_CONFLICT_MESSAGES.nl }
  }
  if (status === 429) {
    const retryAfter = data.retry_after ? ` (${Math.ceil(data.retry_after / 60)} min)` : ""
    return { message: data.error + retryAfter }
  }
  if (status === 401 && data.login_required) {
    return { message: LOGIN_REQUIRED_MESSAGES[language] || LOGIN_REQUIRED_MESSAGES.nl }
  }
  if (status === 402) {
    return {
      message: data.error,
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
  return { message: data.error }
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
