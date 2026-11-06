import { Controller } from '@hotwired/stimulus'
import { withArticleFragment } from '../utils/article_fragment.js'

// On a law's link to its other language version: the article in the address
// bar goes along (utils/article_fragment.js). The href is set when the link is
// followed, so a later hash change counts and the server-rendered link stays
// the plain version link without JavaScript.
export default class extends Controller {
  follow () {
    const href = this.element.getAttribute('href')
    const next = withArticleFragment(href, window.location.hash)
    if (next !== href) this.element.setAttribute('href', next)
  }
}
