// The sample catalogue's URL. Public files are cached for a year, so the fixed
// /chatbot_questions.json kept a reader's first copy for that long: the 155 moves
// of 1.1.76 did not reach a browser that had opened the chatbot before (Sol
// 2026-11-19 22:18:11Z). The layout publishes a content-versioned URL
// (StarterQuestionCatalog.versioned_url); a page without it keeps the plain one.
export const FALLBACK_CHATBOT_QUESTIONS_URL = '/chatbot_questions.json'

export function chatbotQuestionsUrl(doc = document) {
  const content = doc?.querySelector?.('meta[name="ww-chatbot-questions-url"]')?.getAttribute('content')
  return typeof content === 'string' && content.startsWith('/chatbot_questions.json') ? content : FALLBACK_CHATBOT_QUESTIONS_URL
}

// The questions held in this window belong to the catalogue URL they were
// fetched from (window.allQuestionsUrl; the sidebar's inline script reuses a
// held list only for that URL). A Turbo visit keeps the window, so after a
// catalogue-only deploy the next page advertises another URL, and a slower
// response for the older URL must not replace the newer list (Sol 2026-11-19
// 22:43:05Z).
export function holdQuestions(win, url, data, doc = document) {
  if (chatbotQuestionsUrl(doc) !== url) return false
  win.allQuestions = data
  win.allQuestionsUrl = url
  return true
}
