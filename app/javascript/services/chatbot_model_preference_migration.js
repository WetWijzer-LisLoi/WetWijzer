export const RETIRED_CHATBOT_MODEL_REPLACEMENTS = Object.freeze({
  'o4-mini': 'gpt-6-luna',
  'gpt-5-mini': 'gpt-6-luna',
  'gpt-5.6-luna': 'gpt-6-luna',
  'gpt-5': 'gpt-6.1-sol',
  'gpt-5.4': 'gpt-6.1-sol',
  'gpt-5.5': 'gpt-6.1-sol',
  'gpt-5.6-terra': 'gpt-6.1-sol',
  'gpt-5.6-sol': 'gpt-6.1-sol',
  'gpt-6-sol': 'gpt-6.1-sol',
  'mistral-large-3': 'mistral-large-4',
  'claude-4.5-haiku': 'claude-haiku-5-5',
  'claude-sonnet-4-6': 'claude-sonnet-5-5',
  'claude-opus-4-6': 'claude-opus-5-5'
})

const REPLACEMENT_INTELLIGENCE = Object.freeze({
  'gpt-6-luna': 'genius',
  'gpt-6.1-sol': 'mastermind',
  'mistral-large-4': 'genius',
  'claude-haiku-5-5': 'genius',
  'claude-sonnet-5-5': 'mastermind',
  'claude-opus-5-5': 'omniscient'
})

export function migrateChatbotModelPreference(preferences) {
  if (!preferences || typeof preferences !== 'object' || Array.isArray(preferences)) {
    return { preferences, migrated: false }
  }

  const replacement = RETIRED_CHATBOT_MODEL_REPLACEMENTS[preferences.model]
  if (!replacement) return { preferences, migrated: false }

  return {
    preferences: {
      ...preferences,
      model: replacement,
      intelligence: REPLACEMENT_INTELLIGENCE[replacement]
    },
    migrated: true
  }
}
