// F15: a page's own inline scripts keep running after a Turbo visit.
//
// Nonces are random per request (config/initializers/content_security_policy.rb).
// A document keeps the policy of its first page load, and so that load's
// nonce, while a page fetched by Turbo stamps its scripts with its own nonce.
// Turbo copies a script's attributes when it runs it, so every inline script
// of a visited page was blocked by the enforced policy (measured live on
// 2026-10-08: /pricing, then the /about link).
//
// Before Turbo renders a fetched page, the scripts that carry that page's own
// nonce (the server names it on <body data-csp-nonce>) are re-stamped with the
// document's. A script without that page's nonce is left as it is and stays
// blocked, so this trusts exactly what the server marked as trusted: injected
// markup cannot know a per-response nonce.

export function renonceScripts(body, documentNonce) {
  const fetchedNonce = body?.dataset?.cspNonce
  if (!documentNonce || !fetchedNonce || fetchedNonce === documentNonce) return 0

  let restamped = 0
  for (const script of body.querySelectorAll('script')) {
    if (script.getAttribute('nonce') === fetchedNonce) {
      script.setAttribute('nonce', documentNonce)
      restamped += 1
    }
  }
  body.dataset.cspNonce = documentNonce
  return restamped
}

export function installTurboCspNonce(doc = document) {
  const documentNonce = doc.querySelector('meta[name="csp-nonce"]')?.getAttribute('content')
  if (!documentNonce) return false

  doc.addEventListener('turbo:before-render', (event) => {
    renonceScripts(event.detail?.newBody, documentNonce)
  })
  // Turbo's head merge brings in the visited page's csp-nonce meta, which Turbo
  // and our own code read to stamp the scripts and styles they create.
  doc.addEventListener('turbo:render', () => {
    doc.querySelector('meta[name="csp-nonce"]')?.setAttribute('content', documentNonce)
  })
  return true
}
