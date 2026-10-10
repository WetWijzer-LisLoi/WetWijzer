// What the law pages copy, in one place (WW-COPY-01): the text of an article
// or heading as shown or as a citation, the "copy all" and NL/FR comparison
// payloads, a law link with a fragment, the clipboard write and what the
// reader is told about it. The clipboard controller and the article copy
// menu both use it, so the citation cleanup cannot drift apart again (it
// lived on in a copy inside show.html.erb after the controller lost it).
import { showToast } from './toast.js'

export const RULE = '='.repeat(80)

const FEEDBACK_MS = 2000
const FAILURE_MS = 5000

// The page's words (shared/_clipboard_messages); Dutch, the site's default,
// where a page does not provide them.
const DEFAULT_MESSAGES = {
  copied: 'Gekopieerd!',
  copyFailed: 'Kopiëren is mislukt. Probeer het opnieuw.',
  nothingToCopy: 'Er is niets om te kopiëren.',
  consultedOn: 'Geraadpleegd op',
  contents: 'Inhoud',
  citation: 'citaat'
}

export function clipboardMessages(doc = document) {
  const data = doc.querySelector('meta[name="clipboard-messages"]')?.dataset || {}
  return Object.fromEntries(Object.entries(DEFAULT_MESSAGES).map(([key, fallback]) => [key, data[key] || fallback]))
}

// Citation text: the amendment markers Justel wraps changed text in ([1 ... ]1,
// [1 … 1]) and the ellipses they leave behind are dropped, spaces collapse
// within a line, and at most one blank line separates paragraphs.
export function cleanCitationText(text) {
  return String(text || '')
    .replace(/\[\d+\s*\.{3}\s*\d*\]/g, '')   // [1 ... 1]
    .replace(/\[\d+\s*…\s*\d*\]/g, '')  // [1 … 1]
    .replace(/\[\d+\s/g, '')                 // a standalone opening [N
    .replace(/\]\d+/g, '')                   // a standalone closing ]N
    .replace(/\[\d+\]/g, '')                 // [N]
    .replace(/(?:^|\s)\.{3}(?:\s|$)/gm, ' ') // an orphaned '...'
    .replace(/(?:^|\s)…(?:\s|$)/gm, ' ') // an orphaned '…'
    .replace(/\t/g, ' ')
    .split('\n')
    .map(line => line.replace(/ +/g, ' ').trim())
    .filter((line, index, lines) => line || (index > 0 && lines[index - 1]))
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
}

// The citation text of a rendered article or heading: without its reference
// section, reference markers, modification markers and domain tags.
export function citationText(element) {
  if (!element) return ''
  const clone = element.cloneNode(true)
  clone.querySelectorAll('.references-section, .ref-marker').forEach(node => node.remove())
  // A reference left holding only the ellipsis of repealed text goes too.
  clone.querySelectorAll('.reference').forEach(reference => {
    const text = (reference.textContent || '').trim()
    if (!text || /^[.…\s]+$/.test(text)) reference.remove()
  })
  clone.querySelectorAll('.modification-marker, .domain-tag').forEach(node => node.remove())
  clone.querySelectorAll('br').forEach(br => br.insertAdjacentText('beforebegin', '\n'))
  clone.querySelectorAll('p, div').forEach(block => {
    block.insertAdjacentText('beforebegin', '\n')
    block.insertAdjacentText('afterend', '\n')
  })
  // A detached clone is not rendered, so its innerText would be its
  // textContent; the newlines above carry the paragraph structure.
  return cleanCitationText(clone.textContent)
}

// The text of a rendered element as the reader sees it.
export function displayedText(element) {
  if (!element) return ''
  return String(element.innerText ?? element.textContent ?? '').replace(/\n{3,}/g, '\n\n').trim()
}

// The [data-article-scope] elements under root in page order. A scope inside
// another scope is part of the outer one's text, not a second copy of it.
export function articleScopes(root) {
  if (!root) return []
  return Array.from(root.querySelectorAll('[data-article-scope]')).filter(scope => {
    const outer = scope.parentElement?.closest('[data-article-scope]')
    return !(outer && root.contains(outer))
  })
}

// A section heading (Justel or Fisconet) is copied by its <h2>; an article by
// its text container, which leaves out its copy menu and executive decisions.
function scopeParts(root, citation) {
  const textOf = citation ? citationText : displayedText
  return articleScopes(root).map(scope => {
    const heading = scope.matches('.section-heading, [data-section-heading]')
    const source = heading ? scope.querySelector('h2') : scope.querySelector('[id^="article-text-"]')
    return { heading, text: textOf(source || scope) }
  }).filter(part => part.text)
}

export function consultedDate(now = new Date()) {
  const pad = value => String(value).padStart(2, '0')
  return `${pad(now.getDate())}/${pad(now.getMonth() + 1)}/${now.getFullYear()}`
}

// The law's title: a Justel law's title block, else the page context the
// chatbot reads. That <meta> carries data-law-title too and comes first in
// the page, so the first match is not the title block.
export function lawTitle(doc = document) {
  const block = Array.from(doc.querySelectorAll('[data-law-title]')).find(element => element.tagName !== 'META')
  if (block) return displayedText(block)
  return (doc.querySelector('meta[data-law-title]')?.getAttribute('data-law-title') || '').trim()
}

