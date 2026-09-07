import { Controller } from "@hotwired/stimulus"

// Voter avatar fallback: tries alternate URL, then falls back to initials.
// Usage: data-controller="voter-avatar" on the wrapper containing imgs
export default class extends Controller {
  connect() {
    this.element.querySelectorAll(".voter-avatar-fallback").forEach(img => {
      let attempt = 0
      img.addEventListener("error", function handler() {
        attempt++
        if (attempt === 1) {
          this.src = "https://www.dekamer.be/site/wwwroot/images/cv/PERSON_ID_" + this.dataset.leg + "/" + this.dataset.key + ".jpg"
        } else {
          this.removeEventListener("error", handler)
          this.style.display = "none"
          if (this.nextElementSibling) this.nextElementSibling.style.display = "flex"
        }
      })
    })
  }
}
