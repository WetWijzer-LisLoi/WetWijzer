import { Controller } from "@hotwired/stimulus"
import { showToast } from '../utils/toast'
import { getLocale } from '../utils/locale'
import { uiText } from '../utils/ui_translations'

// WW-SEC-15 follow-up: an imported file is untrusted. Only identifiers the
// server would accept (Api::BookmarksController::NUMAC_FORMAT) are kept, and
// imported text reaches the page as text, never as markup.
const NUMAC_FORMAT = /^[0-9A-Za-z_-]{1,50}$/
const TITLE_MAX = 500
const FOLDER_MAX = 100

/**
 * Bookmarks Page Controller
 *
 * Full-featured bookmark management with folders, sorting, delete confirmation,
 * and richer bookmark cards. All data stored server-side via /api/bookmarks.
 * No localStorage or sessionStorage used.
 *
 * Data schema per bookmark:
 *   { numac, title, addedAt, folder }
 */

export default class extends Controller {
  static targets = [
    "list", "empty", "count", "sortLabel",
    "sidebar", "folderList", "createFolderForm", "newFolderInput",
    "deleteDialog", "deleteTitle", "deleteMessage",
    "clearAllBtn", "exportBtn"
  ]

  connect() {
    this.currentSort = 'newest'
    this.currentFolder = null       // null = all, '' = unfiled, 'name' = specific folder
    this.pendingDeleteNumac = null
    this._bookmarksCache = []
    this._foldersCache = []
    
    // Load bookmarks from server
    this.fetchBookmarksFromServer()
  }

  async fetchBookmarksFromServer() {
    try {
      const response = await fetch('/api/bookmarks', {
        credentials: 'same-origin',
        headers: { 'Accept': 'application/json' }
      })
      if (response.ok) {
        const data = await response.json()
        this._bookmarksCache = (data.bookmarks || []).map(b => ({
          numac: b.numac,
          title: b.title || b.numac,
          addedAt: b.created_at || b.addedAt,
          folder: b.folder,
          url: b.url
        }))
        this._foldersCache = data.folders || []
      }
    } catch (e) {
      console.warn('Failed to load bookmarks:', e)
    }
    this.loadBookmarks()
    this.renderFolders()
  }

  // ─── SORTING ──────────────────────────────────────────────────────────

  sort(event) {
    this.currentSort = event.currentTarget.dataset.sort
    if (this.hasSortLabelTarget) {
      this.sortLabelTarget.textContent = event.currentTarget.textContent.trim()
    }
    // Close the dropdown
    const menu = event.currentTarget.closest('[data-dropdown-target="menu"]')
    if (menu) menu.classList.add('hidden')
    this.loadBookmarks()
  }

  sortBookmarks(bookmarks) {
    const sorted = [...bookmarks]
    switch (this.currentSort) {
      case 'newest':
        return sorted.sort((a, b) => new Date(b.addedAt || 0) - new Date(a.addedAt || 0))
      case 'oldest':
        return sorted.sort((a, b) => new Date(a.addedAt || 0) - new Date(b.addedAt || 0))
      case 'alpha_asc':
        return sorted.sort((a, b) => (a.title || '').localeCompare(b.title || ''))
      case 'alpha_desc':
        return sorted.sort((a, b) => (b.title || '').localeCompare(a.title || ''))
      default:
        return sorted
    }
  }

  // ─── FOLDERS ──────────────────────────────────────────────────────────

  getFolders() {
    // Folders are stored as part of the bookmarks API response
    return this._foldersCache || []
  }

