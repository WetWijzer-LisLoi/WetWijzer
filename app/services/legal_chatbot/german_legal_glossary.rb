# frozen_string_literal: true

module LegalChatbot
  # The terminology of the official German translations of Belgian law, for
  # German answers v3 (to-do 7.5). Each term is written into the translation
  # prompt as a French -> German pair and then enforced on the model's output
  # (GermanAnswerTranslation#check_failure): when the French prose uses the
  # French term, the German prose must use the German one, and a banned
  # German term (a term of German-German law, next to absent from the Belgian
  # corpus) must never appear. The question translation shows the same pairs
  # the other way round, so the French question uses the term retrieval finds.
  #
  # The graded run of German answers v2 (docs/ops/german-answers-v2-eval-2026-09-29.md)
  # had translations that changed the legal category or claim: "contrat à
  # distance" became an off-premises contract, "indemnité de congé" (pay in
  # lieu of notice) became "Urlaubsabgeltung" (pay for untaken holiday),
  # "agglomération" became "Ballungsraum" instead of "geschlossene Ortschaft",
  # "règlement de travail" became "Betriebsvereinbarung". Faithful answers
  # drifted to German-German terms too (Tarifvertrag, Rücktrittsrecht,
  # Betriebszugehörigkeit, Altersrente, Versicherungsdauer, Mietkaution).
  #
  # Every German term below was counted in the German corpus on production
  # (laws.prod.sqlite3, language_id 3, read-only, FTS MATCH bounded at 400
  # rows, newest first) on 2026-09-29; the count is in each comment ("DE n",
  # 400 meaning at least 400). The French terms are the report's pairs and
  # the most frequent legal terms of the 135 French answers of that run.
  # "licenciement" is left out on purpose: both "Entlassung" (336) and
  # "Kündigung" (400) are Belgian German for it.
  #
  # Only prose is compared: quotations, links, the retrieval notice and the
  # lines the code maps itself are removed from both texts first
  # (GermanAnswerTranslation#prose).
  module GermanLegalGlossary
    Term = Struct.new(:name, :french, :german, :french_pattern, :german_pattern, :banned, :banned_pattern, :banned_unless,
                      :competing_pattern, :question_line, :french_unless, :competing_french, :line_pattern,
                      keyword_init: true)

    START = '(?<![[:alpha:]])'
    FINISH = '(?![[:alpha:]])'

    # question_line: the pair as the question translation's prompt shows it,
    # when the question direction needs other wording than the answer's.
    # competing_pattern: when given, the term counts as missing only when the
    # German names the concept with a competing word; a rephrasing that drops
    # the noun ("Bei einer Kündigung durch den Arbeitgeber" for "pour un
    # travailleur licencié par l'employeur") keeps the meaning.
    # banned_unless: a French pattern that lifts the ban, for a banned word
    # that is the right one for that French ("Schiedsspruch" for a sentence
    # arbitrale).
    # french_unless: a French pattern under which the trigger means something
    # else and the term is not read ("un employé" as the préposé of Art.
    # 6.14 beside a commettant; v8 grader 3, the run's one false alarm).
    # competing_french: the French word that legitimately yields the
    # competing German word, so a line that carries both the term's trigger
    # and that word is not refused by the line check ("signification" beside
    # "notification" on one line, rendered Zustellung and Notifizierung; v8
    # graders 2 and 3, a retry made wrong by the hint).
    # line_pattern: the German pattern the line check reads instead of the
    # term's, when the whole text may satisfy the term with a compound that a
    # line may not ("Gelegenheitsarbeitnehmer" beside an "Angestellte" that
    # stood for "ceux", v11 grader 2).
    def self.term(name, french, german, french_pattern, german_pattern, banned: [], banned_pattern: nil,
                  banned_unless: nil, question_line: nil, competing_pattern: nil, french_unless: nil,
                  competing_french: nil, line_pattern: nil)
      german_regexp = Regexp.new(german_pattern, Regexp::IGNORECASE)
      Term.new(
        name: name, french: french, german: german,
        french_pattern: Regexp.new(french_pattern, Regexp::IGNORECASE),
        german_pattern: german_regexp,
        line_pattern: line_pattern ? Regexp.new(line_pattern, Regexp::IGNORECASE) : german_regexp,
        banned: banned,
        banned_pattern: banned_pattern && Regexp.new(banned_pattern, Regexp::IGNORECASE),
        banned_unless: banned_unless && Regexp.new(banned_unless, Regexp::IGNORECASE),
        competing_pattern: competing_pattern && Regexp.new(competing_pattern),
        question_line: question_line,
        french_unless: french_unless && Regexp.new(french_unless, Regexp::IGNORECASE),
        competing_french: competing_french && Regexp.new(competing_french, Regexp::IGNORECASE)
      ).freeze
    end
    private_class_method :term

    TERMS = [
      # German answers v4 (docs/ops/german-answers-v4-eval-2026-10-04.md): the
      # six wrong legal terms of the 67 served answers and the Federal German
      # slips the faithfulness reader listed, each counted on the
      # German-language articles of the corpus (language_id 3) on 2026-10-04.
      # The terms judged by a competing word are missing only against it.
      # German answers v6 (the v6 section of the same report, the faithfulness
      # reader): the wrong words of the 86 German answers, each counted on the
      # German-language articles on 2026-10-04.
      # DE Inaktivitätstage 76 (2008000527 Art. 52 and 54); Arbeitsunfähigkeit narrows the assimilated days to illness (q06, both runs).
      term('assimilated_inactivity', "jours d'inactivité assimilés", 'gleichgestellte Inaktivitätstage',
           "jours?\\s+d['’]inactivit[eé]|inactivit[eé]\\s+assimil", 'Inaktivit',
           # Only the Belgian noun counts: "gleichgestellt" stood next to the narrowing in v6 q06 run 1.
           competing_pattern: '(?i:arbeitsunf[äa]hig)'),
      # DE bösgläubig 54; "böse Absicht" 0 (q0015).
      term('bad_faith', 'mauvaise foi', 'bösgläubig',
           'mauvaise\\s+foi', 'b[öo]sgl[äa]ubig',
           competing_pattern: '(?i:b[öo]se[rn]?\\s+absicht|arglist)'),
      # DE "bloße Eigentümer" 5; "nackte Eigentümer" 2 (q12).
      term('bare_owner', 'nu-propriétaire', 'bloßer Eigentümer',
           'nue?s?[-\\s]propri[eé]t(?:aires?|[eé])', 'blo(?:ß|ss)e[rnms]?\\s+Eigent',
           competing_pattern: '(?i:nackte[rnms]?\\s+eigent)'),
      # DE Tenor 87; Urteilsformel 0 (q0377).
      term('operative_part', 'dispositif (du jugement)', 'Tenor',
           "dispositif\\s+(?:du|de\\s+la|de\\s+l['’]|d['’]une?)\\s*(?:jugement|arr[eê]t|d[eé]cision|ordonnance)", "#{START}Tenor#{FINISH}",
           competing_pattern: 'Urteilsformel|Entscheidungsformel'),
      # DE Alkohol-Wegfahrsperre 9; Interlock 0 (q21).
      term('alcohol_interlock', 'éthylotest antidémarrage', 'Alkohol-Wegfahrsperre',
           '[eé]thylotests?\\s+anti-?d[eé]marrage|alcolock', 'Wegfahrsperre',
           competing_pattern: 'Interlock'),
      # DE Hausangestellte 46; Haushaltsangestellte 1 (q07).
      term('domestic_worker', 'travailleur domestique', 'Hausangestellte',
           "travailleu(?:r|se)s?\\s+domestiques?|personnel\\s+domestique|#{START}domestiques?#{FINISH}", 'Hausangestellt',
           competing_pattern: 'Haushaltsangestellt|Haushaltshilfe'),
      # German answers v5 (the v5 section of the same report, the faithfulness
      # reader): the wrong legal terms in 19 of 82 served answers, nine of them
      # a single word, each counted on the German-language articles on
      # 2026-10-04 before it went in; judged by a competing word, as above.
      # DE angefangene 44, begonnenen 18; "vollendet" with Jahr 0 (q0016: "par année entamée" became "pro vollendetem Jahr").
      term('started_year', 'année entamée', 'angefangenes Jahr',
           "#{START}entamée?s?#{FINISH}", 'angefangen|begonnen|angebrochen',
           competing_pattern: '(?:vollendete|abgeschlossene|volle)[mnrs]?\\s+(?:Dienst|Kalender)?[Jj]ahr'),
      # DE "unter Vorbehalt der Inventarerrichtung" 44, Inventarerrichtung 74; Vorerbe 0 (q0774: the prior heir of the BGB, unknown to Belgian law).
      term('beneficiary_heir', "héritier bénéficiaire (sous bénéfice d'inventaire)", 'Erbe unter Vorbehalt der Inventarerrichtung',
           "héritiers?\\s+bénéficiaires?|bénéfice\\s+d['’]inventaire", 'Inventarerrichtung',
           competing_pattern: 'Vorerb|Nacherb'),
      # DE Entscheidung 3,860, Urteil 794; Schiedsspruch (30) is the arbitral award (q0377: the disciplinary "sentence" of Art. 462 of the Judicial Code).
      # Urteil and Entscheidung stand in nearly every procedural answer, so the word is banned unless
      # the French speaks of arbitration (sentence arbitrale, arbitre, arbitrage).
      term('judgment_sentence', 'sentence (disciplinaire ou judiciaire, pas la sentence arbitrale)', 'Entscheidung',
           "#{START}sentences?(?!\\s+arbitrale)#{FINISH}", 'Entscheidung|Urteil|Beschluss|Verfügung',
           banned: %w[Schiedsspruch], banned_pattern: 'Schiedsspr', banned_unless: 'arbitr',
           competing_pattern: 'Schiedsspr',
           # In a question, Entscheidung is the plain décision; the pair must not pull "sentence" into the French question.
           question_line: 'Entscheidung -> décision'),
      # DE Haftpflichtversicherung 102; Mietgarantie is the garantie locative (q13: a tenant liability insurance became a rent-guarantee insurance).
      term('tenant_liability', 'responsabilité locative', 'Haftpflicht des Mieters',
           # The general "Haftung des Mieters" (Art. 1733) stands in every fire answer; only the insurance word counts.
           'responsabilité\\s+locative', 'Haftpflicht',
           competing_pattern: 'Mietgarantie|Mietkaution'),
      # DE garantierten 144, garantierte 63; Lohnausfall (8) is the loss, not the pay (q07).
      term('guaranteed_pay', 'salaire garanti', 'garantierter Lohn',
           'salaire\\s+garanti|rémunération\\s+garantie', 'garantiert|Lohngarantie|Gehaltsgarantie|Garantielohn',
           competing_pattern: 'Lohnausfall'),
      # DE Zuwendung 36, "unentgeltliche Zuwendungen" 37; Schenkung (130) alone leaves the legacy out (q20).
      term('gift_or_legacy', 'libéralité', 'unentgeltliche Zuwendung',
           "#{START}libéralités?#{FINISH}", 'Zuwendung|Schenkungen?\\s+(?:und|oder)\\s+Vermächtnis',
           competing_pattern: "#{START}Schenkung"),
      # DE "wirtschaftlichen Gründen" 31; "betriebsbedingte Kündigung" 0 (q1083).
      term('economic_dismissal', 'licenciement économique', 'Entlassung aus wirtschaftlichen Gründen',
           'licenciements?\\s+(?:économiques?|pour\\s+(?:motifs?|raisons?)\\s+économiques?)', 'wirtschaftlich',
           competing_pattern: 'betriebsbedingt'),
      # DE Unterhalt 276 (Unterhaltsgeld 3); Unterhaltsrente 0 (q0774).
      term('maintenance', 'pension alimentaire', 'Unterhalt',
           'pensions?\\s+alimentaires?', "#{START}Unterhalt(?!srente)",
           competing_pattern: "Unterhaltsrente|#{START}Renten?#{FINISH}"),
      # DE Ladungsfrist 6; Einlassungsfrist 0 (q0377: "délai de comparution en appel").
      term('summons_period', 'délai de citation (de comparution)', 'Ladungsfrist',
           'délais?\\s+de\\s+(?:citation|comparution)', 'Ladungsfrist',
           competing_pattern: 'Einlassungsfrist'),
      # DE Ratskammer 165; Untersuchungsrichter (356) is the juge d'instruction, another organ.
      term('council_chamber', 'chambre du conseil', 'Ratskammer',
           'chambres?\\s+du\\s+conseil', 'Ratskammer',
           competing_pattern: 'Untersuchungsrichter|Beratungskammer|Beratungszimmer'),
      # DE Beschuldigte 117 and Beschuldigter 9; Angeklagte (163) is the accusé before the trial court.
      term('accused_person', 'inculpé', 'Beschuldigter',
           "#{START}inculpée?s?#{FINISH}", 'Beschuldigte',
           competing_pattern: 'Angeklagte|Angeschuldigte|Verdächtige'),
      # DE 33; Strafprozessordnung 3.
      term('criminal_procedure_code', "Code d'instruction criminelle", 'Strafprozessgesetzbuch',
           "Code\\s+d['’]instruction\\s+criminelle", 'Strafprozessgesetzbuch',
           banned: %w[Strafprozessordnung], banned_pattern: 'Strafprozessordnung'),
      # DE 1012; Gerichtsschreiber 0.
      term('registry', 'greffe', 'Kanzlei',
           "#{START}greffes?#{FINISH}", 'Kanzlei',
           competing_pattern: 'Gerichtsschreiber|Geschäftsstelle'),
      # DE 1716; Zustellung (420) is the signification by bailiff, Benachrichtigung (137) a mere notice.
      # v8 graders 2 and 3: Zustellung is right for the signification on the same line (Art. 1051 DE: "ab
      # Zustellung des Urteils oder ab dessen Notifizierung").
      term('notification', 'notification', 'Notifizierung',
           "#{START}notifi(?:cation|cations|é|ée|és|ées|er)#{FINISH}", 'notifizier',
           competing_pattern: 'Zustellung|zugestellt|Benachrichtigung|benachrichtigt',
           competing_french: 'signifi(?:cation|cations|é|ée|és|ées|er)'),
      # DE 803; Staatsanwalt 59, and the Staatsanwaltschaft is the parquet.
      term('crown_prosecutor', 'procureur du Roi', 'Prokurator des Königs',
           'procureurs?\\s+du\\s+Roi', 'Prokurator',
           competing_pattern: "#{START}Staatsanw[aä]lt(?!schaft)"),
      # DE 32.
      term('bankruptcy_judge', 'juge-commissaire', 'Konkursrichter',
           'juges?[-\\s]commissaires?', 'Konkursrichter'),
      # DE 218; Insolvenz (61) is the umbrella term of Book XX, insolvabilité.
      term('bankruptcy', 'faillite', 'Konkurs',
           "#{START}faillites?#{FINISH}", 'Konkurs',
           competing_pattern: 'Insolvenz'),
      # DE Unterbrechung 262 (der Verjährung 9); Hemmung (7) is the suspension, after which the period resumes.
      term('interruption', 'interruption (de la prescription)', 'Unterbrechung',
           "#{START}interr(?:uption|uptions|ompue?s?|ompt|ompent)#{FINISH}(?!\\s+(?:de\\s+|du\\s+)?(?:travail|carrière|service))",
           'Unterbrech|unterbrich|unterbroch',
           competing_pattern: 'Hemmung|gehemmt|hemmt'),
      # DE 106.
      term('walloon_government_decree', 'arrêté du Gouvernement wallon', 'Erlass der Wallonischen Regierung',
           'arrêtés?\\s+du\\s+Gouvernement\\s+wallon', 'Erlass(?:es|e)?\\s+der\\s+Wallonischen\\s+Regierung',
           competing_pattern: 'Königlich\\w*\\s+Erlass|Erlass\\w*\\s+der\\s+Wallonischen\\s+Region'),
      # DE Ruhestandspension 316, Pensionsalter 87; Rente (135) is an annuity (Leibrente, Unfallrente).
      term('pension', 'pension (de retraite)', 'Pension',
           "#{START}pensions?(?!\\s+alimentaire)#{FINISH}", 'pension',
           competing_pattern: "#{START}Renten?#{FINISH}|Rentenalter|Altersrente|Rentner"),
      # DE föderal 23; bundesweit 0.
      term('federal', 'fédéral', 'föderal',
           "#{START}fédéra(?:l|le|ux|les)#{FINISH}", 'föderal',
           banned: %w[bundesweit Bundesregierung], banned_pattern: "#{START}(?:bundesweit|Bundesregierung|Bundesgesetz)"),
      # DE 400 (359 of the 400 oldest hits); Tarifvertrag 5, Kollektivvertrag 2, Kollektivarbeitsvertrag 0.
      term('collective_agreement', 'convention collective de travail (CCT)', 'kollektives Arbeitsabkommen (KAA)',
           "#{START}(?:CCT|conventions?\\s+collectives?(?:\\s+de\\s+travail)?)#{FINISH}",
           "kollektive[mnrs]?\\s+Arbeitsabkommen|#{START}KAA#{FINISH}",
           banned: %w[Tarifvertrag Kollektivvertrag Kollektivarbeitsvertrag],
           banned_pattern: 'Tarifvertr[aä]g|Kollektiv(?:arbeits)?vertr[aä]g'),
      # DE 170; Betriebsvereinbarung 0, Arbeitsreglement 0, Betriebsordnung 0.
      term('work_rules', 'règlement de travail', 'Arbeitsordnung',
           'règlements?\\s+de\\s+travail', 'Arbeitsordnung',
           banned: %w[Betriebsvereinbarung Arbeitsreglement Betriebsordnung],
           banned_pattern: 'Betriebsvereinbarung|Arbeitsreglement|Betriebsordnung'),
      # DE 41; Rücktrittsrecht 3.
      # v5 q0301: "se rétracter" became "zurücktreten" (the Rücktritt family) in a text without any Widerruf.
      term('withdrawal', 'droit de rétractation', 'Widerrufsrecht',
           'rétractation|rétracter', 'Widerruf',
           banned: %w[Rücktrittsrecht], banned_pattern: 'Rücktrittsrecht',
           competing_pattern: 'zurücktret|zurückzutret|Rücktritt'),
      # DE 400.
      term('consumer', 'consommateur', 'Verbraucher',
           "#{START}consommat(?:eur|eurs|rice|rices)#{FINISH}", 'Verbraucher'),
      # DE 30.
      term('distance_contract', 'contrat à distance', 'Fernabsatzvertrag',
           'contrats?\\s+(?:conclus?\\s+)?à\\s+distance', 'Fernabsatz'),
      # DE 8 ("außerhalb von Geschäftsräumen geschlossener Vertrag").
      term('off_premises_contract', 'contrat hors établissement', 'außerhalb von Geschäftsräumen geschlossener Vertrag',
           'hors\\s+établissement', 'außerhalb\\s+(?:von|der)\\s+Geschäftsräum'),
      # DE 14; Ballungsraum or Ballungsgebiet 1.
      term('built_up_area', 'agglomération', 'geschlossene Ortschaft',
           "#{START}agglomérations?#{FINISH}", 'geschlossene[nr]?\\s+Ortschaft',
           banned: %w[Ballungsraum Ballungsgebiet], banned_pattern: 'Ballungsr[aä]um|Ballungsgebiet'),
      # DE 3, and "Entschädigung" in Art. 39 of the German coordination
      # 2008000527; Urlaubsabgeltung 0, Urlaubsentschädigung 0.
      # In the question direction (v4) the pair is "indemnité compensatoire
      # de préavis": in ordinary French "congé" is also holiday, and the v3
      # question "welche Abfindung steht mir zu" rendered "quelle indemnité de
      # congé" pulled the annual-holidays decree (1967033001) on both paths.
      term('notice_pay', 'indemnité de congé (indemnité compensatoire de préavis)', 'Kündigungsentschädigung',
           'indemnités?\\s+(?:compensatoires?\\s+)?de\\s+(?:congé|préavis)',
           "Kündigungsentschädigung|#{START}Entschädigung",
           banned: %w[Urlaubsabgeltung Urlaubsentschädigung], banned_pattern: 'Urlaubsabgeltung|Urlaubsentschädigung',
           question_line: 'Kündigungsentschädigung, Abfindung -> indemnité compensatoire de préavis'),
      # DE 348.
      term('notice_period', 'délai de préavis', 'Kündigungsfrist',
           'délais?\\s+de\\s+préavis', 'Kündigungsfrist'),
      # DE 400; Betriebszugehörigkeit 3.
      # v8 graders 2 and 3: Dienstzeit (DE 91 against Dienstalter 394) was refused twice for a right meaning;
      # it counts.
      term('seniority', 'ancienneté', 'Dienstalter',
           "#{START}ancienneté", 'Dienstalter|Dienstjahr|Dienstzeit',
           banned: %w[Betriebszugehörigkeit], banned_pattern: 'Betriebszugehörigkeit'),
      # DE 400 each.
      # v11 grader 2 (q06): "travailleurs occasionnels ou ceux relevant de ..." became
      # "Gelegenheitsarbeitnehmer oder Angestellte, die ...", and the compound satisfied the line check
      # for the "Angestellte" that stood for "ceux". A compound keeps the whole-text term (a
      # Teilzeitarbeitnehmer is a travailleur à temps partiel); on a line that also carries a competing
      # word, only the bare word does.
      term('worker', 'travailleur', 'Arbeitnehmer',
           "#{START}travailleu(?:r|rs|se|ses)#{FINISH}(?!\\s+(?:indépendant|autonome))", 'Arbeitnehmer',
           competing_pattern: "#{START}(?:Angestellte|Arbeiter(?!nehmer)|Beschäftigte|Mitarbeiter)",
           line_pattern: "#{START}Arbeitnehmer"),
      # v4 q06, q07: "pour un employé" became "für einen Arbeitnehmer", the
      # status the rule attaches to widened; the question direction had the
      # pair, the answer direction did not. Missing only against a competing
      # status word: "employé" is also a participle ("le délai employé").
      # v8 grader 3: "un employé" beside a commettant is the préposé of Art. 6.14 (liability for others),
      # not the white-collar status; the term is not read in that context. The competing Arbeitnehmer is
      # right where the same line says travailleur.
      term('white_collar', 'employé', 'Angestellter', "#{START}employée?s?#{FINISH}", 'Angestellte',
           competing_pattern: "#{START}(?:Arbeitnehmer|Arbeiter(?!nehmer)|Beschäftigte|Mitarbeiter)",
           french_unless: 'préposé|commettant', competing_french: "#{START}travailleu(?:r|rs|se|ses)#{FINISH}"),
      term('employer', 'employeur', 'Arbeitgeber',
           "#{START}employeurs?#{FINISH}", 'Arbeitgeber'),
      term('employment_contract', 'contrat de travail', 'Arbeitsvertrag',
           'contrats?\\s+de\\s+travail', 'Arbeitsvertr'),
      # DE 244; Sozialstrafkodex 0.
      term('social_penal_code', 'Code pénal social', 'Sozialstrafgesetzbuch',
           'Code\\s+pénal\\s+social', 'Sozialstrafgesetzbuch',
           banned: %w[Sozialstrafkodex], banned_pattern: 'Sozialstrafkodex'),
      # DE 400; Bürgerliches Gesetzbuch 0.
      term('civil_code', 'Code civil', 'Zivilgesetzbuch',
           'Code\\s+civil', 'Zivilgesetzbuch',
           banned: ['Bürgerliches Gesetzbuch'], banned_pattern: 'Bürgerliche[mns]?\\s+Gesetzbuch'),
      # DE 400.
      term('judicial_code', 'Code judiciaire', 'Gerichtsgesetzbuch',
           'Code\\s+judiciaire', 'Gerichtsgesetzbuch'),
      # DE 400.
      term('economic_code', 'Code de droit économique', 'Wirtschaftsgesetzbuch',
           'Code\\s+de\\s+droit\\s+économique', 'Wirtschaftsgesetzbuch'),
      # DE 347.
      term('companies_code', 'Code des sociétés et des associations', 'Gesetzbuch der Gesellschaften und Vereinigungen',
           'Code\\s+des\\s+sociétés\\s+et\\s+des\\s+associations',
           'Gesetzbuch(?:e?s)?\\s+der\\s+Gesellschaften\\s+und\\s+Vereinigungen'),
      # DE 400.
      term('royal_decree', 'arrêté royal', 'Königlicher Erlass',
           'arrêtés?\\s+roya(?:l|ux)', 'Königliche[mnrs]?\\s+Erlass'),
      # DE 400.
      term('official_journal', 'Moniteur belge', 'Belgisches Staatsblatt',
           'Moniteur\\s+belge', 'Staatsblatt'),
      # DE 26 ("Pflichtteil", "Pflichtteilserben").
      term('forced_share', 'réserve héréditaire', 'Pflichtteil',
           'réserves?\\s+héréditaires?', 'Pflichtteil'),
      # DE 19 ("frei verfügbarer Teil").
      term('disposable_share', 'quotité disponible', 'frei verfügbarer Teil',
           'quotités?\\s+disponibles?', 'verfügbare[mnr]?\\s+(?:Teil|Quote)'),
      # DE 400; Versicherungsdauer 0.
      # v5 q11: "43 années de carrière" became "43 Dienstjahren" (seniority with one employer)
      # while "Laufbahn" stood elsewhere in the text; the check reads the whole text, so that
      # row still passes, and a text that renders every "carrière" by Dienstjahre is refused.
      term('career', 'carrière', 'Laufbahn',
           "#{START}carrières?#{FINISH}", 'Laufbahn',
           banned: %w[Versicherungsdauer], banned_pattern: 'Versicherungsdauer',
           competing_pattern: 'Dienstjahr|Dienstalter'),
      # DE 384; Altersrente 15.
      term('retirement_pension', 'pension de retraite', 'Ruhestandspension',
           'pensions?\\s+de\\s+retraite', "Ruhestandspension|#{START}Pension"),
      # DE 116. Anchored (v4): "l'âge légal de la pension anticipée" is the
      # early-retirement age, which Belgian German writes without
      # "Pensionsalter" ("Alter für die vorzeitige Pension"); v3 refused a
      # faithful q11 on it.
      term('pension_age', 'âge légal de la pension', 'gesetzliches Pensionsalter',
           'âge\\s+(?:légal\\s+)?de\\s+(?:la\\s+)?pension(?!\\s+anticipée)', 'Pensionsalter'),
      # DE 15.
      term('birth_leave', 'congé de naissance', 'Geburtsurlaub',
           'congés?\\s+de\\s+naissance', 'Geburtsurlaub'),
      # DE 174.
      term('maternity_leave', 'congé de maternité', 'Mutterschaftsurlaub',
           'congés?\\s+de\\s+maternité', 'Mutterschaftsurlaub'),
      # DE 400.
      term('trial_period', "période d'essai", 'Probezeit',
           "périodes?\\s+d['’]essai", 'Probezeit'),
      # DE 400.
      term('joint_committee', 'commission paritaire', 'paritätische Kommission',
           'commissions?\\s+paritaires?', 'paritätische[nr]?\\s+Kommission'),
      # DE 47.
      term('serious_cause', 'motif grave', 'schwerwiegender Grund',
           'motifs?\\s+graves?', 'schwerwiegende[mnrs]?\\s+Gr(?:u|ü)nd'),
      # DE 249.
      term('incapacity', 'incapacité de travail', 'Arbeitsunfähigkeit',
           'incapacités?\\s+de\\s+travail', 'arbeitsunfähig'),
      # DE 32. German answers v7, graders 2 and 3 (q15 r1): "Mangel an Vertragsmäßigkeit" (Vertragsmäßigkeit
      # is a corpus word, 2023046874) rendered the term faithfully and was refused as missing; the retry
      # then put the demanded noun into that phrase and served "ein Mangel an Vertragswidrigkeit" (a lack
      # of non-conformity), the opposite of the French. The faithful phrase counts, the compound is banned.
      # v8, grader 3: the synonym in its plural ("Mängel der Vertragsmäßigkeit") and as "Mangel an
      # Vertragsgemäßheit" were refused and retried; both count.
      term('non_conformity', 'défaut de conformité', 'Vertragswidrigkeit',
           'défauts?\\s+de\\s+conformité',
           'vertragswidrig|M(?:ä|ae|a)ngel[sn]?\\s+(?:an|der|in)\\s+(?:der\\s+)?Vertrags(?:m(?:ä|ae)(?:ß|ss)igkeit|gem(?:ä|ae)(?:ß|ss)heit)',
           banned: ['Mangel an Vertragswidrigkeit'], banned_pattern: 'Mangel\\s+an\\s+(?:der\\s+)?Vertragswidrigkeit'),
      # German answers v7, grader 2 (q0774): "décision définitive" (Art. 2244 of the old Civil Code, the end of an
      # interruption) became "rechtskräftig"; the corpus says Endentscheidung (DE 70). Rechtskräftig is right for
      # "passée en force de chose jugée", so it competes only where the French says décision définitive.
      term('final_decision', 'décision définitive', 'Endentscheidung',
           'décisions?\\s+définitives?', 'Endentscheidung', competing_pattern: 'rechtskräftig'),
      # German answers v7, grader 2 (q0774): "citation en justice" became "Klagezustellung" (DE 0); the corpus
      # says Ladung vor Gericht (DE 9).
      term('court_summons', 'citation en justice', 'Ladung vor Gericht',
           'citations?\\s+en\\s+justice', 'Ladung(?:en)?\\s+vor\\s+(?:das\\s+|dem\\s+)?Gericht|gerichtliche[nr]?\\s+Ladung',
           competing_pattern: 'Klagezustellung'),
      # DE 177.
      term('holiday_pay', 'pécule de vacances', 'Urlaubsgeld',
           'pécules?\\s+de\\s+vacances', 'Urlaubsgeld'),
      # DE 342.
      term('force_majeure', 'force majeure', 'höhere Gewalt',
           'force\\s+majeure', 'höhere[nr]?\\s+Gewalt'),
      # DE 140.
      # DE Inverzugsetzung 135; Mahnung (91) and Anmahnung (34) are reminders, which interrupt no
      # limitation period (v5 q0774: "L'interpellation faite à l'un des débiteurs solidaires", Art.
      # 2249 of the old Civil Code, whose German text in 2012000690 says Inverzugsetzung).
      # v9 grader 2 (q0774): "Aufforderung" for the interpellation of Art. 2249, a competing word now.
      term('formal_notice', 'mise en demeure (interpellation)', 'Inverzugsetzung',
           "mises?\\s+en\\s+demeure|#{START}interpellations?#{FINISH}", 'Inverzugsetzung|in\\s+Verzug\\s+(?:ge)?setz',
           competing_pattern: "#{START}(?:(?:An)?[Mm]ahnung|Aufforderung)"),
      # DE 80.
      term('agency_worker', 'travailleur intérimaire', 'Leiharbeitnehmer',
           'travailleurs?\\s+intérimaires?', 'Leiharbeitnehmer'),
      # DE 12.
      term('single_status', 'statut unique', 'Einheitsstatut',
           'statut\\s+unique', 'Einheitsstatut'),
      # DE 5; Mietkaution 1.
      term('rent_deposit', 'garantie locative', 'Mietgarantie',
           'garanties?\\s+locatives?', 'Mietgarantie',
           banned: %w[Mietkaution], banned_pattern: 'Mietkaution'),
      # DE 132 and 61.
      # v11 grader 2 (q13): "Pächter" (the lessee of farmland, the preneur of a bail à ferme) five
      # times for the preneur of a dwelling, which lease law names beside the locataire; the word is
      # banned unless the French is about a farm lease. Not the preneur d'assurance (the
      # Versicherungsnehmer) nor the preneur de licence or de leasing.
      term('tenant', 'locataire (preneur)', 'Mieter',
           "#{START}(?:locataires?|preneu(?:r|rs|se|ses)(?!\\s+(?:d['’]assurance|de\\s+(?:licence|leasing|crédit))))#{FINISH}",
           "#{START}Mieter",
           banned: %w[Pächter], banned_pattern: "#{START}P[äa]chter",
           banned_unless: 'bail\\s+à\\s+ferme|fermage|agricole|bail\\s+rural|fermier',
           french_unless: 'bail\\s+à\\s+ferme|fermage|agricole|bail\\s+rural|fermier'),
      term('landlord', 'bailleur', 'Vermieter',
           "#{START}bailleurs?#{FINISH}", 'Vermieter'),
      # DE 400. The singular after an article or "délai de", or the verb:
      # "les prescriptions" are rules ("Vorschriften"), not limitation; and
      # never the prescription acquisitive, which is Ersitzung (the run after
      # round 11, 2026-10-06, q0015: the term made a retry turn a right
      # "Ersitzungsfrist" into "Verjährungsfrist", and it was served).
      term('limitation', 'prescription (extinctive)', 'Verjährung',
           "(?:délais?\\s+de|#{START}(?:la|une|cette|sa|leur|de))\\s+prescription#{FINISH}(?!\\s+acquisitive)|" \
           "se\\s+prescri(?:t|vent)#{FINISH}|(?:est|sont)\\s+prescrite?s?#{FINISH}",
           'verjähr'),
      # The prescription acquisitive is Ersitzung in the German Civil Code
      # (2022020363, Art. 3.26 and 3.27: "Ersitzungsfristen", "Die
      # Ersitzungsfrist beträgt zehn Jahre"); a Verjährung beside it is the
      # extinctive prescription, right only where the French line names that
      # one too.
      term('acquisitive_prescription', 'prescription acquisitive', 'Ersitzung',
           "prescription\\s+acquisitive|#{START}usucapion#{FINISH}", 'ersitz',
           competing_pattern: '[Vv]erjähr',
           competing_french: "extinctive|prescription#{FINISH}(?!\\s+acquisitive)|#{START}(?:se\\s+)?prescri(?:t|vent)#{FINISH}"),
      # DE 400.
      # v5 q0377: "interjeter appel" became "Einlegung eines Rechtsmittels" (any remedy; cassation
      # has three months); Einspruch is the opposition, Revision the Federal German appeal on law.
      term('appeal', 'interjeter appel', 'Berufung einlegen',
           "interjeter\\s+appel|appel\\s+interjeté|délais?\\s+d['’]appel", 'Berufung',
           competing_pattern: 'Rechtsmittel|Einspruch|Revision'),
      # DE 370.
      term('labour_court', 'tribunal du travail', 'Arbeitsgericht',
           'tribuna(?:l|ux)\\s+du\\s+travail', 'Arbeitsgericht'),
      # DE 400.
      term('fine', 'amende', 'Geldbuße',
           "#{START}amendes?#{FINISH}", 'Geldbu(?:ß|ss)e'),
      # DE 167.
      # v8 grader 2: "Fahrerlaubnis" (the Federal word) beside the kept Führerschein; a competing word now.
      term('driving_licence', 'permis de conduire', 'Führerschein',
           'permis\\s+de\\s+conduire', 'Führerschein', competing_pattern: 'Fahrerlaubnis'),
      # v8 grader 2 (q0774): "recours en annulation" became "Anfechtungsklage" (DE 6); the corpus says
      # Nichtigkeitsklage (DE 158).
      term('annulment_action', 'recours en annulation', 'Nichtigkeitsklage',
           'recours\\s+en\\s+annulation', 'Nichtigkeitsklage', competing_pattern: 'Anfechtungsklage'),
      # v9 grader 2 (q0409): "Ordnungswidrigkeit" (DE 2, the Federal administrative offence) for an infraction;
      # the corpus says Verstoß (400 and more) and Vergehen (216).
      term('offence', 'infraction', 'Verstoß',
           "#{START}infractions?#{FINISH}", 'Versto(?:ß|ss)|Vergehen|Straftat|Zuwiderhandlung|Übertretung',
           competing_pattern: 'Ordnungswidrigkeit'),
      # v9 grader 2: "Einsprache" (DE 0, the Swiss word) for the opposition against a default judgment; the
      # corpus says Einspruch (DE 400).
      term('opposition', 'opposition (contre un jugement par défaut)', 'Einspruch',
           "#{START}oppositions?#{FINISH}", 'Einspruch|Einsprüche', competing_pattern: 'Einsprache|Widerspruch'),
      # DE 400 each.
      term('walloon_region', 'Région wallonne', 'Wallonische Region',
           'Région\\s+wallonne', 'Wallonische[nr]?\\s+Region'),
      term('german_community', 'Communauté germanophone', 'Deutschsprachige Gemeinschaft',
           'Communauté\\s+germanophone', 'Deutschsprachige[nr]?\\s+Gemeinschaft'),
      # DE 41.
      term('limited_liability_company', 'société à responsabilité limitée (SRL)', 'Gesellschaft mit beschränkter Haftung',
           # v5 q16: the term misdeclined ("mit beschränkten Haftung") is the term, not a missing one.
           'sociétés?\\s+à\\s+responsabilité\\s+limitée', 'Gesellschaft(?:en)?\\s+mit\\s+beschränkte[rn]\\s+Haftung|GmbH'),
      # German answers v4: the terms the served v3 translations got wrong
      # (docs/ops/german-answers-v3-eval-2026-09-29.md), counted on production
      # on 2026-09-29 like the rest (German rows among the first 400 hits;
      # "und OR wird" added to the MATCH of words other languages share).
      # q0841: "autocars" became "Omnibusse", which extends the coach limit of
      # Art. 11.2 1° a) (1975120109) to every bus. Reisebus DE 11, Linienbus
      # DE 3, both in "Kleinbusse, Linienbusse und Reisebusse" (2008000945 Art.
      # 54) and the joint sub-committee for "Linienbusse und Reisebusse" (PUK
      # 140.01, the French "autobus et autocars"); Omnibus DE 2, Autobus DE 5.
      term('coach', 'autocar', 'Reisebus', "#{START}autocars?#{FINISH}", 'Reisebus'),
      # "Busse" or "Autobus" for autobus is the same vehicle (Autobus DE 5):
      # accepted, Linienbus stays the prompt's term; Reisebus for autocar
      # stays required, since a bare "Bus" would extend the coach limit.
      term('city_bus', 'autobus', 'Linienbus', "#{START}autobus#{FINISH}", "Linienbus|Autobus|#{START}Busse?#{FINISH}"),
      # q09: "cohabitez légalement" became "rechtmäßig zusammenleben" (DE 0),
      # which widens declared legal cohabitation to any lawful living
      # together. DE 223 ("gesetzlich Zusammenwohnende", 2009000664).
      # v10 grader 3 (q09): "gesetzlich oder in dauerhafter und gefühlsmäßiger Weise mit der Mutter (oder
      # dem Elternteil) des Kindes zusammenwohnen" was refused for the words between; a coordination after
      # "gesetzlich" may carry up to fifteen words, commas and parentheses before the "zusammen" (a bare
      # "gesetzlich" elsewhere in the sentence is not the term).
      term('legal_cohabitation', 'cohabitation légale', 'gesetzliches Zusammenwohnen',
           'cohabitation\\s+légale|cohabitante?s?\\s+léga(?:l|le|les|ux)|' \
           'cohabit(?:e|es|ez|ent|ons|er|ant|ants|é|ée|és)\\s+légalement',
           'gesetzlich[[:alpha:]]*(?:\\s+(?:oder|und|bzw\\.?|,|sowie)(?:\\s+[[:alpha:],()]+){0,15})?\\s+zusammen'),
      # v10 graders 2 and 3 (q0301): "Rücktrittsformular" (DE 0) and "Muster für die Widerrufsbelehrung" for the
      # formulaire de rétractation; the corpus says Widerrufsformular (DE 8), and the withdrawal pair's hint
      # ("write Widerrufsrecht") did not fit a form.
      term('withdrawal_form', 'formulaire de rétractation', 'Widerrufsformular',
           'formulaires?\\s+de\\s+rétractation', 'Widerrufsformular',
           competing_pattern: 'Rücktrittsformular|Widerrufsbelehrung'),
      # q19: in the instruments of Art. 2274, "compte arrêté" became
      # "abgerechnete Rechnung" (DE 0) and "cédule" "Schuldverschreibung" (a
      # bond, DE 71). Art. 2274 of the German coordination (2012000690) says
      # "Rechnungsabschluss" (DE 6) and "Schuldschein" (DE 8).
      term('settled_account', 'compte arrêté', 'Rechnungsabschluss',
           'comptes?\\s+arrêtés?', 'Rechnungsabschl'),
      term('promissory_note', 'cédule', 'Schuldschein',
           "#{START}cédules?#{FINISH}", 'Schuldschein'),
      # q0377 t1 drifted to "Berufungsgericht" (DE 26, left allowed).
      # Appellationshof DE 400; Appellationsgericht DE 0.
      term('court_of_appeal', "cour d'appel", 'Appellationshof',
           "cours?\\s+d['’]appel", 'Appellationsh[oö]f'),
      # q0774's refused German rendered "commandement" as "Mahnung", a
      # reminder that interrupts no limitation period; Art. 2244 of the German
      # coordination (2012000690) says "Zahlungsbefehl" (DE 92). Mahnung DE 98
      # in other senses, so it is not banned.
      term('payment_order', 'commandement', 'Zahlungsbefehl',
           "#{START}commandements?#{FINISH}", 'Zahlungsbefehl')
    ].freeze

    # German words a reader types that no answer translation needs: shown in
    # the question translation's prompt only (German -> French), so that the
    # French question names what the guards and retrieval read. Counted on
    # production on 2026-09-29 like the terms above.
    QUESTION_ONLY_PAIRS = [
      # DE 58: the Community's own everyday name. FR "Communauté germanophone"
      # 392 of 400; "Cantons de l'Est" (FR 45) is a territory, and names no
      # Community the regional guards know (RegionalSearch).
      ['Ostbelgien', 'Communauté germanophone'],
      # DE 40; FR "allocations familiales" 387 of 400, the term of the
      # regional guards (RegionalSearch::UNSUPPORTED_CORPUS_SUBJECT_PATTERN).
      ['Kindergeld', 'allocations familiales'],
      # German answers v6, grader 1: "krankgeschrieben" became "en arrêt de
      # travail", which the guaranteed-pay topic and its pin did not know. v7,
      # grader 3: a gloss "(avec certificat médical)" on this line leaked
      # verbatim into the four served q07 questions, so the pair is bare.
      ['krankgeschrieben', 'en incapacité de travail'],
      # German answers v4 (the graded v3 run): the status and the remedy a
      # question names select the rule, and v3 lost them. "Angestellter"
      # became "travailleur" (q06, q07), which drops the employé's regime
      # (Art. 38 of 1967033001, Art. 70 of 1978070303), and "Einspruch gegen
      # ein Versäumnisurteil" became "recours" (q0377 t2), which broadens
      # the opposition of Art. 1047-1048 (1967101055) to any remedy.
      # Counted on production on 2026-09-29: Angestellte DE 400, Arbeiter DE
      # 185, Einspruch DE 400, Versäumnisurteil DE 21 ("Der Einspruch gegen
      # das Versäumnisurteil", 2014000097 Art. 151). In the question
      # direction the notice indemnity (Abfindung DE 12,
      # Kündigungsentschädigung DE 3) is "indemnité compensatoire de
      # préavis" (FR 24), not "indemnité de congé" (FR 97, which is also
      # holiday pay in ordinary French).
      ['Angestellter (Angestellte)', 'employé (employée)'],
      ['Arbeiter (Arbeiterin)', 'ouvrier (ouvrière)'],
      ['Einspruch (gegen ein Versäumnisurteil)', 'opposition'],
      ['Versäumnisurteil', 'jugement par défaut'],
      # The graded v4 run (2026-10-04): Vaterschaftsurlaub DE 25 next to
      # Geburtsurlaub DE 11, and the term of Art. 30 of 1978070303 is "congé
      # de naissance"; Landstraße DE 0 (the traffic code says "außerhalb
      # geschlossener Ortschaften", FR "hors agglomération"); "erlöschende
      # Verjährung" DE 0, the French legal term is "prescription extinctive".
      ['Vaterschaftsurlaub', 'congé de naissance'],
      ['Landstraße (außerhalb geschlossener Ortschaften)', 'hors agglomération'],
      ['erlöschende Verjährung', 'prescription extinctive']
    ].map(&:freeze).freeze

    # The pairs the French question must keep (v4): when the German question
    # names the one, the French question names the other, or the translation
    # is refused (GermanQuestionTranslation#check_failures). Only terms that
    # select a rule: a worker's status, the employer, the remedy, the notice
    # indemnity. Case-sensitive on the German side, where these are nouns:
    # "ich bin angestellt" names no status.
    QuestionTerm = Struct.new(:name, :german_label, :french_label, :german_pattern, :french_pattern, keyword_init: true)
    QUESTION_TERMS = [
      QuestionTerm.new(name: 'white_collar', german_label: 'Angestellter', french_label: 'employé',
                       german_pattern: /#{START}Angestellte[mnrs]?#{FINISH}/,
                       french_pattern: /#{START}employée?s?#{FINISH}/i),
      QuestionTerm.new(name: 'blue_collar', german_label: 'Arbeiter', french_label: 'ouvrier',
                       german_pattern: /#{START}Arbeiter(?:in|innen|n|s)?#{FINISH}/,
                       french_pattern: /#{START}ouvri(?:er|ère)s?#{FINISH}/i),
      QuestionTerm.new(name: 'worker', german_label: 'Arbeitnehmer', french_label: 'travailleur',
                       german_pattern: /#{START}Arbeitnehmer(?:in|innen|n|s)?#{FINISH}/,
                       french_pattern: /#{START}(?:travailleu(?:r|se)s?|salariée?s?)#{FINISH}/i),
      QuestionTerm.new(name: 'employer', german_label: 'Arbeitgeber', french_label: 'employeur',
                       german_pattern: /#{START}Arbeitgeber(?:in|innen|n|s)?#{FINISH}/,
                       french_pattern: /#{START}employeu(?:r|se)s?#{FINISH}/i),
      QuestionTerm.new(name: 'default_opposition', german_label: 'Einspruch (gegen ein Versäumnisurteil)',
                       french_label: 'opposition',
                       german_pattern: /\A(?=.*#{START}Einspruch)(?=.*Versäumnis)/m,
                       french_pattern: /#{START}opposition#{FINISH}/i),
      QuestionTerm.new(name: 'notice_pay', german_label: 'Abfindung, Kündigungsentschädigung',
                       french_label: 'indemnité compensatoire de préavis',
                       german_pattern: /\A(?=.*(?:Abfindung|Kündigungsentschädigung))(?=.*(?:kündig|entlass|Arbeit))/im,
                       french_pattern: /indemnités?\s+(?:compensatoires?\s+)?de\s+préavis/i),
      # v4: "congé de paternité" is the term before 2021 and pulls the old
      # wording; "Landstraße" rendered "route nationale" or "route de
      # campagne" misses the speed rule, which is by built-up area.
      QuestionTerm.new(name: 'birth_leave', german_label: 'Vaterschaftsurlaub, Geburtsurlaub',
                       french_label: 'congé de naissance',
                       german_pattern: /#{START}(?:Vaterschafts|Geburts)urlaub/,
                       french_pattern: /cong[eé]s?\s+de\s+naissance/i),
      QuestionTerm.new(name: 'rural_road', german_label: 'Landstraße', french_label: 'hors agglomération',
                       german_pattern: /#{START}Landstra(?:ß|ss)en?#{FINISH}/,
                       french_pattern: /hors\s+(?:d['’])?agglomération/i),
      QuestionTerm.new(name: 'extinctive_prescription', german_label: 'erlöschende Verjährung',
                       french_label: 'prescription extinctive',
                       german_pattern: /erlöschende[nr]?\s+Verjährung/i,
                       french_pattern: /prescriptions?\s+extinctives?/i)
    ].map(&:freeze).freeze

    module_function

    # Lines for the answer translation prompt: French -> German.
    def answer_prompt_lines
      TERMS.map do |term|
        never = term.banned.any? ? " (never #{term.banned.join(', ')})" : ''
        "#{term.french} -> #{term.german}#{never}"
      end
    end

    # Lines for the question translation prompt: German -> French.
    def question_prompt_lines
      TERMS.map { |term| term.question_line || "#{term.german} -> #{term.french}" } +
        QUESTION_ONLY_PAIRS.map { |german, french| "#{german} -> #{french}" }
    end

    # The QUESTION_TERMS a French question drops: [term, ...], empty when it
    # keeps them all.
    def question_failures(german_question, french_question)
      QUESTION_TERMS.select do |term|
        german_question.to_s.match?(term.german_pattern) && !french_question.to_s.match?(term.french_pattern)
      end
    end

    # nil when the German prose keeps the glossary, else "<name>:banned" or
    # "<name>:missing" for the first term it breaks (banned terms first).
    # Both texts are prose.
    def failure(french_prose, german_prose)
      failures(french_prose, german_prose).first
    end

    # Every term the German prose breaks, banned terms first.
    def failures(french_prose, german_prose)
      banned = TERMS.select do |term|
        term.banned_pattern&.match?(german_prose) && !term.banned_unless&.match?(french_prose)
      end.map { |term| "#{term.name}:banned" }
      missing = TERMS.select do |term|
        term.french_pattern.match?(french_prose) && !term.german_pattern.match?(german_prose) &&
          !term.french_unless&.match?(french_prose) &&
          (term.competing_pattern.nil? || term.competing_pattern.match?(german_prose))
      end
      banned + missing.map { |term| "#{term.name}:missing" } + line_failures(french_prose, german_prose, missing)
    end

    # The wrong word beside the kept term: a term judged by a competing word
    # passed the whole text because the Belgian word stood somewhere in it,
    # while a line that names the French trigger carries the competing word
    # alone ("employé" rendered "Arbeitnehmer" on one line, "Angestellte" on
    # another; "carrière" as "Dienstjahre" beside a "Laufbahn"; "rétractation"
    # as "zurücktreten" beside the "Widerruf"). Graders 2 and 3 of the v7 run
    # (2026-10-05) counted it on 7 rows, once masking a major defect. Read
    # line by line when the translation kept the French line structure (the
    # same number of lines); a term already missing as a whole is not named
    # twice.
    def line_failures(french_prose, german_prose, missing)
      french_lines = french_prose.to_s.split("\n")
      german_lines = german_prose.to_s.split("\n")
      return [] unless french_lines.length > 1 && french_lines.length == german_lines.length

      TERMS.select(&:competing_pattern).filter_map do |term|
        next if missing.include?(term)
        next if term.french_unless&.match?(french_prose)

        wrong = french_lines.each_index.any? do |index|
          term.french_pattern.match?(french_lines[index]) &&
            term.competing_pattern.match?(german_lines[index]) &&
            !term.line_pattern.match?(german_lines[index]) &&
            !term.competing_french&.match?(french_lines[index])
        end
        "#{term.name}:line" if wrong
      end
    end

    # Every German line the line check refuses for a term, to quote in the
    # retry hint (v8 grader 2: the hint named the first competing word of
    # the whole prose, not the line; v9 grader 2: a row with four wrong lines
    # got one named, the retry fixed that one and the row fell back).
    def refused_lines(term, french_prose, german_prose)
      french_lines = french_prose.to_s.split("\n")
      german_lines = german_prose.to_s.split("\n")
      return [] unless french_lines.length == german_lines.length

      french_lines.each_index.filter_map do |index|
        next unless term.french_pattern.match?(french_lines[index]) &&
                    term.competing_pattern&.match?(german_lines[index]) &&
                    !term.line_pattern.match?(german_lines[index]) &&
                    !term.competing_french&.match?(french_lines[index])

        german_lines[index].strip
      end
    end

    def refused_line(term, french_prose, german_prose)
      refused_lines(term, french_prose, german_prose).first
    end
  end
end
