import { Controller } from "@hotwired/stimulus"

/**
 * Password Strength Controller
 * Shows real-time password strength feedback
 */
export default class extends Controller {
  static targets = ["input", "meter", "text", "requirements"]
  static values = { labels: Array, requirements: Object, empty: String }

  connect() {
    this.requirements = {
      length: { test: password => password.length >= 8 },
      uppercase: { test: password => /[A-Z]/.test(password) },
      lowercase: { test: password => /[a-z]/.test(password) },
      number: { test: password => /[0-9]/.test(password) },
      special: { test: password => /[^A-Za-z0-9]/.test(password) }
    }
    this.check()
  }

  check() {
    const password = this.inputTarget.value
    const strength = this.calculateStrength(password)
    this.updateMeter(strength)
    this.updateRequirements(password)
  }

  calculateStrength(password) {
    if (!password) return 0
    
    let score = 0
    
    // Length scoring
    if (password.length >= 8) score += 1
    if (password.length >= 12) score += 1
    if (password.length >= 16) score += 1
    
    // Character variety
    if (/[a-z]/.test(password)) score += 1
    if (/[A-Z]/.test(password)) score += 1
    if (/[0-9]/.test(password)) score += 1
    if (/[^A-Za-z0-9]/.test(password)) score += 2
    
    // Normalize to 0-4 scale
    return Math.min(4, Math.floor(score / 2))
  }

  updateMeter(strength) {
    if (!this.hasMeterTarget) return
    
    const colors = ["bg-red-500", "bg-orange-500", "bg-yellow-500", "bg-lime-500", "bg-green-500"]
    const textColors = ["text-red-700 dark:text-red-400", "text-orange-700 dark:text-orange-400", "text-yellow-800 dark:text-yellow-300", "text-lime-800 dark:text-lime-300", "text-green-700 dark:text-green-400"]
    const widths = ["20%", "40%", "60%", "80%", "100%"]
    const label = this.inputTarget.value ? this.labelsValue[strength] : this.emptyValue
    
    // Remove all color classes
    this.meterTarget.className = "h-2 rounded-full transition-all duration-300"
    
    if (this.inputTarget.value) {
      this.meterTarget.classList.add(colors[strength])
      this.meterTarget.style.width = widths[strength]
    } else {
      this.meterTarget.style.width = "0%"
    }
    this.meterTarget.setAttribute("aria-valuenow", this.inputTarget.value ? strength : 0)
    this.meterTarget.setAttribute("aria-valuetext", label || "")
    
    if (this.hasTextTarget) {
      this.textTarget.textContent = this.inputTarget.value ? label : ""
      this.textTarget.className = `text-xs mt-1 ${textColors[strength]}`
    }
  }

  updateRequirements(password) {
    if (!this.hasRequirementsTarget) return
    
    // Translate on the server and create text nodes, never translated HTML.
    this.requirementsTarget.textContent = ""
    for (const [key, req] of Object.entries(this.requirements)) {
      const text = this.requirementsValue[key]
      if (typeof text !== "string") continue
      const met = req.test(password)
      const icon = met ? "✓" : "○"
      const color = met ? "text-green-700 dark:text-green-400" : "text-gray-600 dark:text-gray-400"
      const item = this.requirementsTarget.ownerDocument.createElement("span")
      item.className = `${color} text-xs mr-3`
      item.textContent = `${icon} ${text}`
      this.requirementsTarget.appendChild(item)
    }
  }
}
