/**
 * Copy Reference Controller
 * 
 * Provides one-click copy of formatted law citations in multiple formats.
 * 
 * Formats:
 * - full: "artikel 1134 van het Burgerlijk Wetboek (BS 1804-03-21)"
 * - short: "Art. 1134 BW"
 * - legal: "BW art. 1134, §2"
 * - numac: "NUMAC 2024001234"
 * 
 * @example
 * <div data-controller="copy-reference"
 *      data-copy-reference-numac-value="2024001234"
 *      data-copy-reference-title-value="Burgerlijk Wetboek"
 *      data-copy-reference-abbreviation-value="BW"
 *      data-copy-reference-date-value="1804-03-21">
 *   <button data-action="click->copy-reference#copyFull">Copy full</button>
 * </div>
 */
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu", "button"]
  static values = {
    numac: String,
    title: String,
    abbreviation: String,
    date: String,
    article: String,
    paragraph: String
  }

  connect() {
    // Close menu when clicking outside
    this.closeOnClickOutside = this.closeOnClickOutside.bind(this)
    document.addEventListener('click', this.closeOnClickOutside)
    
    // Load preferred format from localStorage
    this.preferredFormat = localStorage.getItem('wetwijzer_copy_format') || 'full'
  }

  disconnect() {
    document.removeEventListener('click', this.closeOnClickOutside)
  }

  toggle(event) {
    event?.preventDefault?.()
    event?.stopPropagation?.()
    
    if (this.hasMenuTarget) {
      const isHidden = this.menuTarget.classList.contains('hidden')
      this.menuTarget.classList.toggle('hidden')
      
      if (this.hasButtonTarget) {
        this.buttonTarget.setAttribute('aria-expanded', isHidden ? 'true' : 'false')
      }
    }
  }

  closeOnClickOutside(event) {
    if (!this.element.contains(event.target) && this.hasMenuTarget) {
      this.menuTarget.classList.add('hidden')
      if (this.hasButtonTarget) {
        this.buttonTarget.setAttribute('aria-expanded', 'false')
      }
    }
  }

  // Copy using last preferred format (for quick copy button)
  copyPreferred(event) {
    event?.preventDefault?.()
    const format = this.preferredFormat || 'full'
    
    switch (format) {
      case 'short': this.copyShort(event); break
      case 'legal': this.copyLegal(event); break
      case 'numac': this.copyNumac(event); break
      case 'url': this.copyUrl(event); break
      default: this.copyFull(event)
    }
  }

  copyFull(event) {
    event?.preventDefault?.()
    const text = this.buildFullCitation()
    this.copyToClipboard(text)
    this.savePreferredFormat('full')
  }

  copyShort(event) {
    event?.preventDefault?.()
    const text = this.buildShortCitation()
    this.copyToClipboard(text)
    this.savePreferredFormat('short')
  }

  copyLegal(event) {
    event?.preventDefault?.()
    const text = this.buildLegalCitation()
    this.copyToClipboard(text)
    this.savePreferredFormat('legal')
  }

  copyNumac(event) {
    event?.preventDefault?.()
    const text = `NUMAC ${this.numacValue}`
    this.copyToClipboard(text)
    this.savePreferredFormat('numac')
  }

  copyUrl(event) {
    event?.preventDefault?.()
    const text = window.location.href
    this.copyToClipboard(text)
    this.savePreferredFormat('url')
  }

  savePreferredFormat(format) {
    this.preferredFormat = format
    localStorage.setItem('wetwijzer_copy_format', format)
  }

  // Build citation formats
  
  buildFullCitation() {
    const parts = []
    
    if (this.hasArticleValue && this.articleValue) {
      const articleWord = this.isFrench ? "l'article" : "artikel"
      parts.push(`${articleWord} ${this.articleValue}`)
      
      if (this.hasParagraphValue && this.paragraphValue) {
        parts.push(`§ ${this.paragraphValue}`)
      }
      
      const ofWord = this.isFrench ? "du" : "van het"
      parts.push(ofWord)
    }
    
    parts.push(this.titleValue || this.numacValue)
    
    if (this.hasDateValue && this.dateValue) {
      const bsLabel = this.isFrench ? "MB" : "BS"
      parts.push(`(${bsLabel} ${this.formatDate(this.dateValue)})`)
    }
    
    return parts.join(' ')
  }

  buildShortCitation() {
    const parts = []
    
    if (this.hasArticleValue && this.articleValue) {
      parts.push(`Art. ${this.articleValue}`)
      
      if (this.hasParagraphValue && this.paragraphValue) {
        parts.push(`§${this.paragraphValue}`)
      }
    }
    
    if (this.hasAbbreviationValue && this.abbreviationValue) {
      parts.push(this.abbreviationValue)
    } else {
      parts.push(this.numacValue)
    }
    
    return parts.join(' ')
  }

  buildLegalCitation() {
    const parts = []
    
    if (this.hasAbbreviationValue && this.abbreviationValue) {
      parts.push(this.abbreviationValue)
    } else {
      parts.push(this.numacValue)
    }
    
    if (this.hasArticleValue && this.articleValue) {
      parts.push(`art. ${this.articleValue}`)
      
      if (this.hasParagraphValue && this.paragraphValue) {
        parts.push(`§${this.paragraphValue}`)
      }
    }
    
    return parts.join(', ').replace(/, §/, ', §')
  }

  formatDate(dateStr) {
    if (!dateStr) return ''
    
    try {
      const date = new Date(dateStr)
      if (isNaN(date.getTime())) return dateStr
      
      const day = date.getDate().toString().padStart(2, '0')
      const month = (date.getMonth() + 1).toString().padStart(2, '0')
      const year = date.getFullYear()
      
      return `${day}-${month}-${year}`
    } catch (e) {
      return dateStr
    }
  }

  copyToClipboard(text) {
    const showFeedback = () => {
      this.showToast(this.isFrench ? "Référence copiée!" : "Referentie gekopieerd!")
      
      // Close menu after copy
      if (this.hasMenuTarget) {
        this.menuTarget.classList.add('hidden')
        if (this.hasButtonTarget) {
          this.buttonTarget.setAttribute('aria-expanded', 'false')
        }
      }
    }

    const fallbackCopy = (text) => {
      try {
        const textarea = document.createElement('textarea')
        textarea.value = text
        textarea.style.position = 'fixed'
        textarea.style.top = '-9999px'
        textarea.style.opacity = '0'
        document.body.appendChild(textarea)
        textarea.focus()
        textarea.select()
        const ok = document.execCommand('copy')
        document.body.removeChild(textarea)
        if (ok) showFeedback()
      } catch (e) {
        console.warn('Copy failed:', e)
      }
    }

    if (navigator?.clipboard?.writeText) {
      navigator.clipboard.writeText(text).then(showFeedback).catch(() => fallbackCopy(text))
    } else {
      fallbackCopy(text)
    }
  }

  showToast(message) {
    const existingToast = document.querySelector('.copy-ref-toast')
    if (existingToast) existingToast.remove()

    const toast = document.createElement('div')
    toast.className = 'copy-ref-toast fixed bottom-6 left-1/2 -translate-x-1/2 z-[9999] px-4 py-2 bg-gray-900 dark:bg-gray-100 text-white dark:text-gray-900 text-sm font-medium rounded-lg shadow-lg animate-fade-in-up'
    toast.textContent = message
    toast.setAttribute('role', 'status')
    toast.setAttribute('aria-live', 'polite')

    document.body.appendChild(toast)

    setTimeout(() => {
      toast.classList.add('animate-fade-out')
      setTimeout(() => toast.remove(), 300)
    }, 2000)
  }

  get isFrench() {
    return document.documentElement.lang === 'fr'
  }
}
