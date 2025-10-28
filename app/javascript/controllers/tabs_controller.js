import { Controller } from "@hotwired/stimulus"

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
    // Update tab styles using CSS custom properties for theme-aware colors
    this.tabTargets.forEach((tab, i) => {
      if (i === index) {
        tab.classList.remove('border-transparent', 'text-gray-500', 'hover:text-gray-700', 'dark:text-gray-400', 'dark:hover:text-gray-300')
        // Use accent CSS variables for theme-aware active tab styling
        tab.style.borderBottomColor = 'var(--accent-500)'
        tab.style.color = 'var(--accent-600)'
      } else {
        tab.style.borderBottomColor = ''
        tab.style.color = ''
        tab.classList.add('border-transparent', 'text-gray-500', 'hover:text-gray-700', 'dark:text-gray-400', 'dark:hover:text-gray-300')
      }
    })

    // Show/hide panels
    this.panelTargets.forEach((panel, i) => {
      if (i === index) {
        panel.classList.remove('hidden')
      } else {
        panel.classList.add('hidden')
      }
    })
  }
}
