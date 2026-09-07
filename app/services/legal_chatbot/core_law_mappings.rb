# frozen_string_literal: true

# Core Belgian law NUMAC mappings, keyword-to-law lookups, query expansions,
# search tuning constants, and follow-up suggestion data for LegalChatbotService.
#
# This is the largest data module (~1,350 lines), containing bilingual (NL/FR/DE)
# keyword mappings to foundational Belgian law NUMACs used by the RAG search pipeline.
module LegalChatbot
  module CoreLawMappings
    extend ActiveSupport::Concern

    # Popular/foundational Belgian laws - aligned with ApplicationHelper.popular_laws_lookup
    # These are prioritized over sector-specific CAOs in search results
    CORE_LAW_NUMACS = {
      # Oud Burgerlijk Wetboek (1804)
      '1804032150' => 'Oud BW Boek I - Personen',
      '1804032151' => 'Oud BW Boek II - Goederen/Eigendom',
      '1804032152' => 'Oud BW Boek III - Erfopvolging',
      '1804032153' => 'Oud BW Boek III - Schenkingen/Testamenten',
      '1804032154' => 'Oud BW Boek III - Verbintenissen/Contracten',
      '1804032155' => 'Oud BW Boek III - Bijzondere overeenkomsten',
      '1804032156' => 'Oud BW Boek III - Huwelijksvermogen',
      # Nieuw Burgerlijk Wetboek (2019-2025)
      '2022A32057' => 'Nieuw BW Boek 1 - Algemene bepalingen',
      '2022A30600' => 'Nieuw BW Boek 2 - Relatievermogensrecht',
      '2020A20347' => 'Nieuw BW Boek 3 - Goederen',
      '2022B30600' => 'BW Boek 4 - Erfrecht',
      '2022A32058' => 'Nieuw BW Boek 5 - Verbintenissen',
      '2024A01600' => 'Nieuw BW Boek 6 - Buitencontractuele aansprakelijkheid',
      '2019A12168' => 'Nieuw BW Boek 8 - Bewijs',
      '2025A05089' => 'Nieuw BW Boek 9 - Zekerheden',
      # Huwelijksvermogen
      '1976071406' => 'Wet huwelijksvermogen',
      # Gerechtelijk Wetboek
      '1967101052' => 'Gerechtelijk Wetboek - Deel I Algemene beginselen',
      '1967101053' => 'Gerechtelijk Wetboek - Deel II Rechterlijke organisatie',
      '1967101054' => 'Gerechtelijk Wetboek - Deel III Bevoegdheid',
      '1967101055' => 'Gerechtelijk Wetboek - Deel IV Burgerlijke rechtspleging',
      '1967101056' => 'Gerechtelijk Wetboek - Deel V Beslag en collectieve schuldenregeling',
      '1967101057' => 'Gerechtelijk Wetboek - Deel VI Arbitrage',
      '1967101063' => 'Gerechtelijk Wetboek - Deel VII Bemiddeling',
      '1967101064' => 'Gerechtelijk Wetboek - Deel VIII Collaboratieve onderhandeling',
      # Criminal Law. The 2024 code entered into force on 8 April 2026.
      '2024002052' => 'Strafwetboek Boek I - Algemene bepalingen',
      '2024002088' => 'Strafwetboek Boek II - Misdrijven en straffen',
      '1867060850' => 'Strafwetboek 1867 (historisch, feiten vóór 8 april 2026)',
      '1808111701' => 'Wetboek van Strafvordering',
      '1878041750' => 'Voorafgaande Titel Wetboek van Strafvordering',
      '2010A09589' => 'Sociaal Strafwetboek',
      # Constitutional
      '1994021048' => 'Grondwet',
      # Labor & Social
      '1971031602' => 'Arbeidswet',
      '1978070303' => 'Arbeidsovereenkomstenwet',
      '1971062850' => 'Jaarlijkse vakantiewet',
      '1967033001' => 'KB Uitvoeringsbesluit Vakantiegeld',
      '1996012650' => 'Welzijnswet',
      '1963082803' => 'KB Klein verlet',
      '1988050250' => 'CAO nr. 43 - Gewaarborgd gemiddeld minimummaandinkomen',
      # Corporate & Economic
      '2019A40586' => 'Wetboek van vennootschappen en verenigingen',
      '2013A11134' => 'Wetboek economisch recht',
      '2014011239' => 'Wet van 4 april 2014 betreffende de verzekeringen',
      # Intellectual Property - European Patent Convention
      '1973100550' => 'Europees Octrooiverdrag (EOV)',
      # Tax - Federal
      '1992041050' => 'WIB92 (Wetboek Inkomstenbelastingen)',
      '1993082751' => 'WIB92 (KB uitvoering)',
      '1969070305' => 'BTW-Wetboek',
      '1970072012' => 'KB nr. 20 BTW-tarieven en tarieftabellen',
      '1939113002' => 'W.Reg. (registratie-, hypotheek- en griffierechten)',
      '1936033102' => 'W.Succ. (Wetboek successierechten)',
      # Tax - Regional
      '2013036154' => 'Vlaamse Codex Fiscaliteit',
      # Environment - Regional (Flanders)
      '2009035580' => 'Energiedecreet',
      '2012035118' => 'Materialendecreet',
      '2006037062' => 'Bodemdecreet',
      # Housing
      '2018015087' => 'Vlaams Woninghuurdecreet',
      '2020A43545' => 'Vlaamse Codex Wonen',
      '2013A31614' => 'Brusselse Huisvestingscode',
      '1951043003' => 'Handelshuurwet',
      # Pensions
      '2024202431' => 'Pensioenhervorming 2024',
      # Social Security
      '1991013192' => 'Werkloosheidsbesluit',
      '1994071451' => 'Wet verplichte ziekteverzekering (ZIV)',
      '2002022559' => 'Leefloonwet',
      '1967102410' => 'KB nr. 50 werknemerspensioen',
      '1967061510' => 'KB uitkeringen werknemers',
      # Labor - Additional
      '1965041207' => 'Loonbeschermingswet',
      '1974010407' => 'Feestdagenwet',
      '1968120503' => 'Wet CAO en PC',
      '1987012597' => 'Uitzendarbeidswet',
      '2007002098' => 'Genderwet',
      '2007002099' => 'Antidiscriminatiewet',
      # Other
      '1921022450' => 'Drugswet',
      '1980121550' => 'Vreemdelingenwet',
      '2018015287' => 'Samenwerkingsakkoord gecombineerde vergunning (single permit)',
      '2007000528' => 'Camerawet',
      # Time credit / Career breaks
      '2001013224' => 'KB Tijdskrediet',
      # Social elections
      '1948092002' => 'Wet ondernemingsraden',
      # Early retirement / SWT
      '2010201753' => 'KB SWT (brugpensioen)',
      # IGO
      '2001022201' => 'Wet IGO',
      # Occupational diseases / accidents
      '1971041001' => 'Arbeidsongevallenwet',
      '1970060309' => 'Beroepsziektenwet',
      # Agricultural lease
      '1969110450' => 'Pachtwet',
      # Self-employed
      '1967072702' => 'KB nr 38 zelfstandigen',
      # Construction
      '1971070904' => 'Wet Breyne (woningbouw)',
      # Nationality
      '1984900065' => 'Wetboek Belgische nationaliteit',
      # Collective dismissals
      '1998012088' => 'Wet Renault (collectief ontslag)',
      # Birth leave
      '2001012470' => 'Wet geboorteverlof',
      # Spatial Planning / VCRO
      '2009A35738' => 'Vlaamse Codex Ruimtelijke Ordening (VCRO)',
      '2014036510' => 'Omgevingsvergunningsdecreet',
      '2010035645' => 'Vrijstellingenbesluit (omgevingsvergunning)',
      # Traffic
      '1968031601' => 'Wegverkeerswet',
      '1975120109' => 'KB Wegcode (1 december 1975)',
      '1998014078' => 'KB betreffende het rijbewijs',
      # Privacy / GDPR
      '2018040581' => 'Kaderwet gegevensbescherming (AVG)',
      # Healthcare
      '2002022737' => 'Wet Patiëntenrechten',
      '2002009590' => 'Euthanasiewet',
      '2002022868' => 'Wet palliatieve zorg',
      # Property / Co-ownership is codified in current Civil Code Book 3.
      # International Private Law
      '2004009511' => 'Wetboek IPR',
      # Criminal extras
      '1964061106' => 'Probatiewet',
      '1990099963' => 'Wet voorlopige hechtenis',
      '1992000606' => 'Wet op het politieambt',
      '2014009316' => 'Interneringswet',
      # Regional family benefits
      '2018040369' => 'Vlaams Groeipakketdecreet',
      # Mediation amending act (the consolidated rules are in Ger.W. Part VII)
      '2005021182' => 'Wet van 21 februari 2005 tot wijziging van het Gerechtelijk Wetboek inzake bemiddeling',
      # Environment
      '1991035487' => 'VLAREM',
      # Flexi-jobs
      '2015205102' => 'Wet flexi-jobs'
    }.freeze

    # Drug offences are governed by the 1921 enabling/penalty law together
    # with the current 6 September 2017 implementing decree. The former 1930
    # decree was repealed and must not be used as the only retrieval target.
    DRUG_REGIME_NUMACS = %w[1921022450 2017031231].freeze

    # Keywords that trigger inclusion of specific core laws (NL + FR bilingual)
    # Maps question keywords to relevant foundational law NUMACs
    KEYWORD_TO_CORE_LAWS = {
      # Employment contracts (NL)
      'opzegtermijn' => ['1978070303'],
      'opzeg' => ['1978070303'],
      'ontslag' => %w[1978070303 2010A09589],
      'kennelijk onredelijk' => ['1978070303'],
      'onredelijk ontslag' => ['1978070303'],
      'opzegging' => ['1978070303'],
      'dringende reden' => ['1978070303'],
      'arbeidsovereenkomst' => ['1978070303'],
      'concurrentiebeding' => ['1978070303'],
      'proefperiode' => ['1978070303'],
      'proeftijd' => ['1978070303'],
      'anciënniteit' => ['1978070303'],
      'ziekteverlof' => ['1978070303'],
      'ziekte' => ['1978070303'],
      'outplacement' => ['1978070303'],
      'scholingsbeding' => ['1978070303'],
      'schorsing' => ['1978070303'],
      'ontslagvergoeding' => ['1978070303'],
      'beschermde werknemer' => ['1978070303'],
      # Employment contracts (FR)
      'préavis' => ['1978070303'],
      'licenciement' => %w[1978070303 2010A09589],
      'contrat de travail' => ['1978070303'],
      'non-concurrence' => ['1978070303'],
      'période d\'essai' => ['1978070303'],
      'ancienneté' => ['1978070303'],
      # Working time (NL)
      'werktijd' => ['1971031602'],
      'arbeidsduur' => ['1971031602'],
      'overuren' => ['1971031602'],
      'zondagsarbeid' => %w[1971031602 1964070605],
      'zondagsrust' => %w[1964070605 1971031602],
      'zondag' => %w[1964070605 1971031602],
      'repos dominical' => ['1964070605'],
      'nachtarbeid' => ['1971031602'],
      'rusttijd' => %w[1971031602 1964070605],
      'telewerk' => ['1971031602'], # Remote work - Arbeidswet
      'thuiswerk' => ['1971031602'], # Home work - Arbeidswet
      'maximum werkuren' => ['1971031602'], # Max work hours (38u/week)
      'maximale werkuren' => ['1971031602'],
      'werkweek' => ['1971031602'],
      # Working time (FR)

      'temps de travail' => ['1971031602'],
      'durée du travail' => ['1971031602'],
      'heures supplémentaires' => ['1971031602'],
      'travail de nuit' => ['1971031602'],
      'travail du dimanche' => ['1971031602'],
      # Vacation & Leave (NL)
      'vakantie' => %w[1971062850 1967033001],
      'vakantiedagen' => %w[1971062850 1967033001],
      'vakantiegeld' => %w[1967033001 1971062850],
      'vertrekvakantiegeld' => ['1967033001'],
      'dubbel vakantiegeld' => ['1967033001'],
      'enkel vakantiegeld' => ['1967033001'],
      'verlof' => %w[1971062850 1963082803],
      'klein verlet' => %w[1963082803 1963082802],
      'sociaal verlof' => ['1963082803'], # Maps to KB Klein verlet for specific day counts
      'omstandigheidsverlof' => %w[1963082803 1963082802], # Another term for klein verlet
      'familiaal verlof' => ['1963082803'], # Family-related short leave
      'huwelijksverlof' => ['1963082803'], # Marriage leave (part of klein verlet)
      'overlijden verlof' => %w[1963082803 1963082802], # Bereavement leave
      'rouwverlof' => ['1963082803'],
      # Maternity/Paternity/Birth leave (NL) - Arbeidswet + AOW + specific Birth Leave Law
      # Added 2001012470 (Wet geboorteverlof), 2024008627 (RIZIV reg with "20 dagen" figure)
      # Added 2022040009, 2021030270, 2019012277 (articles with "15 weken" maternity content)
      'zwangerschapsverlof' => %w[2022040009 2021030270 2019012277 1971031602 1978070303],
      'zwangerschap' => %w[2022040009 1971031602],
      'moederschapsverlof' => %w[2022040009 2021030270 2019012277 1971031602 1978070303],
      'moederschap' => %w[2022040009 1971031602],
      'vaderschapsverlof' => %w[2001012470 2024008627 2022031410 1971031602 1978070303],
      'geboorteverlof' => %w[2001012470 2024008627 2022031410 1971031602 1978070303],
      'geboorte' => %w[2001012470 1978070303 1963082803],
      'verlof geboorte' => %w[2001012470 1978070303 1963082803],
      # Vacation & Leave (FR)
      'congé' => %w[1971062850 1967033001 1963082803],
      'vacances' => %w[1971062850 1967033001],
      'jours de congé' => %w[1971062850 1967033001],
      'pécule de vacances' => %w[1967033001 1971062850],
      'double pécule' => ['1967033001'],
      'simple pécule' => ['1967033001'],
      'petit chômage' => ['1963082803'],
      'congé social' => ['1963082803'], # French for sociaal verlof
      'congé de circonstance' => %w[1963082803 1963082802], # French for omstandigheidsverlof
      'congé familial' => ['1963082803'], # French for familiaal verlof
      'congé de mariage' => ['1963082803'], # Marriage leave
      'congé de deuil' => ['1963082803'],
      'décès' => ['1963082803'],

      # Maternity/Paternity (FR) - Added specific Birth Leave Law for "20 jours" and "15 semaines" retrieval
      'congé de maternité' => %w[2022040009 2021030270 2019012277 1971031602],
      'maternité' => %w[2022040009 1971031602],
      'congé de paternité' => %w[2001012470 2024008627 2022031410 1971031602],
      'paternité' => %w[2001012470 2024008627 2022031410 1971031602],
      'congé de naissance' => %w[2001012470 2024008627 2022031410 1971031602],
      'naissance' => %w[2001012470 1963082803],
      # Workplace safety (NL + FR)
      'welzijn' => ['1996012650'],
      'veiligheid' => ['1996012650'],
      'veiligheidsmaatregelen' => ['1996012650'],
      'arbeidsongevallen' => %w[1971041001 1996012650],
      'arbeidsongeval' => %w[1971041001 1996012650],
      'beroepsziekten' => ['1970060309'],
      'preventie' => ['1996012650'],
      'risicoanalyse' => ['1996012650'],
      'bien-être' => ['1996012650'],
      'sécurité' => ['1996012650'],
      'accident du travail' => %w[1971041001 1996012650],
      'accidents du travail' => %w[1971041001 1996012650],
      'maladies professionnelles' => ['1970060309'],
      'prévention' => ['1996012650'],
      # Criminal law (NL)
      'straf' => %w[2024002052 2024002088],
      'misdrijf' => %w[2024002052 2024002088],
      'diefstal' => ['2024002088'],
      'stelen' => ['2024002088'],
      'inbraak' => ['2024002088'],
      'slagen en verwondingen' => ['2024002088'],
      'geweld' => ['2024002088'],
      'moord' => ['2024002088'],
      'oplichting' => ['2024002088'],
      'fraude' => ['2024002088'],
      'mishandeling' => ['2024002088'],
      'verkrachting' => ['2024002088'],
      'belaging' => ['2024002088'],
      'stalking' => ['2024002088'],
      'huiszoeking' => ['1808111701'],
      'strafprocedure' => ['1808111701'],
      'aanhouding' => ['1808111701'],
      'voorhechtenis' => ['1808111701'],
      'vov' => ['2006009456'],
      'voorwaardelijk' => %w[2024002052 1964061106],
      'probatie' => %w[2024002052 1964061106],
      'werkstraf' => ['2024002052'],
      'salduz' => ['1808111701'],
      'advocaat verhoor' => ['1808111701'],
      'minnelijke schikking' => ['1808111701'],
      'transactie' => ['1808111701'],
      # Police detention / Politionele aanhouding (NL)
      'vasthouden' => %w[1992000606 1808111701 1990099963],
      'politie vasthouden' => %w[1992000606 1808111701 1990099963],
      'vasthouden politie' => %w[1992000606 1808111701 1990099963],
      'arrestatie' => %w[1992000606 1808111701],
      'administratieve aanhouding' => ['1992000606'],
      'bestuurlijke aanhouding' => ['1992000606'],
      'gerechtelijke aanhouding' => %w[1808111701 1990099963],
      'inverzekeringstelling' => %w[1808111701 1990099963],
      'voorlopige aanhouding' => %w[1808111701 1990099963],
      'politieambt' => ['1992000606'],
      'opsluiting' => %w[1808111701 1990099963],
      '24 uur politie' => %w[1994021048 1808111701],
      '48 uur' => %w[1808111701 1990099963],
      # Police detention (FR)
      'garde à vue' => %w[1992000606 1808111701 1990099963],
      'arrestation administrative' => ['1992000606'],
      'arrestation judiciaire' => %w[1808111701 1990099963],
      'détention préventive' => %w[1808111701 1990099963],
      'mise à disposition' => %w[1808111701 1990099963],
      'fonction de police' => ['1992000606'],
      'verjaring' => %w[1804032155 2022A32058], # Oud BW art. 2262bis + verbintenissencontext
      'verjaringstermijn' => %w[1804032155 2022A32058],
      'verjaring interesten' => ['1804032155'],
      'verjaring schuld' => ['1804032155'],
      'prescription' => %w[1804032155 2022A32058],
      'prescription civile' => %w[1804032155 2022A32058],
      'prescription contractuelle' => %w[1804032155 2022A32058],
      'verkrijgende verjaring' => ['2020A20347'], # Nieuw BW Boek 3 - Goederen
      'bevrijdende verjaring' => ['1804032155'],
      'prescription acquisitive' => ['2020A20347'],
      'prescription extinctive' => ['1804032155'],
      # Criminal prescription - only when explicitly criminal context
      'strafverjaring' => %w[1878041750 1808111701],
      'strafrechtelijke verjaring' => %w[1878041750 1808111701],
      'verjaring misdrijf' => %w[1878041750 1808111701],
      'verjaring strafrecht' => %w[1878041750 1808111701],
      'prescription pénale' => %w[1878041750 1808111701],
      # Drugs (NL) - Drugswet 1921 + current KB 6 september 2017
      'drugs' => DRUG_REGIME_NUMACS,
      'drugsbezit' => DRUG_REGIME_NUMACS,
      'verdovende middelen' => DRUG_REGIME_NUMACS,
      'cannabis' => DRUG_REGIME_NUMACS,
      'marihuana' => DRUG_REGIME_NUMACS,
      'cocaïne' => DRUG_REGIME_NUMACS,
      'heroïne' => DRUG_REGIME_NUMACS,
      'drugshandel' => DRUG_REGIME_NUMACS,
      'druggebruik' => DRUG_REGIME_NUMACS,
      'bezit drugs' => DRUG_REGIME_NUMACS,
      'drugsbeleid' => DRUG_REGIME_NUMACS,
      # Criminal law (FR)
      'peine' => ['2024002052'],
      'délit' => %w[2024002052 2024002088],
      'vol' => ['2024002088'],
      'vol qualifié' => ['2024002088'],
      'cambriolage' => ['2024002088'],
      'coups et blessures' => ['2024002088'],
      'meurtre' => ['2024002088'],
      'escroquerie' => ['2024002088'],
      'viol' => ['2024002088'],
      'harcèlement' => %w[2024002088 1996012650],
      'perquisition' => ['1808111701'],
      'procédure pénale' => ['1808111701'],
      'arrestation' => ['1808111701'],
      'détention' => ['1808111701'],
      'sursis' => %w[2024002052 1964061106],
      'probation' => %w[2024002052 1964061106],
      'transaction pénale' => ['1808111701'],
      # Drugs (FR) - loi de 1921 + arrêté royal actuel du 6 septembre 2017
      'drogue' => DRUG_REGIME_NUMACS,
      'stupéfiants' => DRUG_REGIME_NUMACS,
      'stupéfiant' => DRUG_REGIME_NUMACS,
      'détention de drogue' => DRUG_REGIME_NUMACS,
      'trafic de drogue' => DRUG_REGIME_NUMACS,
      # Civil law - Oud BW + Nieuw BW (NL)
      'contract' => %w[1804032154 2022A32058], # Verbintenissen (Oud BW still in force)
      'overeenkomst' => %w[1804032154 2022A32058], # Verbintenissen
      'contractuele schuld' => %w[1804032154 2022A32058], # Contractual debts
      'contractuele schulden' => %w[1804032154 2022A32058],
      'dettes contractuelles' => %w[1804032154 2022A32058],
      'verbintenis' => %w[1804032154 2022A32058], # Verbintenissen
      'eigendom' => %w[1804032151 2020A20347], # Goederen (Oud BW still in force)
      'bezit te goeder trouw' => %w[1804032151 2020A20347], # Good faith possession
      'possession de bonne foi' => %w[1804032151 2020A20347],
      # NOTE: 'bezit' removed - too generic, conflicts with "bezit van drugs"
      'erfenis' => %w[1804032152 1804032153 2022B30600], # Erfopvolging
      'erfrecht' => %w[1804032152 1804032153 2022B30600], # Erfopvolging
      'erfopvolging' => %w[1804032152 1804032153 2022B30600], # Erfopvolging
      'testament' => ['2022B30600'], # Current Book 4 testament regime
      'schenking' => %w[1804032153 2022B30600], # Schenkingen/Testamenten
      'erfgenaam' => %w[1804032152 2022B30600], # Erfgenamen
      'nalatenschap' => %w[1804032152 2022B30600], # Nalatenschappen
      'onterven' => %w[1804032153 2022B30600], # Reserve
      'reserve' => %w[1804032153 2022B30600], # Wettelijke reserve
      'huwelijksvermogen' => %w[1804032156 1976071406 2022A30600],
      'echtscheiding' => %w[1804032150 2022A30600],
      'samenwoning' => %w[1804032150 2022A30600], # statutory cohabitation remains in old BW arts. 1475-1479
      'wettelijke samenwoning' => ['1804032150'],
      'bewijs' => ['2019A12168'], # Nieuw BW Boek 8
      # NBW Boek 6 - Buitencontractuele aansprakelijkheid (NL)
      'aansprakelijkheid' => %w[2024A01600 1804032154],
      'buitencontractueel' => ['2024A01600'],
      'onrechtmatige daad' => ['2024A01600'],
      'schade' => ['2024A01600'],
      'schadevergoeding' => ['2024A01600'],
      'fout' => ['2024A01600'],
      # NBW Boek 9 - Zekerheden (NL)
      'zekerheid' => %w[2025A05089 2013A09377],
      'zekerheden' => %w[2025A05089 2013A09377],
      'hypotheek' => ['2025A05089'],
      'pand' => ['2025A05089'],
      'pandrecht' => ['2025A05089'],
      'borg' => ['2025A05089'],
      'borgstelling' => ['2025A05089'],
      'waarborg' => ['2025A05089'],
      # Civil law (FR)
      'contrat' => %w[1804032154 2022A32058],
      'obligation' => %w[1804032154 2022A32058],
      'propriété' => %w[1804032151 2020A20347],
      'succession' => %w[1804032152 1804032153 2022B30600],
      'héritage' => %w[1804032152 1804032153 2022B30600],
      'donation' => %w[1804032153 2022B30600],
      'régime matrimonial' => %w[1804032156 1976071406],
      'divorce' => %w[1804032150 2022A30600],
      'preuve' => ['2019A12168'],
      # NBW Boek 6 (FR)
      'responsabilité' => ['2024A01600'],
      'responsabilité extracontractuelle' => ['2024A01600'],
      'dommage' => ['2024A01600'],
      'faute' => ['2024A01600'],
      # NBW Boek 9 (FR)
      'sûretés' => ['2025A05089'],
      'hypothèque' => ['2025A05089'],
      'gage' => ['2025A05089'],
      'cautionnement' => ['2025A05089'],
      # Rental. Residential tenancy is regional, so an unqualified rental
      # word must not silently select Flanders or Brussels.
      'handelshuur' => ['1951043003'],
      # Corporate (NL + FR)
      'vennootschap' => ['2019A40586'],
      'bestuurder' => ['2019A40586'],
      'aandeelhouder' => ['2019A40586'],
      'vzw' => ['2019A40586'],
      'société' => ['2019A40586'],
      'administrateur' => ['2019A40586'],
      'actionnaire' => ['2019A40586'],
      'asbl' => ['2019A40586'],
      'bv' => ['2019A40586'],
      'nv' => ['2019A40586'],
      'jaarrekening' => ['2019A40586'],
      'algemene vergadering' => ['2019A40586'],
      'faillissement' => %w[2019A40586 2013A11134],
      'insolventie' => %w[2019A40586 2013A11134],
      'gerechtelijke reorganisatie' => ['2013A11134'],
      # Intellectual Property / Patents (NL)
      'octrooi' => %w[1973100550 2013A11134],
      'octrooien' => %w[1973100550 2013A11134],
      'octrooiaanvraag' => ['1973100550'],
      'europees octrooi' => ['1973100550'],
      'octrooiverdrag' => ['1973100550'],
      'uitvinding' => %w[1973100550 2013A11134],
      'intellectueel eigendom' => %w[2013A11134 1973100550],
      'intellectuele eigendom' => %w[2013A11134 1973100550],
      # Intellectual Property / Patents (FR)
      'brevet' => %w[1973100550 2013A11134],
      'brevets' => %w[1973100550 2013A11134],
      'brevet européen' => ['1973100550'],
      'demande de brevet' => ['1973100550'],
      'convention sur le brevet' => ['1973100550'],
      'invention' => %w[1973100550 2013A11134],
      'propriété intellectuelle' => %w[2013A11134 1973100550],
      # Consumer / Economic Law (NL)
      'garantie' => %w[1804032154 2013A11134],
      'herroepingsrecht' => ['2013A11134'],
      'consument' => ['2013A11134'],
      'consumentenrecht' => ['2013A11134'],
      'factuur' => ['2013A11134'],
      'solden' => ['2013A11134'],
      'promotie' => ['2013A11134'],
      'levering' => ['2013A11134'],
      'leveringstermijn' => ['2013A11134'],
      'productaansprakelijkheid' => ['2013A11134'],
      'handelspraktijk' => ['2013A11134'],
      'oneerlijke praktijk' => ['2013A11134'],
      'reclame' => ['2013A11134'],
      'prijsaanduiding' => ['2013A11134'],
      'consommateur' => ['2013A11134'],
      'droit de rétractation' => ['2013A11134'],
      'livraison' => ['2013A11134'],
      'soldes' => ['2013A11134'],
      'publicité' => ['2013A11134'],
      # Tax (NL + FR)
      # NOTE 2026-07-13: the consolidated BTW-Wetboek (1969070305), W.Reg.
      # (1939113002) and W.Succ. (1936033102) now HAVE articles in the main DB
      # (ingested from FisconetPlus), so bare tax keywords map to the codes
      # themselves — before the ingest they were empty shells and only
      # amendment KBs could be cited. Regional keys keep the VCF (2013036154)
      # alongside the federal codes (erfbelasting/registratie are regionalised:
      # VCF for Flanders, federal W.Succ./W.Reg. for Brussels/Wallonia).
      'belasting' => %w[1992041050 1993082751],
      'erfbelasting' => %w[2013036154 1936033102],
      'schenkbelasting' => %w[2013036154 1939113002],
      'onroerende voorheffing' => ['2013036154'],
      'vennootschapsbelasting' => %w[1992041050 1993082751],
      'kmo-tarief' => %w[1992041050 1993082751],
      'tarief vennootschap' => %w[1992041050 1993082751],
      'btw' => %w[1969070305 2024009391 2024009395 2023048636],
      'btw-tarief' => %w[1969070305 2024009391 2024009395 2023048636],
      'btw-tarieven' => %w[1969070305 2024009391 2024009395 2023048636],
      'taux de tva' => %w[1969070305],
      'omzetbelasting' => %w[1969070305 2024009391 2024009395],
      'toegevoegde waarde' => %w[1969070305 2024009391 2024009395],
      'inkomstenbelasting' => ['1993082751'],
      'personenbelasting' => ['1993082751'],
      'belastingaangifte' => ['1993082751'],
      'impôt' => %w[1993082751],
      'droits de succession' => %w[2013036154 1936033102],
      'droits de donation' => %w[2013036154 1939113002],
      'précompte immobilier' => ['2013036154'],
      'tva' => %w[1969070305 2024009391 2024009395 2023048636],
      # Pension (NL)
      'pensioen' => %w[2024202431 1967102410],
      'pensioenhervorming' => ['2024202431'],
      'rustpensioen' => %w[2024202431 1967102410],
      'overlevingspensioen' => %w[2024202431 1967102410],
      'pensioenstelsel' => ['2024202431'],
      # Pension (FR)
      'pension' => %w[2024202431 1967102410],
      'réforme des pensions' => ['2024202431'],
      'pension de retraite' => ['2024202431'],
      # Immigration (NL + FR)
      'verblijf' => ['1980121550'],
      'vreemdeling' => ['1980121550'],
      'nationaliteit' => %w[1984900065 1980121550], # Nationaliteitscode first
      'séjour' => ['1980121550'],
      'étranger' => ['1980121550'],
      'nationalité' => %w[1984900065 1980121550],
      # Single permit / Gecombineerde vergunning
      'gecombineerde vergunning' => ['2018015287'],
      'single permit' => ['2018015287'],
      'permis unique' => ['2018015287'],
      'permis combiné' => ['2018015287'],
      'kombinierte erlaubnis' => ['2018015287'],
      # Camera surveillance (NL + FR)
      'camera' => ['2007000528'],
      'bewakingscamera' => ['2007000528'],
      'camerabewaking' => ['2007000528'],
      'videobewaking' => ['2007000528'],
      'caméra' => ['2007000528'],
      'vidéosurveillance' => ['2007000528'],
      # Judicial / Procedural (NL + FR)
      'rechtszaak' => ['1967101055'],
      'procedure' => ['1967101055'],
      'dagvaarding' => ['1967101055'],
      'burgerlijk hoger beroep' => ['1967101055'],
      'hoger beroep burgerlijke zaak' => ['1967101055'],
      'hoger beroep in burgerlijke zaak' => ['1967101055'],
      'rechtbank' => ['1967101053'],
      'procès' => ['1967101055'],
      'tribunal' => ['1967101053'],
      'assignation' => ['1967101055'],
      'appel civil' => ['1967101055'],
      'appel en matière civile' => ['1967101055'],
      # Administrative law / Raad van State (NL + FR)
      'raad van state' => %w[1973011250 2006A21306],
      'conseil d\'état' => %w[1973011250 2006A21306],
      'rolrecht' => ['1973011250'],
      'rolrechten' => ['1973011250'],
      'administratief recht' => %w[1973011250 2006A21306],
      'droit administratif' => %w[1973011250 2006A21306],
      'bestuursrecht' => %w[1973011250 2006A21306],
      'insolvabiliteit' => ['2013A11134'],
      'faillite' => ['2013A11134'],
      # Family law - additions (NL)
      'co-ouderschap' => ['1804032150'],
      'ouderlijk gezag' => ['1804032150'],
      'hoederecht' => ['1804032150'],
      'verblijfsregeling' => ['1804032150'],
      'alimentatie' => ['1804032150'],
      'onderhoudsgeld' => ['1804032150'],
      'adoptie' => ['1804032150'],
      'afstamming' => ['1804032150'],
      'vaderschap' => ['1804032150'],
      'naam' => ['1804032150'],
      'naamswijziging' => ['1804032150'],
      'voogdij' => ['1804032150'],
      'minderjarig' => ['1804032150'],
      # Family law - additions (FR)
      'garde' => ['1804032150'],
      'hébergement' => ['1804032150'],
      'pension alimentaire' => ['1804032150'],
      'adoption' => ['1804032150'],
      'filiation' => ['1804032150'],
      'tutelle' => ['1804032150'],
      # Additional tax keywords
      'loonbelasting' => ['1993082751'],
      'aangifte' => ['1993082751'],
      'aftrek' => ['1993082751'],
      'pensioensparen' => ['1993082751'],
      'roerende voorheffing' => ['1993082751'],
      'dividend' => ['1993082751'],
      'bedrijfswagen belast' => ['1993082751'],
      'bedrijfswagen belasting' => ['1993082751'],
      'belasting op bedrijfswagen' => ['1993082751'],
      'voordeel alle aard' => ['1993082751'],
      'fiscale woonplaats' => ['1993082751'],
      'rijksinwoner' => ['1993082751'],
      'fiscaal voordeel' => ['1993082751'],
      'belastingvoordeel' => ['1993082751'],
      # Additional immigration
      'verblijfsvergunning' => ['1980121550'],
      'asiel' => ['1980121550'],
      'visum' => ['1980121550'],
      'uitwijzing' => ['1980121550'],
      'titre de séjour' => ['1980121550'],
      'asile' => ['1980121550'],
      'visa' => ['1980121550'],
      # Social criminal / zwartwerk
      'zwartwerk' => ['2010A09589'],
      'sociale fraude' => ['2010A09589'],
      'travail au noir' => ['2010A09589'],
      'fraude sociale' => ['2010A09589'],
      # Social Security - Unemployment (NL)
      'werkloosheid' => ['1991013192'],
      'werkloosheidsuitkering' => ['1991013192'],
      'werkloos' => ['1991013192'],
      'rva' => ['1991013192'],
      'onem' => ['1991013192'],
      'wachtuitkering' => ['1991013192'],
      # Social Security - Unemployment (FR)
      'chômage' => ['1991013192'],
      'allocation de chômage' => ['1991013192'],
      'télétravail' => ['1971031602'], # Remote work (FR) - Arbeidswet
      'travail à domicile' => ['1971031602'], # Home work (FR)
      # Early retirement / Brugpensioen / SWT
      'brugpensioen' => %w[1991013192 2010201753], # Now called SWT - via RVA
      'swt' => %w[1991013192 2010201753], # Stelsel werkloosheid met bedrijfstoeslag
      'werkloosheid met bedrijfstoeslag' => %w[1991013192 2010201753],
      'prépension' => ['1991013192'], # French for brugpensioen

      # Social Security - coordinated statutory health insurance (ZIV/AMI).
      # NUMAC 1994071450 is an unrelated election-information order; the
      # source-specific importer validates and ingests the real law below.
      'ziekteverzekering' => ['1994071451'],
      'verplichte ziekteverzekering' => ['1994071451'],
      'ziekenfonds' => ['1994071451'],
      'mutualiteit' => ['1994071451'],
      'riziv' => ['1994071451'],
      'remgeld' => ['1994071451'],
      'persoonlijk aandeel' => ['1994071451'],
      'maximumfactuur' => ['1994071451'],
      'arbeidsongeschiktheidsuitkering' => ['1994071451'],
      'invaliditeitsuitkering' => ['1994071451'],
      'invaliditeit' => ['1994071451'],
      'progressieve werkhervatting' => ['1994071451'],
      'toegelaten arbeid' => ['1994071451'],
      'derdebetalersregeling' => ['1994071451'],
      'geconventioneerde arts' => ['1994071451'],
      'moederschapsuitkering' => ['1994071451'],
      'verhoogde tegemoetkoming' => ['1994071451'],
      'assurance maladie' => ['1994071451'],
      'mutuelle' => ['1994071451'],
      'inami' => ['1994071451'],
      'incapacité de travail' => ['1994071451'],
      'invalidité' => ['1994071451'],
      # A bare refund can concern either consumer law or health insurance;
      # narrower article pins below disambiguate high-confidence medical cases.
      'terugbetaling' => %w[1994071451 2013A11134],
      # Private/supplementary hospitalisation policies. Do not broaden these
      # to "ziekteverzekering", which denotes the statutory ZIV regime.
      'hospitalisatieverzekering' => ['2014011239'],
      'hospitalisatiepolis' => ['2014011239'],
      'assurance hospitalisation' => ['2014011239'],
      "assurance d'hospitalisation" => ['2014011239'],
      'assurance hospitalière' => ['2014011239'],
      'hospital insurance' => ['2014011239'],
      'hospitalisation insurance' => ['2014011239'],
      'hospitalization insurance' => ['2014011239'],
      'krankenhauszusatzversicherung' => ['2014011239'],
      # Social Security - OCMW/Leefloon (NL)
      'leefloon' => ['2002022559'],
      'ocmw' => ['2002022559'],
      'maatschappelijke integratie' => ['2002022559'],
      'bijstand' => ['2002022559'],
      # Social Security - CPAS/RIS (FR)
      'revenu d\'intégration' => ['2002022559'],
      'cpas' => ['2002022559'],
      'aide sociale' => ['2002022559'],
      # Child benefits are regional and underdetermined without a region.
      # Only explicit Flemish terminology is safe for this federal-law boost.
      'groeipakket' => ['2018040369'],
      'vlaamse kinderbijslag' => ['2018040369'],
      'kinderbijslag vlaanderen' => ['2018040369'],
      'allocations familiales flandre' => ['2018040369'],
      # Wage Protection (NL)
      'minimumloon' => ['1988050250'],
      'ggmmi' => ['1988050250'],
      'gewaarborgd gemiddeld minimum maandinkomen' => ['1988050250'],
      'loonbescherming' => ['1965041207'],
      'loonbeslag' => ['1965041207'],
      'loonoverdracht' => ['1965041207'],
      # Wage Protection (FR)
      'salaire minimum' => ['1988050250'],
      'rmmmg' => ['1988050250'],
      'revenu minimum mensuel moyen' => ['1988050250'],
      'protection de la rémunération' => ['1965041207'],
      'saisie sur salaire' => ['1965041207'],
      # Public Holidays (NL)
      'feestdag' => ['1974010407'],
      'feestdagen' => ['1974010407'],
      'wettelijke feestdag' => ['1974010407'],
      # Public Holidays (FR)
      'jour férié' => ['1974010407'],
      'jours fériés' => ['1974010407'],
      # Collective Agreements (NL)
      'cao' => ['1968120503'],
      'collectieve arbeidsovereenkomst' => ['1968120503'],
      'paritair comité' => ['1968120503'],
      # Collective Agreements (FR)
      'cct' => ['1968120503'],
      'convention collective' => ['1968120503'],
      'commission paritaire' => ['1968120503'],
      # Temporary Work (NL)
      'uitzendarbeid' => ['1987012597'],
      'uitzendwerk' => ['1987012597'],
      'interim' => ['1987012597'],
      'uitzendkracht' => ['1987012597'],
      'uitzendbureau' => ['1987012597'],
      # Temporary Work (FR)
      'travail intérimaire' => ['1987012597'],
      'intérim' => ['1987012597'],
      'agence d\'intérim' => ['1987012597'],
      # Anti-discrimination (NL)
      'discriminatie' => %w[2007002098 2007002099 1994021048],
      'gelijke behandeling' => %w[2007002098 2007002099],
      'gelijkheid' => %w[2007002098 2007002099],
      'racisme' => ['2007002099'],
      'weigeren' => %w[2007002098 2007002099],
      'klant weigeren' => %w[2007002098 2007002099],
      # Anti-discrimination (FR)
      'discrimination' => %w[2007002098 2007002099],
      'égalité' => %w[2007002098 2007002099],
      # Psychosocial Risks / Harassment (NL)
      'pesten' => ['1996012650'],
      'pestgedrag' => ['1996012650'],
      'ongewenst gedrag' => ['1996012650'],
      'psychosociaal' => ['1996012650'],
      'burnout' => ['1996012650'],
      'stress' => ['1996012650'],
      # Psychosocial Risks / Harassment (FR)
      # harcèlement already mapped above with merged NUMACs
      'harcèlement moral' => ['1996012650'],
      'risques psychosociaux' => ['1996012650'],
      # Time credit / Career breaks (NL)
      'tijdskrediet' => ['2001013224'],
      'loopbaanonderbreking' => ['2001013224'],
      'thematisch verlof' => ['2001013224'],
      # Time credit (FR)
      'crédit-temps' => ['2001013224'],
      'interruption de carrière' => ['2001013224'],
      # Social elections (NL)
      'sociale verkiezingen' => ['1948092002'],
      'ondernemingsraad' => ['1948092002'],
      'comité preventie' => ['1948092002'],
      # Social elections (FR)
      'élections sociales' => ['1948092002'],
      'canada dry' => ['2010201753'], # Colloquial for pseudo-brugpensioen
      'pseudo-brugpensioen' => ['2010201753'],
      # IGO - Income guarantee elderly (NL)
      'inkomensgarantie' => ['2001022201'],
      'igo' => ['2001022201'],
      # Adoption leave
      'adoptieverlof' => %w[1978070303 1971031602],
      # Occupational diseases (NL)
      'beroepsziekte' => ['1970060309'],
      'fedris' => ['1971041001'],
      # Occupational diseases (FR)
      'maladie professionnelle' => ['1970060309'],
      # Agricultural lease (NL)
      'pacht' => ['1969110450'],
      'pachtovereenkomst' => ['1969110450'],
      'landbouwpacht' => ['1969110450'],
      # Agricultural lease (FR)
      'bail à ferme' => ['1969110450'],
      # Marriage contract (NL)
      'huwelijkscontract' => %w[1976071406 1804032156],
      'huwelijksvermogensstelsel' => %w[1976071406 1804032156],
      # Self-employed (NL)
      'zelfstandige' => ['1967072702'],
      'sociaal statuut zelfstandigen' => ['1967072702'],
      'bijberoep' => ['1967072702'],
      'rsvz' => ['1967072702'],
      # TRAFFIC / WEGCODE (NL) - Weak category: 53%
      'verkeer' => %w[1968031601 1975120109],
      'wegverkeer' => ['1968031601'],
      'wegcode' => %w[1968031601 1975120109],
      'snelheid' => %w[1968031601 1975120109],
      'snelheidsovertreding' => ['1968031601'],
      'maximumsnelheid' => %w[1968031601 1975120109],
      'rood licht' => ['1968031601'],
      'rijbewijs' => %w[1968031601 1998014078],
      'rijverbod' => ['1968031601'],
      'alcoholcontrole' => ['1968031601'],
      'alcohol verkeer' => ['1968031601'],
      'promille' => ['1968031601'],
      'verkeersongeval' => ['1968031601'],
      'aanrijding' => ['1968031601'],
      'vluchtmisdrijf' => ['1968031601'],
      'parkeren' => ['1975120109'],
      'boete verkeer' => ['1968031601'],
      'verkeersboete' => ['1968031601'],
      'pv verkeer' => ['1968031601'],
      # TRAFFIC / CODE DE LA ROUTE (FR)
      'circulation' => %w[1968031601 1975120109],
      'code de la route' => %w[1968031601 1975120109],
      'vitesse' => %w[1968031601 1975120109],
      'excès de vitesse' => ['1968031601'],
      'permis de conduire' => %w[1968031601 1998014078],
      'alcool au volant' => ['1968031601'],
      'accident de la route' => ['1968031601'],
      # BTW / TVA - Weak category: 21%
      'btw-aangifte' => ['1969070305'],
      'btw-aftrek' => ['1969070305'],
      'btw-vrijstelling' => ['1969070305'],
      'btw-plichtig' => ['1969070305'],
      'intracommunautair' => ['1969070305'],
      'invoer btw' => ['1969070305'],
      'uitvoer btw' => ['1969070305'],
      'verlegde btw' => ['1969070305'],
      'medecontractant' => ['1969070305'],
      'déclaration tva' => ['1969070305'],
      'déduction tva' => ['1969070305'],
      'exonération tva' => ['1969070305'],
      # BTW renovation/construction - common questions
      'btw renovatie' => %w[1969070305 2000003841],
      'btw verbouwing' => %w[1969070305 2000003841],
      'btw nieuwbouw' => %w[1969070305],
      'btw afbraak heropbouw' => %w[1969070305 2000003841],
      '6% btw' => %w[1969070305 2000003841],
      '21% btw' => %w[1969070305],
      'verlaagd btw-tarief' => %w[1969070305 2000003841],
      'btw bouw' => ['1969070305'],
      'btw aannemer' => ['1969070305'],
      'tva rénovation' => %w[1969070305 2000003841],
      'taux réduit tva' => %w[1969070305 2000003841],
      # WIB / PERSONENBELASTING - Weak category: 41%
      'wib' => ['1992041050'],
      'wib92' => ['1992041050'],
      'beroepskosten' => ['1992041050'],
      'forfaitaire kosten' => ['1992041050'],
      'belastingvrije som' => ['1992041050'],
      'kinderen ten laste' => ['1992041050'],
      'huwelijksquotiënt' => ['1992041050'],
      'kadastraal inkomen' => %w[1992041050 2013036154],
      'onroerend inkomen' => ['1992041050'],
      'roerend inkomen' => ['1992041050'],
      'buitenlands inkomen' => ['1992041050'],
      'dubbelbelasting' => ['1992041050'],
      'tax shelter' => ['1992041050'],
      'revenu professionnel' => ['1992041050'],
      'frais professionnels' => ['1992041050'],
      'quotité exemptée' => ['1992041050'],
      # REGISTRATIERECHTEN - Weak category: 43%
      # VCF for Flanders + federal W.Reg./W.Succ. (Brussels/Wallonia; ingested
      # from FisconetPlus 2026-07-13, previously empty shells)
      'registratierecht' => %w[2013036154 1939113002],
      'registratierechten' => %w[2013036154 1939113002],
      'registratiebelasting' => %w[2013036154 1939113002],
      'verkooprecht' => %w[2013036154 1939113002],
      'verdeelrecht' => %w[2013036154 1939113002],
      'schenkingsrecht' => %w[2013036154 1939113002],
      'successierecht' => %w[2013036154 1936033102],
      'erfenisbelasting' => %w[2013036154 1936033102],
      'droits d\'enregistrement' => %w[2013036154 1939113002],
      'droits de vente' => %w[2013036154 1939113002],
      # CONSUMER / WER - Weak category: 45-50%
      'wer' => ['2013A11134'],
      'wetboek economisch recht' => ['2013A11134'],
      'code économique' => ['2013A11134'],
      'bedenktijd' => ['2013A11134'],
      'afkoelingsperiode' => ['2013A11134'],
      'wettelijke garantie' => ['1804032154'],
      '2 jaar garantie' => ['1804032154'],
      'verborgen gebrek' => ['1804032154'],
      'conformiteit' => ['1804032154'],
      'non-conformiteit' => ['1804032154'],
      'e-commerce' => ['2013A11134'],
      'online aankoop' => ['2013A11134'],
      'webshop' => ['2013A11134'],
      'verkoop op afstand' => ['2013A11134'],
      'colportage' => ['2013A11134'],
      'misleidende reclame' => ['2013A11134'],
      'oneerlijke handelspraktijk' => ['2013A11134'],
      'gekoppelde verkoop' => ['2013A11134'],
      'délai de réflexion' => ['2013A11134'],
      'vente à distance' => ['2013A11134'],
      'pratique commerciale déloyale' => ['2013A11134'],
      # HEALTH LAW - Weak category: 15% - Added Jan 2026
      'patiëntenrechten' => %w[2002022737 2002S82909],
      'patiëntenrecht' => ['2002022737'],
      'informed consent' => %w[2002022737 2002S82909],
      'geïnformeerde toestemming' => ['2002022737'],
      'medisch dossier' => %w[2002022737 2002S82909],
      'inzagerecht dossier' => ['2002022737'],
      'euthanasie' => %w[2002009590 2002052810],
      'levenseinde' => %w[2002009590 2002052810],
      'palliatieve zorg' => %w[2002022868 2002052810],
      'orgaandonatie' => %w[1986062458 1986062452],
      'medische fout' => ['2002022737'],
      'medische aansprakelijkheid' => ['2002022737'],
      'beroepsgeheim arts' => ['2002022737'],
      'geheimhouding medisch' => ['2002022737'],
      'droits du patient' => ['2002022737'],
      'consentement éclairé' => ['2002022737'],
      'dossier médical' => ['2002022737'],
      'fin de vie' => ['2002009590'],
      'soins palliatifs' => ['2002022868'],
      "don d'organes" => ['1986062458'],
      'erreur médicale' => ['2002022737'],
      # COMPANY LAW ADDITIONS - Weak category: 14.8%
      'oprichting vennootschap' => ['2019A40586'],
      'statutenwijziging' => ['2019A40586'],
      'ontbinding vennootschap' => ['2019A40586'],
      'vereffening' => ['2019A40586'],
      'dagelijks bestuur' => ['2019A40586'],
      'bestuurdersaansprakelijkheid' => ['2019A40586'],
      'kapitaalverhoging' => ['2019A40586'],
      'inbreng natura' => ['2019A40586'],
      'alarmbelprocedure' => ['2019A40586'],
      'winstuitkering' => ['2019A40586'],
      'dissolution société' => ['2019A40586'],
      'liquidation' => ['2019A40586'],
      'responsabilité des administrateurs' => ['2019A40586'],
      # CONSTRUCTION LAW - Wet Breyne (1971): "waarborg" is ambiguous, needs explicit mapping
      'wet breyne' => ['1971070904'],
      'loi breyne' => ['1971070904'],
      'breyne' => ['1971070904'],
      'nieuwbouw' => ['1971070904'],
      'bouwgarantie' => ['1971070904'],
      'tienjarige aansprakelijkheid' => ['1971070904'],
      'woningbouw' => ['1971070904'],
      'aannemer aansprakelijkheid' => ['1971070904'],
      'bouwgebreken' => ['1971070904'],
      'te bouwen woning' => ['1971070904'],
      'in aanbouw' => ['1971070904'],
      'oplevering woning' => ['1971070904'],
      'construction neuve' => ['1971070904'],
      'garantie décennale' => ['1971070904'],
      'responsabilité entrepreneur' => ['1971070904'],
      # VRIJSTELLINGENBESLUIT - omgevingsvergunning (2010)
      'vrijstellingenbesluit' => ['2010035645'],
      'vrijstelling omgevingsvergunning' => ['2010035645'],
      'geen vergunning nodig' => ['2010035645'],
      'vergunningsvrij' => ['2010035645'],
      'meldingsplichtig' => ['2010035576'],
      'exemption permis' => ['2010035645'],
      # COLLECTIVE DISMISSALS - Wet Renault (1998): Q437
      'wet renault' => ['1998012088'],
      'collectief ontslag' => ['1998012088'],
      'massaontslag' => ['1998012088'],
      'loi renault' => ['1998012088'],
      'licenciement collectif' => ['1998012088'],
      'huwelijk verlof' => ['1963082802'],
      'geboorte verlof' => ['2001012470'], # Geboorteverlof wet
      # NATIONALITY - Wetboek Belgische nationaliteit: Q328
      'nationaliteitsverklaring' => ['1984900065'],
      'belgische nationaliteit' => ['1984900065'],
      'naturalisatie' => ['1984900065'],
      'nationaliteitscode' => ['1984900065'],
      'nationalité belge' => ['1984900065'],
      # ARBITRAGE - Gerechtelijk Wetboek art. 1676-1723: Q474
      'arbitrage' => ['1967101057'],
      'scheidsrechter' => ['1967101057'],
      'arbitration' => ['1967101057'],
      # DUBLIN REGULATION - is EU law, often referenced via Vreemdelingenwet: Q336
      'dublin reglement' => ['1980121550'],
      'asielaanvraag' => ['1980121550'],
      'règlement dublin' => ['1980121550'],
      # WOEKER (usury) - Strafwetboek + Handelspraktijkenwet: Q304
      'woeker' => %w[2024002088 2013A11134],
      'usure' => %w[2024002088 2013A11134],
      'dop' => ['1991013192'],
      'ziv' => ['1994071451'],
      'bail commercial' => ['1951043003'],
      'huurhernieuwing' => ['1951043003'],
      'landbouwgrond' => ['1969110450'],
      # EPC obligations are in the Energiedecreet, not the VCF. Woningpas is
      # deliberately not force-mapped: it is a product spanning several
      # Flemish data regimes and needs retrieval-specific evidence.
      'epc' => ['2009035580'],
      'energieprestatiecertificaat' => ['2009035580'],
      # Mede-eigendom
      'appartementswet' => ['2020A20347'],
      'mede-eigendom' => ['2020A20347'],
      'syndicus' => ['2020A20347'],
      'copropriété' => ['2020A20347'],
      'retourrecht' => ['2013A11134'],
      'verborgen gebreken' => ['1804032154'],
      'oneerlijke handelspraktijken' => ['2013A11134'],
      'consumentenkrediet' => ['2013A11134'],
      'jaarlijks kostenpercentage' => ['2013A11134'],
      'jkp' => ['2013A11134'],
      'taeg' => ['2013A11134'],
      # === ADMINISTRATIVE LAW (25.7% weak) ===
      'verblijfskaart' => ['1980121550'],
      'a-kaart' => ['1980121550'],
      'b-kaart' => ['1980121550'],
      'f-kaart' => ['1980121550'],
      'regularisatie' => ['1980121550'],
      'gezinshereniging' => ['1980121550'],
      'regroupement familial' => ['1980121550'],
      'familienzusammenführung' => ['1980121550'],
      'family reunification' => ['1980121550'],
      'vergunning onbepaalde' => ['1980121550'],
      # Grondwet
      'grondrecht' => ['1994021048'],
      'vrijheid meningsuiting' => ['1994021048'],
      'privacy' => %w[1994021048 2018040581],
      # GDPR / AVG / Data Protection (NL)
      'avg' => ['2018040581'],
      'gdpr' => ['2018040581'],
      'gegevensbescherming' => %w[2018040581 1994021048],
      'persoonsgegevens' => ['2018040581'],
      'verwerking gegevens' => ['2018040581'],
      'toestemming gegevens' => ['2018040581'],
      'gegevensverwerking' => ['2018040581'],
      'recht op vergetelheid' => ['2018040581'],
      'datalek' => ['2018040581'],
      'dpo' => ['2018040581'],
      'functionaris gegevensbescherming' => ['2018040581'],
      # GDPR / RGPD (FR)
      'rgpd' => ['2018040581'],
      'protection des données' => %w[2018040581 1994021048],
      'données personnelles' => ['2018040581'],
      'traitement de données' => ['2018040581'],
      'délégué à la protection' => ['2018040581'],
      'violation de données' => ['2018040581'],
      'recht op informatie' => ['2002S82909'],
      'therapeutische vrijheid' => ['2002S82909'],
      'transplantatie' => ['1986062452'],
      # === CRIMINAL LAW extras ===
      'fpc' => ['2014009316'],
      'internering' => ['2014009316'],
      'tbs' => ['2014009316'],
      'voorlopige hechtenis' => ['1990099963'],
      'voorwaardelijke invrijheidstelling' => ['2006009456'],
      'libération conditionnelle' => ['2006009456'],
      'misdrijven' => %w[2024002052 2024002088],
      'overtreding' => %w[2024002052 2024002088],
      'wanbedrijf' => %w[2024002052 2024002088],
      'misdaad' => %w[2024002052 2024002088],
      'strafbaar feit' => %w[2024002052 2024002088],
      'infraction' => %w[2024002052 2024002088],
      'contravention' => %w[2024002052 2024002088],
      'crime' => %w[2024002052 2024002088],
      # Probation / Opschorting - Probatiewet
      'opschorting' => ['1964061106'], # Probatiewet only - civil 'opschorting' shouldn't inject Strafwetboek
      'opschorting uitspraak' => %w[1964061106 2024002052], # Explicitly criminal context
      'opschorting straf' => %w[1964061106 2024002052],
      'uitstel' => ['1964061106'],
      'probatievoorwaarden' => ['1964061106'],
      'suspension du prononcé' => ['1964061106'],
      # Witnesses / Getuigen - Art. 86bis-86quater Sv.
      'getuige' => ['1808111701'],
      'getuigen' => ['1808111701'],
      'getuigenis' => ['1808111701'],
      'getuigenissen' => ['1808111701'],
      'anonieme getuige' => ['1808111701'],
      'anonieme getuigenissen' => ['1808111701'],
      'beschermde getuige' => ['1808111701'],
      'témoin' => ['1808111701'],
      'témoin anonyme' => ['1808111701'],
      'témoignage' => ['1808111701'],
      'strafvordering' => ['1808111701'],
      'opsporingsonderzoek' => ['1808111701'],
      'gerechtelijk onderzoek' => ['1808111701'],
      'onderzoeksrechter' => ['1808111701'],
      'parket' => ['1808111701'],
      'openbaar ministerie' => ['1808111701'],
      'procureur' => ['1808111701'],
      'instruction' => ['1808111701'],
      'juge d\'instruction' => ['1808111701'],
      'ministère public' => ['1808111701'],
      # Persons in law - Burgerlijk Wetboek
      'rechtspersoon' => ['2019A40586'],
      'natuurlijke persoon' => %w[1804032150 2016009215],
      # 'persoon' removed - too generic, triggers on virtually every question
      'personne morale' => ['2019A40586'],
      'personne physique' => %w[1804032150 2016009215],

      # === CONSUMER LAW IMPROVEMENTS (was 39.9%) ===
      # Digital content & services
      'digitale inhoud' => ['2013A11134'],
      'digitale dienst' => ['2013A11134'],
      'streaming' => ['2013A11134'],
      'software aankoop' => ['2013A11134'],
      'app store' => ['2013A11134'],
      'in-app aankoop' => ['2013A11134'],
      # Guarantee specifics
      'refurbished' => ['1804032154'],
      'tweedehands garantie' => ['1804032154'],
      'herstelling garantie' => ['1804032154'],
      'vervanging product' => ['1804032154'],
      'gebrek product' => ['1804032154'],
      'bewijslast garantie' => ['1804032154'],
      'omkering bewijslast' => ['1804032154'],
      # Online shopping
      'webshop retour' => ['2013A11134'],
      'online bestelling' => ['2013A11134'],
      'verzendkosten retour' => ['2013A11134'],
      'annuleren online' => ['2013A11134'],
      'faillissement verkoper' => ['2013A11134'],
      # French consumer terms
      'contenu numérique' => ['2013A11134'],
      'garantie légale' => ['1804032154'],
      'vice caché' => ['1804032154'],
      'achat en ligne' => ['2013A11134'],
      'remboursement' => ['2013A11134'],

      # === LABOR SPECIAL IMPROVEMENTS (was 35.3%) ===
      # Discrimination at work
      'discriminatie werk' => %w[2007002098 2007002099],
      'unia' => %w[2007002098 2007002099],
      'gelijke kansen' => %w[2007002098 2007002099],
      'positieve actie' => %w[2007002098 2007002099],
      'beschermde criteria' => ['2007002099'],
      # Workplace safety
      'arbeidsinspectie' => ['1996012650'],
      'preventieadviseur' => ['1996012650'],
      'pbm' => ['1996012650'],
      'persoonlijke beschermingsmiddelen' => ['1996012650'],
      'cpbw' => ['1996012650'],
      'veiligheidscomité' => ['1996012650'],
      # Special worker statuses
      'kunstenaarsstatuut' => ['1967072702'],
      'platformwerker' => ['2010A09589'],
      'flexi-job' => ['2015205102'],
      'studentenarbeid' => ['1978070303'],
      'jobstudent' => ['1978070303'],
      # French labor special
      'inspection du travail' => ['1996012650'],
      'conseiller en prévention' => ['1996012650'],
      'équipement protection' => ['1996012650'],
      'artiste' => ['1967072702'],

      # === ADMINISTRATIVE LAW IMPROVEMENTS (was 38.9%) ===
      # VCRO - Vlaamse Codex Ruimtelijke Ordening (NL)
      'vcro' => ['2009A35738'],
      'vlaamse codex ruimtelijke ordening' => ['2009A35738'],
      'ruimtelijke ordening' => %w[2009A35738 2014036510],
      'stedenbouw' => ['2009A35738'],
      'stedenbouwkundig' => ['2009A35738'],
      'stedenbouwmisdrijf' => ['2009A35738'],
      'stedenbouwovertreding' => ['2009A35738'],
      'bouwovertreding' => ['2009A35738'],
      'bouwmisdrijf' => ['2009A35738'],
      'herstelvordering' => ['2009A35738'],
      'herstelmaatregel' => ['2009A35738'],
      'stakingsbevel' => ['2009A35738'],
      'bouwen zonder vergunning' => ['2009A35738'],
      'illegale constructie' => ['2009A35738'],
      'illegaal gebouw' => ['2009A35738'],
      'bestemmingswijziging' => ['2009A35738'],
      'zonevreemd' => ['2009A35738'],
      'zonevreemde woning' => ['2009A35738'],
      # VCRO (FR)
      'code flamand aménagement' => ['2009A35738'],
      'aménagement du territoire' => %w[2009A35738 2014036510],
      'infraction urbanistique' => ['2009A35738'],
      'action en réparation' => ['2009A35738'],
      'ordre de cessation' => ['2009A35738'],
      # Permits & planning - Omgevingsvergunningsdecreet
      'omgevingsvergunning' => ['2014036510'],
      'omgevingsloket' => ['2014036510'],
      'openbaar onderzoek' => ['2014036510'],
      'bestemmingsplan' => ['2014036510'],
      'rup' => ['2014036510'],
      'ruimtelijk uitvoeringsplan' => ['2014036510'],
      'verkavelingsvergunning' => ['2014036510'],
      'stedenbouwkundig attest' => %w[2014036510 2009A35738],
      'vlarem' => ['1991035487'],
      'milieuvergunning' => ['1991035487'],
      'planschade' => %w[2014036510 2009A35738],
      'planbaten' => %w[2014036510 2009A35738],
      # Municipal/government
      'gemeentebestuur' => ['1988062452'],
      'schepencollege' => ['1988062452'],
      'gemeentelijk reglement' => ['1988062452'],
      'administratief beroep' => ['1973011250'],
      'raad voor vergunningsbetwistingen' => ['2014036510'],
      # French admin terms
      'permis environnement' => ['1991035487'],
      'permis urbanisme' => ['2014036510'],
      'enquête publique' => ['2014036510'],
      'recours administratif' => ['1973011250'],

      # === COMPANY LAW IMPROVEMENTS (was 44.9%) ===
      'vof' => ['2019A40586'],
      'commanditaire vennootschap' => ['2019A40586'],
      'commv' => ['2019A40586'],
      'coöperatieve' => ['2019A40586'],
      'cv' => ['2019A40586'],
      'start-up visum' => ['2019A40586'],
      'financieel plan' => ['2019A40586'],
      'bedrijfsrevisor' => ['2019A40586'],
      'belgisch staatsblad' => ['2019A40586'],
      'eenpersoons-bv' => ['2019A40586'],
      'aandelen' => ['2019A40586'],
      'winstbewijzen' => ['2019A40586'],
      'stemovereenkomst' => ['2019A40586'],
      'apport en nature' => ['2019A40586'],
      'réviseur entreprises' => ['2019A40586'],

      # === HEALTH LAW IMPROVEMENTS (was 41.7%) ===
      'therapeutische hardnekkigheid' => ['2002009590'],
      'wilsverklaring' => ['2002009590'],
      'voorafgaande wilsverklaring' => ['2002009590'],
      'negatieve wilsverklaring' => ['2002022737'],
      'beroepsgeheim' => ['2002022737'],
      'vaccinatie verplicht' => ['2002022737'],
      'bloedtransfusie' => ['2002022737'],
      'testament donatie' => ['1986062458'],
      # French health
      'déclaration anticipée' => ['2002009590'],
      'obstination déraisonnable' => ['2002009590'],
      'secret médical' => ['2002022737'],

      # === MISCELLANEOUS/IPR IMPROVEMENTS (was 39.8%) ===
      # International private law
      'internationaal privaatrecht' => ['2004009511'],
      'ipr' => ['2004009511'],
      'toepasselijk recht' => ['2004009511'],
      'buitenlands vonnis' => ['2004009511'],
      'erkenning vonnis' => ['2004009511'],
      'kinderontvoering' => ['2004009511'],
      'brussel verordening' => ['2004009511'],
      'rome verordening' => ['2004009511'],
      # Notary/procedure
      'notaris' => ['1803030150'],
      'authentieke akte' => ['1803030150'],
      'derdenbeslissing' => ['1967101055'],
      'bemiddeling' => ['1967101063'],
      'mediatie' => ['1967101063'],
      'mediation' => ['1967101063'],
      'mediation civile' => ['1967101063'],
      'advocaat verzekering' => ['2006022662'],
      'deurwaarder' => ['1967101053'], # Gerechtelijk Wetboek - judicial organization
      'uithuiszetting' => %w[1967101056 2018015087], # Eviction: enforcement + rental law
      # French misc
      'droit international privé' => ['2004009511'],
      'reconnaissance jugement' => ['2004009511'],
      'enlèvement enfant' => ['2004009511'],
      'médiation' => ['1967101063'],
      'huissier' => ['1967101053'], # FR: bailiff → judicial organization

      # === GERMAN (DE) KEYWORD MAPPINGS - GesetzGuide support ===
      # Employment / Arbeitsrecht
      'arbeitsvertrag' => ['1978070303'],
      'kündigungsfrist' => ['1978070303'],
      'kündigung' => %w[1978070303 2010A09589],
      'entlassung' => %w[1978070303 2010A09589],
      'abfindung' => ['1978070303'],
      'probezeit' => ['1978070303'],
      'urlaubstage' => ['1971062850'],
      'urlaub' => ['1971062850'],
      'arbeitszeit' => ['1971031602'],
      'überstunden' => ['1971031602'],
      'nachtarbeit' => ['1971031602'],
      'mindestlohn' => ['1978070303'],
      'elternzeit' => %w[2001012470 1971031602],
      'mutterschutz' => %w[2022040009 1971031602],
      'vaterschaftsurlaub' => %w[2001012470 2024008627],
      # Residential tenancy is regional; generic German terms are retrieved
      # through RegionalSearch only after region scoping.
      'gewerbemiete' => ['1951043003'],
      # Criminal / Strafrecht
      'straftat' => %w[2024002052 2024002088],
      'diebstahl' => ['2024002088'],
      'hausdurchsuchung' => ['1808111701'],
      'verhaftung' => ['1808111701'],
      'strafe' => ['2024002052'],
      'anwalt' => ['1808111701'],
      # Family / Familienrecht
      'scheidung' => %w[1804032150 2022A30600],
      'unterhalt' => %w[1804032150 2022A30600],
      'sorgerecht' => ['1804032150'],
      'erbschaft' => %w[1804032152 2022B30600],
      # Corporate / Gesellschaftsrecht
      'gesellschaft' => ['2019A40586'],
      'gmbh' => ['2019A40586'],
      'geschäftsführer' => ['2019A40586'],
      'gesellschafter' => ['2019A40586'],
      # Tax / Steuerrecht
      'einkommensteuer' => ['1992041050'],
      'mehrwertsteuer' => %w[2024009391 1969070305],
      'erbschaftsteuer' => %w[2013036154 1936033102],
      'erbschaftssteuer' => %w[2013036154 1936033102],
      'schenkungsteuer' => %w[2013036154 1939113002],
      'schenkungssteuer' => %w[2013036154 1939113002],
      'steuer' => %w[1993082751],
      'widerruf' => ['2013A11134'],
      'verbraucher' => ['2013A11134'],
      'onlinekauf' => ['2013A11134'],
      # Social Security / Sozialversicherung
      'arbeitslosengeld' => ['1991013192'],
      'rente' => ['1967102410'],
      'krankenversicherung' => ['1994071451'],
      'sozialhilfe' => ['2002022559'],
      'arbeitsunfähigkeit' => ['1994071451'],
      'invalidität' => ['1994071451'],
      'berufskrankheit' => ['1970060309'],
      'arbeitsunfall' => %w[1996012650 1971041001],
      # GDPR / Datenschutz
      'datenschutz' => %w[2018040581 1994021048],
      'dsgvo' => ['2018040581'],
      'personenbezogene daten' => ['2018040581'],
      'privatsphäre' => %w[1994021048 2018040581],
      'einwilligung' => ['2018040581'],
      'recht auf vergessenwerden' => ['2018040581'],
      'datenschutzbeauftragter' => ['2018040581'],
      'datenpanne' => ['2018040581'],
      # Traffic / Verkehrsrecht
      'verkehr' => %w[1968031601 1975120109],
      'geschwindigkeit' => %w[1968031601 1975120109],
      'geschwindigkeitsüberschreitung' => ['1968031601'],
      'führerschein' => %w[1968031601 1998014078],
      'fahrverbot' => ['1968031601'],
      'alkohol am steuer' => ['1968031601'],
      'verkehrsunfall' => ['1968031601'],
      'parken' => ['1975120109'],
      'bußgeld' => ['1968031601'],
      # Health Law / Gesundheitsrecht
      'patientenrechte' => %w[2002022737 2002S82909],
      'einverständniserklärung' => ['2002022737'],
      'patientenakte' => ['2002022737'],
      'sterbehilfe' => %w[2002009590 2002052810],
      'organspende' => %w[1986062458 1986062452],
      'ärztehaftung' => ['2002022737'],
      'palliativpflege' => %w[2002022868 2002052810],
      # Discrimination / Diskriminierungsschutz
      'diskriminierung' => %w[2007002098 2007002099 1994021048],
      'gleichbehandlung' => %w[2007002098 2007002099],
      'rassismus' => ['2007002099'],
      'mobbing' => ['1996012650'],
      'belästigung' => ['1996012650'],
      # Immigration / Ausländerrecht
      'aufenthalt' => ['1980121550'],
      'aufenthaltserlaubnis' => ['1980121550'],
      'asyl' => ['1980121550'],
      # 'familienzusammenführung' already mapped (line 923)
      'ausweisung' => ['1980121550'],
      'staatsangehörigkeit' => ['1984900065'],
      # Judicial / Gerichtsverfahren
      'gerichtsverfahren' => ['1967101055'],
      'klage' => ['1967101055'],
      'zivilrechtliche berufung' => ['1967101055'],
      'berufung im zivilverfahren' => ['1967101055'],
      'gericht' => ['1967101053'],
      'vollstreckung' => ['1967101056'],
      'schiedsverfahren' => ['1967101057'],
      # Administrative / Verwaltungsrecht
      'verwaltungsrecht' => %w[1973011250 2006A21306],
      'staatsrat' => %w[1973011250 2006A21306],
      # Construction / Baurecht
      'neubau' => ['1971070904'],
      'baugarantie' => ['1971070904'],
      'baumängel' => ['1971070904'],
      # Collective Agreements / Tarifvertrag
      'tarifvertrag' => ['1968120503'],
      'betriebsrat' => ['1948092002'],
      'zeitarbeit' => ['1987012597'],
      'leiharbeit' => ['1987012597'],

      # === ENGLISH (EN) KEYWORD MAPPINGS - International/benchmark support ===
      # Family law
      'marriage' => ['1804032150'],
      # 'divorce' already mapped above (FR section, line 282)
      'child support' => ['1804032150'],
      'alimony' => ['1804032150'],
      'custody' => ['1804032150'],
      'inheritance' => %w[1804032152 2022B30600],
      'heir' => %w[1804032152 2022B30600],
      # 'adoption' already mapped above (FR section, line 439)
      # Criminal law
      'alcohol' => ['1968031601'],
      'driving licence' => %w[1968031601 1998014078],
      'driving license' => %w[1968031601 1998014078],
      'traffic fine' => ['1968031601'],
      'traffic offence' => ['1968031601'],
      'criminal' => %w[2024002052 2024002088],
      'theft' => ['2024002088'],
      'sentence' => ['2024002052'],
      'prosecution' => ['1808111701'],
      # Residential tenancy is regional; generic English terms must not pick
      # Flanders/Brussels before the user identifies the applicable region.
      # Corporate law
      'annual accounts' => ['2019A40586'],
      'filing' => ['2019A40586'],
      'shareholder' => ['2019A40586'],
      'general meeting' => ['2019A40586'],
      'company' => ['2019A40586'],
      'director' => ['2019A40586'],
      'bankruptcy' => %w[2019A40586 2013A11134],
      'insolvency' => %w[2019A40586 2013A11134],
      'articles of association' => ['2019A40586'],
      # Tax law
      'vat' => %w[2024009391 2024009395 2023048636],
      'tax' => %w[1993082751],
      'income tax' => ['1993082751'],
      'corporate tax' => ['1993082751'],
      'inheritance tax' => %w[2013036154 1936033102],
      'gift tax' => %w[2013036154 1939113002],
      'registration tax' => %w[2013036154 1939113002],
      'property tax' => ['2013036154'],
      # Consumer law
      'guarantee' => ['2013A11134'],
      'warranty' => ['2013A11134'],
      'consumer' => ['2013A11134'],
      'withdrawal' => ['2013A11134'],
      'cooling off' => ['2013A11134'],
      'hidden defect' => ['2013A11134'],
      'online purchase' => ['2013A11134'],
      'refund' => ['2013A11134'],
      # Employment
      'dismissal' => ['1978070303'],
      'notice period' => ['1978070303'],
      'employment contract' => ['1978070303'],
      'public holiday' => ['1974010407'],
      'holiday' => ['1971062850'],
      'minimum wage' => ['1978070303'],
      'maternity leave' => %w[2022040009 1971031602],
      'paternity leave' => %w[2001012470 2024008627],
      'working hours' => ['1971031602'],
      'overtime' => ['1971031602'],
      'sick leave' => ['1978070303'],
      'bereavement leave' => ['1963082803'],
      # Social security
      'unemployment' => ['1991013192'],
      'disability benefit' => ['1994071451'],
      'health insurance' => ['1994071451'],
      # 'pension' already mapped above (FR section, line 384)
      # Other
      'nationality' => ['1984900065'],
      'immigration' => ['1980121550'],
      'residence permit' => ['1980121550'],
      # 'gdpr' already mapped above (NL section, line 825)
      'data protection' => %w[2018040581 1994021048],
      # Consumer credit / APR (EN)
      'consumer credit' => ['2013A11134'],
      'apr' => ['2013A11134'],
      'annual percentage rate' => ['2013A11134'],
      'maximum interest rate' => ['2013A11134'],
      'property inventory' => %w[2018015087 2013A31614],
      'condition report' => %w[2018015087 2013A31614],
      'short-term rental' => %w[2018015087 2013A31614],
      'hidden defects real estate' => %w[1804032154 2013A11134],

      # === GERMAN CONSUMER ADDITIONS (benchmark gaps) ===
      # Consumer credit / APR (DE)
      'verbraucherkredit' => ['2013A11134'],
      'jahreszins' => ['2013A11134'],
      'effektiver jahreszins' => ['2013A11134'],
      'maximaler zinssatz' => ['2013A11134'],
      'konsumentenkredit' => ['2013A11134'],
      # Hidden defects (DE)
      'versteckter mangel' => %w[1804032154 2013A11134],
      'versteckte mängel' => %w[1804032154 2013A11134],
      'gewährleistung immobilien' => %w[1804032154 2013A11134],
      # Hidden defects (FR) - immobilier specifics
      'vices cachés immobilier' => %w[1804032154 1971070904],
      'garantie décennale immobilier' => ['1971070904'],

      # === ORPHANED CORE LAW KEYWORDS (May 2026 audit fix) ===
      # Only NEW keywords not already defined above

      # BW Erfrecht extras (1804032152 + 2022B30600)
      'erfgenamen' => %w[1804032152 2022B30600],
      'wettelijke erfgenamen' => %w[1804032152 2022B30600],
      'reserve erfrecht' => %w[1804032152 2022B30600],
      'inbreng erfenis' => %w[1804032152 2022B30600],
      'wettelijk erfdeel' => %w[1804032152 2022B30600],
      'beschikbaar deel' => %w[1804032153 2022B30600],
      'héritiers légaux' => %w[1804032152 2022B30600],
      'réserve héréditaire' => %w[1804032152 2022B30600],
      'héritier' => %w[1804032152 2022B30600],
      'Erbe' => %w[1804032152 2022B30600],
      'gesetzliche Erben' => %w[1804032152 2022B30600],
      'Pflichtteil' => %w[1804032152 2022B30600],

      # BW Schenkingen/Testamenten extras (1804032153)
      'legaat' => %w[1804032153 2022B30600],
      'handgift' => ['1804032153'],
      'notariële schenking' => ['1804032153'],
      'herroeping schenking' => ['1804032153'],
      'legs' => ['1804032153'],
      'testament olographe' => ['2022B30600'],
      'Testament' => ['2022B30600'],
      'Schenkung' => ['1804032153'],
      'Vermächtnis' => ['1804032153'],

      # BW Verbintenissen extras (1804032154 + 2022A32058)
      'wanprestatie' => %w[1804032154 2022A32058],
      'ontbinding contract' => %w[1804032154 2022A32058],
      'résolution contrat' => %w[1804032154 2022A32058],
      'Vertrag' => %w[1804032154 2022A32058],
      'Vertragsverletzung' => %w[1804032154 2022A32058],

      # BW Goederen/Eigendom extras (1804032151 + 2020A20347)
      'eigendomsrecht' => %w[1804032151 2020A20347],
      'vruchtgebruik' => %w[1804032151 2020A20347],
      'erfpacht' => %w[1804032151 2020A20347],
      'erfdienstbaarheid' => %w[1804032151 2020A20347],
      'opstalrecht' => %w[1804032151 2020A20347],
      'usufruit' => %w[1804032151 2020A20347],
      'Eigentum' => %w[1804032151 2020A20347],
      'Nießbrauch' => %w[1804032151 2020A20347],

      # BW Bijzondere overeenkomsten (1804032155)
      'koop' => ['1804032155'],
      'koopovereenkomst' => ['1804032155'],
      'verborgen gebrek koop' => ['1804032155'],
      'lastgeving' => ['1804032155'],
      'volmacht' => ['1804032155'],
      'borgtocht' => %w[1804032155 2025A05089],
      'vente' => ['1804032155'],
      'mandat' => ['1804032155'],
      'Kauf' => ['1804032155'],
      'Bürgschaft' => %w[1804032155 2025A05089],

      # BW Huwelijksvermogen extras (1804032156 + 1976071406)
      'gemeenschap goederen' => %w[1804032156 1976071406],
      'scheiding goederen' => %w[1804032156 1976071406],
      'aanwinsten' => %w[1804032156 1976071406],
      'communauté biens' => %w[1804032156 1976071406],
      'séparation biens' => %w[1804032156 1976071406],
      'Gütergemeinschaft' => %w[1804032156 1976071406],
      'Gütertrennung' => %w[1804032156 1976071406],
      'eheliches Güterrecht' => %w[1804032156 1976071406],

      # Nieuw BW Boek 1 - Algemene bepalingen (2022A32057)
      'rechtsmisbruik' => ['2022A32057'],
      'goede trouw' => ['2022A32057'],
      'abus de droit' => ['2022A32057'],
      'bonne foi' => ['2022A32057'],

      # Nieuw BW Boek 6 extras (2024A01600) - DE translations
      'dommages intérêts' => ['2024A01600'],
      'Haftung' => ['2024A01600'],
      'Schadensersatz' => ['2024A01600'],

      # Nieuw BW Boek 8 extras (2019A12168)
      'bewijslast' => ['2019A12168'],
      'bewijsmiddelen' => ['2019A12168'],
      'charge de la preuve' => ['2019A12168'],
      'Beweis' => ['2019A12168'],
      'Beweislast' => ['2019A12168'],

      # Nieuw BW Boek 9 extras (2025A05089) - DE translations
      'Hypothek' => ['2025A05089'],
      'Pfandrecht' => ['2025A05089'],

      # Genderwet (2007002098)
      'genderidentiteit' => ['2007002098'],
      'geslachtsdiscriminatie' => ['2007002098'],
      'loonkloof' => %w[2007002098 2007002099],
      'man vrouw gelijk' => ['2007002098'],
      'identité genre' => ['2007002098'],
      'écart salarial' => ['2007002098'],
      'Geschlechtsdiskriminierung' => ['2007002098'],
      'Lohngleichheit' => ['2007002098'],

      # KB uitkeringen werknemers (1967061510)
      'uitkering werknemer' => ['1967061510'],
      'ziekte-uitkering' => ['1967061510'],
      'gewaarborgd loon' => %w[1967061510 1978070303],
      'indemnité maladie' => ['1967061510'],
      'allocation maladie' => ['1967061510'],
      'Krankengeld' => ['1967061510'],

      # Brusselse Huisvestingscode (2013A31614)
      'brusselse huur' => ['2013A31614'],
      'bruxelles logement' => ['2013A31614'],
      'bail bruxellois' => ['2013A31614'],
      'code bruxellois logement' => ['2013A31614'],
      'Brüsseler Wohnungsrecht' => ['2013A31614'],

      # Vlaams Woninghuurdecreet (2018015087), only with an explicit region.
      'vlaams woninghuurdecreet' => ['2018015087'],
      'vlaamse woninghuur' => ['2018015087'],
      'woninghuur vlaanderen' => ['2018015087'],
      'huurcontract vlaanderen' => ['2018015087'],
      'vlaamse huurwaarborg' => ['2018015087'],
      'bail flamand' => ['2018015087'],
      'bail en flandre' => ['2018015087'],

      # Vlaamse Codex Wonen (2020A43545)
      'sociaal wonen' => ['2020A43545'],
      'sociale huur' => ['2020A43545'],
      'conformiteitsattest' => ['2020A43545'],
      'woonkwaliteit' => ['2020A43545'],
      'woningkwaliteit' => ['2020A43545'],
      'logement social' => ['2020A43545'],

      # Nieuw BW Boek 2 extras (2022A30600)
      'relatievermogen' => ['2022A30600'],
      'wettelijk samenwonen' => ['1804032150'],
      'cohabitation légale' => ['1804032150'],
      'nichteheliche Lebensgemeinschaft' => ['2022A30600'],

      # Wet rijbewijs (1998014078)
      'rijexamen' => ['1998014078'],
      'voorlopig rijbewijs' => ['1998014078'],
      'rijgeschiktheid' => ['1998014078'],
      'permis provisoire' => ['1998014078'],
      'examen conduite' => ['1998014078'],
      'Fahrprüfung' => ['1998014078']
    }.freeze

    # Boost factor for core laws (multiplied with similarity score)
    # Increased from 1.5 to 2.0 for stronger prioritization of foundational laws over CAOs
    CORE_LAW_BOOST = 2.0

    # Penalty factor for sector-specific CAOs (less relevant for general questions)
    CAO_PENALTY = 0.6

    # Penalty for FISCONET (tax) sources when question is NOT about tax
    # Prevents tax law pollution for consumer/employment questions
    # Reduced from 0.5 to 0.3 - a fisconet source with relevance 1.0 drops to 0.3,
    # ensuring tax articles don't appear in non-tax query results
    FISCONET_PENALTY = 0.3

    # Minimum relevance score for sources to appear in the API response.
    # Sources below this are considered noise and excluded from user output.
    # Cosine scale (0..1) since the 2026-07-13 metric-aware faiss serve.
    # MIN_SOURCE_RELEVANCE is the CORE-law floor (core sources are boosted and
    # cap at 1.0, so this is a low safety floor); NONCORE_SOURCE_RELEVANCE is
    # the floor for unboosted sources (raw cosine). Pre-2026-07-13 these were
    # 0.6 / 0.8 against a squared-L2 distance and, once similarity became
    # cosine, would have culled every non-core source.
    MIN_SOURCE_RELEVANCE = 0.30
    NONCORE_SOURCE_RELEVANCE = 0.45

    # Profile-based boost factor for category-preferred laws
    # Nudge, not restrict: results from preferred laws get boosted, others are NOT penalized
    PROFILE_BOOST = 1.5

    # Context law boost: applied when the user is viewing a specific law page and asks a question
    # This is the strongest boost - the user is literally looking at this law, so articles from it
    # should be prioritized (e.g., "wanneer treedt deze wet in werking?" on the AOW page)
    CONTEXT_LAW_BOOST = 2.5

    # Maps chatbot profile (category) to preferred law NUMACs
    # These are the laws most likely to contain the answer for a given category.
    # FAISS still searches ALL 2.76M articles - these just get a similarity boost.
    PROFILE_PREFERRED_NUMACS = {
      'general' => [], # No preference - all laws equal
      'tax' => %w[
        1992041050 1993082751 1969070305 2013036154
        2024009391 2024009395 2023048636 2000003841
      ],
      'labor' => %w[
        1978070303 1971031602 1971062850 1967033001 1963082803
        1996012650 1965041207 1974010407 1968120503 1987012597
        2001013224 2010A09589 2001012470 1948092002 2010201753
        1971041001 1963082802 2024008627 2022031410
      ],
      'corporate' => %w[
        2019A40586 2013A11134 1973100550
      ],
      'real_estate' => %w[
        2018015087 2013A31614 1951043003 1971070904
        2009A35738 2014036510 2020A43545
        1804032151 2020A20347 1969110450
      ],
      'family' => %w[
        1804032150 1804032152 1804032153 1804032156
        2022A30600 2022B30600 1976071406 1967101052
      ],
      'migration' => %w[
        1980121550 1984900065 2018015287
      ],
      'consumer' => %w[
        2013A11134
      ],
      'criminal' => %w[
        2024002052 2024002088 1808111701 2010A09589
        1968031601 1975120109 1998014078
        1964061106 1990099963 2014009316 1921022450
      ],
      'social' => %w[
        1991013192 1994071451 2002022559 1967102410
        1967061510 2024202431 2001022201 1967072702
      ],
      'administrative' => %w[
        1973011250 2006A21306 2009A35738 2014036510
      ],
      'privacy' => %w[
        2018040581 2007000528
      ]
    }.freeze

    # Query expansion mappings for hybrid search (Feb 2026)
    # Expands user query terms with synonyms and inflections for better BM25 matching
    QUERY_EXPANSIONS = {
      # Criminal law
      'misdrijf' => %w[misdrijven misdaad wanbedrijf overtreding strafbaar feit],
      'misdrijven' => %w[misdrijf misdaad wanbedrijf overtreding],
      'opschorting' => %w[uitstel probatie schorsing opgeschorte],
      'getuige' => %w[getuigen getuigenis verklaring getuigenverklaring],
      'straf' => %w[straffen bestraffing sanctie veroordeling],
      # Persons
      'rechtspersoon' => %w[vennootschap onderneming bedrijf entiteit],
      'natuurlijke persoon' => %w[individu burger particulier persoon],
      # Employment
      'werknemer' => %w[arbeider bediende loontrekkende],
      'werkgever' => %w[patroon ondernemer bedrijf],
      'ontslag' => %w[ontslagen beëindiging verbreking opzeg],
      'opzegtermijn' => %w[opzeg opzegging vooropzeg],
      # Civil law
      'schenking' => %w[gift donatie begiftigde schenker],
      'erfenis' => %w[nalatenschap successie overlijden testament],
      'huur' => %w[huurcontract verhuur verhuurder huurder],
      # Consumer
      'garantie' => %w[waarborg verzekering defect],
      'consument' => %w[koper klant afnemer],
      # Prescription / Verjaring
      'verjaring' => %w[verjaringstermijn vervaltermijn prescription termijn],
      'verjaringstermijn' => %w[verjaring termijn vervaltermijn prescription]
    }.freeze

    # Follow-up suggestions based on detected topics (NL + FR bilingual)
    FOLLOW_UP_SUGGESTIONS = {
      # Employment - NL
      'opzeg' => {
        nl: ['Wat is de opzegvergoeding bij ontslag?', 'Kan ik ontslagen worden tijdens ziekte?',
             'Wat zijn mijn rechten bij collectief ontslag?'],
        fr: ['Quelle est l\'indemnité de préavis?', 'Puis-je être licencié pendant une maladie?',
             'Quels sont mes droits en cas de licenciement collectif?']
      },
      'ontslag' => {
        nl: ['Hoe bereken ik mijn opzegtermijn?', 'Wat is ontslag om dringende reden?', 'Heb ik recht op werkloosheidsuitkering?'],
        fr: ['Comment calculer mon préavis?', 'Qu\'est-ce qu\'un licenciement pour motif grave?', 'Ai-je droit aux allocations de chômage?'],
        en: ['How do I calculate my notice period?', 'What is dismissal for serious misconduct?', 'Am I entitled to unemployment benefits?']
      },
      'dismissal' => {
        nl: ['Hoe bereken ik mijn opzegtermijn?', 'Wat is ontslag om dringende reden?', 'Heb ik recht op werkloosheidsuitkering?'],
        fr: ['Comment calculer mon préavis?', 'Qu\'est-ce qu\'un licenciement pour motif grave?', 'Ai-je droit aux allocations de chômage?'],
        en: ['How do I calculate my notice period?', 'What is dismissal for serious misconduct?', 'Am I entitled to unemployment benefits?']
      },
      'vakantie' => {
        nl: ['Hoeveel vakantiegeld krijg ik?', 'Wat als ik ziek word tijdens vakantie?', 'Kan mijn werkgever mijn vakantie weigeren?'],
        fr: ['Combien de pécule de vacances vais-je recevoir?', 'Que se passe-t-il si je tombe malade pendant mes vacances?',
             'Mon employeur peut-il refuser mes vacances?']
      },
      'verlof' => {
        nl: ['Hoeveel dagen klein verlet bij overlijden?', 'Wat is ouderschapsverlof?', 'Heb ik recht op tijdskrediet?'],
        fr: ['Combien de jours de petit chômage pour un décès?', 'Qu\'est-ce que le congé parental?', 'Ai-je droit au crédit-temps?']
      },
      'loon' => {
        nl: ['Wat is het minimumloon in België?', 'Wanneer moet mijn loon betaald worden?', 'Heb ik recht op een eindejaarspremie?'],
        fr: ['Quel est le salaire minimum en Belgique?', 'Quand mon salaire doit-il être payé?', 'Ai-je droit à une prime de fin d\'année?']
      },
      'arbeidsduur' => {
        nl: ['Hoeveel overuren mag ik werken?', 'Wat zijn de regels voor nachtarbeid?', 'Heb ik recht op rusttijden?'],
        fr: ['Combien d\'heures supplémentaires puis-je faire?', 'Quelles sont les règles du travail de nuit?',
             'Ai-je droit à des temps de repos?']
      },
      # Employment - FR triggers
      'préavis' => {
        nl: ['Hoe bereken ik mijn opzegtermijn?', 'Wat is de opzegvergoeding?', 'Kan ik ontslagen worden tijdens ziekte?'],
        fr: ['Comment calculer mon préavis?', 'Quelle est l\'indemnité de préavis?', 'Puis-je être licencié pendant une maladie?']
      },
      'licenciement' => {
        nl: ['Wat is ontslag om dringende reden?', 'Heb ik recht op werkloosheidsuitkering?',
             'Wat zijn mijn rechten bij collectief ontslag?'],
        fr: ['Qu\'est-ce qu\'un licenciement pour motif grave?', 'Ai-je droit aux allocations de chômage?',
             'Quels sont mes droits en cas de licenciement collectif?']
      },
      'congé' => {
        nl: ['Hoeveel vakantiedagen heb ik?', 'Wat is ouderschapsverlof?', 'Hoeveel dagen klein verlet?'],
        fr: ['Combien de jours de congé ai-je?', 'Qu\'est-ce que le congé parental?', 'Combien de jours de petit chômage?']
      },
      # Rental
      'huur' => {
        nl: ['Wat is de maximale huurwaarborg?', 'Wanneer mag de verhuurder de huur verhogen?',
             'Wat zijn mijn rechten bij verkoop van de woning?'],
        fr: ['Quel est le montant maximum de la garantie locative?', 'Quand le propriétaire peut-il augmenter le loyer?',
             'Quels sont mes droits en cas de vente du bien?']
      },
      'locataire' => {
        nl: ['Wat is de maximale huurwaarborg?', 'Wanneer mag de verhuurder de huur verhogen?', 'Hoe kan ik mijn huurcontract opzeggen?'],
        fr: ['Quel est le montant maximum de la garantie locative?', 'Quand le propriétaire peut-il augmenter le loyer?',
             'Comment résilier mon bail?']
      },
      'bail' => {
        nl: ['Wat is de opzegtermijn voor een huurcontract?', 'Wat zijn mijn rechten als huurder?', 'Wat is de maximale huurwaarborg?'],
        fr: ['Quel est le délai de préavis pour un bail?', 'Quels sont mes droits en tant que locataire?',
             'Quel est le montant maximum de la garantie locative?']
      },
      # Criminal
      'straf' => {
        nl: ['Wat is het verschil tussen een misdrijf en een overtreding?', 'Wanneer verjaart een misdrijf?',
             'Wat zijn mijn rechten bij een verhoor?'],
        fr: ['Quelle est la différence entre un délit et une contravention?', 'Quand un délit est-il prescrit?',
             'Quels sont mes droits lors d\'un interrogatoire?']
      },
      'peine' => {
        nl: ['Wat is het verschil tussen een misdrijf en een overtreding?', 'Wanneer verjaart een misdrijf?',
             'Wat zijn verzachtende omstandigheden?'],
        fr: ['Quelle est la différence entre un délit et une contravention?', 'Quand un délit est-il prescrit?',
             'Que sont les circonstances atténuantes?']
      },
      'vol' => {
        nl: ['Wat is diefstal met verzwarende omstandigheden?', 'Wat is de straf voor heling?', 'Wanneer is er sprake van afpersing?'],
        fr: ['Qu\'est-ce que le vol avec circonstances aggravantes?', 'Quelle est la peine pour recel?', 'Quand parle-t-on d\'extorsion?']
      },
      # Family
      'echtscheiding' => {
        nl: ['Hoe wordt alimentatie berekend?', 'Wat gebeurt er met de kinderen bij echtscheiding?', 'Hoe wordt het vermogen verdeeld?'],
        fr: ['Comment la pension alimentaire est-elle calculée?', 'Que se passe-t-il avec les enfants lors d\'un divorce?',
             'Comment le patrimoine est-il partagé?']
      },
      # 'divorce' entry at line 1595 has EN/DE translations - using that instead
      # 'divorce' => {
      #   nl: ['Hoe wordt alimentatie berekend?', 'Wat is echtscheiding door onderlinge toestemming?', 'Hoe wordt het vermogen verdeeld?'],
      #   fr: ['Comment la pension alimentaire est-elle calculée?', 'Qu\'est-ce que le divorce par consentement mutuel?',
      #        'Comment le patrimoine est-il partagé?']
      # },
      'erfenis' => {
        nl: ['Hoeveel erfbelasting moet ik betalen?', 'Wat zijn de rechten van de langstlevende?', 'Kan ik een erfenis weigeren?'],
        fr: ['Combien de droits de succession dois-je payer?', 'Quels sont les droits du conjoint survivant?', 'Puis-je refuser un héritage?']
      },
      'succession' => {
        nl: ['Hoeveel erfbelasting moet ik betalen?', 'Wat zijn de rechten van kinderen?', 'Kan ik een erfenis weigeren?'],
        fr: ['Combien de droits de succession dois-je payer?', 'Quels sont les droits des enfants?', 'Puis-je refuser un héritage?']
      },
      # English triggers
      'employment' => {
        nl: ['Hoe bereken ik mijn opzegtermijn?', 'Wat is ontslag om dringende reden?', 'Heb ik recht op werkloosheidsuitkering?'],
        fr: ['Comment calculer mon préavis?', 'Qu\'est-ce qu\'un licenciement pour motif grave?', 'Ai-je droit aux allocations de chômage?'],
        en: ['How do I calculate my notice period?', 'What are my rights during dismissal?', 'Am I entitled to unemployment benefits?']
      },
      'contract' => {
        nl: ['Wat zijn de verplichte vermeldingen in een arbeidsovereenkomst?', 'Kan mijn werkgever mijn contract wijzigen?',
             'Wat is het verschil tussen bepaalde en onbepaalde duur?'],
        fr: ['Quelles sont les mentions obligatoires dans un contrat de travail?', 'Mon employeur peut-il modifier mon contrat?',
             'Quelle est la différence entre CDD et CDI?'],
        en: ['What must be included in an employment contract?', 'Can my employer change my contract?',
             'What is the difference between fixed-term and permanent contracts?'],
        de: ['Was muss in einem Arbeitsvertrag stehen?', 'Kann mein Arbeitgeber meinen Vertrag ändern?',
             'Was ist der Unterschied zwischen befristeten und unbefristeten Verträgen?']
      },
      'rent' => {
        nl: ['Wat is de maximale huurwaarborg?', 'Wanneer mag de verhuurder de huur verhogen?', 'Wat zijn mijn rechten als huurder?'],
        fr: ['Quel est le montant maximum de la garantie locative?', 'Quand le propriétaire peut-il augmenter le loyer?',
             'Quels sont mes droits en tant que locataire?'],
        en: ['What is the maximum rental deposit?', 'When can the landlord increase the rent?', 'What are my rights as a tenant?'],
        de: ['Was ist die maximale Mietkaution?', 'Wann darf der Vermieter die Miete erhöhen?', 'Was sind meine Rechte als Mieter?']
      },
      'inheritance' => {
        nl: ['Hoeveel erfbelasting moet ik betalen?', 'Wat zijn de rechten van de langstlevende?', 'Kan ik een erfenis weigeren?'],
        fr: ['Combien de droits de succession dois-je payer?', 'Quels sont les droits du conjoint survivant?',
             'Puis-je refuser un héritage?'],
        en: ['How much inheritance tax do I pay?', 'What are the rights of the surviving spouse?', 'Can I refuse an inheritance?'],
        de: ['Wie viel Erbschaftssteuer muss ich zahlen?', 'Was sind die Rechte des überlebenden Ehegatten?', 'Kann ich ein Erbe ablehnen?']
      },
      'divorce' => {
        nl: ['Hoe wordt alimentatie berekend?', 'Wat is echtscheiding door onderlinge toestemming?', 'Hoe wordt het vermogen verdeeld?'],
        fr: ['Comment la pension alimentaire est-elle calculée?', 'Qu\'est-ce que le divorce par consentement mutuel?',
             'Comment le patrimoine est-il partagé?'],
        en: ['How is alimony calculated?', 'What is divorce by mutual consent?', 'How is property divided?'],
        de: ['Wie wird der Unterhalt berechnet?', 'Was ist eine einvernehmliche Scheidung?', 'Wie wird das Vermögen aufgeteilt?']
      },
      'criminal' => {
        nl: ['Wat is het verschil tussen een misdrijf en een overtreding?', 'Wanneer verjaart een misdrijf?',
             'Wat zijn mijn rechten bij een verhoor?'],
        fr: ['Quelle est la différence entre un délit et une contravention?', 'Quand un délit est-il prescrit?',
             'Quels sont mes droits lors d\'un interrogatoire?'],
        en: ['What is the difference between a crime and a misdemeanor?', 'When does a crime become time-barred?',
             'What are my rights during interrogation?'],
        de: ['Was ist der Unterschied zwischen einem Verbrechen und einer Ordnungswidrigkeit?', 'Wann verjährt eine Straftat?',
             'Was sind meine Rechte bei einer Vernehmung?']
      },
      'tax' => {
        nl: ['Hoe bereken ik mijn personenbelasting?', 'Wat zijn de belastingtarieven in België?', 'Welke kosten zijn fiscaal aftrekbaar?'],
        fr: ['Comment calculer mon impôt des personnes physiques?', 'Quels sont les taux d\'imposition en Belgique?',
             'Quels frais sont déductibles fiscalement?'],
        en: ['How do I calculate my personal income tax?', 'What are the tax rates in Belgium?', 'Which expenses are tax-deductible?'],
        de: ['Wie berechne ich meine Einkommensteuer?', 'Was sind die Steuersätze in Belgien?', 'Welche Kosten sind steuerlich absetzbar?']
      },
      'company' => {
        nl: ['Hoe richt ik een BV op?', 'Wat is de aansprakelijkheid van bestuurders?', 'Wanneer is een jaarrekening verplicht?'],
        fr: ['Comment créer une SRL?', 'Quelle est la responsabilité des administrateurs?',
             'Quand les comptes annuels sont-ils obligatoires?'],
        en: ['How do I set up a limited company?', 'What is the liability of directors?', 'When are annual accounts required?'],
        de: ['Wie gründe ich eine GmbH?', 'Was ist die Haftung von Geschäftsführern?', 'Wann ist ein Jahresabschluss erforderlich?']
      },
      'verjaring' => {
        nl: ['Wat is de verjaringstermijn voor schulden?', 'Wanneer verjaart een schadeclaim?', 'Hoe kan ik de verjaring stuiten?'],
        fr: ['Quel est le délai de prescription pour les dettes?', 'Quand une créance se prescrit-elle?',
             'Comment interrompre la prescription?'],
        en: ['What is the statute of limitations for debts?', 'When does a damage claim expire?', 'How can I interrupt the prescription?'],
        de: ['Was ist die Verjährungsfrist für Schulden?', 'Wann verjährt ein Schadensersatzanspruch?', 'Wie kann ich die Verjährung unterbrechen?']
      },
      'prescription' => {
        nl: ['Wat is de verjaringstermijn voor schulden?', 'Wanneer verjaart een schadeclaim?', 'Hoe kan ik de verjaring stuiten?'],
        fr: ['Quel est le délai de prescription pour les dettes?', 'Quand une créance se prescrit-elle?',
             'Comment interrompre la prescription?'],
        en: ['What is the statute of limitations for debts?', 'When does a damage claim expire?', 'How can I interrupt the prescription?'],
        de: ['Was ist die Verjährungsfrist für Schulden?', 'Wann verjährt ein Schadensersatzanspruch?', 'Wie kann ich die Verjährung unterbrechen?']
      },
      # Default suggestions for common topics
      '_default' => {
        nl: ['Waar kan ik juridisch advies krijgen?', 'Hoe start ik een gerechtelijke procedure?', 'Wat is pro deo rechtsbijstand?'],
        fr: ['Où puis-je obtenir des conseils juridiques?', 'Comment entamer une procédure judiciaire?',
             'Qu\'est-ce que l\'aide juridique pro deo?'],
        en: ['Where can I get legal advice?', 'How do I start legal proceedings?', 'What is pro deo legal aid?'],
        de: ['Wo kann ich Rechtsberatung bekommen?', 'Wie leite ich ein Gerichtsverfahren ein?', 'Was ist Prozesskostenhilfe?']
      }
    }.freeze
  end
end
