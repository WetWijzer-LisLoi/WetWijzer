import { Controller } from "@hotwired/stimulus";

/**
 * PII Mask Controller — Admin panel PII reveal/auto-hide
 *
 * Masks emails and IPs by default. On click of the reveal button,
 * fetches the real value from the server (which logs the access),
 * shows it for 30 seconds, then re-masks automatically.
 *
 * Usage (in ERB, via the PiiMaskingHelper):
 *   <span data-controller="pii-mask"
 *         data-pii-mask-user-id-value="42"
 *         data-pii-mask-field-value="email"
 *         data-pii-mask-masked-value="r*****@hotmail.com">
 *     <span data-pii-mask-target="display">r*****@hotmail.com</span>
 *     <button data-action="click->pii-mask#reveal">👁</button>
 *   </span>
 */
export default class extends Controller {
  static targets = ["display"];
  static values = {
    userId: Number,
    field: String,
    masked: String,
  };

  connect() {
    this._timeout = null;
    this._revealed = false;
  }

  disconnect() {
    if (this._timeout) clearTimeout(this._timeout);
  }

  async reveal(event) {
    event.preventDefault();

    // Toggle: if already revealed, re-mask immediately
    if (this._revealed) {
      this._remask();
      return;
    }

    const btn = event.currentTarget;
    btn.textContent = "⏳";
    btn.disabled = true;

    try {
      const csrfToken =
        document.querySelector('meta[name="csrf-token"]')?.content || "";
      const response = await fetch(
        `/admin/users/${this.userIdValue}/reveal_pii`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-CSRF-Token": csrfToken,
          },
          body: JSON.stringify({ field: this.fieldValue }),
        }
      );

      if (!response.ok) throw new Error(`HTTP ${response.status}`);

      const data = await response.json();
      this.displayTarget.textContent = data.value;
      this._revealed = true;
      btn.textContent = "🔒";
      btn.disabled = false;
      btn.title = "Click to re-mask";

      // Auto-hide after 30 seconds
      this._timeout = setTimeout(() => this._remask(), 30000);
    } catch (err) {
      console.error("[PII] Reveal failed:", err);
      btn.textContent = "❌";
      setTimeout(() => {
        btn.textContent = "👁";
        btn.disabled = false;
      }, 2000);
    }
  }

  _remask() {
    if (this._timeout) clearTimeout(this._timeout);
    this.displayTarget.textContent = this.maskedValue;
    this._revealed = false;

    // Reset all reveal buttons in this controller scope
    const btn = this.element.querySelector(".pii-reveal-btn");
    if (btn) {
      btn.textContent = "👁";
      btn.title = `Reveal ${this.fieldValue}`;
      btn.disabled = false;
    }
  }
}
