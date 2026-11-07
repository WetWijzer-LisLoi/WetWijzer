import { Controller } from '@hotwired/stimulus'
import { withArticleFragment } from '../utils/article_fragment.js'

// On a law's link to its other language version: the article in the address
// bar goes along (utils/article_fragment.js). The href is set when the link is
// followed, so a later hash change counts and the server-rendered link stays
// the plain version link without JavaScript.
// It also takes the article the page was opened at, on connect: on the comparison, its own contents move the
// address to #compare-row-N, and Back then lost the reader's article (Sol 21:25:18Z). A later article in the
// address replaces it; any other address keeps it.
export default class extends Controller {
  connect () {
    this.follow()
  }

  follow () {
    const href = this.element.getAttribute('href')
    const next = withArticleFragment(href, window.location.hash)
    if (next !== href) this.element.setAttribute('href', next)
  }
}
