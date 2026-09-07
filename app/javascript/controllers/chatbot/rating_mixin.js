import { ratingText, scoreLabel, reasonLabel, knownReasonCodes } from "../../services/chatbot_rating_copy"

// The 10-star answer rating control (RAT-005).
//
// Two rules shape everything here:
//
// 1. THE TOKEN LIVES ON THE ANSWER, NOWHERE ELSE. It is written into the
//    rating host's dataset when that answer's metadata is built, and read back
//    with closest(). It is never resolved from conversationHistory - the old
//    Good/Bad handler did that and attributed feedback to the LAST answer,
//    which is wrong the moment a transcript has more than one. It is also
//    never pushed into conversationHistory, because the encrypted snapshot
//    deep-copies that array verbatim and would carry the capability into
//    ciphertext.
//
// 2. THE CONTROL NEVER BLOCKS THE ANSWER. Every failure keeps the user's
//    visible choice, marks it unsaved and offers a retry. It must never
//    remove, re-run or hide an answer, and a low score must never trigger the
//    separate Report flow, which has its own consent dialog.

const MAX_REASONS = 3
const SCORE_MIN = 1
const SCORE_MAX = 10

// How far the open panel has to move to sit fully on screen.
//
// The panel is right-anchored to its trigger, and the trigger sits at the far
// right of the answer's meta row. On a narrow screen that pushes the panel's
// LEFT edge off the viewport: measured at 500px wide, left was -26px and the
// score-1 star straddled the edge - elementFromPoint at its centre returned the
// page behind it, so the lowest scores could not be pressed at all.
//
// The CSS already clamps the panel WIDTH to the viewport, which is precisely
// why this went unseen: nothing overflowed the document, there was no
// horizontal scrollbar, just stars nobody could reach.
export function panelShiftIntoView(rect, viewportWidth, margin = 8) {
  if (!rect || !viewportWidth) return 0

  // Wider than the screen allows: pin to the left margin, since the low scores
  // are the ones the anchor pushes off.
  if (rect.width > viewportWidth - (margin * 2)) return Math.round(margin - rect.left)
  if (rect.left < margin) return Math.ceil(margin - rect.left)
  if (rect.right > viewportWidth - margin) return -Math.ceil(rect.right - (viewportWidth - margin))
  return 0
}

