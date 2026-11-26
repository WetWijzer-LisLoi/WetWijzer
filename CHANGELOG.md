# Changelog

All notable changes to the WetWijzer application are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the version numbers follow [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html) as applied in `docs/VERSIONING_POLICY.md`.

Everything deployed before 1.0.0 was unversioned: that history is identified by commit SHA only (production ran `a35840fba9f44fe8e22079fbb30022410ef7bf3a` when versioning was adopted on 2026-10-18), and no earlier release is retroactively given a number.

A section's date is set when the candidate is sealed for review, and the sealed commit is deployed and tagged (`vX.Y.Z` on that exact SHA) without any change to its files; a dated section is therefore a planned release until the deployed SHA, its tag and its receipt say it shipped. If the day changes before the push, the candidate is re-sealed with the new date.

## [Unreleased]

## [1.1.107] - 2026-11-26

### Changed

- The Praxis strip on the chatbot page is a short list of what Praxis does: case management, court documents in your own writing style, exhibit bundles, time tracking and invoicing.

### Fixed

- A question about transferring a sentenced person to a named country shows that country's transfer treaty and no other country's.
- Questions on penalties for drug offences no longer show the EU-Korea framework agreement on trade and cooperation as a source; a question about that cooperation keeps it.
- Answers about unemployment benefits keep the first benefit period of twelve months apart from its extension, which is the second period. They say that periods of a concurrent unemployment benefit do not extend the right, and tell admissions from 1 March 2026 apart from the transition for earlier admissions.
- An answer about unemployment with company supplement (SWT) cites the collective agreement that has the last employer pay the supplement, and who has a right to it.
- Answers about criminal fines give the 2.5 opdecimes as an increase of 25% as well.
- Answers about drug offences give the general fine ceiling of the Drugs Act apart from the rules for the offences the King designates.

## [1.1.106] - 2026-11-25

### Changed

- The weekly consolidation run ends with a status that asks for a look when the official database lists a newer version of the Drugs Act than ours, or a change on the day of our own copy, which may be newer. The law stays outside that run, which never fetches it; its refresh remains a separate step.
- The Praxis strip on the chatbot page says what Praxis does: drafting court documents with Praxi in the lawyer's own writing style, bundling documents and invoicing recorded time per case.

### Fixed

- The chatbot dates the new Criminal Code (Books I and II) to 1 September 2026, the day it took effect generally, instead of 8 April 2026, the day first planned. Facts of 8 April to 31 August 2026 are now compared under the old and the new Code with the more-favourable-law rule, as earlier facts were. A full date of an earlier year, and "before" any earlier date, now also count as facts before the new Code. The chatbot says that the treatment under deprivation of liberty and the extended supervision take effect only on 1 January 2035, unless the King sets an earlier date.
- A fine a court imposes is described with the 2.5 opdecimes of the law of 5 March 1952, applicable since 1 September 2026, instead of a factor of 8. The chatbot's verified source on opdecimes now reads that law; it pointed at another act of the same day.
- Questions on penalties for drug offences no longer show treaties on the transfer of sentenced persons as sources; a question about such a transfer keeps them, and a question about a transfer of money or data does not raise them. They now show the article of the Criminal Code that defines the penalty levels the Drugs Act uses, and the 1952 law on opdecimes.
- An answer about drug offences committed before 1 September 2026 says that our sources give today's text of the Drugs Act, and links its official version history on Justel.

## [1.1.105] - 2026-11-25

### Added

- In the admin, Pro access that an administrator granted by hand can be recorded as such, and the account then shows "N/A (manual Pro grant)" as its payment provider. The record changes no credits, payments or subscription and applies only to the Pro period it was recorded in: a later change of tier by an administrator ends it, unless it keeps Pro, and it stays visible as history afterwards.

### Fixed

- In the admin, the payment provider of an account names what its records show (Mollie, Crypto (CoinGate), Stripe (legacy) or no recorded provider) instead of a stored value, the provider subscription ID belongs to that provider, and "recurring subscription pending" needs a paid first payment. A payment refunded or charged back in part still counts as a payment; one refunded or charged back in full does not. Downgrading a Pro account that still has paid time works again; it failed since July.
- When one of the site's request limits is reached, opening a page in a browser gives a page in the site's language with the time from which it can try again and a link back to this site, instead of data meant for apps; apps and the site's own scripts keep the data. The limits do not change.
- In an answer on unemployment benefit, a later clause that names another household ("alleenwonend €57,53 en vervolgens samenwonend €60,92") is no later period, so the first amount keeps its own. The minimum amounts of art. 115, § 2 that an answer affirms to be the amounts literally in the article stay as written, each under its own household; where amounts are left out, such a sentence goes with them, while a sentence that denies or questions it stays. A sentence left after a removed claim of a check no longer starts in lower case.
- The n-gram readiness check of the operations runbook reads the database's tables through the application's own connection, which returns rows in another shape.

## [1.1.104] - 2026-11-25

### Fixed

- In an answer on unemployment benefit, a list or table of amounts that no official table confirms is left out and the answer says so once, instead of showing a placeholder for each amount, while a line that states a condition stays; a claim in the answer that the amounts were checked by hand is removed (beside an amount, only its own words), so that only the note under the answer dates the amounts, and a sentence about someone checking a file stays.
- In an answer on unemployment benefit, each amount is checked against its own period: an amount for the first months is no longer replaced by the amount the same sentence gives for a later period, periods written out in words such as "maanden een tot drie", "tot en met" and "en daarna" are read, and a daily amount given as a monthly amount, also by a sentence of its own about the amounts right above it, is left out with a note.
- The chatbot reads statutes without Justel's amendment markers, so an amended figure such as "maximaal [4 650 uur]4" is read as 650 hours, not 4,650; the articles shown on the site keep their markers.
- When the site's own question limit is reached, the chatbot says so in the reader's language, with the time from which questions can be asked again or the wait, and that the question was not charged.

## [1.1.103] - 2026-11-25

### Fixed

- A question that WetWijzer's own budget cap stops before the chosen model is asked now costs nothing, even when its search had already started; the notice says that nothing was charged only once the credits are back.
- When the chosen model's daily budget is reached, the notice says so, so that another model can be chosen, and such a question is refused before its search starts.
- The notice for a withheld quotation from a judgment names a consideration only when one consideration clearly holds the quotation without negating it, with the citations of that passage alone, and only the sentence right after it that vouches for the withheld quotation is removed.
- An error of the AI provider keeps its own status whatever the form of its reply.
- In a doorstep withdrawal question, "art. 3" no longer ends the request, and a law asked for by a short name such as "het horecabesluit" counts as asked.
- A length instruction such as "Antwoord in maximaal 100 woorden." counts as an instruction, not as part of the question.

## [1.1.102] - 2026-11-25

### Fixed

- A quotation from a judgment that cannot be verified is still left out, but the notice now names the consideration it comes from and the parliamentary documents the judgment cites there; a sentence that vouches for a withheld quotation goes with it.
- A question about a legislator's reasons that also asks for an explanation of a later act keeps that act among the sources; a request about the answer's language or length alone still does not.
- Under a doorstep withdrawal question, a law asked about in an instruction, such as "Pas het besluit ... toe", counts as asked.
- The speculation-tax questions get the dated capital gains facts, so the answer no longer gives the statutory base amount as the exemption for 2026 income.

### Changed

- When the AI provider's content filter refuses a question, the log records each category's verdict.

## [1.1.101] - 2026-11-24

### Fixed

- A question about a legislator's reasons that also asks for the answer in a given language still leaves out acts made after the date it names.
- A payment by credit transfer no longer counts as credit in a doorstep withdrawal question.
- A doorstep withdrawal question keeps sources on the consumer's withdrawal only, not every text in which something is revoked, such as a permit.
- Under a doorstep withdrawal question, a law named only by a word among the facts no longer appears; a law the question asks about still does.
- A question about a named judgment of the Constitutional Court that also names a subject of the Constitution, such as discrimination, no longer gets Constitution articles that only share words with it; 1.1.100 stopped this only where the Court's name was the reason.

## [1.1.100] - 2026-11-24

### Fixed

- A doorstep withdrawal question no longer gets an unrelated law in the place of a source left out, such as a royal decree on price indication in restaurants; consumer-contract law, the rules on withdrawal and any law the question names stay.
- A question about a named judgment of the Constitutional Court no longer gets articles of the Constitution that only share words with it; a question that names the Constitution itself, or asks about the Court in general, still gets them.
- A near-quotation is restored from the closest passage that holds its words, so a quotation that begins with a common word is no longer left out.
- An answer about the reasons a judgment quotes from the preparatory works can name the parliamentary documents as the judgment cites them.

## [1.1.99] - 2026-11-24

### Fixed

- A question about a legislator's reasons that also asks, in a clause of its own, what a later act says keeps that later act among the sources.
- A doorstep withdrawal question that also asks about a payment order keeps the payment-services rules of book VII of the Code of Economic Law, and leaves its credit rules out unless it names credit.

## [1.1.98] - 2026-11-24

### Fixed

- A question that names a Constitutional Court judgment but no paragraph, and asks for the legislator's reasons, gets the passages in which the Court quotes the preparatory works, and the answer is told which passages those are.
- A question about a legislator's reasons for an act of a given date no longer shows acts made after that date, unless it compares them or names their year.
- An online purchase made at home is no doorstep sale because a seller is named elsewhere in the question, while a home visit booked online still is; a contract signed digitally is no contract for digital content; rules on credit and payment services no longer appear beside a doorstep withdrawal question that names no credit or instalments; "les moins de 16 ans" and "âgé de moins de 18 ans" are read as ages of minors, and "âgé de 18 ans" is not.

## [1.1.97] - 2026-11-23

### Fixed

