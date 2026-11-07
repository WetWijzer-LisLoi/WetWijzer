// The contents filter ("Zoek artikel...") showed only entries whose text held the query: "3" hid "Art. 1-4", the
// entry that holds article 3 (Sol, on live 1.1.24, 07:47:05Z, /laws/2026001775). A query that reads as an article
// number now also keeps an entry whose article range ("Art. 1-4", "Art. 8.34-8.37", "Art. 2/1-2/3", "Art. 5bis-7")
// holds it, in the law's order: 3 < 3bis < 3ter < 3/1 < 4, and 8.34 < 8.35 within one book. Any other query, and any
// label without such a range, is matched on its text as before; no anchor or label is changed.
const SUFFIXES = ['bis', 'ter', 'quater', 'quinquies', 'sexies', 'septies', 'octies', 'novies', 'nonies', 'decies',
  'undecies', 'duodecies', 'terdecies', 'quaterdecies', 'quindecies', 'sexdecies', 'septdecies', 'octodecies',
  'novodecies', 'vicies']
const SUFFIX = `(?:er|${SUFFIXES.join('|')})`
const NUMBER = `\\d+(?:\\.\\d+)*(?:\\/\\d+)?(?:\\s?${SUFFIX})?`
const RANGE = new RegExp(`\\bart(?:ikelen|ikels?|icles?|\\.)?\\s*(${NUMBER})\\s*[-–]\\s*(${NUMBER})(?![\\w/.]*\\d)`, 'gi')
const QUERY = new RegExp(`^(?:art(?:ikel|icle)?\\.?\\s*)?(${NUMBER})$`, 'i')

// An article number as parts that compare in the law's order: the dotted numbers, then the Latin suffix, then the
// slash number ("1er" is article 1). Null when it is not one.
export function articleKey (text) {
  const match = String(text ?? '').trim().toLowerCase()
    .match(new RegExp(`^(\\d+(?:\\.\\d+)*)(?:\\/(\\d+))?(?:\\s?(${SUFFIX}))?$`))
  if (!match) return null
  const dotted = match[1].split('.').map(Number)
  const suffix = match[3] && match[3] !== 'er' ? SUFFIXES.indexOf(match[3]) + 1 : 0
  return { dotted, rest: [suffix, match[2] ? Number(match[2]) : 0] }
}

function compare (a, b) {
  const left = [...a.dotted, ...a.rest]
  const right = [...b.dotted, ...b.rest]
  for (let i = 0; i < left.length; i++) {
    if (left[i] !== right[i]) return left[i] < right[i] ? -1 : 1
  }
  return 0
}

// The ranges a label names, with the end's book filled in when it is left out ("Art. 8.34-37").
export function articleRanges (label) {
  const ranges = []
  for (const match of String(label ?? '').matchAll(RANGE)) {
    const start = articleKey(match[1])
    let end = articleKey(match[2])
    if (!start || !end) continue
    if (end.dotted.length < start.dotted.length) {
      end = { ...end, dotted: [...start.dotted.slice(0, start.dotted.length - end.dotted.length), ...end.dotted] }
    }
    if (end.dotted.length !== start.dotted.length || compare(start, end) > 0) continue
    ranges.push([start, end])
  }
  return ranges
}

export function tocEntryMatches (text, query) {
  const label = String(text ?? '').toLowerCase()
  const wanted = String(query ?? '').trim().toLowerCase()
  if (wanted === '' || label.includes(wanted)) return true
  const number = wanted.match(QUERY)
  const key = number && articleKey(number[1])
  if (!key) return false
  return articleRanges(label).some(([start, end]) =>
    start.dotted.length === key.dotted.length && compare(start, key) <= 0 && compare(key, end) <= 0)
}
