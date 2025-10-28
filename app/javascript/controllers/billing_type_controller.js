import { Controller } from "@hotwired/stimulus"

// Toggles visibility of B2B fields based on customer type selection
export default class extends Controller {
    static targets = ["businessFields", "consumerRadio", "businessRadio"]

    connect() {
        this.toggle()
    }

    toggle() {
        const isBusiness = this.businessRadioTarget.checked
        this.businessFieldsTargets.forEach(el => {
            el.classList.toggle("hidden", !isBusiness)
        })
    }
}
