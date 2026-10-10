// WW-UI-02: a table-of-contents link whose target id the loaded article frame
// does not have. The contents come from the stored table of contents and the
// body from the article rows, and their texts differ: a repealed heading
// carries "<Opgeheven bij ...>" only in the body, a heading split over two
// contents lines is one body heading, and a slash-numbered article the body
// shows as a heading has a section- id. In each case the intended target sits
// between the targets of the neighbouring links that do resolve, and its id
// extends the link's id.

// tocIds: the links' target ids in order; bodyIds: every id in the article
// frame in document order. Returns, per link, the id it should point at: its
// own when that exists, a matched one, or null when the body has none.
// A matched target is used by one link only, and never jumps outside the
// window between the resolving neighbours.
export function planTocTargets(tocIds, bodyIds) {
  const position = new Map()
  bodyIds.forEach((id, index) => {
    if (!position.has(id)) position.set(id, index)
  })
  const resolves = tocIds.map((id) => position.has(id))
  const plan = tocIds.map((id, index) => (resolves[index] ? id : undefined))
  const claimed = new Set(plan.filter(Boolean))

  for (let index = 0; index < tocIds.length; index++) {
    if (plan[index] !== undefined) continue

    let from = -1
    for (let before = index - 1; before >= 0; before--) {
      if (plan[before]) { from = position.get(plan[before]); break }
    }
    let to = bodyIds.length
    for (let after = index + 1; after < tocIds.length; after++) {
      if (resolves[after]) { to = position.get(tocIds[after]); break }
    }

    plan[index] = null
    for (let at = from + 1; at < to; at++) {
      const candidate = bodyIds[at]
      if (!claimed.has(candidate) && extendsTarget(candidate, tocIds[index])) {
        plan[index] = candidate
        claimed.add(candidate)
        break
      }
    }
  }
  return plan
}

function extendsTarget(id, wanted) {
  return extendsStem(id, wanted) || (wanted.startsWith("art-") && extendsStem(id, `section-${wanted}`))
}

function extendsStem(id, stem) {
  return id === stem || id.startsWith(`${stem}-`)
}
