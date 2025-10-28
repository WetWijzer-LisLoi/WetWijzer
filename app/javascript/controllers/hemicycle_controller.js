import { Controller } from "@hotwired/stimulus"

/**
 * Hemicycle Controller
 *
 * Renders an interactive SVG hemicycle (semicircular parliament seating chart).
 * Clicking a party highlights its seats and shows speakers in a detail panel.
 *
 * Values:
 *   parties:  [{ party, seats, color, involved }]
 *   members:  [{ name, party }]
 *   votes:    [{ ref, result }]  - article/amendment vote details
 *   result:   String - final result text (e.g. "aangenomen")
 */
export default class extends Controller {
  static values = {
    parties:  Array,
    members:  Array,
    votes:    { type: Array, default: [] },
    result:   { type: String, default: '' }
  }

  connect() {
    this.selectedParty = null
    this.groups = {}
    this.render()
  }

  render() {
    const parties = this.partiesValue
    if (!parties || parties.length === 0) return

    const totalSeats = parties.reduce((s, p) => s + p.seats, 0)
    const involvedSeats = parties.filter(p => p.involved).reduce((s, p) => s + p.seats, 0)

    // Root layout
    const root = document.createElement("div")
    root.className = "flex flex-col items-center gap-3"

    /* ────── SVG hemicycle ────── */
    const W = 440, H = 240, cx = W / 2, cy = H - 10
    const svg = this._ns("svg")
    svg.setAttribute("viewBox", `0 0 ${W} ${H}`)
    svg.setAttribute("class", "w-full max-w-md mx-auto")
    svg.style.overflow = "visible"

    // Seat positions
    const rows  = this._computeRows(totalSeats)
    const seats = []
    rows.forEach(r => {
      for (let i = 0; i < r.count; i++) {
        const a = r.startAngle + (r.endAngle - r.startAngle) * i / (r.count - 1 || 1)
        seats.push({ x: cx + r.radius * Math.cos(a), y: cy - r.radius * Math.sin(a) })
      }
    })

    // Sort parties left→right (political spectrum)
    const ORDER = {
      'PVDA-PTB':0,'PTB':0,'PVDA':0,'PS':1,'Vooruit':2,'sp.a':2,
      'Ecolo':3,'Groen':4,'Ecolo-Groen':3.5,'cdH':5,'DéFI':5.5,'LE':5.5,
      'CD&V':6,'Open Vld':7,'MR':8,'N-VA':9,'VB':10
    }
    const sorted = [...parties].sort((a, b) => (ORDER[a.party] ?? 5) - (ORDER[b.party] ?? 5))

    // Assign seats to parties
    let idx = 0
    this.groups = {}
    sorted.forEach(p => {
      this.groups[p.party] = []
      for (let i = 0; i < p.seats && idx < seats.length; i++, idx++) {
        const s = seats[idx]
        const c = this._ns("circle")
        c.setAttribute("cx", s.x)
        c.setAttribute("cy", s.y)
        c.setAttribute("r", "5")
        c.setAttribute("data-party", p.party)
        this._styleSeat(c, p, false)
        c.style.transition = "all .2s"
        c.style.cursor = "pointer"
        // Native tooltip
        const t = this._ns("title")
        t.textContent = `${p.party} (${p.seats} zetels)`
        c.appendChild(t)
        this.groups[p.party].push(c)
        svg.appendChild(c)
      }
    })

    // Click handler
    svg.addEventListener("click", e => {
      const t = e.target.closest("[data-party]")
      const p = t ? t.getAttribute("data-party") : null
      p ? this._selectParty(p) : this._clearSelection()
    })

    // Hover handler - highlight party on mouseover
    svg.addEventListener("mouseenter", e => {
      const t = e.target.closest("[data-party]")
      if (!t || this.selectedParty) return
      this._hoverParty(t.getAttribute("data-party"))
    }, true)
    svg.addEventListener("mouseleave", e => {
      const t = e.target.closest("[data-party]")
      if (!t || this.selectedParty) return
      this._clearHover()
    }, true)

    // Center label
    const lbl = this._ns("text")
    lbl.setAttribute("x", cx); lbl.setAttribute("y", cy - 5)
    lbl.setAttribute("text-anchor", "middle")
    lbl.setAttribute("fill", "currentColor")
    lbl.setAttribute("class", "text-gray-400 dark:text-gray-300/50")
    lbl.setAttribute("font-size", "12"); lbl.setAttribute("font-weight", "600")
    lbl.textContent = `${totalSeats} zetels`
    svg.appendChild(lbl)
    root.appendChild(svg)

    /* ────── Compact legend ────── */
    const leg = document.createElement("div")
    leg.className = "flex flex-wrap justify-center gap-x-3 gap-y-1 text-[11px]"
    sorted.forEach(p => {
      const b = document.createElement("button")
      b.className = `inline-flex items-center gap-1 px-1.5 py-0.5 rounded transition-all hover:bg-gray-100 dark:hover:bg-gray-800/60 ${p.involved ? '' : 'opacity-30'}`
      b.setAttribute("data-legend-party", p.party)
      b.innerHTML = `<span class="w-2 h-2 rounded-full shrink-0" style="background:${p.color}"></span>`
                   + `<span class="text-gray-600 dark:text-gray-300/80 font-medium">${p.party}</span>`
                   + `<span class="text-gray-400 dark:text-gray-300/40">${p.seats}</span>`
      b.addEventListener("click", () => this._selectParty(p.party))
      leg.appendChild(b)
    })
    root.appendChild(leg)

    /* ────── Vote result summary bar ────── */
    const votes = this.votesValue
    if (votes && votes.length) {
      const bar = document.createElement("div")
      bar.className = "w-full max-w-md"

      // Count vote types
      let unanimous = 0, adopted = 0, rejected = 0
      votes.forEach(v => {
        const r = (v.result || '').toLowerCase()
        if (r.includes("eenparig") || r.includes("unanim"))  unanimous++
        else if (r.includes("aangenomen") || r.includes("adopté")) adopted++
        else if (r.includes("verworpen") || r.includes("rejeté")) rejected++
      })
      const total = votes.length

      // Visual bar
      bar.innerHTML = `
        <div class="text-[10px] text-gray-500 dark:text-gray-300/50 mb-1 text-center font-medium">
          Stemmingsresultaten (${total} stemmingen)
        </div>
        <div class="flex h-2.5 rounded-full overflow-hidden bg-gray-200 dark:bg-gray-900/60">
          ${unanimous ? `<div class="bg-emerald-500" style="width:${unanimous/total*100}%" title="${unanimous} eenparig aangenomen"></div>` : ''}
          ${adopted  ? `<div class="bg-amber-400" style="width:${adopted/total*100}%" title="${adopted} aangenomen (niet-eenparig)"></div>` : ''}
          ${rejected ? `<div class="bg-red-500" style="width:${rejected/total*100}%" title="${rejected} verworpen"></div>` : ''}
        </div>
        <div class="flex justify-center gap-3 mt-1 text-[10px] text-gray-400 dark:text-gray-300/40">
          ${unanimous ? `<span class="flex items-center gap-0.5"><span class="w-1.5 h-1.5 rounded-full bg-emerald-500"></span> ${unanimous} eenparig</span>` : ''}
          ${adopted  ? `<span class="flex items-center gap-0.5"><span class="w-1.5 h-1.5 rounded-full bg-amber-400"></span> ${adopted} meerderheid</span>` : ''}
          ${rejected ? `<span class="flex items-center gap-0.5"><span class="w-1.5 h-1.5 rounded-full bg-red-500"></span> ${rejected} verworpen</span>` : ''}
        </div>`
      root.appendChild(bar)
    }

    /* ────── Instruction text ────── */
    const hint = document.createElement("p")
    hint.className = "text-[10px] text-gray-400 dark:text-gray-300/40 text-center"
    hint.innerHTML = `<span class="inline-block w-1.5 h-1.5 rounded-full bg-emerald-500 mr-0.5"></span>`
      + ` betrokken bij debat &nbsp;`
      + `<span class="inline-block w-1.5 h-1.5 rounded-full bg-gray-500 opacity-30 mr-0.5"></span>`
      + ` niet betrokken - klik voor details`
    root.appendChild(hint)

    /* ────── Detail panel (hidden) ────── */
    const dp = document.createElement("div")
    dp.className = "hidden mt-1 w-full"
    dp.id = "hemicycle-detail"
    root.appendChild(dp)
    this.detailPanel = dp

    this.element.appendChild(root)
    this.svg = svg
    this.partiesData = parties
  }

