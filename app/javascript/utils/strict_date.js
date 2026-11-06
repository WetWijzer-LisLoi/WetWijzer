// A typed date in d/m/Y that exists on the calendar, else undefined. The date fields took "31/02/2026" and showed
// "03/03/2026": JavaScript's Date rolls an impossible day forward (Sol, on live 1.1.19, 17:39:46Z).
export function parseStrictDate (text) {
  const match = String(text ?? '').trim().match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/)
  if (!match) return undefined
  const [day, month, year] = match.slice(1).map(Number)
  const date = new Date(year, month - 1, day)
  if (date.getFullYear() !== year || date.getMonth() !== month - 1 || date.getDate() !== day) return undefined
  return date
}
