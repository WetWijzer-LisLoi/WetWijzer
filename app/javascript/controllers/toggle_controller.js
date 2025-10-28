import { Controller } from "@hotwired/stimulus"

// Generic toggle controller: shows/hides a sibling element.
// Usage: data-controller="toggle" on wrapper
//        data-action="click->toggle#toggle" on the button
//        data-toggle-target="content" on the panel to show/hide
export default class extends Controller {
  static targets = ["content"]

  toggle() {
    this.contentTarget.classList.toggle("hidden")
  }
}
