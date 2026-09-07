import { Controller } from "@hotwired/stimulus"

// The two states a source tab can be in.
//
// Both are managed here, symmetrically. The controller used to remove only the
// inactive classes and paint the active tab with inline styles, which left two
// problems: the first tab kept its server-rendered active classes after you
// switched away from it, so text-gray-500 and text-(--accent-600) fought over
// it in whatever order Tailwind happened to emit them; and an inline colour
// beats every hover rule, so the active tab could not respond to the pointer
// at all. Classes on both sides fix both.
const ACTIVE = ['border-(--accent-500)', 'text-(--accent-600)', 'dark:text-(--accent-400)']

// The hover here is deliberately the accent, not a lighter grey. In dark the
// theme raises muted text to --text-muted (#d1d5db), which IS gray-300, so the
// old hover target of gray-300 was the colour the tab already had: measured on
// the live site, rgb(209,213,219) -> rgb(209,213,220), one unit out of 255.
const INACTIVE = ['border-transparent', 'text-gray-500', 'hover:text-(--accent-600)',
                  'hover:border-(--accent-400)/60', 'dark:text-gray-400',
                  'dark:hover:text-(--accent-400)', 'dark:hover:border-(--accent-400)/60']

export default class extends Controller {
  static targets = ["tab", "panel"]

  connect() {
    this.showPanel(0)
  }

  select(event) {
    const index = parseInt(event.currentTarget.dataset.tabIndex, 10)
    this.showPanel(index)
  }

  showPanel(index) {
    this.tabTargets.forEach((tab, i) => {
      const on = i === index
      tab.classList.remove(...(on ? INACTIVE : ACTIVE))
      tab.classList.add(...(on ? ACTIVE : INACTIVE))
      tab.setAttribute('aria-selected', on ? 'true' : 'false')
      // Clear the inline styles earlier versions painted, so a page that was
      // rendered before this change does not keep an unhoverable tab.
      tab.style.borderBottomColor = ''
      tab.style.color = ''
    })

    this.panelTargets.forEach((panel, i) => {
      panel.classList.toggle('hidden', i !== index)
    })
  }
}
