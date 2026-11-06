// After the page scrolls to a fragment's article, content above it can still change size and carry the article off
// the screen. Sol, on live 1.1.19: an amendment link opened in a new tab, /laws/2023048423?language_id=1#art-83, left
// art-83 at -296 px with the hash kept, while a reload and the contents link both landed it at 96 px. What changed
// size above it was not established. For a short while after the scroll the article is put back at the top whenever it
// drifts, until the reader scrolls, types, touches or clicks: the reader's own scrolling always wins.
const DRIFT_PX = 4
const STOP_EVENTS = ['wheel', 'touchstart', 'keydown', 'mousedown']
const LISTEN = { passive: true, capture: true }

export function settleOnTarget (element, {
  win = window,
  durationMs = 3000,
  now = () => Date.now(),
  frame = callback => win.requestAnimationFrame(callback)
} = {}) {
  if (!element) return () => {}
  const expected = element.getBoundingClientRect().top
  const deadline = now() + durationMs
  let stopped = false
  const stop = () => {
    if (stopped) return
    stopped = true
    STOP_EVENTS.forEach(name => win.removeEventListener(name, stop, LISTEN))
  }
  STOP_EVENTS.forEach(name => win.addEventListener(name, stop, LISTEN))
  const check = () => {
    if (stopped) return
    if (now() > deadline) { stop(); return }
    if (Math.abs(element.getBoundingClientRect().top - expected) > DRIFT_PX) {
      element.scrollIntoView({ behavior: 'auto', block: 'start', inline: 'nearest' })
    }
    frame(check)
  }
  frame(check)
  return stop
}
