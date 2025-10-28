import { Controller } from "@hotwired/stimulus"

// Provides visual feedback for file downloads
export default class extends Controller {
  static targets = ["icon", "spinner", "label"]
  static values = {
    url: String,
    filename: String
  }

  async download(event) {
    event.preventDefault()
    
    // Disable button and show loading state
    this.element.disabled = true
    this.iconTarget.classList.add('hidden')
    this.spinnerTarget.classList.remove('hidden')
    if (this.hasLabelTarget) {
      this.labelTarget.textContent = 'Bezig...'
    }

    try {
      // Fetch the file
      const response = await fetch(this.urlValue)
      
      if (!response.ok) {
        throw new Error(`Export failed: ${response.status}`)
      }

      // Get the blob
      const blob = await response.blob()
      
      // Create download link
      const url = window.URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.style.display = 'none'
      a.href = url
      a.download = this.filenameValue
      
      // Trigger download
      document.body.appendChild(a)
      a.click()
      
      // Cleanup
      window.URL.revokeObjectURL(url)
      document.body.removeChild(a)
      
      // Show success feedback
      this.showSuccess()
    } catch (error) {
      console.error('Export error:', error)
      this.showError()
    } finally {
      // Reset button after delay
      setTimeout(() => {
        this.reset()
      }, 2000)
    }
  }

  showSuccess() {
    if (this.hasLabelTarget) {
      this.labelTarget.textContent = 'Geëxporteerd!'
    }
    this.element.classList.add('text-green-600', 'dark:text-green-400')
  }

  showError() {
    if (this.hasLabelTarget) {
      this.labelTarget.textContent = 'Fout'
    }
    this.element.classList.add('text-red-600', 'dark:text-red-400')
  }

  reset() {
    this.element.disabled = false
    this.spinnerTarget.classList.add('hidden')
    this.iconTarget.classList.remove('hidden')
    if (this.hasLabelTarget) {
      this.labelTarget.textContent = 'Word'
    }
    this.element.classList.remove('text-green-600', 'dark:text-green-400', 'text-red-600', 'dark:text-red-400')
  }
}
