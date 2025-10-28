import { Controller } from "@hotwired/stimulus"

// Auto-submit form when a select/input value changes.
// Usage: data-controller="autosubmit" data-action="change->autosubmit#submit"
export default class extends Controller {
  submit() {
    this.element.form?.submit()
  }
}
