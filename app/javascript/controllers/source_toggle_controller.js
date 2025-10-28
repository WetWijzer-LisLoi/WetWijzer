import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["btn", "input"]

  connect() {
    this.updateStyles()
  }

  select(event) {
    const source = event.currentTarget.dataset.source
    
    // Update hidden input
    if (this.hasInputTarget) {
      this.inputTarget.value = source
    }

    // Handle jurisprudence redirect
    if (source === 'jurisprudence') {
      const searchInput = this.element.querySelector('input[name="title"]')
      const query = searchInput ? searchInput.value : ''
      window.location.href = `/jurisprudence${query ? '?q=' + encodeURIComponent(query) : ''}`
      return
    }

    // Handle parliamentary redirect
    if (source === 'parliamentary') {
      const searchInput = this.element.querySelector('input[name="title"]')
      const query = searchInput ? searchInput.value : ''
      window.location.href = `/parliamentary_work/chamber${query ? '?q=' + encodeURIComponent(query) : ''}`
      return
    }

    this.updateStyles()
  }

  updateStyles() {
    const currentSource = this.hasInputTarget ? this.inputTarget.value : 'legislation'
    
    this.btnTargets.forEach(btn => {
      const isActive = btn.dataset.source === currentSource
      
      if (isActive) {
        btn.style.backgroundColor = 'var(--accent-600)'
        btn.style.color = '#fff'
        btn.classList.remove('text-gray-600', 'dark:text-gray-400', 'hover:bg-gray-100', 'dark:hover:bg-gray-700')
      } else {
        btn.style.backgroundColor = ''
        btn.style.color = ''
        btn.classList.add('text-gray-600', 'dark:text-gray-400', 'hover:bg-gray-100', 'dark:hover:bg-gray-700')
      }
    })
  }
}
