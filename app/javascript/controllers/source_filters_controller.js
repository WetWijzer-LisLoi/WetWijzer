import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["legislation", "jurisprudence", "parliamentary", "jurisprudenceFilters", "parliamentaryFilters"]

  connect() {
    this.updateFiltersVisibility()
  }

  toggle() {
    this.updateFiltersVisibility()
    this.updateCheckboxStyles()
  }

  updateFiltersVisibility() {
    // Show/hide jurisprudence filters
    if (this.hasJurisprudenceFiltersTarget && this.hasJurisprudenceTarget) {
      if (this.jurisprudenceTarget.checked) {
        this.jurisprudenceFiltersTarget.classList.remove('hidden')
      } else {
        this.jurisprudenceFiltersTarget.classList.add('hidden')
      }
    }

    // Show/hide parliamentary filters
    if (this.hasParliamentaryFiltersTarget && this.hasParliamentaryTarget) {
      if (this.parliamentaryTarget.checked) {
        this.parliamentaryFiltersTarget.classList.remove('hidden')
      } else {
        this.parliamentaryFiltersTarget.classList.add('hidden')
      }
    }
  }

  updateCheckboxStyles() {
    // Update legislation checkbox container style
    if (this.hasLegislationTarget) {
      const container = this.legislationTarget.closest('label')
      if (this.legislationTarget.checked) {
        container.classList.add('border-blue-500', 'bg-blue-50', 'dark:bg-blue-900/30')
        container.classList.remove('border-gray-300', 'dark:border-gray-600')
      } else {
        container.classList.remove('border-blue-500', 'bg-blue-50', 'dark:bg-blue-900/30')
        container.classList.add('border-gray-300', 'dark:border-gray-600')
      }
    }

    // Update jurisprudence checkbox container style
    if (this.hasJurisprudenceTarget) {
      const container = this.jurisprudenceTarget.closest('label')
      if (this.jurisprudenceTarget.checked) {
        container.classList.add('border-blue-500', 'bg-blue-50', 'dark:bg-blue-900/30')
        container.classList.remove('border-gray-300', 'dark:border-gray-600')
      } else {
        container.classList.remove('border-blue-500', 'bg-blue-50', 'dark:bg-blue-900/30')
        container.classList.add('border-gray-300', 'dark:border-gray-600')
      }
    }

    // Update parliamentary checkbox container style
    if (this.hasParliamentaryTarget) {
      const container = this.parliamentaryTarget.closest('label')
      if (this.parliamentaryTarget.checked) {
        container.classList.add('border-blue-500', 'bg-blue-50', 'dark:bg-blue-900/30')
        container.classList.remove('border-gray-300', 'dark:border-gray-600')
      } else {
        container.classList.remove('border-blue-500', 'bg-blue-50', 'dark:bg-blue-900/30')
        container.classList.add('border-gray-300', 'dark:border-gray-600')
      }
    }
  }
}