export const ratingMethods = {
  // Called from createMetaElement. Returns the collapsed trigger markup, or
  // an empty string when this answer has no token - eligibility is decided by
  // the server, never inferred from role or analytic_id.
  ratingControlMarkup(ratingToken) {
    if (!ratingToken) return ""

    const label = ratingText("rate", this.languageValue)
    return `
      <span class="text-gray-300 dark:text-gray-600">|</span>
      <span class="ww-rating" data-rating-token="${this._ratingEscape(ratingToken)}">
        <button type="button"
                class="ww-rating-trigger"
                data-action="click->chatbot#toggleRating"
                aria-expanded="false"
                title="${label}">
          <span aria-hidden="true">&#9734;</span>
          <span class="ww-rating-trigger-label">${label}</span>
        </button>
      </span>
    `
  },

  toggleRating(event) {
    const host = event.currentTarget.closest(".ww-rating")
    if (!host) return

    if (host.querySelector(".ww-rating-panel")) {
      this._ratingClose(host)
      return
    }
    this._ratingOpen(host)
  },

  _ratingOpen(host) {
    // One panel at a time. The outside-click handler is a single document
    // listener that gets reassigned to whichever panel opened last, so opening
    // B left A on screen with nothing bound to close it and aria-expanded
    // still true on its trigger. Interactively the capture-phase handler
    // usually closed A first, but "usually" is not a contract - anything that
    // opens a panel without a click (a keyboard action, a test, a future
    // caller) skipped it entirely.
    this._ratingCloseAll(host)

    const language = this.languageValue
    const selected = Number(host.dataset.ratingScore || 0)
    const name = `ww-rating-${Math.random().toString(36).slice(2)}`

    const panel = document.createElement("div")
    panel.className = "ww-rating-panel"
    // Native radios in a fieldset rather than ten clickable SVGs: keyboard
    // arrow behaviour, checked state and accessible naming come for free and
    // cannot drift from the visual state.
    panel.innerHTML = `
      <fieldset class="ww-rating-fieldset">
        <legend class="ww-rating-legend">${ratingText("question", language)}</legend>
        <div class="ww-rating-stars">
          ${this._ratingStars(name, selected, language)}
        </div>
      </fieldset>
      <p class="ww-rating-status" role="status" aria-live="polite"></p>
      <div class="ww-rating-reasons" hidden></div>
    `
    host.appendChild(panel)
    host.querySelector(".ww-rating-trigger")?.setAttribute("aria-expanded", "true")

    panel.addEventListener("change", (event) => {
      const input = event.target
      if (input?.name !== name) return
      this._ratingSubmit(host, Number(input.value))
    })

    panel.addEventListener("keydown", (event) => {
      if (event.key !== "Escape") return
      event.stopPropagation()
      this._ratingClose(host)
      host.querySelector(".ww-rating-trigger")?.focus()
    })

    if (host.dataset.ratingScore) this._ratingRenderReasons(host)
    // A failed save survives the panel being closed and reopened. Without this
    // the only route back to the user's unsaved choice was gone: the status
    // line and its Retry control live inside the panel, and a fresh panel
    // renders neither.
    if (host.dataset.ratingFailed === "1") this._ratingRenderStatus(host, false)
    this._ratingClampIntoView(panel)

    // Focus the chosen star, or the first one when unrated.
    const focusTarget = panel.querySelector("input:checked") || panel.querySelector("input")
    focusTarget?.focus()

    this._ratingBindOutsideClose(host)
  },

  _ratingStars(name, selected, language) {
    let html = ""
    for (let score = SCORE_MIN; score <= SCORE_MAX; score++) {
      const label = scoreLabel(score, language, SCORE_MAX)
      const checked = score === selected ? " checked" : ""
      html += `
        <label class="ww-rating-star">
          <input type="radio" class="sr-only" name="${name}" value="${score}" aria-label="${label}"${checked}>
          <span class="ww-rating-star-glyph" aria-hidden="true">&#9733;</span>
        </label>
      `
    }
    return html
  },

  _ratingClose(host) {
    host.querySelector(".ww-rating-panel")?.remove()
    host.querySelector(".ww-rating-trigger")?.setAttribute("aria-expanded", "false")
    if (this._ratingOutsideHandler) {
      document.removeEventListener("click", this._ratingOutsideHandler, true)
      this._ratingOutsideHandler = null
    }
  },

  // Closes every other open panel, restoring each trigger's expanded state.
  _ratingCloseAll(except = null) {
    document.querySelectorAll(".ww-rating .ww-rating-panel").forEach((panel) => {
      const owner = panel.closest(".ww-rating")
      if (!owner || owner === except) return

      panel.remove()
      owner.querySelector(".ww-rating-trigger")?.setAttribute("aria-expanded", "false")
    })
  },

  _ratingBindOutsideClose(host) {
    if (this._ratingOutsideHandler) {
      document.removeEventListener("click", this._ratingOutsideHandler, true)
    }
    this._ratingOutsideHandler = (event) => {
      if (host.contains(event.target)) return
      this._ratingClose(host)
    }
    document.addEventListener("click", this._ratingOutsideHandler, true)
  },

  // --- submission ---------------------------------------------------------

  _ratingSubmit(host, score) {
    host.dataset.ratingScore = String(score)
    this._ratingRenderTrigger(host)
    this._ratingRenderReasons(host)
    this._ratingQueue(host)
  },

  // PUBLIC on purpose: this name is referenced by a Stimulus data-action, so
  // it must match exactly. It was _ratingToggleReason, which Stimulus could
  // not resolve, leaving the reason chips inert while the stars kept working
  // (those use a manual change listener, not an action).
  ratingToggleReason(event) {
    const button = event.currentTarget
    const host = button.closest(".ww-rating")
    if (!host) return

    const code = button.dataset.reasonCode
    const chosen = this._ratingChosenReasons(host)
    const index = chosen.indexOf(code)
    if (index >= 0) {
      chosen.splice(index, 1)
    } else {
      if (chosen.length >= MAX_REASONS) return
      chosen.push(code)
    }
    host.dataset.ratingReasons = JSON.stringify(chosen)
    this._ratingRenderReasons(host)
    this._ratingQueue(host)
  },

  _ratingChosenReasons(host) {
    try {
      const parsed = JSON.parse(host.dataset.ratingReasons || "[]")
      return Array.isArray(parsed) ? parsed.filter((code) => typeof code === "string") : []
    } catch {
      return []
    }
  },

  // Requests are serialized per answer and coalesced: while one is in flight,
  // later changes replace the pending snapshot rather than queueing behind it,
  // so an out-of-order response can never overwrite the user's final choice.
  _ratingQueue(host) {
    // Monotonic per answer. It is what lets the flush loop tell "this is the
    // snapshot that just failed" from "the user changed their mind while it was
    // failing" - the first must stop and offer Retry, the second must be sent.
    host.dataset.ratingRevision = String(Number(host.dataset.ratingRevision || 0) + 1)
    host.dataset.ratingPending = "1"
    if (host.dataset.ratingInFlight === "1") return

    this._ratingFlush(host)
  },

  async _ratingFlush(host) {
    host.dataset.ratingInFlight = "1"
    try {
      while (host.dataset.ratingPending === "1") {
        host.dataset.ratingPending = "0"
        const score = Number(host.dataset.ratingScore || 0)
        if (!score) break

        const revision = host.dataset.ratingRevision || "0"
        const ok = await this._ratingSend(host, score, this._ratingChosenReasons(host))
        const superseded = host.dataset.ratingRevision !== revision

        // The user changed their mind while this request was in flight, so the
        // response describes a snapshot they have already replaced - whether it
        // succeeded or failed. Painting either verdict would describe the wrong
        // choice, and the newer one still has to go out.
        if (superseded) {
          host.dataset.ratingPending = "1"
          continue
        }

        this._ratingRenderStatus(host, ok)
        if (!ok) {
          // Keep the LATEST snapshot for the retry. Clearing pending at the top
          // of the loop is the right coalescing move on the success path, but on
          // failure it threw the user's choice away: the flag stayed "0",
          // inFlight returned to "0", and nothing was left to send it.
          host.dataset.ratingPending = "1"
          host.dataset.ratingFailed = "1"
          break
        }
        host.dataset.ratingFailed = "0"
      }
    } finally {
      host.dataset.ratingInFlight = "0"
    }
  },

  // The retry the failure message has always promised. It was copy only: a
  // `retry` string existed with no call site anywhere, and the one gesture a
  // user would reach for - clicking the star they already chose - fires no
  // `change` event, so it did nothing at all.
  ratingRetry(event) {
    const host = event.currentTarget.closest(".ww-rating")
    if (!host) return

    event.currentTarget.disabled = true
    // Never starts a second request: _ratingQueue returns immediately while
    // one is in flight, and the pending flag it sets is picked up by the
    // running loop.
    this._ratingQueue(host)
  },

  async _ratingSend(host, score, reasonCodes) {
    const token = host.dataset.ratingToken
    if (!token) return false

    try {
      const response = await fetch("/api/chatbot/rating", {
        method: "PUT",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        // EXACTLY three fields. The browser asserts nothing about the model,
        // the parameters, the language or the answer: all of that is
        // server-observed and would be forgeable if sent from here.
        body: JSON.stringify({ rating_token: token, score, reason_codes: reasonCodes })
      })
      return response.ok
    } catch {
      return false
    }
  },

  // --- rendering ----------------------------------------------------------

  _ratingRenderTrigger(host) {
    const trigger = host.querySelector(".ww-rating-trigger")
    if (!trigger) return

    const score = host.dataset.ratingScore
    if (!score) return

    const label = trigger.querySelector(".ww-rating-trigger-label")
    if (label) label.textContent = `${score}/${SCORE_MAX} · ${ratingText("thanks", this.languageValue)}`
    trigger.classList.add("ww-rating-trigger-rated")
  },

  _ratingRenderReasons(host) {
    const container = host.querySelector(".ww-rating-reasons")
    if (!container) return

    const language = this.languageValue
    const chosen = this._ratingChosenReasons(host)
    const atLimit = chosen.length >= MAX_REASONS
    const codes = this._ratingReasonCodes()

    container.hidden = false
    container.innerHTML = `
      <p class="ww-rating-reason-prompt">${ratingText("reasonPrompt", language)}</p>
      <div class="ww-rating-chips">
        ${codes.map((code) => {
          const pressed = chosen.includes(code)
          // At the limit the chosen chips stay enabled so a user can always
          // deselect; only unchosen ones become unavailable.
          const disabled = atLimit && !pressed ? " disabled" : ""
          return `
            <button type="button"
                    class="ww-rating-chip${pressed ? " ww-rating-chip-on" : ""}"
                    data-action="click->chatbot#ratingToggleReason"
                    data-reason-code="${this._ratingEscape(code)}"
                    aria-pressed="${pressed}"${disabled}>${this._ratingEscape(reasonLabel(code, language))}</button>
          `
        }).join("")}
      </div>
      ${atLimit ? `<p class="ww-rating-limit">${ratingText("maxReasons", language)}</p>` : ""}
    `
    this._ratingClampIntoView(host.querySelector(".ww-rating-panel"))
  },

  // Re-run after anything that changes the panel's size: the reason chips wrap
  // to a different height and width once they appear.
  _ratingClampIntoView(panel) {
    if (!panel?.getBoundingClientRect) return

    panel.style.transform = ''
    const shift = panelShiftIntoView(panel.getBoundingClientRect(), window.innerWidth)
    if (shift) panel.style.transform = `translateX(${shift}px)`
  },

  _ratingRenderStatus(host, ok) {
    const status = host.querySelector(".ww-rating-status")
    if (!status) return

    const language = this.languageValue
    // textContent, then a built element: this text is localized copy, but the
    // status node is inside a panel that also renders server-supplied codes,
    // and building rather than interpolating keeps that impossible to confuse.
    status.textContent = ok ? ratingText("saved", language) : ratingText("notSaved", language)
    status.classList.toggle("ww-rating-status-error", !ok)

    if (ok) return

    // Only ever rendered for the LATEST snapshot: a superseded response never
    // reaches here, and a newer choice made during a failure is sent
    // automatically rather than waiting behind this button.
    const retry = document.createElement("button")
    retry.type = "button"
    retry.className = "ww-rating-retry"
    retry.dataset.action = "click->chatbot#ratingRetry"
    retry.textContent = ratingText("retry", language)
    status.append(" ", retry)
  },

  _ratingReasonCodes() {
    if (this._ratingCodesCache) return this._ratingCodesCache

    // Server-ordered when the page supplies it, otherwise the module's own
    // list. Every step is total: a malformed meta tag must not be able to stop
    // the panel opening, because _ratingOpen throwing here is the ONLY path
    // that leaves a panel on screen with no outside-click handler bound.
    const known = knownReasonCodes()
    let parsed = null
    try {
      parsed = JSON.parse(document.querySelector('meta[name="chatbot-rating-reasons"]')?.content || "null")
    } catch {
      parsed = null
    }

    // Intersected with what this client can actually label. A server-only code
    // is dropped on purpose: rendering a raw code to a user is worse than
    // offering one reason fewer until the localized copy ships.
    const valid = Array.isArray(parsed)
      ? parsed.filter((code) => typeof code === "string" && known.includes(code))
      : []

    this._ratingCodesCache = valid.length ? valid : known
    return this._ratingCodesCache
  },

  _ratingEscape(value) {
    return String(value).replace(/[&<>"']/g, (character) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
    })[character])
  }
}
