import { Controller } from "@hotwired/stimulus"

/**
 * Chatbot Controller
 * Handles the chatbot widget UI with streaming responses, conversation history,
 * and feedback mechanism.
 */
export default class extends Controller {
  static targets = [
    "input",
    "messages",
    "sendButton",
    "typingIndicator",
    "widget",
    "toggleButton",
    "badge",
    "languageSelect",
    "sourceSelect",
    "sourceLegislation",
    "sourceJurisprudence",
    "sourceParliamentary",
    "localToggle",
    "loading",
    "progressBar",
    "progressText"
  ]

  static values = {
    open: { type: Boolean, default: false },
    loading: { type: Boolean, default: false },
    apiEndpoint: { type: String, default: "/api/chatbot/ask" },
    localEndpoint: { type: String, default: "/api/local_chatbot/ask" },
    language: { type: String, default: "nl" },
    source: { type: String, default: "legislation,jurisprudence,parliamentary" },
    useLocal: { type: Boolean, default: false },
    pass: { type: String, default: "" }
  }

  connect() {
    this.conversationHistory = []
    this.conversationId = null  // Server-side conversation token for context
    this.messageCount = 0
    
    // Load preferences from localStorage
    this.loadPreferences()
    
    // Set initial state
    if (this.hasWidgetTarget) {
      this.widgetTarget.classList.toggle("hidden", !this.openValue)
    }
    
    // Add welcome message if messages area is empty (widget mode)
    if (this.hasMessagesTarget && this.messagesTarget.children.length === 0) {
      this.addWelcomeMessage()
    }
  }

  disconnect() {
    this.savePreferences()
  }

  // Toggle widget open/closed
  toggle() {
    this.openValue = !this.openValue
    if (this.hasWidgetTarget) {
      this.widgetTarget.classList.toggle("hidden", !this.openValue)
    }
    if (this.openValue && this.hasInputTarget) {
      this.inputTarget.focus()
    }
    // Clear badge when opening
    if (this.openValue && this.hasBadgeTarget) {
      this.badgeTarget.classList.add("hidden")
    }
  }

  // Close widget
  close() {
    this.openValue = false
    if (this.hasWidgetTarget) {
      this.widgetTarget.classList.add("hidden")
    }
  }

