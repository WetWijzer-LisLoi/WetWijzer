import { Controller } from "@hotwired/stimulus"
import { showToast } from '../utils/toast'

// Connects to data-controller="section-expander"
export default class extends Controller {


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
    showToast('Alle secties uitgevouwen')
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
    showToast('Alle secties samengevouwen')
  }
}
