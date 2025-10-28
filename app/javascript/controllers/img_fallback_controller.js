import { Controller } from "@hotwired/stimulus"

// Hides images that fail to load (broken src).
// Usage: data-controller="img-fallback" on img elements, or on a wrapper.
// On a wrapper, it will bind to all child .img-fallback-hide images.
export default class extends Controller {
  connect() {
    const isImg = this.element.tagName === "IMG"
    const images = isImg ? [this.element] : this.element.querySelectorAll(".img-fallback-hide")

    images.forEach(img => {
      img.addEventListener("error", function handler() {
        this.style.display = "none"
        // Show fallback sibling if present
        if (this.nextElementSibling) this.nextElementSibling.style.display = "flex"
        this.removeEventListener("error", handler)
      })
    })
  }
}
