import { Controller } from "@hotwired/stimulus";

/**
 * Password Visibility Toggle Controller
 *
 * Wraps a password input with an eye icon that toggles between
 * password and text input types.
 *
 * Usage:
 *   <div data-controller="password-visibility">
 *     <input type="password" data-password-visibility-target="input" ... />
 *     <button type="button" data-action="click->password-visibility#toggle" ...>
 *       <svg data-password-visibility-target="iconHidden">...</svg>
 *       <svg data-password-visibility-target="iconVisible" class="hidden">...</svg>
 *     </button>
 *   </div>
 */
export default class extends Controller {
  static targets = ["input", "iconHidden", "iconVisible", "toggle"];

  // The button ships hidden: without scripts it could not work.
  connect() {
    if (this.hasToggleTarget) {
      this.toggleTarget.hidden = false;
      if (this.inputTarget.id) this.toggleTarget.setAttribute("aria-controls", this.inputTarget.id);
      this.updateState();
    }
  }

  toggle() {
    const isPassword = this.inputTarget.type === "password";
    this.inputTarget.type = isPassword ? "text" : "password";

    this.updateState();
  }

  updateState() {
    const visible = this.inputTarget.type === "text";
    if (this.hasIconHiddenTarget) this.iconHiddenTarget.classList.toggle("hidden", visible);
    if (this.hasIconVisibleTarget) this.iconVisibleTarget.classList.toggle("hidden", !visible);
    if (this.hasToggleTarget) {
      const label = visible ? this.toggleTarget.dataset.hideLabel : this.toggleTarget.dataset.showLabel;
      this.toggleTarget.setAttribute("aria-label", label || "");
      this.toggleTarget.setAttribute("aria-pressed", String(visible));
    }
  }
}
