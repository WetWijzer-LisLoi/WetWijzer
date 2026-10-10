import { Controller } from "@hotwired/stimulus"

// Deliberately stateless: opening the tour does not persist a preference or call an API.
export default class extends Controller {
  static targets = ["dialog", "opener", "step", "previous", "next", "body"]

  connect() {
    this.currentStep = 0
    this.isDisconnecting = false
    this.previousBodyOverflow = null
    this.openerTarget.hidden = false
    this.dialogTarget.dataset.siteTourEnhanced = "true"
    this._beforeCache = this.beforeCache.bind(this)
    document.addEventListener("turbo:before-cache", this._beforeCache)
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this._beforeCache)
    this.isDisconnecting = true
    if (this.dialogTarget.open) this.dialogTarget.close()
    this.restorePage()
    this.openerTarget.hidden = true
    delete this.dialogTarget.dataset.siteTourEnhanced
  }

  open() {
    if (this.dialogTarget.open) return
    this.opener = document.activeElement
    this.currentStep = 0
    this.render()
    this.previousBodyOverflow = document.body.style.overflow
    document.body.style.overflow = "hidden"
    this.dialogTarget.showModal()
    this.focusClose()
  }

  close() {
    if (this.dialogTarget.open) {
      this.dialogTarget.close()
      // Native `close` is queued. Restore scrolling/focus synchronously so a
      // rapid reopen cannot inherit the previous modal's locked page state.
      this.closed()
    }
  }

  cancel(event) {
    event.preventDefault()
    this.close()
  }

  closed() {
    // A queued close event can arrive after the visitor reopened the dialog.
    if (this.dialogTarget.open) return
    this.restorePage()
    if (!this.isDisconnecting && this.element.isConnected && this.opener?.isConnected) this.opener.focus({ preventScroll: true })
    this.opener = null
  }

  next() {
    if (this.currentStep === this.stepTargets.length - 1) return this.close()
    this.currentStep += 1
    this.render()
  }

  previous() {
    if (this.currentStep === 0) return
    this.currentStep -= 1
    this.render()
  }

  go(event) {
    const index = Number(event.params.index)
    if (!Number.isInteger(index) || index < 0 || index >= this.stepTargets.length) return
    this.currentStep = index
    this.render()
  }

  keydown(event) {
    if (event.key !== "Tab") return
    const focusable = this.focusableElements()
    if (!focusable.length) return
    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }

  beforeCache() {
    if (this.dialogTarget.open) this.dialogTarget.close()
    this.restorePage()
  }

  render() {
    this.stepTargets.forEach((step, index) => { step.hidden = index !== this.currentStep })
    this.previousTarget.disabled = this.currentStep === 0
    this.nextTarget.textContent = this.currentStep === this.stepTargets.length - 1
      ? this.nextTarget.dataset.siteTourFinishLabel
      : this.nextTarget.dataset.siteTourNextLabel
    this.bodyTarget.scrollTop = 0
  }

  focusClose() {
    this.dialogTarget.querySelector("[data-action~='site-tour#close']")?.focus({ preventScroll: true })
  }

  focusableElements() {
    return Array.from(this.dialogTarget.querySelectorAll("button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])"))
      .filter(element => !element.hidden && element.offsetParent !== null)
  }

  restorePage() {
    if (this.previousBodyOverflow !== null) {
      document.body.style.overflow = this.previousBodyOverflow
      this.previousBodyOverflow = null
    }
  }
}