- A question about the reasons a court quotes from the preparatory works gets those passages of the judgment whole, also when it names no paragraph, and a passage a question names is no longer cut before the end of its quotation.
- A question that names one Constitutional Court judgment no longer shows the State Gazette's extracts of other judgments.
- A contract concluded at the consumer's home counts as a doorstep contract only when a trader came there, and an internet subscription sold at the door is not treated as an online sale.
- The old Civil Code's rules on digital content no longer appear beside a withdrawal question that is not about digital content.
- Two tax citations separated only by commas are each looked up in their own code.
- "For under 6 months" is no longer read as a child's age.
- An article's history names the amending act on its first opening when the current text is the saved wording.

## [1.1.96] - 2026-11-23

### Changed

- An article's history panel offers "Vergelijk met vorige versie" right below its dates ("Vergelijking sluiten" while the comparison is shown), keeps the amending act and the Justel link in a quiet "Bron en wijziging" section ("Wet van 19 oktober 2015 (gepubliceerd op 22 oktober 2015)", "Bekijk op Justel (015)"), and shows each period once, in the list of dates.

### Fixed

- Answers about the withdrawal period give their examples with weekday and year, say when the period ends if its last day falls on a weekend or a public holiday, apply the right only between a consumer and a business, tell utilities, a gas bottle and an order delivered in parts apart, give the longer period when the business gave no information about the right (information given more than twelve months after the contract or the delivery opens no new 14 days), and say that a withdrawal sent on the last day is in time even if it arrives later.
- A question about a contract signed at the consumer's home ("bij mij thuis, buiten zijn verkoopruimte") gets the rules for contracts concluded away from business premises, with the article on late information, and no longer those for distance contracts.
- A question about the permit for door-to-door selling no longer gets the buyer's withdrawal rules, also when it names the seller's customers.
- A question about a privacy statement is answered from the GDPR (articles 12 to 14) instead of from Belgian rules for the police, the intelligence services, social housing or the Coronalert app, which still appear when a question is about them, and without unrelated laws beside it. Asking which "inlichtingen" a statement must give is no question about the intelligence services. Dutch questions get the Dutch text of the GDPR.
- An EU article on a narrower subject than its act (unsolicited commercial e-mail, children's consent, GDPR fines) no longer appears beside a question that does not raise that subject. "What kind of" and "older than" no longer raise children's consent, and a reader who gives a minor's age does.
- The GDPR no longer appears beside a question about an objection in a public inquiry, nor the Consumer Rights Directive beside a question that is not about buying, selling or a contract with a business.
- The comparison of two wordings of an article no longer shows a word as changed when only its formatting differs, and keeps the words on either side of a horizontal rule apart.
- A question that names considerations of two court decisions gets each consideration from its own decision, also when each decision is followed by its own ("GwH 41/2009, B.7 en GwH 46/2019, B.5.3"), and a very long consideration no longer pushes out a shorter one asked for beside it.
- A question about the death of "ma propriétaire" (and similar wordings in each language) is read as the landlord's death, not the tenant's.
- A cited tax article written as "artikel 131 KB / WIB 92" or "W.Reg., art. 42" is looked up in the code it names, also when two such citations follow each other ("W.Reg., art. 42 en WIB 92, art. 131").

## [1.1.95] - 2026-11-23

### Changed

- An article's history no longer moves the page. The article's number stays first and where it is; the history panel opens below it, and choosing a date, the comparison and Close change only what stands below the number. No step scrolls the page.
- The history panel has no Older and Newer: its dates are the choices. A wording that ends the day before the next one starts is listed by its start alone.
- History in an article's menu opens that article's history and closes it when it is open; the item says which.
- The comparison with the previous wording stands inside the wording's normal presentation: common words once, added words in the colour of their amendment, removed words struck through where they stood and never as a link, a replacement old then new. When no word changed, a line says so.

### Fixed

- A question that names a court decision by its ECLI, or a Constitutional Court judgment by its number ("arrest nr. 41/2009", "GwH 41/2009"), gets that decision, fetched directly, instead of decisions a search finds near it. A consideration the question names ("B.7", "B.1.7 en B.5.3") is given whole, from its label to the next one, for the decision it belongs to, and a named decision WetWijzer does not hold is said to be missing.

## [1.1.94] - 2026-11-23

### Fixed

- A question about a privacy notice ("Wat is een privacyverklaring?", "privacybeleid", "déclaration de confidentialité", "Datenschutzerklärung", "privacy notice") found no EU article and leaned on special Belgian provisions. An EU topic plan now selects GDPR arts. 13 and 14, the information a privacy notice gives, and art. 12 on how it is given.
- The tax citation repair reads only the tax code a citation names: "artikel 42 W.Reg." no longer also brings the VAT code's art. 42, and "KB/WIB 92" is not read as "WIB 92".
- A question about a doorstep sale ("Wat zijn mijn rechten bij colportage (huis-aan-huisverkoop)?") could get an answer that let the 14 days start on the day of signing or receipt. Such a question now gets the counting rule of WER art. VI.67, § 2, before the article: the day of the contract (services) or of taking possession (goods) is the starting point and is not counted, with a dated example of the first and the last day for each. The 14 days for sending the goods back (art. VI.71) are kept apart.
- A death word that belongs to the landlord ("Wat moet ik als huurder doen na het overlijden van mijn verhuurder?") no longer reads as the tenant's death, and "deceased" and "passed away" count for either party.

## [1.1.93] - 2026-11-23

### Fixed

- EU articles that only shared words with a question reached its cards and the model's context: the AI Act art. 6 and GDPR arts. 8 and 83 under "Zijn algemene voorwaarden altijd bindend?" (the Dutch title of GDPR art. 83 begins with "Algemene voorwaarden"), and the e-commerce directive art. 7 under "Elektronisch voorschrift?". The narrow-subject rule of 1.1.92 never saw EU articles; it now judges them as it judges Belgian ones. An act the question names (by CELEX, alias or ECLI) and the articles an EU topic plan or website overview selects stay. On the 2,877 Dutch catalogue questions, 143 of the 286 EU articles found by word overlap stand under a question that does not raise their act's subject and are left out: 77 of the AI Act, 28 of the GDPR, 24 of the e-commerce directive and 14 of the Digital Services Act. In the French, German and English catalogues 794 of 1,533, 1,604 of 2,026 and 503 of 770 such articles are left out; reading them showed six words the lists lacked, now added: German compounds of "online" and "Webseite", French "en ligne" and "courriel", and English "processing" and "medical file". Dutch privacy compounds ("privacyverklaring", "privacybeleid") and the French "confidentialité" now raise the GDPR too: no catalogue question lost a row for want of them, but a question about a privacy notice would have.
- An answer that cited an article of another law brought tax-code articles with the same number as cards: the citation repair looked each rejected number up in every retrieved tax code, so "Art. 42, § 1, Wet van 26 maart 1999" brought VAT code art. 42 and W.Reg. art. 42 of each region. A rejected number now reaches the tax codes only when its citation names a tax code or links to one, or names no law while no retrieved Belgian law holds that number.
- A death is read for the party it follows: "Ik ben huurder en mijn verhuurder is overleden" gets the rules that keep the lease (Flanders art. 42, Wallonia art. 36, old Civil Code art. 1742), not those that end it at the tenant's death. A landlord's death also needs a lease word, so the death of a company's or a car's owner gets no lease rule (1.1.92 gave it the landlord's).
- The French "Ai-je ... ?" no longer raises the AI Act.

## [1.1.92] - 2026-11-22

### Fixed

- Asked what a controller is, the chatbot gave the citation check's refusal on 1.1.91: retrieval gave the model rows of the Belgian act of 30 July 2018, the model based its definition on them, that act may not stand in for a GDPR definition, the retry received no correction for that fault and was not made, and the list of consulted sources that replaced the answer showed the same rows. A question answered from a GDPR source sealed by topic (the controller, the processor, retention, a data breach, direct marketing, a commercial website) no longer gives the model or the cards the rows of that act, except art. 10/2 on cookies for a website question, and an answer that cites that act for a GDPR rule is retried with a correction that names only its NUMAC. A reader who asks about that act too ("de Belgische wet van 30 juli 2018") keeps it in the context and may see it cited for its own clauses; the GDPR's definition is still required.
- A link label that names each point of GDPR art. 4 with its own article prefix ("Art. 4(7) and Art. 4(8)") is read to its last point, so a controller answer with that label is not shown for point 8, and in a valid comparison the label no longer stops the answer: the citation check now treats a later citation of the same article in one label as verified when it continues the list and names its own point, and a point written as in the GDPR's text ("artikel 4, 7) AVG") as that point, while any other article in the label still needs its own link; a semicolon continues the list of points as it continues the masking, so "Art. 4(7); Art. 4(8)" names point 8. An English or German question about the difference between a controller and a data processor ("Auftragsverarbeiter") gets both definitions and art. 28, and "data controllers' obligations" is no longer taken for a definition question.
- An unemployment amount is checked against the minimum of art. 115 that the facts around it select, not against the figure itself: the regime (full or temporary unemployment, or with a company supplement), the household, the phase of the compensation period and, for temporary unemployment, its cause, read from the figure's clause and sentence, the earlier sentences of its paragraph that give no figure of their own, a table's header and the question. When the facts select one minimum, its amount of the schedule is given; when only the figure does, the facts it leaves out are added, such as "(alleenwonende werknemer, eerste zes maanden)"; when neither does, the figure is withheld and the line says why. 63,29 euro said of a worker with family charges in the first six months becomes 78,09; an amount said of unemployment with a company supplement is withheld under a placeholder that names no table; the period that an earlier sentence names ("In april 2026 gold het volgende.") dates the next one; a copied note goes even when no figure is left; and when the quotation check withheld a quotation, a sentence that only refers to the quoted amounts goes too. "Na de eerste zes maanden", and its French and German forms, name the later phase rather than the first six months they contain, and the "premiers mois" of a French answer no longer reads as another cost (the Dutch "premie"), which on 1.1.91 left the base amounts of such a sentence unchecked. A negated household ("alleenwonende zonder gezinslast") is read as absent, a sentence that refers to the period of the one before it ("in dezelfde maand") takes that period even when that sentence has a figure of its own, and "deze maand" is the present.
- Unrelated cards, and the model's context with them: a law of a narrow subject is kept only when the question raises that subject, before the context is built. The subjects: the statutes and internal services of public bodies, a sector's social fund, excise, the LPG premium, food of animal origin, public procurement, the jury, hospital financing, education and its staff, the AI Act, the GDPR, the e-commerce directive, income tax, VAT and the registration, gift and inheritance duties. The rule covers the legislation, European and regional sources; Fisconet keeps its own. A program law, or diverse provisions over more than one domain, belongs to none; a law of a specific subject is judged by it alone; an article pinned for the question, a law named by its NUMAC and the law being viewed keep their sources; and a question about the source the reader is shown ("Explain this specialist source.") keeps them only when no law is being viewed, since with one that law is the source shown.
- The governing provisions for more catalogue questions: a tenant's death gets the ordinary rule of each region (Flanders art. 42, Wallonia art. 46, Brussels art. 232, and old Civil Code art. 1742), and a landlord's death only the rules that keep the lease (Flanders art. 42, Wallonia art. 36 of its decree, which replaced art. 1742 there, and old Civil Code art. 1742); legal-expenses insurance gets arts. 154, 156 and 157 of the Insurance Act, and "rechtsbijstand" at a police interview does not; what a collective agreement is and whom it binds gets arts. 5, 19, 26 and 31 of the act of 5 December 1968; and an employee's warrants get arts. 42 and 43 of the act of 26 March 1999, also beside a comparison with warrants bought as an investment. A door named only as the place of delivery no longer selects the doorstep-sale rules, an insurer's payout keeps the general-terms rule, and the dossier 56K0002 stays unrelated to a law while 55K1579 keeps its link.

### Changed

- The npm audit gate no longer excepts GHSA-fc5q-39xc-vjpf (picomatch): GitHub withdrew that advisory on 18 November 2026.

## [1.1.91] - 2026-11-22

### Fixed

- The chatbot no longer gives the unemployment decree's base amounts as the amounts paid now. Art. 115 of the royal decree of 25 November 1991 sets the minimum daily amounts at the pivot index of 1 June 1999 (art. 113), and an answer gave 34,94 euro a day for a single claimant, and 38,72 and 35,74 euro for temporary unemployment, as the current minima. The decree's articles now reach the model with the indexed minima. In the answer, a minimum of art. 115 stated in euro in a sentence about the benefit, or its indexed amount at another pivot index, is checked against the schedule of the period that its sentence or the question names, else today: a wrong amount becomes the amount of the RVA's tables valid from 1 September 2026 (63,29, 70,14 and 64,74 euro in those cases) and a right one is kept, and a line under the answer says that art. 115's amounts are base amounts, names the table of each regime used, full or temporary unemployment, in the reader's language, and says that the amounts were checked by hand on 22 November 2026 and that a later indexation may since have replaced them. A sentence about another cost, such as a travel expense or a rent, keeps its amounts unless it also names the benefit; a sentence that calls an amount a base amount keeps it; link labels and destinations, code and article numbers are never changed; and a quotation of art. 115 keeps its base amounts, with their indexed amounts given apart. A figure is withheld, and the line says why, when no schedule checked by hand covers the whole period (before 1 September 2026, or more than 120 days after the check), and for the minima of unemployment with a company supplement, which no official table shows indexed. Monthly amounts the model calculates and the maxima are not checked.
- Asked what a controller is, the chatbot gives the definition in art. 4, point 7, of the GDPR, literally, in the reader's language, and cites it: a Belgian special provision no longer stands in for it. A question about the difference between a controller and a processor gets both definitions. Art. 4 gives every definition at one link, so the label of a link to it names the point it cites: a required point that no label names is added under its own label, and an answer whose label names a point the sources do not give at that link is not shown. A question about what the controller must do ("Wat is de verwerkingsverantwoordelijke verplicht te doen bij een datalek?") is no longer taken for a definition question. Questions about the processor in French, German and English are answered from art. 4, point 8, and art. 28, paragraphs 1 to 3, of their own language edition instead of being refused for want of an official source. The Dutch definition of the processor now reads "namens de verwerkingsverantwoordelijke", as in the consolidated text that includes the corrigendum of 4 March 2021, instead of "ten behoeve van", the Dutch labels call it point 8 of art. 4 instead of paragraph 8, and the GDPR sources link that consolidated text.

### Security

- Puma 8.0.4 (from 8.0.3), for two advisories published on 22 November 2026: GHSA-4v6q-hvv7-49h9, memory exhaustion with SSL connections, and GHSA-rhww-p99c-hgj9, request headers changing the request path in the JRuby HTTP parser. Production terminates TLS at nginx, which passes plain HTTP to Puma on 127.0.0.1, and runs MRI, so neither was reachable there.

## [1.1.90] - 2026-11-22

### Fixed

- A law's parliamentary preparations no longer link a reference that cannot name the dossier. Justel's parliamentary work for a law before 1995 names a session's documents and dates, and these were read as a legislature and a dossier: on Part I of the Judicial Code "Kamer 59-0002" (the Chamber's amendment no. 59-2) opened the Chamber's current dossier 56K0002, a list of members by language group, and "7-4", the date of a bill of 7 April 1965, was read as dossier 4 of a 7th legislature. A reference is now no link when its legislature is not one the house numbers dossiers by (the Chamber from its 49th, the Senate from its 1st, both from the elections of 21 May 1995), or when the Chamber corpus holds the dossier with a type that prepares no law (a resolution, a coalition agreement, the house's rules and the like) or as a budget document (a list or table, a policy note, a general explanation, a report) while the law is no budget law. A dossier the corpus does not hold, a blank or unlisted type, and a dossier of a later legislature than the law keep their link, still shown as automatically linked and unverified. When the Chamber corpus cannot be read, the law's metadata shows Justel's Chamber reference as unverified text, without a link. The panel, its "view all" list and the metadata follow the same rule.
- The chatbot's governing provisions for more ordinary questions: a telephone sold at the door, and a sale concluded at the door after a call, are doorstep sales (only canvassing by telephone is left to the distance-contract rules); a refund asked from a seller, or terms that "permit" a return, keep the general-terms rule (only the conditions of a benefit or a permit are left out); a worker who declares a disputed industrial accident themself gets art. 62 of the Industrial Accidents Act, whose second paragraph lets the victim declare, and is no longer taken for an appeal, while an appeal filed by the worker still is one; a stated public-sector case no longer gets that private-sector article; and the Flemish "erfbelastingaangifte" gets the succession declaration deadline.

