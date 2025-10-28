import { Controller } from "@hotwired/stimulus"

// Bidirectional highlighting between inline references [1 ...]1 and bottom references [1]
export default class extends Controller {
  // Inline reference hover → highlight bottom reference
  highlight() {
    const refNumber = this.element.dataset.refNumber
    if (!refNumber) return

    // Find the bottom reference marker
    const targetMarker = document.querySelector(`[data-ref-target="${refNumber}"]`)
    if (targetMarker) {
      targetMarker.classList.add('reference-highlighted')
      
      const refRow = targetMarker.closest('.text-sm')
      if (refRow) {
        refRow.classList.add('reference-row-highlighted')
      }
    }
  }

  unhighlight() {
    const refNumber = this.element.dataset.refNumber
    if (!refNumber) return

    const targetMarker = document.querySelector(`[data-ref-target="${refNumber}"]`)
    if (targetMarker) {
      targetMarker.classList.remove('reference-highlighted')
      
      const refRow = targetMarker.closest('.text-sm')
      if (refRow) {
        refRow.classList.remove('reference-row-highlighted')
      }
    }
  }

  // Bottom reference hover → highlight all inline references
  highlightInline() {
    const refNumber = this.element.dataset.refNumber
    if (!refNumber) return

    // Find all inline references with this number
    const inlineRefs = document.querySelectorAll(`span.reference[data-ref-number="${refNumber}"]`)
    inlineRefs.forEach(ref => {
      // Don't highlight the bottom reference itself
      if (!ref.hasAttribute('data-ref-target')) {
        ref.classList.add('reference-inline-highlighted')
      }
    })
  }

  unhighlightInline() {
    const refNumber = this.element.dataset.refNumber
    if (!refNumber) return

    const inlineRefs = document.querySelectorAll(`span.reference[data-ref-number="${refNumber}"]`)
    inlineRefs.forEach(ref => {
      ref.classList.remove('reference-inline-highlighted')
    })
  }
}
