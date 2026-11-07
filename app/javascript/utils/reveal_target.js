// A link to an article inside a folded section opened nothing: the address and the scroll changed, the article stayed
// hidden (Sol, on live 1.1.21, 21:56:51Z: Book 8, "Onderafdeling 1. Beslissende eed" folded, then the contents link
// Art. 8.34-8.37). Every folded section around the target is opened through its own button, so the controls and the
// text stay in step, innermost first. Returns how many were opened.
export function revealCollapsedAncestors (element) {
  let opened = 0
  let section = element?.parentElement?.closest?.('[data-controller~="collapse"]')
  while (section) {
    const folded = section.classList?.contains('is-collapsed') || section.getAttribute?.('data-collapse-expanded-value') === 'false'
    if (folded) {
      const button = section.querySelector?.('[data-collapse-target="button"]')
      if (button) {
        button.click()
        opened += 1
      }
    }
    section = section.parentElement?.closest?.('[data-controller~="collapse"]')
  }
  return opened
}
