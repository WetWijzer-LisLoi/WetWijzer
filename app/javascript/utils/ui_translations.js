import { getLocale, localeText } from './locale'

// App-owned interaction copy only. User data, legislation titles, publication
// identifiers and model names must never pass through this dictionary.
export const UI_TRANSLATIONS = {
  close: { nl: 'Sluiten', fr: 'Fermer', de: 'Schließen', en: 'Close' },
  loading: { nl: 'Laden...', fr: 'Chargement...', de: 'Wird geladen...', en: 'Loading...' },
  loadFailed: { nl: 'Laden mislukt', fr: 'Échec du chargement', de: 'Laden fehlgeschlagen', en: 'Loading failed' },
  bookmarkLogin: { nl: 'Log in om bladwijzers te gebruiken', fr: 'Connectez-vous pour utiliser les signets', de: 'Melden Sie sich an, um Lesezeichen zu verwenden', en: 'Sign in to use bookmarks' },
  bookmarkAdded: { nl: 'Bladwijzer toegevoegd', fr: 'Signet ajouté', de: 'Lesezeichen hinzugefügt', en: 'Bookmark added' },
  bookmarkRemoved: { nl: 'Bladwijzer verwijderd', fr: 'Signet supprimé', de: 'Lesezeichen gelöscht', en: 'Bookmark removed' },
  bookmarkSaveFailed: { nl: 'Fout bij opslaan', fr: "Erreur lors de l'enregistrement", de: 'Fehler beim Speichern', en: 'Could not save bookmark' },
  bookmarksRemoved: { nl: 'Bladwijzers verwijderd', fr: 'Signets supprimés', de: 'Lesezeichen gelöscht', en: 'Bookmarks removed' },
  bookmarksLabel: { nl: 'bladwijzers', fr: 'signets', de: 'Lesezeichen', en: 'bookmarks' },
  allFolders: { nl: 'Alle', fr: 'Tous', de: 'Alle', en: 'All' },
  unfiled: { nl: 'Ongesorteerd', fr: 'Non classé', de: 'Unsortiert', en: 'Unfiled' },
  deleteFolder: { nl: 'Map verwijderen', fr: 'Supprimer le dossier', de: 'Ordner löschen', en: 'Delete folder' },
  folderExists: { nl: 'Map bestaat al', fr: 'Le dossier existe déjà', de: 'Der Ordner existiert bereits', en: 'Folder already exists' },
  folderCreated: { nl: 'Map "%{name}" aangemaakt', fr: 'Dossier "%{name}" créé', de: 'Ordner "%{name}" erstellt', en: 'Folder "%{name}" created' },
  folderDeleteConfirm: { nl: 'Map "%{name}" verwijderen? Bladwijzers worden niet verwijderd.', fr: 'Supprimer le dossier "%{name}" ? Les signets ne seront pas supprimés.', de: 'Ordner "%{name}" löschen? Die Lesezeichen werden nicht gelöscht.', en: 'Delete folder "%{name}"? Bookmarks will not be deleted.' },
  folderMoved: { nl: 'Verplaatst naar "%{name}"', fr: 'Déplacé vers "%{name}"', de: 'Nach "%{name}" verschoben', en: 'Moved to "%{name}"' },
  bookmarkUnfiled: { nl: 'Bladwijzer ongesorteerd', fr: 'Signet non classé', de: 'Lesezeichen ist unsortiert', en: 'Bookmark moved to Unfiled' },
  bookmarksExportEmpty: { nl: 'Geen bladwijzers om te exporteren', fr: 'Aucun signet à exporter', de: 'Keine Lesezeichen zum Exportieren', en: 'No bookmarks to export' },
  bookmarksExported: { nl: 'Bladwijzers geëxporteerd', fr: 'Signets exportés', de: 'Lesezeichen exportiert', en: 'Bookmarks exported' },
  bookmarksImported: { nl: '%{count} bladwijzer(s) geïmporteerd', fr: '%{count} signet(s) importé(s)', de: '%{count} Lesezeichen importiert', en: '%{count} bookmark(s) imported' },
  invalidFile: { nl: 'Ongeldig bestand', fr: 'Fichier invalide', de: 'Ungültige Datei', en: 'Invalid file' },
  bookmarksDeleteAll: { nl: 'Alle bladwijzers verwijderen?', fr: 'Supprimer tous les signets ?', de: 'Alle Lesezeichen löschen?', en: 'Delete all bookmarks?' },
  bookmarksDeleteCount: { nl: '%{count} bladwijzer(s) worden verwijderd', fr: '%{count} signet(s) seront supprimés', de: '%{count} Lesezeichen werden gelöscht', en: '%{count} bookmark(s) will be deleted' },
  hideColors: { nl: 'Verberg kleuren', fr: 'Masquer les couleurs', de: 'Farben ausblenden', en: 'Hide colors' },
  showColors: { nl: 'Toon kleuren', fr: 'Afficher les couleurs', de: 'Farben anzeigen', en: 'Show colors' },
  hideHighlight: { nl: 'Verberg markering', fr: 'Masquer le surlignage', de: 'Hervorhebung ausblenden', en: 'Hide highlighting' },
  showHighlight: { nl: 'Toon markering', fr: 'Afficher le surlignage', de: 'Hervorhebung anzeigen', en: 'Show highlighting' },
  hideChanges: { nl: 'Verberg wijzigingen', fr: 'Masquer les modifications', de: 'Änderungen ausblenden', en: 'Hide changes' },
  showChanges: { nl: 'Toon wijzigingen', fr: 'Afficher les modifications', de: 'Änderungen anzeigen', en: 'Show changes' },
  referencesDisabled: { nl: "Schakel eerst 'Toon wijzigingen' in om kleuren en markering te kunnen gebruiken.", fr: "Activez d'abord 'Afficher les modifications' pour utiliser les couleurs et le surlignage.", de: "Aktivieren Sie zuerst 'Änderungen anzeigen', um Farben und Hervorhebungen zu verwenden.", en: "Enable 'Show changes' first to use colors and highlighting." },
  citationArticle: { nl: 'artikel', fr: "l'article", de: 'Artikel', en: 'article' },
  citationOf: { nl: 'van het', fr: 'du', de: 'des', en: 'of the' },
  citationGazette: { nl: 'BS', fr: 'MB', de: 'Belgisches Staatsblatt', en: 'Belgian Official Gazette' },
  citationCopied: { nl: 'Referentie gekopieerd!', fr: 'Référence copiée !', de: 'Fundstelle kopiert!', en: 'Reference copied!' },
  articles: { nl: 'Artikelen', fr: 'Articles', de: 'Artikel', en: 'Articles' },
  legislation: { nl: 'Wetgeving', fr: 'Législation', de: 'Gesetzgebung', en: 'Legislation' },
  jurisprudence: { nl: 'Rechtspraak', fr: 'Jurisprudence', de: 'Rechtsprechung', en: 'Case law' },
  parliamentary: { nl: 'Parlementaire stukken', fr: 'Travaux parlementaires', de: 'Parlamentarische Dokumente', en: 'Parliamentary work' },
  viewAll: { nl: 'Bekijk alle →', fr: 'Voir tout →', de: 'Alle anzeigen →', en: 'View all →' },
  noResults: { nl: 'Geen resultaten gevonden', fr: 'Aucun résultat trouvé', de: 'Keine Ergebnisse gefunden', en: 'No results found' },
  shortcutsTitle: { nl: 'Sneltoetsen', fr: 'Raccourcis clavier', de: 'Tastenkombinationen', en: 'Keyboard shortcuts' },
  shortcutSearch: { nl: 'Zoeken', fr: 'Rechercher', de: 'Suchen', en: 'Search' },
  shortcutSearchField: { nl: 'Zoeken (in veld)', fr: 'Rechercher (dans un champ)', de: 'Suchen (in einem Eingabefeld)', en: 'Search (from an input)' },
  shortcutNavigate: { nl: 'Navigeer resultaten', fr: 'Parcourir les résultats', de: 'Ergebnisse durchgehen', en: 'Navigate results' },
  shortcutOpen: { nl: 'Open selectie', fr: 'Ouvrir la sélection', de: 'Auswahl öffnen', en: 'Open selection' },
  shortcutBookmark: { nl: 'Bladwijzer aan/uit', fr: 'Ajouter/supprimer un signet', de: 'Lesezeichen hinzufügen/entfernen', en: 'Add/remove bookmark' },
  shortcutClose: { nl: 'Sluiten / Annuleren', fr: 'Fermer / Annuler', de: 'Schließen / Abbrechen', en: 'Close / Cancel' },
  shortcutHome: { nl: 'Ga naar home', fr: "Aller à l'accueil", de: 'Zur Startseite', en: 'Go home' },
  shortcutBookmarks: { nl: 'Ga naar bladwijzers', fr: 'Aller aux signets', de: 'Zu den Lesezeichen', en: 'Go to bookmarks' },
  shortcutHelp: { nl: 'Toon hulp', fr: "Afficher l'aide", de: 'Hilfe anzeigen', en: 'Show help' }
}

export function uiText(key, substitutions = {}, locale = getLocale()) {
  const text = localeText(UI_TRANSLATIONS[key], locale)
  return text.replace(/%\{(\w+)\}/g, (placeholder, name) => Object.hasOwn(substitutions, name) ? String(substitutions[name]) : placeholder)
}