// "Copy all articles": the consultation date and the title, then every heading
// and article under root in page order. The plain variant is the text as
// shown, with a contents list and ruled headings; the citation variant is
// clean text. No heading or article gives an empty string.
export function allArticlesText(root, { citation = false, title = '', consultedOn, contents, date = consultedDate() } = {}) {
  const parts = scopeParts(root, citation)
  if (!parts.length) return ''
  const header = [`${consultedOn}: ${date}`, title].filter(Boolean)
  if (citation) return [header.join('\n'), ...parts.map(part => part.text)].join('\n\n')

  const blocks = [[...header, RULE].join('\n')]
  const headings = parts.filter(part => part.heading).map(part => part.text)
  if (headings.length) blocks.push([contents, ...headings].join('\n'))
  parts.forEach(part => blocks.push(part.heading ? [RULE, part.text, RULE].join('\n') : part.text))
  return blocks.join('\n\n')
}

// The NL/FR comparison: one block per #compare-row-N with the column labels.
// A row's cells come in pairs, one pair per paragraph; each side's paragraphs
// are copied together. No rows gives an empty string.
export function compareText(doc, { citation = false, left = 'NL', right = 'FR', consultedOn, citationLabel, date = consultedDate() } = {}) {
  const textOf = citation ? citationText : displayedText
  const rows = Array.from(doc.querySelectorAll('[id^="compare-row-"]')).map(row => {
    const pairs = new Map()
    row.querySelectorAll('[data-article-scope]').forEach(cell => {
      pairs.set(cell.parentElement, [...(pairs.get(cell.parentElement) || []), cell])
    })
    const side = index => [...pairs.values()].map(pair => textOf(pair[index])).filter(Boolean).join('\n') || '-'
    return `[${left}] ${side(0)}\n[${right}] ${side(1)}`
  })
  if (!rows.length) return ''
  const heading = citation ? `${left} / ${right} (${citationLabel})` : `${left} / ${right}`
  return [`${consultedOn}: ${date}`, '', heading, RULE, '', rows.join('\n---\n')].join('\n')
}

// This page's URL with its query (language_id) kept and `fragment` as its
// only hash. No fragment gives an empty string.
export function fragmentUrl(location, fragment) {
  const id = String(fragment || '').replace(/^#+/, '')
  if (!id) return ''
  return `${location.origin}${location.pathname}${location.search}#${id}`
}

// Resolves once the text is on the clipboard. Rejects when the browser refuses
// both the Clipboard API and the older copy command, so a refusal is never
// reported as a copy.
export async function writeClipboard(text, doc = document) {
  try {
    const clipboard = globalThis.navigator?.clipboard
    if (!clipboard?.writeText) throw new Error('no Clipboard API')
    await clipboard.writeText(text)
  } catch (error) {
    if (!legacyCopy(text, doc)) throw error
  }
}

function legacyCopy(text, doc) {
  if (typeof doc.execCommand !== 'function') return false
  const area = doc.createElement('textarea')
  area.value = text
  area.setAttribute('readonly', '')
  area.style.position = 'fixed'
  area.style.top = '-9999px'
  area.style.opacity = '0'
  doc.body.appendChild(area)
  area.select()
  let copied = false
  try {
    copied = doc.execCommand('copy') === true
  } catch (_) {
    copied = false
  }
  area.remove()
  return copied
}

const pendingRestores = new WeakMap()

// Copies what `produce` returns and tells the reader the outcome: a polite
// toast and, for a moment, the control's tooltip on success; an alert on
// failure, with nothing claimed and the control as it was. Nothing to copy (a
// missing or empty source) is a failure too. `label` swaps the visible words
// of a control that holds nothing but words, as the 2FA backup-codes button
// always did; a control with an icon keeps its markup. Resolves to whether
// the text was copied.
export async function runCopy(control, produce, { copied, label = null } = {}) {
  const messages = clipboardMessages()
  let text = ''
  try {
    text = String(produce() || '')
  } catch (_) {
    text = ''
  }
  if (!text.trim()) return fail(control, messages.nothingToCopy)
  try {
    await writeClipboard(text)
  } catch (_) {
    return fail(control, messages.copyFailed)
  }
  succeed(control, copied || label || messages.copied, label)
  return true
}

function succeed(control, message, label) {
  showToast(message)
  if (!control) return
  const pending = pendingRestores.get(control)
  if (pending) clearTimeout(pending.timer)
  const original = pending?.original || {
    title: control.getAttribute('title'),
    words: label && control.children.length === 0 ? control.textContent : null
  }
  control.setAttribute('title', message)
  control.setAttribute('data-clipboard-state', 'copied')
  if (original.words !== null) control.textContent = label
  pendingRestores.set(control, { original, timer: setTimeout(() => restore(control), FEEDBACK_MS) })
}

function fail(control, message) {
  showToast(message, { type: 'error', duration: FAILURE_MS })
  if (control) {
    restore(control)
    control.setAttribute('data-clipboard-state', 'failed')
    setTimeout(() => {
      if (control.getAttribute('data-clipboard-state') === 'failed') control.removeAttribute('data-clipboard-state')
    }, FAILURE_MS)
  }
  return false
}

function restore(control) {
  const pending = pendingRestores.get(control)
  control.removeAttribute('data-clipboard-state')
  if (!pending) return
  clearTimeout(pending.timer)
  pendingRestores.delete(control)
  if (pending.original.title === null) control.removeAttribute('title')
  else control.setAttribute('title', pending.original.title)
  if (pending.original.words !== null) control.textContent = pending.original.words
}
