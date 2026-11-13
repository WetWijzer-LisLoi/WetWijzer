# Changelog

All notable changes to the WetWijzer application are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the version numbers follow [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html) as applied in `docs/VERSIONING_POLICY.md`.

Everything deployed before 1.0.0 was unversioned: that history is identified by commit SHA only (production ran `a35840fba9f44fe8e22079fbb30022410ef7bf3a` when versioning was adopted on 2026-10-18), and no earlier release is retroactively given a number.

A section's date is set when the candidate is sealed for review, and the sealed commit is deployed and tagged (`vX.Y.Z` on that exact SHA) without any change to its files; a dated section is therefore a planned release until the deployed SHA, its tag and its receipt say it shipped. If the day changes before the push, the candidate is re-sealed with the new date.

## [Unreleased]

## [1.1.48] - 2026-11-13

### Fixed
- Parliamentary documents: the Chamber's document 56K0019001, "Orde van voorrang der regeringsleden.", was shown as a bill ("Wetsontwerp"), the default its first document was stored with. The Chamber's own record gives it document type 50, "Tabellen of lijsten", like the dossier's later documents. It is now shown as such in its heading, its details, the result list and the dossier's timeline. This is a correction for that one document, as no source type is reliable for such documents in general; its stored type and title are unchanged.
- Parliamentary documents: the type "Tabellen of lijsten" is now named in each site's language ("Tableaux ou listes", "Tabellen oder Listen", "Tables or lists"); it was shown in Dutch everywhere.
- Parliamentary documents: a proposal to revise the Chamber's rules (or another text) whose title goes on to cite the Constitution no longer takes the type for a revision of the Constitution.

## [1.1.47] - 2026-11-13

### Fixed
- Parliamentary documents: since 1.1.46, a dossier's first document stored with a bill type whose title opens "Voorstel tot herziening" or "Proposition de révision" was given the type for a revision of the Constitution, also when it revises something else (the Chamber's rules, a decree). That type now needs the title to name the Constitution ("Grondwet", "Constitution"); any other revision shows no type. As in 1.1.46, the title is read only for a dossier's first document stored with a bill type ("wetsontwerp" or "wetsvoorstel"); every other document keeps its stored type.
- Tests: the dossier's timeline names a first-document resolution proposal and a second-document amendment each by its own type.

## [1.1.46] - 2026-11-13

### Fixed
- Parliamentary documents: a resolution proposal whose first document was stored with the default type "wetsontwerp" read as a bill, "Wetsontwerp Voorstel van resolutie ...", with a "Wetsontwerp" badge on its page and in the list. A dossier's first document now takes its type from the opening words of its own title: a resolution proposal, a special law, a proposal to revise the Constitution or a declaration, as well as the two kinds of bill. A title that opens as another kind of proposal shows no type rather than a wrong one. A word further on in the title changes nothing, and the stored type and title are unchanged. The list and the dossier's timeline now show the same type as the document's page.
- Parliamentary list: a result's snippet could show control characters from the extracted text (backspaces after the party abbreviations of a party legend). They are now shown as spaces; the stored text is unchanged.
- About page: the purpose paragraphs name legislation, case law and parliamentary documents, as the footer and the support page do, in all four languages.

## [1.1.45] - 2026-11-12

### Tests
- The Chrome update guard's two limits are pinned by tests, so that changing either is a choice. A profile that shows no process for a second counts as done, whether the throwaway start is not listed yet or a first browser has exited before the one it hands over to is listed; at the 60-second limit, one empty reading counts as the end. Its comment now says that the one-second rule is a heuristic, and that how long such a gap can be on this machine is not measured.

## [1.1.44] - 2026-11-12

### Fixed
- Law pages: when the articles' loading was set up again on the same page, what it had found before carried over. After the articles had once loaded, a later failure was kept as it stood when the reader left, and Back showed that notice again instead of loading the articles. Each setup now starts afresh.
- Law pages: when a law page came back with a failure notice but without its handling, Retry worked, but the indicator and the frame kept the failure while the articles loaded again. They now say "Laden..." until the answer comes.
- Tests: the Chrome update guard no longer takes a process list it could not read for an empty one. It counts a throwaway start as over only after two readings at least a second apart find no process on its profile, and it reports a browser as stopped only when a later reading no longer lists it. A profile whose browser may still run is kept and named.
- Tests: the articles' handling when the same controller connects again, and a restored notice's state before the answer.

## [1.1.43] - 2026-11-12

### Fixed
- Law pages: Back to a law page whose articles had failed to load brought back the failure notice with a Retry button that did nothing, and the articles were not asked for again. They now load again, as on a new visit, and Retry shows the articles' loading message while they load again.
- Law pages: on a law page brought back with Back, the articles' loading count kept running until the reader left, out of sight, or beside "Artikelen geladen" when the page had been left within two seconds of loading. The indicator now ends at once, and its fade no longer runs on after the page has gone.
- Tests: the articles' indicator and frame across leaving, Back and a new controller (unit tests), and in Chrome: Back after a failure and after the fade, and an articles request answered with a redirect to the sign-in page, which the page-wide handling opens.
- Tests: on Windows, the first browser test of a run could fail when Chrome had an update waiting and no Chrome was open: the first browser to start applied the update and restarted itself where the test driver could not reach it, and that browser kept running after the run (once, on 2026-11-10; it was found two days later). A browser test run now lets Chrome apply such an update in a throwaway start before its first browser test, and stops a browser it started that outlived its parent process. The test driver's comment no longer puts that failure down to a slow start.

## [1.1.42] - 2026-11-12

### Fixed
- Law pages: when a law's articles could not be loaded because the connection failed, the page went on saying they were loading, with no way to try again; when the site answered with an error page instead, the notice's Retry left the law page. The page now says the loading failed, and Retry loads the articles again in place.
- Tests: the articles' failure handling in unit tests (a network failure, an error page, a sign-in page left to the page-wide handling, a frame inside the articles, Retry) and in Chrome (the articles request answered 502, and lost to a network failure, each followed by Retry); the mobile dock test reads the reopened dock's saved state once the dock has saved it (a read right after it opened could find the old value).

## [1.1.41] - 2026-11-12

### Fixed
- Error pages: when a link was answered while the site was restarting (502 or 503) or after it took too long (504), the page saying so showed no countdown and never tried again: the site's script policy blocked the countdown inside the page the reader was on. The countdown now runs there and, at zero, loads the page the reader asked for.
- Law pages: for a signed-in reader who had unticked "Follow scrolling", the contents followed the page after a full page load until the saved choice arrived, for up to almost two seconds on a slow connection. The choice now comes with the page, so the contents do not follow.
- Tests: the error pages' countdowns are admitted by their hashes and nothing else inline (a test holds the hashes to the pages); a link visit answered 502 or 504 runs its countdown, and the 502 page loads the address asked for again (Chrome); the saved follow choice is rendered for a signed-in reader only, and the preferences store has it before its own request answers; the contents list's listener count in Chrome takes a listener to be its type, its callback and its capture flag, as the browser does.

## [1.1.40] - 2026-11-11

### Fixed
- Law pages: the contents list in the sidebar set itself up twice on each law page, and one set of its scroll, resize and address listeners stayed behind when the reader left, holding on to the old page; every law page opened in the same tab added more. It now sets itself up once and leaves nothing behind, also when the page is left within a split second of opening.
- Law pages: one click on an entry of the sidebar's contents added three steps to the browser's history, so Back had to be pressed three times to return; it adds one.
- Law pages: unticking "Follow scrolling" in the contents' options did nothing; it now stops the contents from following the page, and the choice holds on the next law page.
- Tests: the contents list's lifecycle in Stimulus's own order (unit tests) and in Chrome (its listeners across page visits, one history step per contents click, the follow box); a heading the law's text lacks stays unlinked also when the contents list is set up while the articles are being put in.

