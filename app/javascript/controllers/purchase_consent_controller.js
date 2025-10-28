import { Controller } from "@hotwired/stimulus"

// Enables/disables purchase buttons based on withdrawal consent checkbox
export default class extends Controller {
    static targets = ["checkbox", "button"]

    connect() {
        this.toggle()
        // Prevent click navigation when not consented
        this.buttonTargets.forEach(btn => {
            btn.addEventListener("click", (e) => {
                if (!this.checkboxTarget.checked) {
                    e.preventDefault()
                    // Show tooltip briefly on rejected click
                    const tooltip = btn.closest(".purchase-btn-wrap")?.querySelector(".consent-tooltip")
                    if (tooltip) {
                        tooltip.classList.remove("hidden")
                        setTimeout(() => tooltip.classList.add("hidden"), 2500)
                    }
                }
            })

            // Show tooltip on hover when not consented
            const wrap = btn.closest(".purchase-btn-wrap")
            if (wrap) {
                wrap.addEventListener("mouseenter", () => {
                    if (!this.checkboxTarget.checked) {
                        const tooltip = wrap.querySelector(".consent-tooltip")
                        if (tooltip) tooltip.classList.remove("hidden")
                    }
                })
                wrap.addEventListener("mouseleave", () => {
                    const tooltip = wrap.querySelector(".consent-tooltip")
                    if (tooltip) tooltip.classList.add("hidden")
                })
            }
        })
    }

    toggle() {
        const isChecked = this.checkboxTarget.checked
        const tooltips = this.element.querySelectorAll(".consent-tooltip")

        this.buttonTargets.forEach(btn => {
            if (isChecked) {
                btn.classList.remove("bg-gray-400", "text-gray-200", "cursor-not-allowed")
                btn.classList.add("bg-(--accent-600-solid)", "hover:bg-(--accent-700-solid)", "text-white")
            } else {
                btn.classList.add("bg-gray-400", "text-gray-200", "cursor-not-allowed")
                btn.classList.remove("bg-(--accent-600-solid)", "hover:bg-(--accent-700-solid)", "text-white")
            }
        })

        // Hide all tooltips when checked
        if (isChecked) {
            tooltips.forEach(tip => tip.classList.add("hidden"))
        }
    }
}
