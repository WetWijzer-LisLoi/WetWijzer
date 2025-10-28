import { Controller } from "@hotwired/stimulus"

// Bidirectional highlighting between inline references [1 ...]1 and bottom references [1]
export default class extends Controller {
  // Inline reference hover → highlight ALL references with the same number (scoped to current article)
  highlight(event) {
    const refNumber = this.element.dataset.refNumber
    if (!refNumber) return

    // Check if a nested child reference with a different number is currently being hovered
    // This prevents parent references from highlighting when hovering their nested children
    const nestedRefs = this.element.querySelectorAll('.reference')
    for (const nestedRef of nestedRefs) {
      if (nestedRef.matches(':hover') && nestedRef.dataset.refNumber !== refNumber) {
        return // Skip highlighting if hovering a different nested reference
      }
    }

    // Find the article container to scope the search
    const articleContainer = this.element.closest('article, .article, [data-article]') || document.body
    
    // Find and highlight ALL inline references with this number within the same article
    const inlineRefs = articleContainer.querySelectorAll(`span.reference[data-ref-number="${refNumber}"]`)
    inlineRefs.forEach(ref => {
      // Don't highlight the bottom reference itself
      if (!ref.hasAttribute('data-ref-target')) {
        ref.classList.add('reference-inline-highlighted')
      }
    })
    
    // Find and highlight ALL bottom reference rows with this number (including continuation lines)
    const refRows = articleContainer.querySelectorAll(`div[data-ref-number="${refNumber}"].text-sm`)
    refRows.forEach(row => {
      row.classList.add('reference-row-highlighted')
    })
  }

  unhighlight(event) {
    const refNumber = this.element.dataset.refNumber
    if (!refNumber) return

    // Check if we're still hovering a nested child reference - if so, keep parent unhighlighted
    const nestedRefs = this.element.querySelectorAll('.reference')
    for (const nestedRef of nestedRefs) {
      if (nestedRef.matches(':hover') && nestedRef.dataset.refNumber !== refNumber) {
        return // Keep unhighlighted if still hovering a different nested reference
      }
    }

    // Find the article container to scope the search
    const articleContainer = this.element.closest('article, .article, [data-article]') || document.body
    
    // Find and unhighlight ALL inline references with this number within the same article
    const inlineRefs = articleContainer.querySelectorAll(`span.reference[data-ref-number="${refNumber}"]`)
    inlineRefs.forEach(ref => {
      ref.classList.remove('reference-inline-highlighted')
    })
    
    // Find and unhighlight ALL bottom reference rows with this number (including continuation lines)
    const refRows = articleContainer.querySelectorAll(`div[data-ref-number="${refNumber}"].text-sm`)
    refRows.forEach(row => {
      row.classList.remove('reference-row-highlighted')
    })
  }

  // Bottom reference hover → highlight itself AND all inline references (scoped to current article)
  highlightInline(event) {
    const refNumber = this.element.dataset.refNumber
    if (!refNumber) return

    // Find the article container to scope the search
    const articleContainer = this.element.closest('article, .article, [data-article]') || document.body

    // Highlight ALL bottom reference rows with this number (including continuation lines)
    const refRows = articleContainer.querySelectorAll(`div[data-ref-number="${refNumber}"].text-sm`)
    refRows.forEach(row => {
      row.classList.add('reference-row-highlighted')
    })

    // Find and highlight all inline references with this number within the same article
    const inlineRefs = articleContainer.querySelectorAll(`span.reference[data-ref-number="${refNumber}"]`)
    inlineRefs.forEach(ref => {
      // Don't highlight the bottom reference itself
      if (!ref.hasAttribute('data-ref-target')) {
        ref.classList.add('reference-inline-highlighted')
      }
    })
  }

  unhighlightInline(event) {
    const refNumber = this.element.dataset.refNumber
    if (!refNumber) return

    // Find the article container to scope the search
    const articleContainer = this.element.closest('article, .article, [data-article]') || document.body

    // Unhighlight ALL bottom reference rows with this number (including continuation lines)
    const refRows = articleContainer.querySelectorAll(`div[data-ref-number="${refNumber}"].text-sm`)
    refRows.forEach(row => {
      row.classList.remove('reference-row-highlighted')
    })

    // Unhighlight all inline references within the same article
    const inlineRefs = articleContainer.querySelectorAll(`span.reference[data-ref-number="${refNumber}"]`)
    inlineRefs.forEach(ref => {
      ref.classList.remove('reference-inline-highlighted')
    })
  }
}
