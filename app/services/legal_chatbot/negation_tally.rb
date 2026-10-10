# frozen_string_literal: true

module LegalChatbot
  # A count of the negations in a French and in a German text, for the
  # checks of German answers v3 (to-do 7.5): a translation, in either
  # direction, must say "not" as often as its source.
  #
  # The graded run of German answers v2 (docs/ops/german-answers-v2-eval-2026-09-29.md)
  # found a translation that inverted the law this way: "sauf si le vendeur
  # ... n'a pas respecté" (unless) became "sofern der Verkäufer ... nicht
  # eingehalten hat" (provided that), one negation fewer, and the mechanical
  # check of the time passed it. A negation tally catches that shape and
  # nothing subtler: a change of voice or of the person a rule applies to
  # keeps every count.
  #
  # One unit per negation, not per word, so that the two languages count
  # alike:
  #
  # - French "ne" with its partner (pas, plus, jamais, rien, aucun, nul,
  #   guère, point, personne, ni) is ONE unit, and so is the literary "ne"
  #   without one ("il ne peut être inférieur à"), which is a negation too.
  #   "Aucune exception ne s'applique" is one unit, its partner coming first.
  #   "ne ... que" is "only", not a negation, and is not counted; nor is the
  #   expletive "ne" ("à moins que le juge n'en décide autrement").
  # - A French "pas" or "aucun" without "ne" ("pas de règle", "aucune
  #   citation") is one unit, as is a sentence's "ni ... ni" chain without
  #   "ne"; each "sauf", "sans", "non" and "à moins que" is one unit, and so
  #   is "omettre de" in any form ("a omis de l'informer": did not inform).
  # - German: each nicht, kein (any ending), nichts, nie, niemals, niemand,
  #   ohne, außer, "es sei denn", weder and unbeschadet (the rendering of
  #   "sans préjudice") is one unit, and so is each form of "versäumen" and
  #   "unterlassen" (the renderings of "omettre de"). "noch" is not counted:
  #   it is the second half of "weder ... noch", as the second "ni" is of
  #   "ni ... ni".
  #
  # Tuned on the 32 translated answers of the v2 run, where it flags the two
  # translations whose negation changed (q0300, q1083) and none of the 25
  # faithful ones. That set is also where it was defined, so it still needs a
  # fresh one: the v3 evaluation records every rejection it makes.
  #
  # Version 4 (the graded v3 run, docs/ops/german-answers-v3-eval-2026-09-29.md):
  # on 34 translated answers the whole-answer tally rejected 6 faithful ones
  # and caught 1 real change (q12, "sauf si" became "sofern" three times in a
  # table). So:
  #
  # - An answer is compared line by line (#line_mismatches): the translation
  #   keeps the line order, so a negation dropped in one line and added in
  #   another no longer cancels out, and each line is judged on its own.
  # - A line may differ by the wordings the report found equivalent
  #   (EQUIVALENCES): "enfant sans vie" and "Totgeburt", "non-usage" and
  #   "Nichtausübung", "aucun mariage ne peut ... sans autorisation" and
  #   "nur mit Genehmigung", "n'existe plus ..., y compris" and "nicht mehr
  #   ..., auch nicht". When both wordings are on the paired lines, the line
  #   must differ by exactly the difference they make, no less and no more:
  #   allowed as a range, the "nicht" of "auch nicht" made up for a negation
  #   dropped elsewhere on the line, and "sauf si" rendered "sofern" passed.
  #   The report's fifth equivalence, "a omis de l'informer" and "hat ihn
  #   nicht informiert", is no equivalence any more: "omettre de" counts as a
  #   negation (above), so the two lines count alike.
  # - In a question, the rhetorical "Ist die Forderung nicht schon
  #   verjährt?" asks whether the claim is time-barred: its "nicht" is no
  #   negation, and neither is the French "n'est-elle pas déjà ...?" (q19).
  #
  # Version 5 (the graded v4 run, docs/ops/german-answers-v4-eval-2026-10-04.md):
  # of 21 answers that fell back to French, 10 were this tally refusing
  # faithful German, and one retry it asked for inserted a negation to match
  # the count and was served. So:
  #
  # - Privative wording on one side against an explicit negation on the
  #   other is equivalent (EQUIVALENCES): "insatisfaisante" and "keine
  #   zufriedenstellende", "échappant au contrôle" and "nicht beeinflussen
  #   kann", "en l'absence de" and "falls keine", "à naître" and "noch nicht
  #   geboren", "autres que" and "außer", "sans frais" and "unentgeltlich",
  #   "ne peut pas dépasser" and "höchstens", "non-respect" and
  #   "Nichteinhaltung", "non rémunéré" and "unbezahlt".
  # - "mit Ausnahme", "ausgenommen" and "abgesehen von" count in German, as
  #   "hormis", "excepté" and "à l'exception de" do in French, so "sauf"
  #   rendered "mit Ausnahme" stays balanced.
  # - French "pas non plus" is one negation, not two, and the "ni" of "sans X
  #   ni Y" belongs to the "sans".
  # - An exception a German line states ("es sei denn", "außer",
  #   "ausgenommen", "mit Ausnahme") where its French line states none
  #   ("sauf", "à moins que", "excepté", "hormis", "à l'exception", "autres
  #   que") is a mismatch whatever the counts say: that is the shape of the
  #   inversion the retry produced ("employers grant unpaid days ... not a
  #   legal obligation" became "employers do not grant ..., unless").
  module NegationTally
    WORD_START = '(?<![[:alpha:]])'
    WORD_END = '(?![[:alpha:]])'

    SENTENCE_BREAK = /(?<=[.!?;:])\s+|\n+/
    FRENCH_NE = /#{WORD_START}(?:ne\s|n['’])/i
    # "nul" as a partner of "ne" (nul, nulle, nullement), but not the void of
    # "ne peut être déclarée nulle que" (v11 q17: the partner there is the
    # restrictive "que").
    FRENCH_PARTNER = /#{WORD_START}(pas|plus|jamais|rien|aucun[[:alpha:]]*|nul(?:le?s?|lement)?(?!\s+(?:que#{WORD_END}|qu['’]|de\s+plein\s+droit|et\s+non\s+avenu))|guère|point|personne|ni|que|qu)#{WORD_END}/i
    RESTRICTIVE_PARTNERS = %w[que qu].freeze
    # How far after "ne" its partner is looked for, in words.
    PARTNER_WINDOW_WORDS = 6
    FRENCH_LEADING_PARTNER = /#{WORD_START}(?:aucun[[:alpha:]]*|nul[[:alpha:]]*|rien|personne|jamais)#{WORD_END}/i
    # A "ne" with no partner after "à moins que", "avant que", "de peur que",
    # "sans que" or a comparison ("plus long qu'il ne l'était") is the
    # expletive "ne": no negation, and no German one either.
    # Within one clause: no comma between the context and the "ne".
    FRENCH_EXPLETIVE_CONTEXT = /
      (?:#{WORD_START}(?:à\s+moins|avant|de\s+peur|de\s+crainte|sans)\s+qu(?:e#{WORD_END}|['’])
      |#{WORD_START}(?:plus|moins|mieux|pire|autre|autrement)#{WORD_END}[^.;:!?,]*#{WORD_START}qu(?:e#{WORD_END}|['’]))
      [^.;:!?,]*\z
    /xi
    FRENCH_PAS = /#{WORD_START}pas#{WORD_END}/i
    FRENCH_AUCUN = /#{WORD_START}aucun(?:e|s|es)?#{WORD_END}/i
    FRENCH_NI = /#{WORD_START}ni#{WORD_END}/i
    FRENCH_SIMPLE = [
      /#{WORD_START}sauf#{WORD_END}/i,
      /#{WORD_START}sans#{WORD_END}/i,
      # "pas non plus" is one negation: its "non" is the "pas" said again.
      /#{WORD_START}non#{WORD_END}(?!\s+plus#{WORD_END})/i,
      /#{WORD_START}(?:hormis|excepté(?:e|s|es)?)#{WORD_END}/i,
      /#{WORD_START}à\s+l['’]exception\s+(?:de|d['’]|des|du)/i,
      # "à moins que" (unless), not "à moins de", which in a seniority
      # bracket is "less than" ("de 4 ans à moins de 5 ans").
      /#{WORD_START}à\s+moins\s+qu(?:e#{WORD_END}|['’])/i,
      # "a omis de l'informer", "omet d'indiquer", "l'omission de payer".
      /#{WORD_START}(?:omi[st]e?s?|omet\w*|omission)\s+(?:de\s|d['’])/i
    ].freeze

    GERMAN = [
      /#{WORD_START}nicht#{WORD_END}/i,
      /#{WORD_START}kein(?:e|en|em|er|es)?#{WORD_END}/i,
      /#{WORD_START}nichts#{WORD_END}/i,
      /#{WORD_START}(?:nie|niemals|niemand(?:em|en)?)#{WORD_END}/i,
      /#{WORD_START}ohne#{WORD_END}/i,
      /#{WORD_START}au(?:ß|ss)er#{WORD_END}/i,
      /#{WORD_START}es\s+sei\s+denn#{WORD_END}/i,
      /#{WORD_START}(?:mit\s+Ausnahme|ausgenommen|abgesehen\s+von)#{WORD_END}/i,
      /#{WORD_START}weder#{WORD_END}/i,
      /#{WORD_START}unbeschadet#{WORD_END}/i,
      # "hat es versäumt, ihn zu informieren", "unterlässt es".
      /#{WORD_START}(?:versäum(?:e|en|st|t|te|ten|tet)|unterl(?:asse|assen|ässt|asst|ieß|ießen))#{WORD_END}/i
    ].freeze

    # A rhetorical question: "nicht schon" and "n'est-elle pas déjà" ask
    # whether something already happened, they deny nothing.
    GERMAN_RHETORICAL = /#{WORD_START}nicht(?=\s+(?:schon|bereits)#{WORD_END})/i
    FRENCH_RHETORICAL = /#{WORD_START}(?:ne\s+|n['’])(?<verb>[^\s?]+)\s+pas(?=\s+déjà#{WORD_END})/i
    QUESTION_END = /\?[\s*_»"“”]*\z/

    # Wordings that say the same with a different count, found in the graded
    # v3 run: [name, French pattern, German pattern, German minus French per
    # pair]. A line pair must differ by exactly delta for each time both
    # occur.
    # exact: the pair MUST account for its delta each time both wordings
    # occur, because the German wording renders nothing but the French one
    # (the v3 equivalences, a "Nicht-" compound, "noch nicht geboren"). An
    # equivalence that is not exact MAY account for it, because its German
    # wording also renders French words that are no negation: "unrechtmäßig"
    # on the line of "non-respect" rendered "abusif", not the "non", whose
    # rendering was "nicht eingehalten". Such a line is accepted at any
    # difference the optional pairs can explain, which also means that a
    # "nicht" added on it goes unseen; the exact pairs still see one.
    Equivalence = Struct.new(:name, :french, :german, :delta, :exact) do
      def exact? = exact != false
    end
    FRENCH_NEGATED_CLAUSE = /#{WORD_START}(?:ne\s|n['’]|aucun)/i
    FRENCH_SANS = /#{WORD_START}sans#{WORD_END}/i
    # "sans" in a clause that is already negative: "ne ... sans" is "only with".
    FRENCH_SANS_IN_NEGATED_CLAUSE = lambda do |line|
      line.match?(FRENCH_NEGATED_CLAUSE) ? line.scan(FRENCH_SANS).length : 0
    end
    # Exemption or exclusion said without a negation word: "déroger à",
    # "exempté de", "exonéré", "dispensé", "exclu", "à l'exclusion de", "mis à
    # part", "exception faite de", "hors" (not "hors taxes").
    FRENCH_EXEMPTION = /#{WORD_START}(?:(?:dérog|exempt|exonér|dispens|exclu)[[:alpha:]]*|à\s+l['’]exclusion|mise?\s+à\s+part|
                                      exception\s+faite|hors(?!\s+(?:taxes?|TVA)#{WORD_END})#{WORD_END})/xi
    EQUIVALENCES = [
      # q0041: "Enfant sans vie" (1) and "Totgeburt" (0).
      Equivalence.new('stillbirth', /#{WORD_START}sans\s+vie#{WORD_END}/i,
                      /tot\s*geb(?:urt|oren)|Totgeburt/i, -1),
      # q0774: "non-usage" (1) and "Nichtausübung" (0); v4 q1083: "non-respect"
      # and "Nichteinhaltung". Any "non" prefix against a German "Nicht-"
      # compound (never "nichtig", which is void, not not).
      # v5 q07: "(non professionnel)" against "nichtberuflichen", the
      # adjective compounds written small.
      Equivalence.new('non_compound', /#{WORD_START}non[\s-]+[[:alpha:]]+/i,
                      /#{WORD_START}[Nn]icht(?!ig)[[:alpha:]]{4,}/, -1),
      # v4 q24: "non rémunérés" (1) and "unbezahlte" (0), the German privative
      # adjectives of the run and their kin.
      Equivalence.new('non_adjective', /#{WORD_START}non[\s-]+[[:alpha:]]+/i,
                      /#{WORD_START}un(?:bezahlt|begründet|geboren|entgeltlich|zulässig|möglich|zureichend|vollständig|
                                        befristet|bestimmt|gültig|wirksam|abhängig|erheblich|zumutbar|beschränkt|verändert|
                                        zufrieden|berechtigt|rechtmäßig|gerechtfertigt|freiwillig|verschuldet|kündbar|
                                        übertragbar|veräußerlich|pfändbar|teilbar|widerruflich|verjährbar|
                                        missverständlich)[[:alpha:]]*/xi, -1, false),
      # v4 q1083, q0181, q0301, q22: a French privative word (0) said with a
      # German negation (1): "insatisfaisante" / "keine zufriedenstellende",
      # "impossibilité" / "nicht in der Lage", "échappant au contrôle" /
      # "nicht beeinflussen kann", "en l'absence de" / "falls keine".
      Equivalence.new('privative',
                      /#{WORD_START}(?:i[mn](?:possib|satisfais|capab|capacit|applicab|disponib|complet|complèt|suffisan|
                                            valid|just|exact|existan|connu|admissib|certain|déterminé|dépendan|
                                            compéten|aptitud|apte|exécutab|exigib|opposab|sécur|égal|habil|
                                            prévisib|évitab|contestab|révocab|cessib|saisissab)[[:alpha:]]*
                         |échappant\s+(?:au|à\s+(?:leur|son|sa))\s+contrôle
                         |hors\s+de\s+(?:son|leur|tout)\s+contrôle
                         |(?:en\s+l['’]|(?:en\s+)?cas\s+d['’]|l['’])absence\s+(?:de|d['’])
                         |(?:à|un|le|la|du|en|par|pour|tout|ce)\s+défaut\s+(?:de|d['’])
                         |faute\s+(?:de|d['’])
                         |contraires?\s+(?:à|au|aux)#{WORD_END})/xi,
                      # v6 q15: "en l'absence de défaut" (0) became "ohne Mangel" (1).
                      /#{WORD_START}(?:nicht|kein(?:e|en|em|er|es)?|ohne)#{WORD_END}/i, 1, false),
      # v5 q0841, q11: "sauf exceptions" (1) said "vorbehaltlich der
      # Ausnahmen" or "Ausnahmen vorbehalten" (0).
      Equivalence.new('reserved', /#{WORD_START}(?:sauf|sous\s+réserve|à\s+moins|excepté|hormis)#{WORD_END}/i,
                      /#{WORD_START}vorbehalt(?:lich|en)#{WORD_END}/i, -1, false),
      # v4 q20: "enfants nés et à naître" (0) and "noch nicht geboren" (1).
      Equivalence.new('unborn', /#{WORD_START}à\s+naître#{WORD_END}/i,
                      /#{WORD_START}noch\s+nicht\s+geboren/i, 1),
      # v4 q12: "autres que" (0) and "außer" or "mit Ausnahme" (1); v9 q14:
      # "d'autres coûts que" with the noun between (the same); the run after
      # round 11 (2026-10-06), q22: "les voies publiques autres que les
      # autoroutes" (0) and "Straßen, die keine Autobahnen sind" (1).
      Equivalence.new('other_than', /#{WORD_START}autres?\s+(?:[[:alpha:]’'-]+\s+){0,2}qu(?:e#{WORD_END}|['’])/i,
                      /#{WORD_START}(?:au(?:ß|ss)er|mit\s+Ausnahme|ausgenommen|kein(?:e|en|em|er|es)?)#{WORD_END}/i, 1, false),
      # v9 q13: "sans preuve contraire" (1) said "mangels gegenteiligen
      # Beweises" (0): the German privative preposition.
      Equivalence.new('lacking', /#{WORD_START}(?:sans|faute\s+(?:de|d['’])|à\s+défaut\s+(?:de|d['’]))#{WORD_END}/i,
                      /#{WORD_START}(?:mangels|in\s+Ermangelung)#{WORD_END}/i, -1, false),
      # v10 q0300: "sans équivoque" (1) said "unmissverständlich" (0): a
      # French "sans" said with a German privative adjective (the un- forms
      # the non_adjective pair knows and their kin); the weekly run of
      # 2026-10-05, q0014: "sans interruption" said "ununterbrochen".
      Equivalence.new('sans_adjective', /#{WORD_START}sans\s+[[:alpha:]’'-]+/i,
                      /#{WORD_START}un(?:missverständlich|eingeschränkt|verzüglich|entgeltlich|bedingt|befristet|beschränkt|
                                        begründet|bezahlt|wirksam|gültig|verbindlich|widerruflich|zumutbar|verschuldet|
                                        angemeldet|vollständig|gekündigt|verändert|beanstandet|geprüft|belastet|versteuert|
                                        unterbrochen)
                       [[:alpha:]]*/xi, -1, false),
      # The weekly run of 2026-10-05, q20: "sans distinction d'âge ou de sexe"
      # (1) said "unabhängig von Alter oder Geschlecht" (0).
      Equivalence.new('without_distinction', /#{WORD_START}sans\s+distinctions?\s+(?:de|d['’])/i,
                      /#{WORD_START}(?:unabh[äa]ngig\s+(?:von|vom)|ungeachtet)#{WORD_END}/i, -1, false),
      # The weekly run of 2026-10-05, q0774: "ne cesse de courir que lorsque"
      # (the restrictive, 0) said "läuft nur dann nicht weiter, wenn" (1): the
      # German negation renders the verb "cesser" (the Belgian German Civil
      # Code writes "hört erst auf zu laufen"), one negation at most.
      Equivalence.new('cease', /#{WORD_START}cess(?:e|es|ent|er|é|ée|és|ées|ait|aient|era|eront|ant)\s+(?:de|d['’])/i,
                      /#{WORD_START}nicht\s+(?:weiter|mehr)#{WORD_END}/i, 1, false),
      # The weekly run of 2026-10-05, q22: "(hors autoroute)" (0) said "(nicht
      # auf Autobahnen)" (1): "hors" before a noun said with a German "nicht"
      # and its preposition (the exempted pair takes only the exception
      # words; "hors de", "hors taxes" and "hors TVA" have their own pairs).
      Equivalence.new('outside', /#{WORD_START}hors\s+(?!(?:de|du|des|d['’]|taxes?|TVA|T\.V\.A)(?:#{WORD_END}|\.))[[:alpha:]]/i,
                      /#{WORD_START}nicht\s+(?:auf|in|im|für|an|am)#{WORD_END}/i, 1, false),
      # v4 q15: "sans frais" (1) and "unentgeltlich" or "kostenlos" (0).
      Equivalence.new('without_charge', /#{WORD_START}sans\s+frais#{WORD_END}/i,
                      /#{WORD_START}(?:unentgeltlich|kostenlos|kostenfrei|gebührenfrei)[[:alpha:]]*/i, -1, false),
      # v4 q23: "ne peut pas dépasser" (1) and "höchstens" (0); v7 q0041:
      # "sans dépasser 24 semaines" (1) and "maximal 24 Wochen" (0); v11 q08:
      # "deux fois (pas plus)" (1) and "höchstens zweimal" (0); the run after
      # round 11 (2026-10-06), q0014: "un total n'excédant pas une journée"
      # (1) and "insgesamt maximal ein Arbeitstag" (0), the verb as a
      # participle or in the present.
      Equivalence.new('at_most', /#{WORD_START}(?:(?:ne\s+(?:peu(?:t|vent)|doi(?:t|vent))\s+pas|sans)\s+(?:dépasser|excéder)|\(?pas\s+plus\)?|
                                                 (?:n['’]exc[èé]d(?:ant|e|ent)|ne\s+dépass(?:ant|e|ent))\s+pas)/xi,
                      /#{WORD_START}(?:höchstens|maximal|spätestens)#{WORD_END}/i, -1, false),
      # v11 q0041: "sauf pour des motifs étrangers à ce congé" (the "sauf", 1)
      # said "Gründe, die nicht mit dem Urlaub zusammenhängen" (2): a French
      # "étranger à" (0) is a German "nicht ... zusammenhängen" (1); the run
      # after round 11, q09: "nicht mit der Inanspruchnahme des
      # Geburtsurlaubs zusammenhängen", 40 characters between the two.
      Equivalence.new('unrelated', /#{WORD_START}étrang(?:er|ère|ers|ères)\s+(?:à|au|aux)#{WORD_END}/i,
                      /#{WORD_START}(?:nichts?\s+(?:zu\s+tun|zusammenh[äa]ng|mit[^.;\n]{0,60}zusammenh[äa]ng|in\s+Zusammenhang|im\s+Zusammenhang)|
                                       unabh[äa]ngig|ohne\s+Zusammenhang)/xi, 1, false),
      # v11 q17: "HTVA" (0) said "ohne MwSt." (1): the exclusive-of-tax
      # wording is no exception.
      Equivalence.new('excl_vat', /#{WORD_START}(?:HTVA|hors\s+(?:TVA|taxes?)|hors\s+T\.V\.A\.?)#{WORD_END}/i,
                      /#{WORD_START}(?:ohne\s+(?:MwSt|Mehrwertsteuer|Umsatzsteuer)|exkl(?:usive|\.)?\s+MwSt|netto)/i, 1, false),
      # v4 q0039 (served): "dérogent aux obligations de pause" (0) and "sind
      # von den Pausenregelungen ausgenommen" (1): a French verb of exemption
      # or exclusion said with a German exception word.
      Equivalence.new('exempted', FRENCH_EXEMPTION,
                      /#{WORD_START}(?:au(?:ß|ss)er(?!\s*halb)|mit\s+Ausnahme|ausgenommen|ohne|frei\s+von)#{WORD_END}/i, 1, false),
      # q0181: "Aucun mariage ne peut être célébré ... sans autorisation" (2)
      # and "nur mit Genehmigung" (0).
      Equivalence.new('only_with', FRENCH_SANS_IN_NEGATED_CLAUSE,
                      /#{WORD_START}nur\s+(?:mit|nach|wenn|bei|durch|unter|gegen)#{WORD_END}/i, -2),
      # q05: "n'existe plus ..., y compris pour" (1) and "nicht mehr ..., auch
      # nicht für" (2).
      Equivalence.new('including', /#{WORD_START}y\s+compris#{WORD_END}/i,
                      /#{WORD_START}auch\s+(?:nicht|kein\w*)#{WORD_END}/i, 1),
      # v6 q07: "en l'absence de CCT ou de règlement de travail" (0) became
      # "kein KAA oder keine Arbeitsordnung" (2): the second "kein" of a
      # coordination repeats the first, one negation said twice.
      Equivalence.new('kein_oder_kein', /#{WORD_START}(?:ou|ni|et)#{WORD_END}/i,
                      /#{WORD_START}kein(?:e|en|em|er|es)?#{WORD_END}[^,.;:]{0,60}?#{WORD_START}oder\s+kein(?:e|en|em|er|es)?#{WORD_END}/i,
                      1, false),
      # v6 q15: "sans délai" (1) became "unverzüglich" (0).
      Equivalence.new('without_delay', /#{WORD_START}sans\s+(?:délai|retard|tarder|attendre)#{WORD_END}/i,
                      /#{WORD_START}(?:unverzüglich|sofort|umgehend|fristlos)[[:alpha:]]*/i, -1, false),
      # v6 q21 (the question side): "ai-je l'interdiction de conduire" (0)
      # renders "darf ich nicht mehr fahren" (1); a prohibition is a negation
      # said as a noun.
      Equivalence.new('prohibition',
                      /#{WORD_START}(?:interdiction|interdite?s?|défense\s+(?:de|d['’])|prohib[[:alpha:]]*|illégal[[:alpha:]]*)#{WORD_END}/i,
                      /#{WORD_START}(?:nicht|kein(?:e|en|em|er|es)?)#{WORD_END}/i, 1, false)
    ].freeze

    module_function

    # question: true for a question, where a rhetorical "n'est-elle pas
    # déjà ...?" is not counted.
    def french(text, question: false)
      sentences(text).sum do |sentence|
        sentence = sentence.gsub(FRENCH_RHETORICAL) { Regexp.last_match[:verb] } if question && sentence.match?(QUESTION_END)
        french_sentence(sentence)
      end
    end

    # question: true for a question, where a rhetorical "nicht schon ...?" is
    # not counted.
    def german(text, question: false)
      return german_count(text) unless question

      sentences(text).sum do |sentence|
        sentence.match?(QUESTION_END) ? german_count(sentence.gsub(GERMAN_RHETORICAL, '')) : german_count(sentence)
      end
    end

    def german_count(text)
      GERMAN.sum { |pattern| text.to_s.scan(pattern).length }
    end

    # The lines of a French text and its German translation whose negations
    # differ beyond the EQUIVALENCES, as [{ line:, french:, german:,
    # french_count:, german_count: }]; empty when they agree. Lines with
    # letters are paired in order; when the two texts have a different number
    # of them, the whole texts are compared instead (line: nil).
    def line_mismatches(french_text, german_text)
      french_lines = text_lines(french_text)
      german_lines = text_lines(german_text)
      pairs = if french_lines.length == german_lines.length
                french_lines.zip(german_lines).each_with_index.map { |(fr, de), index| [index + 1, fr, de] }
              else
                [[nil, french_lines.join("\n"), german_lines.join("\n")]]
              end
      pairs.filter_map do |line, fr, de|
        french_count = french(fr)
        german_count = german(de)
        next if within_equivalences?(fr, de, german_count - french_count) && !exception_added?(fr, de)

        { line: line, french: fr, german: de, french_count: french_count, german_count: german_count }
      end
    end

    GERMAN_EXCEPTION = /#{WORD_START}(?:es\s+sei\s+denn|au(?:ß|ss)er(?!\s*halb)|ausgenommen|mit\s+Ausnahme)#{WORD_END}/i
    # "autres que" also with a noun between (v9 q14: "d'autres coûts que").
    FRENCH_EXCEPTION = /#{WORD_START}(?:sauf|à\s+moins|excepté|hormis|à\s+l['’]exception|autres?\s+(?:[[:alpha:]’'-]+\s+){0,2}qu|
                                      en\s+dehors|si\s+ce\s+n['’]est|sous\s+réserve|à\s+défaut|ne\s+\S+\s+que|n['’]\S+\s+que)|
                       #{FRENCH_EXEMPTION}/xi

    # An exception the German states where the French states none. The
    # counts can agree and the meaning still be inverted: "grant unpaid days
    # ..., not a legal obligation" (2) became "do not grant ..., unless" (2).
    def exception_added?(french_line, german_line)
      german_line.match?(GERMAN_EXCEPTION) && !french_line.match?(FRENCH_EXCEPTION)
    end

    def text_lines(text)
      text.to_s.split("\n").map(&:strip).grep(/[[:alpha:]]/)
    end

    # German answers v5: asked "Kann ich Schuhe, die mir nicht gefallen,
    # zurückgeben?", the question retry made up for a dropped "nicht" by
    # negating the question itself ("pour ne pas me rétracter"), three times.
    # A verbal negation keeps its clause: when the French carries more verbal
    # negations in main clauses than the German does, one has moved out of
    # a relative clause ("die mir nicht gefallen" is "qui ne me plaisent
    # pas"). A German relative-clause negation said without a verb in French
    # ("non conformes", "sans contrat") is not a move. Clauses are cut at
    # commas, semicolons, colons and parentheses; a French relative pronoun
    # that opens the sentence is an interrogative, not a relative.
    GERMAN_RELATIVE_START = /\A\s*(?:der|die|das|den|dem|dessen|deren|denen|welche[rsnm]?|wobei|womit|worauf|wofür|woran|wovon)#{WORD_END}/i
    GERMAN_VERBAL_NEGATION = /#{WORD_START}(?:nicht|kein(?:e|en|em|er|es)?|nie|niemals|nichts|niemand)#{WORD_END}/i
    FRENCH_RELATIVE = /#{WORD_START}(?:qui|que|qu['’]|dont|où|lequel|laquelle|lesquels|lesquelles|auquel|auxquels|auxquelles|
                                     duquel|desquels|desquelles)(?![[:alpha:]])/xi
    CLAUSE_BREAK = /[,;:()]/

    def negation_moved_out_of_relative_clause?(german, french)
      main_clause_negations(french, :fr) > main_clause_negations(german, :de)
    end

    # The verbal negations of a text that sit in a main clause (not a
    # relative one) of a question sentence: a negation moved into a
    # declarative sentence of its own ("Je ne les aime pas.") changes no
    # question.
    def main_clause_negations(text, language)
      sentences(text).sum do |sentence|
        next 0 unless sentence.include?('?')

        offset = 0
        sentence.split(CLAUSE_BREAK).sum do |clause|
          clause_start = offset
          offset += clause.length + 1
          if language == :de
            next 0 if clause.match?(GERMAN_RELATIVE_START)

            clause.scan(GERMAN_VERBAL_NEGATION).length
          else
            ne_spans(clause).count do |from, _to|
              relative = clause[0...from].to_enum(:scan, FRENCH_RELATIVE).map { Regexp.last_match.begin(0) }
              relative.none? { |at| (clause_start + at).positive? || clause[0...at].match?(/[[:alpha:]]/) }
            end
          end
        end
      end
    end

    # The difference the equivalent wordings on the two lines make: each
    # exact pair accounts for its delta, each optional pair for any number of
    # its deltas up to the times both wordings occur, and nothing else may
    # change the count.
    def within_equivalences?(french_line, german_line, difference)
      allowed = [0]
      EQUIVALENCES.each do |equivalence|
        times = [occurrences(equivalence.french, french_line), occurrences(equivalence.german, german_line)].min
        next if times.zero?

        steps = equivalence.exact? ? [times] : (0..times).to_a
        allowed = allowed.flat_map { |base| steps.map { |step| base + (equivalence.delta * step) } }.uniq
      end
      allowed.include?(difference)
    end

    def occurrences(pattern, text)
      pattern.respond_to?(:call) ? pattern.call(text) : text.scan(pattern).length
    end

    def sentences(text)
      text.to_s.split(SENTENCE_BREAK).reject { |sentence| sentence.strip.empty? }
    end

    def french_sentence(sentence)
      covered = ne_spans(sentence)
      inside = ->(offset) { covered.any? { |from, to| offset >= from && offset < to } }
      count = covered.length
      count += offsets(sentence, FRENCH_PAS).count { |offset| !inside.call(offset) }
      count += offsets(sentence, FRENCH_AUCUN).count { |offset| !inside.call(offset) }
      count += 1 if covered.empty? && ni_on_its_own?(sentence)
      count + FRENCH_SIMPLE.sum { |pattern| sentence.scan(pattern).length }
    end

    # "ni ... ni" without "ne" is one negation; the "ni" of "sans X ni Y"
    # belongs to the "sans", which is counted already.
    def ni_on_its_own?(sentence)
      ni = offsets(sentence, FRENCH_NI).first
      return false if ni.nil?

      sans = offsets(sentence, FRENCH_SANS).first
      sans.nil? || sans > ni
    end

    # [from, to] of each "ne" negation, its partner included; "ne ... que"
    # is skipped.
    def ne_spans(sentence)
      sentence.to_enum(:scan, FRENCH_NE).filter_map do
        match = Regexp.last_match
        rest = sentence[match.end(0)..]
        window = rest[/\A(?:\s*\S+){0,#{PARTNER_WINDOW_WORDS}}/].to_s
        partner = window.match(FRENCH_PARTNER)
        next if partner && RESTRICTIVE_PARTNERS.include?(partner[1].downcase)
        next [match.begin(0), match.end(0) + partner.end(0)] if partner

        before = sentence[0...match.begin(0)]
        leading = offsets(before, FRENCH_LEADING_PARTNER).last
        next if leading.nil? && before.match?(FRENCH_EXPLETIVE_CONTEXT)

        [leading || match.begin(0), match.end(0)]
      end
    end

    def offsets(text, pattern)
      text.to_enum(:scan, pattern).map { Regexp.last_match.begin(0) }
    end
  end
end
