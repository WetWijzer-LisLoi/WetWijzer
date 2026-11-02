import { Controller } from "@hotwired/stimulus";

// The contents button of a law's source toolbar. The toolbar sits outside the
// sidebar-toggle controller, so the button asks it through a window event and
// names itself as the trigger. It shows only from md to lg (768 to 1023px):
// below md the mobile dock opens the panel, from lg the sliver at the left
// edge does.
export default class extends Controller {
  toggle() {
    window.dispatchEvent(new CustomEvent("ww:toc-toggle", { detail: { trigger: this.element } }));
  }
}
