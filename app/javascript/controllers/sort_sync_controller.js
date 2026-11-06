import { Controller } from '@hotwired/stimulus'

// On a sort chosen in the results menu (laws/_sort_dropdown): the Filters form's own sort select takes the same value.
// The menu reloads only the results frame, so the form outside it kept its old sort, showed it, and put it back on the
// next Search (Sol, on live 1.1.19, 15:37:23Z). A value the select does not offer (relevance) leaves it as it is.
export default class extends Controller {
  apply (event) {
    const value = event.params.value
    if (!value) return
    document.querySelectorAll('select[name="sort"]').forEach(select => {
      if (Array.from(select.options).some(option => option.value === value)) select.value = value
    })
  }
}
