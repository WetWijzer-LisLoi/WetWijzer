// The article a reader is on, carried to the same law's other language version
// (Sol, on live 1.1.19: from /laws/2022A32058?language_id=1#art-5-4 the French
// version link opened the French text at the top, art-5-4 some 6,900 px below).
// Only an article anchor (art-5-4 on a law, art_<n>--<region> on a tax code) travels: the versions share their article ids, not
// their headings or other anchors. Where the other version has no such article
// the browser stays at the top of the page, as before.
export const ARTICLE_FRAGMENT = /^#art[-_][A-Za-z0-9._-]+$/

export function withArticleFragment (href, hash) {
  if (!href || !ARTICLE_FRAGMENT.test(hash || '')) return href
  const base = href.split('#')[0]
  return `${base}${hash}`
}
