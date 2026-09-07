export const RETIRED_CHATBOT_MODEL_REPLACEMENTS = Object.freeze({
  'o4-mini': 'gpt-5.6-luna',
  'gpt-5.4': 'gpt-5.6-terra',
  'gpt-5.5': 'gpt-5.6-sol'
})

export function migrateChatbotModelPreference(preferences) {
  if (!preferences || typeof preferences !== 'object' || Array.isArray(preferences)) {
    return { preferences, migrated: false }
  }

  const replacement = RETIRED_CHATBOT_MODEL_REPLACEMENTS[preferences.model]
  if (!replacement) return { preferences, migrated: false }

  return {
    preferences: { ...preferences, model: replacement },
    migrated: true
  }
}
