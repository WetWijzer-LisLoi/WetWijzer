// Back and Forward after a frame navigation that advances the address (a source's own pager or sort on the combined
// results, data-turbo-action="advance") restored the rows with the window at the top of the page (Sol, on live
// 1.1.29, 12:50:04Z, task 52). Found in Chrome with test/system/results_history_browser_test.rb, in Turbo 8.0.23.
// Turbo ends such a frame navigation with a visit that renders the frame's response as a page it does not show; that
// response has no layout and so none of the page's tracked assets, and the page renderer refuses it. Three things
// follow, each repaired here:
//
// 1. View#renderPage sets view.forceReloaded, which only a reload would reset, and Visit#performScroll skips every
//    later visit: a restored page stayed where the body swap left the window (Back went to 0 from 2412). The flag
//    belongs to the visit that set it, so it is cleared when the next visit starts; a visit that sets it itself (a
//    real change of the tracked assets) still reloads.
// 2. view.lastRenderedLocation stays at the address before the navigation, and Turbo caches the page it leaves under
//    that address: on Back the second page went into the cache as the first, and Forward found nothing for the second
//    page and fetched it. It is brought in line with the history's address once a visit has loaded.
// 3. Hovering a link that targets a frame prefetches it with that frame's Turbo-Frame header, and the next request for
//    the same address takes the prefetched response whatever it asked for. On Forward the pointer rested on the pager
//    link of the restored page, so the page visit received the bare frame and Turbo reloaded the whole page
//    ("tracked_element_mismatch"). A prefetched response now serves only a request for the same frame, or for none.
//
// One more, outside those three: the law's article history (history_links_controller.js) settles the address of a page
// that keeps no snapshot (turbo-cache-control no-cache), and Turbo 8.0.23 takes no restoration for the same page. A
// Back or Forward that changed the fragment alone therefore fetched the address and rendered the page again, which
// closed a second open picker (Sol 2026-11-21 10:09:36Z). keepFragmentRestorationsInPlace lets such a restoration keep
// the page: Turbo still records the entry, and the window goes where Turbo would put it (the entry's saved position,
// else the fragment's element).

function frameOf (headers) {
  if (!headers) return null
  const value = typeof headers.get === 'function' ? headers.get('Turbo-Frame') : headers['Turbo-Frame']
  return value || null
}

export function clearStaleForceReload (turbo) {
  const view = turbo?.session?.view
  if (view?.forceReloaded) view.forceReloaded = false
}

export function syncRenderedLocation (turbo) {
  const view = turbo?.session?.view
  const location = turbo?.session?.history?.location
  if (!view || !location?.href) return
  if (view.lastRenderedLocation?.href !== location.href) view.lastRenderedLocation = new URL(location.href)
}

export function keepFragmentRestorationsInPlace (turbo, fragmentOnly, win = globalThis.window) {
  const session = turbo?.session
  const original = session?.historyPoppedToLocationWithRestorationIdentifierAndDirection
  if (typeof original !== 'function' || original.keepsFragments) return
  const guarded = function (location, restorationIdentifier, direction) {
    if (!fragmentOnly(location)) return original.call(this, location, restorationIdentifier, direction)
    const position = session.history?.getRestorationDataForIdentifier?.(restorationIdentifier)?.scrollPosition
    if (position) return win?.scrollTo(position.x, position.y)
    let id = String(location.hash || '').replace(/^#/, '')
    try { id = decodeURIComponent(id) } catch (_) { /* the id as written */ }
    win?.document?.getElementById(id)?.scrollIntoView()
  }
  guarded.keepsFragments = true
  session.historyPoppedToLocationWithRestorationIdentifierAndDirection = guarded
}

export function dropMismatchedPrefetch (event) {
  const detail = event?.detail
  const prefetched = detail?.fetchRequest
  if (!prefetched) return
  if (frameOf(prefetched.fetchOptions?.headers) !== frameOf(detail.fetchOptions?.headers)) detail.fetchRequest = undefined
}

export function installTurboHistoryRepairs (turbo, doc = document) {
  const listeners = [
    ['turbo:visit', () => clearStaleForceReload(turbo)],
    ['turbo:load', () => syncRenderedLocation(turbo)],
    // Turbo hands the prefetched request over in a capturing listener on the document; this one runs after it.
    ['turbo:before-fetch-request', dropMismatchedPrefetch]
  ]
  listeners.forEach(([name, fn]) => doc.addEventListener(name, fn))
  return () => listeners.forEach(([name, fn]) => doc.removeEventListener(name, fn))
}
