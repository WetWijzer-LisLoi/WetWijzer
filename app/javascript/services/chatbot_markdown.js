// Pure markdown rendering for chatbot messages (FBL-062, extracted
// verbatim from chatbot_controller.js). String -> HTML-string only: no DOM,
// no Stimulus, no storage. The first transformation applied to every line
// is HTML escaping (quotes included, because inlineFormat interpolates into
// href="..."); everything this module returns is fed to innerHTML, so that
// escape path is the XSS boundary and is pinned by
// test/javascript/chatbot_markdown_test.mjs.

// Format message (enhanced markdown support for legal chatbot output)
export function formatMessage(content) {
  if (!content) return ""

  // Process line-by-line for block-level elements (headers, lists, blockquotes, tables)
  const lines = content.split("\n")
  let html = ""
  let inList = false
  let listType = null // 'ul' or 'ol'
  let tableRows = [] // accumulate table rows

  for (let i = 0; i < lines.length; i++) {
    let line = lines[i]

    // Escape HTML (quotes too — _inlineFormat interpolates into href="...")
    line = line.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;")

    // ── Table rows (| col | col |) ──
    if (/^\s*\|/.test(line) && line.trim().endsWith('|')) {
      if (inList) { html += `</${listType}>`; inList = false }
      tableRows.push(line)
      continue
    }

    // Flush accumulated table rows when a non-table line is encountered
    if (tableRows.length > 0) {
      html += renderTable(tableRows)
      tableRows = []
    }

    // Horizontal rule
    if (/^---+$/.test(line.trim())) {
      if (inList) { html += `</${listType}>`; inList = false }
      html += '<hr class="my-2 border-gray-300 dark:border-gray-600">'
      continue
    }

    // Headers (### H3, ## H2, # H1)
    const h3 = line.match(/^###\s+(.+)$/)
    const h2 = line.match(/^##\s+(.+)$/)
    const h1 = line.match(/^#\s+(.+)$/)
    // UPPERCASE headers (HOOFDREGEL, UITZONDERINGEN, JURIDISCHE BASIS, etc.)
    const upperHeader = line.match(/^([A-Z\u00C0-\u00DC\s]{4,}):?\s*$/)

    if (h3 || h2 || h1 || upperHeader) {
      if (inList) { html += `</${listType}>`; inList = false }
      const text = h3 ? h3[1] : h2 ? h2[1] : h1 ? h1[1] : upperHeader[1].trim()
      const tag = h3 ? 'h4' : h2 ? 'h3' : h1 ? 'h3' : 'h4'
      const cls = 'font-semibold text-gray-900 dark:text-white mt-3 mb-1'
      html += `<${tag} class="${cls}">${inlineFormat(text)}</${tag}>`
      continue
    }

    // Blockquote (&gt; escaped >)
    if (line.match(/^&gt;\s?(.*)$/)) {
      if (inList) { html += `</${listType}>`; inList = false }
      const text = line.replace(/^&gt;\s?/, '')
      html += `<blockquote class="border-l-3 border-gray-300 dark:border-gray-600 pl-3 my-1 text-gray-600 dark:text-gray-400 italic">${inlineFormat(text)}</blockquote>`
      continue
    }

    // Unordered list (- item or * item)
    const ulMatch = line.match(/^\s*[-*]\s+(.+)$/)
    if (ulMatch) {
      if (!inList || listType !== 'ul') {
        if (inList) html += `</${listType}>`
        html += '<ul class="list-disc pl-5 my-1 space-y-0.5">'
        inList = true; listType = 'ul'
      }
      html += `<li>${inlineFormat(ulMatch[1])}</li>`
      continue
    }

    // Ordered list (1. item or 1) item)
    const olMatch = line.match(/^\s*(\d+)[.)]\s+(.+)$/)
    if (olMatch) {
      const itemNum = parseInt(olMatch[1], 10)
      if (!inList || listType !== 'ol') {
        if (inList) html += `</${listType}>`
        // Use start attribute to preserve numbering when list is interrupted by other content
        const startAttr = itemNum > 1 ? ` start="${itemNum}"` : ''
        html += `<ol class="list-decimal pl-5 my-1 space-y-0.5"${startAttr}>`
        inList = true; listType = 'ol'
      }
      html += `<li>${inlineFormat(olMatch[2])}</li>`
      continue
    }

    // Close any open list on non-list line (but not on blank lines if next content is another list item)
    if (inList) {
      if (line.trim() === '') {
        // Peek ahead: if next non-blank line is a list item of the same type, keep list open
        let keepOpen = false
        for (let j = i + 1; j < lines.length; j++) {
          const peek = lines[j].trim()
          if (peek === '') continue // skip blank lines
          if (listType === 'ol' && /^\d+[.)]\s+/.test(peek)) keepOpen = true
          if (listType === 'ul' && /^[-*]\s+/.test(peek)) keepOpen = true
          break
        }
        if (!keepOpen) { html += `</${listType}>`; inList = false }
        html += '<br>'
        continue
      }
      html += `</${listType}>`; inList = false
    }

    // Empty line = paragraph break
    if (line.trim() === '') {
      html += '<br>'
      continue
    }

    // Regular text line
    html += inlineFormat(line) + '<br>'
  }

  // Flush any remaining table rows
  if (tableRows.length > 0) {
    html += renderTable(tableRows)
  }

  // Close any remaining open list
  if (inList) html += `</${listType}>`

  // Remove trailing <br>
  html = html.replace(/<br>$/, '')

  // Collapse consecutive <hr> tags (LLM sometimes emits --- before both follow-up hint and disclaimer)
  html = html.replace(/(<hr[^>]*>)(\s*<br>\s*)*(<hr[^>]*>)/g, '$1')

  return html
}

// Render accumulated markdown table rows into an HTML table
export function renderTable(rows) {
  if (rows.length < 2) {
    // Not enough rows for a table – render as plain text
    return rows.map(r => inlineFormat(r) + '<br>').join('')
  }

  // Parse cells from a pipe-delimited row
  const parseCells = (row) => {
    return row.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map(c => c.trim())
  }

  // Detect separator row (|---|---|) – it's the second row in a well-formed table
  const isSeparator = (row) => /^\s*\|[\s\-:|]+\|\s*$/.test(row)

  let headerRow = null
  let dataRows = []

  if (rows.length >= 2 && isSeparator(rows[1])) {
    // Standard markdown table: header + separator + data rows
    headerRow = parseCells(rows[0])
    dataRows = rows.slice(2).filter(r => !isSeparator(r)).map(parseCells)
  } else {
    // No separator – treat all as data rows, first row as header
    headerRow = parseCells(rows[0])
    dataRows = rows.slice(1).filter(r => !isSeparator(r)).map(parseCells)
  }

  let table = '<div class="overflow-x-auto my-2"><table class="min-w-full text-sm border border-gray-200 dark:border-gray-700 rounded-lg overflow-hidden">'

  // Header
  if (headerRow) {
    table += '<thead><tr class="bg-gray-200 dark:bg-gray-800 text-gray-700 dark:text-gray-300 text-left">'
    headerRow.forEach(cell => {
      table += `<th class="px-3 py-1.5 font-semibold border-b border-gray-300 dark:border-gray-600 whitespace-nowrap">${inlineFormat(cell)}</th>`
    })
    table += '</tr></thead>'
  }

  // Body
  if (dataRows.length > 0) {
    table += '<tbody>'
    dataRows.forEach((cells, idx) => {
      const rowClass = idx % 2 === 0
        ? 'bg-white dark:bg-gray-900/50'
        : 'bg-gray-50 dark:bg-gray-800/50'
      table += `<tr class="${rowClass}">`
      cells.forEach(cell => {
        table += `<td class="px-3 py-1.5 border-b border-gray-200 dark:border-gray-700">${inlineFormat(cell)}</td>`
      })
      table += '</tr>'
    })
    table += '</tbody>'
  }

  table += '</table></div>'
  return table
}

// Inline formatting (bold, italic, code, links)
export function inlineFormat(text) {
  return text
    // Markdown links [text](url) - supports absolute (https://) and relative (/path) URLs
    .replace(/\[([^\]]+)\]\((https?:\/\/[^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer" style="color: var(--accent-600)" class="hover:underline">$1</a>')
    .replace(/\[([^\]]+)\]\((\/[^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener" style="color: var(--accent-600)" class="hover:underline font-semibold">$1</a>')
    // Bold
    .replace(/\*\*(.*?)\*\*/g, "<strong>$1</strong>")
    // Italic
    .replace(/\*(.*?)\*/g, "<em>$1</em>")
    // Code
    .replace(/`(.*?)`/g, "<code class='bg-gray-100 dark:bg-gray-700 px-1 rounded'>$1</code>")
}

// Get CSS classes for message
export function messageClasses(role) {
  const base = "message message-fade-in p-3 rounded-lg mb-3 max-w-[85%] shadow-sm break-words"

  switch (role) {
    case "user":
      return `${base} ml-auto bg-(--accent-600-solid) text-white`
    case "assistant":
      return `${base} bg-gray-100 dark:bg-[#0f172a] text-gray-800 dark:text-gray-300`
    case "error":
      return `${base} bg-red-100 dark:bg-red-900 text-red-700 dark:text-red-200`
    default:
      return base
  }
}

// Simple language detection based on script/characters
export function detectQuestionLanguage(text, fallbackLanguage) {
  if (!text) return "nl"

  // Cyrillic script → Russian
  if (/[\u0400-\u04FF]/.test(text)) return "ru"

  // CJK → Chinese/Japanese/Korean
  if (/[\u4E00-\u9FFF\u3040-\u309F\u30A0-\u30FF]/.test(text)) return "zh"

  // Arabic script
  if (/[\u0600-\u06FF]/.test(text)) return "ar"

  // Simple word-based detection for European languages
  const lower = text.toLowerCase()

  // French indicators
  if (/\b(qu'est-ce|c'est|qu'il|qu'elle|j'ai|je suis|dans|avec|pour|sur|mais|sont|une)\b/.test(lower)) return "fr"

  // English indicators
  if (/\b(what|how|when|where|why|which|who|the|and|for|with|this|that|have|has|been|are|would|could|should)\b/.test(lower)) return "en"

  // German indicators (umlauts first - strongest signal)
  if (/[äöüÄÖÜß]/.test(text)) return "de"

  // German word patterns (common German words not shared with Dutch)
  if (/\b(ich|nicht|ist|das|die|und|sie|wir|haben|sein|werden|können|müssen|sollen|möchten|arbeitsvertrag|kündigung|arbeitgeber|arbeitnehmer)\b/.test(lower)) return "de"

  // Dutch-specific patterns (to be certain it's Dutch, not German)
  if (/\b(wat|hoe|wanneer|waar|waarom|welke|wie|kan|mag|moet|zou|heb|heeft|zijn|mijn|het|een|van|voor|bij|ik|ben|dit|dat|deze|die|hoeveel|werknemer|werkgever|opzegtermijn)\b/.test(lower)) return "nl"

  // Default to UI language value (fallback)
  return fallbackLanguage || "nl"
}