## [1.1.89] - 2026-11-22

### Added

- The chat bubble has its own menu, asked for by the owner: a right-click, the context-menu key or Shift+F10 on the bubble offers one action, "Standaardpositie herstellen" ("Rétablir la position par défaut", "Standardposition wiederherstellen", "Reset to default position"), which puts the bubble back at its default place without opening or closing the chat. The panel keeps its size, its open or closed state and what was typed. Escape, Tab or a press elsewhere closes the menu, and a left-click and a drag work as before. Touch keeps the reset in the panel header, without a long press that would compete with dragging.

### Fixed

- For a signed-in reader, a reset position came back from the server on a later page: the saved layout was merged into the stored one, where a key that is left out is kept. A change of place now saves only the place and a change of size only the size, each as its own key, with a null for a place given up, which deletes it; a reset made before the saved preferences arrive is kept over them and leaves the saved size alone. The reset in the panel header deletes the stored layout instead of merging an empty one into it.
- A signed-in reader's saved position and size are applied once the preferences arrive from the server. On a full page load they arrived after the widget had been set up, so they only came back with the next page visited inside the site.
- The chatbot finds the governing provision of four ordinary questions that name no article: the deadline to report an industrial accident (royal decree of 12 March 2003, art. 2, beside art. 62 of the Industrial Accidents Act), whether general terms bind (Civil Code art. 5.23), withdrawing from a doorstep sale (Code of Economic Law arts. VI.67, VI.69 and VI.71) and the deadline of the succession declaration (W.Succ. art. 40 as Fisconet holds it for each region, where the Flemish entry points to the Flemish Tax Code). A flight delay or cancellation named in one word or by the aircraft now asks for Regulation (EC) No 261/2004; its articles reach an answer once the regulation has been fetched. Each is kept to its subject: a bailiff at the door, a sale by telephone, the conditions of a benefit or an appeal against a refused accident claim does not bring them.

## [1.1.88] - 2026-11-21

### Security

- Ruby 4.0.10 instead of 4.0.5, on the web server, the background jobs and in development, CI and the container image. Ruby's own advisory GHSA-34m4-m9fh-gqp5 (published 2026-11-19, critical) reports a heap buffer overflow in the case conversion of strings in some single-byte encodings that may allow remote code execution, in Ruby 4.0.0 to 4.0.9; GitHub lists it as CVE-2026-132825.

### Fixed

- A release that changes the Ruby version can be deployed. The deploy hook ran the new release's checks with the Ruby the running server had been started with (rbenv's `RBENV_VERSION` and `RBENV_DIR`), and refused the restarted server because that variable had changed.
- Law pages, articles: a press on an article's number while its new wording is being shown (a step, a period, a comparison) opens that article's menu, also when the new wording moved the number, and a copy chosen at once is the wording switched to. In 1.1.87 such a press could land on the text and open no menu (a live check on the Judicial Code: from wording 021 to 006 the number of article 20 moved up 40 px).
- Law pages: the text of an article no longer scrolls inside its own box. A one-line article showed a vertical scrollbar that scrolled one pixel (seen in the dark theme). A table wider than the article scrolls sideways in a region of its own, which also scrolls with the keyboard.

### Changed

- Law pages, articles: the article menu no longer repeats the article's number as its first row. Its accessible name still names the article, also after a switch, and History is the first row where the article has one.
- Admin, Users: 200 accounts per page by default, with 25, 50 and 100 to choose; any other value of the size, such as "25.5" or a list, gives 200. Every page, size, sort and filter link keeps the query, the sort, the filters and the size (the pages used to drop the abuse filter), and a new query, filter, sort or size starts at page one. Previous and Next for every sort; at the browsing limit of 10,000 rows there is no Next link, and the page says why. The cached total is labelled as all non-admin accounts, not as the filtered number.

