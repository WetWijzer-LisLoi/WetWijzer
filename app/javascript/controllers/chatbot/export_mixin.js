/**
 * Chatbot Controller - Export Mixin
 *
 * Methods extracted from chatbot_controller.js for maintainability.
 * Mixed into the controller prototype - all methods use 'this' as normal.
 */

export const exportMethods = {

  // Report a failed/bad chatbot answer to the administrator.
  // GDPR: This intentionally sends question+answer text to the server.
  // The user MUST explicitly consent via a confirm dialog.

  async reportFailed(event) {
    const button = event.currentTarget
    const container = button.closest(".feedback-buttons")
    const messageId = container?.dataset.messageId

    // Resolve the turn this button belongs to, NOT the newest one. The
    // consent dialog below promises that "your question and the answer"
    // become visible to the administrator; with several answers on screen,
    // indexing off the end of the history reported a different pair than the
    // one the user was looking at when they consented.
    const historyLength = this.conversationHistory.length
    if (historyLength < 2) return

    const stamped = Number(container?.dataset.turnIndex)
    // Fall back to the previous behaviour for anything rendered without a
    // stamp (a cached older bundle, restored history), so Report never breaks.
    const answerIndex = Number.isInteger(stamped) && stamped > 0 && stamped < historyLength
      ? stamped
      : historyLength - 1

    const question = this.conversationHistory[answerIndex - 1]?.content || ""
    const answer = this.conversationHistory[answerIndex]?.content || ""
    const analyticId = this.conversationHistory[answerIndex]?.analytic_id || null

    if (!question) return

    // GDPR consent dialog - make it ABUNDANTLY CLEAR that Q&A will be visible
    const warnings = {
      nl: `⚠️ PRIVACY WAARSCHUWING ⚠️\n\nDoor dit antwoord te melden worden zowel UW VRAAG als HET ANTWOORD zichtbaar voor de beheerder van ${window.location.hostname}.\n\n🔓 De beheerder kan de volledige inhoud van uw vraag lezen.\n\n⚠️ Als uw vraag gevoelige persoonsgegevens bevat (bijv. namen, financiële gegevens, medische informatie, juridische situaties), worden deze ook zichtbaar.\n\n⏱️ De melding wordt maximaal 90 dagen bewaard en daarna automatisch verwijderd.\n\nWilt u doorgaan met melden?`,
      fr: `⚠️ AVERTISSEMENT VIE PRIVÉE ⚠️\n\nEn signalant cette réponse, VOTRE QUESTION et LA RÉPONSE seront visibles par l'administrateur de ${window.location.hostname}.\n\n🔓 L'administrateur pourra lire l'intégralité de votre question.\n\n⚠️ Si votre question contient des données personnelles sensibles (noms, données financières, informations médicales, situations juridiques), celles-ci seront également visibles.\n\n⏱️ Le signalement sera conservé maximum 90 jours puis automatiquement supprimé.\n\nVoulez-vous continuer ?`,
      de: `⚠️ DATENSCHUTZ-WARNUNG ⚠️\n\nDurch diese Meldung werden sowohl IHRE FRAGE als auch DIE ANTWORT für den Administrator von ${window.location.hostname} sichtbar.\n\n🔓 Der Administrator kann den vollständigen Inhalt Ihrer Frage lesen.\n\n⚠️ Wenn Ihre Frage sensible personenbezogene Daten enthält (Namen, Finanzdaten, medizinische Informationen, rechtliche Situationen), werden diese ebenfalls sichtbar.\n\n⏱️ Die Meldung wird maximal 90 Tage aufbewahrt und danach automatisch gelöscht.\n\nMöchten Sie fortfahren?`,
      en: `⚠️ PRIVACY WARNING ⚠️\n\nBy reporting this answer, both YOUR QUESTION and THE ANSWER will become visible to the administrator of ${window.location.hostname}.\n\n🔓 The administrator will be able to read the full content of your question.\n\n⚠️ If your question contains sensitive personal data (names, financial data, medical information, legal situations), this will also be visible.\n\n⏱️ The report will be stored for a maximum of 90 days and then automatically deleted.\n\nDo you want to continue?`
    }

    const warning = warnings[this.languageValue] || warnings.nl
    if (!confirm(warning)) return

    // Visual feedback - mark as reported
    button.disabled = true
    button.classList.add('text-amber-500')

    const reportedLabels = { nl: 'Gemeld', fr: 'Signalé', de: 'Gemeldet', en: 'Reported' }
    const reportedLabel = reportedLabels[this.languageValue] || reportedLabels.nl

    try {
      const response = await fetch('/api/chatbot/report', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': this.csrfToken
        },
        body: JSON.stringify({
          question: question,
          answer: answer,
          language: this.languageValue,
          source: this.sourceValue,
          intelligence: this.intelligenceValue,
          analytic_id: analyticId
        })
      })

      if (response.ok) {
        // Replace button with "Reported" text
        const span = document.createElement('span')
        span.className = 'text-amber-500 text-[11px] px-1'
        span.textContent = reportedLabel
        button.replaceWith(span)
      } else {
        const data = await response.json()
        button.disabled = false
        button.classList.remove('text-amber-500')
        // Show rate limit message
        if (response.status === 429) {
          alert(data.error || 'Rate limit reached')
        }
      }
    } catch (error) {
      console.error('Failed to report:', error)
      button.disabled = false
      button.classList.remove('text-amber-500')
    }
  },

  // Export answer to Word document

  exportWord(event) {
    const button = event.currentTarget
    const messageDiv = button.closest("[data-message-id]")?.parentElement?.parentElement
    if (!messageDiv) return

    const contentDiv = messageDiv.querySelector(".message-content")
    const sourcesDiv = messageDiv.querySelector(".message-sources")
    if (!contentDiv) return

    // Get HTML content with formatting
    let html = contentDiv.innerHTML
    if (sourcesDiv) {
      html += sourcesDiv.innerHTML
    }

    // Localized Word export content
    const wordLabels = {
      nl: { title: "WetWijzer Juridische Chatbot", generated: "Gegenereerd op", disclaimer: "Door AI gegenereerd - geen juridisch advies.", source: "WetWijzer.be" },
      fr: { title: "LisLoi Chatbot Juridique", generated: "Généré le", disclaimer: "Généré par IA - ne constitue pas un avis juridique.", source: "LisLoi.be" },
      de: { title: "GesetzGuide Juristischer Chatbot", generated: "Erstellt am", disclaimer: "Von KI erstellt - keine Rechtsberatung.", source: "GesetzGuide.be" },
      en: { title: "LexLibera Legal Chatbot", generated: "Generated on", disclaimer: "AI-generated - not legal advice.", source: "LexLibera.be" }
    }
    const wl = wordLabels[this.languageValue] || wordLabels.nl

    // Create Word-compatible HTML document
    const wordContent = `
      <html xmlns:o="urn:schemas-microsoft-com:office:office"
            xmlns:w="urn:schemas-microsoft-com:office:word"
            xmlns="http://www.w3.org/TR/REC-html40">
      <head>
        <meta charset="utf-8">
        <title>${wl.title}</title>
        <style>
          body { font-family: Calibri, Arial, sans-serif; font-size: 11pt; line-height: 1.5; }
          h1, h2, h3 { color: #1e3a5f; }
          strong { font-weight: bold; }
          ul, ol { margin-left: 20px; }
          a { color: #2563eb; text-decoration: underline; }
          .message-sources { margin-top: 20px; padding-top: 10px; border-top: 1px solid #ccc; font-size: 10pt; }
        </style>
      </head>
      <body>
        <h2>${wl.title}</h2>
        <p><em>${wl.generated}: ${new Date().toLocaleString()}</em></p>
        <hr>
        ${html}
        <hr>
        <p style="font-size: 9pt; color: #666;">
          ${wl.disclaimer}<br>
          ${wl.source}
        </p>
      </body>
      </html>
    `

    // Create blob and download
    const blob = new Blob([wordContent], { type: 'application/msword' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `wetwijzer-antwoord-${Date.now()}.doc`
    document.body.appendChild(a)
    a.click()
    document.body.removeChild(a)
    URL.revokeObjectURL(url)

    // Visual feedback
    button.classList.add("text-green-500")
    setTimeout(() => button.classList.remove("text-green-500"), 2000)
  },

  // Export answer to Typst document (.typ)

  exportTypst(event) {
    const button = event.currentTarget
    const messageDiv = button.closest("[data-message-id]")?.parentElement?.parentElement
    if (!messageDiv) return

    const contentDiv = messageDiv.querySelector(".message-content")
    if (!contentDiv) return

    // Get plain text content (Typst uses its own markup, not HTML)
    const textContent = contentDiv.innerText || contentDiv.textContent || ''

    // Localized Typst export content
    const typstLabels = {
      nl: { title: "WetWijzer Juridische Chatbot", generated: "Gegenereerd op", disclaimer: "Door AI gegenereerd – geen juridisch advies.", source: "WetWijzer.be" },
      fr: { title: "LisLoi Chatbot Juridique", generated: "Généré le", disclaimer: "Généré par IA – ne constitue pas un avis juridique.", source: "LisLoi.be" },
      de: { title: "GesetzGuide Juristischer Chatbot", generated: "Erstellt am", disclaimer: "Von KI erstellt – keine Rechtsberatung.", source: "GesetzGuide.be" },
      en: { title: "LexLibera Legal Chatbot", generated: "Generated on", disclaimer: "AI-generated – not legal advice.", source: "LexLibera.be" }
    }
    const tl = typstLabels[this.languageValue] || typstLabels.nl

    // Escape Typst special chars
    const esc = (s) => s.replace(/\\/g, '\\\\').replace(/[#$*_@~`<>]/g, m => '\\' + m)

    // Build Typst document
    const dateStr = new Date().toLocaleString()
    let typstContent = `// ${esc(tl.title)} – https://typst.app to compile\n`
    typstContent += `#set document(title: "${esc(tl.title)}", author: "${esc(tl.source)}")\n`
    typstContent += `#set page(margin: 2cm)\n`
    typstContent += `#set text(font: "New Computer Modern", size: 11pt, lang: "${this.languageValue || 'nl'}")\n`
    typstContent += `#set par(justify: true)\n\n`
    typstContent += `#align(center, text(size: 16pt, weight: "bold")[${esc(tl.title)}])\n\n`
    typstContent += `#align(right, text(size: 9pt, fill: luma(120))[${esc(tl.generated)}: ${esc(dateStr)}])\n\n`
    typstContent += `#line(length: 100%, stroke: 0.5pt + luma(180))\n\n`

    // Process text into paragraphs
    const paragraphs = textContent.split(/\n\n+/)
    for (const para of paragraphs) {
      const trimmed = para.trim()
      if (!trimmed) continue
      typstContent += `${esc(trimmed)}\n\n`
    }

    typstContent += `#v(1fr)\n`
    typstContent += `#line(length: 100%, stroke: 0.5pt + luma(180))\n`
    typstContent += `#text(size: 8pt, fill: luma(140))[${esc(tl.disclaimer)}]\n\n`
    typstContent += `#text(size: 8pt, fill: luma(140))[${esc(tl.source)}]\n`

    // Create blob and download
    const blob = new Blob([typstContent], { type: 'text/plain;charset=utf-8' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    const brandSlug = (tl.source || 'wetwijzer').replace(/\./g, '-').toLowerCase()
    a.download = `${brandSlug}-antwoord-${Date.now()}.typ`
    document.body.appendChild(a)
    a.click()
    document.body.removeChild(a)
    URL.revokeObjectURL(url)

    // Visual feedback
    button.classList.add("text-green-500")
    setTimeout(() => button.classList.remove("text-green-500"), 2000)
  },

  // Export answer to ODT document (.fodt – Flat ODF, no ZIP needed)

  exportOdt(event) {
    const button = event.currentTarget
    const messageDiv = button.closest("[data-message-id]")?.parentElement?.parentElement
    if (!messageDiv) return

    const contentDiv = messageDiv.querySelector(".message-content")
    if (!contentDiv) return

    const textContent = contentDiv.innerText || contentDiv.textContent || ''
    const esc = (s) => (s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

    const odtLabels = {
      nl: { title: "WetWijzer Juridische Chatbot", generated: "Gegenereerd op", disclaimer: "Door AI gegenereerd – geen juridisch advies.", source: "WetWijzer.be" },
      fr: { title: "LisLoi Chatbot Juridique", generated: "Généré le", disclaimer: "Généré par IA – ne constitue pas un avis juridique.", source: "LisLoi.be" },
      de: { title: "GesetzGuide Juristischer Chatbot", generated: "Erstellt am", disclaimer: "Von KI erstellt – keine Rechtsberatung.", source: "GesetzGuide.be" },
      en: { title: "LexLibera Legal Chatbot", generated: "Generated on", disclaimer: "AI-generated – not legal advice.", source: "LexLibera.be" }
    }
    const ol = odtLabels[this.languageValue] || odtLabels.nl
    const dateStr = new Date().toLocaleString()

    // Build paragraphs
    let bodyXml = ''
    bodyXml += `<text:h text:style-name="Heading_20_1" text:outline-level="1">${esc(ol.title)}</text:h>\n`
    bodyXml += `<text:p text:style-name="Subtle">${esc(ol.generated)}: ${esc(dateStr)}</text:p>\n`
    bodyXml += `<text:p text:style-name="Horizontal_20_Line"/>\n`

    const paragraphs = textContent.split(/\n\n+/)
    for (const para of paragraphs) {
      const trimmed = para.trim()
      if (!trimmed) continue
      bodyXml += `<text:p text:style-name="Standard">${esc(trimmed)}</text:p>\n`
    }

    bodyXml += `<text:p text:style-name="Horizontal_20_Line"/>\n`
    bodyXml += `<text:p text:style-name="Subtle">${esc(ol.disclaimer)}</text:p>\n`
    bodyXml += `<text:p text:style-name="Subtle">${esc(ol.source)}</text:p>\n`

    const fodt = this._buildFodtDocument(bodyXml, ol.title, ol.source)
    const blob = new Blob([fodt], { type: 'application/vnd.oasis.opendocument.text' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    const brandSlug = (ol.source || 'wetwijzer').replace(/\./g, '-').toLowerCase()
    a.download = `${brandSlug}-antwoord-${Date.now()}.fodt`
    document.body.appendChild(a)
    a.click()
    document.body.removeChild(a)
    URL.revokeObjectURL(url)

    button.classList.add("text-green-500")
    setTimeout(() => button.classList.remove("text-green-500"), 2000)
  },

  // Save answer to profile

  async saveAnswer(event) {
    const button = event.currentTarget
    const messageDiv = button.closest("[data-message-id]")?.parentElement?.parentElement
    if (!messageDiv) return

    const contentDiv = messageDiv.querySelector(".message-content")
    if (!contentDiv) return

    // Get the question from conversation history
    const historyLength = this.conversationHistory.length
    if (historyLength < 2) {
      const noQ = { nl: 'Geen vraag om op te slaan', fr: 'Aucune question à sauvegarder', de: 'Keine Frage zum Speichern', en: 'No question to save' }
      alert(noQ[this.languageValue] || noQ.nl)
      return
    }

    // Same rule as Report: the answer already comes from the clicked element,
    // so the question must come from the SAME turn. Taking it off the end of
    // the history paired an older saved answer with the newest question.
    const stamped = Number(button.closest(".feedback-buttons")?.dataset?.turnIndex)
    const answerIndex = Number.isInteger(stamped) && stamped > 0 && stamped < historyLength
      ? stamped
      : historyLength - 1

    const question = this.conversationHistory[answerIndex - 1]?.content || ""
    const answer = contentDiv.innerText || contentDiv.textContent

    try {
      const response = await fetch("/api/chatbot/save", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken
        },
        body: JSON.stringify({
          question: question,
          answer: answer,
          language: this.languageValue
        })
      })

      const data = await response.json()

      if (response.ok) {
        // Visual feedback - bookmark filled
        button.innerHTML = `<svg class="w-4 h-4 text-yellow-500" fill="currentColor" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 5a2 2 0 012-2h10a2 2 0 012 2v16l-7-3.5L5 21V5z"/>
        </svg>`
        button.classList.add("text-yellow-500")
        button.disabled = true
      } else if (response.status === 401) {
        // Not logged in - show login prompt
        const loginMsgs = { nl: 'Log in om antwoorden op te slaan', fr: 'Connectez-vous pour sauvegarder les réponses', de: 'Melden Sie sich an, um Antworten zu speichern', en: 'Log in to save answers' }
        alert(loginMsgs[this.languageValue] || loginMsgs.nl)
      } else {
        console.error("Save failed:", data.error)
      }
    } catch (error) {
      console.error("Failed to save:", error)
    }
  },

  // Save answer to Praxis dossier

  async saveToDossier(event) {
    const button = event.currentTarget
    const messageDiv = button.closest("[data-message-id]")?.parentElement?.parentElement
    if (!messageDiv) return

    const contentDiv = messageDiv.querySelector(".message-content")
    if (!contentDiv) return

    const content = contentDiv.innerText || contentDiv.textContent
    const _t = (map) => map[this.languageValue] || map.nl

    try {
      // Fetch available cases
      const casesRes = await fetch("/api/dossier/cases", {
        headers: { "X-CSRF-Token": this.csrfToken }
      })

      if (!casesRes.ok) {
        if (casesRes.status === 403) {
          alert(_t({ nl: 'Praxis-koppeling vereist', fr: 'Liaison Praxis requise', de: 'Praxis-Verknüpfung erforderlich', en: 'Praxis link required' }))
        } else {
          alert(_t({ nl: 'Kan dossiers niet laden', fr: 'Impossible de charger les dossiers', de: 'Dossiers können nicht geladen werden', en: 'Cannot load dossiers' }))
        }
        return
      }

      const casesData = await casesRes.json()
      const cases = casesData.cases || []

      if (cases.length === 0) {
        alert(_t({ nl: 'Geen actieve dossiers gevonden', fr: 'Aucun dossier actif trouvé', de: 'Keine aktiven Dossiers gefunden', en: 'No active dossiers found' }))
        return
      }

      // Build case selection prompt
      const caseList = cases.map((c, i) => `${i + 1}. ${c.reference || c.id} - ${c.client_name || 'N/A'}`).join('\n')
      const promptText = _t({
        nl: `Kies een dossier:\n${caseList}\n\nVoer het nummer in:`,
        fr: `Choisissez un dossier:\n${caseList}\n\nEntrez le numéro:`,
        de: `Wählen Sie ein Dossier:\n${caseList}\n\nGeben Sie die Nummer ein:`,
        en: `Choose a dossier:\n${caseList}\n\nEnter the number:`
      })
      const choice = prompt(promptText)
      if (!choice) return

      const idx = parseInt(choice) - 1
      if (idx < 0 || idx >= cases.length) return

      const selectedCase = cases[idx]

      // Save to dossier
      const saveRes = await fetch("/api/dossier/save", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken
        },
        body: JSON.stringify({
          case_id: selectedCase.id,
          content: content,
          title: `WetWijzer - ${new Date().toLocaleDateString()}`
        })
      })

      if (saveRes.ok) {
        button.innerHTML = `<svg class="w-4 h-4 text-indigo-500" fill="currentColor" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4"/>
        </svg>`
        button.classList.add("text-indigo-500")
        button.disabled = true
      } else {
        const err = await saveRes.json().catch(() => ({}))
        console.error("Dossier save failed:", err.error)
        alert(err.error || _t({ nl: 'Opslaan mislukt', fr: 'Échec de la sauvegarde', de: 'Speichern fehlgeschlagen', en: 'Save failed' }))
      }
    } catch (error) {
      console.error("Dossier save error:", error)
    }
  },

  // Copy answer to clipboard

  copyAnswer(event) {
    const button = event.currentTarget
    const messageDiv = button.closest("[data-message-id]")?.parentElement?.parentElement
    if (!messageDiv) return

    const contentDiv = messageDiv.querySelector(".message-content")
    if (!contentDiv) return

    // Get answer text (strips HTML)
    let text = contentDiv.innerText || contentDiv.textContent

    // Append sources if present
    const sourcesDiv = messageDiv.querySelector(".message-sources")
    if (sourcesDiv) {
      const sourceLinks = sourcesDiv.querySelectorAll(".source-entry a, .source-entry > div")
      if (sourceLinks.length > 0) {
        const _t = (map) => map[this.languageValue] || map.nl
        const sourcesLabel = _t({ nl: "Bronnen", fr: "Sources", de: "Quellen", en: "Sources" })
        text += `\n\n${sourcesLabel}:\n`
        sourceLinks.forEach((link, i) => {
          const title = link.textContent.trim()
          const url = link.href || ''
          text += url ? `${i + 1}. ${title} - ${url}\n` : `${i + 1}. ${title}\n`
        })
      }
    }

    // Add disclaimer
    const _t = (map) => map[this.languageValue] || map.nl
    text += `\n⚠ ${_t({
      nl: 'Dit is geen officieel juridisch advies.',
      fr: 'Ceci ne constitue pas un avis juridique.',
      de: 'Dies ist keine offizielle Rechtsberatung.',
      en: 'This is not official legal advice.'
    })}`

    navigator.clipboard.writeText(text).then(() => {
      this._trackEvent('chatbot-copy-answer')
      // Visual feedback - change icon temporarily
      const originalSvg = button.innerHTML
      button.innerHTML = `<svg class="w-4 h-4 text-green-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/>
      </svg>`
      button.classList.add("text-green-500")

      setTimeout(() => {
        button.innerHTML = originalSvg
        button.classList.remove("text-green-500")
      }, 2000)
    }).catch(err => {
      console.error("Failed to copy:", err)
    })
  },

  // Deep Analysis - re-query with any model (deep prompt) for deeper legal reasoning

  async deepAnalysis(event) {
    const button = event.currentTarget
    if (this.loadingValue || this._sendInProgress || this._deepAnalysisInProgress ||
        this._conversationResetInFlight) return

    // Match normal send's privacy preflight. A paid answer must never be
    // requested while this tab cannot encrypt the account's ZK history.
    const zkReady = this._isZkReady?.() === true
    if (this._zkKeyGeneration && !zkReady) {
      this._showZkUnlockPrompt?.()
      this._showToast?.(
        { nl: 'Ontgrendel eerst uw beveiligde geschiedenis.', fr: "Déverrouillez d'abord votre historique sécurisé.", de: 'Entsperren Sie zuerst Ihren sicheren Verlauf.', en: 'Unlock your secure history first.' }[this.languageValue] || 'Ontgrendel eerst uw beveiligde geschiedenis.',
        'error'
      )
      return
    }

    // A failed encrypted PATCH retains its claim for a safe retry. Finish that
    // durable save before leasing another revision for deep analysis.
    if (this.conversationId && this._zkClaimTokens?.has(this.conversationId)) {
      this._sendInProgress = true
      try {
        await this._pushEncryptedConversation()
      } catch (error) {
        console.error('[ZK] Outstanding encrypted save retry failed:', error)
        this._showToast?.(
          { nl: 'Sla eerst het vorige beveiligde antwoord opnieuw op of herlaad het gesprek.', fr: "Enregistrez d'abord à nouveau la réponse sécurisée précédente ou rechargez la conversation.", de: 'Speichern Sie zuerst die vorherige sichere Antwort erneut oder laden Sie das Gespräch neu.', en: 'Save the previous secure answer again or reload the conversation first.' }[this.languageValue] || 'Sla eerst het vorige beveiligde antwoord opnieuw op of herlaad het gesprek.',
          'error'
        )
        return
      } finally {
        this._sendInProgress = false
      }
    }

    // Use model from the top model dropdown (or fallback to data attribute set at render time).
    // hasModelSelectTarget guard: the Stimulus target getter throws when the
    // target is absent (widget context) — ?. does not protect against that.
    const deepModel = (this.hasModelSelectTarget ? this.modelSelectTarget.value : null) || button.dataset.deepModel || 'gpt-5-mini'
    this._trackEvent('chatbot-deep-analysis', { model: deepModel })

    const feedbackDiv = button.closest(".feedback-buttons")

    // Model display names for deep-think feature
    // ⚠️ HARDCODED - update when models change in models_config.rb
    // (See models_config.rb checklist item #10)
    const modelNames = {
      'mistral-small': 'Mistral Small 4', 'mistral-large-3': 'Mistral Large 3',
      'gpt-5-mini': 'GPT-5 Mini', 'gpt-5.6-luna': 'GPT-5.6 Luna',
      'claude-4.5-haiku': 'Claude Haiku 4.5', 'claude-sonnet-4-6': 'Claude Sonnet 4.6',
      'gpt-5': 'GPT-5', 'gpt-5.6-terra': 'GPT-5.6 Terra',
      'claude-opus-4-6': 'Claude Opus 4.6', 'gpt-5.6-sol': 'GPT-5.6 Sol'
    }
    const modelName = modelNames[deepModel] || deepModel
    const accentColor = ['gpt-5', 'gpt-5.6-sol'].includes(deepModel) ? 'indigo' : 'purple'

    // Find the answer message this button belongs to
    const messageDiv = button.closest("[data-message-id]")?.parentElement?.parentElement
    if (!messageDiv) return

    const contentDiv = messageDiv.querySelector(".message-content")
    if (!contentDiv) return

    const originalAnswer = contentDiv.innerText || contentDiv.textContent

    // Find the question that generated this answer (walk backwards in history)
    const msgId = parseInt(messageDiv.querySelector("[data-message-id]")?.dataset?.messageId || button.closest("[data-message-id]")?.dataset?.messageId)

    // Find the last user message before this assistant message
    let question = ""
    for (let i = this.conversationHistory.length - 1; i >= 0; i--) {
      if (this.conversationHistory[i].role === "assistant" &&
          this.conversationHistory[i].content?.substring(0, 50) === originalAnswer.substring(0, 50)) {
        // Found the matching answer, the question is one before
        if (i > 0 && this.conversationHistory[i - 1].role === "user") {
          question = this.conversationHistory[i - 1].content
        }
        break
      }
    }

    // Fallback: use the last user message
    if (!question) {
      const lastUser = this.conversationHistory.filter(m => m.role === "user").pop()
      question = lastUser?.content || ""
    }

    if (!question) {
      console.error("Could not find original question for deep analysis")
      return
    }

    // Bind the provider request to one immutable conversation context. If a
    // different tab or teardown supersedes the visible chat, a ZK success can
    // still be encrypted into the conversation for which it was purchased.
    const requestConversationId = this.conversationId
    const requestConversationIsZk = Boolean(
      requestConversationId && this._zkConversationIds?.has(requestConversationId)
    )
    const requestConversationRevision = requestConversationIsZk
      ? this._conversationRevisions?.get(requestConversationId)
      : null
    const requestKeyGeneration = zkReady ? this._zkKeyGeneration : null
    const requestMasterKey = zkReady ? this._masterKey : null
    const requestHistory = JSON.parse(JSON.stringify(this.conversationHistory || []))

    // Disable deep analysis controls for this message
    const allDeepBtns = feedbackDiv?.querySelectorAll(".deep-analysis-btn") || [button]
    allDeepBtns.forEach(btn => { btn.disabled = true })
    if (this.hasModelSelectTarget) this.modelSelectTarget.disabled = true

    const labelSpan = button.querySelector(".deep-label")
    const originalLabel = labelSpan?.textContent || "Analyse"
    const resetDeepControls = () => {
      if (labelSpan) labelSpan.textContent = originalLabel
      button.classList.remove(`text-${accentColor}-500`, "animate-pulse")
      allDeepBtns.forEach(btn => { btn.disabled = false })
      if (this.hasModelSelectTarget) this.modelSelectTarget.disabled = false
    }
    const _t = (map) => map[this.languageValue] || map.nl
    const loadingText = _t({
      nl: `${modelName} denkt dieper na...`,
      fr: `${modelName} réfléchit plus profondément...`,
      de: `${modelName} denkt tiefer nach...`,
      en: `${modelName} is thinking deeper...`
    })
    if (labelSpan) labelSpan.textContent = loadingText
    button.classList.add(`text-${accentColor}-500`, "animate-pulse")

    // Add a "thinking" indicator message
    const thinkingDiv = document.createElement("div")
    thinkingDiv.className = `deep-analysis-thinking flex items-center gap-2 text-sm text-${accentColor}-500 dark:text-${accentColor}-400 px-4 py-2 my-2`
    thinkingDiv.innerHTML = `
      <svg class="w-5 h-5 animate-spin" fill="none" viewBox="0 0 24 24">
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
      </svg>
      <span>${loadingText}</span>
    `
    this.messagesTarget.appendChild(thinkingDiv)
    this.scrollToBottom()

    // Deep analysis is a paid provider request, so it must participate in the
    // same single-flight and cancellation lifecycle as a normal chatbot send.
    // Clear/New refuse to reset while this paid request is live; the epoch and
    // signal checks remain defence-in-depth for disconnects and other teardown.
    const contextEpoch = this._conversationContextEpoch || 0
    if (this.abortController) this.abortController.abort()
    const abortController = new AbortController()
    this.abortController = abortController
    this._sendInProgress = true
    this._deepAnalysisInProgress = true
    const contextIsCurrent = () =>
      !abortController.signal.aborted &&
      contextEpoch === (this._conversationContextEpoch || 0)

    try {
      const response = await fetch("/api/chatbot/deep_analysis", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken
        },
        signal: abortController.signal,
        body: JSON.stringify({
          question: question,
          original_answer: originalAnswer,
          language: this.languageValue,
          source: this.sourceValue,
          deep_model: deepModel,
          conversation_id: requestConversationId,
          ...(requestKeyGeneration ? { key_generation: requestKeyGeneration } : {}),
          ...(requestConversationIsZk ? { conversation_revision: requestConversationRevision } : {})
        })
      })

      // Remove thinking indicator
      thinkingDiv.remove()

      const data = await response.json()

      // A response can win the server race just before Clear/New aborts the
      // browser request. Its balance is still authoritative, but rendering a
      // receipt or answer would pollute the newly-selected conversation.
      if (data.credits_info) {
        this._applyCreditsInfo(data.credits_info, { visual: contextIsCurrent() })
      }

      if (data.error) {
        if (contextIsCurrent()) this.addMessage("error", data.error)
        resetDeepControls()
        return
      } else {
        let protocolAccepted = true
        if (data.conversation_id) {
          protocolAccepted = this._recordConversationProtocolState(data, true)
          if (protocolAccepted && contextIsCurrent()) this.conversationId = data.conversation_id
        }
        if (!protocolAccepted) {
          if (contextIsCurrent()) {
            this._showToast?.(
              { nl: 'De beveiligde gespreksstatus is gewijzigd. Herlaad het gesprek.', fr: "L'état sécurisé de la conversation a changé. Rechargez la conversation.", de: 'Der sichere Gesprächsstatus hat sich geändert. Laden Sie das Gespräch neu.', en: 'The secure conversation state changed. Reload the conversation.' }[this.languageValue] || 'De beveiligde gespreksstatus is gewijzigd. Herlaad het gesprek.',
              'error'
            )
          }
          resetDeepControls()
          return
        }

        // Add the deep analysis as a special styled message with model name
        const deepHeader = _t({
          nl: `**Diepere Analyse** *(${modelName})*\n\n---\n\n`,
          fr: `**Analyse approfondie** *(${modelName})*\n\n---\n\n`,
          de: `**Tiefere Analyse** *(${modelName})*\n\n---\n\n`,
          en: `**Deeper Analysis** *(${modelName})*\n\n---\n\n`
        })

        const deepHistoryMessage = {
          role: "assistant",
          content: data.answer,
          analytic_id: data.analytic_id,
          deep_analysis: true,
          deep_model: deepModel
        }
        let snapshotHistory = [...requestHistory, deepHistoryMessage]

        if (contextIsCurrent()) {
          const rendered = await this.streamMessage(
            "assistant",
            deepHeader + data.answer,
            data.sources,
            data.response_time,
            null,
            { conversationContextEpoch: contextEpoch }
          )
          if (rendered && contextIsCurrent()) {
            // Add to conversation history only while this request still owns
            // the visible chat. If ownership changes during the typewriter,
            // continue below with the immutable copy so a paid ZK result still
            // reaches its original encrypted conversation.
            this.conversationHistory.push(deepHistoryMessage)
            snapshotHistory = JSON.parse(JSON.stringify(this.conversationHistory))
          }
        }

        if (data.zero_knowledge === true) {
          try {
            const encryptedPersistence = this._pushEncryptedConversation({
              conversationId: data.conversation_id,
              masterKey: requestMasterKey,
              keyGeneration: data.key_generation,
              claimToken: data.claim_token,
              messages: snapshotHistory
            })
            this._encryptedPersistenceInFlight = encryptedPersistence
            await encryptedPersistence
          } catch (persistenceError) {
            // Keep the answer and claim in memory so the existing retry path can
            // finish the exact snapshot; do not mislabel a delivered paid answer
            // as a failed provider request.
            console.error('[ZK] Failed to persist deep-analysis snapshot:', persistenceError)
            if (contextIsCurrent()) {
              this._showToast?.(
                { nl: 'De beveiligde analyse kon nog niet worden opgeslagen. Probeer opnieuw voor u verdergaat.', fr: "L'analyse sécurisée n'a pas encore pu être enregistrée. Réessayez avant de continuer.", de: 'Die sichere Analyse konnte noch nicht gespeichert werden. Versuchen Sie es erneut, bevor Sie fortfahren.', en: 'The secure analysis could not be saved yet. Retry before continuing.' }[this.languageValue] || 'De beveiligde analyse kon nog niet worden opgeslagen.',
                'error'
              )
            }
          } finally {
            this._encryptedPersistenceInFlight = null
          }
        }

        if (!contextIsCurrent()) return
      }

      if (!contextIsCurrent()) return

      // Disable both buttons permanently (already analyzed)
      const doneText = _t({ nl: "Geanalyseerd ✓", fr: "Analysé ✓", de: "Analysiert ✓", en: "Analyzed ✓" })
      if (labelSpan) labelSpan.textContent = doneText
      button.classList.remove("animate-pulse")
      button.classList.add(`text-${accentColor}-500`, "opacity-60")
      allDeepBtns.forEach(btn => { btn.style.cursor = "default" })

    } catch (error) {
      thinkingDiv.remove()

      // An aborted or superseded request no longer owns the current chat. Do
      // not insert a stale error into whichever conversation replaced it.
      if (!contextIsCurrent() || error?.name === "AbortError") return

      console.error("Deep analysis error:", error)

      const errorMsg = _t({
        nl: "Diepere analyse mislukt. Probeer opnieuw.",
        fr: "L'analyse approfondie a échoué. Réessayez.",
        de: "Tiefere Analyse fehlgeschlagen. Versuchen Sie es erneut.",
        en: "Deep analysis failed. Please try again."
      })
      this.addMessage("error", errorMsg)

      // Reset buttons on error
      resetDeepControls()
    } finally {
      this._deepAnalysisInProgress = false
      this._sendInProgress = false
      if (this.abortController === abortController) this.abortController = null
    }
  },

  // Clear conversation

  toggleExportMenu() {
    const menu = document.getElementById('export-dropdown-menu')
    if (!menu) return
    menu.classList.toggle('hidden')

    // Close on outside click
    if (!menu.classList.contains('hidden')) {
      const dismiss = (e) => {
        if (!menu.contains(e.target) && !e.target.closest('[data-action*="toggleExportMenu"]')) {
          menu.classList.add('hidden')
          document.removeEventListener('click', dismiss)
        }
      }
      setTimeout(() => document.addEventListener('click', dismiss), 50)
    }
  },

  _closeExportMenu() {
    const menu = document.getElementById('export-dropdown-menu')
    if (menu) menu.classList.add('hidden')
  },

  // Toggle per-answer export dropdown (unique per message)

  toggleSingleExportMenu(event) {
    const button = event.currentTarget
    const menuId = button.dataset.exportMenuId
    if (!menuId) return

    // Close any other open single-export menus first
    document.querySelectorAll('[id^="export-single-menu-"]').forEach(m => {
      if (m.id !== menuId) m.classList.add('hidden')
    })

    const menu = document.getElementById(menuId)
    if (!menu) return
    menu.classList.toggle('hidden')

    // Close on outside click
    if (!menu.classList.contains('hidden')) {
      const dismiss = (e) => {
        if (!menu.contains(e.target) && !e.target.closest('[data-action*="toggleSingleExportMenu"]')) {
          menu.classList.add('hidden')
          document.removeEventListener('click', dismiss)
        }
      }
      setTimeout(() => document.addEventListener('click', dismiss), 50)
    }
  },

  // ── Copy entire conversation to clipboard ──

  copyConversation() {
    const pairs = this._getExportConversation()
    if (pairs.length === 0) {
      const _t = (map) => map[this.languageValue] || map.nl
      this._showToast?.(_t({
        nl: 'Geen gesprek om te kopiëren',
        fr: 'Aucune conversation à copier',
        de: 'Kein Gespräch zum Kopieren',
        en: 'No conversation to copy'
      }), 'info')
      return
    }

    const labels = this._getExportLabels()
    const brand = this._getBrandName()
    const date = this._getExportDate()

    let text = `${brand} - ${date}\n${'─'.repeat(50)}\n\n`
    pairs.forEach((p, i) => {
      text += `${labels.question} ${i + 1}:\n${p.question}\n\n`
      text += `${labels.answer}:\n${p.answer}\n\n`
      if (i < pairs.length - 1) text += `${'─'.repeat(50)}\n\n`
    })
    text += `${'─'.repeat(50)}\n⚠ ${labels.disclaimer}\n${brand} · ${labels.domain}`

    navigator.clipboard.writeText(text).then(() => {
      this._trackEvent('chatbot-copy-conversation')
      const _t = (map) => map[this.languageValue] || map.nl
      this._showToast?.(_t({
        nl: '📋 Gesprek gekopieerd',
        fr: '📋 Conversation copiée',
        de: '📋 Gespräch kopiert',
        en: '📋 Conversation copied'
      }), 'success')
    }).catch(err => {
      console.error('Failed to copy conversation:', err)
    })
  },

  // ── Export single answer as PDF (per-message) ──

  exportPDFSingle(event) {
    const button = event.currentTarget
    const messageDiv = button.closest("[data-message-id]")?.parentElement?.parentElement
    if (!messageDiv) return

    const contentDiv = messageDiv.querySelector(".message-content")
    if (!contentDiv) return

    const answerText = contentDiv.innerText || contentDiv.textContent || ''

    // Find the question from conversation history
    let question = ''
    const msgId = parseInt(messageDiv.querySelector("[data-message-id]")?.dataset?.messageId || button.closest("[data-message-id]")?.dataset?.messageId)
    for (let i = this.conversationHistory.length - 1; i >= 0; i--) {
      if (this.conversationHistory[i].role === 'assistant' &&
          this.conversationHistory[i].content?.substring(0, 50) === answerText.substring(0, 50)) {
        if (i > 0 && this.conversationHistory[i - 1].role === 'user') {
          question = this.conversationHistory[i - 1].content
        }
        break
      }
    }
    if (!question) {
      const lastUser = this.conversationHistory.filter(m => m.role === 'user').pop()
      question = lastUser?.content || ''
    }

    const brand = this._getBrandName()
    const subtitle = this._getExportSubtitle()
    const date = this._getExportDate()
    const labels = this._getExportLabels()

    const html = `<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<title>${brand} - ${this._escapeHtml(question.substring(0, 60))}</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap');
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: 'Inter', sans-serif; font-size: 10.5pt; color: #1e293b; background: #fff; }
  .header { background: linear-gradient(135deg, #0f172a 0%, #1e293b 60%, #334155 100%); color: #fff; padding: 32px 48px 28px; position: relative; overflow: hidden; }
  .header::after { content: '⚖'; position: absolute; right: 40px; top: 50%; transform: translateY(-50%); font-size: 64pt; opacity: 0.06; }
  .header .brand-row { display: flex; align-items: baseline; gap: 12px; margin-bottom: 6px; }
  .header .brand-name { font-size: 22pt; font-weight: 700; color: #c9a962; letter-spacing: -0.5px; }
  .header .brand-subtitle { font-size: 10pt; font-weight: 400; color: rgba(255,255,255,0.65); }
  .header .meta { font-size: 8.5pt; color: rgba(255,255,255,0.45); margin-top: 10px; }
  .accent-bar { height: 3px; background: linear-gradient(90deg, #c9a962, #e8d5a0, #c9a962); }
  .content { padding: 32px 48px; }
  .question-block { display: flex; align-items: flex-start; gap: 12px; background: linear-gradient(135deg, #faf8f4, #f8f6f0); border: 1px solid #e8e0d0; border-left: 4px solid #c9a962; border-radius: 0 10px 10px 0; padding: 14px 18px; margin-bottom: 12px; }
  .question-icon { flex-shrink: 0; width: 28px; height: 28px; background: #c9a962; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-size: 12pt; color: #fff; }
  .question-label { font-size: 7.5pt; font-weight: 600; text-transform: uppercase; letter-spacing: 1px; color: #a08840; margin-bottom: 4px; }
  .question-text { font-weight: 600; color: #1e293b; line-height: 1.5; font-size: 11pt; }
  .answer-block { padding: 4px 18px 4px 56px; line-height: 1.7; color: #334155; white-space: pre-wrap; font-size: 10.5pt; }
  .footer { margin-top: 40px; padding: 20px 48px; background: #fafaf8; border-top: 1px solid #e8e0d0; }
  .footer-disclaimer { font-size: 7.5pt; color: #94a3b8; font-style: italic; margin-bottom: 8px; }
  .footer-brand { font-size: 8pt; color: #64748b; display: flex; justify-content: space-between; }
  .footer-brand .gold { color: #c9a962; font-weight: 600; }
  @media print { body { padding: 0; } .header { padding: 24px 32px 20px; } .content { padding: 24px 32px; } .footer { padding: 16px 32px; } .answer-block { padding-left: 44px; } }
  @page { margin: 0; size: A4; }
</style>
</head><body>
<div class="header">
  <div class="brand-row"><span class="brand-name">${brand}</span><span class="brand-subtitle">${subtitle}</span></div>
  <div class="meta">${labels.generated} ${date}</div>
</div>
<div class="accent-bar"></div>
<div class="content">
  <div class="question-block">
    <div class="question-icon">?</div>
    <div>
      <div class="question-label">${labels.question}</div>
      <div class="question-text">${this._escapeHtml(question)}</div>
    </div>
  </div>
  <div class="answer-block">${this._escapeHtml(answerText)}</div>
</div>
<div class="footer">
  <div class="footer-disclaimer">⚠ ${labels.disclaimer}</div>
  <div class="footer-brand"><span><span class="gold">${brand}</span> · ${labels.domain}</span><span>${labels.generated} ${date}</span></div>
</div>
</body></html>`

    const win = window.open('', '_blank')
    if (!win) {
      // Popup blocked
      const _t = (map) => map[this.languageValue] || map.nl
      this._showToast(_t({ nl: 'Pop-up geblokkeerd — sta pop-ups toe om te exporteren', fr: 'Pop-up bloqué — autorisez les pop-ups pour exporter', de: 'Pop-up blockiert — erlauben Sie Pop-ups zum Exportieren', en: 'Popup blocked — allow popups to export' }), 'error')
      return
    }
    win.document.write(html)
    win.document.close()
    setTimeout(() => { win.print() }, 500)
    this._trackEvent('export_single_answer', { format: 'pdf' })

    // Visual feedback
    button.classList.add("text-green-500")
    setTimeout(() => button.classList.remove("text-green-500"), 2000)
  },

  // Build structured conversation data from history

  _getExportConversation() {
    const pairs = []
    const hist = this.conversationHistory || []
    for (let i = 0; i < hist.length; i++) {
      if (hist[i].role === 'user') {
        const answer = (i + 1 < hist.length && hist[i + 1].role === 'assistant')
          ? hist[i + 1].content : ''
        pairs.push({ question: hist[i].content, answer })
      }
    }
    return pairs
  },


  _getExportTitle() {
    const first = this.conversationHistory?.find(m => m.role === 'user')?.content || 'Conversation'
    return first.length > 60 ? first.substring(0, 57) + '...' : first
  },

  _getExportDate() {
    const lang = this.languageValue || 'nl'
    const locale = { nl: 'nl-BE', fr: 'fr-BE', de: 'de-DE', en: 'en-GB' }[lang] || 'nl-BE'
    return new Date().toLocaleDateString(locale, {
      year: 'numeric', month: 'long', day: 'numeric', hour: '2-digit', minute: '2-digit'
    })
  },

  _getBrandName() {
    const lang = this.languageValue || 'nl'
    switch (lang) {
      case 'fr': return 'LisLoi'
      case 'de': return 'GesetzGuide'
      case 'en': return 'LexLibera'
      default: return 'WetWijzer'
    }
  },

  _getExportSubtitle() {
    const lang = this.languageValue || 'nl'
    switch (lang) {
      case 'fr': return 'Par IA'
      case 'de': return 'Von KI'
      case 'en': return 'By AI'
      default: return 'Door AI'
    }
  },

  _getExportLabels() {
    const lang = this.languageValue || 'nl'
    return {
      question: { nl: 'Vraag', fr: 'Question', de: 'Frage', en: 'Question' }[lang],
      answer: { nl: 'Antwoord', fr: 'Réponse', de: 'Antwort', en: 'Answer' }[lang],
      generated: { nl: 'Gegenereerd op', fr: 'Généré le', de: 'Erstellt am', en: 'Generated on' }[lang],
      disclaimer: {
        nl: 'Door AI gegenereerd - geen juridisch advies.',
        fr: 'Généré par IA - ne constitue pas un avis juridique.',
        de: 'Von KI erstellt - keine Rechtsberatung.',
        en: 'AI-generated - not legal advice.'
      }[lang],
      domain: { nl: 'wetwijzer.be', fr: 'lisloi.be', de: 'gesetzguide.be', en: 'lexlibera.be' }[lang]
    }
  },

  // ── PDF Export (via window.print with styled print stylesheet) ──

  exportPDF() {
    this._closeExportMenu()
    const pairs = this._getExportConversation()
    if (pairs.length === 0) return

    const brand = this._getBrandName()
    const subtitle = this._getExportSubtitle()
    const date = this._getExportDate()
    const title = this._getExportTitle()
    const labels = this._getExportLabels()

    const html = `<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<title>${brand} - ${title}</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap');
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
    font-size: 10.5pt; color: #1e293b; padding: 0; margin: 0;
    background: #ffffff;
  }

  /* ── Header band ── */
  .header {
    background: linear-gradient(135deg, #0f172a 0%, #1e293b 60%, #334155 100%);
    color: #ffffff;
    padding: 32px 48px 28px;
    position: relative;
    overflow: hidden;
  }
  .header::after {
    content: '⚖';
    position: absolute;
    right: 40px; top: 50%;
    transform: translateY(-50%);
    font-size: 64pt;
    opacity: 0.06;
  }
  .header .brand-row {
    display: flex;
    align-items: baseline;
    gap: 12px;
    margin-bottom: 6px;
  }
  .header .brand-name {
    font-size: 22pt;
    font-weight: 700;
    color: #c9a962;
    letter-spacing: -0.5px;
  }
  .header .brand-subtitle {
    font-size: 10pt;
    font-weight: 400;
    color: rgba(255,255,255,0.65);
    letter-spacing: 0.5px;
  }
  .header .title {
    font-size: 13pt;
    font-weight: 500;
    color: rgba(255,255,255,0.9);
    margin-top: 8px;
    line-height: 1.4;
  }
  .header .meta {
    font-size: 8.5pt;
    color: rgba(255,255,255,0.45);
    margin-top: 10px;
    letter-spacing: 0.3px;
  }

  /* ── Gold accent bar ── */
  .accent-bar {
    height: 3px;
    background: linear-gradient(90deg, #c9a962, #e8d5a0, #c9a962);
  }

  /* ── Content ── */
  .content {
    padding: 32px 48px;
  }

  /* ── Q&A pair ── */
  .qa-pair {
    margin-bottom: 28px;
    page-break-inside: avoid;
  }
  .qa-pair:last-child { margin-bottom: 0; }

  .question-block {
    display: flex;
    align-items: flex-start;
    gap: 12px;
    background: linear-gradient(135deg, #faf8f4 0%, #f8f6f0 100%);
    border: 1px solid #e8e0d0;
    border-left: 4px solid #c9a962;
    border-radius: 0 10px 10px 0;
    padding: 14px 18px;
    margin-bottom: 12px;
  }
  .question-icon {
    flex-shrink: 0;
    width: 28px; height: 28px;
    background: #c9a962;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 12pt;
    color: #ffffff;
    margin-top: 1px;
  }
  .question-text {
    font-weight: 600;
    color: #1e293b;
    line-height: 1.5;
    font-size: 11pt;
  }
  .question-label {
    font-size: 7.5pt;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: #a08840;
    margin-bottom: 4px;
  }

  .answer-block {
    padding: 4px 18px 4px 56px;
    line-height: 1.7;
    color: #334155;
    white-space: pre-wrap;
    font-size: 10.5pt;
  }

  .qa-divider {
    border: none;
    border-top: 1px solid #f1ede4;
    margin: 24px 48px;
  }

  /* ── Footer ── */
  .footer {
    margin-top: 40px;
    padding: 20px 48px;
    background: #fafaf8;
    border-top: 1px solid #e8e0d0;
  }
  .footer-disclaimer {
    font-size: 7.5pt;
    color: #94a3b8;
    line-height: 1.5;
    font-style: italic;
    margin-bottom: 8px;
  }
  .footer-brand {
    font-size: 8pt;
    color: #64748b;
    display: flex;
    justify-content: space-between;
    align-items: center;
  }
  .footer-brand .gold { color: #c9a962; font-weight: 600; }

  /* ── Print ── */
  @media print {
    body { padding: 0; }
    .header { padding: 24px 32px 20px; }
    .content { padding: 24px 32px; }
    .footer { padding: 16px 32px; }
    .qa-divider { margin: 20px 32px; }
    .answer-block { padding-left: 44px; }
  }
  @page { margin: 0; size: A4; }
</style>
</head><body>
<div class="header">
  <div class="brand-row">
    <span class="brand-name">${brand}</span>
    <span class="brand-subtitle">${subtitle}</span>
  </div>
  <div class="title">💬 ${this._escapeHtml(title)}</div>
  <div class="meta">${labels.generated} ${date} · ${pairs.length} ${labels.question.toLowerCase()}${pairs.length !== 1 ? (this.languageValue === 'en' ? 's' : '') : ''}</div>
</div>
<div class="accent-bar"></div>
<div class="content">
${pairs.map((p, i) => `
<div class="qa-pair">
  <div class="question-block">
    <div class="question-icon">?</div>
    <div>
      <div class="question-label">${labels.question} ${i + 1}</div>
      <div class="question-text">${this._escapeHtml(p.question)}</div>
    </div>
  </div>
  <div class="answer-block">${this._escapeHtml(p.answer)}</div>
</div>${i < pairs.length - 1 ? '<hr class="qa-divider">' : ''}`).join('')}
</div>
<div class="footer">
  <div class="footer-disclaimer">⚠ ${labels.disclaimer}</div>
  <div class="footer-brand">
    <span><span class="gold">${brand}</span> · ${labels.domain}</span>
    <span>${labels.generated} ${date}</span>
  </div>
</div>
</body></html>`

    const win = window.open('', '_blank')
    if (!win) {
      // Popup blocked
      const _t = (map) => map[this.languageValue] || map.nl
      this._showToast(_t({ nl: 'Pop-up geblokkeerd — sta pop-ups toe om te exporteren', fr: 'Pop-up bloqué — autorisez les pop-ups pour exporter', de: 'Pop-up blockiert — erlauben Sie Pop-ups zum Exportieren', en: 'Popup blocked — allow popups to export' }), 'error')
      return
    }
    win.document.write(html)
    win.document.close()
    setTimeout(() => { win.print() }, 500)
    this._trackEvent('export_conversation', { format: 'pdf' })
  },

  // ── Word Export (.docx via HTML-in-blob trick) ──

  exportWordConversation() {
    this._closeExportMenu()
    const pairs = this._getExportConversation()
    if (pairs.length === 0) return

    const brand = this._getBrandName()
    const subtitle = this._getExportSubtitle()
    const date = this._getExportDate()
    const title = this._getExportTitle()
    const labels = this._getExportLabels()

    const content = `
<html xmlns:o="urn:schemas-microsoft-com:office:office"
      xmlns:w="urn:schemas-microsoft-com:office:word"
      xmlns="http://www.w3.org/TR/REC-html40">
<head><meta charset="utf-8">
<style>
  body { font-family: Calibri, sans-serif; font-size: 11pt; color: #1e293b; }
  h1 { font-size: 18pt; color: #0f172a; border-bottom: 3px solid #c9a962; padding-bottom: 10px; margin-bottom: 4px; }
  h1 span { color: #c9a962; }
  .subtitle { font-size: 10pt; color: #64748b; margin-bottom: 4px; }
  .date { font-size: 9pt; color: #94a3b8; margin-bottom: 20px; }
  .question { background: #faf8f4; border-left: 4px solid #c9a962; padding: 10px 14px; font-weight: bold; margin-top: 20px; color: #1e293b; }
  .question-label { font-size: 8pt; color: #a08840; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 4px; font-weight: bold; }
  .answer { padding: 8px 14px 8px 18px; line-height: 1.7; white-space: pre-wrap; color: #334155; }
  .divider { border: none; border-top: 1px solid #e8e0d0; margin: 16px 0; }
  .footer { margin-top: 28px; border-top: 2px solid #c9a962; padding-top: 10px; font-size: 8pt; color: #94a3b8; font-style: italic; }
  .footer-brand { font-size: 9pt; color: #64748b; margin-top: 6px; }
  .footer-brand span { color: #c9a962; font-weight: bold; }
</style></head><body>
<h1><span>${brand}</span> - ${subtitle}</h1>
<p class="subtitle">💬 ${this._escapeHtml(title)}</p>
<p class="date">${labels.generated} ${date}</p>
${pairs.map((p, i) => `
<p class="question-label">${labels.question} ${i + 1}</p>
<div class="question">${this._escapeHtml(p.question)}</div>
<div class="answer">${this._escapeHtml(p.answer)}</div>
${i < pairs.length - 1 ? '<hr class="divider">' : ''}
`).join('')}
<p class="footer">⚠ ${labels.disclaimer}</p>
<p class="footer-brand"><span>${brand}</span> · ${labels.domain} · ${labels.generated} ${date}</p>
</body></html>`

    const blob = new Blob([content], { type: 'application/msword' })
    this._downloadBlob(blob, `${brand}_chat_${this._fileDate()}.doc`)
    this._trackEvent('export_conversation', { format: 'word' })
  },

  // ── Typst Export (.typ) ──

  exportTypstConversation() {
    this._closeExportMenu()
    const pairs = this._getExportConversation()
    if (pairs.length === 0) return

    const brand = this._getBrandName()
    const subtitle = this._getExportSubtitle()
    const date = this._getExportDate()
    const title = this._getExportTitle()
    const labels = this._getExportLabels()

    // Escape Typst special chars
    const esc = (s) => (s || '').replace(/\\/g, '\\\\').replace(/[#$*_@~`<>]/g, m => '\\' + m)

    let typ = `// ${esc(brand)} – https://typst.app to compile\n`
    typ += `#set document(title: "${esc(brand)} ${esc(subtitle)}", author: "${esc(brand)}")\n`
    typ += `#set page(margin: 2cm)\n`
    typ += `#set text(font: "New Computer Modern", size: 11pt, lang: "${this.languageValue || 'nl'}")\n`
    typ += `#set par(justify: true)\n\n`
    typ += `#align(center, text(size: 18pt, weight: "bold")[${esc(brand)} – ${esc(subtitle)}])\n\n`
    typ += `#text(size: 10pt, fill: luma(100))[${esc(title)}]\n\n`
    typ += `#align(right, text(size: 9pt, fill: luma(120))[${esc(labels.generated)} ${esc(date)}])\n\n`
    typ += `#line(length: 100%, stroke: 1pt + luma(200))\n\n`

    pairs.forEach((p, i) => {
      typ += `#rect(fill: luma(245), width: 100%, inset: 10pt, stroke: (left: 3pt + luma(180)))[\n`
      typ += `  #text(size: 8pt, weight: "bold", fill: luma(100))[${esc(labels.question)} ${i + 1}]\n\n`
      typ += `  *${esc(p.question)}*\n]\n\n`
      typ += `${esc(p.answer)}\n\n`
      if (i < pairs.length - 1) {
        typ += `#line(length: 100%, stroke: 0.5pt + luma(220))\n\n`
      }
    })

    typ += `#v(1fr)\n`
    typ += `#line(length: 100%, stroke: 1pt + luma(200))\n`
    typ += `#text(size: 8pt, fill: luma(140))[⚠ ${esc(labels.disclaimer)}]\n\n`
    typ += `#text(size: 8pt, fill: luma(140))[${esc(brand)} · ${esc(labels.domain)} · ${esc(labels.generated)} ${esc(date)}]\n`

    const blob = new Blob([typ], { type: 'text/plain;charset=utf-8' })
    this._downloadBlob(blob, `${brand}_chat_${this._fileDate()}.typ`)
    this._trackEvent('export_conversation', { format: 'typst' })
  },

  // ── ODT Export (.fodt – Flat ODF) ──

  exportOdtConversation() {
    this._closeExportMenu()
    const pairs = this._getExportConversation()
    if (pairs.length === 0) return

    const brand = this._getBrandName()
    const subtitle = this._getExportSubtitle()
    const date = this._getExportDate()
    const title = this._getExportTitle()
    const labels = this._getExportLabels()
    const esc = (s) => (s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

    let body = ''
    body += `<text:h text:style-name="Heading_20_1" text:outline-level="1">${esc(brand)} – ${esc(subtitle)}</text:h>\n`
    body += `<text:p text:style-name="Standard">${esc(title)}</text:p>\n`
    body += `<text:p text:style-name="Subtle">${esc(labels.generated)} ${esc(date)}</text:p>\n`
    body += `<text:p text:style-name="Horizontal_20_Line"/>\n`

    pairs.forEach((p, i) => {
      body += `<text:h text:style-name="Heading_20_3" text:outline-level="3">${esc(labels.question)} ${i + 1}</text:h>\n`
      body += `<text:p text:style-name="Standard"><text:span text:style-name="Bold">${esc(p.question)}</text:span></text:p>\n`
      const answerParas = (p.answer || '').split(/\n\n+/)
      for (const para of answerParas) {
        const trimmed = para.trim()
        if (!trimmed) continue
        body += `<text:p text:style-name="Standard">${esc(trimmed)}</text:p>\n`
      }
      if (i < pairs.length - 1) {
        body += `<text:p text:style-name="Horizontal_20_Line"/>\n`
      }
    })

    body += `<text:p text:style-name="Horizontal_20_Line"/>\n`
    body += `<text:p text:style-name="Subtle">⚠ ${esc(labels.disclaimer)}</text:p>\n`
    body += `<text:p text:style-name="Subtle">${esc(brand)} · ${esc(labels.domain)} · ${esc(labels.generated)} ${esc(date)}</text:p>\n`

    const fodt = this._buildFodtDocument(body, `${brand} ${subtitle}`, brand)
    const blob = new Blob([fodt], { type: 'application/vnd.oasis.opendocument.text' })
    this._downloadBlob(blob, `${brand}_chat_${this._fileDate()}.fodt`)
    this._trackEvent('export_conversation', { format: 'odt' })
  },

  // ── Plain Text Export (.txt) ──

  exportTXT() {
    this._closeExportMenu()
    const pairs = this._getExportConversation()
    if (pairs.length === 0) return

    const brand = this._getBrandName()
    const subtitle = this._getExportSubtitle()
    const date = this._getExportDate()
    const labels = this._getExportLabels()
    const divider = '━'.repeat(60)
    const thinDiv = '─'.repeat(60)

    let text = `${divider}\n`
    text += `  ${brand} - ${subtitle}\n`
    text += `  ${labels.generated} ${date}\n`
    text += `${divider}\n\n`

    pairs.forEach((p, i) => {
      text += `┌─ ${labels.question} ${i + 1} ${'─'.repeat(Math.max(0, 50 - labels.question.length - String(i+1).length))}\n`
      text += `│  ${p.question}\n`
      text += `└${'─'.repeat(59)}\n\n`
      text += `   ${labels.answer}:\n`
      text += `   ${p.answer.split('\n').join('\n   ')}\n\n`
      if (i < pairs.length - 1) text += `${thinDiv}\n\n`
    })

    text += `\n${divider}\n`
    text += `  ⚠ ${labels.disclaimer}\n`
    text += `  ${brand} · ${labels.domain}\n`
    text += `${divider}\n`

    const blob = new Blob([text], { type: 'text/plain;charset=utf-8' })
    this._downloadBlob(blob, `${brand}_chat_${this._fileDate()}.txt`)
    this._trackEvent('export_conversation', { format: 'txt' })
  },

  // Helper: trigger file download from blob

  _downloadBlob(blob, filename) {
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = filename
    document.body.appendChild(a)
    a.click()
    document.body.removeChild(a)
    URL.revokeObjectURL(url)
  },

  // Helper: build Flat ODF document (.fodt) – single XML file, no ZIP needed
  // Supported by LibreOffice, Google Docs, and most ODF-compatible processors

  _buildFodtDocument(bodyXml, title = '', author = '') {
    const esc = (s) => (s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
    return `<?xml version="1.0" encoding="UTF-8"?>
<office:document
  xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
  xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
  xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
  xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
  xmlns:dc="http://purl.org/dc/elements/1.1/"
  xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0"
  office:version="1.3" office:mimetype="application/vnd.oasis.opendocument.text">
  <office:meta>
    <dc:title>${esc(title)}</dc:title>
    <dc:creator>${esc(author)}</dc:creator>
    <meta:creation-date>${new Date().toISOString()}</meta:creation-date>
    <meta:generator>${esc(author)} FODT Export</meta:generator>
  </office:meta>
  <office:styles>
    <style:style style:name="Standard" style:family="paragraph">
      <style:text-properties fo:font-family="Liberation Serif" fo:font-size="11pt"/>
      <style:paragraph-properties fo:text-align="justify" fo:margin-bottom="0.3cm"/>
    </style:style>
    <style:style style:name="Heading_20_1" style:family="paragraph" style:parent-style-name="Standard" style:next-style-name="Standard" style:class="text">
      <style:text-properties fo:font-size="18pt" fo:font-weight="bold" fo:color="#1e3a5f"/>
      <style:paragraph-properties fo:margin-top="0.5cm" fo:margin-bottom="0.3cm" fo:keep-with-next="always"/>
    </style:style>
    <style:style style:name="Heading_20_2" style:family="paragraph" style:parent-style-name="Standard" style:next-style-name="Standard" style:class="text">
      <style:text-properties fo:font-size="15pt" fo:font-weight="bold" fo:color="#2c5282"/>
      <style:paragraph-properties fo:margin-top="0.4cm" fo:margin-bottom="0.2cm" fo:keep-with-next="always"/>
    </style:style>
    <style:style style:name="Heading_20_3" style:family="paragraph" style:parent-style-name="Standard" style:next-style-name="Standard" style:class="text">
      <style:text-properties fo:font-size="13pt" fo:font-weight="bold" fo:color="#2d3748"/>
      <style:paragraph-properties fo:margin-top="0.3cm" fo:margin-bottom="0.2cm" fo:keep-with-next="always"/>
    </style:style>
  </office:styles>
  <office:automatic-styles>
    <style:style style:name="Bold" style:family="text">
      <style:text-properties fo:font-weight="bold"/>
    </style:style>
    <style:style style:name="Subtle" style:family="paragraph" style:parent-style-name="Standard">
      <style:text-properties fo:font-size="9pt" fo:color="#888888"/>
    </style:style>
    <style:style style:name="Horizontal_20_Line" style:family="paragraph">
      <style:paragraph-properties fo:border-bottom="0.5pt solid #999999" fo:padding-bottom="6pt" fo:margin-bottom="6pt"/>
    </style:style>
    <style:page-layout style:name="pm1">
      <style:page-layout-properties fo:page-width="21cm" fo:page-height="29.7cm" fo:margin-top="2cm" fo:margin-bottom="2cm" fo:margin-left="2cm" fo:margin-right="2cm"/>
    </style:page-layout>
  </office:automatic-styles>
  <office:master-styles>
    <style:master-page style:name="Standard" style:page-layout-name="pm1"/>
  </office:master-styles>
  <office:body>
    <office:text>
${bodyXml}
    </office:text>
  </office:body>
</office:document>`
  },

  // Helper: date string for filenames (YYYY-MM-DD)

  _fileDate() {
    return new Date().toISOString().split('T')[0]
  },

  // Helper: escape HTML special characters

  _escapeHtml(str) {
    if (!str) return ''
    const map = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }
    return str.replace(/[&<>"']/g, c => map[c])
  },
  // ═══════════════════════════════════════════════
  // PERSISTENCE - server-side profile for chatbot settings
  // ═══════════════════════════════════════════════

  // NOTE: _escapeHtml() is defined above (string-based .replace()).
  // DO NOT redefine it here — JS object literal property overwriting means
  // only the LAST definition survives, and the DOM-based version is slower.

  // NOTE: _handleSSEResponse is defined at line ~2819.
  // DO NOT add another definition here - JS classes use the last definition,
  // which caused the "no answer" bug when a duplicate expected parsed.chunk
  // instead of the server's {type:'result', data:{answer:...}} format.

  // ═══════════════════════════════════════════════
  // DRAG / RESIZE / RESET - Widget mobility
  // ═══════════════════════════════════════════════

  /**
   * Start dragging the widget (header mousedown / touchstart).
   * The entire #chatbot-widget-container is repositioned via top/left.
   */
}
