import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { accepted: Boolean }

  connect() {
    // Show banner if not yet accepted
    if (!this.acceptedValue && !this.hasConsent()) {
      setTimeout(() => {
        this.element.classList.remove('translate-y-full')
      }, 500)
    }
  }

  hasConsent() {
    return document.cookie.includes('cookie_consent=')
  }

  accept() {
    this.setCookie('cookie_consent', 'accepted', 365)
    this.hideBanner()
  }

  decline() {
    // Set persistent cookie to remember decline (same as accept, just different value)
    // User won't be asked again for 365 days
    this.setCookie('cookie_consent', 'declined', 365)
    this.hideBanner()
  }

  hideBanner() {
    this.element.classList.add('translate-y-full')
    setTimeout(() => {
      this.element.remove()
    }, 300)
  }

  setCookie(name, value, days) {
    let expires = ''
    if (days > 0) {
      const date = new Date()
      date.setTime(date.getTime() + (days * 24 * 60 * 60 * 1000))
      expires = '; expires=' + date.toUTCString()
    }
    document.cookie = name + '=' + value + expires + '; path=/; SameSite=Lax'
  }
}
