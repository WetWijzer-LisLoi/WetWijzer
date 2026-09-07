import { Controller } from "@hotwired/stimulus"

// MP profile photo fallback chain: .jpg → .gif → PERSON_ID → initials.
// Usage: data-controller="mp-photo" on the img element.
export default class extends Controller {
  connect() {
    this._attempt = 0
    this._handler = this._onError.bind(this)
    this.element.addEventListener("error", this._handler)
  }

  disconnect() {
    this.element.removeEventListener("error", this._handler)
  }

  _onError() {
    this._attempt++
    const key = this.element.dataset.key
    const leg = this.element.dataset.leg

    if (this._attempt === 1) {
      this.element.src = `https://www.dekamer.be/site/wwwroot/images/cv/ksegna_${leg}/${key}.gif`
    } else if (this._attempt === 2) {
      this.element.src = `https://www.dekamer.be/site/wwwroot/images/cv/PERSON_ID_${leg}/${key}.jpg`
    } else {
      this.element.removeEventListener("error", this._handler)
      const initial = this.element.dataset.fallbackInitial || "?"
      const color = this.element.dataset.fallbackColor || "#888"
      this.element.parentElement.innerHTML = `<div class="w-full h-full flex items-center justify-center text-white font-bold text-2xl" style="background-color: ${color}">${initial}</div>`
    }
  }
}
