const SERIALIZED_CONTAINER_PREFIX = /^\s*(?:```(?:json|ruby|text)?\s*)?(?:[\[{]|#<)/i
const TYPED_THINKING_FIELD = /(?:["']?type["']?|:type)\s*(?:=>|:)\s*(?:["']thinking["']|:thinking\b)/i
const THINK_CHUNK_MARKER = /(?:#<[^>\n]*\bThinkChunk\b|\bThinkChunk\s*\()/i

export function isProviderReasoningPayload(content) {
  const text = String(content ?? '')
  if (!SERIALIZED_CONTAINER_PREFIX.test(text)) return false

  return TYPED_THINKING_FIELD.test(text) || THINK_CHUNK_MARKER.test(text)
}

export function isLegacyReasoningPayload(content) {
  return isProviderReasoningPayload(content)
}

export function legacyReasoningHiddenMessage(language = 'nl') {
  return {
    nl: 'Dit oudere antwoord is verborgen omdat het interne modelredenering kon bevatten. Stel de vraag opnieuw.',
    fr: 'Cette ancienne réponse a été masquée car elle pouvait contenir le raisonnement interne du modèle. Veuillez poser à nouveau la question.',
    de: 'Diese ältere Antwort wurde ausgeblendet, weil sie interne Modellüberlegungen enthalten konnte. Bitte stellen Sie die Frage erneut.',
    en: 'This older answer was hidden because it could contain internal model reasoning. Please ask the question again.'
  }[language] || 'This older answer was hidden because it could contain internal model reasoning. Please ask the question again.'
}

export function blockedVisibleAnswerMessage(language = 'nl') {
  return {
    nl: 'Het gegenereerde antwoord is geblokkeerd omdat het interne modelredenering bevatte. Het onveilige antwoord is niet opgeslagen. Probeer opnieuw.',
    fr: "La réponse générée a été bloquée car elle contenait un raisonnement interne du modèle. La réponse non sûre n'a pas été enregistrée. Veuillez réessayer.",
    de: 'Die generierte Antwort wurde blockiert, weil sie interne Modellüberlegungen enthielt. Die unsichere Antwort wurde nicht gespeichert. Bitte versuchen Sie es erneut.',
    en: 'The generated answer was blocked because it contained internal model reasoning. The unsafe answer was not saved. Please try again.'
  }[language] || 'The generated answer was blocked because it contained internal model reasoning. The unsafe answer was not saved. Please try again.'
}

export function sanitizeVisibleAssistantAnswer(content, language = 'nl') {
  if (!isProviderReasoningPayload(content)) return { content, blocked: false }

  return {
    content: blockedVisibleAnswerMessage(language),
    blocked: true,
    errorCode: 'provider_reasoning_blocked'
  }
}

export function sanitizeRestoredMessages(messages, language = 'nl') {
  return Array.isArray(messages) ? messages.map(message => {
    if (message?.role !== 'assistant' || !isLegacyReasoningPayload(message.content)) return message

    return {
      ...message,
      content: legacyReasoningHiddenMessage(language),
      legacy_reasoning_hidden: true
    }
  }) : []
}
