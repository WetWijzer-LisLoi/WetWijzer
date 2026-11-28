# frozen_string_literal: true

module LegalChatbot
  # Sol 2026-11-27 09:38:22Z (#304 "Hoeveel werkloosheidsuitkering krijg ik na een arbeidsongeval?", live 1.1.115): "the
  # temporary side says only "in beginsel"; it never explains the actual Art. 61 §2 second-paragraph exception for temporary
  # unemployment when certain work is permitted subject to suspension or temporary reduction of the compensation. Please
  # cover that in the rendered answer."
  #
  # Version 2, Sol 2026-11-27 13:27:18Z (live 1.1.116):
  # - "The actual sentence starts "Als u nog tijdelijk of gedeeltelijk arbeidsongeschikt bent". The statute says "tijdelijk
  #   volledig of gedeeltelijk arbeidsongeschikt": temporary qualifies both full and partial incapacity." The wording is
  #   rendered as the statute has it.
  # - "Put the entitlement distinction before the figures." The entitlement paragraph opens the answer.
  # - The guard fired "for ordinary incapacity caused by influenza and for the spouse asking about a fatal accident survivor
  #   annuity". "Please limit this intervention to an applicable entitlement question".
  # - Sol 14:17:31Z and 14:18:08Z (review of the sealed 1.1.117): the wording repair leaves quotations alone.
  # - Sol 14:57:33Z and 15:56:28Z (reviews of e6da9432d and ecca0a4a8): contradictory advice stayed in the answer, and
  #   ever more permissive drafts passed a check of the exception's wording ("Als uw werkgever het toestaat, mag u als
  #   tijdelijk werkloze altijd werken onder voorbehoud van schorsing van uw vergoeding."). "For #304 use the sourced full
  #   eligibility explanation as the answer's own opening and make it the single source for this part, while preserving
  #   genuine quotations and the useful amounts/citations. This avoids treating an ever-growing series of permissive-word
  #   patterns as legal verification."
  #
  # Art. 61, § 2 of the unemployment decree (1991013192), read in full in NL and FR on 2026-11-27: no benefits for a worker
  # temporarily fully or partly unfit for work under the legislation on compensation for occupational accidents, commuting
  # accidents or occupational diseases; that worker can nevertheless have benefits as temporarily unemployed when the
  # insurance scheme that applies allows certain work subject to suspension or temporary reduction of the right to
  # compensation; a worker permanently unfit under that legislation can have benefits, unless art. 62 deems the worker
  # unfit for work. An incapacity covered by the sickness and invalidity insurance is § 1, not § 2.
  #
  # An entitlement question asks for the unemployment benefit after an occupational accident, a commuting accident or an
  # occupational disease, and not about a death or a survivor. Its answer opens with the sourced paragraph (below a
  # leading heading), the single source on eligibility: every sentence of the chatbot's own prose on eligibility under an
  # incapacity, or on work, a permission, a suspension or a reduction as temporarily unemployed, is withheld, whatever its
  # wording, and so is a heading left without content. Blockquotes (the quotations the quote guard verifies), tables,
  # headings, the amounts and the duration rule stay; elsewhere "tijdelijk of gedeeltelijk" incapacity reads "tijdelijk
  # volledig of gedeeltelijk".
  #
  # Version 3 (1.1.118), Sol 2026-11-27 16:52:39Z to 23:00:25Z: the one compensation sentence right after a withheld one
  # goes with it unless it carries a citation link or an official amount; a quotation a retrieved source holds verbatim
  # stays; a guarantee that the compensation stays whole goes wherever it stands (guarantee?); a quotation is never split.
  #
  # Version 4 (1.1.119), Sol 2026-11-27 23:30:17Z and 2026-11-28 01:45:42Z to 02:36:22Z: a sentence that denies full or
  # automatic payment itself in a recognizable form ("niet volledig doorbetaald", "niet automatisch voor 100 %
  # doorbetaald", "Het is niet gegarandeerd dat ...", "... ist nicht garantiert") is no guarantee and stays, also after a
  # withheld claim; any other sentence with a payment phrase goes, so certainty ("no doubt") and a denial of something
  # else ("zolang uw baan niet gegarandeerd is") deny nothing.
  module AccidentUnemploymentException
    VERSION = 4
    HREF = '/laws/1991013192#art-61'
    TEXT = {
      'nl' => "**Eerst: hebt u recht op een uitkering? ([art. 61, § 2](#{HREF}))** Wie tijdelijk volledig of gedeeltelijk " \
              'arbeidsongeschikt is volgens de wetgeving op de arbeidsongevallen, de ongevallen op de weg naar of van het werk ' \
              'of de beroepsziekten, kan geen werkloosheidsuitkering genieten, behalve als tijdelijk werkloze wanneer de ' \
              'toepasselijke verzekeringsregeling toestaat dat bepaalde arbeid wordt verricht onder voorbehoud van schorsing ' \
              'of tijdelijke vermindering van het recht op vergoeding. Wie volgens die wetgeving blijvend arbeidsongeschikt ' \
              'is, kan uitkeringen genieten, behalve wie volgens art. 62 als arbeidsongeschikt wordt beschouwd. Bedragen ' \
              'gelden alleen voor wie recht heeft.',
      'fr' => "**D'abord : avez-vous droit aux allocations ? ([art. 61, § 2](#{HREF}))** Le travailleur en incapacité temporaire " \
              'de travail, totale ou partielle, au sens de la législation relative aux accidents du travail, aux accidents ' \
              'survenus sur le chemin du travail ou aux maladies professionnelles, ne peut bénéficier des allocations, sauf en ' \
              "tant que chômeur temporaire lorsque le régime d'assurance applicable l'autorise à fournir certaines prestations " \
              "de travail sous réserve de suspension ou de réduction temporaire de son droit à l'indemnité. Le travailleur en " \
              "incapacité de travail permanente au sens de cette législation peut bénéficier des allocations, sauf s'il est " \
              "considéré comme inapte au travail conformément à l'article 62. Les montants ne valent que pour qui a droit aux " \
              'allocations.',
      'de' => "**Zuerst: Haben Sie Anspruch auf Leistungen? ([Art. 61 § 2](#{HREF}))** Wer im Sinne der Rechtsvorschriften über " \
              'Arbeitsunfälle, Wegeunfälle oder Berufskrankheiten vorübergehend ganz oder teilweise arbeitsunfähig ist, kann ' \
              'keine Leistungen erhalten, außer als zeitweilig arbeitslose Person, wenn die anwendbare Versicherungsregelung ' \
              'bestimmte Arbeit unter Vorbehalt der Aussetzung oder vorübergehenden Kürzung des Entschädigungsanspruchs ' \
              'erlaubt. Wer im Sinne dieser Rechtsvorschriften dauerhaft arbeitsunfähig ist, kann Leistungen erhalten, außer ' \
              'bei Einstufung als arbeitsunfähig nach Art. 62. Beträge gelten nur bei Anspruch.',
      'en' => "**First: are you entitled to benefits? ([art. 61, § 2](#{HREF}))** A worker who is temporarily fully or partly " \
              'unfit for work under the legislation on occupational accidents, commuting accidents or occupational diseases ' \
              'cannot receive benefits, except as temporarily unemployed when the applicable insurance scheme allows certain ' \
              'work subject to suspension or temporary reduction of the right to compensation. A worker permanently unfit for ' \
              'work under that legislation can receive benefits, unless deemed unfit for work under art. 62. Amounts apply ' \
              'only to those entitled.'
    }.freeze
    # An occupational accident, a commuting accident or an occupational disease: a bare incapacity (an influenza) is § 1
    OCCUPATIONAL = /(?<![[:alnum:]])(?:\p{L}*arbeidsongeval\p{L}*|ongeval\p{L}*\s+op\s+de\s+weg|\p{L}*beroepsziekte\p{L}*|
                    accidents?\s+du\s+travail|accidents?\s+sur\s+le\s+chemin|maladies?\s+professionnelles?|\p{L}*arbeitsunf[äa]ll\p{L}*|
                    wegeunf[äa]ll\p{L}*|berufskrankheit\p{L}*|(?:occupational|industrial|work(?:place)?|commuting)\s+
                    (?:accidents?|injur\p{L}*|diseases?))(?![[:alnum:]])/iux
    # The question asks for the benefit itself: "werkloze" alone is a status ("de echtgenoot van een werkloze ... een rente")
    BENEFIT = /(?<![[:alnum:]])(?:\p{L}*uitkering\p{L}*|werkloosheidsvergoeding\p{L}*|werkloosheidsgeld|stempelgeld|dopgeld|stempelen|
               recht\s+op\s+werkloosheid|allocation\p{L}*|indemnit\p{L}*\s+de\s+ch[ôo]mage|droit\s+aux?\s+(?:ch[ôo]mage|allocations?)|
               arbeitslosengeld\p{L}*|arbeitslosenunterst[üu]tzung|\p{L}*leistung(?:en)?|anspruch|benefits?|allowances?|
               unemployment\s+(?:pay|compensation|insurance)|entitle\p{L}*|dole)(?![[:alnum:]])/iux
    # Eligibility under an incapacity: an incapacity and an entitlement in one sentence (the duration rule of art. 116,
    # § 2 is another point and stays)
    INCAPACITY = /(?<![[:alpha:]])(?:\p{L}*ongeschikt\p{L}*|incapacit[ée]\p{L}*|inaptes?|\p{L}*unf[äa]hig\p{L}*|unfit|incapacity|
                  incapacitated)(?![[:alpha:]])/iux
    ENTITLEMENT = /(?<![[:alpha:]])(?:\p{L}*uitkering\p{L}*|recht\s+op|rechthebbend\p{L}*|genieten|allocations?|droit|b[ée]n[ée]ficier|
                   \p{L}*leistung(?:en)?|anspruch\p{L}*|benefits?|entitled|entitlement|eligib\p{L}*)(?![[:alpha:]])/iux
    DURATION = /(?<![[:alpha:]])(?:duur|verleng\p{L}*|dur[ée]e|prolong\p{L}*|dauer|verl[äa]nger\p{L}*|duration|extend\p{L}*|
                extension)(?![[:alpha:]])/iux
    # The exception: temporary unemployment (as a status or a noun, Sol 15:56:28Z: "Bij tijdelijke werkloosheid mag u
    # werken ...") with work and its permission, or with a suspension or reduction, in one sentence. "Gebrek aan werk"
    # alone, an amount of temporary unemployment, names no permission and stays.
    TEMPORARY_UNEMPLOYMENT = /(?<![[:alpha:]])(?:tijdelijke?\s+werklo\p{L}*|ch[ôo]m(?:age|eurs?)\s+temporaires?|
                              zeitweilige?\p{L}*\s+arbeitslos\p{L}*|temporar(?:y|ily)\s+unemploy\p{L}*)/iux
    WORK = /(?<![[:alpha:]])(?:arbeid|werk|werken|werkt|prestations?\s+de\s+travail|travail|travailler|arbeit|arbeiten|
            work(?![\s-]+(?:accidents?|injur\p{L}*|related|diseases?)))(?![[:alpha:]])/iux
    PERMITTED = /(?<![[:alpha:]])(?:mag|mogen|toe(?:staat|stond|gestaan|laat|gelaten\p{L}*)|toestemming|autoris\p{L}*|perm[ei][st]\p{L}*|
                 erlaub\p{L}*|gestatte\p{L}*|zul[äa]ssig\p{L}*|darf|d[üu]rfen|allow\p{L}*)(?![[:alpha:]])/iux
    SUSPENSION = /(?<![[:alpha:]])(?:schorsing|geschorst|vermindering|verminderd|verminderen|suspension|suspendu\p{L}*|r[ée]duction|
                  r[ée]duit\p{L}*|aussetzung|ausgesetzt|k[üu]rzung|gek[üu]rzt|reduction|reduced|suspended)(?![[:alpha:]])/iux
    # A dependent sentence speaks of the compensation or the benefit; a citation link or an official amount makes it stand
    # on its own (official_amount?)
    COMPENSATION = /(?<![[:alpha:]])(?:\p{L}*vergoeding\p{L}*|\p{L}*uitkering\p{L}*|rente|indemnit[ée]s?|allocations?|
                    \p{L}*entsch[äa]digung\p{L}*|\p{L}*leistung(?:en)?|compensation|benefits?|annuit(?:y|ies))(?![[:alpha:]])/iux
    # Sol 2026-11-27 23:00:25Z (review of 695aa89a2): "Uw arbeidsongevallenvergoeding wordt daarbij altijd voor 100 %
    # doorbetaald ([Art. 61](/laws/1991013192#art-61))." was published. "The actual link gives that guarantee no support.
    # Please remove this identified false assertion regardless of an appended link and keep the correctly scoped Art. 115
    # minimum. This is not a request for general semantic verification of every citation." Art. 61, § 2, second paragraph
    # (read in full again, NL and FR, on 2026-11-27) allows that work only "onder voorbehoud van schorsing of tijdelijke
    # vermindering van zijn recht op vergoeding" ("sous réserve de suspension ou de réduction temporaire de son droit à
    # l'indemnité"). A sentence that says that compensation stays whole (paid on, kept, in full, unreduced, without
    # suspension or reduction) is withheld wherever it stands, whatever link or amount it carries. The compensation of
    # that right, not the unemployment benefit:
    INDEMNITY = /(?<![[:alpha:]])(?:(?!werkloosheids)\p{L}*vergoeding(?:en)?|renten?|unfallrenten?|indemnit[ée]s?|indemnisation|
                 \p{L}*entsch[äa]digung(?:en)?|compensation|annuit(?:y|ies))(?![[:alpha:]])/iux
    # It is paid on, kept or maintained ("onder voorbehoud" is not "behoud"; "keep in mind" keeps nothing)
    KEPT = /(?<![[:alpha:]])(?:doorbeta(?:al|l)\p{L}*|behoud\p{L}*|beh[äa]lt\p{L}*|weiter(?:ge)?zahl\p{L}*|maintenue?s?|conserv\p{L}*|
            continue\p{L}*\s+(?:d['’]|de\s+|[àa]\s+)?(?:[êe]tre\s+)?(?:vers|pay)\p{L}*|continue[sd]?\s+to\s+be\s+paid|
            continued\s+payments?|keeps?(?!\s+in\s+mind)|kept|retain\p{L}*|maintained)(?![[:alpha:]])/iux
    # It is whole: in full, at 100 % (not "voor 100 % arbeidsongeschikt"), unreduced, without suspension or reduction
    WHOLE = /(?<![[:alpha:]])(?:volledig\s+(?:uit|door)?betaald|volledig\s+vergoed|integra(?:al|le)|ongewijzigd\p{L}*|onverminderd\p{L}*|
             ongekort\p{L}*|voor\s+100\s?%(?!\s*\p{L}*(?:ongeschikt|invalid))|
             zonder\s+(?:enige\s+)?(?:vermindering|schorsing|inhouding|korting)|(?:niet|nooit)\s+(?:\p{L}+\s+)?(?:verminderd|geschorst)|
             int[ée]gral\p{L}*|en\s+totalit[ée]|enti[èe]rement\s+(?:vers|pay)\p{L}*|[àa]\s+100\s?%|
             sans\s+(?:aucune\s+)?(?:r[ée]duction|suspension|retenue)|(?:pas|jamais)\s+(?:\p{L}+\s+)?(?:r[ée]duit\p{L}*|suspendu\p{L}*)|
             vollst[äa]ndig\s+(?:aus|weiter)?(?:ge)?zahl\p{L}*|in\s+voller\s+h[öo]he|ungek[üu]rzt\p{L}*|zu\s+100\s?%|
             ohne\s+(?:jede\s+|jegliche\s+)?(?:k[üu]rzung|aussetzung|abzug)|(?:nicht|nie)\s+(?:\p{L}+\s+)?(?:gek[üu]rzt|ausgesetzt)|
             in\s+full|fully\s+paid|at\s+100\s?%|unreduced|undiminished|without\s+(?:any\s+)?(?:reduction|suspension|deduction)|
             (?:not|never)\s+(?:be\s+)?(?:reduced|suspended))/iux
    # Sol 2026-11-28 03:06:13Z (review of 7deed0145): "U ontvangt altijd 100 % van uw arbeidsongevallenvergoeding" (with
    # an Art. 61 link, right after a withheld claim, in the four languages) stayed: "100 % of" the compensation was no
    # payment phrase (now HUNDRED_OF), and the link let it stand. "Please handle the active "receive 100% of
    # [compensation]" guarantee in the same entitlement context ... An Article 61 link on a generated sentence alone should
    # not establish that 100% is due." A link to art. 61 itself, the article the sourced paragraph states, is no support of
    # its own for a dependent sentence; a link to another provision is (independent_link?).
    ARTICLE_61 = %r{\A/laws/1991013192#art-61(?![0-9])}
    # Sol 03:25:51Z (review of 3dc24a9a7): "Bij tijdelijke algehele arbeidsongeschiktheid bedraagt de dagvergoeding 90 % van
    # het gemiddelde dagloon, dus minder dan 100 % van dat loon ([Art. 22](/laws/1971041001#art-22))." went whole, its
    # cited rate with it. "Please scope the new payment marker so a less-than comparison with the wage base preserves the
    # cited 90% rate. Keep the unsupported full-payment promise suppressed even when it has a citation." Art. 22 of the
    # occupational accidents act (1971041001, read in full in NL and FR on 2026-11-28): 90 % of the average daily amount
    # for a temporary and total incapacity. "100 % of" is a payment phrase, except after "less than" or "up to" (BELOW),
    # where it is a comparison; a negation before that makes it a floor and a promise again ("niet minder dan 100 %").
    HUNDRED_OF = /(?<![[:alnum:]])100\s?%\s+(?:(?:van|de|du|des|of|der|ihrer|ihres|seiner|seines|vom|von)(?![[:alpha:]])|d['’])/iu
    BELOW = /(?<![[:alpha:]])(?:(?:minder|lager|kleiner)\s+dan|onder|tot(?:\s+aan)?|maximaal|ten\s+hoogste|hoogstens|niet\s+meer\s+dan|
             moins\s+d[e'’]|inf[ée]rieure?s?\s+[àa]|en\s+dessous\s+d[e'’]|jusqu['’][àa]|au\s+plus|au\s+maximum|pas\s+plus\s+d[e'’]|
             weniger\s+als|unter(?:halb)?|bis\s+zu|h[öo]chstens|maximal|nicht\s+mehr\s+als|less\s+than|lower\s+than|below|under|
             up\s+to|at\s+most|no\s+more\s+than|a\s+maximum\s+of)\s*\z/iux
    FLOOR = /(?<![[:alpha:]])(?:niet|nooit|pas|nicht|nie|not|no|never)\s*\z/i
    # Sol 2026-11-27 23:30:17Z (review of 202ce9b05): guarantee? "also deletes the accurate, cited sentence "Uw
    # arbeidsongevallenvergoeding wordt bij toegelaten arbeid niet automatisch voor 100 % doorbetaald ([Art. 61](...))."" and
    # "French, German and English denials that payment in full is guaranteed". Sol 2026-11-28 01:45:42Z (review of
    # 00cfed43b): a nearby negation let "Your compensation is no doubt paid in full" and "niet slechts gedeeltelijk maar
    # volledig doorbetaald" through, and "Il n’est pas garanti que votre indemnité soit maintenue intégralement", "Eine
    # Weiterzahlung der Entschädigung in voller Höhe ist nicht garantiert" and "Continued payment of your compensation in
    # full is not guaranteed" still went. "Prefer identifying an explicit denial of automatic/full payment or of a
    # guarantee, including a denial after the payment phrase, over treating any nearby 'no/not/niet' as a denial." Sol
    # 02:05:48Z (review of 3e741967d): "Your compensation is paid in full even when continued employment is not
    # guaranteed." stayed, and "Bij een tijdelijke vermindering wordt de vergoeding niet volledig doorbetaald" went. "The
    # relevant distinction is what is denied — retention of employment or full payment of compensation. A comma is a poor
    # proxy for that distinction."
    #
    # Sol 02:36:22Z (review of 0acf7fde8): "Uw arbeidsongevallenvergoeding wordt altijd volledig doorbetaald zolang uw baan
    # niet gegarandeerd is." stayed, and "Het is niet gegarandeerd dat uw vergoeding tijdens en na de werkhervatting
    # volledig wordt doorbetaald." went: clause separators decided. "I suggest narrowing retention of candidate guarantee
    # clauses to recognizable grammatical forms that explicitly deny full payment, with the curated explanation as
    # fallback where scope is ambiguous. This avoids relying on a growing list of clause separators."
    #
    # A sentence on the compensation with a payment phrase (the KEPT and WHOLE markers, overlapping ones as one) is a
    # guarantee and is withheld, unless the whole sentence has one of three forms that deny the payment itself:
    # - DIRECT_FORM: a negation right before the payment phrase, with only auxiliaries, payment verbs and
    #   "automatically", "always", "necessarily" between ("de vergoeding niet volledig doorbetaald", "n’est pas
    #   intégralement versée", "it is not paid in full"; "no doubt", "niet slechts" and "niet anders dan" deny nothing);
    # - PRE_FORM: a negated guarantee and its "that" clause, which holds the payment phrase ("Het is niet gegarandeerd dat
    #   uw vergoeding tijdens en na de werkhervatting volledig wordt doorbetaald"; each language with its own "that"
    #   words: the English "of" opens an object, "no guarantee of a job");
    # - POST_FORM: the payment as the subject of a negated "guaranteed" ("Continued payment of your compensation in full is
    #   not guaranteed").
    # No payment phrase stands outside the form, and the "that" clause, the subject and what follows the form are plain
    # (plain?). Any other sentence with a payment phrase goes: the sourced paragraph is the account.
    PHRASE = "\u0001"
    NEGATOR = /(?:niet|nooit|geen|(?:ne|n['’])\s*\p{L}+(?:\s+\p{L}+)?\s+(?:pas|jamais|plus)|nicht|nie|kein\p{L}*|not|never|no)/iux
    BETWEEN = /(?:wordt|worden|werd|werden|is|zijn|was|meer|langer|betaald|uitbetaald|uitgekeerd|gestort|volledige?|integrale|volle|
               automatisch|altijd|steeds|noodzakelijk\p{L}*|vanzelf\p{L}*|zomaar|[êe]tre|[ée]t[ée]|est|soit|sera|seront|serait|sont|
               vers[ée]e?s?|pay[ée]e?s?|automatiquement|toujours|forc[ée]ment|n[ée]cessairement|syst[ée]matiquement|mehr|l[äa]nger|
               wird|ist|sind|wurde|gezahlt|ausgezahlt|ausbezahlt|vollen?|voller|immer|unbedingt|notwendigerweise|zwangsl[äa]ufig|
               be|been|being|are|were|paid|kept|maintained|continued|longer|any|automatically|always|necessarily|
               ontvangt|ontvangen|krijgt|krijgen|recevez|re[çc]oit|re[çc]oivent|recevoir|re[çc]ue?s?|touchez|touche|erhalten|
               erh[äa]lt|bekommen|bekommt|receive[sd]?|gets?)/iux
    RUN = /(?:\s+(?:#{BETWEEN}(?![[:alpha:]])|#{PHRASE}))+/
    DIRECT_FORM = /\A(?<lead>[^#{PHRASE}]*?)(?<![[:alpha:]])#{NEGATOR}(?![[:alpha:]])#{RUN}(?<tail>[^#{PHRASE}]*)\z/
    # A negated guarantee by language, as a participle ("not guaranteed") or a noun ("no guarantee"), each with the words
    # that open its "that" clause (the Dutch "of" is "whether"; the English "of" opens an object: "no guarantee of a job")
    NL_GUARANTEED = /(?:niet|nooit)\s+(?:\p{L}+\s+)?(?:gegarandeerd|gewaarborgd|zeker)/i
    FR_GUARANTEED = /(?:ne|n['’])\s*\p{L}+\s+(?:pas|jamais|plus)\s+(?:\p{L}+\s+)?(?:garanti\p{L}*|assur[ée]\p{L}*|certain\p{L}*)/i
    DE_GUARANTEED = /nicht\s+(?:\p{L}+\s+)?(?:garantiert|gew[äa]hrleistet|gesichert|sicher)/i
    EN_GUARANTEED = /(?:not|never)\s+(?:\p{L}+\s+)?(?:guaranteed|assured|certain)/i
    PRE_DENIAL = /(?<![[:alpha:]])(?:(?:#{NL_GUARANTEED}|geen\s+(?:\p{L}+\s+)?(?:garantie|waarborg|zekerheid))\s*,?\s*(?:dat|of)(?![[:alpha:]])|
                  (?:#{FR_GUARANTEED}|(?:aucune|pas\s+de|sans)\s+garantie|rien\s+ne\s+garantit)\s*,?\s*(?:que(?![[:alpha:]])|qu['’])|
                  (?:#{DE_GUARANTEED}|kein\p{L}*\s+(?:\p{L}+\s+)?(?:garantie|gew[äa]hr|sicherheit))\s*,?\s*(?:dass|ob)(?![[:alpha:]])|
                  (?:#{EN_GUARANTEED}|no\s+(?:\p{L}+\s+)?(?:guarantee|assurance|certainty))\s*,?\s*(?:that|whether)(?![[:alpha:]]))/ix
    PRE_FORM = /\A[^#{PHRASE}]*?#{PRE_DENIAL}(?<rest>[^#{PHRASE}]*?)#{RUN}(?<tail>[^#{PHRASE}]*)\z/
    POST_FORM = /\A(?<subject>.*?)\s+(?:(?:is|ist|wordt|est|was|blijft|bleibt|remains|reste)\s+)?(?<![[:alpha:]])
                 (?:#{NL_GUARANTEED}|#{FR_GUARANTEED}|#{DE_GUARANTEED}|#{EN_GUARANTEED})(?![[:alpha:]])(?:\s+(?:is|wordt))?
                 (?<tail>[^#{PHRASE}]*)\z/x
    # What a plain stretch (plain?) has none of: an auxiliary (a clause of its own: "... wordt altijd volledig doorbetaald
    # zolang ..."), punctuation or a word that opens a clause, or a coordinated new subject ("en uw vergoeding", not
    # "tijdens en na")
    AUXILIARY = /(?<![[:alpha:]])(?:wordt|worden|werd|werden|is|zijn|was|waren|blijft|blijven|kan|kunnen|mag|mogen|moet|moeten|zal|
                 zullen|heeft|hebben|est|sont|soit|soient|sera|seront|serait|[ée]t[ée]|[êe]tre|reste|restent|peut|peuvent|doit|
                 doivent|ont|wird|wurde|ist|sind|war|bleibt|bleiben|kann|k[öo]nnen|darf|d[üu]rfen|muss|m[üu]ssen|soll|hat|haben|
                 are|were|be|been|being|remains?|can|may|must|will|would|shall|has|have|had)(?![[:alpha:]])/iux
    CLAUSE = /[,;:()\[\]]|(?<![[:alpha:]])(?:maar|doch|toch|terwijl|zolang|tenzij|omdat|want|zodat|als|wanneer|indien|mais|cependant|
              pourtant|tant\s+que|tandis|lorsque|quand|si|sauf|parce|car|afin|aber|jedoch|solange|w[äa]hrend|wenn|falls|weil|damit|
              au[ßs]er|but|however|while|whereas|as\s+long\s+as|unless|because|if|when|although|though|so\s+that)(?![[:alpha:]])/iux
    NEW_SUBJECT = /(?<![[:alpha:]])(?:en|and|et|und|or|ou|oder)\s+(?:(?:uw|de|het|een|u|zijn|haar|hun|hij|zij|ze|je|jij|your|the|a|an|
                   you|it|its|their|they|he|she|votre|vos|la|le|les|un|une|vous|il|elle|ils|elles|son|sa|ses|leur|ihre?n?|die|der|
                   das|den|dem|ein|eine|einen|sie|es|er|seine)(?![[:alpha:]])|l['’])/iux
    # The same boundary as a sentence end (not after "art." or "nr."), kept as a separator when a line is split
    SENTENCE_SPLIT = /((?<=[.!?;])(?<!\bart\.)(?<!\bartt\.)(?<!\bnr\.)(?<!\bbv\.)\s+)/i
    LINE_PREFIX = /\A[[:space:]]*(?:(?:[-*+•]|\d{1,9}[.)])[[:space:]]+)?/
    EMPTY_ITEM = /\A[[:space:]]*(?:(?:[-*+•]|\d{1,9}[.)])[[:space:]]*)?[*_[:space:]]*\z/
    # A quotation: a blockquote line (also in a list item, at any indentation) and a span in quotation marks, as
    # IndexedAmounts reads them (Sol 14:58:54Z: "‘tijdelijk of gedeeltelijk arbeidsongeschikt’" was still rewritten)
    QUOTE_LINE = IndexedAmounts::BLOCKQUOTE
    QUOTED_SPAN = /(#{IndexedAmounts::QUOTED})/
    # "tijdelijk of gedeeltelijk arbeidsongeschikt": the statute's "tijdelijk volledig of gedeeltelijk"
    WORDING = [
      [/(?<![[:alpha:]])(tijdelijke?)(\s+)of(\s+)(gedeeltelijke?|deels)(?=\s+\p{L}*ongeschikt)/iu,
       ->(m) { "#{m[1]}#{m[2]}#{m[1].end_with?('e') ? 'volledige' : 'volledig'} of#{m[3]}#{m[4]}" }],
      [/(?<![[:alpha:]])(temporairement)(\s+)ou(\s+)(partiellement)(?=\s+(?:inapte|incapable))/iu,
       ->(m) { "#{m[1]}, totalement ou#{m[3]}#{m[4]}" }],
      [/(?<![[:alpha:]])(incapacit[ée]\s+(?:de\s+travail\s+)?temporaire)(\s+)ou(\s+)(partielle)(?![[:alpha:]])/iu,
       ->(m) { "#{m[1]}, totale ou#{m[3]}#{m[4]}" }],
      [/(?<![[:alpha:]])(vor[üu]bergehend|zeitweilig)(\s+)oder(\s+)(teilweise)(?=\s+\p{L}*unf[äa]hig)/iu,
       ->(m) { "#{m[1]}#{m[2]}ganz oder#{m[3]}#{m[4]}" }],
      [/(?<![[:alpha:]])(temporarily)(\s+)or(\s+)(partially|partly)(?=\s+(?:unfit|disabled|incapacitated))/iu,
       ->(m) { "#{m[1]}#{m[2]}fully or#{m[3]}#{m[4]}" }],
      [/(?<![[:alpha:]])(temporary)(\s+)or(\s+)(partial)(?=\s+(?:incapacity|disability))/iu,
       ->(m) { "#{m[1]}#{m[2]}full or#{m[3]}#{m[4]}" }]
    ].freeze

    module_function

    def apply(text, question:, language: 'nl', sources: [])
      return text if text.blank? || !entitlement_question?(question)

      corrected = corrected_wording(text)
      return corrected if TEXT.values.any? { |verified| corrected.include?(verified) }

      lines = without_claims(corrected, source_texts(sources)).split("\n", -1)
      paragraph = TEXT.fetch(TEXT.key?(language.to_s) ? language.to_s : 'nl')
      at = lines.index { |line| !line.strip.empty? } || 0
      at += 1 if lines[at].to_s.match?(UnemploymentAmountApplicability::HEADING)
      head = lines[0...at]
      rest = (lines[at..] || []).drop_while { |line| line.strip.empty? }
      [*head, *(head.empty? || head.last.strip.empty? ? [] : ['']), paragraph, '', *rest].join("\n")
    end

    # A question on the unemployment benefit after an occupational accident or disease, not on a death or a survivor
    def entitlement_question?(question)
      text = question.to_s
      text.match?(LegislationSearch::ACCIDENT_UNEMPLOYMENT_PATTERN) && text.match?(OCCUPATIONAL) && text.match?(BENEFIT) &&
        !text.match?(ArticleSubjectScope::DEATH)
    end

    # A sentence on eligibility under an incapacity, or on the exception for the temporarily unemployed
    def claim?(sentence)
      eligibility = sentence.match?(INCAPACITY) && sentence.match?(ENTITLEMENT) && !sentence.match?(DURATION)
      exception = sentence.match?(TEMPORARY_UNEMPLOYMENT) &&
                  ((sentence.match?(WORK) && sentence.match?(PERMITTED)) || sentence.match?(SUSPENSION))
      eligibility || exception
    end

    # Every claim in the chatbot's own prose is withheld; a list item or line left empty goes, then a heading whose
    # content all went, and a blank line doubled by either. Blockquotes, table rows, headings, the applicability paragraph
    # and the index notes are never read here.
    def without_claims(text, texts = [])
      lines = text.split("\n", -1)
      carry = false
      kept = lines.map do |line|
        if untouchable?(line)
          carry = false
          next line
        end

        prefix = line[LINE_PREFIX]
        carry = false unless prefix.strip.empty?
        pairs = sentence_pairs(line[prefix.length..])
        rest = pairs.reject do |sentence, _separator|
          plain = without_supported_quotes(sentence, texts)
          withheld?(plain, carry).tap { carry = claim?(plain) }
        end
        next line if rest.length == pairs.length

        remaining = "#{prefix}#{rest.join.rstrip}"
        remaining.match?(EMPTY_ITEM) ? nil : remaining
      end
      return text if kept == lines

      result = without_emptied_headings(lines, kept).chunk_while { |a, b| a.strip.empty? && b.strip.empty? }.map(&:first)
                                                    .drop_while { |line| line.strip.empty? }
      result.pop while result.any? && result.last.strip.empty?
      result.join("\n")
    end

    # Sol 2026-11-27 16:52:39Z: "Als tijdelijk werkloze mag u bepaalde arbeid verrichten. Uw arbeidsongevallenvergoeding wordt
    # daarbij altijd volledig doorbetaald." kept its second sentence. "Please ... treat a directly dependent compensation
    # sentence as part of the removed eligibility passage. Keep independently supported amounts and quotations, and avoid
    # adding a blanket filter for all references to compensation." A sentence right after a withheld one, in the same
    # paragraph (the next sentence of the line, or the first of a plain next line), goes with it when it speaks of the
    # compensation or the benefit and stands on nothing of its own: no citation link and no figure.
    def dependent?(sentence)
      sentence.match?(COMPENSATION) && !independent_link?(sentence) && !official_amount?(sentence) && !denial?(sentence)
    end

    # A citation link to a provision other than art. 61 itself (Sol 03:06:13Z)
    def independent_link?(sentence)
      sentence.scan(/\]\(([^)\s]+)\)/).flatten.any? { |href| !href.match?(ARTICLE_61) }
    end

    # Sol 2026-11-27 22:45:44Z (review of the 1.1.118 seal): "Uw arbeidsongevallenvergoeding wordt daarbij altijd voor 100 %
    # doorbetaald." stood because any percentage counted as support. Only a citation link, or an amount IndexedAmounts
    # reads as an official one (a base or an indexed amount of art. 115), lets a sentence stand on its own; a percentage
    # or another figure does not.
    def official_amount?(sentence)
      sentence.to_enum(:scan, IndexedAmounts::AMOUNT).any? do
        match = Regexp.last_match
        IndexedAmounts::READINGS.key?(BigDecimal("#{match[:int]}.#{match[:dec]}"))
      end
    end

    # Sol 22:45:44Z: De bron vermeldt: "Die werknemer kan geen uitkeringen genieten." went, though its words stand verbatim
    # in a retrieved article. "Please protect supported inline quotations through this step without letting an
    # unsupported claim survive merely by putting it in quotation marks." A sentence is judged without the quotations whose
    # words a retrieved source holds verbatim (at least 12 characters); what is left still has to pass.
    def without_supported_quotes(sentence, texts)
      return sentence if texts.empty?

      sentence.gsub(QUOTED_SPAN) do |span|
        words = span[1...-1].to_s.squish.downcase
        words.length >= 12 && texts.any? { |text| text.include?(words) } ? ' ' : span
      end
    end

    def source_texts(sources)
      Array(sources).filter_map do |row|
        next unless row.respond_to?(:[])

        (row[:article_text] || row['article_text'] || row[:text] || row['text']).to_s.squish.downcase.presence
      end
    end

    # A claim, a guarantee, or the one dependent sentence right after a claim (Sol 22:15:28Z: the carry is used once; only a
    # fresh claim starts it again, so "Het bedrag van de werkloosheidsuitkering hangt af van ..." after the dependent one
    # stays). A guarantee starts no carry: it is the sentence that depends on the claim.
    def withheld?(sentence, after_claim)
      claim?(sentence) || guarantee?(sentence) || (after_claim && dependent?(sentence))
    end

    # The compensation and a payment phrase, in a sentence that is not a denial form
    def guarantee?(sentence)
      sentence.match?(INDEMNITY) && core(sentence).include?(PHRASE) && !denial?(sentence)
    end

    # The whole sentence denies the payment itself in one of the three forms ("niet automatisch aangepast", without a
    # payment phrase, denies nothing). Such a sentence stands on its own, like an official amount: art. 61, § 2 makes the
    # work subject to suspension or temporary reduction of the right to compensation.
    def denial?(sentence)
      core = core(sentence)
      return false unless core.include?(PHRASE)

      direct = core.match(DIRECT_FORM)
      pre = core.match(PRE_FORM)
      post = core.match(POST_FORM)
      (direct && plain?(direct[:tail])) || (pre && plain?(pre[:rest]) && plain?(pre[:tail])) ||
        (post && plain?(post[:subject]) && plain?(post[:tail])) || false
    end

    def plain?(text)
      !text.match?(AUXILIARY) && !text.match?(CLAUSE) && !text.match?(NEW_SUBJECT)
    end

    # The sentence with each payment phrase (overlapping markers as one) as PHRASE, less a closing citation link and the
    # final punctuation
    def core(sentence)
      spans = [KEPT, WHOLE].flat_map { |marker| sentence.to_enum(:scan, marker).map { Regexp.last_match.offset(0) } }
      spans += hundred_spans(sentence)
      merged = spans.sort.each_with_object([]) do |(from, to), list|
        if list.any? && from <= list.last[1]
          list.last[1] = [list.last[1], to].max
        else
          list << [from, to]
        end
      end
      skeleton = merged.reverse_each.with_object(sentence.dup) { |(from, to), text| text[from...to] = PHRASE }
      skeleton.sub(/\s*\(\[[^\]]*\]\([^)]*\)\)(?=[.!?]?\s*\z)/, '').sub(/\s*[.!?]\s*\z/, '').strip
    end

    # The "100 % of" spans that promise the payment: not after "less than" or "up to", unless a negation makes that a floor
    # (Sol 03:25:51Z)
    def hundred_spans(sentence)
      sentence.to_enum(:scan, HUNDRED_OF).map { Regexp.last_match.offset(0) }.select do |from, _to|
        below = sentence[0...from].match(BELOW)
        below.nil? || sentence[0...below.begin(0)].match?(FLOOR)
      end
    end

    # Sol 23:00:25Z: in De bron vermeldt: "Die werknemer kan geen uitkeringen genieten." Uw arbeidsongevallenvergoeding ...
    # both sentences went: "The sentence split currently misses the closing quotation mark between sentences". A quotation
    # is never split, and its closing mark ends a sentence when the quotation ends with one. The pairs [sentence, separator].
    def sentence_pairs(text)
      spans = []
      masked = text.gsub(QUOTED_SPAN) do |span|
        spans << span
        "\u0001#{spans.length - 1}#{span[...-1].rstrip.end_with?('.', '!', '?') ? '.' : "\u0002"}"
      end
      masked.split(SENTENCE_SPLIT).map { |part| part.gsub(/\u0001(\d+)[.\u0002]/) { spans[Regexp.last_match(1).to_i] } }
            .each_slice(2).to_a
    end

    def untouchable?(line)
      line.strip.empty? || line.match?(QUOTE_LINE) || line.match?(IndexedAmounts::TABLE_ROW) ||
        line.match?(UnemploymentAmountApplicability::HEADING) || line.match?(IndexedAmounts::NOTE_LEAD) ||
        UnemploymentAmountApplicability::TEXT.values.any? { |paragraph| line.include?(paragraph) }
    end

    # The lines kept (nil: withheld), less each heading whose section had content and now has none; a leading heading
    # stays, the paragraph goes under it
    def without_emptied_headings(lines, kept)
      leading = lines.index { |line| !line.strip.empty? }
      kept.each_with_index.filter_map do |line, index|
        next if line.nil?
        next line if index == leading || !line.match?(UnemploymentAmountApplicability::HEADING)

        section = ((index + 1)...lines.length).take_while { |below| !lines[below].match?(UnemploymentAmountApplicability::HEADING) }
        had = section.any? { |below| !lines[below].strip.empty? }
        has = section.any? { |below| kept[below] && !kept[below].strip.empty? }
        line if has || !had
      end
    end

    # Sol 2026-11-27 14:17:31Z and 14:18:08Z: the rewrite changed "> De tijdelijke of gedeeltelijke arbeidsongeschiktheid",
    # and it runs after the quote guard, whose verdict the answer then published for a different text. Only the chatbot's
    # own prose is corrected: a blockquote line (also in a list item, at any indentation) and a span in quotation marks
    # keep their words.
    def corrected_wording(text)
      text.split("\n", -1).map do |line|
        next line if line.match?(QUOTE_LINE)

        line.split(QUOTED_SPAN).each_with_index.map { |part, index| index.odd? ? part : prose_corrected(part) }.join
      end.join("\n")
    end

    def prose_corrected(text)
      WORDING.reduce(text) { |current, (pattern, render)| current.gsub(pattern) { render.call(Regexp.last_match) } }
    end
  end
end
