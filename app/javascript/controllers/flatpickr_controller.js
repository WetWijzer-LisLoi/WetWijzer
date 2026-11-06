import { Controller } from "@hotwired/stimulus"
import flatpickr from "flatpickr"
import { Dutch } from "flatpickr/dist/l10n/nl.js"
import { French } from "flatpickr/dist/l10n/fr.js"
import { German } from "flatpickr/dist/l10n/de.js"
import { english } from "flatpickr/dist/l10n/default.js"
import { getLocale, localeText } from '../utils/locale'
import { parseStrictDate } from '../utils/strict_date.js'

// A typed date must exist: "31/02/2026" became "03/03/2026" without a word (Sol, on live 1.1.19, 17:39:46Z). The
// picker now reads only real calendar dates; a date that does not exist keeps the reader's text, is marked invalid
// and says why, and a valid date (29/02/2024 included) behaves as before.
export const INVALID_DATE_TEXT = {
  nl: 'Deze datum bestaat niet. Gebruik dd/mm/jjjj.',
  fr: "Cette date n'existe pas. Utilisez jj/mm/aaaa.",
  de: 'Dieses Datum gibt es nicht. Verwenden Sie TT/MM/JJJJ.',
  en: 'This date does not exist. Use dd/mm/yyyy.'
}

export default class extends Controller {
  static values = {
    locale: String
  }

  connect() {
    const locale = (this.localeValue || getLocale()).toLowerCase().split(/[-_]/)[0]
    this.invalidText = localeText(INVALID_DATE_TEXT, locale)

    flatpickr(this.element, {
      locale: localeText({ nl: Dutch, fr: French, de: German, en: english }, locale),
      dateFormat: 'd/m/Y',
      altInput: false,
      allowInput: true,
      disableMobile: true,
      parseDate: (text) => parseStrictDate(text),
      errorHandler: () => {}
    })
    this.onBlur = () => {
      const typed = this.element.value
      setTimeout(() => this.checkTyped(typed), 0)
    }
    this.element.addEventListener('blur', this.onBlur)
  }

  disconnect() {
    this.element.removeEventListener('blur', this.onBlur)
    if (this.element._flatpickr) {
      this.element._flatpickr.destroy()
    }
  }

  // After the picker has handled the field: a typed text that is no real date is put back and explained.
  checkTyped(typed) {
    const text = String(typed ?? '').trim()
    if (text === '' || parseStrictDate(text)) {
      this.element.removeAttribute('aria-invalid')
      this.message()?.remove()
      return
    }
    this.element.value = text
    this.element.setAttribute('aria-invalid', 'true')
    let message = this.message()
    if (!message) {
      message = document.createElement('p')
      message.id = `${this.element.id || this.element.name}-invalid-date`
      message.className = 'mt-1 text-xs text-red-700 dark:text-red-300'
      message.setAttribute('data-invalid-date-message', '')
      this.element.insertAdjacentElement('afterend', message)
    }
    message.textContent = this.invalidText
    this.element.setAttribute('aria-describedby', message.id)
  }

  message() {
    const next = this.element.nextElementSibling
    return next && next.hasAttribute && next.hasAttribute('data-invalid-date-message') ? next : null
  }
}
