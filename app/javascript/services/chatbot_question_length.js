// How many characters a chatbot question may still take.
//
// Api::ChatbotController refuses a question longer than
// LegalChatbotService::MAX_QUESTION_LENGTH (2,000) characters, counted as
// Ruby counts them: in code points, of the question as the box sends it. The
// count here is the same, so a question the box shows as fitting is never
// refused, and an emoji counts once, as the server counts it. The views pass
// the server's constant as data-max; MAX_QUESTION_CHARS is only the fallback.
export const MAX_QUESTION_CHARS = 2000
// From this many characters left, the count turns amber.
export const QUESTION_CHARS_WARNING = 200

const LOCALES = { nl: 'nl-BE', fr: 'fr-BE', de: 'de-BE', en: 'en-GB' }

// [singular, plural]; which one Intl.PluralRules picks per language (French
// takes the singular for 0 too).
const COPY = {
  left: {
    nl: ['%{count} teken over', '%{count} tekens over'],
    fr: ['%{count} caractère restant', '%{count} caractères restants'],
    de: ['%{count} Zeichen übrig', '%{count} Zeichen übrig'],
    en: ['%{count} character left', '%{count} characters left']
  },
  over: {
    nl: ['%{count} teken te veel', '%{count} tekens te veel'],
    fr: ['%{count} caractère de trop', '%{count} caractères de trop'],
    de: ['%{count} Zeichen zu viel', '%{count} Zeichen zu viel'],
    en: ['%{count} character too many', '%{count} characters too many']
  }
}

const TOO_LONG = {
  nl: 'Uw vraag telt %{count} tekens, maximaal %{max}. Maak ze korter om ze te versturen.',
  fr: 'Votre question compte %{count} caractères, au maximum %{max}. Raccourcissez-la pour l’envoyer.',
  de: 'Ihre Frage hat %{count} Zeichen, höchstens %{max}. Kürzen Sie sie, um sie zu senden.',
  en: 'Your question has %{count} characters, at most %{max}. Shorten it to send it.'
}

function languageOf(language) {
  return Object.prototype.hasOwnProperty.call(LOCALES, language) ? language : 'nl'
}

function formatCount(count, language) {
  return count.toLocaleString(LOCALES[language])
}

// trim(), not Ruby's narrower strip: every box sends value.trim() (send(),
// the homepage submit), so trim() is what the server receives and measures.
export function questionLength(value) {
  return Array.from(String(value ?? '').trim()).length
}

export function questionCharsLeft(value, max = MAX_QUESTION_CHARS) {
  return max - questionLength(value)
}

// 'ok', 'warning' (QUESTION_CHARS_WARNING or fewer left) or 'over'.
export function questionCountState(left) {
  if (left < 0) return 'over'
  return left <= QUESTION_CHARS_WARNING ? 'warning' : 'ok'
}

// "1.843 tekens over", "25 tekens te veel".
export function questionCountText(left, language) {
  const lang = languageOf(language)
  const count = Math.abs(left)
  const forms = COPY[left < 0 ? 'over' : 'left'][lang]
  const form = new Intl.PluralRules(LOCALES[lang]).select(count) === 'one' ? forms[0] : forms[1]
  return form.replace('%{count}', formatCount(count, lang))
}

// The message for a Send refused because the question is too long.
export function questionTooLongMessage(value, language, max = MAX_QUESTION_CHARS) {
  const lang = languageOf(language)
  return TOO_LONG[lang]
    .replace('%{count}', formatCount(questionLength(value), lang))
    .replace('%{max}', formatCount(max, lang))
}

// The server's limit as the view states it on the counter, else the fallback.
export function questionMaxFrom(counter) {
  const max = Number.parseInt(counter?.dataset?.max, 10)
  return Number.isInteger(max) && max > 0 ? max : MAX_QUESTION_CHARS
}

// A screen reader hears the count once typing pauses, not on every key (the
// visible counter is aria-hidden; the box points at it with
// aria-describedby). delay 0 says it at once: a refused Send.
export const QUESTION_COUNT_ANNOUNCE_MS = 1000
const announceTimers = new WeakMap()

export function announceQuestionCount(status, text, delay = QUESTION_COUNT_ANNOUNCE_MS) {
  if (!status) return
  clearTimeout(announceTimers.get(status))
  announceTimers.delete(status)
  if (delay <= 0) {
    status.textContent = text
    return
  }
  announceTimers.set(status, setTimeout(() => {
    announceTimers.delete(status)
    status.textContent = text
  }, delay))
}

// Writes the count into the counter and marks the box invalid past the limit.
// Returns { left, state, text }; announcing it is the caller's business.
export function renderQuestionCount(input, counter, language) {
  const max = questionMaxFrom(counter)
  const left = questionCharsLeft(input?.value, max)
  const state = questionCountState(left)
  const text = questionCountText(left, language)
  if (counter) {
    counter.textContent = text
    counter.dataset.state = state
  }
  if (input?.setAttribute) {
    if (state === 'over') input.setAttribute('aria-invalid', 'true')
    else input.removeAttribute('aria-invalid')
  }
  return { left, state, text }
}