## [1.1.87] - 2026-11-21

### Fixed

- Law pages, articles: a copy right after switching an article's wording takes that article's chosen wording. When the article was shown again under its open menu, 1.1.86 closed the menu; Turbo then scrolled to the article, and a press meant for a copy item reached the page instead, where it could open the next article's menu and copy that article (a live check on the Judicial Code: article 20 in French, copied as article 21). The menu now stays open, in its place, for the article's new number, and a copy chosen while the switch is still on its way waits for it and copies the wording switched to. A switch that fails, or has not arrived within five seconds, copies nothing and says so.
- Law pages, article history: in a comparison, the copied wording keeps its paragraph breaks and the line before its amendments ("Wijzigingen"), as the plain view's copy does; it ran together as "bepaald.Wijzigingen[1]".

### Changed

- Home page, frequently used laws: an abbreviation ("ZIV-wet", "Loi AMI") follows the last word of the law's name, one space after it, and moves to the next line whole. It no longer stands apart at the right of a long name or breaks at its hyphen; the row is still one link.

### Removed

- Chatbot: the unused marks that once called a reasoning level recommended, or not recommended, for a model: the reasoning levels' lists, the settings script that looked for them, and an unused "recommended" card style on the legal pages. No model, depth or reasoning choice is called recommended; GPT-6 Luna stays the default and saved choices are kept. A test checks the choices on all four sites.

## [1.1.86] - 2026-11-21

### Fixed

- Law pages, article history (Judicial Code Part I): in a comparison the article's identifier ("Art. 20.") stands on its own line above the compared words and opens the article's menu. 1.1.85 looked for the number inside both wordings and needed a space after its dot, which Justel's texts do not have ("Art. 20.Les voies ..."), so on the live Judicial Code the comparison of article 20 had neither a number nor a menu. The identifier now comes from the article itself, and each wording loses it only when it starts with exactly that number, also written in full ("Artikel 20.", "Article 20."), so the number no longer shows as a changed word; a longer number such as "Art. 20/1." is never taken for it.
- Law pages, article history: on an archive date where an article's wording is unknown (a gap), the article's identifier is shown, and its menu offers the history and the link; there is no wording to copy.
- Law pages, articles: the menu names the article it is open for and closes when that article is shown again after a step. In a live check a copy right after switching article 20's wording once took article 21; that has not been reproduced since.
- Law pages, article history: after quick steps in two articles, the address names the reader's latest step, as its fragment already did, so a fresh visit opens that article's picker.
- Law pages, article history: a Back or Forward that changes only the fragment (an anchor) keeps the page as it is, with every open picker, and returns to the reader's place on that entry. Before, the page was loaded or rendered again and kept only the picker the address names.
- Law pages: when a reader left a law before a deep link's articles had loaded, the jump to the article could still run and write its anchor into the next page's address as a history entry of its own, so Back stayed on that page. The jump now runs only while the law is still on screen at the same address, so not after a move to another page, archive date or language.

## [1.1.85] - 2026-11-21

### Changed

- Law pages, articles: the article number now opens the article's menu, by a click, a tap, Enter or Space, and nothing is copied until a copy item is chosen: the article's link, its text or its citation. Until now a click on the number copied the article's link at once, before the menu opened, on the Justel laws and on the Fisconet codes. Escape, Tab and a copy put the focus back on the number. The number shows that it is a control, with a dotted underline and a keyboard focus ring.
- Law pages, article history (Judicial Code Part I): the history icon before the article number is gone, and the text has the article's full width again. For an article with history, the article's menu holds "Geschiedenis" ("Historique", "History"), which opens that article's history in place; closing it puts the focus back on the number. The history is now named "Geschiedenis van artikel 20" ("Historique de l'article 20"); single wordings and comparisons keep "versie".
- Law pages, the Tekst toolbar: one row of four plain controls, Geschiedenis, Weergave, Kopieer and Exporteer. Geschiedenis, on a law with published history, opens the law's archive by date at the top of the page, with the focus in its date field. Weergave holds the switches for colours, highlighting and amendments, the implementing decrees and the three reading widths. The yellow "Uitvoeringsbesluiten niet geladen" banner is gone: the decrees load from Weergave, with the estimated time, and their loading, a failure and the retry show beside that action. On a phone the row wraps without horizontal scrolling.

### Fixed

- Law pages, article history: two articles changed quickly no longer lose a choice. When the step in the second article was sent before the first article's step had come back, the address kept the first article's old wording, so a reload or a shared link showed something else than the screen. The address is now rebuilt from what every article shows each time a step lands, whatever order the answers come back in. Every article's step links carry the other articles' choices, so copying or opening one gives what is on the screen.
- Law pages, article history: in a comparison the article number is shown again, and with it the article's menu; on the archive by date the article number opens the same menu as on the current law. Both copy the wording shown or chosen.
- Law pages, article history: the "Onopgeloste data voor" note on an archive date lists the same articles after a reader picks a wording in one of them as on a fresh visit of that address. The note states the law's dates on that day, which a reader's choice does not settle; a fresh visit used to drop the article whose wording the reader had picked.
- Law pages, article history: Back and Forward keep the law's archive by date open when the reader had opened it.

## [1.1.84] - 2026-11-20

### Changed

- Law pages, article history (Judicial Code Part I): the history control is now an icon before the article number, a clock with a counterclockwise arrow, named after its article ("Versies van artikel 20", "Versions de l'article 20"). The article reads as the law does ("Art. 20. Middelen van nietigheid..."), with its own amendment markers and source links. Copying the article or its citation gives that wording alone, whether the picker is closed or open: the picker, the chosen version's period and the date notes stand beside the text, outside what is copied. In a comparison, the changed words are shown and the chosen wording is what is copied. The icon has a visible keyboard focus and a 32-pixel target, opens the article's picker, and gets the focus back when the picker closes. On a phone it keeps its own room beside the text.
- Law pages, article history (Judicial Code Part I): a step in one article's history, whether opening its picker, an older or newer wording, a period, the way back or a comparison, now changes that article alone, in place. The rest of the page, the law-wide archive by date and the other articles keep their state, and no other part of the law is loaded again. The address still records every choice, so a link restores the wording and Back and Forward step through the choices; choosing a wording in one article keeps the choices made in the others.

### Fixed

- Chatbot, flight delays and cancellations: a question about a delayed or cancelled flight that names no act now has Regulation 261/2004 fetched from EUR-Lex, as a question naming it already did. Since 14 October no question topic is fetched, so once the cached copy of the Regulation expired nothing brought it back. The one answer that triggers the fetch carries the existing note that EU sources are being fetched and checked in the background and that the question can be asked again later.
- Chatbot, flight delays and air baggage: the Montreal Convention's limits are now given as ICAO revised them with effect from 28 December 2024: 6,303 special drawing rights per passenger for delay and 1,519 for baggage. The 4,150 and 1,000 in the Convention's published text are the original 1999 amounts.
- Chatbot, police custody: a question on how long the police may hold someone ("Hoe lang mag de politie mij vasthouden?") now gets Article 31 of the Police Function Act beside the 48 hours of a judicial arrest: an administrative arrest lasts no longer than the circumstances require and in no case more than twelve hours, unless another national or binding international rule provides a different term.
- Chatbot, estate declaration: a question on the deadline for the declaration of succession now gets both regional rules. In Flanders it is four months from a death in Belgium, five in another country of the European Economic Area and six outside it (Vlaamse Codex Fiscaliteit, art. 3.3.1.0.5). In Brussels and Wallonia it is four months, five elsewhere in Europe and six outside Europe (Wetboek der successierechten, art. 40).
- Fisconet code pages: an article reference that names another tax code is no longer linked to this code's article of that number. On the WIB 92 pages, "artikel 4, KB/WIB 92" and "article 179, AR/CIR 92" stay text; on the KB/WIB 92 pages, "art. 202, WIB 1992" and "artikel 13, WIB 92" do. A reference naming the page's own code keeps its link. Measured on every numbered provision, the rows the pages link: 36 such links in Dutch and French on both codes and their 2027 editions, no link added and no visible text changed.
- Chatbot, the right to erasure: when a controller has made the data public and must erase them, the answer now says that Article 17(2) GDPR has it inform the other controllers processing those data, not processors.

## [1.1.83] - 2026-11-20

### Fixed

