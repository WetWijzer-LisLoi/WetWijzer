import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    message: String,
    estimate: String
  }

  show(event) {
    // Create overlay
    const overlay = document.createElement('div')
    overlay.className = 'fixed inset-0 bg-black/50 dark:bg-black/70 flex items-center justify-center z-[9999] backdrop-blur-sm'
    overlay.innerHTML = `
      <div class="bg-white dark:bg-navy rounded-lg shadow-2xl p-8 max-w-md mx-4 border border-gray-200 dark:border-gray-700">
        <div class="flex flex-col items-center text-center">
          <svg class="animate-spin h-12 w-12 text-blue-500 dark:text-blue-400 mb-4" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
            <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
          </svg>
          
          <h3 class="text-lg font-semibold text-gray-900 dark:text-white mb-2">
            ${this.messageValue || 'Loading...'}
          </h3>
          
          <p class="text-sm text-gray-600 dark:text-gray-400 mb-4">
            ${this.estimateValue || 'This may take a moment'}
          </p>
          
          <div class="w-full bg-gray-200 dark:bg-gray-700 rounded-full h-2 overflow-hidden">
            <div class="loading-bar h-full bg-blue-500 dark:bg-blue-400 rounded-full" style="animation: loading 2s ease-in-out infinite;"></div>
          </div>
        </div>
      </div>
      
      <style>
        @keyframes loading {
          0% { width: 0%; margin-left: 0%; }
          50% { width: 50%; margin-left: 25%; }
          100% { width: 0%; margin-left: 100%; }
        }
      </style>
    `
    
    document.body.appendChild(overlay)
  }
}
