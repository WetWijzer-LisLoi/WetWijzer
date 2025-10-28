import { Controller } from "@hotwired/stimulus"

// Bidirectional highlighting between inline references [1 ...]1 and bottom references [1]
export default class extends Controller {
  // Check if highlighting is enabled in localStorage
  isHighlightEnabled() {
    const stored = localStorage.getItem('ww_show_highlight')
    // Default to true if not set
    return stored === null || stored === 'true'
  }

  // Inline reference hover → highlight ALL references with the same number (scoped to current article)
  highlight(event) {
    if (!this.isHighlightEnabled()) return
    
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

    // Find the article container to scope the search - must have data-article-scope
    const articleContainer = this.element.closest('[data-article-scope]')
    if (!articleContainer) return // Don't highlight if not scoped to an article
    
    // If this element has a parent reference with a different number, unhighlight the parent first
    // This handles moving from outer [1] to inner [2]
    const parentRef = this.element.parentElement?.closest('.reference')
    if (parentRef) {
      const parentRefNumber = parentRef.dataset.refNumber
      if (parentRefNumber && parentRefNumber !== refNumber) {
        // Unhighlight the parent reference
        const parentInlineRefs = articleContainer.querySelectorAll(`span.reference[data-ref-number="${parentRefNumber}"]`)
        parentInlineRefs.forEach(ref => {
          ref.classList.remove('reference-inline-highlighted')
        })
        
        const parentRefRows = articleContainer.querySelectorAll(`div[data-ref-number="${parentRefNumber}"].text-sm`)
        parentRefRows.forEach(row => {
          row.classList.remove('reference-row-highlighted')
        })
      }
    }
    
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

    // Find the article container to scope the search - must have data-article-scope
    const articleContainer = this.element.closest('[data-article-scope]')
    if (!articleContainer) return // Don't highlight if not scoped to an article
    
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

    // After unhighlighting, check if we're now hovering a parent reference
    // This handles the case where we move from nested [2] to parent [1]
    const parentRef = this.element.parentElement?.closest('.reference')
    if (parentRef && parentRef.matches(':hover')) {
      const parentRefNumber = parentRef.dataset.refNumber
      if (parentRefNumber && parentRefNumber !== refNumber) {
        // Highlight the parent reference we're now hovering
        const parentInlineRefs = articleContainer.querySelectorAll(`span.reference[data-ref-number="${parentRefNumber}"]`)
        parentInlineRefs.forEach(ref => {
          if (!ref.hasAttribute('data-ref-target')) {
            ref.classList.add('reference-inline-highlighted')
          }
        })
        
        const parentRefRows = articleContainer.querySelectorAll(`div[data-ref-number="${parentRefNumber}"].text-sm`)
        parentRefRows.forEach(row => {
          row.classList.add('reference-row-highlighted')
        })
      }
    }
  }

  // Bottom reference hover → highlight itself AND all inline references (scoped to current article)
  highlightInline(event) {
    if (!this.isHighlightEnabled()) return
    
    const refNumber = this.element.dataset.refNumber
    if (!refNumber) return

    // Find the article container to scope the search - must have data-article-scope
    const articleContainer = this.element.closest('[data-article-scope]')
    if (!articleContainer) return // Don't highlight if not scoped to an article

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

    // Find the article container to scope the search - must have data-article-scope
    const articleContainer = this.element.closest('[data-article-scope]')
    if (!articleContainer) return // Don't highlight if not scoped to an article

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
