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
    
    // Find all articles and section headings in order
    const elements = articlesContainer.querySelectorAll('.section-heading h2, article');
    
    elements.forEach((element) => {
      if (element.matches('.section-heading h2')) {
        // Section heading
        const headingText = element.innerText.trim();
        if (headingText) {
          textParts.push('\n' + headingText + '\n' + '='.repeat(headingText.length) + '\n');
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
}
