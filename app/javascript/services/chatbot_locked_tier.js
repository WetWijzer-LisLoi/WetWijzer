// The offer shown when a question is sent with an intelligence level the
// account cannot use.
//
// Data and copy only - the controller keeps the DOM and the send. Everything
// here is pure so the part that decides what the user is offered can be tested
// without a browser: which level they fall back to, and what each language
// actually says.
//
// The framing is deliberate. This is the one moment where someone has already
// written a question and pressed send, so the modal must not read as a wall.
// It names what the locked level would add, offers the upgrade, and always
// leaves a way to get an answer now.

const LABEL_KEYS = { nl: "labelNl", fr: "labelFr", de: "labelDe", en: "labelEn" }
const DESC_KEYS = { nl: "descNl", fr: "descFr", de: "descDe", en: "descEn" }

// The full page renders the levels as slider notches and the floating widget
// renders them as pills; the layout swaps one for the other, so exactly one
// set is ever present.
export function readIntelligenceChoices(root, language) {
  const lang = language || "nl"
  const labelKey = LABEL_KEYS[lang] || LABEL_KEYS.nl
  const descKey = DESC_KEYS[lang] || DESC_KEYS.nl

  const notches = Array.from(
    root?.querySelectorAll?.("#intelligence-slider-section .notch-label[data-intelligence-level]") || []
  )
  if (notches.length) {
    return notches.map((notch, index) => ({
      id: notch.dataset.intelligenceLevel,
      index,
      locked: notch.dataset.intelligenceLocked === "true",
      tier: notch.dataset.intelligenceTier || "free",
      name: notch.dataset[labelKey] || notch.querySelector?.(".notch-text")?.textContent?.trim() || notch.dataset.intelligenceLevel,
      desc: notch.dataset[descKey] || "",
      element: notch
    }))
  }

  const pills = Array.from(root?.querySelectorAll?.("#widget-intelligence-pills .widget-intel-pill") || [])
  return pills.map((pill, index) => ({
    id: pill.dataset.widgetLevel,
    index,
    locked: pill.dataset.widgetLocked === "true",
    tier: pill.dataset.widgetLockedTier || "free",
    name: pill.dataset.widgetLabel || pill.dataset.widgetLevel,
    desc: pill.dataset.widgetDesc || "",
    element: pill
  }))
}

// The STRONGEST level this account can actually use. Dropping to the weakest
// available one would hand back a worse answer than the account is entitled
// to, which is its own small betrayal at exactly the wrong moment.
export function bestUnlockedChoice(choices, excludeId) {
  return (choices || []).filter(choice => choice && !choice.locked && choice.id !== excludeId).pop() || null
}

// The tooltip shown the moment a locked control is clicked - before any
// question has been written. Same voice as the modal: what it adds, not what
// you are missing. `subject` is the level's own name and description when the
// anchor carries them, so a level says what it does and a locked source falls
// back to the general line.
export function proTooltipCopy(language, subject = null) {
  const table = {
    nl: { generic: "Meer diepgang met WetWijzer Pro.", link: "Bekijk WetWijzer Pro →" },
    fr: { generic: "Plus de profondeur avec WetWijzer Pro.", link: "Découvrir WetWijzer Pro →" },
    de: { generic: "Mehr Tiefe mit WetWijzer Pro.", link: "WetWijzer Pro ansehen →" },
    en: { generic: "More depth with WetWijzer Pro.", link: "See WetWijzer Pro →" }
  }
  const copy = table[language] || table.nl
  const name = String(subject?.name || "").trim()
  const desc = String(subject?.desc || "").trim()
  if (!name) return { text: copy.generic, link: copy.link }

  return { text: desc ? `${name} - ${desc}.` : `${name}.`, link: copy.link }
}

export function lockedTierCopy(language, { purchasable = false } = {}) {
  const table = {
    nl: {
      title: "Wilt u een grondiger antwoord?",
      availability: purchasable
        ? "Dit niveau werkt met credits of met WetWijzer Pro."
        : "Dit niveau hoort bij WetWijzer Pro.",
      proBtn: "Probeer WetWijzer Pro",
      buyBtn: "Credits kopen",
      continueBtn: name => `Nu antwoorden met ${name}`,
      close: "Sluiten"
    },
    fr: {
      title: "Vous voulez une réponse plus approfondie ?",
      availability: purchasable
        ? "Ce niveau fonctionne avec des crédits ou avec WetWijzer Pro."
        : "Ce niveau fait partie de WetWijzer Pro.",
      proBtn: "Essayer WetWijzer Pro",
      buyBtn: "Acheter des crédits",
      continueBtn: name => `Répondre maintenant avec ${name}`,
      close: "Fermer"
    },
    de: {
      title: "Möchten Sie eine gründlichere Antwort?",
      availability: purchasable
        ? "Diese Stufe funktioniert mit Credits oder mit WetWijzer Pro."
        : "Diese Stufe gehört zu WetWijzer Pro.",
      proBtn: "WetWijzer Pro testen",
      buyBtn: "Credits kaufen",
      continueBtn: name => `Jetzt mit ${name} antworten`,
      close: "Schließen"
    },
    en: {
      title: "Want a more thorough answer?",
      availability: purchasable
        ? "This level runs on credits or on WetWijzer Pro."
        : "This level is part of WetWijzer Pro.",
      proBtn: "Try WetWijzer Pro",
      buyBtn: "Buy credits",
      continueBtn: name => `Answer now with ${name}`,
      close: "Close"
    }
  }
  return table[language] || table.nl
}

// The level's OWN server-rendered description, never an invented promise about
// what a stronger model will do.
export function lockedTierLead(levelName, levelDesc, availability) {
  const name = String(levelName || "").trim()
  const desc = String(levelDesc || "").trim()
  if (!name) return availability
  return desc ? `${name} - ${desc}. ${availability}` : `${name}. ${availability}`
}

export function escapeLockedTierText(value) {
  return String(value ?? "").replace(/[&<>"']/g, character => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  })[character])
}
