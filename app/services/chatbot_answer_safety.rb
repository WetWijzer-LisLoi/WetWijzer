# frozen_string_literal: true

# One fail-closed contract for content that may be shown as a chatbot answer or
# written to readable conversation history. Provider reasoning is normally
# removed by each provider adapter; this guard is the final boundary if an SDK
# shape changes or a typed chunk is accidentally stringified upstream.
module ChatbotAnswerSafety
  ERROR_CODE = 'provider_reasoning_blocked'

  class UnsafeProviderReasoningPayload < StandardError; end

  TYPED_THINKING_FIELD =
    /(?:["']?type["']?|:type)\s*(?:=>|:)\s*(?:["']thinking["']|:thinking\b)/i
  THINK_CHUNK_MARKER = /(?:#<[^>\n]*\bThinkChunk\b|\bThinkChunk\s*\()/i
  SERIALIZED_CONTAINER_PREFIX = /\A\s*(?:```(?:json|ruby|text)?\s*)?(?:[\[{]|#<)/i

  module_function

  def provider_reasoning_payload?(content)
    text = content.to_s
    return false if text.empty? || !text.match?(SERIALIZED_CONTAINER_PREFIX)

    text.match?(TYPED_THINKING_FIELD) || text.match?(THINK_CHUNK_MARKER)
  end

  def validate_visible_answer!(content)
    return content unless provider_reasoning_payload?(content)

    raise UnsafeProviderReasoningPayload, ERROR_CODE
  end

  def blocked_message(language = 'nl')
    case language.to_s
    when 'fr'
      "La réponse générée a été bloquée car elle contenait un raisonnement interne du modèle. La réponse non sûre n'a pas été enregistrée. Veuillez réessayer."
    when 'de'
      'Die generierte Antwort wurde blockiert, weil sie interne Modellüberlegungen enthielt. Die unsichere Antwort wurde nicht gespeichert. Bitte versuchen Sie es erneut.'
    when 'en'
      'The generated answer was blocked because it contained internal model reasoning. The unsafe answer was not saved. Please try again.'
    else
      'Het gegenereerde antwoord is geblokkeerd omdat het interne modelredenering bevatte. Het onveilige antwoord is niet opgeslagen. Probeer opnieuw.'
    end
  end
end
