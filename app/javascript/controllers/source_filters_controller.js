import { Controller } from "@hotwired/stimulus";

// Shows each source's filter block only while that source is selected.
//
// app/views/laws/index.html.erb has carried
// data-action="change->source-filters#toggle" on the three source pills, and
// app/views/laws/_filter_section.html.erb the matching filter blocks, but no
// controller by this name existed - so the actions were inert and ticking
// Rechtspraak or Parlementaire stukken never revealed their filters.
//
// The defaults disagreed too: a pill renders checked unless its param is '0',
// while its block rendered hidden unless the param was exactly '1'. On a first
// visit that showed all three sources selected and only the legislation
// filters. connect() re-syncs from the checkboxes, so the pills are the single
// source of truth however the page was rendered.
export default class extends Controller {
  static targets = ["legislation", "jurisprudence", "parliamentary",
                    "legislationFilters", "jurisprudenceFilters", "parliamentaryFilters"];

  connect() {
    this.toggle();
  }

  toggle() {
    this.sync("legislation", "legislationFilters");
    this.sync("jurisprudence", "jurisprudenceFilters");
    this.sync("parliamentary", "parliamentaryFilters");
  }

  sync(source, block) {
    const checkbox = this.target(`has${this.capitalize(source)}Target`, `${source}Target`);
    const panel = this.target(`has${this.capitalize(block)}Target`, `${block}Target`);
    if (!checkbox || !panel) return;
    panel.classList.toggle("hidden", !checkbox.checked);
  }

  target(hasName, name) {
    return this[hasName] ? this[name] : null;
  }

  capitalize(name) {
    return name.charAt(0).toUpperCase() + name.slice(1);
  }
}