- Law pages, dated links (?as_of=): the Classic page and the plain-text response show today's text, and now say so with the requested day. Where the archive serves the law they link the dated reader on the standard site; elsewhere they say that the wording of that day is not verified. The Classic notice stays in view while scrolling, so a link to an article sees it too. From a dated page, the NL/FR comparison says that it shows the current texts, and its Back link returns to the date. The German site's language links keep the date and the chosen versions, as the NL/FR switch already did.
- Judgment pages: the Samenvatting shows only a summary the source supplies, in full and naming its source, whose link is in the External links card. A bare title ("Arrest nr 72.930 van 2 april 1998") or Juportal's "not yet available" placeholder is no longer shown as a summary. A source title that carries subject wording is kept and labelled as the source's title. The judgment stays under Volledige tekst.
- Case-law excerpts keep a judgment's outcome when its operative part is headed "Dictum", as recent Cassation judgments are. Measured on 200 such judgments on production: the outcome reached the excerpt in 188 of 189 cases, against 29 before.
- Case-law excerpts of OCR texts with a few words per line no longer shrink to a few dozen characters around a match. A matching window grows to about 600 characters when the budget allows, and a judgment that matches no question term keeps its opening, where a reported judgment's headnote stands. Measured on 184 judgments from ten courts (477 questions): every passage stayed literal and within budget, the literal context rose from 847 to 1,389 characters on average (429 to 990 on OCR texts with short lines), and the closing lines were kept in 142 runs against 125.
- Case-law excerpts put the court's own reasoning before the parties' arguments. The deciding court's name in a question ("Wat zegt het Grondwettelijk Hof over discriminatie?") no longer counts as a match, a verb of saying such as "zegt" no longer counts as a subject word, and on an equal match the court's reasoning comes first, then the passage that uses the matched words most often. Measured on 304 judgments (976 questions): Constitutional Court excerpts reached the Court's reasoning in 144 of 278 runs against 81, with 37% less text from before the reasoning, where the parties' arguments stand, and kept the outcome in 297 of 318 runs against 293. Cassation and the other courts kept their outcome as often as before, and every passage stayed literal and within budget.
- Chatbot, Raad voor Vergunningsbetwistingen: Article 105 of the Omgevingsvergunningsdecreet is retrieved for questions about the council. A fact note keeps the objection requirement out of the answer, because the Constitutional Court annulled it (GwH 46/2019 of 14 March 2019). The exhaustion of the organised administrative appeal and the 45-day time limit still apply.
- Chatbot, ending a home lease: when the three regions' termination articles are among the sources, an instruction beside them gives the tenant's notice in all three regions. It is three months, with compensation of three, two or one month's rent in the first three years, and one month without compensation after a landlord's notice (Flanders art. 20, Brussels art. 237, Wallonia art. 55). When the Walloon student-lease article is a source, its route is given in full: two months' notice and three months' rent, no notice after 15 March, and the cases without compensation, one of which lifts the 15 March limit (art. 81).
- Fisconet code pages: an article reference that names another act's article is no longer linked to the code's own article of that number. The applicability note of WIB 92 art. 131 reads "(art. 2, 1°, en 4, 1ste lid, W 15.07.2026 - B.S. 29.07.2026; Numac: 2026005724)", and its "art. 2" led to article 2 of WIB 92. A reference inside such a source note, before a dated act ("W 15.07.2026", "KB 10.04.1992"), or before the name of another act (a law, decree, ordinance, directive, regulation or treaty, the Constitution, or the Civil, Judicial or Criminal Code) now stays text, and the note's NUMAC link still opens the act. Measured on all 10,707 provision texts of the Fisconet pages: 19,279 of 65,703 article links pointed at another act and are now text, 46,424 remain, and no visible text changed.
- Fisconet code pages: 12,423 links to fisconet.direct and fisconet.compare, the addresses Fisconet uses for its other documents, led nowhere because neither host exists. They are now plain text, and the 11,673 other links are unchanged.
- Chatbot source cards stay on the question's topic. A question about contesting a traffic fine keeps its legislation cards to road traffic law, so articles on contesting paternity no longer appear. A question about the Raad voor Vergunningsbetwistingen shows only case law that names the council, so Council of State rulings from 1998, before the council existed, no longer appear.
- Chatbot source cards: a Fisconet provision stored under a page identifier instead of an article number is labelled with its own stored title, for example "W.Btw, art. 58sexies. Bijzondere regeling voor de aangifte en betaling van de btw bij invoer", instead of "Artikel doc:w-btw-art-58sexies-...". Its link and anchor are unchanged.
- Chatbot, recidivism under the new Criminal Code (Book I, art. 60): a fact note gives the article as in force since 1 September 2026 and says that Justel's note, which records the whole article as annulled, goes further than the judgment. Judgment 14/2026 of 29 January 2026 annulled only the second subparagraph and upheld the first (B.56). The law of 16 March 2026 (art. 19) amended the first subparagraph and put a new second one in place of the annulled one, adding a minimum fine of 2,080,000 euro for legal persons. Article 60 and article 19 of that law are retrieved for recidivism questions in four languages; traffic recidivism keeps its own rules.
- Chatbot, receiving a state secret (new Criminal Code, Book II, art. 586): the consolidated text still prints the wording the Constitutional Court annulled in judgment 14/2026. A fact note gives the article that the law of 16 March 2026 (art. 110) put in its place, in force since 1 September 2026: receiving a state secret without authority is punishable only with the intent to harm the essential interests of Belgium or of a State linked to Belgium by an international agreement on common defence. Article 586 and article 110 of that law are retrieved for questions about state secrets in four languages.

### Added

- Judgment pages: a copyable reference on every interface. On the Dutch interface it takes the form of the Verwijzingen en Afkortingen guide (RS1 and its list of court abbreviations) where the record allows it, for example "RvS 2 april 1998, 72.930, ECLI:BE:RVSCE:1998:ARR.72.930." and "Cass. 16 februari 2011, ECLI:BE:CASS:2011:ARR.20110216.7.". Otherwise, and on the French, German and English interfaces, a plain Referentie, Référence, Fundstelle or Citation gives the court, the date, the number where the ECLI carries one, and the ECLI, for example "Conseil d'État, 2 avril 1998, n° 72.930, ECLI:BE:RVSCE:1998:ARR.72.930". A court is named only where an official text names it so in that language: the Council of State has no official English name, so the English citation starts with the date. An opinion or a conclusion gives its date and ECLI, and a date the ECLI contradicts leaves the ECLI alone. The reference is one button with its copy icon. Clicking it, or Enter or Space, copies exactly the text shown, and a live region announces the copy. If the clipboard refuses, the reference is left selected for a manual copy.
- Article-history pilot (local only, never in production): on a page showing a date, the chat widget sends the reader's date, language and article, region included. A Dutch or French question that names a covered article and one or two days is then answered from the date resolver of the law reader's archive view (1.1.81). Each day gets the exact wording, its period as Justel's listing gives it, the amending act and its publication date apart from the commencement date, and the dated Justel page. When the act was published after the day its text applies from, the answer says so: the change had retroactive effect and was not yet published on that day. A day the archive leaves open is said to be unverified, with the official archive page. An undated question never reaches the archive.

## [1.1.82] - 2026-11-20

### Fixed