## [1.1.39] - 2026-11-11

### Fixed
- Search: the results-per-page choice shows the size the page was built with, also when that is not one of the five offered sizes (an older link with 20 per page, for example). It showed 10 or 50 over the page's own rows, and the next search silently used that size.
- Law pages: opened at an article, the page held that article in place for three seconds even when the reader had just folded its section or clicked something, and pulled the page back to it against any other scrolling; a click on the contents in that time could miss. The page now lets go as soon as the reader acts or the article is folded away.
- Tests: the advice-extraction tests load where spaCy is not installed, as in the workflow's own environment; returning with Back to a page whose search failed is tested on Turbo's cached copy of it; the search-results test that switches page scripts off first waits for the legislation list to finish loading (a list arriving later was reported as a missing frame).

## [1.1.38] - 2026-11-11

### Fixed
- Search: when a search fails, the earlier results stay on screen with a notice that says so, and its Retry runs the search that was sent. An error answer from the server, such as the "service unavailable" page during a restart, used to replace the whole page at the earlier search's address, where its Retry reloaded the earlier search and its automatic retry never started.
- Browser tests: Chrome gets 30 seconds to start and for a run's first command, as for later commands (the first browser test of two runs failed on the shorter defaults); address checks compare the values the server reads, and the judgment sort test also goes Forward.

## [1.1.37] - 2026-11-10

### Fixed
- Backups: a free-space reading whose `df` command failed no longer counts, even when it printed a number. The run stops without deleting anything, and the space check before an online snapshot reads the value the same way.
- Parliamentary documents: a 200-character title that the dossier's own page confirms was complete is no longer rewritten or counted as repaired.
- Browser tests: a search whose request really fails, and a changed judgment sort with legislation off followed by Back, are tested in the browser.

## [1.1.36] - 2026-11-10

### Fixed
- Backups: when the free space on the disk cannot be read, the backup job now stops without deleting anything. Only a measured shortage may apply the retention rules early.

## [1.1.35] - 2026-11-10

### Fixed
- Document links: the weekly job that turns dossier numbers into links runs again. Two numbers that Justel gives to two documents each had stopped it; each now leads to the document a consolidated text will cite.
- Monitoring: the morning check no longer reports the Chamber feed as empty because its own query ran past its time limit; both parliamentary feeds now read only their newest rows.

## [1.1.34] - 2026-11-09

### Fixed
- Backups: below the free space they need, the backup jobs now apply their retention rules once, keeping the newest archive of each corpus, and check again. They used to stop before their own cleanup, so old archives stayed on the disk and the backups kept being refused (2026-11-07 to 2026-11-09).
- Disk: a finished article-index run removes its own replacement embeddings, a failed run's are cleared after 13 days, and a verified case-law repair removes its copies of the index. Every run used to leave them behind.
- Monitoring: the morning check no longer names the Praxis legal-corpus job, which the owner ended on 2026-11-09.

## [1.1.33] - 2026-11-09

### Fixed
- Law pages: an article that Justel publishes without an article anchor of its own is an article, not part of the heading before it. Article 1 of the new Strafwetboek (the legality principle) was printed as the bold heading of its chapter, in Dutch and in French, and articles Justel marks with a heading anchor, mostly ones inserted later ("Art. 1/1."), were printed as headings: 1,229 heading rows in 286 laws on production held such articles, and the chatbot's index, which takes articles only, did not hold them. The scraper (updater v0.895) stores them as articles; a law already in the corpus is corrected when it is fetched again.
- Browser tests: the linked-decisions and unified-search paging tests read the links in the page in one call, once Turbo shows the page itself rather than its cached preview; a Capybara count over node handles across that swap met an obsolete node for its whole wait (receipt-1-1-32).

### Changed
- The scheduled runs (daily 2.5, weekly 2.5, monthly 2.8, consolidations 1.3) and the refresh batches run updater v0.895; v0.894 stays in place for rollback.

## [1.1.32] - 2026-11-09

### Fixed
- Chamber lane: a hand run that re-reads both the dossiers whose people are in a broken shape and the older rows chooses each dossier once; a dossier in both groups took two of the run's places and left another out.
- Chamber lane: a dry run's title counts are the counts an apply writes; with both fiche titles, an empty French row was counted twice.

## [1.1.31] - 2026-11-08

### Fixed
- Search: Back and Forward over a source's own page of the combined results (its Next, Previous or a page number) bring each list back with the window where the reader was; they landed at the top of the page, above the results. Three faults of Turbo 8.0.23 after a frame navigation that changes the address are repaired: a flag left set that skipped the scroll of every later visit, the page cached under the address it had left, and a hovered link's frame response reused for a whole-page request, which then reloaded the page.
- Search: the "Zoekresultaten" region holds the case law and the parliamentary documents as well, with their own pagers; it closed after the legislation results.
- Parliamentary documents: the voting card's results heading says "1 stemming", "1 vote" or "1 Abstimmung" for a single vote; it said "1 stemmingen".
- Browser tests: a 50-row page-size control (Back shows the 50 in order with the form on 50, Forward the 10), the three-source Back and Forward journey, and the RSS menu's Escape cases checked on the exact element, including two links of equal text. The page-size test counts the visible rows in the page in one call; a Capybara count across Turbo's body swap after Search could keep failing although the page showed the rows (receipt-1-1-30-c).

## [1.1.30] - 2026-11-08

### Changed
- Law pages: the main heading is the law's own title, in the law's language (its short title where it has one, otherwise the title without its editorial notes); every law read "Details". A long title takes a smaller heading size. The Titel card keeps the official text in full.
- Chatbot page: the privacy notice is three labelled lines in readable text (saving, the storage password, getting an answer) with the privacy policy link and the detailed caveats under their own heading; the Praxis strip says what Praxis is for and links to more about it, without the unexplained "in Plus".
- Support page: the Pro section draws on the same model catalogue as the pricing page (the levels, their models, the preview and coming-soon labels, the Pro level and the sources Pro unlocks); it listed the models by hand, still called the Uitgebreid group "zodra beschikbaar", and named parliamentary documents but not case law.
- Support page: the two sentences about what is free name legislation, case law and parliamentary documents; they named the first two.
- Search filters: the sort of the legislation results and "Show abbreviations first" show only while legislation is selected, like the other legislation filters; each source's sort is labelled by its scope. Results per page stays shared.

### Fixed
- Parliamentary documents: a title cut at 200 characters by an earlier repair (7,225 Chamber and Senate titles, most of them mid-word) ends with an ellipsis in the reader and the lists instead of reading as complete; the words themselves are not guessed. The Chamber lane now takes the full title from the dossier's fiche whenever it reads one, and reads the French fiche for the French rows with `--retitle-cut`.
- Parliamentary documents: a former member of the Chamber, written on the fiche without a link, is read as a name and a party ("Segers Ben (Vooruit)"); the party sat between the names. Rapporteurs are written the same way as authors. A hand run can read the affected dossiers again (`--reread-broken-people`).
- Concordance tables: a sentence or clause qualifier after an article number ("1429 1e zin") is plain text; "1e" and "2e" became links to articles 1 and 2 of Book I.
- Search: a search whose request fails (a network error, an error response) shows the earlier results again; they stayed hidden under the loading view.
- Browser tests: the landing test waits for the frame's load event before it measures; the keyboard-navigation test makes sure the search field has lost the focus before typing the shortcut. Both had failed only under load.