  saveFolders(folders) {
    this._foldersCache = folders
    // Sync to server
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    fetch('/api/bookmarks', {
      method: 'POST',
      credentials: 'same-origin',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        ...(csrfToken ? { 'X-CSRF-Token': csrfToken } : {})
      },
      body: JSON.stringify({ action: 'save_folders', folders })
    }).catch(() => {})
  }

  renderFolders() {
    if (!this.hasFolderListTarget) return
    const folders = this.getFolders()
    const bookmarks = this.getBookmarks()
    const allLabel = uiText('allFolders')
    const unfiledLabel = uiText('unfiled')
    const allCount = bookmarks.length
    const unfiledCount = bookmarks.filter(b => !b.folder).length

    let html = ''

    // "All" folder
    html += this._folderItem(allLabel, allCount, null)
    // "Unfiled" folder
    html += this._folderItem(unfiledLabel, unfiledCount, '')

    // User folders
    folders.forEach(f => {
      const count = bookmarks.filter(b => b.folder === f.name).length
      html += this._folderItem(f.name, count, f.name, true)
    })

    this.folderListTarget.innerHTML = html

    // Attach click handlers
    this.folderListTarget.querySelectorAll('[data-folder-name]').forEach(el => {
      el.addEventListener('click', (e) => {
        e.preventDefault()
        const val = el.dataset.folderName
        this.currentFolder = val === '__all__' ? null : val
        this.loadBookmarks()
        this.renderFolders()
      })
    })

    // Attach delete handlers for user folders
    this.folderListTarget.querySelectorAll('[data-delete-folder]').forEach(btn => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation()
        this.deleteFolder(btn.dataset.deleteFolder)
      })
    })
  }

  _folderItem(label, count, folderValue, deletable = false) {
    const isActive = this.currentFolder === folderValue
    const dataVal = folderValue === null ? '__all__' : folderValue
    const activeClass = isActive
      ? 'bg-(--accent-50) dark:bg-(--accent-900)/20 text-(--accent-700) dark:text-(--accent-400) font-medium'
      : 'text-gray-600 dark:text-gray-400 hover:bg-gray-50 dark:hover:bg-gray-800'

    return `<li>
      <a href="#" data-folder-name="${this._escapeHtml(dataVal)}" class="flex items-center justify-between px-2 py-1.5 rounded-md text-sm ${activeClass} transition-colors group/folder">
        <span class="flex items-center gap-1.5 truncate">
          <svg class="w-4 h-4 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"/></svg>
          <span class="truncate">${this._escapeHtml(label)}</span>
        </span>
        <span class="flex items-center gap-1">
          <span class="text-xs text-gray-400">${count}</span>
          ${deletable ? `<button type="button" aria-label="${uiText('deleteFolder')}" data-delete-folder="${this._escapeHtml(folderValue)}" class="hidden group-hover/folder:inline p-0.5 text-gray-400 hover:text-red-500 transition-colors"><svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg></button>` : ''}
        </span>
      </a>
    </li>`
  }

  showCreateFolder() {
    if (this.hasCreateFolderFormTarget) {
      this.createFolderFormTarget.classList.remove('hidden')
      this.newFolderInputTarget.focus()
    }
  }

  hideCreateFolder() {
    if (this.hasCreateFolderFormTarget) {
      this.createFolderFormTarget.classList.add('hidden')
      this.newFolderInputTarget.value = ''
    }
  }

  createFolder() {
    const name = this.newFolderInputTarget.value.trim()
    if (!name) return

    const folders = this.getFolders()
    if (folders.some(f => f.name === name)) {
      showToast(uiText('folderExists'))
      return
    }

    folders.push({ name, createdAt: new Date().toISOString() })
    this.saveFolders(folders)
    this.hideCreateFolder()
    this.renderFolders()
    showToast(uiText('folderCreated', { name }))
  }

  deleteFolder(name) {
    const msg = uiText('folderDeleteConfirm', { name })
    if (!confirm(msg)) return

    // Remove folder from folder list
    const folders = this.getFolders().filter(f => f.name !== name)
    this.saveFolders(folders)

    // Move bookmarks in that folder to unfiled
    const bookmarks = this.getBookmarks().map(b => {
      if (b.folder === name) return { ...b, folder: undefined }
      return b
    })
    this.saveBookmarks(bookmarks)

    if (this.currentFolder === name) this.currentFolder = null
    this.renderFolders()
    this.loadBookmarks()
  }

  moveToFolder(event) {
    const numac = event.currentTarget.dataset.numac
    const folder = event.currentTarget.dataset.folder
    const bookmarks = this.getBookmarks().map(b => {
      if (b.numac === numac) return { ...b, folder: folder || undefined }
      return b
    })
    this.saveBookmarks(bookmarks)
    this.loadBookmarks()
    this.renderFolders()

    const msg = folder
      ? uiText('folderMoved', { name: folder })
      : uiText('bookmarkUnfiled')
    showToast(msg)
  }

  // ─── DELETE CONFIRMATION ──────────────────────────────────────────────

  requestDelete(numac, title) {
    this.pendingDeleteNumac = numac
    if (this.hasDeleteDialogTarget) {
      this.deleteDialogTarget.classList.remove('hidden')
      if (this.hasDeleteMessageTarget) {
        this.deleteMessageTarget.textContent = title || numac
      }
    }
  }

  confirmDelete() {
    if (this.pendingDeleteNumac) {
      const bookmarks = this.getBookmarks().filter(b => b.numac !== this.pendingDeleteNumac)
      this.saveBookmarks(bookmarks)
      this.pendingDeleteNumac = null
      this.cancelDelete()
      this.loadBookmarks()
      this.renderFolders()
      showToast(uiText('bookmarkRemoved'))
    }
  }

  cancelDelete() {
    if (this.hasDeleteDialogTarget) {
      this.deleteDialogTarget.classList.add('hidden')
    }
    this.pendingDeleteNumac = null
  }

  // ─── MAIN RENDER ──────────────────────────────────────────────────────

  loadBookmarks() {
    let bookmarks = this.getBookmarks()
    const locale = getLocale()

    // Filter by folder
    if (this.currentFolder !== null && this.currentFolder !== undefined) {
      if (this.currentFolder === '') {
        bookmarks = bookmarks.filter(b => !b.folder)
      } else {
        bookmarks = bookmarks.filter(b => b.folder === this.currentFolder)
      }
    }

    // Sort
    bookmarks = this.sortBookmarks(bookmarks)

    if (bookmarks.length === 0) {
      this.showEmpty()
      this.updateCount(0)
      this.updateActionButtons(this.getBookmarks().length)
      return
    }

    this.hideEmpty()
    this.updateCount(bookmarks.length)
    this.updateActionButtons(this.getBookmarks().length)
    this.listTarget.innerHTML = ''

    const template = document.getElementById('bookmark-item-template')
    if (!template) return

    const folders = this.getFolders()

    bookmarks.forEach(bookmark => {
      const item = template.content.cloneNode(true)
      const link = item.querySelector('.bookmark-link')
      const numac = item.querySelector('.bookmark-numac')
      const dateEl = item.querySelector('.bookmark-date')
      const folderBadge = item.querySelector('.bookmark-folder-badge')
      const removeBtn = item.querySelector('.bookmark-remove')
      const folderMenu = item.querySelector('.bookmark-folder-menu')

      // Title and link
      const title = bookmark.title || bookmark.numac
      link.textContent = title
      link.href = `/laws/${encodeURIComponent(bookmark.numac)}?language_id=${locale === 'nl' ? 1 : locale === 'de' ? 3 : 2}`
      numac.textContent = `NUMAC ${bookmark.numac}`

      // Date added
      if (bookmark.addedAt && dateEl) {
        const d = new Date(bookmark.addedAt)
        dateEl.textContent = d.toLocaleDateString({ nl: 'nl-BE', fr: 'fr-BE', de: 'de-BE', en: 'en-GB' }[locale], {
          day: 'numeric', month: 'short', year: 'numeric'
        })
      }

      // Folder badge
      if (bookmark.folder && folderBadge) {
        folderBadge.textContent = bookmark.folder
        folderBadge.classList.remove('hidden')
      }

      // Delete button → confirmation dialog
      removeBtn.addEventListener('click', () => this.requestDelete(bookmark.numac, title))

      // Folder menu, built from nodes: the identifier and folder names are
      // data, so they never pass through innerHTML.
      if (folderMenu) {
        const unfiledLabel = uiText('unfiled')
        const menu = document.createElement('div')
        menu.className = 'py-1'
        const addOption = (label, folderName, current) => {
          const option = document.createElement('button')
          option.type = 'button'
          option.className = `block w-full text-left px-3 py-1.5 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800 ${current ? 'font-bold' : ''}`
          option.dataset.numac = bookmark.numac
          option.dataset.folder = folderName
          option.textContent = label
          option.addEventListener('click', (e) => this.moveToFolder(e))
          menu.appendChild(option)
        }

        addOption(unfiledLabel, '', !bookmark.folder)
        folders.forEach(f => addOption(f.name, f.name, bookmark.folder === f.name))
        folderMenu.replaceChildren(menu)
      }

      this.listTarget.appendChild(item)
    })
  }

  // ─── EXPORT / IMPORT / CLEAR ──────────────────────────────────────────

  exportBookmarks() {
    const bookmarks = this.getBookmarks()
    const folders = this.getFolders()
    if (bookmarks.length === 0) {
      showToast(uiText('bookmarksExportEmpty'))
      return
    }

    const data = JSON.stringify({ bookmarks, folders }, null, 2)
    const blob = new Blob([data], { type: 'application/json' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `wetwijzer-bookmarks-${new Date().toISOString().split('T')[0]}.json`
    document.body.appendChild(a)
    a.click()
    document.body.removeChild(a)
    URL.revokeObjectURL(url)
    showToast(uiText('bookmarksExported'))
  }

  importBookmarks(event) {
    const file = event.target.files[0]
    if (!file) return

    const reader = new FileReader()
    reader.onload = (e) => {
      try {
        const raw = JSON.parse(e.target.result)
        let imported = []
        let importedFolders = []

        // Handle both old (plain array) and new ({ bookmarks, folders }) formats
        if (Array.isArray(raw)) {
          imported = raw
        } else if (raw.bookmarks && Array.isArray(raw.bookmarks)) {
          imported = raw.bookmarks
          importedFolders = raw.folders || []
        } else {
          throw new Error('Invalid format')
        }

        // Merge bookmarks
        const existing = this.getBookmarks()
        const existingNumacs = new Set(existing.map(b => b.numac))
        let added = 0
        imported.forEach(bookmark => {
          const numac = typeof bookmark?.numac === 'string' ? bookmark.numac.trim() : ''
          if (!NUMAC_FORMAT.test(numac) || existingNumacs.has(numac)) return

          existingNumacs.add(numac)
          existing.push({
            numac,
            title: String(bookmark.title || numac).slice(0, TITLE_MAX),
            addedAt: typeof bookmark.addedAt === 'string' ? bookmark.addedAt : new Date().toISOString(),
            folder: typeof bookmark.folder === 'string' && bookmark.folder ? bookmark.folder.slice(0, FOLDER_MAX) : undefined
          })
          added++
        })
        this.saveBookmarks(existing)

        // Merge folders
        if (importedFolders.length > 0) {
          const existingFolders = this.getFolders()
          const existingNames = new Set(existingFolders.map(f => f.name))
          importedFolders.forEach(f => {
            const name = typeof f?.name === 'string' ? f.name.slice(0, FOLDER_MAX) : ''
            if (name && !existingNames.has(name)) {
              existingNames.add(name)
              existingFolders.push({ name, createdAt: typeof f.createdAt === 'string' ? f.createdAt : new Date().toISOString() })
            }
          })
          this.saveFolders(existingFolders)
        }

        this.loadBookmarks()
        this.renderFolders()
        showToast(uiText('bookmarksImported', { count: added }))
      } catch {
        showToast(uiText('invalidFile'))
      }
    }
    reader.readAsText(file)
    event.target.value = ''
  }

  clearAll() {
    const total = this.getBookmarks().length
    if (total === 0) return

    // Use custom dialog for clear all too
    this.pendingDeleteNumac = '__CLEAR_ALL__'
    if (this.hasDeleteDialogTarget) {
      this.deleteDialogTarget.classList.remove('hidden')
      if (this.hasDeleteTitleTarget) {
        this.deleteTitleTarget.textContent = uiText('bookmarksDeleteAll')
      }
      if (this.hasDeleteMessageTarget) {
        this.deleteMessageTarget.textContent = uiText('bookmarksDeleteCount', { count: total })
      }
    }

    // Override confirmDelete for this case
    const origConfirm = this.confirmDelete.bind(this)
    this.confirmDelete = () => {
      if (this.pendingDeleteNumac === '__CLEAR_ALL__') {
        this.saveBookmarks([])
        this.pendingDeleteNumac = null
        this.cancelDelete()
        this.loadBookmarks()
        this.renderFolders()
        showToast(uiText('bookmarksRemoved'))
        this.confirmDelete = origConfirm
      } else {
        origConfirm()
      }
    }
  }

  // ─── STORAGE ──────────────────────────────────────────────────────────

  getBookmarks() {
    // Return cached data from the initial API fetch
    return this._bookmarksCache || []
  }

  saveBookmarks(bookmarks) {
    this._bookmarksCache = bookmarks
    // Sync to server
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    fetch('/api/bookmarks/import', {
      method: 'POST',
      credentials: 'same-origin',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        ...(csrfToken ? { 'X-CSRF-Token': csrfToken } : {})
      },
      body: JSON.stringify({ bookmarks, replace: true })
    }).catch(() => {})
  }

  // ─── UI HELPERS ───────────────────────────────────────────────────────

  updateCount(count) {
    if (this.hasCountTarget) {
      const label = uiText('bookmarksLabel')
      this.countTarget.textContent = `${count} ${label}`
    }
  }

  showEmpty() {
    if (this.hasEmptyTarget) this.emptyTarget.classList.remove('hidden')
    if (this.hasListTarget) this.listTarget.classList.add('hidden')
  }

  hideEmpty() {
    if (this.hasEmptyTarget) this.emptyTarget.classList.add('hidden')
    if (this.hasListTarget) this.listTarget.classList.remove('hidden')
  }

  updateActionButtons(totalCount) {
    const disabled = totalCount === 0
    const disabledClass = 'opacity-40 pointer-events-none'

    if (this.hasClearAllBtnTarget) {
      this.clearAllBtnTarget.disabled = disabled
      if (disabled) {
        this.clearAllBtnTarget.classList.add(...disabledClass.split(' '))
      } else {
        this.clearAllBtnTarget.classList.remove(...disabledClass.split(' '))
      }
    }

    if (this.hasExportBtnTarget) {
      this.exportBtnTarget.disabled = disabled
      if (disabled) {
        this.exportBtnTarget.classList.add(...disabledClass.split(' '))
      } else {
        this.exportBtnTarget.classList.remove(...disabledClass.split(' '))
      }
    }
  }

  // Also for attribute values: a text node's serialization leaves quotes as
  // they are, so a folder name could close its data attribute.
  _escapeHtml(str) {
    return String(str ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;')
  }
}