  // Handle input keydown (Enter to send)
  handleKeydown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.send()
    }
  }

  // Update language preference
  updateLanguage(event) {
    this.languageValue = event.target.value
    this.savePreferences()
  }

  // Update source preference (legacy dropdown)
  updateSource(event) {
    this.sourceValue = event.target.value
    this.savePreferences()
  }

  // Update sources from checkboxes
  updateSources() {
    const sources = []
    
    if (this.hasSourceLegislationTarget && this.sourceLegislationTarget.checked) {
      sources.push('legislation')
    }
    if (this.hasSourceJurisprudenceTarget && this.sourceJurisprudenceTarget.checked) {
      sources.push('jurisprudence')
    }
    if (this.hasSourceParliamentaryTarget && this.sourceParliamentaryTarget.checked) {
      sources.push('parliamentary')
    }
    
    // Convert to source value: single source or 'all' for multiple
    if (sources.length === 0) {
      // Default to legislation if nothing selected
      this.sourceValue = 'legislation'
      if (this.hasSourceLegislationTarget) {
        this.sourceLegislationTarget.checked = true
      }
    } else if (sources.length === 1) {
      this.sourceValue = sources[0]
    } else {
      // Multiple sources selected - use custom format
      this.sourceValue = sources.join(',')
    }
    
    this.savePreferences()
  }

  // Get currently selected sources as array
  getSelectedSources() {
    const sources = []
    if (this.hasSourceLegislationTarget && this.sourceLegislationTarget.checked) {
      sources.push('legislation')
    }
    if (this.hasSourceJurisprudenceTarget && this.sourceJurisprudenceTarget.checked) {
      sources.push('jurisprudence')
    }
    if (this.hasSourceParliamentaryTarget && this.sourceParliamentaryTarget.checked) {
      sources.push('parliamentary')
    }
    return sources.length > 0 ? sources : ['legislation']
  }

  // Toggle local/cloud
  toggleLocal(event) {
    this.useLocalValue = event.target.checked
    this.savePreferences()
  }

  // Send message
  async send() {
    if (this.loadingValue) return

    const question = this.inputTarget.value.trim()
    if (!question) return

    // Add user message to UI
    this.addMessage("user", question)
    this.inputTarget.value = ""

    // Add to conversation history
    this.conversationHistory.push({ role: "user", content: question })

    // Show loading state
    this.loadingValue = true
    this.updateLoadingState()
    this.startProgress()

    try {
      const endpoint = this.useLocalValue ? this.localEndpointValue : this.apiEndpointValue
      
      const response = await fetch(endpoint, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken
        },
        body: JSON.stringify({
          question: question,
          language: this.languageValue,
          source: this.sourceValue,
          sources: this.getSelectedSources(),
          pass: this.passValue,
          conversation_id: this.conversationId  // Server-side context for follow-ups
        })
      })

      const data = await response.json()

      // Hide loading as soon as response arrives
      this.stopProgress()
      this.loadingValue = false
      this.updateLoadingState()

      if (data.error) {
        this.addMessage("error", data.error)
      } else {
        // Save conversation_id for follow-up questions
        if (data.conversation_id) {
          this.conversationId = data.conversation_id
        }
        
        // Stream the response for better UX
        await this.streamMessage("assistant", data.answer, data.sources, data.response_time)
        
        // Add to conversation history
        this.conversationHistory.push({ role: "assistant", content: data.answer })
        
        // Show follow-up suggestions if available
        if (data.suggestions && data.suggestions.length > 0) {
          this.showSuggestions(data.suggestions)
        }
      }
    } catch (error) {
      console.error("Chatbot error:", error)
      this.stopProgress()
      this.loadingValue = false
      this.updateLoadingState()
      this.addMessage("error", this.languageValue === "fr" 
        ? "Erreur de connexion. Veuillez réessayer."
        : "Verbindingsfout. Probeer opnieuw.")
    }
  }

  // Add message to chat
  addMessage(role, content, sources = null, responseTime = null) {
    const messageDiv = document.createElement("div")
    messageDiv.className = this.getMessageClasses(role)
    messageDiv.dataset.messageId = ++this.messageCount

    const contentDiv = document.createElement("div")
    contentDiv.className = "message-content"
    contentDiv.innerHTML = this.formatMessage(content)
    messageDiv.appendChild(contentDiv)

    // Add sources if present
    if (sources && sources.length > 0) {
      const sourcesDiv = this.createSourcesElement(sources)
      messageDiv.appendChild(sourcesDiv)
    }

    // Add metadata (response time, feedback)
    if (role === "assistant") {
      const metaDiv = this.createMetaElement(responseTime, this.messageCount)
      messageDiv.appendChild(metaDiv)
    }

    this.messagesTarget.appendChild(messageDiv)
    this.scrollToBottom()
  }

  // Stream message character by character for better UX
  async streamMessage(role, content, sources = null, responseTime = null) {
    const messageDiv = document.createElement("div")
    messageDiv.className = this.getMessageClasses(role)
    messageDiv.dataset.messageId = ++this.messageCount

    const contentDiv = document.createElement("div")
    contentDiv.className = "message-content"
    messageDiv.appendChild(contentDiv)

    this.messagesTarget.appendChild(messageDiv)

    // Stream characters
    const chars = content.split("")
    let displayed = ""
    
    for (let i = 0; i < chars.length; i++) {
      displayed += chars[i]
      contentDiv.innerHTML = this.formatMessage(displayed)
      
      // Scroll every few characters
      if (i % 10 === 0) {
        this.scrollToBottom()
      }
      
      // Small delay for streaming effect (faster for longer messages)
      const delay = content.length > 500 ? 5 : 15
      await new Promise(resolve => setTimeout(resolve, delay))
    }

    // Add sources after streaming
    if (sources && sources.length > 0) {
      const sourcesDiv = this.createSourcesElement(sources)
      messageDiv.appendChild(sourcesDiv)
    }

    // Add metadata
    const metaDiv = this.createMetaElement(responseTime, this.messageCount)
    messageDiv.appendChild(metaDiv)

    this.scrollToBottom()
  }

  // Create sources element
  createSourcesElement(sources) {
    const div = document.createElement("div")
    div.className = "message-sources mt-2 pt-2 border-t border-gray-200 dark:border-gray-600 text-xs"
    
    const label = this.languageValue === "fr" ? "Sources:" : "Bronnen:"
    let html = `<div class="font-medium text-gray-500 dark:text-gray-400 mb-1">${label}</div>`
    
    sources.forEach((source, index) => {
      const title = source.law_title || source.title || "Unknown"
      const relevance = source.relevance ? ` (${(source.relevance * 100).toFixed(0)}%)` : ""
      
      // Format: "Artikel X van de Law Title" or just "Law Title" if no article
      let displayText = title
      if (source.article_title) {
        // Extract article number from "Art.5" or "Art. 5" format
        const artMatch = source.article_title.match(/Art\.?\s*(\d+\S*)/i)
        if (artMatch) {
          const artNum = artMatch[1]
          const lang = this.languageValue
          const prefix = lang === "fr" ? `Article ${artNum} de la ` : `Artikel ${artNum} van de `
          displayText = prefix + title
        } else {
          displayText = source.article_title + " " + title
        }
      }
      
      if (source.url) {
        html += `<div class="text-blue-600 dark:text-blue-400 hover:underline">
          <a href="${source.url}" target="_blank">${index + 1}. ${displayText}${relevance}</a>
        </div>`
      } else {
        html += `<div class="text-gray-600 dark:text-gray-300">${index + 1}. ${displayText}${relevance}</div>`
      }
    })
    
    div.innerHTML = html
    return div
  }

  // Create metadata element with feedback buttons and copy button
  createMetaElement(responseTime, messageId) {
    const div = document.createElement("div")
    div.className = "message-meta mt-2 flex items-center justify-between text-xs text-gray-400"
    
    const timeText = responseTime ? `${responseTime}s` : ""
    const thumbsUp = this.languageValue === "fr" ? "Utile" : "Nuttig"
    const thumbsDown = this.languageValue === "fr" ? "Pas utile" : "Niet nuttig"
    const copyText = this.languageValue === "fr" ? "Copier" : "Kopiëren"
    
    div.innerHTML = `
      <span>${timeText}</span>
      <div class="feedback-buttons flex gap-2" data-message-id="${messageId}">
        <button type="button" 
                class="copy-btn hover:text-blue-500 transition-colors p-1 rounded"
                data-action="click->chatbot#copyAnswer"
                title="${copyText}">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" 
                  d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/>
          </svg>
        </button>
        <button type="button" 
                class="word-btn hover:text-blue-500 transition-colors p-1 rounded"
                data-action="click->chatbot#exportWord"
                title="Word">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" 
                  d="M12 10v6m0 0l-3-3m3 3l3-3m2 8H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"/>
          </svg>
        </button>
        <button type="button" 
                class="save-btn hover:text-yellow-500 transition-colors p-1 rounded"
                data-action="click->chatbot#saveAnswer"
                title="${this.languageValue === 'fr' ? 'Sauvegarder' : 'Opslaan'}">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" 
                  d="M5 5a2 2 0 012-2h10a2 2 0 012 2v16l-7-3.5L5 21V5z"/>
          </svg>
        </button>
        <button type="button" 
                class="feedback-btn hover:text-green-500 transition-colors p-1 rounded"
                data-action="click->chatbot#feedback"
                data-feedback="positive"
                title="${thumbsUp}">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" 
                  d="M14 10h4.764a2 2 0 011.789 2.894l-3.5 7A2 2 0 0115.263 21h-4.017c-.163 0-.326-.02-.485-.06L7 20m7-10V5a2 2 0 00-2-2h-.095c-.5 0-.905.405-.905.905 0 .714-.211 1.412-.608 2.006L7 11v9m7-10h-2M7 20H5a2 2 0 01-2-2v-6a2 2 0 012-2h2.5"/>
          </svg>
        </button>
        <button type="button"
                class="feedback-btn hover:text-red-500 transition-colors p-1 rounded"
                data-action="click->chatbot#feedback"
                data-feedback="negative"
                title="${thumbsDown}">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" 
                  d="M10 14H5.236a2 2 0 01-1.789-2.894l3.5-7A2 2 0 018.736 3h4.018a2 2 0 01.485.06l3.76.94m-7 10v5a2 2 0 002 2h.096c.5 0 .905-.405.905-.904 0-.715.211-1.413.608-2.008L17 13V4m-7 10h2m5-10h2a2 2 0 012 2v6a2 2 0 01-2 2h-2.5"/>
          </svg>
        </button>
      </div>
    `
    
    return div
  }

  // Handle feedback
  feedback(event) {
    const button = event.currentTarget
    const feedbackType = button.dataset.feedback
    const container = button.closest(".feedback-buttons")
    const messageId = container.dataset.messageId
    
    // Visual feedback
    container.querySelectorAll(".feedback-btn").forEach(btn => {
      btn.classList.remove("text-green-500", "text-red-500")
      btn.disabled = true
    })
    
    if (feedbackType === "positive") {
      button.classList.add("text-green-500")
    } else {
      button.classList.add("text-red-500")
    }

    // Send feedback to server
    this.sendFeedback(messageId, feedbackType)
  }

  // Send feedback to server
  async sendFeedback(messageId, feedbackType) {
    // Get the last question and answer from conversation history
    const historyLength = this.conversationHistory.length
    if (historyLength < 2) return

    const question = this.conversationHistory[historyLength - 2]?.content || ""
    const answer = this.conversationHistory[historyLength - 1]?.content || ""

    try {
      await fetch("/api/chatbot/feedback", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          question: question,
          answer: answer,
          feedback_type: feedbackType,
          language: this.languageValue,
          source: this.sourceValue
        })
      })
    } catch (error) {
      console.error("Failed to send feedback:", error)
    }
  }

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

    // Create Word-compatible HTML document
    const wordContent = `
      <html xmlns:o="urn:schemas-microsoft-com:office:office" 
            xmlns:w="urn:schemas-microsoft-com:office:word" 
            xmlns="http://www.w3.org/TR/REC-html40">
      <head>
        <meta charset="utf-8">
        <title>WetWijzer Chatbot Antwoord</title>
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
        <h2>WetWijzer Juridisch Antwoord</h2>
        <p><em>Gegenereerd op: ${new Date().toLocaleString()}</em></p>
        <hr>
        ${html}
        <hr>
        <p style="font-size: 9pt; color: #666;">
          Dit is geen officieel juridisch advies. Verifieer altijd bij officiële bronnen.<br>
          Bron: WetWijzer.be / LisLoi.be
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
  }

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
      alert(this.languageValue === 'fr' ? 'Aucune question à sauvegarder' : 'Geen vraag om op te slaan')
      return
    }

    const question = this.conversationHistory[historyLength - 2]?.content || ""
    const answer = contentDiv.innerText || contentDiv.textContent

    try {
      const response = await fetch("/api/chatbot/save", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
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
        const msg = this.languageValue === 'fr' 
          ? 'Connectez-vous pour sauvegarder les réponses' 
          : 'Log in om antwoorden op te slaan'
        alert(msg)
      } else {
        console.error("Save failed:", data.error)
      }
    } catch (error) {
      console.error("Failed to save:", error)
    }
  }

  // Copy answer to clipboard
  copyAnswer(event) {
    const button = event.currentTarget
    const messageDiv = button.closest("[data-message-id]")?.parentElement?.parentElement
    if (!messageDiv) return

    const contentDiv = messageDiv.querySelector(".message-content")
    if (!contentDiv) return

    // Get text content (strips HTML)
    const text = contentDiv.innerText || contentDiv.textContent

    navigator.clipboard.writeText(text).then(() => {
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
  }

  // Clear conversation
  clear() {
    this.conversationHistory = []
    this.conversationId = null  // Reset server-side conversation
    this.messagesTarget.innerHTML = ""
    this.addWelcomeMessage()
  }

  // Add welcome message
  addWelcomeMessage() {
    let welcome
    if (this.languageValue === "fr") {
      welcome = "Bonjour! Je suis l'assistant juridique LisLoi. Posez-moi une question sur la législation belge. Je réponds dans la langue de votre question."
    } else if (this.languageValue === "en") {
      welcome = "Hi! I'm the WetWijzer legal assistant. Ask me a question about Belgian law. I respond in your input language."
    } else {
      welcome = "Hallo! Ik ben de WetWijzer juridische assistent. Stel me een vraag over Belgische wetgeving. Ik antwoord in de taal van je vraag."
    }
    
    this.addMessage("assistant", welcome)
  }

  // Show follow-up suggestions as clickable buttons
  showSuggestions(suggestions) {
    // Remove any existing suggestions
    const existing = this.messagesTarget.querySelector(".suggestions-container")
    if (existing) existing.remove()

    const container = document.createElement("div")
    container.className = "suggestions-container flex flex-wrap gap-2 mt-3 mb-2 px-2"

    suggestions.forEach(suggestion => {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = "suggestion-btn text-xs px-3 py-1.5 bg-blue-50 dark:bg-blue-900/30 text-blue-700 dark:text-blue-300 rounded-full hover:bg-blue-100 dark:hover:bg-blue-900/50 transition-colors border border-blue-200 dark:border-blue-800"
      btn.textContent = suggestion
      btn.addEventListener("click", () => {
        // Remove suggestions when clicked
        container.remove()
        // Set the input value and submit
        this.inputTarget.value = suggestion
        this.ask()
      })
      container.appendChild(btn)
    })

    this.messagesTarget.appendChild(container)
    this.scrollToBottom()
  }

  // Format message (basic markdown support)
  formatMessage(content) {
    if (!content) return ""
    
    return content
      // Escape HTML first (but preserve markdown)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      // Markdown links [text](url) - must be before other formatting
      .replace(/\[([^\]]+)\]\((https?:\/\/[^\)]+)\)/g, '<a href="$2" target="_blank" class="text-blue-600 dark:text-blue-400 hover:underline">$1</a>')
      // Bold
      .replace(/\*\*(.*?)\*\*/g, "<strong>$1</strong>")
      // Italic
      .replace(/\*(.*?)\*/g, "<em>$1</em>")
      // Code
      .replace(/`(.*?)`/g, "<code class='bg-gray-100 dark:bg-gray-700 px-1 rounded'>$1</code>")
      // Line breaks
      .replace(/\n/g, "<br>")
  }

  // Get CSS classes for message
  getMessageClasses(role) {
    const base = "message p-3 rounded-lg mb-3 max-w-[85%]"
    
    switch (role) {
      case "user":
        return `${base} ml-auto bg-blue-500 text-white`
      case "assistant":
        return `${base} bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-200`
      case "error":
        return `${base} bg-red-100 dark:bg-red-900 text-red-700 dark:text-red-200`
      default:
        return base
    }
  }

  // Update loading state
  updateLoadingState() {
    if (this.hasSendButtonTarget) {
      this.sendButtonTarget.disabled = this.loadingValue
    }
    if (this.hasLoadingTarget) {
      this.loadingTarget.classList.toggle("hidden", !this.loadingValue)
    }
    if (this.hasTypingIndicatorTarget) {
      this.typingIndicatorTarget.classList.toggle("hidden", !this.loadingValue)
    }
    if (this.hasInputTarget) {
      this.inputTarget.disabled = this.loadingValue
    }
  }

  // Scroll to bottom of messages
  scrollToBottom() {
    if (this.hasMessagesTarget) {
      this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
    }
  }

  // Get CSRF token
  get csrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.content : ""
  }

  // Save preferences to localStorage
  savePreferences() {
    try {
      localStorage.setItem("chatbot_preferences", JSON.stringify({
        language: this.languageValue,
        source: this.sourceValue,
        useLocal: this.useLocalValue
      }))
    } catch (e) {
      // localStorage not available
    }
  }

  // Load preferences from localStorage
  loadPreferences() {
    try {
      const prefs = JSON.parse(localStorage.getItem("chatbot_preferences") || "{}")
      if (prefs.language) this.languageValue = prefs.language
      if (prefs.source) this.sourceValue = prefs.source
      if (prefs.useLocal !== undefined) this.useLocalValue = prefs.useLocal
      
      // Update UI elements
      if (this.hasLanguageSelectTarget) {
        this.languageSelectTarget.value = this.languageValue
      }
      if (this.hasSourceSelectTarget) {
        this.sourceSelectTarget.value = this.sourceValue
      }
      if (this.hasLocalToggleTarget) {
        this.localToggleTarget.checked = this.useLocalValue
      }
    } catch (e) {
      // localStorage not available or invalid data
    }
  }

  // Progress bar simulation (client-side)
  startProgress() {
    this.currentProgress = 0
    // Start with visible progress immediately
    this.updateProgressBar(5, this.languageValue === "fr" ? "Traitement..." : "Verwerken...")
    
    // Simulate progress over expected ~20 second duration
    const phases = this.languageValue === "fr" ? [
      { progress: 15, text: "Génération embedding", duration: 1000 },
      { progress: 30, text: "Recherche base de données", duration: 2000 },
      { progress: 50, text: "Recherche articles", duration: 4000 },
      { progress: 70, text: "Analyse des résultats", duration: 5000 },
      { progress: 85, text: "Construction contexte", duration: 4000 },
      { progress: 95, text: "Génération réponse", duration: 3000 }
    ] : [
      { progress: 15, text: "Embedding genereren", duration: 1000 },
      { progress: 30, text: "Database doorzoeken", duration: 2000 },
      { progress: 50, text: "Artikelen zoeken", duration: 4000 },
      { progress: 70, text: "Resultaten analyseren", duration: 5000 },
      { progress: 85, text: "Context opbouwen", duration: 4000 },
      { progress: 95, text: "Antwoord genereren", duration: 3000 }
    ]
    
    let currentPhase = 0
    const advancePhase = () => {
      if (currentPhase < phases.length && this.progressInterval) {
        const phase = phases[currentPhase]
        this.updateProgressBar(phase.progress, `${phase.text}... (${phase.progress}%)`)
        currentPhase++
        this.progressInterval = setTimeout(advancePhase, phase.duration)
      }
    }
    
    this.progressInterval = setTimeout(advancePhase, 500)
  }

  stopProgress() {
    if (this.progressInterval) {
      clearTimeout(this.progressInterval)
      this.progressInterval = null
    }
    this.updateProgressBar(100, "✓ Voltooid!")
    setTimeout(() => {
      this.currentProgress = 0
    }, 300)
  }

  updateProgressBar(progress, text) {
    this.currentProgress = progress
    if (this.hasProgressBarTarget) {
      this.progressBarTarget.style.width = `${progress}%`
    }
    if (this.hasProgressTextTarget) {
      this.progressTextTarget.textContent = text
    }
  }
}
