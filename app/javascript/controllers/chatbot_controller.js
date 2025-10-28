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
    source: { type: String, default: "jurisprudence" },
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

  // Update source preference
  updateSource(event) {
    this.sourceValue = event.target.value
    this.savePreferences()
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
          pass: this.passValue,
          conversation_id: this.conversationId  // Server-side context for follow-ups
        })
      })

      const data = await response.json()

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
      }
    } catch (error) {
      console.error("Chatbot error:", error)
      this.addMessage("error", this.languageValue === "fr" 
        ? "Erreur de connexion. Veuillez réessayer."
        : "Verbindingsfout. Probeer opnieuw.")
    } finally {
      this.stopProgress()
      this.loadingValue = false
      this.updateLoadingState()
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
      const article = source.article_title ? ` - ${source.article_title}` : ""
      const relevance = source.relevance ? ` (${(source.relevance * 100).toFixed(0)}%)` : ""
      
      if (source.url) {
        html += `<div class="text-blue-600 dark:text-blue-400 hover:underline">
          <a href="${source.url}" target="_blank">${index + 1}. ${title}${article}${relevance}</a>
        </div>`
      } else {
        html += `<div class="text-gray-600 dark:text-gray-300">${index + 1}. ${title}${article}${relevance}</div>`
      }
    })
    
    div.innerHTML = html
    return div
  }

  // Create metadata element with feedback buttons
  createMetaElement(responseTime, messageId) {
    const div = document.createElement("div")
    div.className = "message-meta mt-2 flex items-center justify-between text-xs text-gray-400"
    
    const timeText = responseTime ? `${responseTime}s` : ""
    const thumbsUp = this.languageValue === "fr" ? "Utile" : "Nuttig"
    const thumbsDown = this.languageValue === "fr" ? "Pas utile" : "Niet nuttig"
    
    div.innerHTML = `
      <span>${timeText}</span>
      <div class="feedback-buttons flex gap-2" data-message-id="${messageId}">
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

    // Log feedback (could send to server)
    console.log(`Feedback for message ${messageId}: ${feedbackType}`)
    
    // TODO: Send feedback to server for analytics
    // this.sendFeedback(messageId, feedbackType)
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
    const welcome = this.languageValue === "fr"
      ? "Bonjour! Je suis l'assistant juridique WetWijzer. Posez-moi une question sur la législation belge."
      : "Hallo! Ik ben de WetWijzer juridische assistent. Stel me een vraag over Belgische wetgeving."
    
    this.addMessage("assistant", welcome)
  }

  // Format message (basic markdown support)
  formatMessage(content) {
    if (!content) return ""
    
    return content
      // Escape HTML
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
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
    this.updateProgressBar(0, "Vraag wordt verwerkt... (0%)")
    
    // Simulate progress over expected ~35 second duration (based on actual response times)
    const phases = [
      { progress: 10, text: "Embedding genereren", duration: 1500 },
      { progress: 25, text: "Database doorzoeken", duration: 3000 },
      { progress: 45, text: "Relevante artikelen zoeken", duration: 6000 },
      { progress: 65, text: "Beste matches analyseren", duration: 10000 },
      { progress: 80, text: "Context opbouwen", duration: 8000 },
      { progress: 90, text: "Antwoord genereren", duration: 5000 },
      { progress: 98, text: "Afwerken", duration: 2000 }
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
    
    this.progressInterval = setTimeout(advancePhase, 300)
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