## [1.1.29] - 2026-11-08

### Fixed
- Search: Back after a search that changed the number of results per page shows the earlier list again; its results area came back empty. The new search no longer empties the list before it leaves, and an empty list that comes back from the browser's history is fetched again.
- Search: a source's own Next or Previous on the combined results shows that source's new page from its heading, which gets the focus; the window stayed near the end of the new page.
- Parliamentary documents: the voting card speaks the interface language: the result ("Adopté" on the French site), the hemicycle's seats, results and legend, and a party's details. It was Dutch on every site. Speakers' names and the document's own text are unchanged.
- Homepage: the recent parliamentary documents are the newest by date, as on the View-all list; they were the ones imported last, which can be older. A document without a date comes last.
- Search filters: Escape in a date field with its calendar open closes the calendar and keeps the focus and the text in the field; the calendar stayed open and the focus fell to the page.
- Header menus: Escape with the focus outside an open menu (after Tab left it) closes the menu and leaves the focus where it is; it jumped back to the menu's button. Escape inside a menu still returns to its button.
- Judgments: the 1.1.27 entry overstated the paragraph rule. Precisely: below the one-line threshold, a line longer than 240 characters that ends a sentence stands apart from a following line that starts with a capital; a line of exactly 240 characters, a line that does not end a sentence, and a lowercase continuation still join. Tests now pin these edges.

## [1.1.28] - 2026-11-07

### Fixed
- Header: Escape on a colour in the accent-colour picker returns the focus to the button that opened it. 1.1.26 meant to do this but focused the first colour instead, hidden with the picker, so the focus still fell to the page.

## [1.1.27] - 2026-11-07

### Fixed
- Judgments: a list the text writes with dashes shows an en dash before each item; 1.1.26 showed two wrong characters instead.
- Judgments: a paragraph on a line longer than 240 characters stands apart from the next sentence in every text, also when few of the text's lines are long; it was joined to the sentence after it.
- Case law: a part of a subject that WetWijzer does not know is shown as stored and no longer claims a language; 1.1.26 gave it the language of the names beside it.

## [1.1.26] - 2026-11-07

