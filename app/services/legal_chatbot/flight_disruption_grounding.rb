# frozen_string_literal: true

require 'digest'

module LegalChatbot
  # Measured misstatements in short flight-disruption answers (the 2026-10-17
  # depth run), not a verifier of Regulation 261/2004 answers: it decides
  # neither scope nor any remedy. Each check needs the exact admitted article
  # it is about; a changed, excerpted or other-edition unit disables that
  # check until it is reviewed again. No answer text is logged, and passing
  # does not verify an answer.
  class FlightDisruptionGrounding
    VERSION = 4
    CONDITION_CODES = %w[flight_return_route_reversed flight_completed_trip_unconditional_refund
                         flight_unsupported_paragraph flight_care_without_trigger flight_unsupported_examples
                         flight_defence_without_reasonable_measures flight_unconditional_scope
                         flight_third_country_exception_disjunctive flight_technical_problem_without_control
                         flight_amounts_without_edition_caveat].freeze
    REVIEW_AFTER = Date.new(2027, 1, 17)
    MAX_ANSWER_CHARS = 200_000
    MAX_QUESTION_CHARS = 12_000
    CELEX = '02004R0261-20050217'
    # Complete article bodies of the only edition production serves for this
    # CELEX (Dutch, live corpus), read read-only on 2026-10-17.
    BODY_SIGNATURES = {
      %w[3 nl] => '19dee4c44cb2ac8b0a6a513a5d51b495d5c9d59f577e429b99757d57e354c7a9',
      %w[5 nl] => 'c649fae51112db56c65482a557757682c45bda6f708cf0ed7689f2057fc21a3f',
      %w[6 nl] => '89f31c63726c6d00db0b1abacf075966aca7e1141e7fbe883ee4a941909afa02',
      %w[7 nl] => '15ec7a40c5202f1d2bb2fb4e5a25bac7ee7a6fb501590706fb7e1f9e926c4c7a',
      %w[8 nl] => 'bcc2ce6f045233fef41873e77e3e13cc96c48ad76d247a4cb32c65726aefafeb'
    }.transform_keys(&:freeze).freeze

    # "retourtickets Brussel-Tokio": the outbound order of a return booking.
    ROUTE_PAIR_PATTERN = %r{(?i:\b(?:retour\p{L}*|heen[-\s]en[-\s]terug\p{L}*|return\s+(?:tickets?|flights?|trip)|aller[-\s]retour|Hin-\s+und\s+Rück\p{L}*))\s+(?:\p{L}+\s+){0,3}?(\p{Lu}[\p{L}'’]+)\s*[-–—/>→]\s*(\p{Lu}[\p{L}'’]+)}u
    RETURN_LEG_PATTERN = /\b(?:terugreis|terugvlucht\p{L}*|terugweg|terugkeer|return\s+(?:flight|journey|leg|trip)s?|way\s+back|vols?\s+(?:de\s+)?retour|trajet\s+(?:de\s+)?retour|au\s+retour|Rückflug\p{L}*|Rückreise|Rückweg)\b/iu
    COMPLETED_TRIP_PATTERN = /\b(?:kwam|kwamen)\b[^.!?\n]{0,80}\baan\b|\baangekom\p{L}*|\bbereikte?\b[^.!?\n]{0,40}\b(?:eind)?bestemming|\bgeland\b|\barriv\p{L}*|\blanded\b|\breached\b[^.!?\n]{0,40}\bdestination|\bangekommen\b|\b(?:kam|kamen)\b[^.!?\n]{0,80}\ban\b|\berreicht\p{L}*\b[^.!?\n]{0,40}\bZiel/iu
    CANCELLATION_PATTERN = /\b(?:geannuleerd\p{L}*|annuler\p{L}*|annulé\p{L}*|annulation\p{L}*|annulering\p{L}*|cancel\p{L}*|annulliert\p{L}*|Annullierung\p{L}*|gestrichen|ausgefallen)\b/iu
    # "de vlucht was niet geannuleerd" states that there was no cancellation.
    NEGATED_CANCELLATION_PATTERN = /\b(?:niet|geen|not|no|never|nooit|pas|jamais|aucune?|nicht|kein\p{L}*)\s+(?:\p{L}+\s+){0,2}?(?:geannuleerd\p{L}*|annuler\p{L}*|annulé\p{L}*|annulation\p{L}*|annulering\p{L}*|cancel\p{L}*|annulliert\p{L}*|Annullierung\p{L}*|gestrichen|ausgefallen)\b/iu
    # "U heeft ook recht op", "u heeft de keuze tussen": an adverb or the
    # choice wording does not make the promise conditional (2026-10-17 run).
    ENTITLEMENT_ADVERB = '(?:ook|dan|daarnaast|bovendien|eveneens|wel|nog|altijd|also|then|always|still|aussi|alors|toujours|auch|dann|immer|zudem)'
    DIRECT_ENTITLEMENT_PATTERN = /\b(?:u|je|jij)\s+(?:(?:hebt|heeft|kunt|kan|mag|zult|zal|krijgt|#{ENTITLEMENT_ADVERB})\s+){0,3}(?:recht\s+op|(?:de\s+)?keuze\p{L}*|kiezen|aanspraak|krijgt|krijgen)\b|\b(?:heeft|hebt|krijgt|kunt)\s+(?:u|je)\s+(?:\p{L}+\s+){0,2}?(?:recht|keuze\p{L}*|kiezen|aanspraak|terugbetaling)\b|\byou\s+(?:(?:have|has|can|may|will|are|#{ENTITLEMENT_ADVERB})\s+){0,3}(?:a\s+right|the\s+right|the\s+choice|a\s+choice|choose|entitled|claim|get|receive)\b|\bvous\s+(?:(?:avez|pouvez|aurez|êtes|#{ENTITLEMENT_ADVERB})\s+){0,3}(?:le\s+)?(?:droit|choix|choisir|obtenir|recevoir|réclamer)\b|\bSie\s+(?:(?:haben|können|werden|sind|#{ENTITLEMENT_ADVERB})\s+){0,3}(?:Anspruch|die\s+Wahl|wählen|verlangen|erhalten|berechtigt)\b|\bhaben\s+Sie\s+(?:\p{L}+\s+){0,2}?(?:Anspruch|die\s+Wahl)\b/iu
    REMEDY_PATTERN = /\b(?:terugbetal\p{L}*|terugbetaald|refund\p{L}*|reimburs\p{L}*|rembours\p{L}*|Erstattung\p{L}*|erstatt\p{L}*|herrout\p{L}*|omboek\p{L}*|rerout\p{L}*|réachemin\p{L}*|Ersatzbeförderung|anderweitig\p{L}*\s+Beförderung)\b|\balternatie\p{L}*\s+(?:reisplan|vervoer|vlucht)\b|\balternative\s+(?:flight|routing|transport)\b|\bretourvlucht\s+naar\s+(?:het\s+)?(?:eerste\s+)?vertrekpunt\b/iu
    # A local qualifier that ties the remedy to what actually triggers it.
    LOCAL_CONDITION_PATTERN = /\b(?:geannuleerd\p{L}*|annuler\p{L}*|annulé\p{L}*|annulation\p{L}*|annulering\p{L}*|cancel\p{L}*|annulliert\p{L}*|Annullierung\p{L}*)\b|\b(?:vijf|five|cinq|fünf|5)\s*(?:uur|hours?|heures?|h|Stunden)\b|\b(?:verwijst|verwezen|verwijzing|refers?|referred|renvoi\p{L}*|renvoie|verweist|verwiesen)\b|\bonder\s+(?:de\s+)?voorwaarden\b|\bunder\s+the\s+conditions\b|\bsous\s+(?:les\s+)?conditions?\b|\bunter\s+den\s+(?:Voraussetzungen|Bedingungen)\b|\b(?:mits|provided\s+that|voorwaardelijk\p{L}*|conditional\p{L}*|conditionnel\p{L}*|bedingt)\b/iu
    DENIAL_PATTERN = /\b(?:geen|niet|not|no|pas|kein\p{L}*|nicht)\s+(?:\p{L}+\s+){0,2}?(?:automatisch\p{L}*|onvoorwaardelijk\p{L}*|recht|right|entitled|droit|Anspruch|automatic\p{L}*|unconditional\p{L}*|automatique\p{L}*|inconditionnel\p{L}*|unbedingt\p{L}*)\b|\b(?:bewijst|proves?|prouve|beweist)\s+(?:\p{L}+\s+){0,3}?(?:geen|niet|no|not|pas|kein\p{L}*|nicht)\b/iu
    # Care (meals, hotel, transport) promised without the departure-delay and
    # distance thresholds that trigger it, or as an Article 8 right (final
    # depth run 3, Snel: "bijstand ... als de vertraging langer duurt dan
    # verwacht ([art. 8], [art. 9])").
    CARE_PATTERN = /\b(?:maaltijd\p{L}*|verfrissing\p{L}*|hotel\p{L}*|accommodatie|bijstand|verzorging|meals?|refreshments?|hotel\s+accommodation|care|assistance|repas|rafraîchissements?|hébergement|prise\s+en\s+charge|Mahlzeit\p{L}*|Erfrischung\p{L}*|Hotelunterbringung|Betreuungsleistung\p{L}*|Unterstützungsleistung\p{L}*)\b/iu
    CARE_DUTY_PATTERN = /\b(?:moet|moeten|dient|dienen)\b[^.!?\n]{0,90}\b(?:verlenen|bieden|geven|verstrekken|zorgen|vergoeden)\b|\brecht\s+op\b|\b(?:u|je)\s+krijgt\b|\bmust\s+(?:provide|offer|give|pay)\b|\bentitled\b|\bdroit\s+[àa]\b|\bdoit\s+(?:fournir|offrir|prendre)\b|\bAnspruch\b|\bmuss\b[^.!?\n]{0,60}\b(?:leisten|anbieten|gewähren|bieten)\b/iu
    CARE_TRIGGER_PATTERN = /\b(?:twee|drie|vier|two|three|four|deux|trois|quatre|zwei|drei|vier|[234])\s*(?:uur|uren|hours?|heures?|h|Stunden)\b|\b\d[\d .]*\s*km\b|\b(?:afstand\p{L}*|distance\p{L}*|Entfernung\p{L}*|drempel\p{L}*|thresholds?|seuils?|Schwellen\p{L}*)\b|\b(?:art(?:ikel|icle|\.)?\s*6)\b|\bonder\s+(?:de\s+)?(?:toepasselijke\s+)?voorwaarden\b|\bunder\s+the\s+(?:applicable\s+)?conditions\b|\bsous\s+(?:les\s+)?conditions?\b|\bunter\s+den\s+(?:Voraussetzungen|Bedingungen)\b|\bdaags\s+na\b|\bnext\s+day\b|\blendemain\b|\bam\s+nächsten\s+Tag\b/iu
    EXTRAORDINARY_PATTERN = /\b(?:buitengewone\s+omstandigheden|extraordinary\s+circumstances|circonstances\s+extraordinaires|außergewöhnliche\p{L}*\s+Umständ\p{L}*|omstandigheden\s+waarop)\b/iu
    # Examples a model tends to add from memory; they count only when a
    # supplied source states them.
    EXAMPLE_TERMS = (%w[weersomstandigh storm politiek instabiliteit staking stakingen vogel luchtverkeersleid
                        veiligheidsrisic terroris weather political instability strike bird météo grève oiseau
                        instabilité Streik Wetter Vogel Fluglots politisch] + ['air traffic', 'security risk']).freeze
    # A care promise for a cancellation has its own trigger (Codex review
    # 18:28): the delay thresholds bind only care promised for a delay.
    DELAY_PATTERN = /\b(?:vertraag\p{L}*|vertraging\p{L}*|vertraagd|delay\p{L}*|retard\p{L}*|Verspätung\p{L}*|verspätet\p{L}*)\b/iu
    # A defence is asserted only when the sentence gives it an effect on the
    # claim; "no extraordinary circumstances were shown" invokes nothing.
    DEFENCE_EFFECT_PATTERN = /\b(?:tenzij|weiger\p{L}*|vervalt|vervallen|ontheven|vrijgesteld|niet\s+verplicht|hoeft\s+(?:\p{L}+\s+){0,3}?niet|geen\s+compensatie|unless|refuse\p{L}*|exempt\p{L}*|not\s+(?:required|obliged|liable)|no\s+compensation|sauf\s+si|à\s+moins\s+que|refuser|exonér\p{L}*|n['’]est\s+pas\s+tenu\p{L}*|pas\s+d['’]indemnisation|es\s+sei\s+denn|verweiger\p{L}*|entfällt|nicht\s+verpflichtet|befreit|keine\s+Ausgleichs\p{L}*)\b/iu
    DEFENCE_DENIAL_PATTERN = /\b(?:geen|no|aucune?|keine?)\s+(?:\p{L}+\s+){0,2}?(?:buitengewone|extraordinary|circonstances?|außergewöhnlich\p{L}*)\b|\b(?:niet|not|pas|nicht)\s+(?:(?:\p{L}+\s+){0,2}?)(?:aangetoond|bewezen|vastgesteld|gebleken|established|shown|proven|proved|démontrée?s?|prouvée?s?|établie?s?|nachgewiesen|belegt)\b/iu
    REASONABLE_MEASURES_PATTERN = /\b(?:redelijke\s+maatregel\p{L}*|reasonable\s+measures|mesures\s+raisonnables|zumutbare\p{L}*\s+Maßnahmen|niet\s+(?:hadden|konden|kon)\s+(?:kunnen\s+)?worden\s+voorkomen|niet\s+(?:te\s+)?voorkomen\s+(?:waren|was)|could\s+not\s+have\s+been\s+avoided|n['’]auraient\s+pas\s+pu\s+être\s+évitées|nicht\s+hätten\s+vermieden\s+werden\s+können)\b/iu
    # "Uw situatie valt onder de verordening" as a fact, for a return from a
    # third country, without the supplied exception for benefits received
    # there (final depth run 3, Snel).
    SCOPE_ASSERTION_PATTERN = /\b(?:uw\s+(?:situatie|reis|vlucht|terugreis|terugvlucht|claim)|u)\s+(?:valt|vallen)\s+(?:onder|binnen)\b|\bvalt\s+uw\s+(?:situatie|reis|vlucht|terugreis)\s+(?:onder|binnen)\b|\byour\s+(?:situation|trip|journey|flight|claim)\s+(?:is\s+covered|falls\s+(?:under|within))\b|\bvotre\s+(?:situation|voyage|vol)\s+(?:relève|est\s+couvert\p{L}*|tombe\s+sous)\b|\bIhre\s+(?:Situation|Reise|Flug)\s+(?:fällt\s+unter|ist\s+erfasst)\b/iu
    SCOPE_HEDGE_PATTERN = /\b(?:in\s+beginsel|mogelijk|waarschijnlijk|kan|kunnen|zou|zouden|als|indien|wanneer|op\s+voorwaarde|in\s+principle|may|might|likely|if|provided|si|pourrait|en\s+principe|grundsätzlich|wenn|falls|kann|könnte)\b/iu
    THIRD_COUNTRY_EXCEPTION_PATTERN = /\b(?:derde\s+land|third\s+country|pays\s+tiers|Drittstaat\p{L}*|Drittland\p{L}*)\b[^.!?\n]{0,160}\b(?:ontvangen|voordelen|received|benefits|reçu\p{L}*|avantages|erhalten|Leistungen)\b|\b(?:ontvangen|voordelen|received|benefits|reçu\p{L}*|avantages|erhalten|Leistungen)\b[^.!?\n]{0,160}\b(?:derde\s+land|third\s+country|pays\s+tiers|Drittstaat\p{L}*|Drittland\p{L}*)\b/iu
    LIST_ITEM_PATTERN = /\A(\s*)(?:[-*•+]|\d+[.)])\s+/
    # v5 (Codex 20:14/20:30): Article 3(1)(b) excludes a passenger who
    # received (benefits OR compensation) AND assistance; "compensatie of
    # bijstand" as the exclusion makes either one enough.
    THIRD_COUNTRY_DISJUNCTION_PATTERN = /\b(?:compensatie|voordelen|compensation|benefits|indemnisation|avantages|Ausgleichsleistung\p{L}*|Leistungen)\s+(?:of|or|ou|oder)\s+(?:(?!(?:en|én|and|et|und|compensatie|voordelen|compensation|benefits)\b)\p{L}+\s+){0,2}?(?:bijstand|assistance|Unterst[üu]tzung\p{L}*|Betreuung\p{L}*)\b/iu
    # "Compensatie of bijstand ... volstaat niet om uitgesloten te zijn"
    # denies that either one alone excludes (Codex 20:42).
    DISJUNCTION_DENIAL_PATTERN = /\b(?:volstaat|volstaan|voldoet|voldoen)\s+niet\b|\bniet\s+(?:genoeg|voldoende)\b|\bis\s+niet\s+(?:genoeg|voldoende)\b|\bdoes\s+not\s+suffice\b|\bis\s+not\s+(?:enough|sufficient)\b|\bne\s+suffi(?:t|sent)\s+pas\b|\bgen[üu]g(?:t|en)\s+nicht\b|\breich(?:t|en)\s+nicht\b/iu
    EXCLUSION_RELATION_PATTERN = /\b(?:tenzij|unless|sauf\s+si|[àa]\s+moins\s+que|es\s+sei\s+denn|(?:indien|als|wanneer|if)\s+(?:u|you)\s+(?:al|reeds|already)|geen\s+compensatie|niet\s+van\s+toepassing|valt\s+(?:\p{L}+\s+){0,3}?niet\s+onder|uitgesloten|excluded|does\s+not\s+apply|no\s+compensation|ne\s+s['’]applique\s+pas|exclu\p{L}*|gilt\s+nicht|ausgeschlossen)\b/iu
    THIRD_COUNTRY_CONTEXT_PATTERN = /\b(?:derde\s+land|third\s+country|pays\s+tiers|Drittstaat\p{L}*|Drittland\p{L}*|reeds|already|d[ée]j[àa]|bereits)\b/iu
    # The supplied Sturgeon holding needs both limbs: not inherent in the
    # normal activity AND beyond the carrier's actual control.
    # The reviewed NL operative part of C-402/07, sealed by its complete body
    # (read-only capture 2026-10-17); a changed, excerpted or other unit
    # disables this check (Codex 20:42).
    STURGEON_CELEX = '62007CJ0402'
    STURGEON_BODY_SHA256 = '6c6db4f2868aa51629aa361d81fedfe135d7cdd1da22e7df86ff18a63a275a93'
    # Only an asserted one-limb exception is measured: "tenzij ...",
    # "alleen als ...", "is (wel) een buitengewone omstandigheid als ...".
    TECHNICAL_EXCEPTION_ASSERTION_PATTERN = /\b(?:tenzij|alleen\s+(?:als|indien|wanneer)|slechts\s+(?:als|indien|wanneer)|enkel\s+(?:als|indien|wanneer)|(?:is|zijn|vormt|vormen)\s+(?:wel\s+)?(?:een\s+)?buitengewone\s+omstandighe\p{L}*\s+(?:als|indien|wanneer)|unless|only\s+(?:if|when|where)|is\s+an\s+extraordinary\s+circumstance\s+(?:if|when|where)|sauf\s+si|[àa]\s+moins\s+que|seulement\s+si|es\s+sei\s+denn|nur\s+(?:wenn|dann))\b/iu
    TECHNICAL_DENIAL_PATTERN = /\b(?:niet\s+(?:automatisch|zonder\s+meer|per\s+definitie|noodzakelijk)|not\s+(?:automatically|necessarily|by\s+definition)|pas\s+(?:automatiquement|n[ée]cessairement)|nicht\s+(?:automatisch|ohne\s+Weiteres|notwendigerweise))\b/iu
    TECHNICAL_PROBLEM_PATTERN = /\b(?:technisch\p{L}*\s+(?:probleem|problemen|mankement\p{L}*|defect\p{L}*)|technical\s+(?:problem|defect|fault)s?|probl[èe]mes?\s+techniques?|technische[sn]?\s+(?:Problem\p{L}*|Defekt\p{L}*))\b/iu
    NOT_INHERENT_PATTERN = /\b(?:niet\s+inherent|not\s+inherent|pas\s+inh[ée]rent\p{L}*|nicht\s+(?:\p{L}+\s+){0,3}?(?:innewohn\p{L}*|inh[äa]rent\p{L}*))\b/iu
    # "… en waarover zij geen controle heeft" (v5 Snel draft 1, Codex
    # 2026-10-18) states the control limb as a relative clause.
    ACTUAL_CONTROL_PATTERN = /\b(?:(?:waarover|waarop)\s+(?:zij|ze|hij|de\s+(?:luchtvaart)?maatschappij|de\s+vervoerder)\s+geen\s+(?:enkele\s+)?(?:daadwerkelijke\s+|werkelijke\s+)?(?:controle|invloed|zeggenschap)\b|daadwerkelijke?\s+(?:invloed|controle|zeggenschap)|werkelijke?\s+(?:invloed|controle)|buiten\s+(?:de\s+|haar\s+|zijn\s+)?(?:daadwerkelijke\s+|werkelijke\s+)?(?:controle|macht|invloed)|actual\s+control|beyond\s+(?:its|the\s+carrier['’]s|their)\s+(?:actual\s+)?control|ma[îi]trise\s+effective|tats[äa]chlich\p{L}*\s+(?:Einfluss|Kontrolle|beherrsch\p{L}*))\b/iu
    UNESTABLISHED_FACT_PATTERN = /\b(?:staat\s+niet\s+vast|niet\s+(?:vastgesteld|bekend|duidelijk)|onbekend|ontbreekt|onduidelijk|not\s+(?:established|known|clear)|unknown|n['’]est\s+pas\s+(?:[ée]tabli|connu)|inconnu|nicht\s+(?:festgestellt|bekannt)|unbekannt)\b/iu
    # Article 7 amounts stated as a current entitlement need a meaningful
    # edition/currentness limitation when every supplied edition is
    # uncertified; a generic disclaimer is not one.
    UNCERTIFIED_EDITION = 'SOURCE_EDITION_NOT_CERTIFIED_CURRENT'
    AMOUNT_PATTERN = /(?:€\s*(?:250|400|600)\b|\b(?:250|400|600)\s*(?:EUR|euro|€))/iu
    AMOUNT_ENTITLEMENT_PATTERN = /\b(?:bedraagt|bedragen\s+(?:zijn|is)|compensatiebedrag\p{L}*|recht\s+op|(?:u|je)\s+(?:krijgt|ontvangt)|(?:krijgt|ontvangt)\s+(?:u|je)|entitled|amounts?\s+(?:is|are)|you\s+(?:get|receive)|droit\s+[àa]|s['’][ée]l[èe]ve|montants?\s+(?:est|sont)|Anspruch|betr[äa]gt|Betr[äa]ge)\b/iu
    AMOUNT_DESCRIPTION_PATTERN = /\b(?:noemt|vermeldt|vermelden|de\s+(?:verstrekte|aangeleverde)\s+tekst|states|lists|mentions|the\s+supplied\s+text|mentionne|indique|le\s+texte\s+fourni|nennt|der\s+bereitgestellte\s+Text)\b/iu
    # A limitation needs an edition/currentness term AND an uncertainty in
    # the same sentence; "staat in de editie van 2005" or "is nog van
    # kracht" is not one (Codex 20:42).
    EDITION_TERM_PATTERN = /\b(?:editie\p{L}*|edition\p{L}*|[ée]dition\p{L}*|Fassung|geconsolideerd\p{L}*|consolidat\p{L}*|actuele\s+(?:gelding|stand|tekst|versie)|actualiteit|huidige\s+(?:gelding|versie|tekst|stand)|meest\s+recente\s+(?:toepasselijke\s+)?tekst|current\s+(?:force|version|text|law)|in\s+force|en\s+vigueur|in\s+Kraft|aktuelle\s+(?:Geltung|Fassung))\b/iu
    EDITION_UNCERTAINTY_PATTERN = /\b(?:niet\s+(?:\p{L}+\s+){0,6}?(?:te\s+)?(?:bevestig\p{L}*|verifi[eë]r\p{L}*|vaststell\p{L}*|vast\s+te\s+stellen|gecertificeerd|geverifieerd)|bevestig\p{L}*\s+(?:\p{L}+\s+){0,2}?niet|(?:kan|kunnen)\s+(?:ik|wij|we)?\s*(?:\p{L}+\s+){0,4}?niet\s+(?:\p{L}+\s+){0,2}?(?:bevestigen|verifi[eë]ren)|onzeker\p{L}*|vereist\s+(?:\p{L}+\s+){0,2}?verificatie|moet\s+(?:\p{L}+\s+){0,3}?(?:worden\s+)?(?:geverifieerd|nagegaan|gecontroleerd)|not\s+(?:\p{L}+\s+){0,4}?(?:confirmed|certified|verified)|cannot\s+(?:\p{L}+\s+){0,2}?(?:confirm|verify)|uncertain|pas\s+(?:\p{L}+\s+){0,3}?(?:confirm[ée]e?|certifi[ée]e?|v[ée]rifi[ée]e?)|ne\s+(?:peux|peut|pouvons)\s+pas\s+(?:confirmer|v[ée]rifier)|nicht\s+(?:\p{L}+\s+){0,4}?(?:best[äa]tigt|bestätigen|[üu]berpr[üu]f\p{L}*|zertifiziert)|unsicher)\b/iu
    STEM_LENGTH = 7
    STOPWORDS = %w[
      worden wordt werden kunnen heeft hebben onder tussen binnen tegen zonder indien wanneer omdat alleen andere ander
      bepaalde volgens artikel artikelen verordening bepaling dergelijke waarop daarvan eventueel moeten mogen zullen
      nadat voordat sinds vanaf inzake betreffende welke hetzelfde dezelfde waarin waarbij zoals geval gevallen
      article articles regulation under where which their there these those other shall should would could about after
      before between within without because provided règlement selon entre avant après lorsque quand leurs cette celle
      celui autres autre peuvent doivent toute toutes notamment conformément verordnung gemäß können
      müssen dieser diese dieses welche anderen zwischen innerhalb sofern
    ].to_set.freeze

    class << self
      def topic?(question)
        question.to_s.length <= MAX_QUESTION_CHARS && EuTopicIntent.plan(question.to_s)&.dig(:topic) == :flight_disruption
      end

      def evidence(sources)
        return {} if Date.current > REVIEW_AFTER

        EuSealedUnits.selected(sources, celex: CELEX, signatures: BODY_SIGNATURES)
      end

      def evaluate(answer, question, sources)
        grounded = topic?(question) ? evidence(sources) : {}
        return { applicable: false, missing_conditions: [], version: VERSION } if grounded.empty?

        text = answer.to_s[0, MAX_ANSWER_CHARS]
        missing = []
        missing << 'flight_return_route_reversed' if grounded['3'] && reversed_return?(text, question.to_s)
        if grounded['8'] && grounded['6'] && completed_trip?(question.to_s) && unconditional_refund?(text)
          missing << 'flight_completed_trip_unconditional_refund'
        end
        missing << 'flight_unsupported_paragraph' if EuSealedUnits.unsupported_paragraph?(text, grounded) ||
                                                     misattributed_paragraph?(text, grounded)
        missing << 'flight_care_without_trigger' if grounded['6'] && care_without_trigger?(text)
        missing << 'flight_unsupported_examples' if unsupported_examples?(text, sources)
        missing << 'flight_defence_without_reasonable_measures' if grounded['5'] && defence_without_measures?(text)
        return_leg = question.to_s.match?(RETURN_LEG_PATTERN)
        missing << 'flight_unconditional_scope' if grounded['3'] && return_leg && unconditional_scope?(text)
        missing << 'flight_third_country_exception_disjunctive' if grounded['3'] && disjunctive_exception?(text)
        missing << 'flight_technical_problem_without_control' if sturgeon_supplied?(sources) && technical_without_control?(text)
        missing << 'flight_amounts_without_edition_caveat' if uncertified?(grounded['7']) && amounts_without_caveat?(text)
        { applicable: true, missing_conditions: CONDITION_CODES & missing, version: VERSION }
      end

      def corrective_feedback(missing_conditions, language: 'nl')
        codes = Array(missing_conditions).map(&:to_s) & CONDITION_CODES
        return nil if codes.empty?

        copy = FEEDBACK_COPY.fetch(language.to_s, FEEDBACK_COPY.fetch('nl'))
        "#{codes.map { |code| copy.fetch(code) }.join(' ')} [#{codes.join(', ')}]"
      end

      private

      # Markdown removed, but "*" and "+" bullets kept as list items.
      def plain(text)
        text.to_s.gsub(/```[\s\S]*?```/, '').gsub(/^[ \t]*>.*$/, '').gsub(/^([ \t]*)[*+][ \t]+/, '\\1- ')
            .gsub(EuSealedUnits::LINK_PATTERN, '\\1').gsub(%r{https?://\S+}, '').gsub(/[*_`#]/, '')
      end

      def sentences(text)
        text.split(/(?<=[!?;])\s+|(?<=\.)\s+(?=[[:upper:]])/).map(&:strip).reject(&:empty?)
      end

      # The question booked "A-B" return tickets and describes the return leg;
      # an answer naming that return leg as A-B again has reversed it.
      def reversed_return?(text, question)
        pair = question.match(ROUTE_PAIR_PATTERN)
        return false unless pair && question.match?(RETURN_LEG_PATTERN)

        origin, destination = pair.captures.map { |name| Regexp.escape(name) }
        outbound = %r{\A[^.!?;\n]{0,25}?(?:\b#{origin}\s*[-–—/>→]\s*#{destination}\b|\b(?:van|from|de|von)\s+#{origin}\s+(?:naar|to|à|vers|nach)\s+#{destination}\b)}iu
        plain(text).to_enum(:scan, RETURN_LEG_PATTERN).any? do
          Regexp.last_match.post_match.match?(outbound)
        end
      end

      # The thresholds may stand on the lines just above the promise, in the
      # same paragraph block ("Bij een verwachte vertraging van: - 2 uur ...
      # heeft u recht op: - maaltijden"); a block without them is flagged.
      def care_without_trigger?(text)
        text.to_s.split(/\n[ \t]*\n/).any? do |block|
          next false if plain(block).match?(CARE_TRIGGER_PATTERN)

          claim_units(block).any? do |unit|
            next false if unit.end_with?('?') || unit.match?(DENIAL_PATTERN) || cancellation_care?(unit)

            unit.match?(CARE_PATTERN) && unit.match?(CARE_DUTY_PATTERN)
          end
        end
      end

      def unsupported_examples?(text, sources)
        supplied = Array(sources).filter_map do |source|
          next unless source.is_a?(Hash)

          %i[article_text text full_text content].filter_map { |key| EuSealedUnits.field(source, key) }.join("\n")
        end.join("\n").downcase
        claim_units(text).any? do |unit|
          next false unless unit.match?(EXTRAORDINARY_PATTERN)

          lowered = unit.downcase
          EXAMPLE_TERMS.any? do |term|
            stem = term.downcase
            lowered.match?(/\b#{Regexp.escape(stem)}/) && !supplied.match?(/\b#{Regexp.escape(stem)}/)
          end
        end
      end

      def cancellation_care?(unit)
        unit.match?(CANCELLATION_PATTERN) && !unit.match?(NEGATED_CANCELLATION_PATTERN) && !unit.match?(DELAY_PATTERN)
      end

      def defence_without_measures?(text)
        return false if plain(text).match?(REASONABLE_MEASURES_PATTERN)

        claim_units(text).flat_map { |unit| sentences(unit) }.any? do |sentence|
          sentence.match?(EXTRAORDINARY_PATTERN) && sentence.match?(DEFENCE_EFFECT_PATTERN) &&
            !sentence.match?(DEFENCE_DENIAL_PATTERN)
        end
      end

      def disjunctive_exception?(text)
        claim_units(text).flat_map { |unit| sentences(unit) }.any? do |sentence|
          !sentence.end_with?('?') && sentence.match?(THIRD_COUNTRY_DISJUNCTION_PATTERN) &&
            sentence.match?(EXCLUSION_RELATION_PATTERN) && sentence.match?(THIRD_COUNTRY_CONTEXT_PATTERN) &&
            !sentence.match?(DISJUNCTION_DENIAL_PATTERN)
        end
      end

      def sturgeon_supplied?(sources)
        Array(sources).any? do |source|
          next false unless source.is_a?(Hash) && EuSealedUnits.field(source, :celex).to_s == STURGEON_CELEX
          next false unless EuSealedUnits.field(source, :language).to_s.casecmp?('nl')
          next false if %i[kind source_kind].any? do |key|
            value = EuSealedUnits.field(source, key)
            value.present? && !%w[final jurisprudence].include?(value.to_s)
          end

          body = EuSealedUnits.field(source, :article_text)
          body.is_a?(String) && Digest::SHA256.hexdigest(body) == STURGEON_BODY_SHA256 && EuCorpus.verified_record?(source)
        end
      end

      # An asserted exception that names only the not-inherent limb; the
      # actual-control limb must stand in the same claim unit. A denial
      # ("niet automatisch"), an unestablished fact or a question is not
      # an asserted exception.
      def technical_without_control?(text)
        claim_units(text).any? do |unit|
          next false if unit.match?(ACTUAL_CONTROL_PATTERN) || !unit.match?(TECHNICAL_PROBLEM_PATTERN)

          sentences(unit).any? do |sentence|
            !sentence.end_with?('?') && sentence.match?(NOT_INHERENT_PATTERN) &&
              sentence.match?(TECHNICAL_EXCEPTION_ASSERTION_PATTERN) &&
              !sentence.match?(UNESTABLISHED_FACT_PATTERN) && !sentence.match?(TECHNICAL_DENIAL_PATTERN)
          end
        end
      end

      def uncertified?(source)
        source.is_a?(Hash) && EuSealedUnits.field(source, :correction_status).to_s == UNCERTIFIED_EDITION
      end

      def amounts_without_caveat?(text)
        body = plain(text)
        return false if sentences(body.gsub("\n", ' ')).any? do |sentence|
          sentence.match?(EDITION_TERM_PATTERN) && sentence.match?(EDITION_UNCERTAINTY_PATTERN)
        end

        body.split(/\n[ \t]*\n/).any? do |block|
          block.match?(AMOUNT_PATTERN) && block.match?(AMOUNT_ENTITLEMENT_PATTERN) && !block.match?(AMOUNT_DESCRIPTION_PATTERN)
        end
      end

      def unconditional_scope?(text)
        body = plain(text)
        return false if body.match?(THIRD_COUNTRY_EXCEPTION_PATTERN)

        sentences(body.gsub("\n", ' ')).any? do |sentence|
          sentence.match?(SCOPE_ASSERTION_PATTERN) && !sentence.match?(SCOPE_HEDGE_PATTERN)
        end
      end

      def completed_trip?(question)
        question.match?(COMPLETED_TRIP_PATTERN) && !question.gsub(NEGATED_CANCELLATION_PATTERN, ' ').match?(CANCELLATION_PATTERN)
      end

      def unconditional_refund?(text)
        claim_units(text).any? do |unit|
          next false if unit.end_with?('?') || unit.match?(DENIAL_PATTERN) || unit.match?(LOCAL_CONDITION_PATTERN)

          unit.match?(DIRECT_ENTITLEMENT_PATTERN) && unit.match?(REMEDY_PATTERN)
        end
      end

      # Sentences, with each list item read together with every lead-in line
      # it completes ("U heeft recht op:" + "- Keuze tussen:" + "- volledige
      # terugbetaling ..."). A paragraph lead-in owns the list that follows it,
      # at any indentation and across a blank line; a list-item lead-in owns
      # only its nested items.
      def claim_units(text)
        leads = []
        units = []
        plain(text).split("\n").each do |line|
          next if line.strip.empty?

          item = line.match(LIST_ITEM_PATTERN)
          indent = item ? item[1].length : line[/\A\s*/].length
          content = line.sub(LIST_ITEM_PATTERN, '').strip
          leads.pop while leads.any? && !owns?(leads.last, item, indent)
          units.concat(sentences([*leads.map(&:first), content].join(' ')))
          leads << [content, indent, !item.nil?] if content.end_with?(':')
        end
        units
      end

      def owns?(lead, item, indent)
        _content, lead_indent, lead_item = lead
        item && (indent > lead_indent || (!lead_item && indent >= lead_indent))
      end

      # A paragraph label must point at the paragraph that says it. Flag the
      # reference only when its own sentence or list item clearly describes
      # ANOTHER paragraph of the same article: it shares at least two more
      # words with that paragraph than with the one it names, and no word that
      # only the named paragraph has. Words that merely recur elsewhere in the
      # article ("ongeacht", "tickets") are not enough (2026-10-17 run: a
      # correct Article 3(5) attribution was flagged by a looser rule). Only
      # same-language evidence can be compared.
      def misattributed_paragraph?(text, grounded)
        EuSealedUnits.paragraph_references(text, grounded).any? do |reference|
          paragraphs = EuSealedUnits.paragraphs(EuSealedUnits.field(grounded[reference[:number]], :article_text))
          named = paragraphs[reference[:paragraph]]
          next false unless named

          unit = enclosing_unit(text, reference)
          next false if unit.nil? || unit.scan(EuSealedUnits::LINK_PATTERN).length != 1

          description = stems(plain(unit.sub(EuSealedUnits::LINK_PATTERN, ' ')))
          own = stems(named)
          others = paragraphs.except(reference[:paragraph]).transform_values { |paragraph| stems(paragraph) }
          next false if description.intersect?(own - others.values.reduce(Set.new, :|))

          best = others.values.map { |words| (description & words).size }.max.to_i
          best >= (description & own).size + 2
        end
      end

      # The list item or prose sentence (in the raw answer) holding the link.
      def enclosing_unit(text, reference)
        line_start = text.rindex("\n", [reference[:begin] - 1, 0].max)
        line_start = line_start ? line_start + 1 : 0
        line_end = text.index("\n", reference[:end]) || text.length
        line = text[line_start...line_end]
        return line if line.match?(LIST_ITEM_PATTERN)

        offset = reference[:begin] - line_start
        masked = line.gsub(EuSealedUnits::LINK_PATTERN) { |link| 'x' * link.length }
        starts = [0] + masked.to_enum(:scan, /(?<=[.!?;])\s+(?=\S)/).map { Regexp.last_match.end(0) }
        start = starts.rfind { |position| position <= offset } || 0
        stop = starts.find { |position| position > offset } || line.length
        line[start...stop]
      end

      def stems(text)
        text.to_s.downcase.scan(/\p{L}+/).filter_map do |word|
          word[0, STEM_LENGTH] if word.length >= 5 && !STOPWORDS.include?(word)
        end.to_set
      end
    end

    FEEDBACK_COPY = {
      'nl' => {
        'flight_return_route_reversed' => 'CORRECTIE: u keerde de terugreis om. De terugreis vertrok op de bestemming van de heenreis en eindigde op het oorspronkelijke vertrekpunt; beschrijf de heen- en terugreis elk in hun eigen richting en pas voor een vertrek uit een derde land de daarvoor aangeleverde toepassingsvoorwaarde toe. Herschrijf zonder deze correctie te vermelden.',
        'flight_completed_trip_unconditional_refund' => 'CORRECTIE: beloof bij een voltooide, niet-geannuleerde reis geen terugbetaling of alternatief reisplan zonder voorwaarde. Artikel 8 geldt alleen waar een andere bepaling ernaar verwijst, zoals bij annulering of bij een vertrekvertraging van minstens vijf uur (dan alleen terugbetaling); noem die voorwaarde in dezelfde zin. Herschrijf zonder deze correctie te vermelden.',
        'flight_unsupported_paragraph' => 'CORRECTIE: een verwijzing naar een lid moet wijzen naar het lid dat zelf zegt wat u eraan toeschrijft. Noem een lid alleen als de aangeleverde tekst van dat lid het zegt; anders link het artikel zonder lidnummer. Herschrijf zonder deze correctie te vermelden.',
        'flight_care_without_trigger' => 'CORRECTIE: koppel bijstand (maaltijden, hotel, vervoer) bij vertraging aan de vertrekvertraging en afstandsdrempels van de aangeleverde vertragingsbepaling en de voorwaarden van de bijstandsbepaling (hotel alleen bij een noodzakelijke overnachting); bij annulering is de annulering zelf de aanleiding; de bepaling over terugbetaling of een alternatief reisplan is geen regel over maaltijden of hotel. Herschrijf zonder deze correctie te vermelden.',
        'flight_unsupported_examples' => 'CORRECTIE: noem geen voorbeelden van buitengewone omstandigheden (weer, politieke onrust, stakingen, vogels) die niet in de aangeleverde bronnen staan, en hang ze niet aan een arrest dat ze niet bevat; omschrijf de uitzondering zoals de bron ze omschrijft. Herschrijf zonder deze correctie te vermelden.',
        'flight_defence_without_reasonable_measures' => 'CORRECTIE: vermeld bij de uitzondering van buitengewone omstandigheden de voorwaarde uit de bron: de vertraging kon niet worden voorkomen, ook niet als alle redelijke maatregelen waren getroffen, en de maatschappij moet dat aantonen. Herschrijf zonder deze correctie te vermelden.',
        'flight_unconditional_scope' => 'CORRECTIE: stel niet als vaststaand feit dat de situatie onder de verordening valt. Voor een vertrek uit een derde land noem je de aangeleverde voorwaarden als voorwaarden: een communautaire uitvoerende maatschappij en de uitzondering wanneer in dat derde land al voordelen of compensatie EN bijstand werden ontvangen; noem ontbrekende feiten. Herschrijf zonder deze correctie te vermelden.',
        'flight_third_country_exception_disjunctive' => 'CORRECTIE: de uitzondering voor een vertrek uit een derde land geldt volgens de aangeleverde toepassingsbepaling alleen als de passagier daar bepaalde voordelen of compensatie heeft ontvangen EN bijstand heeft gekregen; schrijf niet dat compensatie of bijstand alleen volstaat. Herschrijf zonder deze correctie te vermelden.',
        'flight_technical_problem_without_control' => 'CORRECTIE: volgens de aangeleverde uitspraak is een technisch probleem alleen een buitengewone omstandigheid als het voortvloeit uit gebeurtenissen die niet inherent zijn aan de normale uitoefening van de activiteit van de maatschappij EN waarop zij geen daadwerkelijke invloed kan uitoefenen; noem beide voorwaarden samen. Herschrijf zonder deze correctie te vermelden.',
        'flight_amounts_without_edition_caveat' => 'CORRECTIE: de aangeleverde editie van de verordening is niet bevestigd als de actuele tekst; vermeld de compensatiebedragen als bedragen van die aangeleverde editie en zeg dat hun actuele gelding niet uit de bronnen kan worden bevestigd. Herschrijf zonder deze correctie te vermelden.'
      },
      'fr' => {
        'flight_return_route_reversed' => 'CORRECTION : vous avez inversé le trajet retour. Le retour partait de la destination de l’aller et se terminait au point de départ initial ; décrivez l’aller et le retour chacun dans son propre sens et, pour un départ d’un pays tiers, appliquez la condition fournie à cet effet. Réécrivez sans mentionner cette correction.',
        'flight_completed_trip_unconditional_refund' => 'CORRECTION : pour un voyage achevé et non annulé, ne promettez pas de remboursement ni de réacheminement sans condition. L’article 8 ne s’applique que lorsqu’une autre disposition y renvoie, comme en cas d’annulation ou d’un retard au départ d’au moins cinq heures (alors seulement le remboursement) ; indiquez cette condition dans la même phrase. Réécrivez sans mentionner cette correction.',
        'flight_unsupported_paragraph' => 'CORRECTION : une référence à un paragraphe doit viser le paragraphe qui dit lui-même ce que vous lui attribuez. Ne citez un paragraphe que si son texte fourni le dit ; sinon liez l’article sans numéro de paragraphe. Réécrivez sans mentionner cette correction.',
        'flight_care_without_trigger' => 'CORRECTION : en cas de retard, rattachez la prise en charge (repas, hôtel, transport) aux seuils de retard au départ et de distance de la disposition fournie sur le retard et aux conditions de la disposition sur la prise en charge (hôtel seulement si une nuit est nécessaire) ; en cas d’annulation, l’annulation est elle-même le déclencheur ; la disposition sur le remboursement ou le réacheminement ne règle ni repas ni hôtel. Réécrivez sans mentionner cette correction.',
        'flight_unsupported_examples' => 'CORRECTION : ne citez pas d’exemples de circonstances extraordinaires (météo, instabilité politique, grèves, oiseaux) absents des sources fournies et ne les rattachez pas à un arrêt qui ne les contient pas ; décrivez l’exception comme la source la décrit. Réécrivez sans mentionner cette correction.',
        'flight_defence_without_reasonable_measures' => 'CORRECTION : pour l’exception des circonstances extraordinaires, reprenez la condition de la source : le retard n’aurait pas pu être évité même si toutes les mesures raisonnables avaient été prises, et le transporteur doit le prouver. Réécrivez sans mentionner cette correction.',
        'flight_unconditional_scope' => 'CORRECTION : n’affirmez pas comme un fait établi que la situation relève du règlement. Pour un départ d’un pays tiers, présentez les conditions fournies comme des conditions : un transporteur communautaire et l’exception lorsque des avantages ou une indemnisation ET une assistance ont déjà été reçus dans ce pays tiers ; indiquez les faits manquants. Réécrivez sans mentionner cette correction.',
        'flight_third_country_exception_disjunctive' => 'CORRECTION : selon la disposition fournie sur le champ d’application, l’exception pour un départ d’un pays tiers ne vaut que si le passager y a reçu certains avantages ou une indemnisation ET une assistance ; n’écrivez pas qu’une indemnisation ou une assistance seule suffit. Réécrivez sans mentionner cette correction.',
        'flight_technical_problem_without_control' => 'CORRECTION : selon l’arrêt fourni, un problème technique n’est une circonstance extraordinaire que s’il découle d’événements qui ne sont pas inhérents à l’exercice normal de l’activité du transporteur ET échappent à sa maîtrise effective ; citez les deux conditions ensemble. Réécrivez sans mentionner cette correction.',
        'flight_amounts_without_edition_caveat' => 'CORRECTION : l’édition fournie du règlement n’est pas confirmée comme texte actuel ; présentez les montants d’indemnisation comme ceux de cette édition fournie et dites que leur vigueur actuelle ne peut pas être confirmée par les sources. Réécrivez sans mentionner cette correction.'
      },
      'de' => {
        'flight_return_route_reversed' => 'KORREKTUR: Sie haben die Rückreise umgekehrt. Sie begann am Ziel der Hinreise und endete am ursprünglichen Abflugort; beschreiben Sie Hin- und Rückreise jeweils in ihrer eigenen Richtung und wenden Sie für einen Abflug aus einem Drittstaat die dafür bereitgestellte Bedingung an. Überarbeiten Sie ohne Hinweis auf diese Korrektur.',
        'flight_completed_trip_unconditional_refund' => 'KORREKTUR: Versprechen Sie bei einer abgeschlossenen, nicht annullierten Reise keine Erstattung oder anderweitige Beförderung ohne Bedingung. Artikel 8 gilt nur, wo eine andere Bestimmung darauf verweist, etwa bei Annullierung oder bei einer Abflugverspätung von mindestens fünf Stunden (dann nur Erstattung); nennen Sie diese Bedingung im selben Satz. Überarbeiten Sie ohne Hinweis auf diese Korrektur.',
        'flight_unsupported_paragraph' => 'KORREKTUR: Ein Verweis auf einen Absatz muss auf den Absatz zeigen, der selbst sagt, was Sie ihm zuschreiben. Nennen Sie einen Absatz nur, wenn sein bereitgestellter Text es sagt; sonst verlinken Sie den Artikel ohne Absatznummer. Überarbeiten Sie ohne Hinweis auf diese Korrektur.',
        'flight_care_without_trigger' => 'KORREKTUR: Verknüpfen Sie Betreuungsleistungen (Mahlzeiten, Hotel, Beförderung) bei Verspätung mit den Abflugverspätungs- und Entfernungsschwellen der bereitgestellten Verspätungsbestimmung und den Bedingungen der Betreuungsbestimmung (Hotel nur bei notwendiger Übernachtung); bei Annullierung ist die Annullierung selbst der Auslöser; die Bestimmung über Erstattung oder anderweitige Beförderung regelt weder Mahlzeiten noch Hotel. Überarbeiten Sie ohne Hinweis auf diese Korrektur.',
        'flight_unsupported_examples' => 'KORREKTUR: Nennen Sie keine Beispiele außergewöhnlicher Umstände (Wetter, politische Instabilität, Streiks, Vögel), die nicht in den bereitgestellten Quellen stehen, und hängen Sie sie nicht an ein Urteil, das sie nicht enthält; beschreiben Sie die Ausnahme wie die Quelle. Überarbeiten Sie ohne Hinweis auf diese Korrektur.',
        'flight_defence_without_reasonable_measures' => 'KORREKTUR: Nennen Sie bei der Ausnahme der außergewöhnlichen Umstände die Bedingung der Quelle: Die Verspätung hätte sich auch dann nicht vermeiden lassen, wenn alle zumutbaren Maßnahmen ergriffen worden wären, und das Unternehmen muss dies nachweisen. Überarbeiten Sie ohne Hinweis auf diese Korrektur.',
        'flight_unconditional_scope' => 'KORREKTUR: Stellen Sie nicht als feststehende Tatsache dar, dass die Situation unter die Verordnung fällt. Bei einem Abflug aus einem Drittstaat nennen Sie die bereitgestellten Bedingungen als Bedingungen: ein Luftfahrtunternehmen der Gemeinschaft und die Ausnahme, wenn im Drittstaat bereits Gegenleistungen oder eine Ausgleichsleistung UND Unterstützungsleistungen erhalten wurden; nennen Sie fehlende Tatsachen. Überarbeiten Sie ohne Hinweis auf diese Korrektur.',
        'flight_third_country_exception_disjunctive' => 'KORREKTUR: Nach der bereitgestellten Anwendungsbestimmung gilt die Ausnahme für einen Abflug aus einem Drittstaat nur, wenn der Fluggast dort bestimmte Gegenleistungen oder eine Ausgleichsleistung erhalten UND Unterstützungsleistungen bekommen hat; schreiben Sie nicht, dass Ausgleich oder Unterstützung allein genügt. Überarbeiten Sie ohne Hinweis auf diese Korrektur.',
        'flight_technical_problem_without_control' => 'KORREKTUR: Nach dem bereitgestellten Urteil ist ein technisches Problem nur dann ein außergewöhnlicher Umstand, wenn es auf Vorkommnisse zurückgeht, die nicht Teil der normalen Ausübung der Tätigkeit des Luftfahrtunternehmens sind UND von ihm tatsächlich nicht zu beherrschen sind; nennen Sie beide Voraussetzungen zusammen. Überarbeiten Sie ohne Hinweis auf diese Korrektur.',
        'flight_amounts_without_edition_caveat' => 'KORREKTUR: Die bereitgestellte Fassung der Verordnung ist nicht als aktueller Text bestätigt; geben Sie die Ausgleichsbeträge als Beträge dieser bereitgestellten Fassung an und sagen Sie, dass ihre aktuelle Geltung aus den Quellen nicht bestätigt werden kann. Überarbeiten Sie ohne Hinweis auf diese Korrektur.'
      },
      'en' => {
        'flight_return_route_reversed' => 'CORRECTION: you reversed the return journey. It left the outbound destination and ended at the original departure point; describe the outbound and return journeys each in its own direction and, for a departure from a third country, apply the supplied scope condition for it. Rewrite without mentioning this correction.',
        'flight_completed_trip_unconditional_refund' => 'CORRECTION: for a completed, non-cancelled journey, do not promise a refund or rerouting without a condition. Article 8 applies only where another provision refers to it, such as cancellation or a departure delay of at least five hours (then only the refund); state that condition in the same sentence. Rewrite without mentioning this correction.',
        'flight_unsupported_paragraph' => 'CORRECTION: a paragraph reference must point at the paragraph that itself says what you attribute to it. Name a paragraph only when its supplied text says so; otherwise link the article without a paragraph number. Rewrite without mentioning this correction.',
        'flight_care_without_trigger' => 'CORRECTION: for a delay, tie care (meals, hotel, transport) to the departure-delay and distance thresholds of the supplied delay provision and the conditions of the care provision (hotel only when an overnight stay is necessary); for a cancellation, the cancellation itself is the trigger; the refund or rerouting provision is not a meals or hotel rule. Rewrite without mentioning this correction.',
        'flight_unsupported_examples' => 'CORRECTION: do not give examples of extraordinary circumstances (weather, political instability, strikes, birds) that the supplied sources do not contain, and do not attach them to a judgment that does not contain them; describe the exception as the source does. Rewrite without mentioning this correction.',
        'flight_defence_without_reasonable_measures' => 'CORRECTION: with the extraordinary-circumstances exception, state the supplied condition: the delay could not have been avoided even if all reasonable measures had been taken, and the carrier must prove it. Rewrite without mentioning this correction.',
        'flight_unconditional_scope' => 'CORRECTION: do not state as an established fact that the situation falls under the Regulation. For a departure from a third country, give the supplied conditions as conditions: a Community operating carrier and the exception where benefits or compensation AND assistance were already received in that third country; name the missing facts. Rewrite without mentioning this correction.',
        'flight_third_country_exception_disjunctive' => 'CORRECTION: under the supplied scope provision the exception for a departure from a third country applies only if the passenger received benefits or compensation AND was given assistance there; do not write that compensation or assistance alone suffices. Rewrite without mentioning this correction.',
        'flight_technical_problem_without_control' => 'CORRECTION: under the supplied judgment a technical problem is an extraordinary circumstance only if it stems from events not inherent in the normal exercise of the carrier’s activity AND beyond its actual control; state both conditions together. Rewrite without mentioning this correction.',
        'flight_amounts_without_edition_caveat' => 'CORRECTION: the supplied edition of the Regulation is not confirmed as the current text; present the compensation amounts as those of that supplied edition and say that their current force cannot be confirmed from the sources. Rewrite without mentioning this correction.'
      }
    }.transform_values(&:freeze).freeze
  end
end
