import { Controller } from "@hotwired/stimulus"
import flatpickr from "flatpickr"
import { Dutch } from "flatpickr/dist/l10n/nl.js"
import { French } from "flatpickr/dist/l10n/fr.js"

export default class extends Controller {
  static values = {
    locale: String
  }

  connect() {
    const locale = this.localeValue || 'nl'
    
    flatpickr(this.element, {
      locale: locale === 'fr' ? French : Dutch,
      dateFormat: 'd/m/Y',
      altInput: false,
      allowInput: true,
      disableMobile: true
    })
  }

  disconnect() {
    if (this.element._flatpickr) {
      this.element._flatpickr.destroy()
    }
  }
}