### Fixed
- Search filters: a typed date that does not exist (31/02/2026) is kept and explained after Tab, a click elsewhere or Enter. 1.1.22 and 1.1.24 said this already, but the date picker emptied the field and then reported its own empty field as what the reader typed, so the field still went blank without a word. A day picked from the calendar afterwards replaces the text and the message.
- Case law: every subject is named in the interface language, also when a judgment has several ("Strafrecht - Internationaal publiekrecht" reads "Criminal law - Public international law" on the English site); only eight single subjects were translated. A part WetWijzer does not know stays as stored and says its language when the names beside it show it.
- Law pages: the contents filter keeps an entry for a range of articles that holds the typed article; "3" hid "Art. 1-4". Words and other numbers are matched on the text as before.
- Judgments and parliamentary documents: the "Full text" heading and the width choice line up with the text at every width, with Wide or Comfortable; on a wide screen they ran the whole card while the text was centred.
- Judgments: a text that gives each paragraph its own line (as Juportal's own pages do) keeps its paragraphs, short closing sentences and headings apart; the page welded them into one paragraph. A short title between a finished sentence and a numbered paragraph ("Ambtshalve onderzoek") is shown as a heading, and a list the text writes with dashes keeps its dashes. No word is added or removed: on 201 judgments the words are the same before and after.
- Homepage: a recent law's title says its language, so a French title on the German site is read as French.
- Header: Escape in the accent-colour picker returns the focus to the button that opened it; it fell to the page.
- Law pages: a contents link opens the folded sections around its article also when the address already names that article; the article stayed hidden.
- Law pages: a section around a linked article that could not be opened keeps saying it is folded; one check now decides both opening it and what its button says.

### Changed
- Judgments, parliamentary documents and law texts: three reading widths, Full screen, Wide and Comfortable, beside the text (on a law, above its articles). The text uses the full width of its card unless a narrower width is chosen; it was 64rem from a wide screen and 80 characters below. A signed-in reader's choice is saved in the profile and comes back on every reader and after a reload; a choice saved before keeps applying. Full screen is the page's reading width, not the browser's full-screen mode.

## [1.1.25] - 2026-11-07

### Fixed
- Law comparison: its Back link keeps the article the comparison was opened at after the comparison's own contents were used. 1.1.23 said this already, but those contents links reloaded the whole comparison, and the reloaded Back link no longer had the article. They now move within the page.
- Law pages: a folded or opened section's button says whether the section is open. Leaving a page could mark open sections as folded on the page still on screen, and a link to an article now also corrects the sections around it.
- Homepage: a recent parliamentary document's title says its language, so a French title on the German site is read as French.

## [1.1.24] - 2026-11-07

### Fixed
- Search filters: a typed date that does not exist (31/02/2026) is kept and explained. 1.1.22 meant to do this, but the date picker emptied the field first, so the field went blank without a word. The explanation is added to the field's own description and removed with it.
- Search: a source that was searched and found nothing says so, with its count of 0; a source whose search did not finish in time says that instead. The results area stayed empty.
- Search filters: the legislation filters show only while legislation is selected; results per page and sort stay for every source.
- Civil Code concordance tables: an old article of a repealed Act whose text WetWijzer does not hold (the 1991 product-liability Act) opens that Act's page, which links its official versions on Justel, and says so; the link pointed at an article that page does not show.

## [1.1.23] - 2026-11-07

### Fixed
- Case law: "Search in the decision text" decides what is searched. It starts ticked, which searches the decision text as every search did; unticked, only the case number, court, summary, subject and parties are searched. The box changed nothing, and its help said the default was the case number and court only.
- Search: after Back, the search and filter forms show the choices of the results on the page, not those of the next search; source boxes came back unticked and filters showed later selections.
- Homepage: Back returns to the source tab the reader was on; the tabs are one keyboard stop, and the arrow keys, Home and End move between them.
- Law comparison: it opens at the article the reader came from, and its Back link keeps that article after the comparison's own contents were used.
- Law pages: a link to an article inside a folded section opens the section.
- Classic: the link back to the modern site keeps the date filters and the source choice.
- Parliamentary documents: the type "aangenomen tekst" is named in the interface language ("Texte adopté", "Angenommener Text", "Adopted text").

## [1.1.22] - 2026-11-06

### Fixed
- Parliamentary documents: Senate titles show their dashes, apostrophes and other punctuation ("NAVO – Belgische delegatie", "l’occasion", "mise en œuvre"). They showed control characters: the text had been read in the wrong encoding.
- Civil Code concordance tables: an old article from a separate Act (the 1991 product-liability Act, the 2003 Act on public servants, the 1824 Acts on building and long-lease rights, and eleven others) opens that Act, not the 1804 Civil Code.
- Search: Return with no suggestion chosen searches, as the Search button does; it only closed the suggestions. The arrow keys no longer choose an item in a closed list.
- Search filters: the sort list offers relevance and shows the sort the results use; after a relevance sort, the next Search kept another sort.
- Search filters: the legislation type, language and scope checkboxes are named by their labels for screen readers, and a click on a label ticks its box.
- Search filters: a typed date that does not exist (31/02/2026) is kept and marked as not a date, with an explanation. It became 03/03/2026.
- Law pages: the "Go to" menu takes the keyboard: the focus moves to its first item, the arrow keys move between items, and Tab leaves it.
- Search: a results list restored empty by Back is loaded again only when it had finished loading, never while it still loads.

## [1.1.21] - 2026-11-06

1.1.20 was sealed but not released: its CI run was stopped when the build machine ran low on memory, with its first five stages passed. Its change ships here.

### Added
- Judgments and parliamentary documents: on a large screen the full text can be read wide or at the comfortable 80-character measure, from two buttons beside its heading. Wide is the default from 1,280 px, and the column is centred at both widths; a signed-in reader's choice is kept with their other interface preferences on the server, as the README describes; a visitor's is not stored, and nothing is written to browser storage. The text used under half the card at 1,550 px.

### Fixed
- Tax codes: a reference such as "article 145<sup>1</sup>" leads to article 145/1, as Fisconet numbers it, and is not linked when that article is not on the page. It led to article 145.
- Case law: the subject badges on the results are in the interface language. 1.1.19 said so, but translated only the filter: the results show the stored Dutch or French names, which the badges now translate for the eight subjects of the filter; any other stored name stays as it stands.
- Law pages: the link to the law's other language version keeps the article the reader is on (`#art-5-4`); it opened the other version at the top.
- Homepage: Recent legislation's View all lists the language of its cards; from the French content selection on LexLibera it listed Dutch and French, and that page's links went back to Dutch. The German site keeps its own languages.
- Law and parliamentary pages: the title of the text says its language, as its body does, for screen readers and hyphenation; so do the titles on the parliamentary lists.
- Parliamentary documents: the document type is named in the interface language, on the lists, the document page, a law's related sources and the RSS feed ("Rapport", "Bericht", "Report" for "verslag"). The French pages and feed showed the stored Dutch type. A stored type outside the 20 named ones stays as it stands.
- Law pages: the status says what the stored dates of entry into force say: "Not yet in force" when every date is still to come (Book 7, 1 September 2027), "Partly in force" when some have passed and others are to come or not set, and "Entry into force not set" when no date is set. A line that cannot be read keeps "In force". It said "In force" for every law not repealed.
- Tax codes: the document box gives the code's official NUMAC (1992041050 for the Income Tax Code), not the internal FISCONET number, and gives the act's date and its publication date as two facts (10 April 1992 and 30 July 1992). The act's date was labelled the publication date.
- Case law: a cited law opens in the decision's language where we hold it, under that language's title; a French decision's link opened the Dutch law. The decision page's subject badges are in the interface language, as on the results.
- Classic: the Justel link beside the language switch is the law's own Justel address; it was an address built from the date alone, which opened no record. A title search that orders by relevance says so, and no longer shows the date column's newest-first arrow.
- Law pages: an article reached by a link stays at the top while the page finishes loading; opened in a new tab, an amendment link left its article above the screen.
- Law pages: Compare, and its Back link, keep the article the reader is on; Back opened the law at the top.
- Homepage: the article range beside each book of the new Civil Code is read from the text it opens (Book 8 "art. 8.1-8.39", Book 9 "art. 9.1.1-9.1.54"). Eight of the nine typed ranges differed from the texts.
- Search: the suggestions show the book of the Civil Code a query names, as in the field's own example "BW boek 3" (and "Code civil livre 3", "Civil Code book 3"); they said there were no results.
- Search: Escape on a suggestion closes the list and returns to the field.
- Search: a sort chosen above the results is also the sort in Filters, so the next Search keeps it; it went back to the earlier sort.
- Search: a results list that comes back empty on Back is loaded again; after a change of page size it stayed empty until a reload.

## [1.1.19] - 2026-11-06

### Fixed
- Tax codes: articles numbered with a slash follow their number, 145/1, 145/2 ... 145/10, as Fisconet stores them. They read 145/1, 145/10 ... 145/17, 145/2.
- Law comparison: each column says the language of its text, for screen readers and hyphenation.
- Case law: the subject names in the filter and on the results are in the interface language. The English site listed them in French, the German site in Dutch.

## [1.1.18] - 2026-11-06

1.1.17 was sealed but not released: one system test failed in its CI run, on a timing race in the test itself. Its changes ship here.

### Fixed
- Case law: a list with a date or a year reads the date index. One day of French judgments took 50 seconds and the page showed its failure panel.
- Parliamentary documents: on a law's list, newest first and oldest first follow the date, and a third choice, parliamentary order, is the default; with a search word the list starts newest first, as before. Both date choices gave the parliamentary order.
- Tax codes: a reference such as "artikel 1:24" (an article of another code) is no longer linked to article 1 of the code on the page.
- Law pages: the link to a law's Fisconet version keeps the language of the text; from a French text it opened the Dutch one.
- Site search: a parliamentary document without a stored title is named by its type, dossier and number, and its line has no separator for a missing date.
- Civil Code concordance tables: the Book 9 card gives its own law (5 June 2025, Moniteur of 11 July 2025, in force since 1 January 2026), not Book 3's; the Book 6 card gives its law of 7 February 2024, not 1 February.
- Law pages: two dates of entry into force stand on two lines. The line-break markers were printed as text.
- Search filters: the labels of the display options and of the case-law and parliamentary filters name their selects, for screen readers.
- Footer and guided tour: the site is described as searching legislation, case law and parliamentary documents; the RSS step says the header offers all sources together or one at a time.
- Search: with suggestions open, a click on Search searches. A layer over the whole page took that click to close the suggestions.
- RSS: a feed of one source links back to the search with that source ticked alone. It opened with all three ticked.
- Law pages on phones: the closed contents panel is out of the keyboard order. Tab reached its hidden search field.
- Parliamentary documents: a Senate dossier's link says senate.be, the site it opens, not dekamer.be.
- AI security page: the ALTCHA link opens the geo-verification section of the privacy policy, in every language. It pointed at a section that does not exist.
- Homepage chat: the area-of-law select has a name for screen readers, as the model select beside it has.

## [1.1.16] - 2026-11-05

### Fixed
- RSS: a feed of one source names it in its title. The judgments feed was called "Latest laws".
- Search: with all three sources unticked, the page says that no source is chosen, instead of advising other search terms. The query stays.

### Tests
- Parliamentary documents: a legislature alone, with a year, a word or a parliament gives the same rows and count with the date index as without it, in date order.

## [1.1.15] - 2026-11-05

### Fixed
- Parliamentary documents: newest first and oldest first now follow the date, with a word, a year, a parliament or a legislature. They used to follow the row's number whatever was chosen. A document with no date comes last either way. A year with a legislature no longer reads the documents' text to choose a page.
- Parliamentary documents: dates and types come from the Chamber's own dossier page. Documents 002 to 010 were all called amendments, and many dates were those of a law named in the title. The weekly run corrects a few dozen dossiers at a time, and the stored dates were repaired separately on 2026-11-05: 21,551 wrong dates were replaced by the dossier's filing date or by none.
- `scripts/enrich_all.py` no longer takes the first date in a document's text for its date.
- RSS: a feed of one source, as the header's menu offers, holds that source only, and its own address says which. The judgments feed held all three.
- Law comparison: Back returns to the language the reader came from.
- Search: with exact search on, a search with no results no longer advises turning it on.
- Removal requests: the form's link to the privacy policy opens it. It answered 404 on every site.

## [1.1.14] - 2026-11-05

### Fixed
- Search: the unified search no longer walks the text of every judgment it finds to sort them. Pages read for a very common word, by SQL run by hand on production before this release: about 2,100 instead of about 608,000 for the list, about 3,700 instead of about 210,000 for the count. The whole page took about 90 seconds on some requests before this release; how much of that this was is not measured. A rare word now reads somewhat more than before.
- Search results: when the server cannot answer while paging, the results stay on the screen with a message and a way to try again, instead of being replaced by a bare "Content missing".
- Judgments: the address rule for rebuilt judgments no longer reads the floor `rez-de-chaussée` or the phrase `prend place sur` as a street with a number. Judgments already published keep their text until they are rebuilt.

## [1.1.13] - 2026-11-05

### Fixed
- Parliamentary documents: the search in the site-wide search and the year filter of the parliamentary list read far less of the corpus. Pages read, by SQL run by hand on production before this release, cold and warm cache mixed: the count of a common word with a language about 830 instead of about 56,700; page 1 of a year's list about 380 instead of about 63,700. Results of one date now come in a fixed order, so that a later page does not repeat a result.

## [1.1.12] - 2026-11-05

### Fixed
- Chatbot: a question about compensation in lieu of notice finds article 39 of the Employment Contracts Act whichever comes first in the question, the employment word or the compensation word. It had to be the compensation word.
- Case law: the privacy rules leave a word such as `Alle` or `Plusieurs` in full before a dotted acronym, as in `Alle O.C.M.W.'s`, where it became `A.`. This applies to text processed from now on; published judgments are unchanged.
- Tax codes: in the KB/WIB 92, the note on repealed article 49¹ is headed `Art. 49¹`, on the page and in downloads, where two provisions both read `Art. 49/1`.

## [1.1.11] - 2026-11-05

### Fixed
- Tax codes: in the 2027 edition of the KB/WIB 92, a reference to article 49/1 opens the article in force. It opened the note on the repeal of article 49^1, which is stored under the same number.
- Law sitemaps: a page that is not in the cache is built far faster, with the same content. In a local comparison on 45,000 invented laws: 0.2 s instead of 26 s.
- Case law: the privacy rules leave the lower-case ending of a word built on an acronym alone, as in `Q.U.I.'ers`. This applies to text processed from now on; published judgments are unchanged.
- Law downloads: the Typst and ODT buttons on an ordinary law download the law. They sent the reader to the home page with a message that the law had no articles; only tax codes and the Word format worked.
- Law text: in downloads, the plain-text law pages, the Classic pages and the data for search engines, a title or heading shows its quotation marks and `&` as text. Some of these showed a stray `&amp;`, and file names could carry the entity's letters. In a Classic search, a word in a title is marked without touching the text around it.
- Security: Rails 8.1.4.1, published on 2026-11-04 with fixes for 21 advisories on Action Pack, Action View, Active Storage, Active Support and Action Mailbox, among them a streaming denial of service (GHSA-rwvh-fw6r-pwvp) and cross-site scripting in the text and tag helpers (GHSA-2p2f-4rq4-gjwc, GHSA-68p9-83h6-5wpj, GHSA-rq8q-p985-fjq7, GHSA-v6rj-xm57-3p59).

## [1.1.10] - 2026-11-04

### Fixed
- Chatbot: a link in an answer about registration or inheritance duties now opens the article of the region it cites. It used to open the first region's article of that number, mostly Brussels, whichever region the answer was about. Where an answer's link holds no region, the region its wording names decides; where it names none, the federal text is opened if it was among the sources, and otherwise the first region's article, as before.
- Chatbot: the sources under an answer list each region's text of an article on its own line with its own link. Only the first of them was shown.
- Chatbot: a quotation linked to one region's article must now stand in that region's text.

## [1.1.9] - 2026-11-03

### Fixed
- Tax codes: on the regional codes (registration duties and inheritance duties), each article now has its own link. An entry in the table of contents opens its own article. A reference inside an article opens that number in the same region, else in the federal text, else the first article with that number in another region. A link used to depend on the article's number alone, so most entries opened an earlier article with that number. Old links to an article number still land where they did, and so do chatbot citations, which have not changed.
- Chatbot: finding the governing articles for a long question takes a fraction of the work: on one test question repeated to 2,000 characters, 0.4 s instead of 7.8 s on a busy machine. The changed checks are built to give the same answer: a comparison on about 26,000 questions and test strings found no differences, though 3 checks on a very long test text ran out of time and were not compared. If a check still runs out of time, the question loses that one article instead of all of them, and the answer says the search was incomplete. Before, it lost them all without saying so.
- Law pages: the chat prompt no longer opens where a visible button or link stands at that moment, because a press meant for that control opened the chat. It also goes away when the reader scrolls.
- Case-law index: requests to the embedding service stay within a token budget, and a refused request is logged with fixed words for the reason, not the provider's message.

## [1.1.8] - 2026-11-03

### Fixed
- Tax codes: the federal codes, such as the WIB 92 with its 788 articles and the VAT code, now have a table of contents, open in the main column, with its button in the toolbar and its sidebar. Only a document with regional variants had one.
- Parliamentary documents: a search for a common word and the later pages of a list no longer read the full text of every document they pass. One such count read 1.5 GB of the corpus and now reads 4 MB, with the same results.
- Parliamentary documents: the number of results and the pager now follow the legislature filter, as the list already did.
- Parliamentary documents: a search with nothing searchable in it ("!!!") now finds nothing. The page used to say the documents were coming soon.
- Home page: room is kept for the sample questions, so what stands below them no longer moves when they arrive or change. The longest sets can still take a row more on a narrow phone.
- Judgments: the compound of an acronym or an initial, such as "XYZ-steun", which name recognition now and then takes for a person, keeps its ordinary word after the initial ("X.-steun") when the document also writes that word on its own. Before, only the initial remained. This applies to new judgments and later rebuilds; texts already stored keep what they have.
- Security: Loofah 2.25.3, Nokogiri 1.19.7 and rails-html-sanitizer 1.7.2, published fixes for bypasses of HTML sanitizing and a use-after-free (GHSA-345x-3rq2-jfrm, GHSA-h6v6-rg66-fqj4, GHSA-jcff-cj73-4w4f, GHSA-m3x9-938q-5767, GHSA-mf2j-8f84-cc9q, GHSA-p9wj-w8xq-vjx6, GHSA-3w22-6jfg-527w, GHSA-4p39-36wj-23h4, GHSA-v995-44v6-5fqm, GHSA-cpgf-5mjf-73p7, GHSA-h7wh-q2qr-458c).

## [1.1.7] - 2026-11-02

### Fixed
- Law pages: between phone and desktop widths (768 to 1023 px) the table of contents in the sidebar can be opened again, from a contents button in the toolbar, by keyboard too; Escape closes it and returns to the button. Since 1.1.6 a long law had no way to open it at those widths, and other laws never had one.

## [1.1.6] - 2026-11-02

### Changed
- Law pages: a long law's table of contents no longer carries the note below it ("De inhoudstafel hierboven telt ... onderdelen") or its two buttons. The full list stays open in the page, with its count in the heading, and the sidebar keeps its own controls.

### Fixed
- Law pages: on a desktop, the closed table of contents at the left edge opens from the keyboard. Its handle can now take focus and shows it; before, only a mouse could open it there.
- Security: sqlite3 2.10.2 with SQLite 3.54.1, published fix for SQL text cut short at strings of 4 GiB or more (GHSA-4fqr-96q8-xrfx).
- Security: addressable 2.9.2, published fixes for denial of service in templates and path normalization (GHSA-4w5q-wg7v-w6gp, GHSA-9f42-57jx-vpp3, GHSA-j82w-28jv-3pmj, GHSA-qq38-m9mg-xjj5), dotted path segments (GHSA-8gmh-2hhj-2hv9) and misleading hosts in `display_uri` (GHSA-539f-xcgw-2gjg, GHSA-9crm-g4mf-wc5j).

## [1.1.5] - 2026-11-01

### Changed
- Council of State opinions: the members of the Council named in the closing of an older, scanned opinion stay named and appear in the opinion's bench. A name counts only on a line of a proved closing and only when the corpus knows it as a member's, and it is kept there alone: a person who shares the surname elsewhere in the text stays in initials. This applies to opinions built from this release on.
- Council of State opinions: a cited author also stays named when the citation gives the publisher after the year or before the place ("1988, Story-Scientia", "Bruylant, Bruxelles, 1990"), or a place and a year followed by a page. Opinions built from this release on.
- Public repository: each release is published as its own tagged commit with its changelog. The one-commit snapshot is gone.

### Fixed
- Council of State opinions and judgments: a treaty or regulation named in capitals ("la Convention MARPOL", "het Verdrag UNCLOS", "le Pacte PIDESC") is no longer initialled as if it were a person.
- Parliamentary documents: a short heading in capitals keeps the punctuation its source prints ("NOTICE:").
- Repealed articles: an older citation that names the repealing act only by its kind and date, such as `(Opgeheven) <W 18-03-1970, art. 3>`, now links that act when it can be identified: the only act of that kind on that date, whose title names the law the article stands in. The link opens the cited article when that article is on the page.
- Repealed articles: such a citation no longer links the first act published on its date, which was often another act. When the act cannot be identified the citation stays red text, with the Justel link beside it.

## [1.1.4] - 2026-10-31

### Fixed
- Search: going Back to the first page of a multi-source search shows the legislation status line again ("Wetgeving: 0 resultaten gevonden."). The restored page started a loading indicator that nothing finished, which replaced the line and could turn into a load error after 30 seconds.
- RSS feed: parliamentary items name their assembly in the interface language ("Kamer", "Chambre", "Senaat", "Sénat") instead of the internal codes "chamber" and "senate", and the LexLibera and GesetzGuide feeds link to the French document they list.

## [1.1.3] - 2026-10-31

### Fixed
- RSS feed: the newest parliamentary documents of the site's language are listed again, after the case law. They had been missing since 8 October 2026, when a cleanup removed the database connection that only the feed still used.
- Security: rack 3.2.8, published fixes for multipart parsing (memory exhaustion, GHSA-5v64-555j-wjxm; boundary handling, GHSA-p8x9-v4hv-2w4g), invalid `Host` values passed through by `base_url` (GHSA-2j8w-xcrc-x985) and `Rack::Static` header rules (GHSA-wvg4-6p58-3gh3).

## [1.1.2] - 2026-10-31

### Fixed
- RSS feed: building the feed no longer reads every case-law decision of the language to find the newest ten. A feed that was not cached took 25 to 212 seconds, so the reader who asked for it after a deploy or an hourly expiry got a gateway timeout; it now takes milliseconds. Equal decision dates are listed newest record first.

## [1.1.1] - 2026-10-31

### Changed
- Case-law pages, their print view and the Word, ODT and Typst exports say "This text may contain personal data." (in the page's language) instead of claiming that the text was automatically pseudonymised.
- RSS feed: case-law items carry the court, number and date only, no longer a summary. Category labels and date captions follow the interface language in English and German ("Date of promulgation", "Date of decision"; "Ausfertigungsdatum", "Entscheidungsdatum"), a law links to the text in its own language, and descriptions are escaped. The cached feed is kept apart per interface language, legal language, host and type filter.
- Popular legislation on GesetzGuide shows LisLoi's French short labels, marked as French, beside the German titles, since the cards open the French texts. The old Civil Code reads "(oud) BW" on WetWijzer.

### Fixed
- Law pages: the article text no longer touches the left edge of the hover highlight (for example Art. 7 of the Criminal Code). The hotfix of 31 October on 1.0.2 did this with padding alone, which narrowed the text column on a phone until a provision's table no longer fit; the highlight now extends outward instead, and the column keeps its full width.
- Classic site: a search result row opens the text in the language of that row. When a search listed the Dutch and the French version of one act, the French row opened the Dutch text on WetWijzer and LexLibera, and the Dutch row the French text on LisLoi.
- Security: crass 1.0.8 (CSS sanitizer bypass, GHSA-pq4g-8rxf-4g29) and view_component 4.20.0 (component state leaking across reused instances, GHSA-8qw7-6phv-7q6p). The build tool Vite 8.1.6 fixes its development server's advisories (GHSA-9jrq-w75r-8gcw and others); production serves pre-built files and never ran it.
- Law pages: loading the executive decisions that refer to an article says when none were found, when only some could be shown and when the list could not be loaded, each with a retry, in all four languages. A newer request replaces an older one, and a result that arrives after the page was left is ignored.
- Parliamentary documents keep text that was dropped as presumed boilerplate: blocks of abbreviation definitions, contact details, lines with dot leaders, repeated lines and the prose lines of a block that mixes prose and bullets.
- Search: the status line names legislation when it counts only legislation results ("Wetgeving: 0 resultaten gevonden."), so it no longer reads as a result for every selected source.
- Multi-source search no longer claims that nothing was found when another source has matches or a search timed out. A failed results frame shows a localized manual retry instead of Turbo's raw missing-content message, while retaining and labelling previously loaded results.
- Case-law scraper: the regular weekly run fetches missing official French Constitutional Court judgments into same-ECLI language documents, including a bounded rotating backlog outside the recent discovery window. It preserves the Dutch primary and retrieval index, requires French pseudonymisation and complete matching judgment text, retains withdrawals, and reports French source failures separately.
- Case-law pages: a published French Constitutional Court document links to its exact official French PDF; the language toggle and Word, Typst and ODT exports continue to use the selected document.
- Repeal references: Abrogé/Opgeheven links omit a lookup's source-language parameter so the destination uses the current site language, retaining article anchors and encoded URLs. Ordinary reference links retain their existing behavior.

## [1.1.0] - 2026-10-27

### Added
- Chatbot answers and exports: every answer carries a metadata record of what produced it: the category, the model that generated it (with its exact revision when the provider's response named one), the research depth and the reasoning setting the server actually used, kept apart from what was requested. The single-answer copy, PDF and Word document and every whole-chat export (copy, TXT, PDF, Word, Typst, ODT) print one line under each answer in the export's language. An answer from before this release reads "niet vastgelegd"; when no model answer is shown (a list of verified sources, a source-derived answer, a refusal, a time-out or an error) the line says so and what was asked, without claiming that nothing was sent. The record is kept in the browser history, the encrypted history and, with storage consent only, the server history; it never reaches the model, an invalid record is dropped whole, and an imported record is marked as imported and not verified. API results carry it as `answer_meta` and `answer_provenance`, with `category_used`; `model_used` keeps its meaning, the selected model.
- Chatbot exports: a legacy deep analysis kept after an answer now appears in the whole-chat exports under its own question, with its stored model marked as historical.
- Site wizard: an RSS feed step in all four languages, after the bookmarks step. It points at the RSS button in the modern header, or at a new RSS link in the mobile menu, and explains how to follow the feed with an RSS reader; the native guide (classic, and modern without scripts) offers one ordinary link to the feed. The wizard never opens or fetches the feed itself.

### Changed
- Chatbot sources: a general or neighbour-noise question ("Wat zijn de regels voor geluidsoverlast?", "Quelles sont les règles en matière de bruit de voisinage ?") retrieves the rules that govern it, each labelled with its scope: Civil Code Book 3 Art. 3.101 and 3.102 (abnormal neighbour nuisance), the GAS Act Art. 2 (sanctions for breaches of municipal regulations), Judicial Code Art. 591 2° ter (the justice of the peace), and per region the 1973 noise act Art. 1 (its Flemish version for Flanders), the Brussels noise ordinance Art. 13 and 14 and the Brussels Nieuwe Gemeentewet Art. 135. A named region gets only its own rules. Specialist rules (workers' protection, rail-wagon aid, noise-plan procedures, planning amendments, meter subsidies, inspection powers) no longer take the place of these rules, and join them only when that subject is itself asked. Facts dated before 1 September 2021 also retrieve the transition articles of the act of 4 February 2020. A question asked from a law page, or naming a NUMAC or an article, keeps its own sources.
- Chatbot sources: the 1973 noise act Art. 10 (inspection powers), repealed in Brussels in 1998 and in Wallonia and Flanders in 2009, is no longer used as current law, also when the act is named; it remains available for facts dated before its repeal.
- Chatbot answers: a general noise question is answered with an overview first and gives no general hours or decibel limits unless a source gives them for the place asked about; it asks for the municipality and the source of the noise when they change the answer.
- Deployment readiness: `--verify-pin-readiness` also verifies the noise rules, each in its own language with a phrase its text must hold; a regional version must carry its own region in both its title and its variant.
- Popular legislation: the 1976 matrimonial property act (Wet huwelijksvermogensstelsels) is listed right after the old Civil Code instead of after the Judicial Code.
- Reading layout: judgments and parliamentary documents read in a column of about 80 characters. Judgments, parliamentary documents, law articles (modern and classic site) and the information pages start on the left on a phone and are justified from 40rem, hyphenated in the text's own language. Captions, cards, headings and code keep their own alignment, and table cells on the modern site stay left-aligned.

### Fixed
- Legislation search: "Drugwet" and "Drugswet" also find the existing act under its formal title.
- Search results: sorting and pagination on the modern site update the results frame while keeping the filters and other open result sets. Classic and no-script navigation keep ordinary links.
- Judgments of the Council of State keep the structure of their source: sentences that the PDF extraction split over blank lines are joined, wrapped headings are whole again, paragraph numbers stay with their text and initials in a signature are no longer shown as headings. The Word, ODT and Typst downloads follow the same paragraphs and headings; the ODT download is valid XML again and the Typst download escapes Typst's reserved characters.
- Judgments: a defined acronym (such as "OVD") and a lettered section heading ("A. Beleidskadering", "V. Onderzoek van het beroep") are no longer initialled as if they were names, while persons in lettered lists of parties or neighbours still are. This applies to judgments pseudonymised from this release on; judgments already stored keep their text until a separate repair, which has not been carried out.
- Parliamentary documents are no longer cut at the first heading of the legal service's technical note, when they are shown or extracted; a text that an earlier extraction already cut (such as DOC 56 1817/001) needs a separate repair, which has not been carried out. A cover-page party-legend entry is removed only when it is recognised as a party and its name; every other line stays. Document 001 of a dossier is shown with its own type (bill or proposal), numbered headings ("123. PROCEDURE", "12.3. ADVIES") keep their numbers, and a sentence keeps its final number.
- Law pages: after "Toch laden" the confirmation appears and the notice about unloaded references disappears; the loading and error indicators no longer show while nothing is loading.
- Tax codes (the Fisconet text of WIB 92, KB/WIB 92, the VAT code and the registration and succession codes): the proven redundant opening headings of a provision, the source's own title line and standalone heading that repeat exactly that provision's identity (the article word and number, at most followed by a comma and one of the code's names), are removed under the generated `Art. N.` label; meaningful, version and unknown headings stay; an implementing instrument is headed by its stored title instead of its internal key; a targeted link is never dropped. The sanitizer keeps its bounded passes: the source's empty anchors, spacer paragraphs, runs of breaks and of non-breaking spaces and breaks beside blocks are removed, a line break between inline text is kept (the fragment-level break pruning is one linear pass), the body is no longer wrapped in a paragraph the browser auto-closed, and the provisions have even spacing.
- Tax codes, metadata card: the code's identifier (WIB 92 or CIR 92, KB/WIB 92 or AR/CIR 92, WBTW or C.TVA, W.Reg. or C. enr., W.Succ. or C. succ.), the legal form of the instrument and its subject are shown as three facts instead of three copies of the identifier; a code without a stored title shows the catalogue title of the requested language and marks that source; a code the catalogue does not know shows its other language's stored title marked with that language; a row without a document type takes no other code's metadata.
- Tax codes, exports and language: the existing copy, Word, Typst and ODT export surfaces carry the same source-backed label, title and language as the page (an export body may still repeat a heading the source repeats), and a Fisconet page or export requested without a usable language is redirected to its canonical language address.

## [1.0.2] - 2026-10-19

### Changed
- Release: 1.0.2 ships every change listed under 1.0.1, which was sealed for review on 2026-10-19 but not deployed on its own.
- Chatbot sources: a Dutch question about a rented garage, parking space, car or bike phrased with "over" ("Indexering huurprijs over mijn garage?") is no longer read as a home lease, so it no longer receives the three regions' home-lease rules; the English "over" before "a", "an" or "the" still names where the rented object is.
- Chatbot answers: the theft citation reads "Art. 463 — Strafwetboek" instead of "Art. 463 — Strafwetboek Boek II", as the 2024 criminal code is named whichever book.
- Chatbot answers: law articles reach the model complete, whichever model and research depth are chosen; the depth decides how many sources are read, not how much of each, where each article used to be cut to between 1,800 and 2,500 characters. One answer holds at most 128,000 characters of statutory text, counted on the complete articles: when that is full, lower-ranked articles are left out whole, and the Flemish, Walloon and Brussels versions of the same tax rule are kept or left out together. When a required governing article cannot be included, or nothing usable is left, the answer says that the search was incomplete instead of answering from a cut rule. EU legislation articles and recitals, the sealed official texts and the verified legal data the model receives are complete too and count toward the same limit; Belgian and EU case law, Advocate General opinions, guidance and parliamentary documents keep their excerpts.
- Chatbot sources: deposit questions also retrieve Brussels Art. 249 (placing and releasing the deposit) beside Art. 248, and "Wat is een arbeidsovereenkomst?" retrieves the statutory definitions in Art. 2 and 3 of the Arbeidsovereenkomstenwet, in Dutch, French and English (not for a subtype such as "contrat de travail en alternance").
- Chatbot sources: an employer's change of pay or working hours asked without the word "eenzijdig" ("Kan mijn werkgever mijn loon verlagen?") retrieves Art. 20 and 25 of the Arbeidsovereenkomstenwet; a part-time contract ("deeltijds contract", "contrat à temps partiel", "part-time contract") retrieves Art. 11bis, not the timeshare law; and a defective good, also asked without a purchase word, retrieves the consumer conformity rules (old Civil Code Art. 1649bis to 1649quinquies), never for a good bought from an explicitly private seller.
- Chatbot sources: a question on bringing a rental claim before the court ("Hoe stap ik naar de vrederechter voor huur?", "Comment saisir le juge de paix pour un litige de bail ?") retrieves the filing rules: Judicial Code Art. 1344bis and 1344septies for every region and, for a home lease, Brussels Housing Code Art. 233quinquies and 233octies, each labelled as federal or Brussels, with the Brussels rules in force since 31 August 2023. A hired movable, a garage or business premises keeps Art. 1344bis only and an agricultural lease none; a question that only names the judge ("Hoeveel huurverhoging kan de vrederechter toestaan?") or asks which court is competent receives no filing rule; and old Civil Code Art. 1743 (a sale does not end the lease) no longer joins a filing question that names no sale.
- Chatbot sources: rent indexation questions ("Huurindexatie berekenen?") also retrieve the Walloon indexation formula (Art. 26 of the decree of 15 March 2018) and the Flemish energy-label correction from 1 October 2023 (Art. 4 of the decree of 3 October 2022), not that decree's expired 2022-2023 restriction. The provisions of every housing topic a question raises, and the competence and filing rules of a filing question, are kept whole and first when they outnumber the research depth's sources, so a question on repairs and a rent increase keeps both topics' rules for all three regions; other sources share the remaining places, and the 128,000-character limit still applies.
- Chatbot answers: a lease, insurance or subscription notice question in English or German ("Notice period for 9-year lease?") no longer receives the employment notice periods, nor does a lease question that only mentions the asker's job; a dismissal or an employment contract in the same question still brings them.
- Chatbot answers: a sentence or heading that denies the zero-day withdrawal deadline ("Het is niet zo dat de herroepingstermijn verstrijkt op de dag waarop ...") is no longer mistaken for that claim; the claim itself is still corrected.
- Evaluation tooling: the German answer evaluation, and with it the weekly check of the German answers, answers with the research depth the browser links to the chosen model for the stated tier, refuses a model, tier or depth the run may not use, and records the selected depth beside the depth, effort and context policy the service actually used; its summary refuses to pool rows of different depths. Earlier runs used the legacy budget, so the weekly runs after this release are separate evidence of the linked configuration that needs its own review; no baseline or threshold is reset automatically.

## [1.0.1] - 2026-10-19

Not deployed on its own: superseded by 1.0.2, which ships these changes.

### Changed
- Chatbot models: Claude Haiku 5.5, Claude Sonnet 5.5 and Claude Opus 5.5 are offered on every surface (model selectors, homepage and widget, pricing page, research-depth bar) after the Frankfurt runtime access check of 2026-10-19; their tiers (Haiku and Sonnet for every account, Opus for Pro), credit prices, reasoning surcharges and the default selection are unchanged, and the pricing summary drops its "coming soon" clause while no configured model is pending.
- Provider spend accounting for Anthropic models on Bedrock: the cache-read and cache-creation tokens that implicit prompt caching reports are counted and settled at their published rates, Claude Haiku 5.5's higher tier is selected on the total input of the whole request, a creation token whose TTL is not reported is settled at the one-hour write rate (the reservation is kept only for malformed usage), and that reservation now bounds every input token at the highest cache-write rate and the output at the tier the prompt's size selects. Fixed credit prices and the user's charge-on-dispatch settlement are unchanged.
- Credits: the account menu and the account sidebar follow the accepted balance after a charge or refund on the same page, as the page and widget counters already did.
- Admin finance: the "Provider spend ceilings" subtitle states the sum of the provider cards beneath it instead of a stale total.
- Chatbot answers: a withheld answer that only lists the consulted sources is headed "Antwoord niet weergegeven. Geraadpleegde bronnen:" (with its French, English and German equivalents) instead of "Geverifieerd antwoord:"; an employer changing pay, the fixed schedule, the function or the working conditions "zonder akkoord van de werknemer", or "de arbeidsvoorwaarden eenzijdig wijzigen", retrieves Art. 25 of the Arbeidsovereenkomstenwet like the question "eenzijdig wijzigen van de arbeidsvoorwaarden".
- Research-depth bar: the first category's label ("Snel", "Rapide", "Schnell", "Quick") is shown in full at desktop widths, on the same row as the other three, instead of "Q..."; the category spans, ticks and selection are unchanged. The tracked production bundle now carries this release's credit-counter change.
- Popular laws: the criminal codes are no longer called old or new by name. The catalogue lists "Strafwetboek 1867" and "Strafwetboek - Boek I/II" (French, German and English alike), the 2024 code's badge is "Sw." ("C. pén.", "StGB") for either book, and the concordance table heads its columns "Oud artikel Sw." and "Artikel Sw. (+ niveau)" ("Ancien article C. pén.", "Article C. pén. (+ niveau)"), with its notes citing the 1867 code's articles as old articles of the Sw.
- Chatbot sources: an employer who wants to change "the contract" unilaterally, or to move a contract between full-time and part-time work, retrieves Art. 25, 20 and 11bis of the Arbeidsovereenkomstenwet; a bought product that does not work retrieves the consumer conformity rules of the old Civil Code (Art. 1649bis to 1649quinquies), but not for a purchase by a business; "Wat is een koop op afstand?" retrieves Art. I.8 of the Code of Economic Law; a rental dispute before the justice of the peace retrieves Art. 591 and 629 of the Judicial Code when the lease concerns an immovable (not for a hired bike, car or laptop, and Art. 629 not for an agricultural lease, which it excludes); "Indexering huurprijs?" reaches the indexation rules of all three regions, and defects and repairs in a rented home reach the three regions' repair rules. Book 7 of the Civil Code, which takes effect on 1 September 2027, is no longer presented as current law.
- Chatbot answers: an answer that lets the withdrawal period end on the day itself instead of 14 days after it, lists the sealed hygiene goods or alcoholic drinks exception without its condition, or says that a defect excludes the right of withdrawal, and an answer that gives the tenant's one-month counter-notice to the landlord or applies the short-lease rule to a nine-year lease, is sent back for a corrected version and otherwise replaced by the labelled list of consulted sources.

## [1.0.0] - 2026-10-19

The first formally versioned release of a product already in production. Its scope is what root reviewed for it:

### Changed
- Chatbot billing: a question is charged its reserved price once a paid AI request for it was sent (question embedding, HyDE, generation and its retries, German translations) and released otherwise; an error, fence, lost claim or timeout after a paid request keeps exactly one charge, and the answer or error shown says so (`charge_notice` on code-only errors). The free-incomplete-search note is retired.
- A consent grant, even with the identical key pair, cancels the account's active conversation claims, so an answer or encrypted snapshot of the previous storage generation is never delivered or accepted.
- Explicit clear and delete of a conversation run under the account's storage gate, the same gate as the first paid dispatch of a question.
- Admin dashboard and analytics: research depth, model and thinking mode as recorded with each answer (never the stored tier, never a default), charges from the durable ledger, cost and revenue labelled as estimates with their coverage; the legacy intelligence tier stays as a labelled, unpriced view.
- Copy: the model tooltip, the FAQ entry on when a question is charged, the privacy banner's billing clause and the chatbot sidebar footer prompt.
- Internal: the repository's lint debt (964 rubocop offenses in 125 files, none from this release) repaired in reviewed batches with no behaviour change, the test suites of the German sites and the incomplete-provider copy aligned with the billing policy, and the EU corpus acquisition job split into bounded helpers under characterization tests; the committed exclude-only baseline, configuration and gates are unchanged.

### Added
- `billing_reservations.work_dispatched_at` and `work_dispatch_kind` (additive accounts migration `20261018100000`).
- `VERSION`, `WetWijzer::Version` and `WetWijzer::Release`, `version` in `GET /api/release`, the version in the site footer and the admin header, and `rake version:check`, `version:bump[level]`, `version:tag_check[sha]`.
