import { Controller } from "@hotwired/stimulus"
import flatpickr from "flatpickr"
import { Dutch } from "flatpickr/dist/l10n/nl.js"
import { French } from "flatpickr/dist/l10n/fr.js"
import { German } from "flatpickr/dist/l10n/de.js"
import { english } from "flatpickr/dist/l10n/default.js"
import { getLocale, localeText } from '../utils/locale'

export default class extends Controller {
  static values = {
    locale: String
  }

  connect() {
    const locale = (this.localeValue || getLocale()).toLowerCase().split(/[-_]/)[0]
    
    flatpickr(this.element, {
      locale: localeText({ nl: Dutch, fr: French, de: German, en: english }, locale),
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
