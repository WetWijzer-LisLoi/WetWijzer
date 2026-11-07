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

// The text is taken where flatpickr reads it. When flatpickr cannot read a text (on blur, when focus or a click
// leaves the open calendar, on Enter, or on load) it empties the field, and on a change it dispatches its own "input"
// event on the emptied field. 1.1.22 read the field and 1.1.24 that event, so both kept "" and said nothing (Sol, on
// live 1.1.22 and 1.1.24: 31/02/2026, Tab, an empty field). The text flatpickr rejected is put back once flatpickr
// has finished, and a real date picked or read in the meantime cancels that (Sol 05:28:58Z).
export default class extends Controller {
  static values = {
    locale: String
  }

  connect() {
    const locale = (this.localeValue || getLocale()).toLowerCase().split(/[-_]/)[0]
    this.invalidText = localeText(INVALID_DATE_TEXT, locale)
    this.rejected = null
    this.pending = null

    flatpickr(this.element, {
      locale: localeText({ nl: Dutch, fr: French, de: German, en: english }, locale),
      dateFormat: 'd/m/Y',
      altInput: false,
      allowInput: true,
      disableMobile: true,
      parseDate: (text) => this.read(text),
      errorHandler: () => {},
      onChange: (dates) => { if (dates && dates.length) this.accept() }
    })
    // A field the reader emptied, or holding a real date, loses an old message when focus leaves it.
    this.onBlur = () => setTimeout(() => this.settle(), 0)
    this.element.addEventListener('blur', this.onBlur)
  }

  disconnect() {
    clearTimeout(this.pending)
    this.pending = null
    this.element.removeEventListener('blur', this.onBlur)
    if (this.element._flatpickr) {
      this.element._flatpickr.destroy()
    }
  }

  // flatpickr's parser: only real calendar dates. A text it cannot read is remembered and put back after flatpickr
  // has emptied the field.
  read(text) {
    const date = parseStrictDate(text)
    const value = String(text ?? '').trim()
    if (date || value === '') return date
    this.rejected = value
    clearTimeout(this.pending)
    this.pending = setTimeout(() => this.restore(), 0)
    return date
  }

  // A real date (picked, or typed and read) replaces a rejected text and cancels putting it back.
  accept() {
    clearTimeout(this.pending)
    this.pending = null
    this.checkTyped('')
  }

  restore() {
    this.pending = null
    if (this.rejected !== null) this.checkTyped(this.rejected)
  }

  settle() {
    if (this.pending) return // a rejected text is about to be put back
    const value = String(this.element.value ?? '').trim()
    if (value === '' || parseStrictDate(value)) this.checkTyped(value)
  }

  // A typed text that is no real date is put back and explained; an empty field or a real date clears the error.
  checkTyped(typed) {
    const text = String(typed ?? '').trim()
    if (text === '' || parseStrictDate(text)) {
      this.rejected = null
      this.element.removeAttribute('aria-invalid')
      const message = this.message()
      if (message) {
        this.describedBy(message.id, false)
        message.remove()
      }
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
    this.describedBy(message.id, true)
  }

  // The field's own descriptions stay; only the error's id is added and taken away again (Sol 23:04:42Z: the
  // error replaced them, and a corrected date left the field pointing at the removed error).
  describedBy(id, present) {
    const ids = (this.element.getAttribute('aria-describedby') || '').split(/\s+/).filter(token => token && token !== id)
    if (present) ids.push(id)
    if (ids.length) this.element.setAttribute('aria-describedby', ids.join(' '))
    else this.element.removeAttribute('aria-describedby')
  }

  message() {
    const next = this.element.nextElementSibling
    return next && next.hasAttribute && next.hasAttribute('data-invalid-date-message') ? next : null
  }
}
