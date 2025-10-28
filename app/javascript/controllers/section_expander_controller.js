import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="section-expander"
export default class extends Controller {
  // Show toast notification
  showToast(message) {
    // Remove any existing toasts
    const existingToast = document.querySelector('.section-expander-toast')
    if (existingToast) {
      existingToast.remove()
    }

    // Create toast element
    const toast = document.createElement('div')
    toast.className = 'section-expander-toast fixed bottom-6 left-1/2 -translate-x-1/2 z-[9999] px-4 py-2 bg-gray-900 dark:bg-gray-100 text-white dark:text-gray-900 text-sm font-medium rounded-lg shadow-lg animate-fade-in-up'
    toast.textContent = message
    toast.setAttribute('role', 'status')
    toast.setAttribute('aria-live', 'polite')

    document.body.appendChild(toast)

    // Remove after 2 seconds
    setTimeout(() => {
      toast.classList.add('animate-fade-out')
      setTimeout(() => toast.remove(), 300)
    }, 2000)
  }

  expandAll(event) {
    event?.preventDefault()
    
    // Find all collapse controllers within the articles section
    const articlesContainer = document.getElementById('tekst')
    if (!articlesContainer) return
    
    // Find all collapsible sections (section headings, NOT the main Tekst header)
    // Exclude the parent Tekst collapse controller by only selecting .section-heading elements
    const collapseButtons = articlesContainer.querySelectorAll('.section-heading [data-controller*="collapse"] [data-collapse-target="button"]')
    
    collapseButtons.forEach(button => {
      const collapseController = this.application.getControllerForElementAndIdentifier(
        button.closest('[data-controller*="collapse"]'),
        'collapse'
      )
      
      if (collapseController && !collapseController.expandedValue) {
        // Section is collapsed, expand it
        collapseController.toggle()
      }
    })
    
    // Show toast notification
    this.showToast('Alle secties uitgevouwen')
  }
  
  collapseAll(event) {
    event?.preventDefault()
    
    // Find all collapse controllers within the articles section
    const articlesContainer = document.getElementById('tekst')
    if (!articlesContainer) return
    
    // Find all collapsible sections (section headings, NOT the main Tekst header)
    // Exclude the parent Tekst collapse controller by only selecting .section-heading elements
    const collapseButtons = articlesContainer.querySelectorAll('.section-heading [data-controller*="collapse"] [data-collapse-target="button"]')
    
    collapseButtons.forEach(button => {
      const collapseController = this.application.getControllerForElementAndIdentifier(
        button.closest('[data-controller*="collapse"]'),
        'collapse'
      )
      
      if (collapseController && collapseController.expandedValue) {
        // Section is expanded, collapse it
        collapseController.toggle()
      }
    })
    
    // Show toast notification
    this.showToast('Alle secties samengevouwen')
  }
}
