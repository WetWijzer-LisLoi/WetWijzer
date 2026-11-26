# frozen_string_literal: true

module LegalChatbot
  # Card relevance (Sol 2026-11-22 13:15:02Z and 13:20:48Z, the 1.1.90 retest of the twenty catalogue questions):
  # semantic neighbours from a narrow subject reached the model's context and the cards of questions that never raise
  # that subject. "Zijn algemene voorwaarden altijd bindend?" got a treasury decree, the statutes of two waterway
  # agencies and of the Brussels stock exchange, the AI Act and two GDPR provisions; "Hoe worden warrants fiscaal
  # behandeld in België?" the excise on tobacco and energy; "Hoe werkt werkloosheidsuitkering?" the statutes of two
  # sector funds; "Hoe wijzig ik de statuten?" a decree on the jury; "Huur overlijden huurder?" hospital financing.
  #
  # A law of one of these subjects, known by its title, is kept only when the question raises the subject. The rule
  # runs before the context is built, so the model no longer reads what the reader no longer sees. An article pinned
  # for the question, a law the question names by its NUMAC and a law the reader is viewing are kept before this
  # scope runs (LegislationSearch.contextual_source_relevant?). A keyword hit is not: the words a narrow law shares
  # with a question ("statuten", "voorwaarden") are what brought it in.
  module SpecialistSubjectScope
    B = '(?<![[:alnum:]])'
    E = '(?![[:alnum:]])'
    # Words that raise any tax: each tax subject's question names one of them or words of its own
    TAX_WORDS = '\p{L}*belasting\p{L}*|fisca\p{L}*|fiscus|btw|tva|mwst|(?-i:VAT)|tax\p{L}*|imp[ôo]t\p{L}*|imposi\p{L}*|' \
                'imposable\p{L}*|\p{L}*steuer\p{L}*|aftrek\p{L}*|d[ée]duct\p{L}*|abzug\p{L}*|abzugsf[äa]hig\p{L}*|deduct\p{L}*|' \
                'voorheffing\p{L}*|pr[ée]compte\p{L}*|financi[ëe]n|finances|vrijstelling\p{L}*|exon[ée]r\p{L}*|befreiung\p{L}*|' \
                'exemption\p{L}*|douane\p{L}*|zoll\p{L}*|customs|accijns\p{L}*|accise\p{L}*|aanslag\p{L}*|kohier\p{L}*|' \
                'avertissement-extrait\p{L}*|enr[ôo]lement\p{L}*|steuerbescheid\p{L}*|tax\s+assessment\p{L}*|\p{L}*minfin\p{L}*|' \
                'tax-?on-?web|elektrische\s+(?:auto|wagen)\p{L}*|v[ée]hicules?\s+[ée]lectriques?|voitures?\s+[ée]lectriques?|' \
                'elektroauto\p{L}*|electric\s+(?:vehicles?|cars?)|laadpa\p{L}*|bornes?\s+de\s+recharge'
    # The words of SUBJECTS[:social_integration]: a question about the amount of an unemployment benefit, which names
    # no social integration and no end, loss, limit, duration or reform of that benefit (a duration question asks about
    # the time limit, after which the social-integration income may follow)
    UNEMPLOYMENT_WORDS = 'werkloo\p{L}*|werkloze\p{L}*|doppen|dopgeld|stempelgeld|ch[ôo]mage\p{L}*|ch[ôo]meur\p{L}*|' \
                         'arbeitslos\p{L}*|unemploy\p{L}*|rva|onem'
    BENEFIT_AMOUNT_WORDS = '\p{L}*bedr(?:ag|aag)\p{L}*|hoeveel|hoogte|hoe\s+hoog|bereken\p{L}*|percentage|\p{L}*maximum\p{L}*|' \
                           '\p{L}*minimum\p{L}*|bruto\p{L}*|netto\p{L}*|montant\p{L}*|combien|calcul\p{L}*|taux|pourcentage|' \
                           'betrag\p{L}*|h[öo]he|wie\s+hoch|wie\s*viel\p{L}*|berechn\p{L}*|prozent\p{L}*|amount\p{L}*|' \
                           'how\s+much|calculat\p{L}*|rates?'
    SOCIAL_INTEGRATION_WORDS = 'leefloon\p{L}*|ocmw\p{L}*|cpas|maatschappelijke\s+integratie|maatschappelijk\s+welzijn|' \
                               'int[ée]gration\s+sociale|revenu\s+d.int[ée]gration|aide\s+sociale|bijstand\p{L}*|' \
                               'sozialhilfe|eingliederungseinkommen|[öo]shz|social\s+(?:assistance|integration|welfare)|' \
                               'integration\s+income|bestaansminimum|minimex'
    BENEFIT_END_WORDS = 'stop\p{L}*|gestopt|einde\p{L}*|eindig\p{L}*|afgelopen|verlie\p{L}*|verloren|kwijt\p{L}*|geschorst|' \
                        'schorsing\p{L}*|uitgesloten|uitsluiting\p{L}*|sanctie\p{L}*|geweigerd|weigering\p{L}*|beperk\p{L}*|' \
                        'hervorm\p{L}*|fin|finit|termin[ée]\p{L}*|arr[êe]t\p{L}*|perte\p{L}*|perd\p{L}*|suspen\p{L}*|' \
                        'exclu\p{L}*|sanction\p{L}*|refus\p{L}*|limit\p{L}*|r[ée]form\p{L}*|ende\p{L}*|endet|beend\p{L}*|' \
                        'verlier\p{L}*|verlust\p{L}*|gesperrt|sperre\p{L}*|ausgeschlossen|ausschluss\p{L}*|sanktion\p{L}*|' \
                        'abgelehnt|befrist\p{L}*|begrenz\p{L}*|end|ends|ended|ending|lose|loses|losing|lost|loss|denied|' \
                        'reform\p{L}*|geen\s+(?:uitkering|inkomen)|zonder\s+(?:uitkering|inkomen)|' \
                        'sans\s+(?:allocations?|revenus?)|ohne\s+(?:leistung\p{L}*|einkommen)|no\s+(?:benefits?|income)|' \
                        'without\s+(?:benefits?|income)|hoe\s*lang\p{L}*|duur\p{L}*|looptijd|maanden|jaren|jaar|' \
                        'periode\p{L}*|p[ée]riode\p{L}*|dur[ée]e\p{L}*|combien\s+de\s+temps|mois|ans|ann[ée]es?|' \
                        'wie\s+lange|dauer\p{L}*|monate\p{L}*|jahre\p{L}*|how\s+long|duration|months?|years?|period\p{L}*'
    # A program law or a law of diverse provisions lists many subjects in its title: no title word makes it a narrow law.
    # Diverse provisions on one named domain ("diverse bepalingen betreffende de controle van energieproducten") are
    # that domain's law.
    DOMAIN = '(?![[:space:]]+(?:betreffende|inzake|op\s+het\s+vlak\s+van|met\s+betrekking\s+tot|in\s+verband\s+met|en\s+mati[èe]re|' \
             'relatives?|relatifs?|concernant|in\s+bezug|betreffend|zur|zum|on|concerning|relating))'
    OMNIBUS = /#{B}(?:programmawet\p{L}*|programmadecreet\p{L}*|programma-?ordonnantie\p{L}*|loi-programme|d[ée]cret-programme|
                ordonnance-programme|programmgesetz\p{L}*|programmdekret\p{L}*|herstelwet\p{L}*|loi\s+de\s+redressement|
                houdende\s+(?:diverse|verschillende)\s+(?:bepalingen|maatregelen)#{DOMAIN}|en\s+diverse\s+bepalingen#{DOMAIN}|
                portant\s+des\s+dispositions\s+diverses#{DOMAIN}|portant\s+diverses\s+(?:dispositions|mesures)#{DOMAIN}|
                et\s+(?:des\s+)?dispositions\s+diverses#{DOMAIN}|verschiedene\p{L}*\s+bestimmungen#{DOMAIN}|
                (?:en|et|und)\s+(?:diverse|verschillende|divers(?:es)?|verschiedene\p{L}*)\s+(?:\p{L}+\s+)?(?:bepalingen|maatregelen|
                dispositions|mesures|bestimmungen|ma(?:ß|ss)nahmen)|
                (?:diverse|verschillende|divers(?:es)?)\s+(?:\p{L}+\s+)?(?:bepalingen|maatregelen|dispositions|mesures)\s+
                (?:inzake|betreffende|en\s+mati[èe]re\s+de|relatives?\s+(?:à|aux?))\s+(?:het\s+|de\s+|la\s+|le\s+)?\p{L}+\s+
                (?:en|et)\s+\p{L}+)#{E}/iux

    # subject => [the law's title, the question that raises it]
    SUBJECTS = {
      # The statutes and internal organisation of public bodies: an agency's statutes, a treasury, a board's services
      public_body: [
        /#{B}(?:statuten\s+van|statuts\s+(?:de|du|des)|satzung\p{L}*|extern\s+verzelfstandigd\p{L}*\s+agentschap|
           publiekrechtelijk\s+vormgegeven|thesauriebeheer|gestion\s+(?:commune\s+)?de\s+(?:la\s+)?tr[ée]sorerie|
           effectenbeursvennootschap|soci[ée]t[ée]\s+de\s+la\s+bourse|directiecomit[ée]|comit[ée]\s+de\s+direction|
           oprichting\s+van\s+diensten\s+in\s+de\s+schoot|cr[ée]ation\s+de\s+services\s+au\s+sein)#{E}/iux,
        /#{B}(?:agentschap\p{L}*|agences?|agentur\p{L}*|agency|agencies|thesaurie\p{L}*|tr[ée]sorerie|treasury|
           \p{L}*beurs\p{L}*|bourse\p{L}*|b[öo]rse\p{L}*|stock\s+exchange|directiecomit[ée]|comit[ée]\s+de\s+direction|
           overheidsdienst\p{L}*|(?-i:FOD|SPF)|ministerie\p{L}*|minist[èe]re\p{L}*|ministry|ministerium|administratie\p{L}*|
           administration\p{L}*|verwaltung\p{L}*|bestu\p{L}*|conseil\s+d.administration|verwaltungsrat|board|
           waterweg\p{L}*|zeekanaal|scheepvaart|voies?\s+hydrauliques?|wasserstra(?:ß|ss)e\p{L}*|waterways?|
           overheidsbedrijf\p{L}*|entreprises?\s+publiques?|instelling\p{L}*\s+van\s+openbaar\s+nut|organisme\p{L}*\s+public\p{L}*|
           ambtena\p{L}*|fonctionnaire\p{L}*|beamte\p{L}*|civil\s+servants?|personeelsstatuut|statut\s+du\s+personnel)#{E}/iux
      ],
      # The statutes of a sector's social fund
      sector_fund: [
        /#{B}(?:fonds\s+voor\s+bestaanszekerheid|fonds\s+de\s+s[ée]curit[ée]\s+d.existence|sociaal\s+fonds|fonds\s+social|
           sozialfonds|fonds\s+f[üu]r\s+existenzsicherheit)#{E}/iux,
        /#{B}(?:fonds|sectorfonds|bestaanszekerheid|s[ée]curit[ée]\s+d.existence|existenzsicherheit|sozialfonds|social\s+fund|
           sector\p{L}*|secteur\p{L}*|branche\p{L}*|paritair\p{L}*|paritaire\p{L}*|parit[äa]tisch\p{L}*|joint\s+committee|
           vakbond\p{L}*|syndica\p{L}*|gewerkschaft\p{L}*|trade\s+unions?|eindejaarspremie\p{L}*|prime\s+de\s+fin\s+d.ann[ée]e|
           syndicale\s+premie|prime\s+syndicale)#{E}/iux
      ],
      # Excise on energy products, electricity, tobacco and alcohol
      excise: [
        /#{B}(?:accijns\p{L}*|accise\p{L}*|verbrauchsteuer\p{L}*|excise\p{L}*|energieproducten|produits\s+[ée]nerg[ée]tiques|
           energieerzeugniss\p{L}*|gefabriceerde\s+tabak|tabacs?\s+manufactur[ée]s?|tabakwaren|alcoholhoudende\s+dranken|
           boissons\s+alcoolis[ée]es)#{E}/iux,
        /#{B}(?:accijns\p{L}*|accise\p{L}*|verbrauchsteuer\p{L}*|excise\p{L}*|tabak\p{L}*|tabac\p{L}*|sigaret\p{L}*|
           cigarette\p{L}*|zigarette\p{L}*|energieproduct\p{L}*|produits?\s+[ée]nerg[ée]tiques?|brandstof\p{L}*|carburant\p{L}*|
           kraftstoff\p{L}*|fuel\p{L}*|diesel|benzine|essence|gasoil|kerosine|k[ée]ros[èe]ne|stookolie|mazout|heiz[öo]l|
           elektriciteit\p{L}*|[ée]lectricit[ée]|strom\p{L}*|stroom\p{L}*|electricity|energie\p{L}*|[ée]nergie\p{L}*|energy|
           aardgas|gaz\s+naturel|erdgas|natural\s+gas|alcohol\p{L}*|alcool\p{L}*|alkohol\p{L}*|bier\p{L}*|bi[èe]re\p{L}*|beer|
           wijn\p{L}*|wein\p{L}*|wine|spirit\p{L}*|frisdrank\p{L}*|soda\p{L}*|douane\p{L}*|zoll\p{L}*|customs)#{E}/iux
      ],
      # A premium scheme for fitting an LPG installation
      energy_subsidy: [
        /#{B}(?:premiestelsel|lpg-installatie\p{L}*|installation\s+lpg|lpg-anlage\p{L}*)#{E}/iux,
        /#{B}(?:lpg|premie\p{L}*|primes?|pr[äa]mie\p{L}*|subsidie\p{L}*|subsides?|subvention\p{L}*|zuschuss\p{L}*|grants?|
           steun\p{L}*|aides?|f[öo]rderung\p{L}*)#{E}/iux
      ],
      # Food hygiene and the direct supply of food of animal origin
      food: [
        /#{B}(?:levensmiddel\p{L}*|denr[ée]es?\s+alimentaires?|dierlijke\s+oorsprong|origine\s+animale|lebensmittel\p{L}*|
           tierischen\s+ursprungs|voedselveiligheid|s[ée]curit[ée]\s+de\s+la\s+cha[îi]ne\s+alimentaire|foodstuffs?)#{E}/iux,
        /#{B}(?:levensmiddel\p{L}*|voedsel\p{L}*|voeding\p{L}*|eten|maaltijd\p{L}*|denr[ée]e\p{L}*|aliment\p{L}*|nourriture|
           repas|lebensmittel\p{L}*|nahrung\p{L}*|essen|mahlzeit\p{L}*|food\p{L}*|meals?|favv|afsca|vlees\p{L}*|viande\p{L}*|
           fleisch\p{L}*|meat|melk\p{L}*|lait\p{L}*|milch\p{L}*|milk|eieren|[œo]eufs?|eier|eggs?|kaas\p{L}*|fromage\p{L}*|
           k[äa]se|cheese|horeca|restaurant\p{L}*|caf[ée]\p{L}*|slager\p{L}*|boucher\p{L}*|metzger\p{L}*|butcher\p{L}*|
           bakker\p{L}*|boulang\p{L}*|b[äa]cker\p{L}*|baker\p{L}*|landbouw\p{L}*|agricult\p{L}*|landwirt\p{L}*|boer\p{L}*|
           hoeve\p{L}*|ferme\p{L}*|farm\p{L}*|hygi[ëe]ne|hygiene|dierlijk\p{L}*|animal\p{L}*|tierisch\p{L}*|jam|confituur)#{E}/iux
      ],
      # Public procurement and concessions
      procurement: [
        /#{B}(?:overheidsopdracht\p{L}*|march[ée]s?\s+publics?|concessieovereenkomst\p{L}*|contrats?\s+de\s+concession|
           [öo]ffentliche\p{L}*\s+auftr[äa]g\p{L}*|public\s+(?:procurement|contracts?))#{E}/iux,
        /#{B}(?:overheidsopdracht\p{L}*|aanbested\p{L}*|march[ée]s?\s+publics?|adjudicat\p{L}*|soumission\p{L}*|procurement|
           tender\p{L}*|vergabe\p{L}*|ausschreibung\p{L}*|[öo]ffentliche\p{L}*\s+auftr[äa]g\p{L}*|concessie\p{L}*|
           concession\p{L}*|konzession\p{L}*|inschrijver\p{L}*|soumissionnaire\p{L}*|bieter\p{L}*|bidders?)#{E}/iux
      ],
      # The jury and the court of assizes
      jury: [
        /#{B}(?:jury|hof\s+van\s+assisen|cour\s+d.assises|schwurgericht\p{L}*|gezworenen|jur[ée]s)#{E}/iux,
        /#{B}(?:jury\p{L}*|assisen|assises|gezworene\p{L}*|jur[ée]s?|geschworene\p{L}*|schwurgericht\p{L}*|jurors?)#{E}/iux
      ],
      # The financing and recognition of hospitals and psychiatric homes
      hospital: [
        /#{B}(?:ziekenhui\p{L}*|h[ôo]pita\p{L}*|krankenh[äa]us\p{L}*|hospitals?|psychiatrische\s+verzorgingstehuizen|
           maisons?\s+de\s+soins\s+psychiatriques)#{E}/iux,
        /#{B}(?:ziekenhui\p{L}*|hospita\p{L}*|h[ôo]pita\p{L}*|krankenh[äa]us\p{L}*|kliniek\p{L}*|clinique\p{L}*|klinik\p{L}*|
           clinic\p{L}*|psychiatr\p{L}*|verzorgingstehuis\p{L}*|rusthuis\p{L}*|woonzorg\p{L}*|maisons?\s+de\s+(?:repos|soins)|
           pflegeheim\p{L}*|nursing\s+homes?|opname\p{L}*|patient\p{L}*|pati[ëe]nt\p{L}*|dokter\p{L}*|m[ée]decin\p{L}*|
           arzt\p{L}*|[äa]rzt\p{L}*|doctors?|verpleeg\p{L}*|infirmi\p{L}*|pflege\p{L}*|nurs\p{L}*|medisch\p{L}*|
           m[ée]dical\p{L}*|medizinisch\p{L}*|medical|soins\s+de\s+sant[ée]|gezondheidszorg\p{L}*|gesundheitsversorgung|
           health\s*care|zorgverlener\p{L}*|prestataires?\s+de\s+soins)#{E}/iux
      ],
      # Education and its staff
      education: [
        /#{B}(?:onderwijs\p{L}*|enseignement\p{L}*|unterricht\p{L}*|schulwesen|leerplicht\p{L}*|obligation\s+scolaire|
           hogeschol\p{L}*|universiteit\p{L}*|universit[ée]s?|studiefinanciering|allocations?\s+d.[ée]tudes)#{E}/iux,
        /#{B}(?:onderwijs\p{L}*|\p{L}*school\p{L}*|leerkracht\p{L}*|leraar|leraren|leerling\p{L}*|student\p{L}*|studie\p{L}*|
           enseignement\p{L}*|[ée]cole\p{L}*|enseignant\p{L}*|[ée]l[èe]ve\p{L}*|[ée]tudiant\p{L}*|[ée]tudes?|professeur\p{L}*|
           schule\p{L}*|sch[üu]ler\p{L}*|lehrer\p{L}*|studium|studien\p{L}*|unterricht\p{L}*|teacher\p{L}*|pupils?|
           universit\p{L}*|hogeschol\p{L}*|hogeschool|diploma\p{L}*|dipl[ôo]me\p{L}*|opleiding\p{L}*|formation\p{L}*|
           ausbildung\p{L}*|training\p{L}*|cursus\p{L}*|leerplicht\p{L}*|kleuter\p{L}*|crèche|kinderopvang|educat\p{L}*|
           stude\p{L}*|studeer\p{L}*|[ée]tudi\p{L}*|
           [ée]ducati\p{L}*|bildung\p{L}*|schooling|obligation\s+scolaire|schulpflicht\p{L}*)#{E}/iux
      ],
      # The AI Act. A hyphen compound ("ai-verordening", "KI-Verordnung") raises it, but not the French inversion
      # "Ai-je ... ?" (Sol 2026-11-22 23:31:33Z).
      ai: [
        %r{#{B}(?:2024/1689|artifici[ëe]le\s+intelligentie|intelligence\s+artificielle|k[üu]nstliche\p{L}*\s+intelligenz|
           artificial\s+intelligence)#{E}}iux,
        %r{#{B}(?:(?-i:AI|A\.I\.|KI|IA)|(?:ai(?!-je(?![[:alpha:]]))|ia|ki)-\p{L}+|artifici[ëe]le|artificielle|artificial|k[üu]nstlich\p{L}*|intelligent\p{L}*|algoritm\p{L}*|
           algorithm\p{L}*|algorithmus|chatbot\p{L}*|chatgpt|deepfake\p{L}*|geautomatiseerd\p{L}*|automatis\p{L}*|automated|
           automatisiert\p{L}*|machine\s+learning|gezichtsherkenning|reconnaissance\s+faciale|gesichtserkennung|
           facial\s+recognition|biometr\p{L}*|robot\p{L}*|2024/1689)#{E}}iux
      ],
      # The GDPR and data protection laws. An objection alone raises nothing (Sol 2026-11-23 14:13:13Z: GDPR arts. 12 and
      # 13 on the cards of "... dat het betrokken publiek tijdens het openbaar onderzoek al een bezwaar of standpunt
      # indiende ..."): an objection in a public inquiry, to a permit or to a tax is no objection to processing, and a
      # question about that names the data, the processing, marketing or profiling.
      data_protection: [
        %r{#{B}(?:2016/679|gegevensbescherming|protection\s+des\s+donn[ée]es|datenschutz\p{L}*|data\s+protection|
           verwerking\s+van\s+persoonsgegevens|traitement\s+des\s+donn[ée]es\s+[àa]\s+caract[èe]re\s+personnel|
           verarbeitung\s+personenbezogener\s+daten|processing\s+of\s+personal\s+data)#{E}}iux,
        /#{B}(?:privacy\p{L}*|confidentialit\p{L}*|priv[ée]\p{L}*|vie\s+priv[ée]e|privatsph[äa]re|persoonsgegeven\p{L}*|persoonlijke\s+gegevens|\p{L}*gegevens\p{L}*|
           \p{L}*data|donn[ée]es|daten\p{L}*|personenbezogen\p{L}*|gdpr|avg|rgpd|dsgvo|camera\p{L}*|cam[ée]ra\p{L}*|kamera\p{L}*|
           foto\p{L}*|photo\p{L}*|beeld\p{L}*|image\p{L}*|bild\p{L}*|video\p{L}*|cookie\p{L}*|e-?mail\p{L}*|mail\p{L}*|
           courriel\p{L}*|computer\p{L}*|ordinateur\p{L}*|internet|online|app|apps|applicati\p{L}*|website\p{L}*|site\s+web|webshop\p{L}*|
           webwinkel\p{L}*|verwerk\p{L}*|traitement\p{L}*|sous-traitant\p{L}*|verarbeit\p{L}*|auftragsverarbeit\p{L}*|
           processor\p{L}*|processing|controller\p{L}*|verantwortlich\p{L}*|inzage\p{L}*|vergetel\p{L}*|oubli|vergessen\p{L}*|
           forgotten|forget|erasure|effacement|l[öo]schung\p{L}*|uitwiss\p{L}*|personal|personnel\p{L}*|persoonlijk\p{L}*|
           verwijder\p{L}*|wissen|gewist|supprim\p{L}*|effac\p{L}*|l[öo]sch\p{L}*|eras\p{L}*|delet\p{L}*|
           herkomst|herkunft|origine|direktwerbung\p{L}*|prospection\p{L}*|telefoonnummer\p{L}*|
           telefonnummer\p{L}*|rufnummer\p{L}*|phone\s+numbers?|num[ée]ros?\s+de\s+t[ée]l[ée]phone|ongevraagd\p{L}*|
           non\s+sollicit\p{L}*|unsolicited|werbeanruf\p{L}*|spam\p{L}*|bel-me-niet\p{L}*|ne-m.appelez-plus|
           profil\p{L}*|marketing|nieuwsbrief\p{L}*|newsletter\p{L}*|telemarketing|datalek\p{L}*|breach\p{L}*|fuite\p{L}*|
           identiteit\p{L}*|identit[ée]\p{L}*|identit[äa]t\p{L}*|identity|(?-i:eID|EID)|rijksregister\p{L}*|registre\s+national|
           bewak\p{L}*|surveil\p{L}*|[üu]berwach\p{L}*|monitor\p{L}*|track\p{L}*|gps|locatie\p{L}*|localisation|standort\p{L}*|
           location|medisch\s+dossier|dossier\s+m[ée]dical|patientenakte|medical\s+(?:records?|files?)|registratie\p{L}*|
           enregistrement\p{L}*|toestemming\p{L}*|consentement\p{L}*|einwilligung\p{L}*|consent)#{E}/iux
      ],
      # The e-commerce directive
      ecommerce: [
        %r{#{B}(?:2000/31|elektronische\s+handel|commerce\s+[ée]lectronique|elektronischen\s+gesch[äa]ftsverkehr\p{L}*|
           electronic\s+commerce|informatiemaatschappij|soci[ée]t[ée]\s+de\s+l.information|informationsgesellschaft|
           information\s+society)#{E}}iux,
        # "Onlinekauf" and "en ligne" too: the EU measurement of 2026-11-23 read French and German questions
        /#{B}(?:online\p{L}*|en\s+ligne|internet\p{L}*|webwinkel\p{L}*|webshop\p{L}*|website\p{L}*|webseite\p{L}*|site\s+web|
           sites?\s+internet|e-?commerce|
           platform\p{L}*|plateforme\p{L}*|plattform\p{L}*|marketplace\p{L}*|marktplaats|elektronische\s+handel|
           commerce\s+[ée]lectronique|informatiemaatschappij|soci[ée]t[ée]\s+de\s+l.information|informationsgesellschaft|
           information\s+society|hosting\p{L}*|h[ée]berge\p{L}*|provider\p{L}*|fournisseur\p{L}*|anbieter\p{L}*|
           e-?mail\p{L}*|courriel\p{L}*|spam\p{L}*|cookie\p{L}*|app|apps|digita\p{L}*|num[ée]rique\p{L}*|sociale\s+media|
           r[ée]seaux\s+sociaux|
           social\s+media|soziale\p{L}*\s+medien)#{E}/iux
      ],
      # The consumer rights directive. Sol 2026-11-23 14:13:13Z: its art. 16 ter stood on the cards of a question about
      # the closed list of discrimination grounds, found by word overlap alone. A row a topic plan targets (the
      # withdrawal plan) stays before this scope is asked.
      consumer_rights: [
        %r{#{B}(?:2011/83|consumentenrechten|droits\s+des\s+consommateurs|rechte\s+der\s+verbraucher|consumer\s+rights)#{E}}iux,
        /#{B}(?:consument\p{L}*|consommat\p{L}*|verbraucher\p{L}*|consumer\p{L}*|koper\p{L}*|acheteu\p{L}*|k[äa]ufer\p{L}*|
           buyer\p{L}*|aankoop\p{L}*|achat\p{L}*|kauf\p{L}*|purchas\p{L}*|gekocht|kocht|koop|kopen|achet\p{L}*|gekauft|bought|
           buy\p{L}*|bestel\p{L}*|commande\p{L}*|bestell\p{L}*|order\p{L}*|herroep\p{L}*|bedenktijd|r[ée]tract\p{L}*|
           widerruf\p{L}*|withdraw\p{L}*|cooling|webwinkel\p{L}*|webshop\p{L}*|online\p{L}*|en\s+ligne|verkoper\p{L}*|
           vendeu\p{L}*|verk[äa]ufer\p{L}*|seller\p{L}*|trader\p{L}*|handelaar\p{L}*|professionnel\p{L}*|unternehm\p{L}*|
           lever\p{L}*|livr\p{L}*|liefer\p{L}*|deliver\p{L}*|terugbetal\p{L}*|rembours\p{L}*|erstatt\p{L}*|refund\p{L}*|
           retour\p{L}*|terugstur\p{L}*|terugzend\p{L}*|return\p{L}*|colportage|huis-aan-huis\p{L}*|d[ée]marchage|
           haust[üu]r\p{L}*|doorstep|abonnement\p{L}*|subscription\p{L}*|verko\p{L}*|vente\p{L}*|vend\p{L}*|verkauf\p{L}*|
           sale\p{L}*|sold|sell\p{L}*|winkel\p{L}*|magasin\p{L}*|gesch[äa]ft\p{L}*|shop\p{L}*|store\p{L}*|
           overeenkomst\p{L}*|contract\p{L}*|contrat\p{L}*|vertr[äa]g\p{L}*|kosten|frais|geb[üu]hr\p{L}*|fees?|charges?|
           betal\p{L}*|paiement\p{L}*|zahl\p{L}*|pay\p{L}*|prijs\p{L}*|prix|preis\p{L}*|price\p{L}*|garantie\p{L}*|
           guarantee\p{L}*|warrant\p{L}*|digita\p{L}*|num[ée]rique\p{L}*|op\s+afstand|[àa]\s+distance|fernabsatz\p{L}*|
           telefo\p{L}*|t[ée]l[ée]phon\p{L}*|phone\p{L}*|pakket\p{L}*|colis|paket\p{L}*|parcel\p{L}*)#{E}/iux
      ],
      # Income tax: the income tax code, its royal decree and the withholding taxes
      income_tax: [
        %r{#{B}(?:inkomstenbelasting\p{L}*|imp[ôo]ts?\s+sur\s+les\s+revenus|einkommensteuer\p{L}*|kb/wib|ar/cir|wib\s*92|cir\s*92|
           fiscaal\s+stelsel|r[ée]gime\s+fiscal|bedrijfsvoorheffing|pr[ée]compte\s+professionnel|roerende\s+voorheffing|
           pr[ée]compte\s+mobilier)#{E}}iux,
        /#{B}(?:#{TAX_WORDS}|inkomen\p{L}*|revenus?|einkommen\p{L}*|income|bruto|netto|brutto|brut|salaire\s+net|
           net\s+(?:pay|salary|income)|gross\s+(?:pay|salary|income)|loonbrief\p{L}*|fiche\s+de\s+paie|lohnzettel\p{L}*|
           warrant\p{L}*|aandelenoptie\p{L}*|options?\s+sur\s+actions|aktienoption\p{L}*|stock\s+options?|
           voordeel\p{L}*\s+van\s+alle\s+aard|avantages?\s+de\s+toute\s+nature|sachbezug\p{L}*|benefits?\s+in\s+kind|
           bedrijfswagen\p{L}*|firmawagen\p{L}*|voiture\p{L}*\s+de\s+soci[ée]t[ée]|dienstwagen\p{L}*|company\s+cars?|
           flexi-?job\p{L}*|winst\p{L}*|
           b[ée]n[ée]fice\p{L}*|gewinn\p{L}*|profit\p{L}*|meerwaarde\p{L}*|plus-values?|kapitaalwinst\p{L}*|dividend\p{L}*|
           interest\p{L}*|int[ée]r[êe]ts?|zinsen|rente\p{L}*|pensioensparen|[ée]pargne-pension|afkoop\p{L}*|afkopen|
           rachat\p{L}*|lening\p{L}*|pr[êe]t\s+hypoth[ée]caire|hypothe\p{L}*|mortgage\p{L}*|woonbonus|vennootschap\p{L}*|
           soci[ée]t[ée]\p{L}*|gesellschaft\p{L}*|compan\p{L}*|onderneming\p{L}*|entreprise\p{L}*|unternehmen\p{L}*|
           zelfstandig\p{L}*|ind[ée]pendant\p{L}*|selbst[äa]ndig\p{L}*|self-employed|freelance\p{L}*|onkosten\p{L}*|
           frais\s+professionnels|beroepskosten|alimentatie\p{L}*|onderhoudsgeld\p{L}*|pension\s+alimentaire|unterhalt\p{L}*|
           alimony|\p{L}*cheque\p{L}*|ch[èe]que\p{L}*|vouchers?|bons?\s+d.achat|gutschein\p{L}*|vapz|plci)#{E}/iux
      ],
      # VAT
      vat: [
        /#{B}(?:belasting\s+over\s+de\s+toegevoegde\s+waarde|taxe\s+sur\s+la\s+valeur\s+ajout[ée]e|btw-wetboek|
           code\s+de\s+la\s+tva|mehrwertsteuer\p{L}*|umsatzsteuer\p{L}*|value\s+added\s+tax)#{E}/iux,
        /#{B}(?:#{TAX_WORDS}|factu\p{L}*|invoice\p{L}*|rechnung\p{L}*)#{E}/iux
      ],
      # Registration, gift and inheritance duties, and the regional tax codes that levy them. Sol 2026-11-23 14:13:13Z: the
      # Code of miscellaneous duties and taxes (titles read in the corpus on 2026-11-23) brought its arts. 153 and 156,
      # whose notes name a Constitutional Court judgment, to a question about an objection in a public inquiry.
      duties: [
        /#{B}(?:registratie-,\s+hypotheek-\s+en\s+griffierechten|droits\s+d.enregistrement|successierechten|
           droits\s+de\s+succession|erbschaftsteuer\p{L}*|codex\s+fiscaliteit|code\s+(?:wallon|bruxellois)\s+de\s+la\s+fiscalit[ée]|
           erfbelasting|schenkbelasting|registratiebelasting|diverse\s+rechten\s+en\s+taksen|droits\s+et\s+taxes\s+divers|
           met\s+het\s+zegel\s+gelijkgestelde\s+taksen|taxes\s+assimil[ée]es\s+au\s+timbre)#{E}/iux,
        /#{B}(?:#{TAX_WORDS}|erf\p{L}*|erven|nalatenschap\p{L}*|\p{L}*schenk\p{L}*|h[ée]rit\p{L}*|successi\p{L}*|legs|
           erb\p{L}*|inherit\p{L}*|legacy|donation\p{L}*|don\s+manuel|gifts?|registratie\p{L}*|enregistrement\p{L}*|
           notari\p{L}*|onroerend\p{L}*|immobili\p{L}*|immobilier|real\s+estate|kadast\p{L}*|cadast\p{L}*|
           verkeersbelasting|onroerende\s+voorheffing|abat\p{L}*|sprong\p{L}*|saut\s+de\s+g[ée]n[ée]ration|registr\p{L}*|
           enregistr\p{L}*|\p{L}*gift(?:en)?|verdel\p{L}*|verdeeld|verdeling\p{L}*|partage\p{L}*|teilung\p{L}*|testament\p{L}*|
           estate\p{L}*|vruchtgebruik\p{L}*|usufruit\p{L}*|nie(?:ß|ss)brauch\p{L}*|usufruct\p{L}*|taks\p{L}*|zegel\p{L}*|
           timbre\p{L}*|beurs\p{L}*|bourse\p{L}*|effectenrekening\p{L}*|comptes?[-\s]titres|wertpapierkont\p{L}*|
           securities\s+accounts?|verzekeringsverrichting\p{L}*|op[ée]rations?\s+d.assurance)#{E}/iux
      ],
      # Treaties and laws on the transfer of sentenced persons. Sol 2026-11-25 11:06:22Z: the Belgian-Moroccan and
      # Belgian-Congolese treaties (1999A15126 art. 9, 2014B15235 art. 11) were cards 5 and 6 of the drug sentencing
      # samples #1556 and #1557. Titles read in the corpus on 2026-11-25: "overbrenging (tussen Staten) van (de)
      # gevonniste personen" or "veroordeelde personen", "transfèrement (interétatique) des personnes condamnées". A
      # question about such a transfer, or about serving a sentence in one's home country, keeps them. Sol 16:22:46Z: a
      # transfer word counts only beside a sentence or prison word ("a bank transfer" raises nothing); the French
      # "transfèrement" and the German "Überstellung" name the transfer of a person on their own.
      sentenced_transfer: [
        /#{B}(?:overbrenging\s+(?:tussen\s+staten\s+)?van\s+(?:de\s+)?(?:gevonniste|veroordeelde)\s+personen|
           transf[èe]rement\s+(?:inter-?[ée]tatique\s+)?des\s+personnes\s+condamn[ée]es|
           [üu]berstellung\s+verurteilter\s+personen|transfer\s+of\s+sentenced\s+persons)#{E}/iux,
        /\A(?:(?=.*#{B}(?:transf[èe]rement\p{L}*|[üu]berstell\p{L}*)#{E})|
              (?=.*#{B}(?:overbreng\p{L}*|overgebracht|overgeplaatst|overplaats\p{L}*|transf[ée]r\p{L}*|transfer\p{L}*|
                         thuisland|land\s+van\s+herkomst|pays\s+d.origine|heimatland|home\s+country)#{E})
              (?=.*#{B}(?:gevangen\p{L}*|gedetineerd\p{L}*|veroordeel\p{L}*|gevonnist\p{L}*|straf\p{L}*|d[ée]tenu\p{L}*|
                         condamn\p{L}*|peine\p{L}*|prison\p{L}*|inmate\p{L}*|sentenc\p{L}*|convict\p{L}*|h[äa]ftling\p{L}*|
                         gefangen\p{L}*|verurteil\p{L}*|haft)#{E}))/iumx
      ],
      # Framework agreements on trade and cooperation between the European Community and a third country. Sol 2026-11-25
      # 23:00:07Z: art. 13 of the EC-Korea agreement (1999A15104, "Bestrijding van drugs en witwassen van geld",
      # cooperation, no sentencing rule; read in full on 2026-11-26) was card 6 of the drug trafficking sample #1557 on
      # live 1.1.106. In the corpus the title names that agreement and the acts that approve it (titles read on
      # 2026-11-26). A question about cooperation or such an agreement keeps it; a domestic penalty question does not.
      # The separable "werken ... samen" and "arbeiten ... zusammen" are not read: "samen" alone is no cooperation.
      trade_cooperation: [
        /#{B}(?:kaderovereenkomst\s+inzake\s+handel\s+en\s+samenwerking|accord-cadre\s+de\s+commerce\s+et\s+de\s+coop[ée]ration)#{E}/iux,
        /#{B}(?:samenwerk\p{L}*|co[öo]peratie\p{L}*|coop[éèe]r\p{L}*|co-operat\p{L}*|kooperation\p{L}*|
           zusammenarbeit\p{L}*|kaderovereenkomst\p{L}*|accords?-cadres?|framework\s+agreements?|rahmenabkommen\p{L}*|
           handelsakkoord\p{L}*|handelsovereenkomst\p{L}*|accords?\s+commerciaux|accord\s+commercial|trade\s+agreements?|
           handelsabkommen\p{L}*)#{E}/iux
      ],
      # Cards Sol named on four live catalogue samples (2026-11-25 09:55:53Z, 14:42:20Z and 23:21:19Z, live 1.1.104 to
      # 1.1.106): on #115 "Bedrag werkloosheidsuitkering?" the social-integration art. 14 (2002022559); on #1944 "Wat is SWT
      # stelsel werkloosheid met bedrijfstoeslag?" the occupational-pension tax notice (2016003244); on #2534 "Kan ik
      # ontslagen worden tijdens de proeftijd?" the Proximus and 1991 civil-service cards (1984014223, 1991801190); on #2548
      # "Hoeveel RSZ werknemer?" the judicial organisation (1967101053) and the 2006-08 State/RSZ management agreement
      # (2006A22748). None of them answers its sample. Titles read in the corpus on 2026-11-26, Dutch and French. These
      # subjects are GENERIC: a law that an older subject judges stays judged by it, with one more reason to keep it.
      # A management agreement between the State and a public institution, kept for a question about such an agreement
      management_agreement: [
        /#{B}(?:bestuursovereenkomst\p{L}*|contrats?\s+d.administration)#{E}/iux,
        /#{B}(?:bestuursovereenkomst\p{L}*|contrats?\s+d.administration|management\s+agreements?|verwaltungsvertr[äa]g\p{L}*)#{E}/iux
      ],
      # A circular on the staff of public services, kept for a question about public staff (municipal, provincial, OCMW,
      # police, teaching and military staff included) or about a tax (the circulars on the municipal tax on employed
      # staff). The staff word of the title is the noun personeel or personnel only: a circular to the ambtenaren van de
      # burgerlijke stand is about civil status, and "à caractère personnel" or "statut personnel" (personal data, the
      # personal status of foreigners, their names) is the French adjective.
      public_staff_circular: [
        /\A(?=.*#{B}(?:omzendbrief|circulaire)#{E})
           (?=.*(?:#{B}personeel\p{L}*|#{B}(?:le|du|au|de|en|et|son|sa|leur|leurs|ce|cet|notre|votre)\s+personnel#{E}|
                  (?:\A|[.\-_:;]\s*)personnel#{E}|#{B}personnel\s+(?:contractuel|statutaire|provincial|communal|enseignant|
                  temporaire|administratif|technique|ouvrier|subalterne|militaire|civil)\p{L}*))/iumx,
        /#{B}(?:#{TAX_WORDS}|ambt\p{L}*|fonctionnaire\p{L}*|beamte\p{L}*|civil\s+servants?|contractu\p{L}*|statutair\p{L}*|statutaire\p{L}*|
           personeel\p{L}*|personnel|staff|overheid\p{L}*|openbare\s+(?:sector|dienst\p{L}*|besturen|instelling\p{L}*)|
           pouvoirs?\s+publics?|secteur\s+public|services?\s+publics?|public\s+(?:sector|services?|servants?)|
           [öo]ffentlich\p{L}*\s+dienst\p{L}*|fonction\s+publique|ministerie\p{L}*|minist[èe]re\p{L}*|ministry|ministerium|
           overheidsdienst\p{L}*|(?-i:FOD|SPF)|gemeente\p{L}*|communes?|communa\p{L}*|gemeinde\p{L}*|municipa\p{L}*|
           provincie\p{L}*|provinces?|provincia\p{L}*|provinz\p{L}*|ocmw\p{L}*|cpas|politie\p{L}*|police\p{L}*|polizei\p{L}*|
           onderwijs\p{L}*|enseignement\p{L}*|unterricht\p{L}*|leerkracht\p{L}*|leraa?r\p{L}*|onderwijzer\p{L}*|enseignant\p{L}*|
           lehrer\p{L}*|teacher\p{L}*|defensie|d[ée]fense|militair\p{L}*|militaire\p{L}*|wedde\p{L}*|bar[èe]me\p{L}*)#{E}/iux
      ],
      # A decree on the staff or the employment at one named public employer, kept for a question that names it
      employer_staff_decree: [
        /\A(?=.*#{B}(?:proximus|belgacom)#{E})(?=.*#{B}(?:tewerkstelling|personeel\p{L}*|statuut|minder-?validen|emploi|personnel|
           statut|handicap\p{L}*)#{E})/iumx,
        /#{B}(?:proximus|belgacom)#{E}/iux
      ],
      # Part II of the Judicial Code, on the organisation of the courts, and the decrees on that organisation. A question
      # about courts, judges, their offices and registries, a procedure, lawyers, bailiffs, court experts or legal aid
      # keeps them (Part II holds the bar, the bailiffs, the register of court experts and second-line legal aid).
      judicial_organisation: [
        /#{B}(?:rechterlijke\s+organisatie|organisation\s+judiciaire)#{E}/iux,
        /#{B}(?:\p{L}*rechtbank\p{L}*|\p{L}*rechter\p{L}*|\p{L}*hof|\p{L}*hoven|magistra\p{L}*|griffie\p{L}*|griffier\p{L}*|
           \p{L}*parket\p{L}*|procureur\p{L}*|\p{L}*gerecht\p{L}*|justitie\p{L}*|rechtszaa?k\p{L}*|rechtszaken|proces\p{L}*|
           jury\p{L}*|jur[ée]s?|assis\p{L}*|geschworene\p{L}*|\p{L}*auditeur\p{L}*|\p{L}*auditora\p{L}*|assessor\p{L}*|assesseur\p{L}*|
           procedur\p{L}*|procederen|geding\p{L}*|vonnis\p{L}*|arrest\p{L}*|beroep\p{L}*|advoca\p{L}*|balie\p{L}*|
           deurwaarder\p{L}*|\p{L}*deskundige\p{L}*|pro\s+deo|juridische\s+bijstand|rechtsbijstand|rechtshulp|kanton\p{L}*|
           arrondissement\p{L}*|tribuna\p{L}*|cours?|juges?|juridiction\p{L}*|greff\p{L}*|parquet\p{L}*|proc[èe]s|
           proc[ée]dure\p{L}*|jugement\p{L}*|appel\p{L}*|avocat\p{L}*|barreau\p{L}*|huissier\p{L}*|expert\p{L}*|
           aide\s+juridique|assistance\s+judiciaire|canton\p{L}*|justice|\p{L}*gericht\p{L}*|\p{L}*richter\p{L}*|
           staatsanwalt\p{L}*|\p{L}*anw[äa]lt\p{L}*|prozess\p{L}*|verfahren\p{L}*|urteil\p{L}*|berufung\p{L}*|
           gerichtsvollzieher\p{L}*|sachverst[äa]ndig\p{L}*|justiz\p{L}*|courts?|judges?|judicia\p{L}*|prosecut\p{L}*|
           lawyers?|attorneys?|bailiffs?|lawsuits?|litigation|proceedings?|appeals?|legal\s+aid)#{E}/iux
      ],
      # The social-integration law and its decrees. Only a question about the amount of an unemployment benefit that names
      # no social integration and no end, loss, limit or reform of the benefit leaves them out: every other question keeps
      # them, a collective debt settlement among them (its arts 1675/12 and /13 cite art. 14).
      social_integration: [
        /#{B}(?:recht\s+op\s+maatschappelijke\s+integratie|droit\s+[àa]\s+l.int[ée]gration\s+sociale)#{E}/iux,
        /\A(?!(?=.*#{B}(?:#{UNEMPLOYMENT_WORDS})#{E})(?=.*#{B}(?:#{BENEFIT_AMOUNT_WORDS})#{E})
             (?!.*#{B}(?:#{SOCIAL_INTEGRATION_WORDS}|#{BENEFIT_END_WORDS})#{E}))/iumx
      ],
      # A notice of the tax administration. Its notices cover advance payments, deductions, certificates for childcare,
      # gifts and loans, VAT, withholding taxes and supplementary pensions; a question naming a tax or one of those matters
      # keeps them.
      tax_notice: [
        /#{B}(?:algemene\s+administratie\s+van\s+de\s+fiscaliteit|administration\s+g[ée]n[ée]rale\s+de\s+la\s+fiscalit[ée])#{E}/iux,
        /#{B}(?:#{TAX_WORDS}|\p{L}*belast\p{L}*|\p{L}*impos\p{L}*|\p{L}*besteuer\p{L}*|\p{L}*voorheffing\p{L}*|\p{L}*pr[ée]compte\p{L}*|
           voorafbetaling\p{L}*|versements?\s+anticip\p{L}*|vorauszahlung\p{L}*|advance\s+payments?|aangifte\p{L}*|
           d[ée]claration\p{L}*|\p{L}*erkl[äa]rung\p{L}*|\p{L}*attest\p{L}*|certificat\p{L}*|bescheinigung\p{L}*|kwijtschrift\p{L}*|
           re[çc]us?|gift\p{L}*|dons?(?!['’]t)|lib[ée]ralit\p{L}*|spende\p{L}*|donation\p{L}*|\p{L}*lening\p{L}*|pr[êe]ts?|
           darlehen\p{L}*|\p{L}*krediet\p{L}*|cr[ée]dit\p{L}*|kredit\p{L}*|loans?|mortgage\p{L}*|hypoth\p{L}*|\p{L}*pensioen\p{L}*|
           pensions?|retraite\p{L}*|\p{L}*rente\p{L}*|retirement|\p{L}*verzekering\p{L}*|assurance\p{L}*|\p{L}*versicherung\p{L}*|
           insurance|kinderopvang\p{L}*|opvang\p{L}*|\p{L}*oppas\p{L}*|garde\s+d.enfants|kinderbetreuung\p{L}*|child\s*care|
           inkomen\p{L}*|revenus?|einkommen\p{L}*|income|\p{L}*verklaring\p{L}*|invest\p{L}*|
           ereloon\p{L}*|erelonen|honorai\p{L}*|commissie\p{L}*|commission\p{L}*|factu\p{L}*|invoic\p{L}*|rechnung\p{L}*|
           pensions?\s+compl[ée]mentaires?|fonds\s+de\s+pension|supplementary\s+pensions?|group\s+insurance)#{E}/iux
      ]
    }.freeze
    # A question about a source the reader is shown ("Explain this specialist source.", "Wat zegt deze wet?") keeps
    # every source, as the gates of 2026-10-11 do (fe8545cc9): it asks about that source, whatever its subject.
    ABOUT_SHOWN_SOURCE = /(?<![[:alpha:]])(?:this|these|that|deze|dit|dat|ce|cet|cette|ces|diese[srnm]?)[[:space:]]+
                          (?:\p{L}+[[:space:]]+)?(?:sources?|laws?|acts?|statutes?|provisions?|articles?|regulations?|decrees?|
                          wet(?:ten)?|decreet|decreten|besluit(?:en)?|bepaling(?:en)?|artikel(?:en)?|bron(?:nen)?|tekst(?:en)?|loi|lois|
                          d[ée]crets?|arr[êe]t[ée]s?|dispositions?|textes?|gesetze?s?|dekrete?s?|erlass(?:e|es)?|bestimmung(?:en)?|
                          artikels?|quellen?)(?![[:alpha:]])/iux
    # A law of a specific subject is judged by it alone: the tobacco decree's "fiscaal stelsel" makes it no income tax
    # law, a sector fund's statutes make it no agency
    GENERIC = %i[public_body income_tax vat duties management_agreement public_staff_circular employer_staff_decree
                 judicial_organisation social_integration tax_notice].freeze
    # Sol 2026-11-25 17:29:23Z: a transfer question that names where the person goes keeps that country's bilateral
    # treaty and no other. The bilateral transfer treaties in the corpus (titles read on 2026-11-25): Morocco, Thailand,
    # Hong Kong, DR Congo, the Dominican Republic, Brazil, Kosovo, Albania, China and India. Each entry: the country as a
    # Dutch or French title names it, and the country or its people as a question names them. A title is the treaty of
    # the first entry it names, so the Hong Kong agreement ("Hongkong van de Volksrepubliek China") is Hong Kong's. A
    # title that names none (the Strasbourg convention, the law of 23 May 1990) and a question that names none keep every
    # treaty. "Indien" is Dutch for "if" and never names India, so the German "Indien" is not read either.
    TRANSFER_COUNTRIES = {
      morocco: [/#{B}(?:marokko|maroc)#{E}/iu, /#{B}(?:marok\p{L}*|maroc\p{L}*|morocc\p{L}*)#{E}/iu],
      congo: [/#{B}congo#{E}/iu, /#{B}(?:congo\p{L}*|kongo\p{L}*|rdc|drc)#{E}/iu],
      thailand: [/#{B}(?:thailand|tha[ïi]lande)#{E}/iu, /#{B}tha[ïi]\p{L}*#{E}/iu],
      hong_kong: [/#{B}hong[[:space:]]?kong#{E}/iu, /#{B}hong[[:space:]]?kong\p{L}*#{E}/iu],
      dominican_republic: [/#{B}(?:dominicaanse|dominicaine)#{E}/iu, /#{B}(?:dominica\p{L}*|dominikan\p{L}*)#{E}/iu],
      brazil: [/#{B}(?:brazili[ëe]|br[ée]sil)#{E}/iu, /#{B}(?:brazil\p{L}*|br[ée]sil\p{L}*|brasil\p{L}*)#{E}/iu],
      kosovo: [/#{B}kosovo#{E}/iu, /#{B}kosov\p{L}*#{E}/iu],
      albania: [/#{B}(?:albani[ëe]|albanie)#{E}/iu, /#{B}alban\p{L}*#{E}/iu],
      china: [/#{B}(?:china|chine)#{E}/iu, /#{B}(?:china|chine\p{L}*|chinois\p{L}*)#{E}/iu],
      india: [/#{B}(?:india|inde)#{E}/iu, /#{B}(?:india\p{L}*|indi[ëe]r\p{L}*|indiase|indisch\p{L}*|inde)#{E}/iu]
    }.freeze

    module_function

    # Whether the question raises a narrow subject of the article's law, or the law has none. viewing: a law is being
    # viewed, kept by its NUMAC before this scope runs, so "dit artikel" refers to it and exempts no other candidate
    # (Sol 19:11:40Z).
    def source_relevant?(article, question, viewing: false)
      title = law_title(article)
      found = subjects(title)
      return true if found.empty?

      text = question.to_s
      return true if !viewing && text.match?(ABOUT_SHOWN_SOURCE)

      found.any? { |subject| text.match?(SUBJECTS.fetch(subject).last) && destination_fits?(subject, title, text) }
    end

    # Whether a transfer treaty fits the destination the question names: a question that names one or more of
    # TRANSFER_COUNTRIES keeps their treaties and those of no other; a title that names none of them stays
    def destination_fits?(subject, title, question)
      return true unless subject == :sentenced_transfer

      party = TRANSFER_COUNTRIES.find { |_country, (in_title, _asked)| title.match?(in_title) }&.first
      return true unless party

      named = TRANSFER_COUNTRIES.select { |_country, (_in_title, asked)| question.match?(asked) }.keys
      named.empty? || named.include?(party)
    end

    # The narrow subjects of a law title, the specific ones over the generic
    def subjects(title)
      return [] if title.to_s.match?(OMNIBUS)

      found = SUBJECTS.select { |_subject, (law, _asked)| title.to_s.match?(law) }.keys
      specific = found - GENERIC
      specific.any? ? specific : found
    end

    def law_title(article)
      return '' unless article.is_a?(Hash)

      (article[:law_title] || article[:title] || article['law_title'] || article['title']).to_s
    end
  end
end