  /* ── Selection ── */
  _selectParty(party) {
    if (this.selectedParty === party) { this._clearSelection(); return }
    this.selectedParty = party
    const pd = this.partiesData.find(p => p.party === party)

    // Highlight SVG
    Object.entries(this.groups).forEach(([p, circles]) => {
      const d = this.partiesData.find(pp => pp.party === p)
      circles.forEach(c => {
        if (p === party) {
          c.setAttribute("r", "6.5")
          c.setAttribute("opacity", "1")
          c.setAttribute("stroke", "#fff")
          c.setAttribute("stroke-width", "2")
        } else {
          c.setAttribute("r", "5")
          c.setAttribute("opacity", "0.12")
          this._styleSeat(c, d, true)
        }
      })
    })

    // Highlight legend
    this.element.querySelectorAll("[data-legend-party]").forEach(b => {
      if (b.dataset.legendParty === party) {
        b.style.opacity = "1"
        b.classList.add("ring-1","ring-white/40","bg-gray-100","dark:bg-gray-900/60")
      } else {
        b.style.opacity = "0.2"
        b.classList.remove("ring-1","ring-white/40","bg-gray-100","dark:bg-gray-900/60")
      }
    })

    // Detail panel
    const members = (this.membersValue || []).filter(m => m.party === party)
    let html = `<div class="bg-gray-50 dark:bg-gray-900/40 rounded-lg p-3 border border-gray-200 dark:border-gray-700">`
    html += `<div class="flex items-center gap-2 mb-1.5 flex-wrap">`
    html += `<span class="w-3 h-3 rounded-full shrink-0" style="background:${pd?.color||'#888'}"></span>`
    html += `<span class="font-semibold text-sm text-gray-900 dark:text-white">${party}</span>`
    html += `<span class="text-xs text-gray-500 dark:text-gray-300/60">${pd?.seats||'?'} zetels in de Kamer</span>`
    if (pd?.involved) {
      html += `<span class="text-[10px] px-1.5 py-0.5 rounded-full bg-emerald-100 dark:bg-emerald-900/30 text-emerald-700 dark:text-emerald-400 font-medium">betrokken bij debat</span>`
    } else {
      html += `<span class="text-[10px] px-1.5 py-0.5 rounded-full bg-gray-200 dark:bg-gray-700 text-gray-500 dark:text-gray-400 font-medium">niet betrokken</span>`
    }
    html += `</div>`

    if (members.length > 0) {
      html += `<div class="text-xs text-gray-500 dark:text-gray-300/60 mb-1">Sprekers in dit debat:</div>`
      html += `<div class="flex flex-wrap gap-1">`
      members.forEach(m => {
        html += `<span class="inline-flex items-center px-2 py-0.5 rounded text-xs bg-white dark:bg-gray-800/60 text-gray-700 dark:text-gray-300 border border-gray-200 dark:border-gray-600">${m.name}</span>`
      })
      html += `</div>`
    } else if (pd?.involved) {
      html += `<div class="text-xs text-gray-400 dark:text-gray-300/40 italic">Partij betrokken bij stemming - individuele sprekers niet geïdentificeerd in deze tekst.</div>`
    } else {
      html += `<div class="text-xs text-gray-400 dark:text-gray-300/40 italic">Deze partij werd niet vermeld in het verslag van deze commissievergadering.</div>`
    }

    html += `</div>`
    this.detailPanel.innerHTML = html
    this.detailPanel.classList.remove("hidden")
  }