- Laws in force: when the official consolidation still files a newer version of an article as future law after its commencement date has passed, the chatbot now answers with that version and says since when it applies, instead of quoting the text it replaced. Of 3,102 such versions in the corpus, this concerns 652 that replace an older text and 360 that are new articles; a version that is not newer than the article as consolidated is left aside. An article that was inserted but never brought into force is marked as such and is no longer given as the current rule.
- Admin dashboard: Pro access is shown apart from confirmed recurring subscriptions. Monthly revenue now counts only subscriptions a payment provider holds and that are paid through a future date; manual grants and rows without a provider subscription are shown as unverified, and paid-through cancellations and expired rows separately.
- Parliamentary sources: a Chamber document card stored with an outdated link, which opened a "dossier not found" page, now opens the document's official PDF, or the dossier page when no matching PDF is known.
- Tax: questions on the corporate tax rate and a small company's reduced rate get Article 215 of the income tax code, with the director-remuneration condition and its exception.
- Answers: a citation the model wrote with a space after the opening parenthesis, such as "[judgment]( /jurisprudence/...)", appeared on the page as raw Markdown; it is now closed into a normal link and checked like any other, or reduced to its label when the case was not retrieved.
- Chatbot: the research-depth Info now says, right after the selected depth, that a stronger model or more thinking time can give a better answer to a complex question but the answer can still be wrong or incomplete, and that case law and parliamentary sources can support an answer better but make it less accurate when they fit the question poorly; the credit and citation details stay concise and the explanation of the tick heights comes last. In four languages, on the full chatbot and the homepage chatbot. On a 320-pixel phone the guidance is in view as soon as the Info opens.
- Tax: questions on crypto or on the capital gains tax get the 2026 regime for capital gains on financial assets: the 10% rate, the yearly exemption (for income 2026, assessment year 2027: EUR 10,000 per person, with the carry-forward), the value on 31 December 2025 for assets bought earlier, the duty to declare crypto gains, and the 33% rate for speculation outside normal private management.
- Tax: questions on rental income now separate what a landlord enters on the return (the non-indexed cadastral income, and for professional use also the gross rent) from the amount that is taxed (the indexed cadastral income plus 40%, or for professional use the higher of the net rent and that amount), with the coefficients for income 2025 and 2026. French questions on "revenus locatifs" now reach the rental income articles too.
- Pensions: a question on contesting a pension decision now gets the three-month period of Article 23 of the Charter of the socially insured, counted from the notification, beside the one month that Article 66 of Royal Decree no. 50 still prints, and is told that the shorter period does not apply.
- Consumer law: an answer on the withdrawal period now counts the 14 days from the day after the delivery or the conclusion of the contract, with an example date; questions on Black Friday, sales and announced price reductions get Article VI.18 of the Economic Law Code (the previous price is the lowest price of the 30 days before). The withdrawal facts also say that a trader who offered to collect the goods may not hold back the refund until they are returned (Article VI.50, § 3), and that the extra conditions for digital content and for services (prior express consent, the acknowledgment and, for digital content, the trader's confirmation) apply only to a contract that obliges the consumer to pay (Article VI.53, 1° and 13°).
- Traffic fines: a question about contesting a traffic fine, or about a payment order for a traffic offence, now gets the three stages: immediate collection (Article 65 of the Road Traffic Act), the prosecutor's settlement (Article 216bis of the Code of Criminal Procedure) and the payment order (Article 65/1: 30 days from receipt to pay or to appeal to the police court, receipt being presumed on the tenth working day after the date of the order). Article 65ter, which has no date of entry into force, is never given as the rule. Parking, municipal (GAS) and GDPR fines are left out.
- Procedure: a party asking whether they can object to a witness being heard gets the court's power to admit witness evidence of a precise, relevant fact, and a summoned witness gets the duty to appear and testify, the fine and the lawful excuses, in a civil case and before the investigating judge, kept apart.
- Health care: questions on the maximumfactuur get the RIZIV amounts per year (2024 to 2026: the income bands, the social maximumfactuur, the ceiling for a child under 19 and the reduction for the chronically ill), with the statutory 450 and 100 euro named as base amounts and the income of the second year before; a question on the school maximumfactuur is left out.
- Employment: questions on collective dismissal and the Renault procedure now get Articles 62 and 66 to 69 of the act of 13 February 1998, so a reference to "article 67" in the contest procedure (the registered letter within 30 days) is no longer linked to the Employment Contracts Act.
- Notice periods: every overview now states that the 52-week cap of Article 37/2, § 1/1 applies to every contract whose performance begins from 1 June 2026, including in August 2026 or later, and that the date of 1 August 2026 concerns only the periods below six months of seniority.

## [1.1.81] - 2026-11-20

### Added

- Judicial Code Part I: article history on the law page, in Dutch and French. An article's Versions link opens its earlier wordings in place, each with its period and the archived Justel page that shows it. Archief op datum shows the whole law as Justel's archived editions give it on a chosen day. Composed views, missing editions and disputed effective dates (Walloon article 42) are labelled as such. The dataset holds Justel's archived editions 001 to 030 and the current page, of which 25 are complete pages in each language. It is versioned with the code, and no other law or text gets history: not Judicial Code Part II, not any other law, not the German text.

### Fixed

- Dated law links: a link that opens a law for a given day (`?as_of=`) that WetWijzer cannot show as of that day now says so above the law. It names the day, says that the text shown is the current consolidated text, and links the official Justel text. A deep-linked article gets the same note at its own top, outside the text its copy menu copies. The address stays undated for search engines.
- Article history: every archived Justel page is looked up for the article's own law and language, also where another law has an edition with the same number.

## [1.1.80] - 2026-11-20

### Changed
- Header: every language link shows its site's domain beside its code, for the current site too, in the desktop bar and in the mobile menu: NL (wetwijzer.be), FR (lisloi.be), DE (gesetzguide.be) and EN/INT (lexlibera.be). On narrower screens the links wrap instead of hiding the domains.

### Fixed
- Notice periods: for a contract that began before 2014 the chatbot is no longer given the period of the current law for the whole seniority, which an answer still put first. It gets the rule of the two parts with the second part, and the employee's own notice, which since October 2023 follows the current law alone.
- Guaranteed pay during illness: the answer starts with each category's own rules, with the totals from day 8 to 14 of 85.88% for workers and 86.93% for employees hired for less than three months, and explains what the sickness fund and the employer pay from day 15. A question about pay in the first month of illness gets these facts too, the articles for each category are always among the sources, and the other cards come from the employment contracts law, collective agreements and the sickness insurance.
- Inheritance: a question about refusing an inheritance gets the Civil Code articles on renouncing it (a declaration before a notary, entered in the central inheritance register), on the time to decide (three months for the inventory and forty days to deliberate), on its effect and on where the share goes. Civil inheritance and gift questions without tax wording no longer show the Special Financing Act, which only concerns the regions' tax powers.
- Medical treatment: a question about refusing a treatment or withdrawing consent gets the patient rights act's articles on that right and on a refusal in an advance directive, even when it does not say "patient".
- Image rights: a question about the use of a person's photo or about the right to one's image gets the portrait right of the Code of Economic Law, and its other sources stay within copyright, data protection and private life instead of unrelated decrees that mention an image.
- Admin: the Set credits and Change tier buttons on a user's page submit their form again. Their confirmation was attached to the button in a way that left it without a form, so a click did nothing. Set credits now takes a whole number from 0 to 10,000: a higher or malformed value is refused with a message and the balance stays as it was, instead of being clamped.
- VAT: questions on the rate for medicines, mains water and electricity get their own rubric of the rate schedule, and each schedule rubric now tells the chatbot its table's rate (6, 12 or 0 percent) from the decree's first article. German VAT questions ("Umsatzsteuer") get the schedule rubrics too.

## [1.1.79] - 2026-11-20

### Fixed
- Notice periods: when a question gives the start date of the contract, the notice period is calculated from it, so a contract begun on 31 December 2013 gets the two-part calculation and one begun on 1 January 2014 does not. A seniority alone that cannot tell on which side of 1 January 2014 the contract began now gives both conditions and asks for the start date, and a stated date of a past dismissal replaces today. For a contract begun before 2014 the answer now opens with the two-part rule and gives no total while the first part is unknown, instead of opening with a single figure. A question without a seniority, such as a request for the table of notice periods, now carries the periods that still apply to contracts begun before 1 August 2026 and the two-part rule. Below six months' seniority, a start date or an earlier dismissal decides whether the periods from before 1 August 2026 apply.
- Leefloon: each set of amounts is shown with its period and its circular, and the newest as the last confirmed amounts, so a later indexation cannot make an older amount look current.
- Training clause: at a value exactly equal to twice the average minimum monthly income, the chatbot names the difference between the law ("gelijk aan") and the FOD guidance ("hoger dan").
- Guaranteed pay during illness: workers, employees, and employees hired for less than three months each get their own days, percentages and shares (85,88% or 86,93% from day 8, the sickness fund from day 15).
- Sources: an annual-leave question gets the rules for workers and for employees, a palliative-leave question the article on its duration (one month, renewable twice), a question about how often to file the VAT return Royal Decree no. 1, art. 17, and a question about the deadline of the personal income-tax return WIB 92 art. 308 beside its exceptions in art. 308/1.

## [1.1.78] - 2026-11-20

### Fixed
- Notice periods: the chatbot again calculates the notice period for the seniority a question states. The law of 3 June 2026 changed the periods below six months' seniority from 1 August 2026. Since the corpus took in that text on 16 October 2026, the calculation compared it with the earlier periods and stayed silent, and answers worked the period out themselves (for example 21 weeks instead of 24 for a dismissal by the employer after seven years). The calculation now follows the current text in Dutch and French. It gives the earlier periods for contracts begun before 1 August 2026 while those can still be below six months' seniority. When the seniority reaches back before 1 January 2014, it states that a dismissal by the employer adds two parts (the rules of 31 December 2013 for the seniority up to then, and the current scale from 2014) instead of presenting one figure as the total.
- Leefloon: the chatbot gives the amounts that apply from 1 September 2026 (€911,56, €1.367,34 and €1.847,89 per month for the three categories), and the amounts of 1 March 2026 for the months before, instead of presenting the March amounts as current. Category 3 covers a single parent with an unmarried minor child.
- Training clause: the chatbot reads the training condition of a training clause as an "or": at least 80 hours or a value of twice the average minimum monthly income (€4.467,22 since 1 July 2026) is enough, where an answer had required both. It also gives the annual pay the clause requires in 2026 (more than €44.447).

## [1.1.77] - 2026-11-20

### Fixed
- Sample questions: the chatbot sidebar, the category filter and the home page's question pills now load the current sample catalogue. The catalogue file was fetched from a fixed address that browsers keep for a year, so a reader who had opened the chatbot before still saw the old questions and subjects, including after 1.1.76 moved 155 of them. The pages now fetch the catalogue from an address that changes whenever its content changes. When the catalogue changes while a reader moves between pages, a slower answer for the previous catalogue no longer replaces the current one in the sidebar.

## [1.1.76] - 2026-11-19

### Fixed
- Sample questions: 155 questions filed under the wrong subject now sit under their own, and the sidebar, the category filter and the search follow. They include the immigration, criminal, consumer, company and education questions that a bulk addition in January 2026 had put under general tax; for example, "Welke soorten visa bestaan er voor België?" is now under immigration law. They also include inheritance questions that sat under family law, social security questions under employment law, and GDPR questions under consumer law.
- Sample questions: "Kan ik getuigen weigeren?" could mean refusing to testify or objecting to a witness. It now asks the latter, as its French, German and English versions already did: "Kan ik als partij bezwaar maken tegen het horen van een getuige?". The witness's own duty to testify is a new question. The French, German and English versions of "Welke soorten visa bestaan er voor België?" now ask the same question as the Dutch one.
- Chatbot: a tax citation that names a numbered royal decree ("KB nr. 20", "K.B. 20", "AR n° 20") now verifies only on a link to the decree with that number, no longer on a link to the royal decree implementing WIB 92. A date in a label ("KB 20 juli 1970", "KB 20.07.1970") is not read as a decree number.

## [1.1.75] - 2026-11-19

### Fixed
- Chatbot: a tax answer that names the code it cites, for example "Art. 131 WIB 92", is no longer withheld. Such a citation lost its link because "WIB" pointed to the code's empty Justel page instead of the Fisconet text the link opens, and the guard then rejected the bare article number. This is a cause found for the thirteen general tax sample questions that ended without an answer, among them "Hoeveel bedraagt de belastingvrije som?" and "Roerende voorheffing dividenden?". Their answers were not read, so it is not established that each carried such a label. A label that names another instrument still loses its link: the code on a link to its royal decree, a royal decree on a link to the code, or VAT royal decree nr. 20 on a link to nr. 1.
- Chatbot: when an answer cites an article of a tax code (WIB 92, the VAT code or their royal decrees) that the search had not returned, that article is now looked up in the code, in each region the code holds it for, and the answer is regenerated with it, as was already done for the other laws.
- Chatbot: questions that name their tax in a compound word ("bedrijfsvoorheffing", "speculatiebelasting", "investeringsaftrek", "effectentaks"), or ask about taxable ("belastbaar") income, the sale duty or the "klein beschrijf", now search the tax codes. 21 Dutch sample questions did not.

## [1.1.74] - 2026-11-19

### Fixed
- Mobile: Search ("Zoeken") in the bottom navigation now opens the home page's search field and puts the cursor in it. From another page it opens the home page at the search field and focuses it once the page has arrived. On the home page itself, also when scrolled down, it brings the field into view and focuses it without reloading the page, keeps any text already typed, and closes an open chat panel first. Until now it opened the home page at the top, at the chat, with nothing focused. Without scripts the link still opens the search page, and its fragment (`#homepage-search-card`) names the search field.

## [1.1.73] - 2026-11-19

### Fixed
- Chatbot: a question about the inviolability of the home (for example "Onschendbaarheid woning?") keeps Article 15 of the Constitution, and its other sources are now limited to the Constitution, human rights treaties, criminal law and procedure with the search laws, the police function, and diplomatic and consular law. Rules that only let an inspector or an estate agent enter "subject to the inviolability of the home", such as those on swine brucellosis, African swine fever and the estate agents' code of ethics, no longer appear. A question that names such a rule keeps it.
- Chatbot: "hoelang" and the "lang" of "hoe lang" are no longer search terms, so "Adoptieverlof hoelang?" no longer shows a gas-network article that says how long its records are kept.
- Law pages: the French text of a Brussels regional version of an article (for example Art. 11 "Région de Bruxelles-Capitale" of the traffic code) now has its own anchor (`#art-11-region_bruxelles_capitale`), so its contents link and the chatbot's source card open the Brussels text instead of the general article.

### Changed
- Chatbot: the sample question categories are written in sentence case in every language ("Intellectuele eigendom", "Fiscaal recht"), and the sidebar and the category filter list them in one order: general first, miscellaneous last, the others alphabetically by their name in the reader's language. The employment and tax subgroups stay together under their main category, whose own questions are labelled "algemeen".

## [1.1.72] - 2026-11-19

### Fixed
- Chatbot: a road speed limit question (for example "Wat is de maximumsnelheid in de bebouwde kom?") now always gets the traffic code's speed article in its Flemish, Walloon and Brussels versions, each labelled with its region, even when search ranks one of the near-identical texts lower. In 1.1.70 the Brussels version could be missing, and the answer then gave Brussels the 50 km/h of the other regions instead of its 30 km/h. A question that names one region gets that region's version.
- Chatbot: a source that is a regional version of an article now links to that version on the law page (for example `#art-11-brussels_hoofdstedelijk_gewest`) in the answer and on its source card, instead of to the general article.
- Site: an address is now banned for an hour only after 50 requests within five minutes that a rate limit actually refused, as intended. Until now every request counted, so about 100 ordinary requests in five minutes, for example a reader asking a few chatbot questions, led to the hour-long "Tijdelijk geblokkeerd" page. The rate limits themselves are unchanged, and search engines stay exempt from the ban.

## [1.1.71] - 2026-11-19

### Fixed
- Chatbot: a question about the inviolability of the home (for example "Onschendbaarheid woning?", in Dutch, French, German or English) now gets Article 15 of the Constitution. A question about parliamentary immunity or a police house search does not.
- Chatbot: a question about the right to or freedom of education (for example "Hoe is het recht op onderwijs gewaarborgd in België?") now gets Article 24 of the Constitution. Its other sources are limited to the Constitution, education law and human rights treaties, so the lawyers' code of ethics, whose continuing-education rules mention teaching in higher education, no longer appears. A question about lawyers' continuing education keeps that code.
- Both articles stay out of a question about a foreign constitution or legal system.

## [1.1.70] - 2026-11-19

### Fixed
- Chatbot: a question about a road speed limit (for example "Wat is de maximumsnelheid in de bebouwde kom?", in Dutch, French, German or English) is now treated as a regional subject. The answer covers Flanders, Brussels and Wallonia separately, as the traffic code's speed article differs per region (30 km/h in the Brussels bebouwde kom, 50 km/h in Flanders and Wallonia), instead of leading with one national figure. Its other sources stay road-traffic law, so the Brussels-Scheldt canal's shipping regulation no longer appears. Questions about the speed of vessels, trains, aircraft or an internet connection are not affected.

## [1.1.69] - 2026-11-19

### Fixed
- Chatbot: a question about a personal data breach (for example "Wanneer en hoe moet ik een datalek melden?", in Dutch, French, German or English) now gets GDPR Article 33 (notifying the supervisory authority, within 72 hours where feasible) and Article 34 (informing the people concerned) from the official EUR-Lex text, and its other sources are limited to data-protection rules. The Belgian rules for police and criminal-justice authorities (Title 2 of the Act of 30 July 2018) no longer stand in for the GDPR, and unrelated sources such as animal by-products rules are dropped. A question about a breach by the police or the intelligence services keeps the Belgian rules.

## [1.1.68] - 2026-11-19

### Changed
- Chatbot: the application's own monthly spend ceiling for each AI provider (Azure OpenAI, Mistral and AWS Bedrock) is EUR 50, down from EUR 100, so EUR 150 in total; the admin Finance page shows the new ceilings. The monthly spend record and the daily per-model limit are unchanged.

## [1.1.67] - 2026-11-19

### Fixed
- Chatbot: a question about challenging a GAS fine (municipal administrative sanction) now gets the GAS law's appeal to the police court, the enforceability rule, the decision after the defence and the notice, and its other sources are limited to GAS material: no posting-of-workers, social-penalty, energy-regulator or regional tourism fines.
- Chatbot: a question about using a photo or image taken from the internet now gets the copyright articles of the Code of Economic Law (the author's exclusive right, quotation and the other exceptions), and its other sources are limited to copyright and portrait rights.
- Chatbot: a question about cameras at work now gets CAO nr. 68 on camera surveillance at the workplace (conditions, purposes, proportionality, informing the works council) beside the Camera Act, without the Maritime Code, civil security or other specialist camera rules.
- Chatbot: in those three cases a source the question names by its title, such as the Social Penal Code or the Maritime Code, stays.

## [1.1.66] - 2026-11-18

### Fixed
- Chatbot: an abstract question about equality and the Constitution no longer shows the Brussels ordinance on paid educational leave and the Experience Fund as a source, unless the question is about leave or training.
- Chatbot: the sources an equality question may keep are grouped by kind (circulars and taxes, exams and admission tests, international organisations, educational leave), and a question about one kind keeps only that kind: a question about an inspector's admission test no longer brings back a tax circular or the IRENA statute.
- Chatbot: a German question about "die Verfassung" (unqualified, as on the Grondwet and Constitution side) now adds the Belgian Constitution as a core law. "Verfassung" in the sense of someone's condition ("in guter Verfassung", "seine gesundheitliche Verfassung") does not, and neither does a foreign one.
- Chatbot: "die Verfassung der Vereinigten Staaten", "von Frankreich", "Deutschlands" and the other German country names are read as a foreign constitution, also for an article number.

## [1.1.65] - 2026-11-18

### Fixed
- Chatbot: an abstract question about equality and the Constitution no longer shows an entrance-test regulation whose Dutch title says "proef" (such as the French Community's inspector admission test) or the statute of an international organisation (such as IRENA's, on the sovereign equality of its members) as a source, unless the question is about an exam, an admission test, an international organisation or a treaty.
- Chatbot: a question about inheritance without a will no longer shows the Special Financing Act (1989021010) as a source when search retrieves it, the same rule that already applied to its pins, unless the question is about tax, cost, a declaration, an exemption or a region.
- Chatbot: a Belgian person in the question ("Ik ben Belg", "als Belgische onderdaan", "je suis belge") no longer stops a question asked under a foreign law or constitution from being read as foreign; only Belgian law or a Belgian court does.
- Chatbot: "naar het recht van de Verenigde Staten" is read as a foreign legal system.
- Chatbot: a question comparing the Grundgesetz with an unqualified Grondwet or Verfassung keeps the Belgian Constitution.

## [1.1.64] - 2026-11-18

### Fixed
- Chatbot: a question asked under a foreign constitution or a foreign legal system ("de Franse grondwet", "la Constitution américaine", "the US constitution", "das Grundgesetz", "naar Frans recht", "en droit allemand", "under Dutch law", "nach deutschem Erbrecht") no longer gets the Belgian Constitution's Arts. 10 and 11 or Civil Code Book 4's rules on who inherits pinned, and the Belgian Constitution and succession law are no longer added as core laws for it. A question that also names Belgium or Belgian law keeps them. Where someone lived or died changes nothing here.
- Chatbot: an article number of "de grondwet van de Verenigde Staten" is read as another instrument's, not as an article of the Belgian Constitution.
- Chatbot: a question about inheritance without a will gets no regional tax-competence provisions (Special Financing Act Arts. 3 and 4) unless it is about tax, cost, a declaration, an exemption or a region.
- Chatbot: an abstract question about equality and the Constitution no longer shows an administrative circular or an exam regulation as a source, unless the question is about a tax, a circular, an exam or a recruitment.
- Chatbot: a question about the right of withdrawal no longer shows the timeshare and long-term holiday products act (2011011331) as a source, unless the question is about timeshare or holiday products, names the act's NUMAC, or the row was pinned.

## [1.1.63] - 2026-11-18

### Fixed
- Chatbot: a question about the equality principle and the Constitution retrieves Constitution Arts. 10 and 11 as pinned sources again when the words are compounds ("Gelijkheidsbeginsel grondwet?", "Gleichheitsgrundsatz", "Non-discriminatiebeginsel"); the built-in example question was answered from a municipal tax circular.
- Chatbot: a question about an estate without a will (Dutch, French, English and German) retrieves Civil Code Book 4 Arts. 4.10, 4.16 and 4.17, the rules on who inherits, instead of only the certificate of inheritance. Questions about making or contesting a will do not.
- Chatbot: a question about the right of withdrawal no longer shows the Flemish wijk-werken decree's Art. 42 (withdrawal from a purchase of wijk-werk cheques) as a source, unless the question is about wijk-werken, names that decree's NUMAC, or the row was pinned.

## [1.1.62] - 2026-11-18

### Changed
- Signing out ends the session on this device only; the account's other devices stay signed in. Each sign-in now gets its own server-side session (a `user_sessions` row holding only the SHA-256 digest of the cookie's random token), and signing out deletes that row, so a copy of the signed-out cookie is refused too. Each session is bound to the account's session token, so a password or second-factor change, suspension, deactivation and erasure still end every device at once. The new cookie no longer contains the account token. Cookies issued before this release keep working until their own expiry (at most thirty days); signing out with one still ends every device. Expired sessions are deleted by the daily scrub, account erasure deletes the rest, and the account export lists them without digests.
- ww-faiss-pin holds all six served search indexes: the budget is 7168 MB (was 4096) and LimitMEMLOCK 7600M, so the parliamentary index (2.8 GB) is no longer left to the five-minute keep-warm, where it was found cold on almost every pass. The 4096 MB floor and the release below 2048 MB are unchanged.

### Added
- Account page, Security: "Sign out everywhere" (`DELETE /logout/everywhere`, after a confirmation). It clears the account's session token and deletes its device sessions, so every device is signed out, this one and pre-1.1.62 cookies included, and records a `logout_everywhere` entry in the activity log. Texts in Dutch, French, German and English.
- Database: accounts migration `20261118100000_create_user_sessions`. On production it is applied by hand as `wetwijzer_migrate`, with its grants to `wetwijzer_app`, before the deploy (`docs/ops/analytics-migrations.md`); the deploy hook refuses a push with a pending migration.

## [1.1.61] - 2026-11-18

### Changed
- Signing in no longer signs the account out on its other devices. A sign-in keeps the account's current session token instead of replacing it. A copied cookie stays bounded by the signed expiry Rails checks on the server (two hours, or thirty days with "remember me"). A password or second-factor change, signing out, suspension, deactivation and erasure still end the session on every device.

### Added
- Operations: `ww-faiss-pin.service` holds the served FAISS indexes in memory, smallest first within a 4 GB budget, and releases them all when available memory drops below 2 GB. It is installed by `scripts/ops/install_ops_timers.sh` as root. The parliamentary index (2.8 GB) stays on the five-minute keep-warm, which no longer charges the pinned files against its memory budget (it reads their list from `/run/wetwijzer-faiss-pin/pinned`).
- CI: the security stage runs each scanner on its own. npm advisories go through `scripts/ops/npm_audit_gate.mjs`, which excepts a listed advisory only while no fixed release exists. The one exception is GHSA-fc5q-39xc-vjpf (picomatch, build time only).

## [1.1.60] - 2026-11-17

### Changed
- In Admin > Chatbot analytics > Quality, the Retries cell of Ratings by configuration (retry share and mean provider calls) is shown from five answers with a recorded call count; below that it reads "<5" with the sample size. The row and its rating figures stay visible from one rating.

## [1.1.59] - 2026-11-17

### Changed
- Admin > Chatbot analytics keeps a five-answer display floor for the operational figures (provider calls, guard verdicts and retries in the regeneration and guard panels); ratings still show from one recorded rating onward.

## [1.1.58] - 2026-11-17

### Changed
- Admin > Chatbot analytics shows the rating count, mean and star breakdown from one recorded rating onward, also per model, language and configuration; only a period without ratings shows the empty state. All traffic is counted, as before.

## [1.1.57] - 2026-11-17

### Fixed
- A question about an article of the first Protocol to the European Convention on Human Rights ("Geef artikel 1 van het Eerste Protocol bij het EVRM") is answered from that article alone, without unrelated laws in the source list.
- A later protocol named by its ordinal or number ("het tweede aanvullend protocol", "le deuxième protocole additionnel", "protocol 12") is never taken for the first Protocol.
- A protocol named in one sentence no longer takes the Convention named in the next ("Geef artikel 1 van het Eerste Protocol. Geef ook EVRM artikel 10.").
- The full stops in an article reference ("Art. 10", "VI.49") no longer split a question into two, so a plain lookup stays a plain lookup.
- A French question about a cross-reference ("renvoi à l'article 5") in a text published online no longer brings up the consumer withdrawal article.

### Changed
- The Praxis strip beside the Dutch chatbot is headed "In ontwikkeling" (was "Praxis - In ontwikkeling").

## [1.1.56] - 2026-11-17

### Fixed
- Answers no longer say "de zoekopdracht was onvolledig" because of the EU lane when nothing failed. A general EU topic (consumer withdrawal, equal treatment, ...) was still sent to the EU acquisition helper, which has discovered no topics since 2026-10-14; it asked EUR-Lex nothing, reported the topic as unavailable, and the next identical question showed the incomplete-search notice. Only a named act or case is sent now, as the helper can act on it.
- An article of the first Protocol to the European Convention on Human Rights ("artikel 1 van het Eerste Protocol bij het EVRM", "le Protocole additionnel à la CEDH", "Protocol No. 1 to the ECHR") is looked up in that Protocol's consolidated text (NUMAC 1952032050), never in the Convention; another numbered protocol is still not guessed.
- A protocol named before a Convention reference no longer takes the later Convention reference with it ("artikel 1 van het Eerste Protocol bij het EVRM en artikel 10 van het EVRM").
- A question that asks something besides the requested article ("Vat artikel 10 van de Grondwet samen. Is dat discriminatie?") keeps its other sources.

### Changed
- The citation check's log line admits only the exact identifier shapes the check itself produces.

## [1.1.55] - 2026-11-17

### Fixed
- The chatbot states when a period starts as the law writes it. When a provision lets a period expire a number of days after a given day ("verstrijkt 14 dagen na de dag waarop de consument de goederen fysiek in bezit neemt", "expire 14 jours après le jour où"), the answer says the period starts the day after, not "on the day" or "from the day". In a paired check on the consumer withdrawal question, 5 of 5 answers said so, against 5 of 8 before.
- A French or English question about returning something bought online ("Puis-je le renvoyer parce que j'ai changé d'avis ?", "Can I send them back because I changed my mind?") finds Art. VI.47 of the Code of Economic Law, so the answer can say when the withdrawal period starts.

## [1.1.54] - 2026-11-17

### Fixed
- An article asked for by number is answered from that article alone only when the question is a clearly bounded task on its text (quote it, summarise it, its first sentence, in plain words, a link). A question that also asks to apply it to a situation ("Vat artikel 10 van de Grondwet samen en pas het toe op ongelijke pensioenrechten") keeps the other sources it needs.
- An article of a protocol to the European Convention on Human Rights ("artikel 1 van het Eerste Protocol bij het EVRM", "l'article 1 du Protocole n° 12 à la CEDH") is no longer taken for the article of the Convention itself.

### Changed
- The citation check's log line writes only canonical identifiers (an article number, an EU unit or a source id) and counts anything else without writing it.

## [1.1.53] - 2026-11-16

### Fixed
- A question about one article asked for by number ("Zoek de Belgische Grondwet (NUMAC 1994021048), artikel 10. Vat de eerste zin samen") is answered from that article alone once it is found: unrelated hits (other articles of the law, VAT articles, unrelated decrees) no longer reach the answer or its source list, so they cannot be cited wrongly and get the answer withheld. A question that asks for an explanation, a comparison or another instrument's article keeps ordinary retrieval.
- An article of the European Convention on Human Rights asked for by number ("artikel 10 EVRM", "l'article 10 de la CEDH", "Article 8 of the European Convention on Human Rights") is looked up in the Convention's consolidated text (NUMAC 1950110452), so a question comparing Art. 19 of the Constitution with Art. 10 EVRM retrieves and can cite both. Before, the Convention's article was left to ordinary retrieval and was not found.
- The answer for an article the lookup did not find no longer doubles the full stop after a law title that ends with one ("Grondwet..").

### Changed
- When the citation check withholds an answer, the server log names the article references it could not verify (numbers only, at most five), not just their count.

### Security
- Puma 8.0.3 (seven advisories published 2026-11-16 against 8.0.2).

## [1.1.52] - 2026-11-16

### Fixed
- The chatbot looks up an article asked for by number together with its law, a NUMAC or the Constitution ("Zoek de Belgische Grondwet (NUMAC 1994021048), artikel 10", "artikel VI.49 van het Wetboek van economisch recht (NUMAC 2013A11134)"), so the article is retrieved and can be cited. Each article number belongs to the law named with it: "artikel 10 van het EVRM" is not read as the Constitution's, and a foreign constitution ("la Constitution suisse") never as the Belgian one.
- An article the law's consolidated text in WetWijzer does not hold ("artikel 9999 van de Grondwet") gets a plain answer saying it was not found, with a link to the law, instead of a withheld answer with unrelated sources. It does not claim the article does not exist, and a question that asks for more goes the ordinary way.
- The question which articles of the Constitution concern equality and non-discrimination finds Arts. 10 and 11, and a consumer's question how to notify a webshop of a withdrawal finds Art. VI.49 of the Code of Economic Law without the website operator's privacy articles.
- When an answer is withheld after its citations could not be verified, the list of consulted sources keeps the sources that help with the question (for an article asked by number, that article and the other laws the question names) instead of the first five retrieved.
- A question how long one has to contest a decision that names neither the decision nor who took it gets a short question back: which decision, and when and how it was received.
- A quotation inside or under a list item is shown as a quotation in the chat, not with a literal ">", and a numbered list goes on after it.

### Added
- The article history of a law page and an archive by date, built for the Judicial Code part I as a local pilot. It is active only where its database is present, which is not the case in production: the production law pages are unchanged.

## [1.1.51] - 2026-11-14

### Tests
- The parliamentary list checks that the result cards which must show no type are on the list before checking that they show none; until now a missing card passed that check.
- The correction for the Chamber's document 56K0614001 has test cases of its own, so it is proved without 56K0613001's.
- The browser test of the search page's keyboard shortcuts (j, Tab, Enter) waits for the page a source tab opens before pressing j. The tab is a link: it is marked selected at the click, and the new page, which puts the focus back in the search box, can arrive after the shortcut. A full test run failed on that.
- Test files only: the application and its bundle are unchanged.

## [1.1.50] - 2026-11-14

### Fixed
- Parliamentary documents: the Chamber's documents 56K0613001 and 56K0614001, proposals to revise the 1830 decrees nr. 3 and nr. 5, are shown as "Voorstel tot herziening", the document type the Chamber's own record gives them. Since 1.1.47 they showed no type, because their titles do not name the Constitution. This is a correction for those two documents; the title rule, their stored type and their titles are unchanged, and 54K2806001 (the Chamber's type "Voorstel reglement") still shows no type.

## [1.1.49] - 2026-11-13

### Fixed
- Parliamentary documents: a proposal to revise the Chamber's rules whose title has two spaces before "van het" could still take the type for a revision of the Constitution when the title went on to cite it. Repeated spaces no longer change the result.
- Tests: the correction for 56K0019001 is checked against a second document of the same dossier stored with the same bill type, which keeps it.

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
