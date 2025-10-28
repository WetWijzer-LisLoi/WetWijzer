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
  static targets = ["input", "iconHidden", "iconVisible"];

  toggle() {
    const isPassword = this.inputTarget.type === "password";
    this.inputTarget.type = isPassword ? "text" : "password";

    this.iconHiddenTarget.classList.toggle("hidden", !isPassword);
    this.iconVisibleTarget.classList.toggle("hidden", isPassword);
  }
}