  _clearSelection() {
    this.selectedParty = null
    Object.entries(this.groups).forEach(([p, circles]) => {
      const d = this.partiesData.find(pp => pp.party === p)
      circles.forEach(c => { c.setAttribute("r","5"); this._styleSeat(c, d, false) })
    })
    this.element.querySelectorAll("[data-legend-party]").forEach(b => {
      const d = this.partiesData.find(pp => pp.party === b.dataset.legendParty)
      b.style.opacity = d?.involved ? "1" : ""
      b.classList.remove("ring-1","ring-white/40","bg-gray-100","dark:bg-gray-900/60")
      if (!d?.involved) b.classList.add("opacity-30")
    })
    this.detailPanel.classList.add("hidden")
  }

  /* ── Helpers ── */
  _styleSeat(el, party, dimmed) {
    if (!party) return
    const inv = party.involved
    el.setAttribute("fill", inv ? party.color : this._desat(party.color))
    el.setAttribute("stroke", inv ? party.color : "#555")
    el.setAttribute("stroke-width", inv ? "1.5" : "0.5")
    el.setAttribute("opacity", dimmed ? "0.12" : (inv ? "1" : "0.25"))
  }

  _computeRows(total) {
    const rMin = 70, rMax = 200, gap = 20
    const n = Math.ceil((rMax - rMin) / gap)
    const rows = []
    let rem = total
    for (let i = 0; i < n && rem > 0; i++) {
      const r = rMin + i * gap
      const cnt = Math.min(Math.floor(Math.PI * r / 16), rem)
      rows.push({ radius: r, count: cnt, startAngle: Math.PI * 0.02, endAngle: Math.PI * 0.98 })
      rem -= cnt
    }
    if (rem > 0 && rows.length) rows[rows.length - 1].count += rem
    return rows
  }

  /* ── Hover (non-sticky highlight) ── */
  _hoverParty(party) {
    Object.entries(this.groups).forEach(([p, circles]) => {
      const d = this.partiesData.find(pp => pp.party === p)
      circles.forEach(c => {
        if (p === party) {
          c.setAttribute("r", "6")
          c.setAttribute("opacity", "1")
          c.setAttribute("stroke", "#fff")
          c.setAttribute("stroke-width", "1.5")
        } else {
          c.setAttribute("r", "5")
          c.setAttribute("opacity", "0.2")
          this._styleSeat(c, d, true)
        }
      })
    })
  }

  _clearHover() {
    Object.entries(this.groups).forEach(([p, circles]) => {
      const d = this.partiesData.find(pp => pp.party === p)
      circles.forEach(c => { c.setAttribute("r", "5"); this._styleSeat(c, d, false) })
    })
  }

  _ns(tag)  { return document.createElementNS("http://www.w3.org/2000/svg", tag) }
  _desat(h) {
    if (!h || h.length < 7) return "#888"
    const [r,g,b] = [1,3,5].map(i => parseInt(h.slice(i,i+2),16))
    const gr = Math.round(r*.299+g*.587+b*.114)
    return '#'+[r,g,b].map(c=>Math.round(c*.3+gr*.7).toString(16).padStart(2,'0')).join('')
  }
}
