import { Controller } from "@hotwired/stimulus"

// Hemicycle SVG highlight: dots + legend items for a political party.
// data-controller="hemicycle-hover" on the wrapper containing both SVG and legend.
// data-hemicycle-hover-mode-value="click" to use click-toggle instead of hover.
export default class extends Controller {
  static values = { mode: { type: String, default: "hover" } }

  connect() {
    this.svg = this.element.querySelector("svg")
    if (!this.svg) return

    this.dots = this.svg.querySelectorAll(".seat-dot")
    this.legendItems = this.element.querySelectorAll("[data-legend-party]")
    this.defaultRadius = this.dots[0]?.getAttribute("r") || "5"
    this._selected = null

    if (this.modeValue === "click") {
      this._onSvgClick = this._handleSvgClick.bind(this)
      this.svg.addEventListener("click", this._onSvgClick)

      this._legendClickHandlers = []
      this.legendItems.forEach(el => {
        el.style.cursor = "pointer"
        const handler = (e) => {
          e.preventDefault()
          const party = el.getAttribute("data-legend-party")
          party === this._selected ? this._clear() : this._highlight(party)
        }
        el.addEventListener("click", handler)
        this._legendClickHandlers.push({ el, fn: handler })
      })
    } else {
      // Hover mode (default)
      this._onSvgOver = this._handleSvgOver.bind(this)
      this._onSvgOut  = this._handleSvgOut.bind(this)
      this.svg.addEventListener("mouseover", this._onSvgOver)
      this.svg.addEventListener("mouseout", this._onSvgOut)

      this._legendEnterHandlers = []
      this._legendLeaveHandlers = []
      this.legendItems.forEach(el => {
        const enter = () => this._highlight(el.getAttribute("data-legend-party"))
        const leave = () => this._clear()
        el.addEventListener("mouseenter", enter)
        el.addEventListener("mouseleave", leave)
        this._legendEnterHandlers.push({ el, fn: enter })
        this._legendLeaveHandlers.push({ el, fn: leave })
      })
    }
  }

  disconnect() {
    if (!this.svg) return

    if (this.modeValue === "click") {
      this.svg.removeEventListener("click", this._onSvgClick)
      this._legendClickHandlers?.forEach(({ el, fn }) => el.removeEventListener("click", fn))
    } else {
      this.svg.removeEventListener("mouseover", this._onSvgOver)
      this.svg.removeEventListener("mouseout", this._onSvgOut)
      this._legendEnterHandlers?.forEach(({ el, fn }) => el.removeEventListener("mouseenter", fn))
      this._legendLeaveHandlers?.forEach(({ el, fn }) => el.removeEventListener("mouseleave", fn))
    }
  }

  _handleSvgOver(e) {
    const party = e.target.getAttribute("data-party")
    if (party) this._highlight(party)
  }

  _handleSvgOut(e) {
    if (e.target.classList.contains("seat-dot")) this._clear()
  }

  _handleSvgClick(e) {
    const party = e.target.getAttribute("data-party")
    if (party) {
      party === this._selected ? this._clear() : this._highlight(party)
    } else if (e.target.tagName !== "title") {
      this._clear()
    }
  }

  _highlight(party) {
    this._selected = party
    const dr = this.defaultRadius
    this.dots.forEach(d => {
      if (d.getAttribute("data-party") === party) {
        d.setAttribute("r", parseFloat(dr) * 1.3)
        d.setAttribute("opacity", "1")
        d.setAttribute("stroke", "#fff")
        d.setAttribute("stroke-width", "1.5")
      } else {
        d.setAttribute("r", dr)
        d.setAttribute("opacity", this.modeValue === "click" ? "0.12" : "0.15")
        d.removeAttribute("stroke")
        d.removeAttribute("stroke-width")
      }
    })
    this.legendItems.forEach(el => {
      el.style.opacity = el.getAttribute("data-legend-party") === party ? "1" : "0.3"
    })
  }

  _clear() {
    this._selected = null
    const dr = this.defaultRadius
    this.dots.forEach(d => {
      d.setAttribute("r", dr)
      d.setAttribute("opacity", "0.9")
      d.removeAttribute("stroke")
      d.removeAttribute("stroke-width")
    })
    this.legendItems.forEach(el => { el.style.opacity = "1" })
  }
}
