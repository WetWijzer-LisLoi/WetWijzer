import { Controller } from "@hotwired/stimulus"

// Generic controller: fetches HTML into a target container when a checkbox is toggled.
// Usage:
//   <input type="checkbox"
//          data-controller="lazy-checkbox"
//          data-lazy-checkbox-url-value="/some/endpoint"
//          data-lazy-checkbox-target-value="container-id"
//          data-action="change->lazy-checkbox#toggle">
//   <div id="container-id" class="hidden"></div>
export default class extends Controller {
    static values = {
        url: String,
        target: String,
        loaded: { type: Boolean, default: false }
    }

    toggle(event) {
        const container = document.getElementById(this.targetValue)
        if (!container) return

        if (event.target.checked) {
            container.classList.remove("hidden")
            if (!this.loadedValue) {
                const locale = document.documentElement.lang || "nl"
                const loadingText = locale === "nl" ? "Laden…" : "Chargement…"
                const errorText = locale === "nl" ? "Laden mislukt" : "Échec du chargement"

                container.innerHTML = `<div class="p-4 flex items-center gap-2 text-sm text-gray-500 dark:text-gray-400">
          <svg class="animate-spin h-4 w-4" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
            <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
          </svg>
          ${loadingText}
        </div>`

                fetch(this.urlValue, { headers: { "Accept": "text/html" } })
                    .then(response => {
                        if (!response.ok) throw new Error(`HTTP ${response.status}`)
                        return response.text()
                    })
                    .then(html => {
                        container.innerHTML = html
                        this.loadedValue = true
                    })
                    .catch(() => {
                        container.innerHTML = `<div class="p-4 text-sm text-red-600 dark:text-red-400">${errorText}</div>`
                    })
            }
        } else {
            container.classList.add("hidden")
        }
    }
}
