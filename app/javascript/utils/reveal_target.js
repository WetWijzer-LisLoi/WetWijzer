// A link to an article inside a folded section opened nothing: the address and the scroll changed, the article stayed
// hidden (Sol, on live 1.1.21, 21:56:51Z: Book 8, "Onderafdeling 1. Beslissende eed" folded, then the contents link
// Art. 8.34-8.37). Every folded section around the target is opened through its own button, so the controls and the
// text stay in step, innermost first. Returns how many are open afterwards that were folded before.
// Every section around the target also says on its button what it is: on live 1.1.23 (Sol 02:20:35Z) three open
// sections around Art. 8.34 showed their text while their buttons said aria-expanded="false". One check decides both
// (Sol 08:53:54Z: the open test read only the class while the folded test read the class or the value, so a section
// folded by its value alone, whose click did nothing, was told "true").
export function sectionFolded (section) {
  return Boolean(section?.classList?.contains('is-collapsed') ||
    section?.getAttribute?.('data-collapse-expanded-value') === 'false')
}

export function revealCollapsedAncestors (element) {
  let opened = 0
  let section = element?.parentElement?.closest?.('[data-controller~="collapse"]')
  while (section) {
    const button = section.querySelector?.('[data-collapse-target="button"]')
    if (sectionFolded(section) && button) {
      button.click()
      if (!sectionFolded(section)) opened += 1
    }
    if (button) button.setAttribute?.('aria-expanded', String(!sectionFolded(section)))
    section = section.parentElement?.closest?.('[data-controller~="collapse"]')
  }
  return opened
}
