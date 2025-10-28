# frozen_string_literal: true

require 'openai'
require 'net/http'
require 'json'

# Service class for AI-powered legal Q&A using RAG (Retrieval Augmented Generation)
# Uses Azure OpenAI for GDPR compliance and EU data residency
class LegalChatbotService
  EMBEDDING_MODEL = 'text-embedding-3-large'
  EMBEDDING_DIMENSIONS = 3072 # Must match articles_large_pq.faiss
  CHAT_MODEL = 'gpt-4o-mini'
  MAX_CONTEXT_ARTICLES = 5
  
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
    # Nieuw Burgerlijk Wetboek (2019-2022)
    '2022A32057' => 'Nieuw BW Boek 1 - Algemene bepalingen',
    '2020A20347' => 'Nieuw BW Boek 3 - Goederen',
    '2022A32058' => 'Nieuw BW Boek 5 - Verbintenissen',
    '2019A12168' => 'Nieuw BW Boek 8 - Bewijs',
    '2022A30600' => 'Nieuw BW Boek 2 - Relatievermogensrecht',
    '2022B30600' => 'BW Boek 4 - Erfrecht',
    # Huwelijksvermogen
    '1976071406' => 'Wet huwelijksvermogen',
    # Gerechtelijk Wetboek
    '1967101052' => 'Gerechtelijk Wetboek',
    # Criminal Law
    '1867060850' => 'Strafwetboek',
    '1808111701' => 'Wetboek van Strafvordering',
    '2010A09589' => 'Sociaal Strafwetboek',
    # Constitutional
    '1994021048' => 'Grondwet',
    # Labor & Social
    '1971031602' => 'Arbeidswet',
    '1978070303' => 'Arbeidsovereenkomstenwet',
    '1971062850' => 'Jaarlijkse vakantiewet',
    '1996012650' => 'Welzijnswet',
    '1963082803' => 'KB Klein verlet',
    # Corporate & Economic
    '2019A40586' => 'Wetboek van vennootschappen en verenigingen',
    '2013A11134' => 'Wetboek economisch recht',
    # Tax - Federal
    '1993082751' => 'WIB92 (KB uitvoering)',
    '1969070305' => 'BTW-Wetboek',
    # Tax - Regional
    '2013036154' => 'Vlaamse Codex Fiscaliteit',
    # Housing
    '2018015087' => 'Vlaams Woninghuurdecreet',
    '2013A31614' => 'Brusselse Huisvestingscode',
    '1951043003' => 'Handelshuurwet',
    # Social Security
    '1991013192' => 'Werkloosheidsbesluit',
    '1994071450' => 'Wet ziekteverzekering (ZIV)',
    '2002022559' => 'Leefloonwet',
    '1967102704' => 'KB kinderbijslag werknemers',
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
    # Agricultural lease
    '1969110450' => 'Pachtwet',
    # Self-employed
    '1967072702' => 'KB nr 38 zelfstandigen',
  }.freeze
  
  # Keywords that trigger inclusion of specific core laws (NL + FR bilingual)
  # Maps question keywords to relevant foundational law NUMACs
  KEYWORD_TO_CORE_LAWS = {
    # Employment contracts (NL)
    'opzegtermijn' => ['1978070303'],
    'opzeg' => ['1978070303'],
    'ontslag' => ['1978070303', '2010A09589'],
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
    'ziekte' => ['1978070303', '1994071450'],
    'outplacement' => ['1978070303'],
    'scholingsbeding' => ['1978070303'],
    'schorsing' => ['1978070303'],
    'ontslagvergoeding' => ['1978070303'],
    'beschermde werknemer' => ['1978070303'],
    # Employment contracts (FR)
    'préavis' => ['1978070303'],
    'licenciement' => ['1978070303', '2010A09589'],
    'contrat de travail' => ['1978070303'],
    'non-concurrence' => ['1978070303'],
    'période d\'essai' => ['1978070303'],
    'ancienneté' => ['1978070303'],
    # Working time (NL)
    'werktijd' => ['1971031602'],
    'arbeidsduur' => ['1971031602'],
    'overuren' => ['1971031602'],
    'zondagsarbeid' => ['1971031602', '1964070605'],
    'zondagsrust' => ['1964070605', '1971031602'],
    'zondag' => ['1964070605', '1971031602'],
    'repos dominical' => ['1964070605'],
    'nachtarbeid' => ['1971031602'],
    'rusttijd' => ['1971031602', '1964070605'],
    # Working time (FR)
    'temps de travail' => ['1971031602'],
    'durée du travail' => ['1971031602'],
    'heures supplémentaires' => ['1971031602'],
    'travail de nuit' => ['1971031602'],
    'travail du dimanche' => ['1971031602'],
    # Vacation & Leave (NL)
    'vakantie' => ['1971062850'],
    'vakantiedagen' => ['1971062850'],
    'verlof' => ['1971062850', '1963082803'],
    'klein verlet' => ['1963082803'],
    'rouwverlof' => ['1963082803'],
    # Maternity/Paternity/Birth leave (NL) - Arbeidswet + AOW
    'zwangerschapsverlof' => ['1971031602', '1978070303'],
    'zwangerschap' => ['1971031602'],
    'moederschapsverlof' => ['1971031602', '1978070303'],
    'moederschap' => ['1971031602'],
    'vaderschapsverlof' => ['1971031602', '1978070303'],
    'geboorteverlof' => ['1971031602', '1978070303'],
    'geboorte' => ['1978070303', '1963082803'],
    'verlof geboorte' => ['1978070303', '1963082803'],
    'werkweek' => ['1971031602'],
    # Vacation & Leave (FR)
    'congé' => ['1971062850', '1963082803'],
    'vacances' => ['1971062850'],
    'jours de congé' => ['1971062850'],
    'petit chômage' => ['1963082803'],
    'congé de deuil' => ['1963082803'],
    'décès' => ['1963082803'],
    # Maternity/Paternity (FR)
    'congé de maternité' => ['1971031602'],
    'maternité' => ['1971031602'],
    'congé de paternité' => ['1971031602'],
    'paternité' => ['1971031602'],
    # Workplace safety (NL + FR)
    'welzijn' => ['1996012650'],
    'veiligheid' => ['1996012650'],
    'veiligheidsmaatregelen' => ['1996012650'],
    'arbeidsongevallen' => ['1996012650'],
    'arbeidsongeval' => ['1996012650'],
    'preventie' => ['1996012650'],
    'risicoanalyse' => ['1996012650'],
    'bien-être' => ['1996012650'],
    'sécurité' => ['1996012650'],
    'accident du travail' => ['1996012650'],
    'prévention' => ['1996012650'],
    # Criminal law (NL)
    'straf' => ['1867060850'],
    'misdrijf' => ['1867060850'],
    'diefstal' => ['1867060850'],
    'huiszoeking' => ['1808111701'],
    'strafprocedure' => ['1808111701'],
    'aanhouding' => ['1808111701'],
    'voorhechtenis' => ['1808111701'],
    'vov' => ['1867060850'],
    'voorwaardelijk' => ['1867060850'],
    'probatie' => ['1867060850'],
    'werkstraf' => ['1867060850'],
    'salduz' => ['1808111701'],
    'advocaat verhoor' => ['1808111701'],
    'minnelijke schikking' => ['1808111701'],
    'transactie' => ['1808111701'],
    'verjaring' => ['1867060850', '1808111701'],
    # Criminal law (FR)
    'peine' => ['1867060850'],
    'délit' => ['1867060850'],
    'vol' => ['1867060850'],
    'perquisition' => ['1808111701'],
    'procédure pénale' => ['1808111701'],
    'arrestation' => ['1808111701'],
    'détention' => ['1808111701'],
    'sursis' => ['1867060850'],
    'probation' => ['1867060850'],
    'transaction pénale' => ['1808111701'],
    # Civil law - Oud BW + Nieuw BW (NL)
    'contract' => ['1804032154', '2022A32058'],      # Verbintenissen
    'overeenkomst' => ['1804032154', '2022A32058'],  # Verbintenissen
    'verbintenis' => ['1804032154', '2022A32058'],   # Verbintenissen
    'eigendom' => ['1804032151', '2020A20347'],      # Goederen
    # Note: 'bezit' removed - too generic, conflicts with "bezit van drugs"
    'erfenis' => ['1804032152', '1804032153', '2022B30600'],       # Erfopvolging
    'erfrecht' => ['1804032152', '1804032153', '2022B30600'],      # Erfopvolging
    'erfopvolging' => ['1804032152', '1804032153', '2022B30600'],  # Erfopvolging
    'testament' => ['1804032153', '2022B30600'],                   # Schenkingen/Testamenten
    'schenking' => ['1804032153', '2022B30600'],                   # Schenkingen/Testamenten
    'erfgenaam' => ['1804032152', '2022B30600'],                   # Erfgenamen
    'nalatenschap' => ['1804032152', '2022B30600'],                # Nalatenschappen
    'onterven' => ['1804032153', '2022B30600'],                    # Reserve
    'reserve' => ['1804032153', '2022B30600'],                     # Wettelijke reserve
    'huwelijksvermogen' => ['1804032156', '1976071406', '2022A30600'],
    'echtscheiding' => ['1804032150', '2022A30600'],
    'samenwoning' => ['2022A30600'],                 # Relatievermogensrecht
    'bewijs' => ['2019A12168'],                      # Nieuw BW Boek 8
    # Civil law (FR)
    'contrat' => ['1804032154', '2022A32058'],
    'obligation' => ['1804032154', '2022A32058'],
    'propriété' => ['1804032151', '2020A20347'],
    'succession' => ['1804032152', '1804032153', '2022B30600'],
    'héritage' => ['1804032152', '1804032153', '2022B30600'],
    'donation' => ['1804032153', '2022B30600'],
    'testament' => ['1804032153'],
    'régime matrimonial' => ['1804032156', '1976071406'],
    'divorce' => ['1804032150', '2022A30600'],
    'preuve' => ['2019A12168'],
    # Rental (NL)
    'huur' => ['2018015087', '2013A31614'],
    'verhuurder' => ['2018015087', '2013A31614'],
    'huurder' => ['2018015087', '2013A31614'],
    'huurwaarborg' => ['2018015087'],
    'handelshuur' => ['1951043003'],
    # Rental (FR)
    'locataire' => ['2018015087', '2013A31614'],
    'bailleur' => ['2018015087', '2013A31614'],
    'loyer' => ['2018015087', '2013A31614'],
    'garantie locative' => ['2018015087'],
    'bail' => ['2018015087', '2013A31614'],
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
    'faillissement' => ['2019A40586', '2013A11134'],
    'insolventie' => ['2019A40586', '2013A11134'],
    'gerechtelijke reorganisatie' => ['2013A11134'],
    # Consumer / Economic Law (NL)
    'garantie' => ['2013A11134'],
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
    # Consumer / Economic Law (FR)
    'garantie' => ['2013A11134'],
    'consommateur' => ['2013A11134'],
    'droit de rétractation' => ['2013A11134'],
    'livraison' => ['2013A11134'],
    'soldes' => ['2013A11134'],
    'publicité' => ['2013A11134'],
    # Drugs (NL + FR)
    'drugs' => ['1921022450'],
    'verdovende middelen' => ['1921022450'],
    'cannabis' => ['1921022450'],
    'cocaïne' => ['1921022450'],
    'heroïne' => ['1921022450'],
    'drugsbezit' => ['1921022450'],
    'stupéfiants' => ['1921022450'],
    'drogue' => ['1921022450'],
    'possession' => ['1921022450'],
    # Tax (NL + FR)
    'belasting' => ['1993082751', '2013036154'],
    'erfbelasting' => ['2013036154'],
    'schenkbelasting' => ['2013036154'],
    'onroerende voorheffing' => ['2013036154'],
    'btw' => ['2024009391', '2024009395', '2023048636'],
    'btw-tarief' => ['2024009391', '2024009395', '2023048636'],
    'btw-tarieven' => ['2024009391', '2024009395', '2023048636'],
    'omzetbelasting' => ['2024009391', '2024009395'],
    'toegevoegde waarde' => ['2024009391', '2024009395'],
    'inkomstenbelasting' => ['1993082751'],
    'personenbelasting' => ['1993082751'],
    'belastingaangifte' => ['1993082751'],
    'impôt' => ['1993082751', '2013036154'],
    'droits de succession' => ['2013036154'],
    'droits de donation' => ['2013036154'],
    'précompte immobilier' => ['2013036154'],
    'tva' => ['2024009391', '2024009395', '2023048636'],
    # Immigration (NL + FR)
    'verblijf' => ['1980121550'],
    'vreemdeling' => ['1980121550'],
    'nationaliteit' => ['1980121550'],
    'séjour' => ['1980121550'],
    'étranger' => ['1980121550'],
    'nationalité' => ['1980121550'],
    # Camera surveillance (NL + FR)
    'camera' => ['2007000528'],
    'bewakingscamera' => ['2007000528'],
    'camerabewaking' => ['2007000528'],
    'videobewaking' => ['2007000528'],
    'caméra' => ['2007000528'],
    'vidéosurveillance' => ['2007000528'],
    # Judicial / Procedural (NL + FR)
    'rechtszaak' => ['1967101052'],
    'procedure' => ['1967101052'],
    'dagvaarding' => ['1967101052'],
    'beroep' => ['1967101052'],
    'rechtbank' => ['1967101052'],
    'procès' => ['1967101052'],
    'tribunal' => ['1967101052'],
    'assignation' => ['1967101052'],
    'appel' => ['1967101052'],
    # Administrative law / Raad van State (NL + FR)
    'raad van state' => ['1973011250', '2006A21306'],
    'conseil d\'état' => ['1973011250', '2006A21306'],
    'rolrecht' => ['1973011250'],
    'rolrechten' => ['1973011250'],
    'administratief recht' => ['1973011250', '2006A21306'],
    'droit administratif' => ['1973011250', '2006A21306'],
    'bestuursrecht' => ['1973011250', '2006A21306'],
    # Economic / Consumer (NL + FR)
    'consument' => ['2013A11134'],
    'garantie' => ['2013A11134'],
    'faillissement' => ['2013A11134'],
    'insolvabiliteit' => ['2013A11134'],
    'consommateur' => ['2013A11134'],
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
    'bedrijfswagen' => ['1993082751'],
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
    # Social Security - Health Insurance (NL)
    'ziekteverzekering' => ['1994071450'],
    'ziekenfonds' => ['1994071450'],
    'mutualiteit' => ['1994071450'],
    'riziv' => ['1994071450'],
    'arbeidsongeschiktheid' => ['1994071450'],
    'invaliditeit' => ['1994071450'],
    'terugbetaling' => ['1994071450'],
    # Social Security - Health Insurance (FR)
    'assurance maladie' => ['1994071450'],
    'mutuelle' => ['1994071450'],
    'inami' => ['1994071450'],
    'incapacité de travail' => ['1994071450'],
    'invalidité' => ['1994071450'],
    # Social Security - OCMW/Leefloon (NL)
    'leefloon' => ['2002022559'],
    'ocmw' => ['2002022559'],
    'maatschappelijke integratie' => ['2002022559'],
    'bijstand' => ['2002022559'],
    # Social Security - CPAS/RIS (FR)
    'revenu d\'intégration' => ['2002022559'],
    'cpas' => ['2002022559'],
    'aide sociale' => ['2002022559'],
    # Social Security - Child Benefits (NL)
    'kinderbijslag' => ['1967102704'],
    'groeipakket' => ['1967102704'],
    'gezinsbijslag' => ['1967102704'],
    # Social Security - Child Benefits (FR)
    'allocations familiales' => ['1967102704'],
    # Wage Protection (NL)
    'loonbescherming' => ['1965041207'],
    'loonbeslag' => ['1965041207'],
    'loonoverdracht' => ['1965041207'],
    # Wage Protection (FR)
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
    'discriminatie' => ['2007002098', '2007002099'],
    'gelijke behandeling' => ['2007002098', '2007002099'],
    'gelijkheid' => ['2007002098', '2007002099'],
    'racisme' => ['2007002099'],
    'weigeren' => ['2007002098', '2007002099'],
    'klant weigeren' => ['2007002098', '2007002099'],
    # Anti-discrimination (FR)
    'discrimination' => ['2007002098', '2007002099'],
    'égalité' => ['2007002098', '2007002099'],
    'racisme' => ['2007002099'],
    # Psychosocial Risks / Harassment (NL)
    'pesten' => ['1996012650'],
    'pestgedrag' => ['1996012650'],
    'ongewenst gedrag' => ['1996012650'],
    'psychosociaal' => ['1996012650'],
    'burnout' => ['1996012650'],
    'stress' => ['1996012650'],
    # Psychosocial Risks / Harassment (FR)
    'harcèlement' => ['1996012650'],
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
    'conseil d\'entreprise' => ['1948092002'],
    # Early retirement / SWT (NL)
    'brugpensioen' => ['2010201753'],
    'swt' => ['2010201753'],
    'werkloosheid met bedrijfstoeslag' => ['2010201753'],
    'canada dry' => ['2010201753'],  # Colloquial for pseudo-brugpensioen
    'pseudo-brugpensioen' => ['2010201753'],
    # IGO - Income guarantee elderly (NL)
    'inkomensgarantie' => ['2001022201'],
    'igo' => ['2001022201'],
    # Adoption leave
    'adoptieverlof' => ['1978070303', '1971031602'],
    # Occupational diseases (NL)
    'beroepsziekte' => ['1971041001'],
    'fedris' => ['1971041001'],
    'arbeidsongeval' => ['1971041001'],
    # Occupational diseases (FR)
    'maladie professionnelle' => ['1971041001'],
    'accident du travail' => ['1971041001'],
    # Agricultural lease (NL)
    'pacht' => ['1969110450'],
    'pachtovereenkomst' => ['1969110450'],
    'landbouwpacht' => ['1969110450'],
    # Agricultural lease (FR)
    'bail à ferme' => ['1969110450'],
    # Marriage contract (NL)
    'huwelijkscontract' => ['1976071406', '1804032156'],
    'huwelijksvermogensstelsel' => ['1976071406', '1804032156'],
    # Self-employed (NL)
    'zelfstandige' => ['1967072702'],
    'sociaal statuut zelfstandigen' => ['1967072702'],
    'bijberoep' => ['1967072702'],
    'rsvz' => ['1967072702'],
    # TRAFFIC / WEGCODE (NL) - Weak category: 53%
    'verkeer' => ['1968031601', '1975032710'],
    'wegverkeer' => ['1968031601'],
    'wegcode' => ['1968031601', '1975032710'],
    'snelheid' => ['1968031601', '1975032710'],
    'snelheidsovertreding' => ['1968031601'],
    'maximumsnelheid' => ['1968031601', '1975032710'],
    'rood licht' => ['1968031601'],
    'rijbewijs' => ['1968031601', '1998012250'],
    'rijverbod' => ['1968031601'],
    'alcoholcontrole' => ['1968031601'],
    'alcohol verkeer' => ['1968031601'],
    'promille' => ['1968031601'],
    'verkeersongeval' => ['1968031601'],
    'aanrijding' => ['1968031601'],
    'vluchtmisdrijf' => ['1968031601'],
    'parkeren' => ['1975032710'],
    'boete verkeer' => ['1968031601'],
    'verkeersboete' => ['1968031601'],
    'pv verkeer' => ['1968031601'],
    # TRAFFIC / CODE DE LA ROUTE (FR)
    'circulation' => ['1968031601', '1975032710'],
    'code de la route' => ['1968031601', '1975032710'],
    'vitesse' => ['1968031601', '1975032710'],
    'excès de vitesse' => ['1968031601'],
    'permis de conduire' => ['1968031601', '1998012250'],
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
    'btw renovatie' => ['1969070305', '2000003841'],
    'btw verbouwing' => ['1969070305', '2000003841'],
    'btw nieuwbouw' => ['1969070305'],
    'btw afbraak heropbouw' => ['1969070305', '2000003841'],
    '6% btw' => ['1969070305', '2000003841'],
    '21% btw' => ['1969070305'],
    'verlaagd btw-tarief' => ['1969070305', '2000003841'],
    'btw bouw' => ['1969070305'],
    'btw aannemer' => ['1969070305'],
    'tva rénovation' => ['1969070305', '2000003841'],
    'taux réduit tva' => ['1969070305', '2000003841'],
    # WIB / PERSONENBELASTING - Weak category: 41%
    'wib' => ['1992003455'],
    'wib92' => ['1992003455'],
    'beroepskosten' => ['1992003455'],
    'forfaitaire kosten' => ['1992003455'],
    'belastingvrije som' => ['1992003455'],
    'kinderen ten laste' => ['1992003455'],
    'huwelijksquotiënt' => ['1992003455'],
    'kadastraal inkomen' => ['1992003455', '2013036154'],
    'onroerend inkomen' => ['1992003455'],
    'roerend inkomen' => ['1992003455'],
    'buitenlands inkomen' => ['1992003455'],
    'dubbelbelasting' => ['1992003455'],
    'tax shelter' => ['1992003455'],
    'revenu professionnel' => ['1992003455'],
    'frais professionnels' => ['1992003455'],
    'quotité exemptée' => ['1992003455'],
    # REGISTRATIERECHTEN - Weak category: 43%
    'registratierecht' => ['2013036154'],
    'registratierechten' => ['2013036154'],
    'verkooprecht' => ['2013036154'],
    'verdeelrecht' => ['2013036154'],
    'schenkingsrecht' => ['2013036154'],
    'successierecht' => ['2013036154'],
    'erfenisbelasting' => ['2013036154'],
    'droits d\'enregistrement' => ['2013036154'],
    'droits de vente' => ['2013036154'],
    # CONSUMER / WER - Weak category: 45-50%
    'wer' => ['2013A11134'],
    'wetboek economisch recht' => ['2013A11134'],
    'code économique' => ['2013A11134'],
    'bedenktijd' => ['2013A11134'],
    'afkoelingsperiode' => ['2013A11134'],
    'wettelijke garantie' => ['2013A11134'],
    '2 jaar garantie' => ['2013A11134'],
    'verborgen gebrek' => ['2013A11134'],
    'conformiteit' => ['2013A11134'],
    'non-conformiteit' => ['2013A11134'],
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
  }.freeze
  
  # Boost factor for core laws (multiplied with similarity score)
  # Increased from 1.5 to 2.0 for stronger prioritization of foundational laws over CAOs
  CORE_LAW_BOOST = 2.0
  
  # Penalty factor for sector-specific CAOs (less relevant for general questions)
  CAO_PENALTY = 0.6
  
  # Follow-up suggestions based on detected topics (NL + FR bilingual)
  FOLLOW_UP_SUGGESTIONS = {
    # Employment - NL
    'opzeg' => {
      nl: ['Wat is de opzegvergoeding bij ontslag?', 'Kan ik ontslagen worden tijdens ziekte?', 'Wat zijn mijn rechten bij collectief ontslag?'],
      fr: ['Quelle est l\'indemnité de préavis?', 'Puis-je être licencié pendant une maladie?', 'Quels sont mes droits en cas de licenciement collectif?']
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
      fr: ['Combien de pécule de vacances vais-je recevoir?', 'Que se passe-t-il si je tombe malade pendant mes vacances?', 'Mon employeur peut-il refuser mes vacances?']
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
      fr: ['Combien d\'heures supplémentaires puis-je faire?', 'Quelles sont les règles du travail de nuit?', 'Ai-je droit à des temps de repos?']
    },
    # Employment - FR triggers
    'préavis' => {
      nl: ['Hoe bereken ik mijn opzegtermijn?', 'Wat is de opzegvergoeding?', 'Kan ik ontslagen worden tijdens ziekte?'],
      fr: ['Comment calculer mon préavis?', 'Quelle est l\'indemnité de préavis?', 'Puis-je être licencié pendant une maladie?']
    },
    'licenciement' => {
      nl: ['Wat is ontslag om dringende reden?', 'Heb ik recht op werkloosheidsuitkering?', 'Wat zijn mijn rechten bij collectief ontslag?'],
      fr: ['Qu\'est-ce qu\'un licenciement pour motif grave?', 'Ai-je droit aux allocations de chômage?', 'Quels sont mes droits en cas de licenciement collectif?']
    },
    'congé' => {
      nl: ['Hoeveel vakantiedagen heb ik?', 'Wat is ouderschapsverlof?', 'Hoeveel dagen klein verlet?'],
      fr: ['Combien de jours de congé ai-je?', 'Qu\'est-ce que le congé parental?', 'Combien de jours de petit chômage?']
    },
    # Rental
    'huur' => {
      nl: ['Wat is de maximale huurwaarborg?', 'Wanneer mag de verhuurder de huur verhogen?', 'Wat zijn mijn rechten bij verkoop van de woning?'],
      fr: ['Quel est le montant maximum de la garantie locative?', 'Quand le propriétaire peut-il augmenter le loyer?', 'Quels sont mes droits en cas de vente du bien?']
    },
    'locataire' => {
      nl: ['Wat is de maximale huurwaarborg?', 'Wanneer mag de verhuurder de huur verhogen?', 'Hoe kan ik mijn huurcontract opzeggen?'],
      fr: ['Quel est le montant maximum de la garantie locative?', 'Quand le propriétaire peut-il augmenter le loyer?', 'Comment résilier mon bail?']
    },
    'bail' => {
      nl: ['Wat is de opzegtermijn voor een huurcontract?', 'Wat zijn mijn rechten als huurder?', 'Wat is de maximale huurwaarborg?'],
      fr: ['Quel est le délai de préavis pour un bail?', 'Quels sont mes droits en tant que locataire?', 'Quel est le montant maximum de la garantie locative?']
    },
    # Criminal
    'straf' => {
      nl: ['Wat is het verschil tussen een misdrijf en een overtreding?', 'Wanneer verjaart een misdrijf?', 'Wat zijn mijn rechten bij een verhoor?'],
      fr: ['Quelle est la différence entre un délit et une contravention?', 'Quand un délit est-il prescrit?', 'Quels sont mes droits lors d\'un interrogatoire?']
    },
    'peine' => {
      nl: ['Wat is het verschil tussen een misdrijf en een overtreding?', 'Wanneer verjaart een misdrijf?', 'Wat zijn verzachtende omstandigheden?'],
      fr: ['Quelle est la différence entre un délit et une contravention?', 'Quand un délit est-il prescrit?', 'Que sont les circonstances atténuantes?']
    },
    'vol' => {
      nl: ['Wat is diefstal met verzwarende omstandigheden?', 'Wat is de straf voor heling?', 'Wanneer is er sprake van afpersing?'],
      fr: ['Qu\'est-ce que le vol avec circonstances aggravantes?', 'Quelle est la peine pour recel?', 'Quand parle-t-on d\'extorsion?']
    },
    # Family
    'echtscheiding' => {
      nl: ['Hoe wordt alimentatie berekend?', 'Wat gebeurt er met de kinderen bij echtscheiding?', 'Hoe wordt het vermogen verdeeld?'],
      fr: ['Comment la pension alimentaire est-elle calculée?', 'Que se passe-t-il avec les enfants lors d\'un divorce?', 'Comment le patrimoine est-il partagé?']
    },
    'divorce' => {
      nl: ['Hoe wordt alimentatie berekend?', 'Wat is echtscheiding door onderlinge toestemming?', 'Hoe wordt het vermogen verdeeld?'],
      fr: ['Comment la pension alimentaire est-elle calculée?', 'Qu\'est-ce que le divorce par consentement mutuel?', 'Comment le patrimoine est-il partagé?']
    },
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
      nl: ['Wat zijn de verplichte vermeldingen in een arbeidsovereenkomst?', 'Kan mijn werkgever mijn contract wijzigen?', 'Wat is het verschil tussen bepaalde en onbepaalde duur?'],
      fr: ['Quelles sont les mentions obligatoires dans un contrat de travail?', 'Mon employeur peut-il modifier mon contrat?', 'Quelle est la différence entre CDD et CDI?'],
      en: ['What must be included in an employment contract?', 'Can my employer change my contract?', 'What is the difference between fixed-term and permanent contracts?']
    },
    'rent' => {
      nl: ['Wat is de maximale huurwaarborg?', 'Wanneer mag de verhuurder de huur verhogen?', 'Wat zijn mijn rechten als huurder?'],
      fr: ['Quel est le montant maximum de la garantie locative?', 'Quand le propriétaire peut-il augmenter le loyer?', 'Quels sont mes droits en tant que locataire?'],
      en: ['What is the maximum rental deposit?', 'When can the landlord increase the rent?', 'What are my rights as a tenant?']
    },
    'inheritance' => {
      nl: ['Hoeveel erfbelasting moet ik betalen?', 'Wat zijn de rechten van de langstlevende?', 'Kan ik een erfenis weigeren?'],
      fr: ['Combien de droits de succession dois-je payer?', 'Quels sont les droits du conjoint survivant?', 'Puis-je refuser un héritage?'],
      en: ['How much inheritance tax do I pay?', 'What are the rights of the surviving spouse?', 'Can I refuse an inheritance?']
    },
    'divorce' => {
      nl: ['Hoe wordt alimentatie berekend?', 'Wat is echtscheiding door onderlinge toestemming?', 'Hoe wordt het vermogen verdeeld?'],
      fr: ['Comment la pension alimentaire est-elle calculée?', 'Qu\'est-ce que le divorce par consentement mutuel?', 'Comment le patrimoine est-il partagé?'],
      en: ['How is alimony calculated?', 'What is divorce by mutual consent?', 'How is property divided?']
    },
    'criminal' => {
      nl: ['Wat is het verschil tussen een misdrijf en een overtreding?', 'Wanneer verjaart een misdrijf?', 'Wat zijn mijn rechten bij een verhoor?'],
      fr: ['Quelle est la différence entre un délit et une contravention?', 'Quand un délit est-il prescrit?', 'Quels sont mes droits lors d\'un interrogatoire?'],
      en: ['What is the difference between a crime and a misdemeanor?', 'When does a crime become time-barred?', 'What are my rights during interrogation?']
    },
    'tax' => {
      nl: ['Hoe bereken ik mijn personenbelasting?', 'Wat zijn de belastingtarieven in België?', 'Welke kosten zijn fiscaal aftrekbaar?'],
      fr: ['Comment calculer mon impôt des personnes physiques?', 'Quels sont les taux d\'imposition en Belgique?', 'Quels frais sont déductibles fiscalement?'],
      en: ['How do I calculate my personal income tax?', 'What are the tax rates in Belgium?', 'Which expenses are tax-deductible?']
    },
    'company' => {
      nl: ['Hoe richt ik een BV op?', 'Wat is de aansprakelijkheid van bestuurders?', 'Wanneer is een jaarrekening verplicht?'],
      fr: ['Comment créer une SRL?', 'Quelle est la responsabilité des administrateurs?', 'Quand les comptes annuels sont-ils obligatoires?'],
      en: ['How do I set up a limited company?', 'What is the liability of directors?', 'When are annual accounts required?']
    },
    # Default suggestions for common topics
    '_default' => {
      nl: ['Waar kan ik juridisch advies krijgen?', 'Hoe start ik een gerechtelijke procedure?', 'Wat is pro deo rechtsbijstand?'],
      fr: ['Où puis-je obtenir des conseils juridiques?', 'Comment entamer une procédure judiciaire?', 'Qu\'est-ce que l\'aide juridique pro deo?'],
      en: ['Where can I get legal advice?', 'How do I start legal proceedings?', 'What is pro deo legal aid?']
    }
  }.freeze
  
  # Sample size for embedding similarity search (performance optimization)
  # Scanning all 276K embeddings takes ~10s, sampling 25K takes 1-2s
  # Trade-off: 10x faster, minimal quality loss (semantic clustering)
  EMBEDDING_SAMPLE_SIZE = 25_000
  MAX_QUESTION_LENGTH = 500
  
  # External embeddings database paths
  JURISPRUDENCE_EMBEDDINGS_DB = ENV.fetch('JURISPRUDENCE_EMBEDDINGS_DB', '/mnt/HC_Volume_103359050/embeddings/jurisprudence_embeddings.db')
  JURISPRUDENCE_SOURCE_DB = ENV.fetch('JURISPRUDENCE_SOURCE_DB', '/mnt/HC_Volume_103359050/embeddings/jurisprudence.db')
  LEGISLATION_EMBEDDINGS_DB = ENV.fetch('LEGISLATION_EMBEDDINGS_DB', '/mnt/HC_Volume_103359050/embeddings/legislation_embeddings.db')
  ARTICLE_EMBEDDINGS_DB = ENV.fetch('ARTICLE_EMBEDDINGS_DB', '/mnt/HC_Volume_104299669/embeddings/text_embedding_3_large.db')
  FAISS_LARGE_URL = ENV.fetch('FAISS_LARGE_URL', 'http://localhost:8767')
  FAISS_FISCONET_URL = ENV.fetch('FAISS_FISCONET_URL', 'http://localhost:8768')
  FAISS_PARLIAMENTARY_URL = ENV.fetch('FAISS_PARLIAMENTARY_URL', 'http://localhost:8769')
  FAISS_REGIONAL_URL = ENV.fetch('FAISS_REGIONAL_URL', 'http://localhost:8770')
  # Use __dir__ to get actual deploy path (Rails.root returns production path even on staging)
  PARLIAMENTARY_DB = ENV.fetch('PARLIAMENTARY_DB', File.expand_path('../../storage/parliamentary.sqlite3', __dir__))
  FISCONET_DB = ENV.fetch('FISCONET_DB', '/mnt/HC_Volume_104299669/embeddings/fisconet.sqlite3')
  
  def initialize(language: 'nl', conversation: nil, model: nil)
    @language = language
    @language_id = language == 'fr' ? 2 : 1
    @conversation = conversation
    @context_numacs = conversation&.context_numacs_array || []
    @model_override = model  # Allow testing different models
    @client = azure_client
    @juris_emb_db = nil
    @juris_source_db = nil
    @leg_emb_db = nil
    @article_emb_db = nil
    @parliamentary_db = nil
    @fisconet_db = nil
  end
  
  private
  
  # Configure Azure OpenAI client for EU data residency (GDPR compliant)
  def azure_client
    endpoint = ENV['AZURE_OPENAI_ENDPOINT']
    return nil unless endpoint
    # Ensure endpoint ends with /openai for Azure API
    endpoint = endpoint.chomp('/') + '/openai' unless endpoint.include?('/openai')
    
    OpenAI::Client.new(
      access_token: ENV['AZURE_OPENAI_KEY'],
      uri_base: endpoint,
      api_type: :azure,
      api_version: ENV.fetch('AZURE_OPENAI_API_VERSION', '2024-02-15-preview')
    )
  end
  
  public
  
  # Main method to answer a question
  def ask(question, source: :all)
    start_time = Time.current
    
    # Timeout wrapper to prevent hanging requests
    Timeout.timeout(45) do
      ask_internal(question, source: source)
    end
  rescue Timeout::Error
    {
      answer: @language == 'fr' ? 
        "Désolé, la requête a pris trop de temps. Essayez une question plus simple." :
        "Sorry, de vraag duurde te lang. Probeer een eenvoudigere vraag.",
      sources: [],
      response_time: (Time.current - start_time).round(2),
      error: 'timeout'
    }
  end
  
  # Ask with multiple sources (checkbox UI)
  # sources: array of symbols like [:legislation, :jurisprudence, :parliamentary]
  def ask_with_sources(question, sources: [:legislation])
    start_time = Time.current
    
    Timeout.timeout(60) do
      ask_internal_multi(question, sources: sources)
    end
  rescue Timeout::Error
    {
      answer: @language == 'fr' ? 
        "Désolé, la requête a pris trop de temps. Essayez une question plus simple." :
        "Sorry, de vraag duurde te lang. Probeer een eenvoudigere vraag.",
      sources: [],
      response_time: (Time.current - start_time).round(2),
      error: 'timeout'
    }
  end
  
  # Internal method for multi-source search
  def ask_internal_multi(question, sources: [:legislation])
    raise ArgumentError, "Question too long" if question.length > MAX_QUESTION_LENGTH
    
    start_time = Time.current
    question_embedding = generate_embedding(question)
    
    # Search each selected source in parallel
    # Note: fisconet (WIB 92) and regional legislation are automatically included with legislation
    all_results = { legislation: [], jurisprudence: [], parliamentary: [], fisconet: [], regional: [] }
    threads = []
    
    if sources.include?(:legislation)
      # Search main legislation
      threads << Thread.new do
        begin
          all_results[:legislation] = find_similar_legislation(question_embedding, limit: 5, question: question)
        rescue => e
          Rails.logger.error("[Multi-search] Legislation failed: #{e.message}")
          all_results[:legislation] = []
        end
      end
      
      # Also search fisconet (WIB 92) - it's legislation, just from a different source
      threads << Thread.new do
        begin
          all_results[:fisconet] = search_fisconet(question_embedding, limit: 2)
        rescue => e
          Rails.logger.error("[Multi-search] Fisconet failed: #{e.message}")
          all_results[:fisconet] = []
        end
      end
      
      # Also search regional legislation (Vlaamse Codex, Wallex, Brussels)
      threads << Thread.new do
        begin
          all_results[:regional] = search_regional_legislation(question_embedding, limit: 3)
        rescue => e
          Rails.logger.error("[Multi-search] Regional failed: #{e.message}")
          all_results[:regional] = []
        end
      end
    end
    
    if sources.include?(:jurisprudence)
      threads << Thread.new do
        begin
          all_results[:jurisprudence] = find_similar_jurisprudence(question_embedding, limit: 3)
        rescue => e
          Rails.logger.error("[Multi-search] Jurisprudence failed: #{e.message}")
          all_results[:jurisprudence] = []
        end
      end
    end
    
    if sources.include?(:parliamentary)
      threads << Thread.new do
        begin
          all_results[:parliamentary] = find_similar_parliamentary(question_embedding, limit: 3)
        rescue => e
          Rails.logger.error("[Multi-search] Parliamentary failed: #{e.message}")
          all_results[:parliamentary] = []
        end
      end
    end
    
    threads.each { |t| t.join(30) }
    
    leg_articles = all_results[:legislation] || []
    jur_cases = all_results[:jurisprudence] || []
    parl_docs = all_results[:parliamentary] || []
    tax_articles = all_results[:fisconet] || []
    regional_docs = all_results[:regional] || []
    
    return no_answer_response if leg_articles.empty? && jur_cases.empty? && parl_docs.empty? && tax_articles.empty? && regional_docs.empty?
    
    # Build combined context (includes regional legislation)
    context = build_combined_context_from_db(leg_articles, jur_cases, parl_docs, tax_articles, regional_docs)
    answer = query_llm(question, context, source_type: :all)
    suggestions = generate_follow_up_suggestions(question)
    
    result = {
      answer: answer,
      sources: format_legislation_sources(leg_articles) + format_jurisprudence_sources_from_db(jur_cases) + format_parliamentary_sources(parl_docs) + format_fisconet_sources(tax_articles) + format_regional_sources(regional_docs),
      suggestions: suggestions,
      language: @language
    }
    
    result[:response_time] = (Time.current - start_time).round(2)
    result
  rescue OpenAI::Error => e
    Rails.logger.error("Azure OpenAI API error: #{e.message}")
    { error: "Service temporarily unavailable", details: e.message }
  rescue StandardError => e
    Rails.logger.error("Chatbot error: #{e.message}\n#{e.backtrace.join("\n")}")
    { error: "An error occurred", details: e.message }
  end
  
  def ask_internal(question, source: :legislation)
    raise ArgumentError, "Question too long" if question.length > MAX_QUESTION_LENGTH
    
    start_time = Time.current
    
    # Route based on source selection:
    # - legislation: Fast (~20s), searches written law only
    # - jurisprudence: Fast (~20s), searches case law only
    # - parliamentary: Fast (~20s), searches preparatory works only
    # - all: Slow (~40s), searches both for comprehensive results
    result = case source
    when :jurisprudence
      search_jurisprudence(question)
    when :parliamentary
      search_parliamentary(question)
    when :all
      search_both(question)
    else  # :legislation (default)
      search_legislation(question)
    end
    
    result[:response_time] = (Time.current - start_time).round(2)
    result
  rescue OpenAI::Error => e
    Rails.logger.error("Azure OpenAI API error: #{e.message}")
    { error: "Service temporarily unavailable", details: e.message }
  rescue StandardError => e
    Rails.logger.error("Chatbot error: #{e.message}\n#{e.backtrace.join("\n")}")
    { error: "An error occurred", details: e.message }
  end
  
  # Search legislation using hybrid approach: embeddings + keyword fallback
  # Proven to handle both semantic matches (vakantiedagen, zelfstandigen) 
  # and cases where embeddings fail (deeltijds, proeftijd)
  # 
  # For follow-up questions (when @context_numacs present), prioritizes
  # searching within previously mentioned laws for better context continuity
  def search_legislation(question, progress_callback: nil)
    Rails.logger.info("[Search] Searching LEGISLATION ONLY for: #{question}")
    
    # For follow-ups: expand vague questions with conversation context
    effective_question = expand_followup_question(question)
    if effective_question != question
      Rails.logger.info("[Search] Expanded follow-up: #{effective_question}")
    end
    
    # Step 1: Try embeddings first (15 sources for better coverage)
    question_embedding = generate_embedding(effective_question)
    similar_articles = find_similar_legislation(question_embedding, limit: 15, question: effective_question)
    
    # Step 1b: Also search FisconetPlus (WIB 92 tax code) - it's legislation from a different source
    fisconet_articles = search_fisconet(question_embedding, limit: 3)
    Rails.logger.info("[Search] Fisconet found #{fisconet_articles.length} tax articles")
    
    # Step 2: For follow-ups with context, inject articles from previous NUMACs
    if @context_numacs.present? && is_followup_question?(question)
      Rails.logger.info("[Search] Follow-up detected, injecting context from: #{@context_numacs.join(', ')}")
      context_articles = inject_context_articles(@context_numacs, question.downcase)
      similar_articles = merge_search_results(context_articles, similar_articles)
    end
    
    # Step 3: ALWAYS add keyword search for hybrid retrieval (improves topic relevance)
    keywords = extract_keywords(effective_question)
    Rails.logger.info("[Search] Hybrid search - Keywords: #{keywords.join(', ')}")
    
    keyword_articles = find_by_keywords(keywords, limit: 10)
    Rails.logger.info("[Search] Keyword search found #{keyword_articles.length} articles")
    
    # Merge embedding + keyword results (hybrid search)
    if keyword_articles.any?
      similar_articles = merge_search_results(similar_articles, keyword_articles)
      Rails.logger.info("[Search] After hybrid merge: #{similar_articles.length} articles")
    end
    
    # Apply core law boosting AFTER hybrid merge to ensure foundational laws are prioritized
    similar_articles = apply_core_law_boosting(similar_articles, effective_question)
    
    return no_answer_response if similar_articles.empty?
    
    # QUALITY FILTER 1: Remove sources with clearly irrelevant titles (soft filter)
    filtered_articles = filter_by_title_relevance(similar_articles, effective_question)
    Rails.logger.info("[Search] After title filter: #{filtered_articles.length} articles")
    
    # FALLBACK: If filter removed everything, use original results (filter was too aggressive)
    if filtered_articles.length < 5
      Rails.logger.info("[Search] Title filter too aggressive, using original results")
      filtered_articles = similar_articles
    end
    
    # QUALITY FILTER 2: Soft similarity threshold (keep at least 5 articles)
    min_similarity = 0.65
    high_sim = filtered_articles.select { |a| a[:similarity] >= min_similarity }
    if high_sim.length >= 5
      similar_articles = high_sim
    else
      similar_articles = filtered_articles.take(10)  # Fallback: take top 10 by score
    end
    Rails.logger.info("[Search] After similarity filter: #{similar_articles.length} articles")
    
    return no_answer_response if similar_articles.empty?
    
    # Take top 15 candidates for final selection
    candidates = similar_articles.take(15)
    
    # QUALITY FILTER 3: GPT rerank to get best 10 sources (balance quality and coverage)
    if candidates.length > 10
      similar_articles = gpt_rerank_candidates(effective_question, candidates, limit: 10)
      Rails.logger.info("[Search] After GPT rerank: #{similar_articles.length} articles")
    else
      similar_articles = candidates
    end
    
    Rails.logger.info("[Search] Final: #{similar_articles.length} articles, top similarity: #{similar_articles.first[:similarity].round(3)}")
    
    # Build context and query LLM
    context = build_legislation_context(similar_articles)
    
    # Inject abolished topic warnings directly into context
    context = inject_abolished_warnings(question, context)
    
    # Add fisconet context if we have tax articles
    if fisconet_articles.any?
      fisconet_context = build_fisconet_context(fisconet_articles)
      context = "#{context}\n\n#{fisconet_context}"
    end
    
    # For follow-ups: add conversation history to LLM context
    if @conversation && @conversation.messages_array.length > 2
      conv_context = @conversation.conversation_context
      context = "#{conv_context}\n\n---\n\n#{context}" if conv_context
    end
    
    answer = query_llm(question, context, source_type: :legislation)
    
    # Generate follow-up suggestions based on question topic
    suggestions = generate_follow_up_suggestions(question)
    
    {
      answer: answer,
      sources: format_legislation_sources(similar_articles) + format_fisconet_sources(fisconet_articles),
      suggestions: suggestions,
      language: @language
    }
  end
  
  # Detect if question is a vague follow-up that needs context
  def is_followup_question?(question)
    q = question.downcase.strip
    
    # Short questions are likely follow-ups
    return true if q.split.length <= 5
    
    # Dutch follow-up patterns
    nl_patterns = [
      /^(wat|welke|hoe|wanneer|waar|wie|waarom)\s+(zijn|is|moet|kan|mag)\s+(die|dat|deze|dit|ze|het)/i,
      /^(en|maar|of|dus)\s/i,
      /^(meer|verder|specifiek|detail)/i,
      /\b(die|dat|deze|dit|ervan|erbij|erover|hierover|daarover)\b/i,
      /^(leg uit|vertel meer|geef meer|kun je|kunt u)/i,
      /^(wat bedoel|wat betekent|wat houdt)/i,
      /\b(de regels|de wet|de voorwaarden|de procedure)\b/i
    ]
    
    # French follow-up patterns
    fr_patterns = [
      /^(qu'est-ce|quelles?|comment|quand|où|qui|pourquoi)\s+(sont|est|dois|peut|faut)\s+(ces?|cette?|cela|ça)/i,
      /^(et|mais|ou|donc)\s/i,
      /^(plus|encore|spécifiquement|en détail)/i,
      /\b(ces?|cette?|cela|ça|en|y|là-dessus)\b/i,
      /^(expliquez|dites-moi|donnez-moi|pouvez-vous)/i,
      /^(que signifie|qu'entendez|que veut dire)/i,
      /\b(les règles|la loi|les conditions|la procédure)\b/i
    ]
    
    (nl_patterns + fr_patterns).any? { |p| q.match?(p) }
  end
  
  # Expand vague follow-up questions with context from conversation
  def expand_followup_question(question)
    return question unless @conversation && is_followup_question?(question)
    
    # Get the topic from last question
    last_q = @conversation.last_question
    return question unless last_q.present?
    
    # Extract key topic words from last question
    topic_words = last_q.downcase.split(/\s+/).select { |w| w.length > 4 }
    return question if topic_words.empty?
    
    # Combine current question with topic context
    "#{question} (context: #{topic_words.first(5).join(' ')})"
  end
  
  # Inject articles from conversation context NUMACs
  def inject_context_articles(numacs, question_lower)
    keywords = question_lower.split(/\s+/).select { |w| w.length > 3 }
    
    injected = []
    numacs.first(3).each do |numac|
      articles = Article
        .select('articles.*, legislation.title as law_title, legislation.is_abolished')
        .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
        .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
        .where(content_numac: numac, language_id: @language_id)
        .limit(20)
      
      scored = articles.map do |article|
        text = "#{article.article_title} #{article.article_text}".downcase
        matches = keywords.count { |term| text.include?(term) }
        
        {
          id: article.id,
          numac: article.content_numac,
          law_title: article.law_title || 'Unknown',
          article_title: article.article_title,
          article_text: article.article_text,
          language_id: article.language_id,
          similarity: 0.80 + (matches * 0.02), # High base score for context
          is_abolished: article.try(:is_abolished) == 1
        }
      end
      
      injected.concat(scored.sort_by { |a| -a[:similarity] }.take(2))
    end
    
    Rails.logger.info("[Search] Injected #{injected.length} articles from conversation context")
    injected
  end
  
  # Generate follow-up suggestions based on detected keywords in question
  def generate_follow_up_suggestions(question)
    question_lower = question.downcase
    
    # Detect question language for suggestions
    lang_key = detect_question_language(question_lower)
    
    # Find matching topic based on keywords
    FOLLOW_UP_SUGGESTIONS.each do |keyword, suggestions|
      next if keyword == '_default'
      if question_lower.include?(keyword)
        # Fall back to nl if language not available for this topic
        return suggestions[lang_key] || suggestions[:nl]
      end
    end
    
    # Return default suggestions if no topic matched
    FOLLOW_UP_SUGGESTIONS['_default'][lang_key] || FOLLOW_UP_SUGGESTIONS['_default'][:nl]
  end
  
  # Detect question language (en, fr, nl, de) based on common words
  def detect_question_language(question)
    # English indicators - expanded list
    en_words = %w[what how when where why which who can may must should would could have has been the and for with from is an a are do does did will about my your their this that these those it if or but not any all some]
    # French indicators  
    fr_words = %w[quel quelle quand comment pourquoi combien est-ce que puis-je ai-je le la les des une un pour avec dans sur je suis mon ma mes]
    # Dutch indicators - expanded with common Dutch words
    nl_words = %w[wat hoe wanneer waar waarom welke wie kan mag moet zou heb heeft zijn mijn het de een van voor met bij ik ben dit dat deze die bepaalde tijd werk contract dagen jaren maanden hoeveel welk]
    # German indicators - exclude words shared with Dutch to avoid false positives
    de_words = %w[wann warum kann darf muss soll würde könnte habe hat mein das der eine für dies dieser ist und auch nicht aber wenn dann oder noch sehr]
    
    words = question.downcase.gsub(/[?!.,]/, '').split(/\s+/)
    
    en_count = words.count { |w| en_words.include?(w) }
    fr_count = words.count { |w| fr_words.include?(w) }
    nl_count = words.count { |w| nl_words.include?(w) }
    de_count = words.count { |w| de_words.include?(w) }
    
    # English boosters - legal terms and common patterns
    en_count += 2 if question.downcase =~ /\b(employment|contract|dismissal|vacation|salary|employer|employee|rights|entitled|allowed|notice|period|leave|maternity|paternity|pension|insurance|tax|rent|tenant|landlord|divorce|custody|inheritance|company|director|shareholder|consumer|warranty|criminal|fine|prison|privacy|gdpr)\b/
    en_count += 1 if question.downcase =~ /\b(i am|i'm|i have|i need|i want|my rights|at home|how long|how much|how many|am i|can i|may i|do i|does the|is it|is there|are there)\b/
    
    # French boosters - legal terms and common patterns  
    fr_count += 2 if question.downcase =~ /\b(licenciement|préavis|congé|employeur|salarié|pension|retraite|chômage|divorce|garde|succession|société|administrateur|consommateur|garantie|loyer|locataire|propriétaire|amende|prison)\b/
    fr_count += 1 if question.downcase =~ /\b(je suis|j'ai|je veux|mes droits|est-ce que|puis-je|ai-je|combien de|quelle est|quelles sont|y a-t-il)\b/
    
    # Dutch boosters - legal terms (less needed as fallback, but helps accuracy)
    nl_count += 2 if question.downcase =~ /\b(arbeidsovereenkomst|opzegtermijn|ontslag|werkgever|werknemer|vakantie|pensioen|werkloosheid|echtscheiding|voogdij|erfenis|vennootschap|bestuurder|consument|garantie|huur|huurder|verhuurder|boete|gevangenis)\b/
    nl_count += 1 if question.downcase =~ /\b(ik ben|ik heb|ik wil|mijn rechten|hoeveel dagen|hoe lang|mag ik|kan ik|moet ik|heb ik recht)\b/
    
    # German boosters - umlauts are strong German indicators
    de_count += 3 if question =~ /[äöüÄÖÜß]/  # Umlauts are distinctly German
    de_count += 2 if question.downcase =~ /\b(arbeitsvertrag|kündigung|kündigungsfrist|urlaub|gehalt|arbeitgeber|arbeitnehmer|rechte|anspruch|frist|mutterschutz|elternzeit|rente|versicherung|steuer|miete|mieter|vermieter|scheidung|sorgerecht|erbschaft|gesellschaft|geschäftsführer|verbraucher|garantie|strafe|gefängnis)\b/
    de_count += 1 if question.downcase =~ /\b(ich bin|ich habe|ich will|meine rechte|wie lange|wie viel|darf ich|kann ich|muss ich|habe ich)\b/
    
    # Return detected language - Dutch/French are primary (Belgian law app)
    # German only triggers if EXPLICITLY German (very high threshold)
    if fr_count > nl_count && fr_count >= 2
      :fr
    elsif en_count > fr_count && en_count > nl_count && en_count >= 2
      :en
    elsif de_count >= 4 && de_count > nl_count * 2 && de_count > fr_count * 2
      :de  # German only if overwhelming evidence (4+ German words, 2x more than Dutch/French)
    else
      # Default to Dutch for Belgian law context
      @language == 'fr' ? :fr : :nl
    end
  end
  
  # Extract important keywords from question with legal term mappings
  def extract_keywords(question)
    # Expanded stop words to filter out
    stop_words = %w[wat is de het een op van voor met als in door bij hoe kan mag moet waar wanneer welke wie waarom hoeveel zijn mijn ik recht hebben rechten onder aan naar tot dit deze die dat jaar jaren]
    
    # Legal term mappings: user term → [search terms with synonyms]
    legal_terms = {
      # Employment & contracts
      /vakantiedagen|jaarlijks.*vakantie/i => ['vakantiedagen', 'jaarlijkse vakantie', 'wettelijke vakantie', 'verlof'],
      'ontslag' => ['ontslag', 'opzeg', 'beëindiging', 'ontslaan', 'opzegtermijn', 'opzegvergoeding'],
      'zelfstandig' => ['zelfstandig', 'zelfstandige', 'freelance', 'independent', 'schijnzelfstandigheid'],
      'deeltijd' => ['deeltijd', 'deeltijds', 'part-time', 'parttime'],
      'proef' => ['proef', 'proeftijd', 'proefperiode', 'trial period', 'testperiode'],
      'concurrentie' => ['concurrentiebeding', 'niet-concurrentiebeding', 'concurrentie', 'non-compete'],
      'arbeider' => ['arbeider', 'arbeiders', 'blue collar', 'handarbeider'],
      'bediende' => ['bediende', 'bedienden', 'white collar', 'kantoorwerk'],
      'loon' => ['loon', 'salaris', 'verloning', 'minimumloon', 'bezoldiging'],
      'overuren' => ['overuren', 'meeruren', 'extra uren', 'overtime'],
      /arbeidsovereenkomst|arbeidscontract|werkcontract/i => ['arbeidsovereenkomst', 'arbeidscontract', 'dienstverband', 'tewerkstelling'],
      /deeltijds.*werk|parttime/i => ['deeltijds', 'part-time', 'gedeeltelijke arbeid', 'halftijds'],
      /overuren|over.*uren|meeruren/i => ['overuren', 'meeruren', 'aanvullende prestaties', 'extra uren'],
      
      # Dismissal & termination
      /ontslag|afdanking/i => ['ontslag', 'afdanking', 'beëindiging', 'arbeidsbeëindiging'],
      /dringende.*reden|dringend.*ontslag/i => ['dringende reden', 'dringend ontslag', 'onmiddellijke beëindiging'],
      
      # Social security & contributions
      /zelfstandige|ondernemer/i => ['zelfstandige', 'zelfstandig ondernemer', 'vrij beroep'],
      /sociale.*bijdrage|rsz/i => ['sociale bijdragen', 'RSZ', 'socialezekerheidsbijdrage'],
      /werkloosheid|werkloosheidsuitkering/i => ['werkloosheid', 'werkloosheidsuitkering', 'werkloosheidsvergoeding'],
      
      # Wages & compensation
      /minimumloon|minimum.*loon/i => ['minimumloon', 'minimum loon', 'gewaarborgd loon'],
      /loon|salaris|bezoldiging/i => ['loon', 'salaris', 'bezoldiging', 'wedde'],
      /eindejaar.*premie|13.*maand/i => ['eindejaarspremie', '13de maand', 'dertiende maand'],
      
      # Leave & absences
      /ziekteverlof|ziek/i => ['ziekteverlof', 'ziekte', 'arbeidsongeschiktheid'],
      /zwangerschapsverlof|moederschaps/i => ['zwangerschapsverlof', 'moederschapsverlof', 'bevallingsrust'],
      
      # Discrimination & harassment
      /discriminatie|ongelijke.*behandeling/i => ['discriminatie', 'ongelijke behandeling', 'gelijke behandeling'],
      /pesten|pestgedrag|intimidatie|harassment/i => ['pestgedrag', 'pesten', 'intimidatie', 'psychosociale risicos'],
      
      # Work conditions
      /thuiswerk|telewerk|remote/i => ['thuiswerk', 'telewerk', 'thuiswerken', 'afstandswerk'],
      /arbeidsduur|werkuren|arbeidstijd/i => ['arbeidsduur', 'arbeidstijd', 'werkuren', 'arbeidstijdvermindering'],
      /concurrentiebeding|concurrentie/i => ['concurrentiebeding', 'niet-concurrentiebeding', 'concurrentieclausule'],
      
      # Specific cases
      /burnout/i => ['burnout', 'overspanning', 'psychische belasting', 'arbeidsongeval'],
    }
    
    # Find matching legal terms
    phrases = []
    legal_terms.each do |pattern, terms|
      # Handle both regex and string patterns
      match = if pattern.is_a?(Regexp)
        question =~ pattern
      else
        question.downcase.include?(pattern.to_s.downcase)
      end
      phrases += terms if match
    end
    
    # Extract meaningful words as fallback
    # Keep important short keywords like BTW, RSZ, CAO, ZIV, etc.
    important_short = %w[btw rsz cao ziv igo bob rva wet kb mb bw]
    words = question.downcase.split(/\W+/)
    keywords = words.select { |w| (w.length >= 4 || important_short.include?(w)) && !stop_words.include?(w) }
    
    # Combine: prioritize legal terms, add keywords
    result = phrases.compact.uniq
    result += keywords.take(4) if result.length < 3
    result.uniq.take(8)  # Max 8 search terms
  end
  
  # Find articles by keyword search (fallback for poor embeddings)
  def find_by_keywords(keywords, limit: 5)
    return [] if keywords.empty?
    
    # Build sanitized LIKE conditions
    conditions = []
    params = []
    
    keywords.each do |kw|
      sanitized = kw.gsub("'", "''") # SQL escape
      conditions << "article_text LIKE ?"
      params << "%#{sanitized}%"
    end
    
    articles = Article.includes(:content)
                      .where(conditions.join(' OR '), *params)
                      .where(language_id: @language == 'fr' ? 2 : 1)
                      .limit(limit * 3)
    
    Rails.logger.info("Keyword search found #{articles.count} articles")
    
    # Convert to same format as embedding results
    articles.map do |article|
      next unless article.content
      {
        id: article.id,
        numac: article.content_numac,
        law_title: article.content.legislation&.title || 'Unknown',
        article_title: article.article_title,
        article_text: article.article_text,
        language_id: article.language_id,
        similarity: 0.75 # Higher than weak embeddings
      }
    end.compact.take(limit)
  end
  
  # GPT query expansion: Convert natural language to better search terms
  def expand_query_with_gpt(question)
    prompt = if @language == 'fr'
      "Tu es un expert en droit belge. Reformule cette question pour une recherche dans des textes juridiques.
Ajoute des synonymes et termes juridiques pertinents.
Garde la réponse courte (max 30 mots).

Question: #{question}

Recherche:"
    else
      "Je bent een expert in Belgisch recht. Herformuleer deze vraag als zoekopdracht voor juridische teksten.
Voeg relevante synoniemen en juridische termen toe.
Houd het antwoord kort (max 30 woorden).

Vraag: #{question}

Zoekopdracht:"
    end
    
    messages = [{ role: 'user', content: prompt }]
    
    begin
      expanded = azure_chat_completion(messages, temperature: 0.3, max_tokens: 100)
      expanded&.strip || question
    rescue => e
      Rails.logger.warn("[QueryExpansion] Failed: #{e.message}, using original")
      question
    end
  end
  
  # Rerank articles with embeddings (fast cosine similarity)
  def rerank_with_embeddings(articles, question_embedding)
    articles.map do |article|
      # Generate embedding for article text
      article_text = [article[:article_title], article[:article_text]].compact.join(": ")
      article_text = article_text[0..2000] # Limit for speed
      
      article_embedding = generate_embedding(article_text)
      similarity = cosine_similarity(question_embedding, article_embedding)
      
      article.merge(similarity: similarity)
    end.sort_by { |a| -a[:similarity] }
  rescue => e
    Rails.logger.warn("[EmbeddingRerank] Failed: #{e.message}, returning as-is")
    articles
  end
  
  # GPT-based relevance scoring (slow but accurate)
  def gpt_rerank_candidates(question, candidates, limit: 5)
    return candidates.take(limit) if candidates.length <= limit
    
    Rails.logger.info("[GPTRerank] Scoring #{candidates.length} candidates")
    
    # Score each candidate with GPT
    scored = candidates.map do |article|
      score = gpt_relevance_score(question, article[:article_text])
      [article, score]
    end
    
    # Sort by GPT score and take top N
    scored.sort_by { |_, score| -score }
           .take(limit)
           .map { |article, _| article }
  rescue => e
    Rails.logger.warn("[GPTRerank] Failed: #{e.message}, using embedding scores")
    candidates.take(limit)
  end
  
  # Score article relevance with GPT (0.0 - 1.0)
  def gpt_relevance_score(question, article_text)
    # Truncate article for speed
    snippet = article_text&.slice(0, 800) || ""
    
    prompt = if @language == 'fr'
      "Évalue la pertinence de cet article pour la question (score 0-10).
Réponds uniquement avec un nombre.

Question: #{question}

Article: #{snippet}

Score:"
    else
      "Beoordeel de relevantie van dit artikel voor de vraag (score 0-10).
Antwoord alleen met een getal.

Vraag: #{question}

Artikel: #{snippet}

Score:"
    end
    
    messages = [{ role: 'user', content: prompt }]
    
    begin
      response = azure_chat_completion(messages, temperature: 0.0, max_tokens: 10)
      score_str = response&.strip&.match(/\d+/)&.[](0)
      score = score_str ? score_str.to_f / 10.0 : 0.5
      score.clamp(0.0, 1.0)
    rescue => e
      Rails.logger.warn("[RelevanceScore] Failed: #{e.message}")
      0.5 # Default neutral score
    end
  end
  
  # Merge embedding and keyword results, removing duplicates
  def merge_search_results(embedding_results, keyword_results)
    seen_ids = Set.new
    merged = []
    
    # Add all results, tracking IDs to avoid duplicates
    (embedding_results + keyword_results).each do |result|
      next if seen_ids.include?(result[:id])
      seen_ids.add(result[:id])
      merged << result
    end
    
    # Sort by similarity and take top 15
    merged.sort_by { |r| -r[:similarity] }.take(15)
  end
  
  # ARTICLE-LEVEL RETRIEVAL: Direct search using article embeddings
  # Uses FAISS for fast exact search, falls back to sampling if unavailable
  # Now includes core law boosting to prioritize foundational laws over sector CAOs
  def find_similar_legislation(question_embedding, limit: 5, progress_callback: nil, question: nil)
    # Try FAISS service first (fast path - searches all 2.76M articles in <1s)
    # Request more results so we have room for boosting/reranking
    top_articles = find_similar_legislation_faiss(question_embedding, limit * 2)
    
    # Fallback to direct DB search if FAISS unavailable
    if top_articles.nil?
      Rails.logger.warn("FAISS service unavailable, falling back to sampled DB search")
      return find_similar_legislation_direct(question_embedding, limit: limit)
    end
    
    # Apply core law boosting if question provided
    if question.present?
      top_articles = apply_core_law_boosting(top_articles, question)
    end
    
    # Return top N after boosting
    top_articles.take(limit)
  end
  
  # Apply boost to articles from core/foundational laws
  # This ensures general laws are prioritized over sector-specific CAOs
  def apply_core_law_boosting(articles, question)
    question_lower = question.downcase
    
    # Find which core laws are relevant based on keywords
    relevant_core_numacs = Set.new
    KEYWORD_TO_CORE_LAWS.each do |keyword, numacs|
      if question_lower.include?(keyword.to_s.downcase)
        numacs.each { |n| relevant_core_numacs.add(n) }
      end
    end
    
    # INJECTION: If core laws are relevant but missing from results, inject them
    if relevant_core_numacs.any?
      existing_numacs = articles.map { |a| a[:numac] }.to_set
      missing_numacs = relevant_core_numacs - existing_numacs
      
      if missing_numacs.any?
        injected = inject_core_law_articles(missing_numacs, question_lower)
        if injected.any?
          Rails.logger.info("Core law injection: Added #{injected.length} articles")
          articles = articles + injected
        end
      end
    end
    
    # Apply boost to core laws, freshness boost, and penalty to sector-specific CAOs
    boosted = articles.map do |article|
      numac = article[:numac]
      law_title = article[:law_title] || ''
      boost = 1.0
      
      # Core law boosting
      if CORE_LAW_NUMACS.key?(numac)
        if relevant_core_numacs.include?(numac)
          boost = CORE_LAW_BOOST * 1.1
          Rails.logger.debug("Strong boost for #{CORE_LAW_NUMACS[numac]} (keyword match)")
        else
          boost = CORE_LAW_BOOST
        end
      elsif is_sector_cao?(law_title)
        boost = CAO_PENALTY
        Rails.logger.debug("CAO penalty applied to: #{law_title[0..60]}")
      end
      
      # Freshness boost: recently modified laws get slight priority
      if article[:modification_count].to_i > 50
        boost *= 1.05  # Laws with many amendments are likely still relevant
      end
      
      # COVID penalty: penalize COVID-era temporary measures
      if law_title =~ /covid|corona|pandemie|tijdelijke.*2020|tijdelijke.*2021/i
        boost *= 0.7
        Rails.logger.debug("COVID penalty applied to: #{law_title[0..60]}")
      end
      
      # Abolished law penalty: strongly deprioritize abolished laws
      if article[:is_abolished]
        boost *= 0.5
        Rails.logger.debug("Abolished law penalty applied to: #{law_title[0..60]}")
      end
      
      # Text-based abolished detection: check if article text says "opgeheven"
      article_text = article[:article_text].to_s.downcase
      if article_text =~ /\b(opgeheven|abrogé|afgeschaft|geschrapt)\b/
        boost *= 0.6
        Rails.logger.debug("Text-based abolished penalty applied to article")
      end
      
      article.merge(similarity: article[:similarity] * boost, boosted: boost > 1.0)
    end
    
    # Re-sort by boosted similarity
    result = boosted.sort_by { |a| -a[:similarity] }
    
    # Log if boosting changed the order
    core_in_top5 = result.take(5).count { |a| a[:boosted] }
    if core_in_top5 > 0
      Rails.logger.info("Core law boosting: #{core_in_top5}/5 top results are from foundational laws")
    end
    
    result
  end
  
  # Filter articles by title relevance to the question
  # Removes sources whose titles clearly don't match the question topic
  def filter_by_title_relevance(articles, question)
    question_lower = question.downcase
    question_words = question_lower.split(/\s+/).select { |w| w.length > 3 }
    
    # Extract key topic words from question
    topic_keywords = extract_topic_keywords(question_lower)
    
    articles.select do |article|
      title = (article[:law_title] || '').downcase
      
      # Always keep core laws
      next true if CORE_LAW_NUMACS.key?(article[:numac])
      
      # Check if title has ANY relevance to question
      title_words = title.split(/\s+/)
      
      # Must have at least one topic keyword match OR high similarity
      has_topic_match = topic_keywords.any? { |kw| title.include?(kw) }
      has_word_overlap = (question_words & title_words).any?
      high_similarity = article[:similarity] >= 1.5
      
      has_topic_match || has_word_overlap || high_similarity
    end
  end
  
  # Extract key topic keywords from question for filtering
  def extract_topic_keywords(question)
    # Map common question topics to relevant title keywords
    topic_map = {
      'ontslag' => %w[arbeid ontslag werk],
      'opzeg' => %w[arbeid ontslag opzeg],
      'vakantie' => %w[vakantie arbeid werk verlof],
      'huur' => %w[huur woning woon verhuur],
      'belasting' => %w[belasting fiscaal btw inkomsten],
      'echtscheiding' => %w[echtscheiding huwelijk burgerlijk],
      'erfenis' => %w[erfenis successie nalatenschap burgerlijk],
      'vennootschap' => %w[vennootschap onderneming economisch],
      'straf' => %w[straf boete sanctie verkeer],
      'rijbewijs' => %w[verkeer rijbewijs wegverkeer],
      'werkloosheid' => %w[werkloosheid uitkering sociale],
      'pensioen' => %w[pensioen sociale zekerheid],
      'kinderbijslag' => %w[kind gezin groeipakket],
      'garantie' => %w[consument garantie economisch],
    }
    
    keywords = []
    topic_map.each do |topic, title_keywords|
      if question.include?(topic)
        keywords.concat(title_keywords)
      end
    end
    
    # Add generic keywords from question
    question.split(/\s+/).each do |word|
      keywords << word if word.length >= 5
    end
    
    keywords.uniq
  end
  
  # Detect sector-specific CAOs that should be deprioritized for general questions
  # These are collective agreements for specific industries, not general labor law
  def is_sector_cao?(law_title)
    return false if law_title.blank?
    title_lower = law_title.downcase
    
    # Patterns indicating sector-specific CAOs
    cao_patterns = [
      /paritair comit[eé]/i,           # Paritair Comité (joint committees)
      /paritair subcomit[eé]/i,        # Paritair Subcomité
      /collectieve arbeidsovereenkomst/i,  # CAO
      /convention collective/i,         # French: CAO
      /commission paritaire/i,          # French: joint committee
      /sous-commission paritaire/i,     # French: joint subcommittee
      /pc\s*\d+/i,                      # PC 100, PC 200, etc.
      /cp\s*\d+/i,                      # CP (French)
    ]
    
    # Sector keywords that indicate narrow applicability
    sector_keywords = [
      'hardsteengroeven', 'kwartsietgroeven', 'zandsteen',  # Stone quarries
      'warenhuizen', 'groothandelaar',                       # Retail
      'voedingsnijverheid', 'bakkerijen',                   # Food industry
      'textielnijverheid', 'kleding',                       # Textile
      'metaal', 'garage', 'carrosserie',                    # Metal/auto
      'bouw', 'hout', 'meubel',                             # Construction/wood
      'haven', 'scheepvaart', 'luchtvaart',                 # Transport
      'hotels', 'horeca', 'toerisme',                       # Hospitality
    ]
    
    # Check CAO patterns
    return true if cao_patterns.any? { |p| title_lower.match?(p) }
    
    # Check sector keywords (only if also looks like a CAO/agreement)
    if title_lower.include?('overeenkomst') || title_lower.include?('convention')
      return true if sector_keywords.any? { |k| title_lower.include?(k) }
    end
    
    false
  end
  
  # Inject articles from core laws that are missing from FAISS results
  # Uses keyword root matching to find relevant articles, with fallback to top articles
  def inject_core_law_articles(numacs, question_lower)
    # Extract key terms and their roots for matching
    keywords = question_lower.split(/\s+/).select { |w| w.length > 3 }
    roots = keywords.select { |w| w.length >= 6 }.map { |w| w[0, 5] }
    search_terms = (keywords + roots).uniq
    
    injected = []
    numacs.each do |numac|
      # Find articles from this core law (include is_abolished status and preamble)
      articles = Article
        .select('articles.*, legislation.title as law_title, legislation.date, legislation.is_abolished, contents.preamble')
        .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
        .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
        .where(content_numac: numac, language_id: @language_id)
        .limit(100)
      
      # Score articles by keyword/root matches in title/text
      scored = articles.map do |article|
        text = "#{article.article_title} #{article.article_text}".downcase
        matches = search_terms.count { |term| text.include?(term) }
        
        {
          id: article.id,
          numac: article.content_numac,
          law_title: article.law_title || CORE_LAW_NUMACS[numac] || 'Unknown',
          article_title: article.article_title,
          article_text: article.article_text,
          language_id: article.language_id,
          similarity: 0.70 + (matches * 0.03), # Base 0.70, up to 0.85 with matches
          injected: true,
          match_count: matches,
          is_abolished: article.try(:is_abolished) == 1,
          preamble: article.try(:preamble)
        }
      end
      
      # Sort by matches (desc), then take top 2
      # This ensures we always inject SOMETHING from the core law, even without keyword matches
      top_articles = scored.sort_by { |a| [-a[:match_count], -a[:similarity]] }.take(2)
      
      # Log what we're injecting
      if top_articles.any?
        match_info = top_articles.map { |a| "#{a[:article_title]}(#{a[:match_count]} matches)" }.join(', ')
        Rails.logger.info("Injecting from #{CORE_LAW_NUMACS[numac] || numac}: #{match_info}")
      end
      
      injected += top_articles
    end
    
    injected
  end
  
  # Call FAISS service for fast article similarity search
  def find_similar_legislation_faiss(question_embedding, limit)
    require 'net/http'
    require 'json'
    
    faiss_url = FAISS_LARGE_URL  # Use large embeddings FAISS on port 8767
    uri = URI("#{faiss_url}/search")
    
    request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
    request.body = { embedding: question_embedding, limit: limit }.to_json
    
    response = Net::HTTP.start(uri.hostname, uri.port, 
                                use_ssl: uri.scheme == 'https',
                                open_timeout: 5, read_timeout: 10) do |http|
      http.request(request)
    end
    
    if response.is_a?(Net::HTTPSuccess)
      data = JSON.parse(response.body)
      Rails.logger.info("FAISS article search completed in #{data['search_time_ms'].round(1)}ms (searched #{data['total_indexed']} articles)")
      
      # Fetch full article details from Rails DB (including abolished status)
      article_ids = data['results'].map { |r| r['article_id'] }
      articles_by_id = Article
        .select('articles.*, legislation.title as law_title, legislation.date, legislation.is_abolished')
        .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
        .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
        .where(id: article_ids)
        .index_by(&:id)
      
      # Map results with similarity scores - boost same-language articles
      data['results'].map do |result|
        article = articles_by_id[result['article_id']]
        next unless article
        
        # Boost same-language articles by 20% to prefer user's language
        adjusted_similarity = article.language_id == @language_id ? result['similarity'] * 1.20 : result['similarity']
        
        {
          id: article.id,
          numac: article.content_numac,
          law_title: article.law_title || 'Unknown',
          article_title: article.article_title,
          article_text: article.article_text,
          language_id: article.language_id,
          similarity: adjusted_similarity,
          is_abolished: article.try(:is_abolished) == 1
        }
      end.compact.sort_by { |a| -a[:similarity] }
    else
      Rails.logger.error("FAISS article service error: #{response.code} #{response.message}")
      nil
    end
  rescue StandardError => e
    Rails.logger.debug("FAISS article service unavailable: #{e.message}")
    nil
  end
  
  # Direct database search (fallback when FAISS unavailable)
  # Samples 2% of articles for speed
  def find_similar_legislation_direct(question_embedding, limit: 5)
    emb_db = article_embeddings_db
    
    q_vec = question_embedding
    q_magnitude = Math.sqrt(q_vec.sum { |x| x * x })
    
    # Find top articles
    top_matches = []
    min_similarity = 0.0
    
    # Fast random sampling: LIMIT to 5000 records for speed
    # Large embedding DB (31GB) is too slow to scan - use random offset + limit
    sample_size = 5000
    total_count = emb_db.get_first_value('SELECT COUNT(*) FROM article_embeddings')
    random_offset = rand(total_count - sample_size)
    Rails.logger.info("Sampling #{sample_size} of #{total_count} article embeddings (offset #{random_offset})...")
    
    emb_db.execute("SELECT article_id, embedding FROM article_embeddings LIMIT ? OFFSET ?", [sample_size, random_offset]) do |row|
      article_id = row[0]
      embedding_blob = row[1]
      stored_vec = embedding_blob.unpack('e*')
      
      # Fast cosine similarity
      dot = 0.0
      stored_mag_sq = 0.0
      q_vec.each_with_index do |v, i|
        dot += v * stored_vec[i]
        stored_mag_sq += stored_vec[i] * stored_vec[i]
      end
      stored_magnitude = Math.sqrt(stored_mag_sq)
      
      similarity = (q_magnitude > 0 && stored_magnitude > 0) ? dot / (q_magnitude * stored_magnitude) : 0.0
      
      # Keep top N matches (store article_id and similarity only)
      if top_matches.size < limit
        top_matches << [article_id, similarity]
        min_similarity = top_matches.min_by { |_, s| s }[1] if top_matches.size == limit
      elsif similarity > min_similarity
        top_matches.delete(top_matches.min_by { |_, s| s })
        top_matches << [article_id, similarity]
        min_similarity = top_matches.min_by { |_, s| s }[1]
      end
    end
    
    Rails.logger.info("Sampled search found #{top_matches.size} articles with similarities: #{top_matches.map { |_, s| s.round(3) }.join(', ')}")
    
    # Fetch full article details from Rails DB (including abolished status)
    article_ids = top_matches.map { |id, _| id }
    articles_by_id = Article
      .select('articles.*, legislation.title as law_title, legislation.date, legislation.is_abolished')
      .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
      .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
      .where(id: article_ids)
      .index_by(&:id)
    
    # Map results with similarity scores - boost same-language articles
    top_matches.map do |article_id, similarity|
      article = articles_by_id[article_id]
      next unless article
      
      # Boost same-language articles by 20% to prefer user's language
      adjusted_similarity = article.language_id == @language_id ? similarity * 1.20 : similarity
      
      {
        id: article.id,
        numac: article.content_numac,
        law_title: article.law_title || 'Unknown',
        article_title: article.article_title,
        article_text: article.article_text,
        language_id: article.language_id,
        similarity: adjusted_similarity,
        is_abolished: article.try(:is_abolished) == 1
      }
    end.compact.sort_by { |a| -a[:similarity] }
  end
  
  # Build context from legislation articles
  # Includes abolished warnings, exdecs, modifications, and parliamentary context
  def build_legislation_context(articles)
    # Track which numacs we've added preamble for (only add once per law)
    seen_preambles = Set.new
    
    articles.map do |article|
      text = article[:article_text].to_s[0..1500]
      numac = article[:numac]
      
      # Status warnings
      warnings = []
      warnings << "[OPGEHEVEN/ABROGÉ]" if article[:is_abolished]
      
      # Check article_modifications for specific article abolition
      article_num = article[:article_title].to_s.gsub(/\D/, '')[0..5] # Extract article number
      if article_num.present?
        begin
          abolition_date = ArticleModification.abolition_date(numac, article_num, @language_id)
          if abolition_date
            warnings << "[ARTIKEL OPGEHEVEN OP #{abolition_date}]"
          end
        rescue => e
          Rails.logger.debug("ArticleModification check failed: #{e.message}")
        end
      end
      
      # Text-based detection: check if article text itself says it's abolished
      if text =~ /\b(opgeheven|abrogé|afgeschaft|geschrapt|vervallen)\b/i
        warnings << "[BEPALING MOGELIJK OPGEHEVEN - controleer actuele status]"
      end
      
      # Check for implementing decrees (exdecs)
      exdec_count = Exdec.where(content_numac: numac, language_id: @language_id).count rescue 0
      warnings << "[HEEFT #{exdec_count} UITVOERINGSBESLUITEN]" if exdec_count > 0
      
      # Check for modifications and abolitions
      begin
        updating_laws = UpdatedLaw
          .joins("LEFT JOIN legislation ON updated_laws.update_numac = legislation.numac AND legislation.language_id = #{@language_id}")
          .where(content_numac: numac, language_id: @language_id)
          .select('legislation.title as updating_title')
        
        update_count = updating_laws.count
        warnings << "[GEWIJZIGD DOOR #{update_count} WETTEN]" if update_count > 0
        
        # Check if any modifying law abolishes provisions (ophef, afschaf, intrekk)
        abolition_laws = updating_laws.where("legislation.title LIKE '%ophef%' OR legislation.title LIKE '%afschaf%' OR legislation.title LIKE '%intrekk%'")
        if abolition_laws.any?
          warnings << "[BEVAT OPGEHEVEN BEPALINGEN - controleer actuele status]"
        end
      rescue => e
        Rails.logger.debug("Error checking modifications: #{e.message}")
      end
      
      warning_str = warnings.any? ? " #{warnings.join(' ')}" : ""
      
      # Add preamble (parliamentary context) once per law if available
      preamble_text = ""
      if article[:preamble].present? && !seen_preambles.include?(numac)
        seen_preambles.add(numac)
        preamble_text = "\n[PARLEMENTAIRE CONTEXT: #{article[:preamble].to_s[0..500]}]"
      end
      
      "[WET NUMAC #{numac}#{warning_str}] #{article[:law_title]}\n#{article[:article_title]}\n#{text}#{preamble_text}"
    end.join("\n\n---\n\n")
  end
  
  # Inject warnings about abolished topics directly into context
  # This helps the LLM understand the context before reading sources
  def inject_abolished_warnings(question, context)
    q = question.downcase
    warnings = []
    
    if q.include?('proefperiode') || q.include?('proeftijd')
      warnings << <<~WARN
        ⚠️ KRITIEKE CONTEXT VOOR DEZE VRAAG:
        De PROEFPERIODE voor gewone arbeidsovereenkomsten is AFGESCHAFT sinds 1 januari 2014 (Wet Eenheidsstatuut).
        De bronnen hieronder kunnen verwijzen naar een 3-dagen proefperiode, maar dit geldt ALLEEN voor:
        - Uitzendarbeid (interim)
        - Studentencontracten
        Dit is NIET de algemene regel. Begin je antwoord met de afschaffing in 2014, daarna pas de uitzonderingen.
      WARN
    end
    
    if q.include?('carensdag')
      warnings << <<~WARN
        ⚠️ KRITIEKE CONTEXT VOOR DEZE VRAAG:
        De CARENSDAG is AFGESCHAFT sinds 1 januari 2014.
        Vroeger: eerste ziektedag onbetaald. Nu: eerste ziektedag WEL betaald (gewaarborgd loon vanaf dag 1).
        Begin je antwoord met deze afschaffing.
      WARN
    end
    
    # Regional topics - ALWAYS mention all 3 regions
    regional_topics = ['registratierecht', 'kinderbijslag', 'groeipakket', 'huur', 'woninghuur', 
                       'erfbelasting', 'successie', 'onroerende voorheffing', 'premie', 'renovatie']
    if regional_topics.any? { |topic| q.include?(topic) }
      warnings << <<~WARN
        ⚠️ DIT IS EEN REGIONAAL ONDERWERP - VERMELD ALTIJD ALLE 3 GEWESTEN:
        België heeft 3 gewesten met VERSCHILLENDE wetgeving. Je MOET vermelden:
        
        REGISTRATIERECHTEN:
        - Vlaanderen: 2% (enige eigen woning), 12% (andere)
        - Wallonië: 12.5% (verlaagd 6% onder voorwaarden)
        - Brussel: 12.5% (abattement €200.000 mogelijk)
        
        KINDERBIJSLAG/GROEIPAKKET:
        - Vlaanderen: €173.20/maand basis
        - Wallonië: €181.61/maand basis  
        - Brussel: €168.50/maand basis
        
        Voeg ALTIJD een sectie "⚠️ REGIONALE VERSCHILLEN" toe met de 3 gewesten!
      WARN
    end
    
    return context if warnings.empty?
    
    "#{warnings.join("\n")}\n\n---\nBRONNEN (let op: kunnen verouderde info bevatten):\n#{context}"
  end
  
  # Format legislation sources for response
  # Includes exdecs and modification counts for frontend display
  def format_legislation_sources(articles)
    articles.map do |article|
      numac = article[:numac]
      source = {
        numac: numac,
        law_title: article[:law_title],
        article_title: article[:article_title],
        url: "/#{@language}/#{numac}",
        language: article[:language_id] == 1 ? 'NL' : 'FR',
        relevance: article[:similarity].round(3)
      }
      source[:abolished] = true if article[:is_abolished]
      
      # Add exdecs and modification counts
      begin
        exdec_count = Exdec.where(content_numac: numac, language_id: @language_id).count
        source[:exdec_count] = exdec_count if exdec_count > 0
        
        updating_laws = UpdatedLaw
          .joins("LEFT JOIN legislation ON updated_laws.update_numac = legislation.numac AND legislation.language_id = #{@language_id}")
          .where(content_numac: numac, language_id: @language_id)
        
        update_count = updating_laws.count
        source[:modification_count] = update_count if update_count > 0
        
        # Check for abolition laws
        abolition_laws = updating_laws.where("legislation.title LIKE '%ophef%' OR legislation.title LIKE '%afschaf%' OR legislation.title LIKE '%intrekk%'")
        source[:has_abolitions] = true if abolition_laws.any?
      rescue => e
        Rails.logger.debug("Error in format_legislation_sources: #{e.message}")
      end
      
      source
    end
  end
  
  # Search jurisprudence only - ZERO HALLUCINATION
  # Uses external embeddings database for similarity search
  def search_jurisprudence(question)
    question_embedding = generate_embedding(question)
    
    # Find similar cases from external embeddings DB
    similar_cases = find_similar_jurisprudence(question_embedding, limit: 5)
    
    return no_answer_response if similar_cases.empty?
    
    context = build_jurisprudence_context_from_db(similar_cases)
    answer = query_llm(question, context, source_type: :jurisprudence)
    suggestions = generate_follow_up_suggestions(question)
    
    {
      answer: answer,
      sources: format_jurisprudence_sources_from_db(similar_cases),
      suggestions: suggestions,
      language: @language
    }
  end
  
  # Minimum similarity threshold for jurisprudence to be considered relevant
  # 0.40 allows general questions to get case mentions, 0.55 was too strict
  JURISPRUDENCE_SIMILARITY_THRESHOLD = 0.40
  
  # Find similar jurisprudence cases using external embeddings DB
  # Uses random sampling for broad court coverage with fast response
  def find_similar_jurisprudence(question_embedding, limit: 5)
    source_db = jurisprudence_source_db
    
    # Try FAISS service first (fast path) - request more to filter by threshold
    top_cases = find_similar_jurisprudence_faiss(question_embedding, limit * 2)
    
    # Fallback to direct DB search if FAISS unavailable
    if top_cases.nil?
      Rails.logger.warn("FAISS service unavailable, falling back to direct DB search")
      top_cases = find_similar_jurisprudence_direct(question_embedding, limit * 2)
    end
    
    # Filter by similarity threshold and limit
    top_cases = top_cases.select { |_, sim| sim >= JURISPRUDENCE_SIMILARITY_THRESHOLD }.first(limit)
    Rails.logger.info("Jurisprudence: #{top_cases.length} cases above threshold #{JURISPRUDENCE_SIMILARITY_THRESHOLD}")
    
    # Fetch case details
    top_cases.map do |case_id, similarity|
      case_data = source_db.execute(
        "SELECT id, case_number, court, decision_date, summary, full_text, url, language_id FROM cases WHERE id = ?",
        [case_id]
      ).first
      
      next unless case_data
      
      {
        id: case_data[0],
        case_number: case_data[1],
        court: case_data[2],
        decision_date: case_data[3],
        summary: case_data[4],
        full_text: case_data[5],
        url: case_data[6],
        language_id: case_data[7],
        similarity: similarity
      }
    end.compact
  end
  
  # Call FAISS service for fast similarity search
  def find_similar_jurisprudence_faiss(question_embedding, limit)
    require 'net/http'
    require 'json'
    
    faiss_url = ENV.fetch('FAISS_SERVICE_URL', 'http://127.0.0.1:8765')
    uri = URI("#{faiss_url}/search")
    
    request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
    request.body = { embedding: question_embedding, limit: limit }.to_json
    
    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 2, read_timeout: 5) do |http|
      http.request(request)
    end
    
    if response.is_a?(Net::HTTPSuccess)
      data = JSON.parse(response.body)
      Rails.logger.info("FAISS search completed in #{data['search_time_ms'].round(1)}ms")
      
      # Convert to [case_id, similarity] format
      data['results'].map { |r| [r['case_id'], r['similarity']] }
    else
      Rails.logger.error("FAISS service error: #{response.code} #{response.message}")
      nil
    end
  rescue StandardError => e
    Rails.logger.debug("FAISS service unavailable: #{e.message}")
    nil
  end
  
  # Direct database search (fallback when FAISS unavailable)
  def find_similar_jurisprudence_direct(question_embedding, limit)
    emb_db = jurisprudence_embeddings_db
    
    q_vec = question_embedding
    q_magnitude = Math.sqrt(q_vec.sum { |x| x * x })
    
    top_matches = []
    min_similarity = -1.0
    
    total = emb_db.get_first_value("SELECT COUNT(*) FROM jurisprudence_embeddings WHERE case_id IN (SELECT case_id FROM valid_case_ids)").to_i
    Rails.logger.info("Direct DB search: scanning ALL #{total} embeddings...")
    
    emb_db.execute("SELECT e.case_id, e.embedding FROM jurisprudence_embeddings e INNER JOIN valid_case_ids v ON e.case_id = v.case_id") do |row|
      case_id = row[0]
      embedding_blob = row[1]
      
      stored_vec = embedding_blob.unpack('e*')
      
      dot = 0.0
      stored_mag_sq = 0.0
      q_vec.each_with_index do |v, i|
        dot += v * stored_vec[i]
        stored_mag_sq += stored_vec[i] * stored_vec[i]
      end
      stored_magnitude = Math.sqrt(stored_mag_sq)
      
      similarity = (q_magnitude > 0 && stored_magnitude > 0) ? dot / (q_magnitude * stored_magnitude) : 0.0
      
      if top_matches.size < limit
        top_matches << [case_id, similarity]
        min_similarity = top_matches.min_by { |_, s| s }[1] if top_matches.size == limit
      elsif similarity > min_similarity
        top_matches.delete(top_matches.min_by { |_, s| s })
        top_matches << [case_id, similarity]
        min_similarity = top_matches.min_by { |_, s| s }[1]
      end
    end
    
    top_matches.sort_by { |_, sim| -sim }
  end
  
  # Connect to external jurisprudence embeddings DB
  def jurisprudence_embeddings_db
    @juris_emb_db ||= SQLite3::Database.new(JURISPRUDENCE_EMBEDDINGS_DB)
  end
  
  # Connect to external jurisprudence source DB
  def jurisprudence_source_db
    @juris_source_db ||= SQLite3::Database.new(JURISPRUDENCE_SOURCE_DB)
  end
  
  # Connect to external legislation embeddings DB
  def legislation_embeddings_db
    @leg_emb_db ||= SQLite3::Database.new(LEGISLATION_EMBEDDINGS_DB)
  end
  
  # Connect to external article embeddings DB
  def article_embeddings_db
    @article_emb_db ||= SQLite3::Database.new(ARTICLE_EMBEDDINGS_DB)
  end
  
  # Connect to parliamentary documents DB (embeddings + source in same DB)
  def parliamentary_db
    @parliamentary_db ||= begin
      # Check staging path first, fall back to production
      staging_path = '/var/www/wetwijzer-staging/current/storage/parliamentary.sqlite3'
      prod_path = '/var/www/wetwijzer/current/storage/parliamentary.sqlite3'
      db_path = ENV['PARLIAMENTARY_DB'] || (File.size?(staging_path).to_i > 0 ? staging_path : prod_path)
      Rails.logger.info("[Parliamentary DB] Connecting to: #{db_path}")
      db = SQLite3::Database.new(db_path)
      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").flatten
      Rails.logger.info("[Parliamentary DB] Tables found: #{tables.join(', ')}")
      db
    end
  end
  
  # Search parliamentary preparation documents (voorbereidende werken)
  # Returns memorie van toelichting, amendments, committee reports, etc.
  def search_parliamentary(question)
    question_embedding = generate_embedding(question)
    similar_docs = find_similar_parliamentary(question_embedding, limit: 5)
    
    return no_answer_response if similar_docs.empty?
    
    context = build_parliamentary_context(similar_docs)
    answer = query_llm(question, context, source_type: :parliamentary)
    suggestions = generate_follow_up_suggestions(question)
    
    {
      answer: answer,
      sources: format_parliamentary_sources(similar_docs),
      suggestions: suggestions,
      language: @language
    }
  end
  
  # Find similar parliamentary documents using FAISS (fast) with SQLite fallback
  def find_similar_parliamentary(question_embedding, limit: 5)
    # Try FAISS first (fast, uses large embeddings)
    faiss_results = search_parliamentary_faiss(question_embedding, limit: limit)
    return faiss_results if faiss_results.any?
    
    # Fallback to SQLite brute-force (slow, uses small embeddings)
    Rails.logger.info("[Parliamentary] FAISS unavailable, falling back to SQLite search")
    search_parliamentary_sqlite(question_embedding, limit: limit)
  end
  
  # Search parliamentary via FAISS service (port 8769)
  def search_parliamentary_faiss(question_embedding, limit: 5)
    require 'net/http'
    require 'json'
    
    uri = URI("#{FAISS_PARLIAMENTARY_URL}/search")
    request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
    request.body = { embedding: question_embedding, limit: limit }.to_json
    
    response = Net::HTTP.start(uri.hostname, uri.port, read_timeout: 10) do |http|
      http.request(request)
    end
    
    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.warn("[Parliamentary FAISS] HTTP error: #{response.code}")
      return []
    end
    
    result = JSON.parse(response.body)
    faiss_results = result['results'] || []
    return [] if faiss_results.empty?
    
    # Look up document details from SQLite
    db = parliamentary_db
    docs = []
    
    faiss_results.each do |fr|
      doc_id = fr['document_id']
      similarity = fr['similarity']
      
      row = db.get_first_row(
        "SELECT parliament, dossier_number, document_number, title, content, url FROM documents WHERE id = ?",
        [doc_id]
      )
      next unless row
      
      docs << {
        document_id: doc_id,
        parliament: row[0],
        dossier: row[1],
        document_number: row[2],
        title: row[3],
        content: row[4],
        url: row[5],
        similarity: similarity
      }
    end
    
    docs
  rescue StandardError => e
    Rails.logger.warn("[Parliamentary FAISS] Error: #{e.message}")
    []
  end
  
  # Fallback: SQLite brute-force search (uses small embeddings - 1536 dims)
  def search_parliamentary_sqlite(question_embedding, limit: 5)
    db = parliamentary_db
    
    q_vec = question_embedding
    q_magnitude = Math.sqrt(q_vec.sum { |x| x * x })
    
    top_matches = []
    min_similarity = -1.0
    
    # Sample for performance (124K chunks is a lot)
    sample_size = [EMBEDDING_SAMPLE_SIZE, 50_000].min
    
    db.execute("SELECT de.document_id, de.chunk_text, de.embedding, d.parliament, d.dossier_number, d.document_number, d.title, d.content, d.url
                FROM document_embeddings de
                JOIN documents d ON de.document_id = d.id
                WHERE de.chunk_index = 0
                ORDER BY RANDOM() LIMIT ?", [sample_size]) do |row|
      doc_id, chunk_text, embedding_blob, parliament, dossier, doc_num, title, content, url = row
      
      next unless embedding_blob
      stored_vec = embedding_blob.unpack('e*')
      # Handle dimension mismatch (small=1536, large=3072)
      next if stored_vec.length != q_vec.length && stored_vec.length != 1536
      
      # If dimensions don't match, skip (query is 3072, stored is 1536)
      if stored_vec.length != q_vec.length
        Rails.logger.debug("[Parliamentary] Dimension mismatch: query=#{q_vec.length}, stored=#{stored_vec.length}")
        next
      end
      
      dot = 0.0
      stored_mag_sq = 0.0
      q_vec.each_with_index do |v, i|
        dot += v * stored_vec[i]
        stored_mag_sq += stored_vec[i] * stored_vec[i]
      end
      stored_magnitude = Math.sqrt(stored_mag_sq)
      
      similarity = (q_magnitude > 0 && stored_magnitude > 0) ? dot / (q_magnitude * stored_magnitude) : 0.0
      
      if top_matches.size < limit
        top_matches << {
          document_id: doc_id,
          parliament: parliament,
          dossier: dossier,
          document_number: doc_num,
          title: title,
          content: content || chunk_text,
          url: url,
          similarity: similarity
        }
        min_similarity = top_matches.min_by { |m| m[:similarity] }[:similarity] if top_matches.size == limit
      elsif similarity > min_similarity
        top_matches.delete(top_matches.min_by { |m| m[:similarity] })
        top_matches << {
          document_id: doc_id,
          parliament: parliament,
          dossier: dossier,
          document_number: doc_num,
          title: title,
          content: content || chunk_text,
          url: url,
          similarity: similarity
        }
        min_similarity = top_matches.min_by { |m| m[:similarity] }[:similarity]
      end
    end
    
    top_matches.sort_by { |m| -m[:similarity] }
  end
  
  # Build context from parliamentary documents
  def build_parliamentary_context(docs)
    parts = []
    parl_label = @language == 'fr' ? 'TRAVAUX PRÉPARATOIRES' : 'PARLEMENTAIRE VOORBEREIDING'
    
    docs.each_with_index do |doc, index|
      parliament_name = case doc[:parliament]
        when 'kamer' then 'Kamer van Volksvertegenwoordigers'
        when 'senaat' then 'Senaat'
        when 'vlaams' then 'Vlaams Parlement'
        when 'brussels' then 'Brussels Parlement'
        when 'waals' then 'Waals Parlement'
        else doc[:parliament]&.capitalize
      end
      
      text = doc[:content].to_s[0..6000]
      parts << "[Bron #{index + 1} - #{parl_label}]\nParlement: #{parliament_name}\nDossier: #{doc[:dossier]}/#{doc[:document_number]}\nTitel: #{doc[:title]}\n\n#{text}"
    end
    
    parts.join("\n\n---\n\n")
  end
  
  # Format parliamentary sources for response
  def format_parliamentary_sources(docs)
    docs.map do |doc|
      parliament_abbr = case doc[:parliament]
        when 'kamer' then 'Kamer'
        when 'senaat' then 'Senaat'
        when 'vlaams' then 'Vlaams'
        when 'brussels' then 'Brussels'
        when 'waals' then 'Waals'
        else doc[:parliament]&.capitalize
      end
      
      {
        type: 'parliamentary',
        parliament: parliament_abbr,
        dossier: "#{doc[:dossier]}/#{doc[:document_number]}",
        title: doc[:title],
        url: doc[:url],
        similarity: doc[:similarity]&.round(3)
      }
    end
  end
  
  # Search regional legislation (Vlaamse Codex, Wallex, Brussels Parliament)
  # These are Flemish, Walloon, and Brussels regional laws not in the federal DB
  def search_regional_legislation(question_embedding, limit: 5)
    require 'net/http'
    require 'json'
    
    uri = URI("#{FAISS_REGIONAL_URL}/search")
    request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
    request.body = { embedding: question_embedding, limit: limit }.to_json
    
    response = Net::HTTP.start(uri.hostname, uri.port, read_timeout: 10, open_timeout: 5) do |http|
      http.request(request)
    end
    
    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.warn("[Regional FAISS] HTTP error: #{response.code}")
      return []
    end
    
    result = JSON.parse(response.body)
    faiss_results = result['results'] || []
    return [] if faiss_results.empty?
    
    # Convert to standard format
    faiss_results.map do |fr|
      {
        source: fr['source'],
        title: fr['title'],
        similarity: fr['similarity'],
        metadata: fr['metadata']
      }
    end
  rescue StandardError => e
    Rails.logger.warn("[Regional FAISS] Error: #{e.message}")
    []
  end
  
  # Build context from regional legislation results
  def build_regional_context(docs)
    return '' if docs.empty?
    
    parts = []
    label = @language == 'fr' ? 'LÉGISLATION RÉGIONALE' : 'REGIONALE WETGEVING'
    
    docs.each_with_index do |doc, index|
      source_name = case doc[:source]
        when 'vlaamse_codex' then 'Vlaamse Codex'
        when 'wallex' then 'Wallex (Wallonië)'
        when 'brussels' then 'Brussels Parlement'
        else doc[:source]
      end
      
      meta = doc[:metadata] || {}
      article_info = meta['article_number'] ? "Artikel #{meta['article_number']}" : ''
      
      parts << "[Bron #{index + 1} - #{label}]\nBron: #{source_name}\nTitel: #{doc[:title]}\n#{article_info}"
    end
    
    parts.join("\n\n")
  end
  
  # Format regional sources for response
  def format_regional_sources(docs)
    docs.map do |doc|
      source_abbr = case doc[:source]
        when 'vlaamse_codex' then 'Vlaams'
        when 'wallex' then 'Waals'
        when 'brussels' then 'Brussels'
        else doc[:source]
      end
      
      {
        type: 'regional',
        region: source_abbr,
        title: doc[:title],
        similarity: doc[:similarity]&.round(3)
      }
    end
  end
  
  # Connect to FisconetPlus tax legislation DB
  def fisconet_db
    @fisconet_db ||= SQLite3::Database.new(FISCONET_DB)
  rescue SQLite3::CantOpenException
    Rails.logger.warn("FisconetPlus DB not available at #{FISCONET_DB}")
    nil
  end
  
  # Search FisconetPlus tax articles via FAISS (WIB 92, BTW, etc.)
  def search_fisconet(question_embedding, limit: 5)
    require 'net/http'
    require 'json'
    
    # Query FAISS service for similar article IDs
    uri = URI("#{FAISS_FISCONET_URL}/search")
    request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
    request.body = { embedding: question_embedding, limit: limit }.to_json
    
    response = Net::HTTP.start(uri.hostname, uri.port, read_timeout: 10) do |http|
      http.request(request)
    end
    
    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.error("[Fisconet FAISS] HTTP error: #{response.code}")
      return []
    end
    
    result = JSON.parse(response.body)
    faiss_results = result['results'] || []
    return [] if faiss_results.empty?
    
    # Look up article details from SQLite
    db = fisconet_db
    return [] unless db
    
    article_ids = faiss_results.map { |r| r['article_id'] }
    similarity_map = faiss_results.to_h { |r| [r['article_id'], r['similarity']] }
    
    placeholders = article_ids.map { '?' }.join(',')
    rows = db.execute(
      "SELECT a.id, a.article_number, a.text_nl, a.text_fr, a.section_path,
              l.title_nl, l.title_fr, l.document_type, l.fisconet_id
       FROM tax_articles a
       JOIN tax_legislation l ON a.legislation_id = l.id
       WHERE a.id IN (#{placeholders})", article_ids
    )
    
    # Select text based on language preference
    is_french = @language == 'fr'
    
    top_matches = rows.map do |row|
      article_id, art_num, text_nl, text_fr, section_path, title_nl, title_fr, doc_type, fisconet_id = row
      # Use French text if available and user prefers French, otherwise fall back to Dutch
      text = is_french ? (text_fr.presence || text_nl) : (text_nl.presence || text_fr)
      title = is_french ? (title_fr.presence || title_nl) : (title_nl.presence || title_fr)
      {
        article_id: article_id,
        article_number: art_num,
        text: text.to_s[0..3000],
        section_path: section_path,
        legislation_title: title,
        document_type: doc_type,
        fisconet_id: fisconet_id,
        similarity: similarity_map[article_id] || 0.0
      }
    end
    
    top_matches.sort_by { |m| -m[:similarity] }
  rescue => e
    Rails.logger.error("[Fisconet] FAISS search failed: #{e.message}")
    []
  end
  
  # Build context from fisconet tax articles
  def build_fisconet_context(articles)
    parts = []
    label = @language == 'fr' ? 'FISCALITÉ' : 'FISCALITEIT'
    
    articles.each_with_index do |art, index|
      section = art[:section_path].present? ? " (#{art[:section_path]})" : ""
      parts << "[Bron #{index + 1} - #{label}]\n#{art[:document_type]} - #{art[:legislation_title]}\nArtikel #{art[:article_number]}#{section}\n\n#{art[:text]}"
    end
    
    parts.join("\n\n---\n\n")
  end
  
  # Format fisconet sources for response
  # Links to WetWijzer laws page for WIB 92 articles (same as Justel)
  def format_fisconet_sources(articles)
    articles.map do |art|
      {
        type: 'tax',
        document_type: art[:document_type],
        article_number: art[:article_number],
        title: art[:legislation_title],
        section: art[:section_path],
        numac: "fisconet_#{art[:article_id]}",
        url: "/laws/fisconet_#{art[:article_id]}",
        relevance: art[:similarity]&.round(3)
      }
    end
  end
  
  # Search legislation, jurisprudence, parliamentary works, and tax legislation
  # This is now the DEFAULT - gives best coverage for all questions
  # Uses parallel execution to minimize response time
  def search_both(question)
    Rails.logger.info("[Search] Searching ALL sources (legislation + jurisprudence + parliamentary + tax) for: #{question}")
    
    question_embedding = generate_embedding(question)
    
    # Execute searches in parallel for speed
    leg_articles = nil
    jur_cases = nil
    parl_docs = nil
    tax_articles = nil
    
    threads = []
    
    # Thread 1: Search legislation
    threads << Thread.new do
      begin
        leg_articles = find_similar_legislation(question_embedding, limit: 2, question: question)
        Rails.logger.info("[Search] Legislation search found #{leg_articles.length} articles")
      rescue => e
        Rails.logger.error("[Search] Legislation search failed: #{e.message}")
        leg_articles = []
      end
    end
    
    # Thread 2: Search jurisprudence
    threads << Thread.new do
      begin
        jur_cases = find_similar_jurisprudence(question_embedding, limit: 2)
        Rails.logger.info("[Search] Jurisprudence search found #{jur_cases.length} cases")
      rescue => e
        Rails.logger.error("[Search] Jurisprudence search failed: #{e.message}")
        jur_cases = []
      end
    end
    
    # Thread 3: Search parliamentary works
    threads << Thread.new do
      begin
        parl_docs = find_similar_parliamentary(question_embedding, limit: 2)
        Rails.logger.info("[Search] Parliamentary search found #{parl_docs.length} documents")
      rescue => e
        Rails.logger.error("[Search] Parliamentary search failed: #{e.message}")
        parl_docs = []
      end
    end
    
    # Thread 4: Search FisconetPlus tax legislation (WIB 92, etc.)
    threads << Thread.new do
      begin
        tax_articles = search_fisconet(question_embedding, limit: 2)
        Rails.logger.info("[Search] FisconetPlus search found #{tax_articles.length} tax articles")
      rescue => e
        Rails.logger.error("[Search] FisconetPlus search failed: #{e.message}")
        tax_articles = []
      end
    end
    
    # Wait for all searches to complete (max 30s each)
    threads.each { |t| t.join(30) }
    
    # Ensure we have results (fallback to empty arrays if threads timed out)
    leg_articles ||= []
    jur_cases ||= []
    parl_docs ||= []
    tax_articles ||= []
    
    return no_answer_response if leg_articles.empty? && jur_cases.empty? && parl_docs.empty? && tax_articles.empty?
    
    # Build combined context
    context = build_combined_context_from_db(leg_articles, jur_cases, parl_docs, tax_articles)
    answer = query_llm(question, context, source_type: :all)
    suggestions = generate_follow_up_suggestions(question)
    
    {
      answer: answer,
      sources: format_legislation_sources(leg_articles) + format_jurisprudence_sources_from_db(jur_cases) + format_parliamentary_sources(parl_docs) + format_fisconet_sources(tax_articles),
      suggestions: suggestions,
      language: @language
    }
  end
  
  # Build combined context from legislation, jurisprudence, parliamentary works, tax legislation, and regional legislation
  def build_combined_context_from_db(articles, cases, parl_docs = [], tax_articles = [], regional_docs = [])
    parts = []
    law_label = @language == 'fr' ? 'LOI' : 'WET'
    juris_label = @language == 'fr' ? 'JURISPRUDENCE' : 'RECHTSPRAAK'
    tax_label = @language == 'fr' ? 'FISCALITÉ' : 'FISCALITEIT'
    parl_label = @language == 'fr' ? 'TRAVAUX PRÉPARATOIRES' : 'PARLEMENTAIRE VOORBEREIDING'
    regional_label = @language == 'fr' ? 'LÉGISLATION RÉGIONALE' : 'REGIONALE WETGEVING'
    
    articles.each_with_index do |article, index|
      lang_label = article[:language_id] == 1 ? 'NL' : 'FR'
      text = article[:article_text].to_s[0..4000]
      parts << "[Bron #{index + 1} - #{law_label} (#{lang_label})]\nNUMAC: #{article[:numac]}\nWet: #{article[:law_title]}\n#{article[:article_title]}\n#{text}"
    end
    
    cases.each_with_index do |c, index|
      lang_label = c[:language_id] == 1 ? 'NL' : 'FR'
      text = c[:full_text].to_s[0..4000]
      parts << "[Bron #{articles.size + index + 1} - #{juris_label} (#{lang_label})]\nECLI: #{c[:case_number]}\nHof: #{c[:court]}\nDatum: #{c[:decision_date]}\n#{text}"
    end
    
    parl_docs.each_with_index do |doc, index|
      parliament_name = case doc[:parliament]
        when 'kamer' then 'Kamer'
        when 'senaat' then 'Senaat'
        else doc[:parliament]&.capitalize
      end
      text = doc[:content].to_s[0..4000]
      parts << "[Bron #{articles.size + cases.size + index + 1} - #{parl_label}]\nParlement: #{parliament_name}\nDossier: #{doc[:dossier]}/#{doc[:document_number]}\n#{text}"
    end
    
    tax_articles.each_with_index do |art, index|
      section = art[:section_path].present? ? " (#{art[:section_path]})" : ""
      text = art[:text].to_s[0..4000]
      parts << "[Bron #{articles.size + cases.size + parl_docs.size + index + 1} - #{tax_label}]\n#{art[:document_type]} - #{art[:legislation_title]}\nArtikel #{art[:article_number]}#{section}\n\n#{text}"
    end
    
    # Regional legislation (Vlaamse Codex, Wallex, Brussels)
    regional_docs.each_with_index do |doc, index|
      source_name = case doc[:source]
        when 'vlaamse_codex' then 'Vlaamse Codex'
        when 'wallex' then 'Wallex (Wallonië)'
        when 'brussels' then 'Brussels Parlement'
        else doc[:source]
      end
      meta = doc[:metadata] || {}
      article_info = meta['article_number'] ? "Artikel #{meta['article_number']}" : ''
      parts << "[Bron #{articles.size + cases.size + parl_docs.size + tax_articles.size + index + 1} - #{regional_label}]\nBron: #{source_name}\nTitel: #{doc[:title]}\n#{article_info}"
    end
    
    parts.join("\n\n---\n\n")
  end
  
  # Generate embedding for text using Azure OpenAI (EU data residency)
  # Uses direct HTTP call for proper Azure deployment path
  # Includes retry logic with exponential backoff for rate limits (429)
  def generate_embedding(text)
    max_retries = 3
    base_delay = 2
    
    max_retries.times do |attempt|
      begin
        return Timeout.timeout(15) do
          generate_embedding_internal(text)
        end
      rescue => e
        if e.message.include?('429') && attempt < max_retries - 1
          delay = base_delay * (2 ** attempt) + rand(0.5..1.5)
          Rails.logger.warn("Azure embedding rate limit hit, retry #{attempt + 1}/#{max_retries} after #{delay.round(1)}s")
          sleep(delay)
        else
          raise e
        end
      end
    end
  rescue Timeout::Error
    Rails.logger.error("Embedding generation timeout for text: #{text[0..100]}")
    raise "Embedding generation timeout"
  end
  
  def generate_embedding_internal(text)
    endpoint = ENV['AZURE_OPENAI_ENDPOINT'].to_s.chomp('/')
    api_key = ENV['AZURE_OPENAI_KEY']
    api_version = ENV.fetch('AZURE_OPENAI_API_VERSION', '2024-02-15-preview')
    
    uri = URI("#{endpoint}/openai/deployments/#{EMBEDDING_MODEL}/embeddings?api-version=#{api_version}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['api-key'] = api_key
    request.body = { input: text, dimensions: EMBEDDING_DIMENSIONS }.to_json
    
    response = http.request(request)
    
    unless response.code == '200'
      raise "Azure OpenAI error #{response.code}: #{response.body}"
    end
    
    result = JSON.parse(response.body)
    result.dig('data', 0, 'embedding')
  end
  
  # Generate embeddings for all articles (used in rake task)
  def self.generate_all_embeddings(batch_size: 100, language_id: nil)
    service_nl = new(language: 'nl')
    service_fr = new(language: 'fr')
    
    scope = Article.where(embedding: nil)
    scope = scope.where(language_id: language_id) if language_id
    
    total = scope.count
    processed = 0
    
    puts "Generating embeddings for #{total} articles..."
    
    scope.find_in_batches(batch_size: batch_size) do |articles|
      articles.each do |article|
        service = article.language_id == 2 ? service_fr : service_nl
        text = build_article_text(article)
        
        embedding = service.generate_embedding(text)
        
        article.update_columns(
          embedding: embedding,
          embedding_generated_at: Time.current,
          embedding_model: EMBEDDING_MODEL
        )
        
        processed += 1
        print "\rProgress: #{processed}/#{total} (#{(processed.to_f / total * 100).round(1)}%)"
      rescue StandardError => e
        Rails.logger.error("Failed to generate embedding for article #{article.id}: #{e.message}")
      end
      
      # Rate limiting: OpenAI allows 3000 requests/min, sleep to be safe
      sleep 0.5
    end
    
    puts "\nDone! Generated #{processed} embeddings."
  end
  
  private
  
  # Find articles most similar to the question embedding
  # CROSS-LINGUAL: Searches both NL and FR legislation
  def find_relevant_articles(embedding)
    # Fetch laws with embeddings from database (prioritize recent laws)
    # SEARCH BOTH LANGUAGES: Belgian laws exist in both NL and FR
    all_laws = Legislation
      .select('legislation.*, contents.*')
      .joins('LEFT JOIN contents ON legislation.numac = contents.legislation_numac AND legislation.language_id = contents.language_id')
      .where.not(embedding: nil)
      .order('legislation.date DESC')
      .limit(100) # Get 100 recent laws (both languages) for similarity calculation
    
    # Calculate cosine similarity in Ruby (SQLite doesn't have vector operations)
    laws_with_similarity = all_laws.map do |law|
      law_embedding = JSON.parse(law.embedding)
      similarity = cosine_similarity(embedding, law_embedding)
      law.define_singleton_method(:distance) { 1 - similarity }
      law.define_singleton_method(:similarity) { similarity }
      law
    end
    
    # Sort by similarity - prioritize user's language but include other if highly relevant
    sorted = laws_with_similarity.sort_by(&:distance)
    top_law_matches = sorted.take(15)
    sorted = articles_with_similarity.sort_by(&:distance)
    user_lang = sorted.select { |a| a.language_id == @language_id }.first(4)
    other_lang = sorted.reject { |a| a.language_id == @language_id }.first(1)
    
    # Return top matches: mostly user's language + 1 from other language if relevant
    (user_lang + other_lang).sort_by(&:distance).first(MAX_CONTEXT_ARTICLES)
  end
  
  # Calculate cosine similarity between two vectors
  def cosine_similarity(vec1, vec2)
    return 0.0 if vec1.empty? || vec2.empty? || vec1.length != vec2.length
    
    dot_product = vec1.zip(vec2).sum { |a, b| a * b }
    magnitude1 = Math.sqrt(vec1.sum { |a| a**2 })
    magnitude2 = Math.sqrt(vec2.sum { |a| a**2 })
    
    return 0.0 if magnitude1.zero? || magnitude2.zero?
    
    dot_product / (magnitude1 * magnitude2)
  end
  
  # Build context string from articles
  def build_context(articles)
    articles.map.with_index do |article, index|
      <<~CONTEXT
        [Bron #{index + 1}]
        Wet: #{article.law_title}
        NUMAC: #{article.numac}
        #{article.article_title}: #{article.article_text}
      CONTEXT
    end.join("\n---\n")
  end
  
  # Build searchable text from article for embedding
  def self.build_article_text(article)
    law = article.content&.legislation
    return "#{article.article_title}: #{article.article_text}" unless law
    
    text = "Wet: #{law.title}\n"
    text += "NUMAC: #{law.numac}\n"
    text += "Datum: #{law.date}\n" if law.date
    
    # Parliamentary work links
    if law.chamber.present? && law.chamber != "N/A"
      text += "Kamer documenten: #{law.chamber}\n"
    end
    if law.senate.present? && law.senate != "N/A"
      text += "Senaat documenten: #{law.senate}\n"
    end
    
    # Additional metadata from Justel
    text += "Justel: #{law.justel}\n" if law.justel.present? && law.justel != "N/A"
    text += "Belgisch Staatsblad: #{law.mon}\n" if law.mon.present? && law.mon != "N/A"
    
    # Article content
    text += "\n#{article.article_title}: #{article.article_text}"
    
    text
  end
  
  # Build jurisprudence context from external DB results
  def build_jurisprudence_context_from_db(cases)
    cases.map.with_index do |c, index|
      lang_label = c[:language_id] == 1 ? 'NL' : 'FR'
      source_label = @language == 'fr' ? 'JURISPRUDENCE' : 'RECHTSPRAAK'
      
      # Use summary if available, otherwise truncate full_text
      text = c[:summary].present? ? c[:summary] : c[:full_text].to_s[0, 2000]
      
      <<~CONTEXT
        [Bron #{index + 1} - #{source_label} (#{lang_label})]
        ECLI: #{c[:case_number]}
        Hof: #{c[:court]}
        Datum: #{c[:decision_date]}
        
        #{text}
      CONTEXT
    end.join("\n---\n")
  end
  
  # Build jurisprudence context (legacy - for CaseChunk model)
  def build_jurisprudence_context(chunks)
    chunks.map.with_index do |chunk, index|
      c = chunk.case
      lang_label = c.language_id == 1 ? 'NL' : 'FR'
      source_label = @language == 'fr' ? 'JURISPRUDENCE' : 'RECHTSPRAAK'
      
      <<~CONTEXT
        [Bron #{index + 1} - #{source_label} (#{lang_label})]
        ECLI: #{c.case_number}
        Hof: #{c.court}
        Datum: #{c.decision_date}
        
        #{chunk.chunk_text}
      CONTEXT
    end.join("\n---\n")
  end
  
  # Build combined context (with language labels for cross-lingual search)
  def build_combined_context(articles, chunks)
    parts = []
    law_label = @language == 'fr' ? 'LOI' : 'WET'
    juris_label = @language == 'fr' ? 'JURISPRUDENCE' : 'RECHTSPRAAK'
    
    articles.each_with_index do |article, index|
      lang_label = article.language_id == 1 ? 'NL' : 'FR'
      parts << <<~CONTEXT
        [Bron #{index + 1} - #{law_label} (#{lang_label})]
        Wet: #{article.law_title}
        NUMAC: #{article.numac}
        #{article.article_title}: #{article.article_text}
      CONTEXT
    end
    
    chunks.each_with_index do |chunk, index|
      c = chunk.case
      lang_label = c.language_id == 1 ? 'NL' : 'FR'
      parts << <<~CONTEXT
        [Bron #{articles.size + index + 1} - #{juris_label} (#{lang_label})]
        ECLI: #{c.case_number}
        Hof: #{c.court}
        Datum: #{c.decision_date}
        
        #{chunk.chunk_text}
      CONTEXT
    end
    
    parts.join("\n---\n")
  end
  
  # Court name mapping for ECLI codes
  COURT_NAME_MAP = {
    'CASS' => 'Hof van Cassatie',
    'RVSCE' => 'Raad van State',
    'RvS' => 'Raad van State',
    'GHCC' => 'Grondwettelijk Hof',
    'CABRL' => 'Hof van Beroep Brussel',
    'CALIE' => 'Hof van Beroep Luik',
    'CAMON' => 'Hof van Beroep Bergen',
    'AHANT' => 'Hof van Beroep Antwerpen',
    'AHGNT' => 'Hof van Beroep Gent',
    'CTBRL' => 'Arbeidsrechtbank Brussel',
    'HBANT' => 'Handelsrechtbank Antwerpen',
    'HBGNT' => 'Handelsrechtbank Gent',
    'HBBRL' => 'Handelsrechtbank Brussel',
    'COHSAV' => 'Commissie voor de Bescherming van de Persoonlijke Levenssfeer'
  }.freeze
  
  # Format jurisprudence sources from external DB results
  def format_jurisprudence_sources_from_db(cases)
    cases.map do |c|
      # Build WetWijzer URL using case ID, fallback to JuPortal URL if available
      wetwijzer_url = c[:id] ? "https://wetwijzer.be/jurisprudence/#{c[:id]}" : nil
      juportal_url = c[:url].presence
      
      # Extract court code from ECLI and map to readable name
      court_name = c[:court]
      if court_name.nil? || court_name == 'Unknown'
        ecli = c[:case_number].to_s
        if ecli.start_with?('ECLI:BE:')
          court_code = ecli.split(':')[2]
          court_name = COURT_NAME_MAP[court_code] || court_code
        elsif ecli.start_with?('RvS-')
          court_name = 'Raad van State'
        end
      end
      
      {
        type: 'RECHTSPRAAK',
        ecli: c[:case_number],
        court: court_name,
        date: c[:decision_date],
        url: wetwijzer_url || juportal_url,
        language: c[:language_id] == 1 ? 'NL' : 'FR',
        relevance: c[:similarity].round(2)
      }
    end
  end
  
  # Format jurisprudence sources (legacy - for CaseChunk model)
  def format_jurisprudence_sources(chunks)
    chunks.map do |chunk|
      {
        type: 'RECHTSPRAAK',
        ecli: chunk.case.case_number,
        court: chunk.case.court,
        date: chunk.case.decision_date,
        url: chunk.case.url,
        language: chunk.case.language_id == 1 ? 'NL' : 'FR',
        relevance: (1 - chunk.distance).round(2)
      }
    end
  end
  
  # Query Azure OpenAI with context and question - ZERO HALLUCINATION MODE
  # Data processed in EU (West Europe region) for GDPR compliance
  def query_llm(question, context, source_type: :legislation)
    system_prompt = build_system_prompt(source_type)
    
    # Detect language and explicitly tell LLM (don't let it guess)
    detected_lang = detect_question_language(question)
    lang_instruction = case detected_lang
                       when :en then "Respond in ENGLISH"
                       when :fr then "Répondez en FRANÇAIS"
                       when :de then "Antworten Sie auf DEUTSCH"
                       else "Antwoord in het NEDERLANDS"
                       end
    
    messages = [
      { role: 'system', content: system_prompt },
      { role: 'user', content: "Sources:\n#{context}\n\n#{lang_instruction}\n\nQuestion: #{question}" }
    ]
    
    answer = azure_chat_completion(messages, temperature: 0.1, max_tokens: 2000)
    
    # Return Azure response as-is (trust the LLM)
    return answer if answer && !answer.empty?
    
    # Only error if Azure completely failed to respond
    Rails.logger.error("Azure returned nil/empty response")
    @language == 'fr' ? 
      "Désolé, je n'ai pas pu générer une réponse. Veuillez réessayer." :
      "Sorry, ik kon geen antwoord genereren. Probeer het opnieuw."
  end
  
  # Direct HTTP call to Azure OpenAI chat completions
  def azure_chat_completion(messages, temperature: 0.7, max_tokens: 2000)
    endpoint = ENV['AZURE_OPENAI_ENDPOINT'].to_s.chomp('/')
    api_key = ENV['AZURE_OPENAI_KEY']
    api_version = ENV.fetch('AZURE_OPENAI_API_VERSION', '2024-02-15-preview')
    
    model = @model_override || CHAT_MODEL
    uri = URI("#{endpoint}/openai/deployments/#{model}/chat/completions?api-version=#{api_version}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    http.open_timeout = 10
    
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['api-key'] = api_key
    request.body = {
      messages: messages,
      temperature: temperature,
      max_tokens: max_tokens
    }.to_json
    
    response = http.request(request)
    
    unless response.code == '200'
      raise "Azure OpenAI chat error #{response.code}: #{response.body}"
    end
    
    result = JSON.parse(response.body)
    result.dig('choices', 0, 'message', 'content')
  end
  
  # Build strict anti-hallucination system prompt
  def build_system_prompt(source_type)
    # Language-neutral base rules in English to allow multilingual responses
    base_rules = <<~RULES
      You are a helpful legal assistant for Belgian law.
      
      CRITICAL LANGUAGE RULE: ALWAYS respond in the SAME LANGUAGE as the user's question.
      - If user asks in German → respond in German
      - If user asks in Spanish → respond in Spanish  
      - If user asks in any other language → respond in that language
      - The source texts are in Dutch/French, but you translate your answer to match the user's input language.
      
      ⚠️ ABSOLUTE RULE - NO HALLUCINATION ⚠️
      You must ONLY state facts that are EXPLICITLY written in the provided sources.
      - If a number/date/amount is NOT in the sources, say "niet vermeld in de beschikbare bronnen"
      - NEVER use your training knowledge to fill in gaps - ONLY use the provided sources
      - If sources don't answer the question, admit it clearly
      - Wrong example: "De termijn is 14 dagen" (when 14 is not in sources) ❌
      - Correct example: "De termijn is niet vermeld in de beschikbare bronnen" ✓
      
      ANSWER STRUCTURE (use headers in USER'S LANGUAGE only):
      For Dutch: 1. **ALGEMEEN** 2. **KERNFEITEN** 3. **UITZONDERINGEN** 4. **BRONNEN**
      For French: 1. **GÉNÉRAL** 2. **FAITS CLÉS** 3. **EXCEPTIONS** 4. **SOURCES**
      For English: 1. **GENERAL** 2. **KEY FACTS** 3. **EXCEPTIONS** 4. **SOURCES**
      For German: 1. **ALLGEMEIN** 2. **KERNFAKTEN** 3. **AUSNAHMEN** 4. **QUELLEN**
      
      1. **ALGEMEEN/GÉNÉRAL/GENERAL**: First give the most common/standard answer (2-3 sentences)
      2. **KERNFEITEN/FAITS CLÉS/KEY FACTS**: Extract specific numbers from sources:
         - Bedragen: €X (exact amounts)
         - Percentages: X%
         - Termijnen: X dagen/maanden/jaren
         - Drempels: minimum/maximum waarden
      3. **UITZONDERINGEN/EXCEPTIONS**: Special cases (if any)
      4. **BRONNEN/SOURCES** (MANDATORY - QUOTE the actual text):
         - Don't just cite article numbers - QUOTE the relevant passage
         - Format: "Artikel X van de [Law Title] states: '[exact quote]'" + link
         - Citation format: "Artikel X van de [Wet/Wetboek]" (NOT "Wet Art.X")
         - Example: "Artikel 30 van de Arbeidsovereenkomstenwet bepaalt: 'De werknemer heeft recht op vijftien dagen...' [Artikel 30 van de Arbeidsovereenkomstenwet](https://wetwijzer.be/laws/1978070303#art-30)"
         - Quote the SPECIFIC sentence that answers the question
         - If source text is too long, quote the key phrase with "..."
         - ALWAYS include the link after the quote
      
      CRITICAL - KEY FACTS EXTRACTION:
      - SCAN all provided source text for ANY numbers, amounts, percentages, deadlines
      - If the source contains "€500" or "21%" or "30 dagen" - YOU MUST include it
      - Format as bullet points under KERNFEITEN/FAITS CLÉS
      - If no numeric data in sources, write: "Geen specifieke bedragen vermeld in de bronnen."
      
      IMPORTANT - FINE AMOUNTS (BOETES/AMENDES):
      - Belgian fines are multiplied by OPDECIEMEN (currently 8x)
      - If source shows "€100 tot €500", explain: "€100-500 (x8 opdeciemen = €800-4000 effectief)"
      - Always mention the multiplier when citing fine amounts from criminal/traffic law
      
      REGIONAL DIFFERENCES (GEWESTEN/RÉGIONS) - ALWAYS INCLUDE:
      Belgium has 3 regions with DIFFERENT laws. For these topics, ALWAYS mention all 3:
      
      TOPICS THAT VARY BY REGION (always mention Vlaanderen/Wallonië/Brussel):
      - Registratierechten (2% VL, 12.5% WAL/BRU)
      - Kinderbijslag/Groeipakket (different amounts per region)
      - Huurwetgeving (Vlaams Woninghuurdecreet vs Code Wallon vs Brussels)
      - Stedenbouwkundige vergunningen
      - Erfbelasting/Successierechten
      - Onroerende voorheffing
      - Premies (renovatie, energie, wonen)
      - Onderwijs (Vlaamse Gemeenschap vs Fédération Wallonie-Bruxelles)
      - Milieu/omgevingsvergunningen
      
      FORMAT: Always add a "REGIONALE VERSCHILLEN" section:
      "⚠️ **REGIONALE VERSCHILLEN:**
      - **Vlaanderen:** [specifics]
      - **Wallonië:** [specifics]  
      - **Brussel:** [specifics]"
      
      If topic is FEDERAL (arbeidsrecht, strafrecht, BTW, sociale zekerheid) → no regional section needed
      
      COMMON MISCONCEPTIONS - CORRECT THESE:
      - "Rijbewijs met punten" → Belgium does NOT have a point-based license system (unlike France/Germany)
      - "Minimumpensioen" → There is no single "minimum pension" - depends on career, household, etc.
      - "Automatisch orgaandonor" → Belgium has opt-OUT system, everyone is donor unless registered refusal
      - "Proefperiode" → Abolished in 2014 for most contracts (only for students/interim)
      - "VOV" → Means "voorwaardelijke opschorting van de veroordeling" (suspended sentence in criminal law), NOT "VZW" (non-profit)
      - "Canada Dry regeling" → Colloquial for pseudo-brugpensioen/SWT supplements paid by employer to bridge to retirement, NOT about beverages
      - "BV minimumkapitaal" → Since 2019 WVV reform, BV (besloten vennootschap) has NO minimum capital requirement. Only NV requires €61,500
      - If user asks about something Belgium doesn't have, CLEARLY STATE this fact first
      
      DATE AWARENESS - AVOID OUTDATED INFO:
      - Current year is 2026 - do NOT cite COVID-19 temporary measures (2020-2022) as current law
      - If source mentions "tijdelijk", "corona", "COVID" → warn it may be outdated
      - Prefer citing permanent legislation over temporary crisis measures
      
      CURRENT KEY AMOUNTS (use these if sources are unclear):
      - Groeipakket Vlaanderen: €173.20/month base (not sociale toeslagen which are income-based)
      - Groeipakket Wallonië: €181.61/month base
      - Groeipakket Brussel: €168.50/month base
      - Registratierechten Vlaanderen: 2% for main residence (since Jan 2024)
      - Registratierechten Wallonië: 12.5% (reduced rates available)
      - Registratierechten Brussel: 12.5% (abattement €200k possible)
      - BTW standaard: 21%, verlaagd: 6%, super verlaagd: 0%
      - Opzegtermijn: see table in Arbeidsovereenkomstenwet Art. 37/2
      
      ⚠️ CRITICAL - ABOLISHED/CHANGED RULES (OVERRIDE SOURCE DATA IF OUTDATED):
      
      BV vs NV KAPITAAL (2019 WVV REFORM):
      - BV (besloten vennootschap) has NO minimum capital since May 1, 2019
      - Article 7:2 WVV (€61,500) applies ONLY to NV (naamloze vennootschap)
      - If user asks "BV minimumkapitaal" → Answer: "Sinds de WVV-hervorming van 2019 is er GEEN minimumkapitaal meer vereist voor een BV. Wel moet het aanvangsvermogen toereikend zijn (art. 5:3 WVV)."
      - NEVER apply art. 7:2 (NV capital) to questions about BV!
      
      These rules changed in 2014 - if sources show old rules, CORRECT THEM:
      
      - PROEFPERIODE: ❌ AFGESCHAFT sinds 1 januari 2014 (Wet Eenheidsstatuut 2013)
        → Was: 1-12 maanden afhankelijk van contract type
        → Nu: BESTAAT NIET MEER voor standaard arbeidsovereenkomsten
        → BELANGRIJKE UITZONDERING: uitzendarbeid heeft nog 3 dagen proefperiode
        → MAAR: Als gebruiker vraagt "wat is de proefperiode?" zonder context van uitzendarbeid:
          START ANTWOORD MET: "De proefperiode voor gewone arbeidsovereenkomsten is AFGESCHAFT sinds 1 januari 2014."
          DAARNA pas vermelden: "Enkel voor uitzendarbeid/interim bestaat nog een proefperiode van 3 dagen."
        → NOOIT de 3-dagen regel van uitzendarbeid presenteren als de algemene regel!
        
      - CARENSDAG: ❌ AFGESCHAFT sinds 1 januari 2014
        → Was: eerste ziektedag onbetaald
        → Nu: eerste ziektedag WEL betaald (gewaarborgd loon vanaf dag 1)
        → Als gebruiker vraagt over carensdag → ZEGGEN DAT HET AFGESCHAFT IS
        
      - OPZEGTERMIJN: Bedienden/arbeiders onderscheid OPGEHEVEN sinds 1 jan 2014
        → Nu: één uniform stelsel voor alle werknemers
      
      INHERITANCE/TESTAMENT QUESTIONS:
      - New inheritance law since 2018 (Wet van 31 juli 2017)
      - Burgerlijk Wetboek Book 4 (NUMAC 1804032156) is the primary source
      - Reserve (voorbehouden deel) changed: children get 1/2 regardless of number
      - Cite the NEW law, not old Civil Code provisions
      
      QUALITY RULES:
      1. Use ONLY sources that DIRECTLY relate to the question topic
      2. If a source title doesn't match the question topic, DO NOT cite it
      3. Prefer citing the main law (Wetboek, Code) over implementing decrees (KB, MB)
      4. ALWAYS extract concrete numbers - this is critical for legal accuracy
      5. Keep answers focused - don't include tangential information
      
      SOURCE HANDLING:
      - ABOLISHED LAWS [OPGEHEVEN/ABROGÉ]: WARN this law is no longer valid
      - IMPLEMENTING DECREES [HEEFT X UITVOERINGSBESLUITEN]: Mention KB/MB exist with details
      - AMENDMENTS [GEWIJZIGD DOOR X WETTEN]: This is the consolidated version
      - PARLIAMENTARY CONTEXT: Use to explain background/intent if helpful
      
      CRITICAL ANTI-HALLUCINATION RULES:
      - NEVER invent numbers, dates, amounts, or percentages not explicitly in the sources
      - If sources don't contain the answer, say: "De beschikbare bronnen bevatten geen directe informatie over dit onderwerp."
      - Do NOT guess or estimate - only cite what is EXPLICITLY written in sources
      - If you're unsure, say "niet vermeld in de bronnen" rather than making something up
      - Check source TITLES - if they don't match the question topic, DO NOT USE THEM
      - Example: A question about "Raad van State" should NOT cite sources about "luchtvervoer" or "maritieme grenzen"
      
      KEY FACTS EXTRACTION (always include when available in sources):
      - Amounts: €X, bedragen, montants
      - Percentages: X%, tarieven, taux
      - Deadlines: X dagen/maanden, délais
      - Thresholds: minimaal/maximaal, minimum/maximum
      - Dates: effectieve datum, date d'effet
      
      MANDATORY DISCLAIMER (always add at end, in user's language):
      - NL: "Dit is geen officieel juridisch advies. Verifieer altijd bij officiële bronnen."
      - FR: "Ceci n'est pas un avis juridique officiel. Vérifiez toujours auprès des sources officielles."
      - EN: "This is not official legal advice. Always verify with official sources."
      - DE: "Dies ist keine offizielle Rechtsberatung. Überprüfen Sie immer bei offiziellen Quellen."
      
      RESPONSE LENGTH:
      - Provide COMPREHENSIVE, DETAILED explanations - not brief summaries
      - Each section (ALGEMEEN, KERNFEITEN, UITZONDERINGEN) should have 3-5 sentences minimum
      - Quote extensively from the sources - use their exact wording
      - Explain what the source text means in plain language
      - ALL detail must come FROM THE SOURCES - never add information not in sources
      - If sources are brief, your answer should be brief too - don't pad with invented content
      
      Response format:
      [Comprehensive, detailed answer with thorough explanations - IN USER'S LANGUAGE]
      
      Bronnen: 
      - [Korte Titel Art.X](https://wetwijzer.be/laws/NUMAC#art-X) - link MUST include #art-X anchor (with dash) to specific article
      
      [DISCLAIMER - mandatory]
    RULES
    
    source_specific = case source_type
    when :jurisprudence
      "\n\nYou are citing JURISPRUDENCE (court decisions / rechtspraak).\n" \
      "MANDATORY: You MUST cite at least one court case in your answer with its ECLI number.\n" \
      "Format case citations as: [ECLI number](URL from sources) - do NOT invent URLs\n" \
      "Use the URL provided in the source data, NOT https://wetwijzer.be/laws/...\n" \
      "Example: [ECLI:BE:CASS:2006:ARR.20061120.3](https://wetwijzer.be/jurisprudence/609898)\n" \
      "NEVER format jurisprudence links as /laws/NUMAC - that format is ONLY for legislation.\n" \
      "In BRONNEN section: quote a key passage from the court decision and link to it."
    when :parliamentary
      "\n\nYou are citing PARLIAMENTARY PREPARATION DOCUMENTS (voorbereidende werken / travaux préparatoires).\n" \
      "These include: memorie van toelichting, committee reports, amendments, advice from Council of State.\n" \
      "Format sources as: [Parliament] Dossier X/Y - Title\n" \
      "Explain the INTENT behind the law based on these preparatory works."
    when :all
      "\n\nIMPORTANT - DISTINGUISH SOURCES:\n" \
      "- [LAW]: Legal articles and official regulations\n" \
      "- [CASE LAW]: Court decisions and judicial interpretations\n" \
      "- [PARLIAMENTARY]: Preparatory works explaining legislative intent\n\n" \
      "REQUIRED:\n" \
      "1. ALWAYS indicate category: [LAW], [CASE LAW], or [PARLIAMENTARY]\n" \
      "2. Explain if info comes from written law, judicial interpretation, or legislative intent\n" \
      "3. **MANDATORY**: If RECHTSPRAAK sources are provided, you MUST mention at least one court case in your KERNFEITEN section\n" \
      "4. Format: 'Volgens een arrest van [Hof] (ECLI:...) geldt dat...'\n" \
      "5. In BRONNEN section, include the ECLI with link: [ECLI:BE:...](URL from source)"
    else  # legislation
      "\nCite ONLY legal articles. Format: Article X, NUMAC..."
    end
    
    disclaimer = "\n\nMandatory disclaimer: This is not official legal advice. Always verify with official sources."
    
    language_instruction = "\n\n**CRITICAL: Your response MUST be in the SAME LANGUAGE as the user's question. If they ask in English, respond in English. If Dutch, respond in Dutch. If French, respond in French.**"
    
    base_rules + source_specific + disclaimer + language_instruction
  end
  
  # Old query_llm method kept for compatibility
  def query_llm_old(question, context)
    system_prompt = if @language == 'fr'
      <<~PROMPT
        Vous êtes un assistant juridique belge expert. Répondez UNIQUEMENT en vous basant sur les articles de loi fournis.
        
        Règles strictes:
        1. Citez toujours les articles spécifiques (ex: "Selon l'article 3...")
        2. Si l'information n'est pas dans les sources, dites "Je ne trouve pas cette information dans les sources disponibles"
        3. Soyez précis et concis
        4. Utilisez un langage clair, pas de jargon juridique excessif
        5. Ajoutez toujours: "Ceci n'est pas un conseil juridique officiel. Les modèles d'IA peuvent faire des erreurs - vérifiez toujours les informations importantes auprès de sources officielles ou consultez un professionnel juridique."
      PROMPT
    else
      <<~PROMPT
        Je bent een Belgische juridische assistent. Beantwoord vragen ENKEL op basis van de verstrekte wetsartikelen.
        
        Strikte regels:
        1. Citeer altijd specifieke artikelen (bijv. "Volgens artikel 3...")
        2. Als de informatie niet in de bronnen staat, zeg dan "Ik vind deze informatie niet in de beschikbare bronnen"
        3. Wees nauwkeurig en bondig
        4. Gebruik duidelijke taal, geen overdreven juridisch jargon
        5. Voeg altijd toe: "Dit is geen officieel juridisch advies. AI-modellen kunnen fouten maken - verifieer belangrijke informatie altijd bij officiële bronnen of raadpleeg een juridisch professional."
      PROMPT
    end
    
    messages = [
      { role: 'system', content: system_prompt },
      { role: 'user', content: "Bronnen:\n#{context}\n\nVraag: #{question}" }
    ]
    
    azure_chat_completion(messages, temperature: 0.3, max_tokens: 500)
  end
  
  # Format sources for response (with language info)
  def format_sources(articles)
    articles.map do |article|
      {
        numac: article.numac,
        law_title: article.law_title,
        article_title: article.article_title,
        url: "/#{@language}/#{article.numac}##{article.article_title.parameterize}",
        language: article.language_id == 1 ? 'NL' : 'FR',
        relevance: (1 - article.distance).round(2) # Convert distance to similarity score
      }
    end
  end
  
  # Response when no relevant articles found
  def no_answer_response
    message = if @language == 'fr'
      "Je n'ai pas trouvé d'informations pertinentes dans la législation belge pour répondre à cette question."
    else
      "Ik heb geen relevante informatie gevonden in de Belgische wetgeving om deze vraag te beantwoorden."
    end
    
    {
      answer: message,
      sources: [],
      language: @language
    }
  end
end
