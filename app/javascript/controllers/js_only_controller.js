import { Controller } from "@hotwired/stimulus"

// A control that only works with scripts ships with the hidden attribute
// and appears when its controller connects, so a reader without scripts is
// never offered a dead control (10:49 no-JS plan, C.4).
export default class extends Controller {
  connect() {
    this.element.hidden = false
  }
}
