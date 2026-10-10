import { Controller } from "@hotwired/stimulus"
import {
  allArticlesText, citationText, clipboardMessages, compareText, displayedText, fragmentUrl, lawTitle, runCopy
} from "../utils/article_copy.js"

// Copies law text, a law link or a given text, and says whether it worked
// (WW-COPY-01: six of these actions were lost on 2026-06-23 while the views
// kept binding them).
//
//   click->clipboard#copy
//     data-clipboard-text-value="..."          that text (the 2FA backup codes)
//     data-clipboard-fragment-value="art_2"    or this law's URL with #art_2
//   click->clipboard#copyText / #copyCleanText
//     data-clipboard-source-selector-value     one rendered article, as shown or as a citation
//   click->clipboard#copyAllArticles / #copyAllArticlesCitation
//     every heading and article of the law frame the button is in, else of #tekst
//   click->clipboard#copyCompareArticles / #copyCompareArticlesCitation
//     the NL/FR comparison, row by row
//
// data-clipboard-copied-label-value is the success message; the older
// data-clipboard-success-value also replaces the label of a words-only button.
export default class extends Controller {
  static values = {
    text: String,
    success: String,
    fragment: String,
    copiedLabel: String,
    sourceSelector: String,
    root: String,
    leftLabel: String,
    rightLabel: String
  }

  copy(event) {
    return this.run(event, () => {
      if (this.hasFragmentValue && this.fragmentValue) return fragmentUrl(window.location, this.fragmentValue)
      return this.hasTextValue ? this.textValue : ""
    })
  }

  copyText(event) {
    return this.run(event, () => displayedText(this.source()))
  }

  copyCleanText(event) {
    return this.run(event, () => citationText(this.source()))
  }

  copyAllArticles(event) {
    return this.run(event, () => this.allArticles(false))
  }

  copyAllArticlesCitation(event) {
    return this.run(event, () => this.allArticles(true))
  }

  copyCompareArticles(event) {
    return this.run(event, () => this.comparison(false))
  }

  copyCompareArticlesCitation(event) {
    return this.run(event, () => this.comparison(true))
  }

  run(event, produce) {
    event?.preventDefault?.()
    const label = this.hasSuccessValue && this.successValue ? this.successValue : null
    const copied = this.hasCopiedLabelValue && this.copiedLabelValue ? this.copiedLabelValue : label
    return runCopy(this.element, produce, { copied, label })
  }

  source() {
    if (!this.hasSourceSelectorValue || !this.sourceSelectorValue) return null
    try {
      return document.querySelector(this.sourceSelectorValue)
    } catch (_) {
      return null
    }
  }

  // A Justel law's copy buttons sit in its article frame; a Fisconet code's
  // in #tekst, which holds its articles directly.
  scopeRoot() {
    if (this.hasRootValue && this.rootValue) return document.querySelector(this.rootValue)
    return this.element.closest("turbo-frame, #tekst") || document.getElementById("tekst")
  }

  allArticles(citation) {
    const messages = clipboardMessages()
    return allArticlesText(this.scopeRoot(), {
      citation, title: lawTitle(), consultedOn: messages.consultedOn, contents: messages.contents
    })
  }

  comparison(citation) {
    const messages = clipboardMessages()
    return compareText(document, {
      citation,
      left: this.leftLabelValue || "NL",
      right: this.rightLabelValue || "FR",
      consultedOn: messages.consultedOn,
      citationLabel: messages.citation
    })
  }
}
