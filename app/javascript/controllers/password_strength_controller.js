import { Controller } from "@hotwired/stimulus"

/**
 * Password Strength Controller
 * Shows real-time password strength feedback
 */
export default class extends Controller {
  static targets = ["input", "meter", "text", "requirements"]

  connect() {
    this.requirements = {
      length: { regex: /.{8,}/, text: "8+ characters" },
      uppercase: { regex: /[A-Z]/, text: "Uppercase letter" },
      lowercase: { regex: /[a-z]/, text: "Lowercase letter" },
      number: { regex: /[0-9]/, text: "Number" },
      special: { regex: /[^A-Za-z0-9]/, text: "Special character" }
    }
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
    const labels = ["Very weak", "Weak", "Fair", "Good", "Strong"]
    const widths = ["20%", "40%", "60%", "80%", "100%"]
    
    // Remove all color classes
    this.meterTarget.className = "h-2 rounded-full transition-all duration-300"
    
    if (this.inputTarget.value) {
      this.meterTarget.classList.add(colors[strength])
      this.meterTarget.style.width = widths[strength]
    } else {
      this.meterTarget.style.width = "0%"
    }
    
    if (this.hasTextTarget) {
      this.textTarget.textContent = this.inputTarget.value ? labels[strength] : ""
      this.textTarget.className = `text-xs mt-1 ${colors[strength].replace('bg-', 'text-')}`
    }
  }

  updateRequirements(password) {
    if (!this.hasRequirementsTarget) return
    
    let html = ""
    for (const [key, req] of Object.entries(this.requirements)) {
      const met = req.regex.test(password)
      const icon = met ? "✓" : "○"
      const color = met ? "text-green-600" : "text-gray-400"
      html += `<span class="${color} text-xs mr-3">${icon} ${req.text}</span>`
    }
    this.requirementsTarget.innerHTML = html
  }
}
