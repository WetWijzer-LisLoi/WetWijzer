import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  fire() {
    window.scrollTo({ top: 0, behavior: "auto" })
  }
}
