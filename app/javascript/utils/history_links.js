// The article-history pilot's in-place steps (laws/_history_frame; the owner, via Sol 2026-11-20 17:10:56Z). A step
// link was rendered when its own article last changed: it carries that article's choice, but the other articles'
// choices may have moved since, in the address their own steps advanced. The address therefore gives every other
// article's choice and the link its own article's. ownKeys: the article's keys in both languages, since a regional
// variant has one per language (Art.42_WAALS_GEWEST, Art.42_REGION_WALLONNE).
const HISTORY_PARAM = /^(?:art_version|art_compare)\[(.+)\]$/

export function mergedHistoryUrl(linkHref, currentHref, ownKeys = []) {
  const current = new URL(currentHref)
  const link = new URL(linkHref, current)
  const own = new Set(ownKeys)
  const otherArticle = name => {
    const match = HISTORY_PARAM.exec(name)
    return match !== null && !own.has(match[1])
  }
  for (const name of new Set(link.searchParams.keys())) {
    if (otherArticle(name)) link.searchParams.delete(name)
  }
  for (const [name, value] of current.searchParams) {
    if (otherArticle(name)) link.searchParams.append(name, value)
  }
  return link.toString()
}

// What an address asks one article's frame to show, in the form the frame's row carries what it shows
// (data-history-state, HistoryPilotHelper#history_rendered_state): the archive date, the chosen wording, a comparison,
// the picker open, separated by "|". keys: the article's keys in both languages. The values the server ignores are
// ignored here too (LawsController::HISTORY_DAY, HISTORY_VERSION, HISTORY_FOCUS).
const DAY = /^\d{4}-\d{2}-\d{2}$/
const VERSION = /^(?:\d{3}|current)$/
const FOCUS = /^(Art\.[0-9A-Za-z/_. -]{1,60}):(open|close|older|newer|law|compare|item)$/

export function requestedHistoryState(href, keys = []) {
  const params = new URL(href).searchParams
  const day = params.get("as_of") || ""
  const version = keys.map(key => params.get(`art_version[${key}]`)).find(value => value !== null) || ""
  const compare = keys.some(key => params.has(`art_compare[${key}]`)) ? "1" : ""
  const focus = FOCUS.exec(params.get("history_focus") || "")
  const open = focus !== null && keys.includes(focus[1]) && focus[2] !== "close" ? "1" : ""
  return [DAY.test(day) ? day : "", VERSION.test(version) ? version : "", compare, open].join("|")
}

// The address once an article's step has landed: every article frame on the page in it as the frame shows it, so the
// address, a reload and Back give what is on the screen, whatever order the frames' answers came back in (Sol
// 2026-11-21 06:56:33Z: two quick steps in two articles left the address with the first article's old wording, since
// the second step was sent before the first one had landed). frames: [{ keys, key, state }], the frame's keys in both
// languages, its row's key (data-history-row) and what it shows (data-history-state: day|version|compare|open). The
// date, the step (history_focus) and the choices for articles without a frame on the page stay as they are.
export function settledHistoryUrl(currentHref, frames = []) {
  const url = new URL(currentHref)
  for (const { keys = [], key, state } of frames) {
    if (!key) continue
    const [, version = "", compare = ""] = String(state || "").split("|")
    for (const name of new Set([...keys, key])) {
      url.searchParams.delete(`art_version[${name}]`)
      url.searchParams.delete(`art_compare[${name}]`)
    }
    if (VERSION.test(version)) url.searchParams.append(`art_version[${key}]`, version)
    if (compare === "1") url.searchParams.append(`art_compare[${key}]`, "1")
  }
  return url.toString()
}
