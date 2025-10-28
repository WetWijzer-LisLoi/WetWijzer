/**
 * Clipboard Controller
 *
 * Provides a reusable way to copy the current page URL with an optional
 * hash fragment to the clipboard and give user feedback via the title
 * attribute.
 *
 * Usage in HTML:
 * <button
 *   data-controller="clipboard"
 *   data-action="click->clipboard#copy"
 *   data-clipboard-fragment-value="art-1"
 *   data-clipboard-copied-label-value="Lien copié!"
 *   title="Copier le lien"
 * >
 *   ...
 * </button>
 */
import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static values = {
    fragment: String,
    copiedLabel: String,
    // New: allow copying arbitrary text
    text: String,
    sourceSelector: String
  };

  // Show toast notification
  showToast(message) {
    // Remove any existing toasts
    const existingToast = document.querySelector('.clipboard-toast');
    if (existingToast) {
      existingToast.remove();
    }

    // Create toast element
    const toast = document.createElement('div');
    toast.className = 'clipboard-toast fixed bottom-6 left-1/2 -translate-x-1/2 z-[9999] px-4 py-2 bg-gray-900 dark:bg-gray-100 text-white dark:text-gray-900 text-sm font-medium rounded-lg shadow-lg animate-fade-in-up';
    toast.textContent = message;
    toast.setAttribute('role', 'status');
    toast.setAttribute('aria-live', 'polite');

    document.body.appendChild(toast);

    // Remove after 2 seconds
    setTimeout(() => {
      toast.classList.add('animate-fade-out');
      setTimeout(() => toast.remove(), 300);
    }, 2000);
  }

  copy(event) {
    // Prevent default anchor navigation so clicking the copy icon doesn't scroll/jump
    try {
      event?.preventDefault?.();
      event?.stopPropagation?.();
    } catch (_) {}
    const fragment = this.hasFragmentValue ? this.fragmentValue : this.element.dataset.clipboardFragment;
    // Preserve current query string (e.g., language_id) when building the URL
    const base = window.location.origin + window.location.pathname + window.location.search;
    const url = fragment ? `${base}#${fragment}` : base;

    const button = event?.currentTarget || this.element;
    const originalTitle = button?.getAttribute?.("title") || "";
    const copied = this.hasCopiedLabelValue ? this.copiedLabelValue : (button?.getAttribute?.("data-copied-label") || "Copied!");

    const showFeedback = () => {
      if (!button) return;
      button.setAttribute("title", copied);
      button.setAttribute("aria-label", copied);
      
      // Show toast notification
      this.showToast(copied);
      
      setTimeout(() => {
        button.setAttribute("title", originalTitle);
        button.setAttribute("aria-label", originalTitle);
      }, 2000);
    };

    const fallbackCopy = (text) => {
      try {
        const textarea = document.createElement("textarea");
        textarea.value = text;
        // Prevent scrolling on iOS
        textarea.style.position = "fixed";
        textarea.style.top = "-9999px";
        textarea.style.opacity = "0";
        document.body.appendChild(textarea);
        textarea.focus();
        textarea.select();
        const ok = document.execCommand("copy");
        document.body.removeChild(textarea);
        if (ok) showFeedback();
      } catch (_) {
        // Last resort: do nothing; avoid throwing
      }
    };

    if (navigator?.clipboard?.writeText) {
      navigator.clipboard.writeText(url).then(showFeedback).catch(() => fallbackCopy(url));
    } else {
      fallbackCopy(url);
    }
  }

  // New action: copy plain text from a provided value or a DOM source selector
  copyText(event) {
    try {
      event?.preventDefault?.();
      event?.stopPropagation?.();
    } catch (_) {}

    const button = event?.currentTarget || this.element;
    const originalTitle = button?.getAttribute?.("title") || "";
    const copied = this.hasCopiedLabelValue
      ? this.copiedLabelValue
      : button?.getAttribute?.("data-copied-label") || "Copied!";

    const showFeedback = () => {
      if (!button) return;
      button.setAttribute("title", copied);
      button.setAttribute("aria-label", copied);
      
      // Show toast notification
      this.showToast(copied);
      
      setTimeout(() => {
        button.setAttribute("title", originalTitle);
        button.setAttribute("aria-label", originalTitle);
      }, 2000);
    };

    const fallbackCopy = (text) => {
      try {
        const textarea = document.createElement("textarea");
        textarea.value = text;
        textarea.style.position = "fixed";
        textarea.style.top = "-9999px";
        textarea.style.opacity = "0";
        document.body.appendChild(textarea);
        textarea.focus();
        textarea.select();
        const ok = document.execCommand("copy");
        document.body.removeChild(textarea);
        if (ok) showFeedback();
      } catch (_) {
        // no-op
      }
    };

    // Determine text to copy
    let textToCopy = null;
    if (this.hasTextValue) {
      textToCopy = this.textValue;
    } else if (this.hasSourceSelectorValue) {
      try {
        const node = document.querySelector(this.sourceSelectorValue);
        if (node) {
          // innerText preserves visual text, ignoring hidden controls/icons
          textToCopy = (node.innerText || "").trim();
        }
      } catch (_) {
        // invalid selector, ignore
      }
    }

    if (!textToCopy) return; // nothing to copy

    if (navigator?.clipboard?.writeText) {
      navigator.clipboard.writeText(textToCopy).then(showFeedback).catch(() => fallbackCopy(textToCopy));
    } else {
      fallbackCopy(textToCopy);
    }
  }

  // Copy clean text (without references) from a DOM source selector
  // Strips the references section (everything after "----") from the article text
  copyCleanText(event) {
    try {
      event?.preventDefault?.();
      event?.stopPropagation?.();
    } catch (_) {}

    const button = event?.currentTarget || this.element;
    const originalTitle = button?.getAttribute?.("title") || "";
    const copied = this.hasCopiedLabelValue
      ? this.copiedLabelValue
      : button?.getAttribute?.("data-copied-label") || "Copied!";

    const showFeedback = () => {
      if (!button) return;
      button.setAttribute("title", copied);
      button.setAttribute("aria-label", copied);
      this.showToast(copied);
      setTimeout(() => {
        button.setAttribute("title", originalTitle);
        button.setAttribute("aria-label", originalTitle);
      }, 2000);
    };

    const fallbackCopy = (text) => {
      try {
        const textarea = document.createElement("textarea");
        textarea.value = text;
        textarea.style.position = "fixed";
        textarea.style.top = "-9999px";
        textarea.style.opacity = "0";
        document.body.appendChild(textarea);
        textarea.focus();
        textarea.select();
        const ok = document.execCommand("copy");
        document.body.removeChild(textarea);
        if (ok) showFeedback();
      } catch (_) {
        // no-op
      }
    };

    // Get text from source selector
    let textToCopy = null;
    if (this.hasSourceSelectorValue) {
      try {
        const node = document.querySelector(this.sourceSelectorValue);
        if (node) {
          // Clone the node to manipulate without affecting the DOM
          const clone = node.cloneNode(true);
          
          // Remove the references section (has class 'references-section')
          const refsSection = clone.querySelector('.references-section');
          if (refsSection) {
            refsSection.remove();
          }
          
          // Remove inline reference markers (class 'ref-marker') like [1], [1 ...]1
          clone.querySelectorAll('.ref-marker').forEach(ref => ref.remove());
          
          // Remove modification markers like <Wijziging ...>
          clone.querySelectorAll('.modification-marker').forEach(marker => marker.remove());
          
          // Remove domain tags like <W ...>, <KB ...>, <L ...>
          clone.querySelectorAll('.domain-tag').forEach(tag => tag.remove());
          
          // Insert paragraph markers before block elements to preserve structure
          // This ensures <br><br>, <p>, <div> etc. become proper newlines
          clone.querySelectorAll('br').forEach(br => {
            br.insertAdjacentText('beforebegin', '\n');
          });
          clone.querySelectorAll('p, div').forEach(el => {
            el.insertAdjacentText('beforebegin', '\n');
            el.insertAdjacentText('afterend', '\n');
          });
          
          // Get the text content
          let rawText = clone.innerText || "";
          
          // Citation-ready formatting:
          // 1. Replace tabs with spaces
          // 2. Collapse multiple spaces to single space (within lines)
          // 3. Preserve paragraph breaks (single newlines between paragraphs)
          // 4. Remove empty lines but keep paragraph structure
          textToCopy = rawText
            .replace(/\t/g, ' ')                    // Tabs to spaces
            .split('\n')
            .map(line => line.replace(/ +/g, ' ').trim())  // Collapse spaces, trim
            .filter((line, i, arr) => {
              // Keep non-empty lines
              if (line) return true;
              // Keep one empty line between paragraphs (if previous line was not empty)
              if (i > 0 && arr[i-1]) return true;
              return false;
            })
            .join('\n')
            .replace(/\n{3,}/g, '\n\n')  // Max 2 consecutive newlines
            .trim();
        }
      } catch (_) {
        // invalid selector, ignore
      }
    }

    if (!textToCopy) return;

    if (navigator?.clipboard?.writeText) {
      navigator.clipboard.writeText(textToCopy).then(showFeedback).catch(() => fallbackCopy(textToCopy));
    } else {
      fallbackCopy(textToCopy);
    }
  }

  // Copy all articles and section headings in display order
  copyAllArticles(event) {
    try {
      event?.preventDefault?.();
      event?.stopPropagation?.();
    } catch (_) {}

    const button = event?.currentTarget || this.element;
    const originalTitle = button?.getAttribute?.("title") || "";
    const copied = this.hasCopiedLabelValue
      ? this.copiedLabelValue
      : button?.getAttribute?.("data-copied-label") || "Copied!";

    const showFeedback = () => {
      if (!button) return;
      button.setAttribute("title", copied);
      button.setAttribute("aria-label", copied);
      
      // Show toast notification
      this.showToast(copied);
      
      setTimeout(() => {
        button.setAttribute("title", originalTitle);
        button.setAttribute("aria-label", originalTitle);
      }, 2000);
    };

    const fallbackCopy = (text) => {
      try {
        const textarea = document.createElement("textarea");
        textarea.value = text;
        textarea.style.position = "fixed";
        textarea.style.top = "-9999px";
        textarea.style.opacity = "0";
        document.body.appendChild(textarea);
        textarea.focus();
        textarea.select();
        const ok = document.execCommand("copy");
        document.body.removeChild(textarea);
        if (ok) showFeedback();
      } catch (_) {
        // no-op
      }
    };

    // Find the articles container
    const articlesContainer = document.getElementById('tekst');
    if (!articlesContainer) return;

    // Collect all text in display order
    const textParts = [];
    
    // Add extraction date and law title at the top
    const lawTitleElement = document.querySelector('[data-law-title]');
    if (lawTitleElement) {
      const extractionDate = lawTitleElement.dataset.extractionDate;
      if (extractionDate) {
        textParts.push(`Geraadpleegd op: ${extractionDate}\n`);
      }
      const lawTitle = lawTitleElement.innerText.trim();
      if (lawTitle) {
        textParts.push(lawTitle + '\n' + '='.repeat(80) + '\n');
      }
    }
    
    // Build table of contents first
    const tocParts = [];
    const sectionHeadings = articlesContainer.querySelectorAll('.section-heading h2');
    if (sectionHeadings.length > 0) {
      tocParts.push('\n' + '='.repeat(80) + '\nINHOUD\n' + '='.repeat(80) + '\n');
      sectionHeadings.forEach((heading) => {
        const headingText = heading.innerText.trim();
        if (headingText) {
          tocParts.push(headingText);
        }
      });
      tocParts.push('\n');
    }
    textParts.push(tocParts.join('\n'));
    
    // Find all articles and section headings in order
    const elements = articlesContainer.querySelectorAll('.section-heading h2, article');
    
    elements.forEach((element) => {
      if (element.matches('.section-heading h2')) {
        // Section heading
        const headingText = element.innerText.trim();
        if (headingText) {
          textParts.push('\n' + '='.repeat(80) + '\n' + headingText + '\n' + '='.repeat(80) + '\n');
        }
      } else if (element.matches('article')) {
        // Article - find the article title and text
        const titleElement = element.querySelector('h3, strong');
        const title = titleElement ? titleElement.innerText.trim() : '';
        
        // Find article text container (skip copy buttons and other UI)
        const textContainer = element.querySelector('[id^="article-text-"]');
        const articleText = textContainer ? textContainer.innerText.trim() : '';
        
        if (title && articleText) {
          textParts.push(`${title}\n${articleText}\n`);
        } else if (articleText) {
          textParts.push(`${articleText}\n`);
        }
      }
    });

    const fullText = textParts.join('\n');
    
    if (!fullText.trim()) return; // nothing to copy

    if (navigator?.clipboard?.writeText) {
      navigator.clipboard.writeText(fullText).then(showFeedback).catch(() => fallbackCopy(fullText));
    } else {
      fallbackCopy(fullText);
    }
  }

  // Copy all articles as citation (clean text without references, collapsed whitespace)
  copyAllArticlesCitation(event) {
    try {
      event?.preventDefault?.();
      event?.stopPropagation?.();
    } catch (_) {}

    const button = event?.currentTarget || this.element;
    const originalTitle = button?.getAttribute?.("title") || "";
    const copied = this.hasCopiedLabelValue
      ? this.copiedLabelValue
      : button?.getAttribute?.("data-copied-label") || "Copied!";

    const showFeedback = () => {
      if (!button) return;
      button.setAttribute("title", copied);
      button.setAttribute("aria-label", copied);
      this.showToast(copied);
      setTimeout(() => {
        button.setAttribute("title", originalTitle);
        button.setAttribute("aria-label", originalTitle);
      }, 2000);
    };

    const fallbackCopy = (text) => {
      try {
        const textarea = document.createElement("textarea");
        textarea.value = text;
        textarea.style.position = "fixed";
        textarea.style.top = "-9999px";
        textarea.style.opacity = "0";
        document.body.appendChild(textarea);
        textarea.focus();
        textarea.select();
        const ok = document.execCommand("copy");
        document.body.removeChild(textarea);
        if (ok) showFeedback();
      } catch (_) {
        // no-op
      }
    };

    // Helper to clean text for citation (collapse whitespace, preserve paragraphs)
    const cleanForCitation = (text) => {
      return text
        .replace(/\t/g, ' ')
        .split('\n')
        .map(line => line.replace(/ +/g, ' ').trim())
        .filter((line, i, arr) => {
          if (line) return true;
          if (i > 0 && arr[i-1]) return true;
          return false;
        })
        .join('\n')
        .replace(/\n{3,}/g, '\n\n')
        .trim();
    };

    // Helper to get clean article text (without references/markers)
    const getCleanArticleText = (container) => {
      if (!container) return '';
      
      const clone = container.cloneNode(true);
      
      // Remove references section
      const refsSection = clone.querySelector('.references-section');
      if (refsSection) refsSection.remove();
      
      // Remove markers
      clone.querySelectorAll('.ref-marker').forEach(el => el.remove());
      clone.querySelectorAll('.modification-marker').forEach(el => el.remove());
      clone.querySelectorAll('.domain-tag').forEach(el => el.remove());
      
      // Insert newlines for block elements
      clone.querySelectorAll('br').forEach(br => br.insertAdjacentText('beforebegin', '\n'));
      clone.querySelectorAll('p, div').forEach(el => {
        el.insertAdjacentText('beforebegin', '\n');
        el.insertAdjacentText('afterend', '\n');
      });
      
      return cleanForCitation(clone.innerText || '');
    };

    // Find the articles container
    const articlesContainer = document.getElementById('tekst');
    if (!articlesContainer) return;

    // Collect all text in display order
    const textParts = [];
    
    // Add extraction date and law title at the top
    const lawTitleElement = document.querySelector('[data-law-title]');
    if (lawTitleElement) {
      const extractionDate = lawTitleElement.dataset.extractionDate;
      if (extractionDate) {
        textParts.push(`Geraadpleegd op: ${extractionDate}`);
      }
      const lawTitle = lawTitleElement.innerText.trim();
      if (lawTitle) {
        textParts.push(lawTitle + '\n');
      }
    }
    
    // Find all articles and section headings in order
    const elements = articlesContainer.querySelectorAll('.section-heading h2, article');
    
    elements.forEach((element) => {
      if (element.matches('.section-heading h2')) {
        // Section heading
        const headingText = element.innerText.trim();
        if (headingText) {
          textParts.push('\n' + headingText + '\n');
        }
      } else if (element.matches('article')) {
        // Article - find the article title and text
        const titleElement = element.querySelector('h3, strong');
        const title = titleElement ? titleElement.innerText.trim() : '';
        
        // Find article text container and get clean text
        const textContainer = element.querySelector('[id^="article-text-"]');
        const articleText = getCleanArticleText(textContainer);
        
        if (title && articleText) {
          textParts.push(`${title}\n${articleText}\n`);
        } else if (articleText) {
          textParts.push(`${articleText}\n`);
        }
      }
    });

    const fullText = textParts.join('\n').replace(/\n{3,}/g, '\n\n').trim();
    
    if (!fullText) return;

    if (navigator?.clipboard?.writeText) {
      navigator.clipboard.writeText(fullText).then(showFeedback).catch(() => fallbackCopy(fullText));
    } else {
      fallbackCopy(fullText);
    }
  }

  // Copy compare view articles (two-column NL/FR format)
  copyCompareArticles(event) {
    try {
      event?.preventDefault?.();
      event?.stopPropagation?.();
    } catch (_) {}

    const button = event?.currentTarget || this.element;
    const originalTitle = button?.getAttribute?.("title") || "";
    const copied = this.hasCopiedLabelValue
      ? this.copiedLabelValue
      : button?.getAttribute?.("data-copied-label") || "Copied!";

    const showFeedback = () => {
      if (!button) return;
      button.setAttribute("title", copied);
      button.setAttribute("aria-label", copied);
      this.showToast(copied);
      setTimeout(() => {
        button.setAttribute("title", originalTitle);
        button.setAttribute("aria-label", originalTitle);
      }, 2000);
    };

    const fallbackCopy = (text) => {
      try {
        const textarea = document.createElement("textarea");
        textarea.value = text;
        textarea.style.position = "fixed";
        textarea.style.top = "-9999px";
        textarea.style.opacity = "0";
        document.body.appendChild(textarea);
        textarea.focus();
        textarea.select();
        const ok = document.execCommand("copy");
        document.body.removeChild(textarea);
        if (ok) showFeedback();
      } catch (_) {
        // no-op
      }
    };

    // Find all article rows in the compare view
    const articleRows = document.querySelectorAll('.flex.gap-2.mb-1');
    if (!articleRows.length) return;

    // Determine column order from header
    const headers = document.querySelectorAll('.flex.gap-2.mb-2.sticky h2');
    const leftLang = headers[0]?.innerText?.match(/\((\w+)\)/)?.[1] || 'NL';
    const rightLang = headers[1]?.innerText?.match(/\((\w+)\)/)?.[1] || 'FR';

    const textParts = [];
    
    // Add date and header
    const isFrench = document.documentElement.lang === 'fr';
    const dateLabel = isFrench ? 'Consulté le' : 'Geraadpleegd op';
    textParts.push(`${dateLabel}: ${new Date().toLocaleDateString('nl-BE')}`);
    textParts.push(`\n${leftLang} / ${rightLang}\n${'='.repeat(80)}\n`);

    // Process each row
    articleRows.forEach((row) => {
      const cells = row.querySelectorAll('.flex-1');
      if (cells.length < 2) return;

      const leftText = cells[0]?.innerText?.trim() || '-';
      const rightText = cells[1]?.innerText?.trim() || '-';

      // Format as two columns with separator
      textParts.push(`[${leftLang}] ${leftText}`);
      textParts.push(`[${rightLang}] ${rightText}`);
      textParts.push('---');
    });

    const fullText = textParts.join('\n').replace(/\n{3,}/g, '\n\n').trim();
    
    if (!fullText) return;

    if (navigator?.clipboard?.writeText) {
      navigator.clipboard.writeText(fullText).then(showFeedback).catch(() => fallbackCopy(fullText));
    } else {
      fallbackCopy(fullText);
    }
  }

  // Copy compare view articles (citation mode - without references)
  copyCompareArticlesCitation(event) {
    try {
      event?.preventDefault?.();
      event?.stopPropagation?.();
    } catch (_) {}

    const button = event?.currentTarget || this.element;
    const originalTitle = button?.getAttribute?.("title") || "";
    const copied = this.hasCopiedLabelValue
      ? this.copiedLabelValue
      : button?.getAttribute?.("data-copied-label") || "Copied!";

    const showFeedback = () => {
      if (!button) return;
      button.setAttribute("title", copied);
      button.setAttribute("aria-label", copied);
      this.showToast(copied);
      setTimeout(() => {
        button.setAttribute("title", originalTitle);
        button.setAttribute("aria-label", originalTitle);
      }, 2000);
    };

    const fallbackCopy = (text) => {
      try {
        const textarea = document.createElement("textarea");
        textarea.value = text;
        textarea.style.position = "fixed";
        textarea.style.top = "-9999px";
        textarea.style.opacity = "0";
        document.body.appendChild(textarea);
        textarea.focus();
        textarea.select();
        const ok = document.execCommand("copy");
        document.body.removeChild(textarea);
        if (ok) showFeedback();
      } catch (_) {
        // no-op
      }
    };

    // Helper to clean text for citation (remove references)
    const cleanForCitation = (text) => {
      if (!text) return '-';
      return text
        .replace(/\[\d+\s*\]\d+/g, '')  // Remove [1 ]1 style markers
        .replace(/\[\d+\]/g, '')         // Remove [1] style markers
        .replace(/\(\d+\)<[^>]*>/g, '')  // Remove (1)<...> style markers
        .replace(/<[^>]+>/g, '')         // Remove any HTML tags
        .replace(/\s+/g, ' ')            // Collapse whitespace
        .trim() || '-';
    };

    // Find all article rows in the compare view
    const articleRows = document.querySelectorAll('.flex.gap-2.mb-1');
    if (!articleRows.length) return;

    // Determine column order from header
    const headers = document.querySelectorAll('.flex.gap-2.mb-2.sticky h2');
    const leftLang = headers[0]?.innerText?.match(/\((\w+)\)/)?.[1] || 'NL';
    const rightLang = headers[1]?.innerText?.match(/\((\w+)\)/)?.[1] || 'FR';

    const textParts = [];
    
    // Add date and header
    const isFrench = document.documentElement.lang === 'fr';
    const dateLabel = isFrench ? 'Consulté le' : 'Geraadpleegd op';
    textParts.push(`${dateLabel}: ${new Date().toLocaleDateString('nl-BE')}`);
    textParts.push(`\n${leftLang} / ${rightLang} (${isFrench ? 'citation' : 'citaat'})\n${'='.repeat(80)}\n`);

    // Process each row
    articleRows.forEach((row) => {
      const cells = row.querySelectorAll('.flex-1');
      if (cells.length < 2) return;

      const leftText = cleanForCitation(cells[0]?.innerText?.trim());
      const rightText = cleanForCitation(cells[1]?.innerText?.trim());

      // Format as two columns with separator
      textParts.push(`[${leftLang}] ${leftText}`);
      textParts.push(`[${rightLang}] ${rightText}`);
      textParts.push('---');
    });

    const fullText = textParts.join('\n').replace(/\n{3,}/g, '\n\n').trim();
    
    if (!fullText) return;

    if (navigator?.clipboard?.writeText) {
      navigator.clipboard.writeText(fullText).then(showFeedback).catch(() => fallbackCopy(fullText));
    } else {
      fallbackCopy(fullText);
    }
  }
}
