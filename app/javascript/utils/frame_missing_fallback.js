import { uiText } from './ui_translations'

// A frame whose response does not hold it gets Turbo's bare "Content missing" in place of its content, and Turbo then throws. The search
// results frame has no frame-status controller, so a 502 during a restart emptied the results that way (2026-11-05). frame-status
// handles its own frames and has already cancelled the event when it reaches the document.
export function handleFrameMissing(event, doc = document, origin = window.location.origin) {
  if (event.defaultPrevented) return
  const frame = event.target
  const { response, visit } = event.detail || {}
  event.preventDefault()

  // A whole page without this frame, as a login page: open it, as a plain link would.
  if (response?.ok && response.url && typeof visit === 'function') {
    visit(response.url)
    return
  }

  frame.querySelector('[data-frame-status-error]')?.remove()
  const panel = doc.createElement('div')
  panel.setAttribute('data-frame-status-error', '')
  panel.setAttribute('role', 'alert')
  panel.className = 'flex flex-wrap items-center gap-3 p-4 text-sm text-red-700 dark:text-red-300'

  const message = doc.createElement('span')
  message.textContent = uiText('loadFailed')
  panel.appendChild(message)
  if (frame.children.length > 0) {
    const previous = doc.createElement('span')
    previous.textContent = uiText('previousResults')
    panel.appendChild(previous)
  }

  // The address that failed still holds the search, so trying it again keeps the query.
  const target = sameOriginUrl(response?.url, origin)
  if (target) {
    const retry = doc.createElement('a')
    retry.setAttribute('href', target)
    retry.setAttribute('data-turbo-frame', '_top')
    retry.className = 'underline font-medium'
    retry.textContent = uiText('retry')
    panel.appendChild(retry)
  }
  frame.prepend(panel)
}

function sameOriginUrl(url, origin) {
  if (!url) return null
  try {
    return new URL(url, origin).origin === origin ? url : null
  } catch {
    return null
  }
}

export function installFrameMissingFallback(doc = document) {
  doc.addEventListener('turbo:frame-missing', event => handleFrameMissing(event, doc))
}
