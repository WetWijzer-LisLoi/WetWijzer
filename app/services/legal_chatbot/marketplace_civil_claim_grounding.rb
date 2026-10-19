# frozen_string_literal: true

require 'digest'

module LegalChatbot
  # Two measured factual contradictions in marketplace answers, not a general
  # legal verifier. Each check needs its own exact admitted current source.
  # A changed, excerpted or unidentified statute deliberately disables that
  # check until its evidence is reviewed again. No answer text is logged or
  # reconstructed here, and passing these checks does not verify an answer.
  class MarketplaceCivilClaimGrounding
    VERSION = 4
    CONDITION_CODES = %w[marketplace_invented_seller_refusal marketplace_unrepresented_lawyer_fee_entitlement
                         marketplace_criminal_status_asserted marketplace_fee_exception_inverted
                         marketplace_oral_notice_sufficient marketplace_amount_indexation_asserted
                         marketplace_lawyer_requirement_invented marketplace_cost_exception_unrestricted
                         marketplace_aided_party_not_losing marketplace_conciliation_mechanics_changed
                         marketplace_jurisdiction_blanket_exclusion].freeze
    REVIEW_AFTER = Date.new(2027, 1, 17)
    MAX_ANSWER_CHARS = 200_000
    MAX_QUESTION_CHARS = 12_000
    MAX_SOURCE_CHARS = 20_000
    SOURCE_BINDINGS = { '5.233' => '2022A32058', '1022' => '1967101055', '5.231' => '2022A32058', '590' => '1967101054',
                        '728' => '1967101055', '732' => '1967101055', '1017' => '1967101055' }.freeze
    # Exact complete NL/FR article bodies captured read-only on 2026-10-17.
    # The full-body seal is intentionally stricter than finding a familiar
    # clause in an arbitrary, stale or altered text carrying the same title.
    BODY_SIGNATURES = {
      ['5.233', 1] => 'c75081506e7d3abfaf723058dfd71749baa1ae0a5103da525ddf3595cf28d3d7',
      ['5.233', 2] => 'e898002a457da0d85d6de37ce06cbc59fa7564fe94c82999f39ee39f63387f19',
      ['1022', 1] => '82a5be88d14e297707ab9331ac9fb8e4c19a18efd4ab5374805a5e83fe8e8736',
      ['1022', 2] => 'ec6d17cfa0dd6174ea563d880d9fb7de283e9d947a75751715bbebea53a7e6cf',
      ['5.231', 1] => 'f3928b21ea05d0039da73603b40931bdd04c305f68c8c978e00b567ac91ab1ed',
      ['5.231', 2] => 'e46078f9fcd977cdfcb0d62372f95992389ce59afa7835638bddf50722df5ca9',
      ['590', 1] => '30884e8768389437667107580c5d35f86405fbeaceebf44b2e3ff517fab04fc9',
      ['590', 2] => 'ebea3af085e3f82a5d2db8cbc550456be6fab947a56d84a0dcb3983ecd553baa',
      ['728', 1] => '56b3f4e07ffaa38e627b7f66df819dec31d120b4a2fb7b8f4d93bce3eca55ef1',
      ['728', 2] => '24845f27493ef1bcfaa541237ba74173943f37c2fa0daa22ad4c7a411886dd79',
      ['732', 1] => '7030536ef6db36c7f911f785b0a44d6e7e575d5ba5be030b170b5801e461d9af',
      ['732', 2] => '1f1e6ff413922d891cd4e2d51a69f4658cc248b8f588fd02b7da1e7c4cc78ed1',
      ['1017', 1] => 'b309b80f9bef6d0daf103aa3e76fd9fbf01b3f36bf5cf29b17953f55549b9075',
      ['1017', 2] => 'cb29d2249966faab9eb08e245fbcefa73c69f5876ead4e710296e1669c915199'
    }.transform_keys(&:freeze).freeze
    PROMISE_PATTERN = /\b(?:beloof\p{L}*|belooft|promise[ds]?|promet\p{L}*|promis\p{L}*|verspr(?:icht|ach|ochen))\b[^.!?;\n]{0,160}\b(?:regel\p{L}*|oploss\p{L}*|lever\p{L}*|fix\p{L}*|sort\p{L}*|resolv\p{L}*|deliver\p{L}*|arrang\p{L}*|r[ée]gl\p{L}*|livr\p{L}*|k[üu]mmern|regeln|liefern)\b/iu
    ACTOR_PATTERN = /\b(?:de\s+verkoper|verkoper|hij|the\s+seller|seller|he|le\s+vendeur|vendeur|il|der\s+Verk[äa]ufer|Verk[äa]ufer|er)\b/iu
    REFUSAL_PATTERN = /\b(?:weiger\p{L}*|geweigerd|toegegeven|meegedeeld|gezegd|laten\s+weten|refus\p{L}*|admitted|said|stated|declared|told|d[ée]clar\p{L}*|annonc\p{L}*|indiqu\p{L}*|verweigert\p{L}*|abgelehnt|erkl[äa]rt\p{L}*|mitgeteilt)\b/iu
    DELIVERY_PATTERN = /\b(?:lever\p{L}*|verstuur\p{L}*|uitvoer\p{L}*|deliver\p{L}*|send|perform\p{L}*|livr\p{L}*|ex[ée]cut\p{L}*|liefern|Lieferung|erf[üu]ll\p{L}*)\b/iu
    NEGATIVE_DELIVERY_PATTERN = /\b(?:niet\s+(?:(?:meer|te|zullen|zal|kan|wil)\s+){0,3}|not\s+(?:to\s+)?|won['’]t\s+|will\s+not\s+|nicht\s+(?:mehr\s+)?)(?:#{DELIVERY_PATTERN.source})|\bne\s+(?:\p{L}+\s+){0,2}(?:livr\p{L}*|ex[ée]cut\p{L}*)\s+(?:pas|jamais)\b/iu
    EXPLICIT_DELIVERY_REFUSAL_PATTERN = /\b(?:weiger\p{L}*|geweigerd)\s+(?:(?:om|nog|verder|het|te|de|een)\s+){0,5}(?:lever\p{L}*|verstuur\p{L}*|uitvoer\p{L}*)\b|\brefus\p{L}*\s+(?:(?:to|any|further|the|a|de|la|le|toute|encore)\s+){0,4}(?:deliver\p{L}*|delivery|send|perform\p{L}*|livr\p{L}*|ex[ée]cut\p{L}*)\b|\b(?:verweigert\p{L}*|abgelehnt)\s+(?:(?:die|eine|weitere)\s+){0,3}(?:Lieferung|liefern|Erf[üu]llung)\b|\b(?:levering|livraison|Lieferung)\s+(?:(?:nu|al|uitdrukkelijk|express[ée]ment|maintenant|jetzt|nun|ausdr[üu]cklich|endg[üu]ltig)\s+){0,3}(?:geweigerd|weigert|refus[ée]\p{L}*|verweigert\p{L}*|abgelehnt)\b/iu
    CONDITIONAL_PATTERN = /\b(?:als|indien|wanneer|mits|of|tenzij|if|unless|when|whether|si|lorsque|wenn|falls|sollte|ob|sauf\s+si|[àa]\s+moins\s+que|es\s+sei\s+denn)\b/iu
    # A condition governs only its own clause: "Indien nodig ..., want de
    # verkoper heeft geweigerd" still asserts the refusal (Codex 20:30).
    CLAUSE_BOUNDARY_PATTERN = /;|\b(?:want|omdat|dus|daarom|aangezien|because|since|so|therefore|car|donc|puisque|weil|denn|deshalb|daher)\b/iu
    LIST_ITEM_PATTERN = /\A(\s*)(?:[-*•+]|\d+[.)]|\d+°)\s+/
    EXCEPTION_FRAME_PATTERN = /\b(?:niet\s+(?:vereist|nodig|verplicht|noodzakelijk)|hoeft\s+(?:\p{L}+\s+){0,3}?(?:geen|niet)|geen\s+ingebrekestelling\s+(?:nodig|vereist)|uitzondering\p{L}*|not\s+(?:required|needed|necessary)|need\s+not|exceptions?|n['’]est\s+pas\s+(?:requise?|n[ée]cessaire)|pas\s+(?:requise?|n[ée]cessaire)|nicht\s+(?:erforderlich|n[öo]tig|notwendig)|Ausnahmen?)\b/iu
    # "ingeberkestelling" (v4 Snel draft 2) is the same notice, misspelt.
    NOTICE_PATTERN = /\b(?:ingeb\p{L}{0,6}stelling\p{L}*|in\s+gebreke\s+(?:stel\p{L}*|te\s+stellen|gesteld)|aanmaning\p{L}*|sommatie|formal\s+notice|notice\s+of\s+default|mise\s+en\s+demeure|mettre\s+en\s+demeure|Inverzugsetzung|Mahnung|in\s+Verzug\s+setz\p{L}*)\b/iu
    ANAPHOR_PATTERN = /\A(?:dit|dat|deze|die|zij|ze|this|that|it|cela|ceci|elle|celle-ci|dies|das|sie|diese)\b/iu
    ORAL_SUFFICIENCY_PATTERN = /\b(?:schriftelijk|written|in\s+writing|par\s+[ée]crit|[ée]crite?|schriftlich)\b[^.!?\n]{0,90}?\b(?:of|or|ou|oder)\s+(?:\p{L}+\s+){0,2}?(?:mondeling|orally|oral|oralement|verbalement|m[üu]ndlich)\b|\b(?:mondeling|orally|oralement|verbalement|m[üu]ndlich)\s+(?:of|or|ou|oder)\s+(?:\p{L}+\s+){0,2}?(?:schriftelijk|in\s+writing|written|par\s+[ée]crit|schriftlich)\b|\b(?:mondelinge?|oral(?:ly)?|oralement|verbale?|m[üu]ndliche?)\b[^.!?\n]{0,40}\b(?:volstaat|volstaan|is\s+voldoende|is\s+geldig|suffices|is\s+enough|is\s+valid|suffit|est\s+valable|gen[üu]gt|reicht)\b|\b(?:kan|mag|can|may|peut|kann|darf)\s+(?:(?:ook|zelfs|also|even|aussi|m[êe]me|auch)\s+)?(?:\p{L}+\s+){0,3}?(?:mondeling|orally|oralement|verbalement|m[üu]ndlich)\b/iu
    # Article 732's oral conciliation request, negations and statements that
    # the source prescribes no form are not the measured sufficiency claim.
    ORAL_EXCLUSION_PATTERN = /\b(?:verzoek\p{L}*|verzoening\p{L}*|minnelijk\p{L}*|conciliation|request|demande|requ[êe]te|Schlichtung\p{L}*|G[üu]teantrag|Antrag)\b|\b(?:niet|geen|not|no|pas|nicht|kein\p{L}*)\s+(?:\p{L}+\s+){0,2}?(?:mondeling\p{L}*|oral\p{L}*|m[üu]ndlich\p{L}*)\b|\b(?:mondeling\p{L}*|oral\p{L}*|m[üu]ndlich\p{L}*)\b[^.!?\n]{0,40}\b(?:volstaat\s+niet|is\s+niet\s+voldoende|niet\s+voldoende|does\s+not\s+suffice|is\s+not\s+enough|ne\s+suffit\s+pas|gen[üu]gt\s+nicht|reicht\s+nicht)\b|\b(?:geen\s+(?:vaste\s+)?vorm|bepaalt\s+(?:geen|niet)|schrijft\s+(?:geen|niet)|zegt\s+niet|regelt\s+(?:geen|niet)|no\s+(?:particular\s+)?form|does\s+not\s+(?:prescribe|specify|say)|aucune\s+forme|ne\s+(?:pr[ée]voit|pr[ée]cise|prescrit)\s+pas|keine\s+(?:bestimmte\s+)?Form)\b/iu
    AMOUNT_CONTEXT_PATTERN = /\b(?:5[ .]?000|bedrag\p{L}*|bevoegdheidsgrens|grens|drempel|amount|threshold|montant|seuil|Betrag|Grenze|Schwelle)\b/iu
    INDEXATION_ASSERTION_PATTERN = /\b(?:jaarlijks|elk\s+jaar|ieder\s+jaar|automatisch|annually|every\s+year|automatically|chaque\s+ann[ée]e|annuellement|automatiquement|j[äa]hrlich|automatisch)\b[^.!?\n]{0,40}\b(?:ge[iï]ndexeerd|aangepast|herzien|indexed|adjusted|revised|index[ée]e?s?|ajust[ée]e?s?|r[ée]vis[ée]e?s?|indexiert|angepasst)\b|\b(?:ge[iï]ndexeerd|indexed|index[ée]e?s?|indexiert)\b[^.!?\n]{0,20}\b(?:jaarlijks|elk\s+jaar|annually|every\s+year|chaque\s+ann[ée]e|j[äa]hrlich)\b|\(\s*(?:met\s+indexering|ge[iï]ndexeerd|indexed|index[ée]e?|indexiert)\s*\)|\b(?:actuele|huidige)\s+bedrag\b|\bcurrent\s+amount\b|\bmontant\s+actuel\b|\baktuelle[rn]?\s+Betrag\b/iu
    INDEXATION_CLAUSE_PATTERN = /[,;:]|\s+(?:en|and|et|und|terwijl|whereas|tandis\s+que|w[äa]hrend)\s+/iu
    # An item that speaks about this case ("deze verkoper", "in uw geval") is
    # a fact of the case, never a statutory exception example (Codex 20:36).
    CASE_OWNED_PATTERN = /\b(?:(?:deze|uw|jouw|die|this|your|that|ce|cet|votre|dieser|Ihr)\s+verkoper|(?:this|your|that)\s+seller|(?:ce|votre)\s+vendeur|(?:dieser|Ihr)\s+Verk[äa]ufer|in\s+(?:uw|jouw)\s+(?:geval|situatie|zaak)|in\s+your\s+(?:case|situation)|dans\s+votre\s+(?:cas|situation)|in\s+Ihrem\s+Fall)\b/iu
    INDEXATION_HEDGE_PATTERN = /\b(?:kan|kunnen|mag|may|can|could|might|peut|pourrait|kann|k[öo]nnte|mogelijk|eventueel|possibly|possiblement|m[öo]glicherweise|niet\s+(?:automatisch|jaarlijks)|not\s+(?:automatically|annually)|pas\s+automatiquement|nicht\s+automatisch)\b/iu
    EXAMPLE_PATTERN = /\A\s*(?:[-\d.)]+\s*)?(?:bijvoorbeeld|voorbeeld|for\s+example|example|par\s+exemple|exemple|zum\s+Beispiel|Beispiel)\s*[:—–,]/iu
    REFUSAL_DENIAL_PATTERN = /\b(?:niet|nooit|not|never|pas|jamais|nicht|nie)\s+(?:(?:uitdrukkelijk|explicitly|express[ée]ment|ausdr[üu]cklich|al|yet|encore|noch)\s+){0,2}#{REFUSAL_PATTERN.source}|\b(?:hasn['’]t|hadn['’]t|doesn['’]t|didn['’]t)\s+#{REFUSAL_PATTERN.source}|\b(?:geen|no|aucun\p{L}*|kein\p{L}*|evenmin|noch|nor|ni|ebenso\s+wenig)\s+(?:(?:een|a|un|une|eine|uitdrukkelijke)\s+){0,2}(?:weigering|refusal|refus|Verweigerung)\b|#{REFUSAL_PATTERN.source}[^.!?;\n]{0,45}\b(?:niet\s+vast|niet\s+aan|niet\s+bewezen|not\s+established|not\s+shown|pas\s+[ée]tabli|nicht\s+belegt)\b/iu
    UNESTABLISHED_PATTERN = /\b(?:niet\s+(?:vastgesteld|bewezen|gebleken)|geen\s+bewijs|onduidelijk\s+of|not\s+(?:established|shown|proven)|no\s+evidence|cannot\s+infer|pas\s+[ée]tabli|aucune?\s+preuve|nicht\s+(?:festgestellt|belegt|bewiesen)|kein\p{L}*\s+(?:Beweis|Nachweis))\b/iu
    FEE_PATTERN = /\b(?:rechtsplegingsvergoeding\p{L}*|indemnit[ée]\s+de\s+proc[ée]dure|Verfahrensentsch[äa]digung|Prozesskostenpauschale|(?:statutory\s+)?lawyer[-\s]fee\s+contribution|procedural\s+indemnity|litigation\s+indemnity)\b/iu
    UNREPRESENTED_PATTERN = /\b(?:zonder\s+(?:een\s+)?advocaat|geen\s+advocaat\s+(?:hebt|heeft|neemt|inschakelt)|zelf\s+(?:procedeert|verschijnt)|in\s+persoon\s+verschijnt|without\s+(?:a\s+)?lawyer|self[-\s]represented|(?:have|has|use|uses)\s+no\s+lawyer|sans\s+avocat|vous\s+(?:vous\s+)?repr[ée]sentez\s+seul|ohne\s+(?:einen?\s+)?(?:Rechts)?anwalt|selbst\s+vertreten)\b/iu
    FEE_ENTITLEMENT_PATTERN = /\b(?:krijg\p{L}*|ontvang\p{L}*|recht\s+op|kan\p{L}*\s+(?:\p{L}+\s+){0,4}(?:vorderen|krijgen|ontvangen)|bedraagt|minimumbedrag|minimumvergoeding|receiv\p{L}*|entitl\p{L}*|can\s+claim|payable|awarded|minimum|droit\s+[àa]|recev\p{L}*|obten\p{L}*|allou\p{L}*|pouvez\s+(?:la\s+)?demander|erhalt\p{L}*|erh[äa]lt|Anspruch|steht\s+[^.!?;\n]{0,55}\bzu|Mindestbetrag|zugesprochen\p{L}*)\b/iu
    FEE_DENIAL_PATTERN = /\b(?:geen\s+(?:automatisch\s+)?(?:recht|rechtsplegingsvergoeding)|niet\s+(?:krijg\p{L}*|ontvang\p{L}*|verschuldigd)|krijg\p{L}*\s+(?:(?:u|je|men)\s+)?geen|ontvang\p{L}*\s+(?:(?:u|je|men)\s+)?geen|not\s+(?:automatically\s+)?(?:entitled|payable|awarded)|no\s+(?:automatic\s+)?(?:entitlement|procedural\s+indemnity|lawyer[-\s]fee\s+contribution)|(?:cannot|can't|do\s+not|does\s+not)\s+(?:claim|receive)|pas\s+(?:de\s+)?(?:droit|d['’]indemnit[ée])|ne\s+(?:recev\p{L}*|pouvez\s+(?:pas\s+)?(?:obtenir|demander))\s+pas|aucun\p{L}*\s+(?:droit|indemnit[ée])|kein\p{L}*\s+(?:Anspruch|Verfahrensentsch[äa]digung|Prozesskostenpauschale)|nicht\s+(?:erhalt\p{L}*|geschuldet)|erhalt\p{L}*\s+(?:Sie\s+)?keine)\b/iu
    ADVERSE_COST_PATTERN = /\b(?:tegenpartij|andere\s+partij|opponent|other\s+party|partie\s+adverse|Gegner|Gegenpartei)\b[^.!?;,\n]{0,90}\b(?:rechtsplegingsvergoeding|vorderen|ontvang\p{L}*|recht|entitl\p{L}*|claim|receiv\p{L}*|procedural\s+indemnity|droit|recev\p{L}*|r[ée]clam\p{L}*|indemnit[ée]|Anspruch|erhalt\p{L}*|Verfahrensentsch[äa]digung)\b|\b(?:aan\s+(?:de\s+)?tegenpartij|to\s+(?:the\s+)?opponent|[àa]\s+la\s+partie\s+adverse|an\s+den\s+Gegner)\b/iu
    # A comma does not turn the opponent's fee entitlement into the user's.
    # Keep this to a bounded named antecedent + local beneficiary pronoun;
    # an unrelated mention of an opponent is not a blanket exemption.
    ADVERSE_PRONOUN_PATTERN = /\b(?:tegenpartij|andere\s+partij|opponent|other\s+party|partie\s+adverse|Gegner|Gegenpartei)\b[^.!?;,\n]{0,100},\s*(?:(?:krijg\p{L}*|ontvang\p{L}*)\s+(?:hij|zij|ze|deze)|(?:they|it|he|she|that\s+party)\s+(?:(?:will|may|can|is|are|be|also|still)\s+){0,4}(?:receiv\p{L}*|entitl\p{L}*|claim)|(?:elle|il|cette\s+partie)\s+(?:(?:aura|a|peut|aussi)\s+){0,3}(?:droit|recev\p{L}*|obten\p{L}*|r[ée]clam\p{L}*)|(?:erh[äa]lt|bekommt)\s+(?:sie|er|diese)|(?:sie|er|diese)\s+(?:erh[äa]lt|bekommt))\b[^.!?;,\n]{0,80}#{FEE_PATTERN.source}/iu
    # Civil sources neither establish nor exclude an offence (2026-10-17 depth
    # run: "a civil claim and not a criminal fact"). Only a categorical
    # classification counts; an insufficiency or an open question does not.
    NOT_CRIMINAL_PATTERN = /\b(?:geen\s+|niet\s+(?:om\s+)?(?:een\s+)?)(?:strafbaar\s+feit|misdrijf|oplichting|fraude|bedrog|strafzaak|strafrechtelijk\p{L}*\s+(?:zaak|kwestie|feit))\b|\bniet\s+strafbaar\b|\bnot\s+(?:a\s+)?(?:criminal\s+(?:offen[cs]e|matter|act|case)|fraud|scam)\b|\bno\s+(?:criminal\s+offen[cs]e|fraud)\b|\bpas\s+(?:d['’]\s*|de\s+)?(?:une?\s+)?(?:infraction|escroquerie|fraude|délit|affaire\s+pénale)\b|\b(?:keine?|nicht)\s+(?:Straftat|Betrug|strafbar\p{L}*)\b/iu
    HEDGE = '(?:niet|not|pas|nicht|geen|kein\p{L}*|no|never|nooit|jamais|nie|mogelijk|misschien|eventueel|possibly|perhaps|probably|peut-être|möglicherweise|vielleicht|waarschijnlijk|vermoedelijk|probablement|wahrscheinlich)'
    IS_CRIMINAL_PATTERN = /\b(?:(?:dit|het|dat|this|it|that|cela|das|es)\s+(?:is|gaat\s+om|betreft|vormt|constitutes|ist|est|constitue)|c['’]est|it['’]s|that['’]s)\s+(?:(?!#{HEDGE}\b)\p{L}+\s+){0,2}?(?:oplichting|fraude|bedrog|strafbaar\s+feit|misdrijf|fraud|scam|criminal\s+offen[cs]e|escroquerie|infraction|délit|Betrug|Straftat)\b|\b(?:u\s+bent|je\s+bent|jij\s+bent|you\s+(?:have\s+been|were|got)|vous\s+avez\s+été|Sie\s+(?:wurden|sind))\s+(?:(?!#{HEDGE}\b)\p{L}+\s+){0,2}?(?:opgelicht|bedrogen|scammed|defrauded|escroqu\p{L}*|betrogen)\b/iu
    STATUS_UNCERTAINTY_PATTERN = /\b(?:of|whether|si|ob|als|indien|wanneer|if|when|lorsque|wenn|falls|mogelijk|misschien|eventueel|possibly|perhaps|might|peut[-\s]être|éventuellement|möglicherweise|vielleicht|onduidelijk|unclear)\b/iu
    STATUS_INSUFFICIENCY_PATTERN = /\A[^.!?;\n]{0,40}?\b(?:vast\s+te\s+stellen|aan\s+te\s+tonen|te\s+bewijzen|uit\s+te\s+sluiten|bewezen|vastgesteld|to\s+(?:establish|prove|rule\s+out)|established|proven|d['’](?:établir|exclure)|de\s+(?:prouver|démontrer)|établi\p{L}*|festzustellen|nachzuweisen|auszuschließen|festgestellt|bewiesen)\b/iu
    # "... en geen strafbaar feit hoeft te zijn" says it NEED not be an
    # offence, which leaves the question open (2026-10-17 run). Only a modal
    # directly attached to the offence words counts.
    STATUS_MODAL_PATTERN = /\A\s*(?:\p{L}+\s+){0,1}?(?:hoeft|hoeven|hoefde|hoefden)\s+(?:\p{L}+\s+){0,2}?te\s+(?:zijn|wezen)\b|\A\s*(?:need|needs)\s+not\s+be\b|\A\s*(?:does|do)\s+not\s+(?:need|have)\s+to\s+be\b|\A\s*(?:sein\s+)?(?:muss|müssen|braucht|brauchen)\s+(?:\p{L}+\s+){0,2}?(?:zu\s+)?sein\b/iu
    CRIMINAL_LAW_SOURCE_PATTERN = /\b(?:Strafwetboek|Code\s+p[ée]nal|Strafgesetzbuch|Criminal\s+Code)\b/iu
    CRIMINAL_CODE_NUMAC = '1867060850'
    # Article 1022's exceptions concern the amount (the minimum for a losing
    # party on second-line legal aid, unless manifestly unreasonable), never
    # an absence of the contribution.
    FEE_ABSENCE_PATTERN = /\bgeen\s+rechtsplegingsvergoeding\b|\bpas\s+d['’]indemnit[ée]\s+de\s+proc[ée]dure\b|\baucune\s+indemnit[ée]\s+de\s+proc[ée]dure\b|\bkeine\s+Verfahrensentsch[äa]digung\b|\bno\s+(?:procedural\s+indemnity|lawyer[-\s]fee\s+contribution)\b/iu
    FEE_EXCEPTION_CONTEXT_PATTERN = /\b(?:kennelijk\s+onredelijk\p{L}*|tweedelijns\p{L}*|manifestement\s+d[ée]raisonnable|deuxi[èe]me\s+ligne|offensichtlich\s+unvern[üu]nftig\p{L}*|zweiten?\s+Linie|manifestly\s+unreasonable|second[-\s]line)\b/iu
    DIRECT_RECIPIENT_PATTERN = /\b(?:u|je|jij)\s+(?:(?:zal|zult|kunt|kan|ook|toch|zelf)\s+){0,3}(?:krijg\p{L}*|ontvang\p{L}*|hebt\s+recht)|\b(?:krijg\p{L}*|ontvang\p{L}*)\s+(?:u|je|jij)\b|\byou\s+(?:(?:are|will|can|may|still|also)\s+){0,3}(?:receiv\p{L}*|entitl\p{L}*|claim)|\bvous\s+(?:(?:aurez|avez|pouvez|aussi)\s+){0,3}(?:recev\p{L}*|obten\p{L}*|r[ée]clam\p{L}*|droit)|\bSie\s+(?:(?:k[öo]nnen|werden|auch|selbst)\s+){0,3}(?:erhalt\p{L}*|haben\s+Anspruch)/iu

    class << self
      def topic?(question)
        question.to_s.length <= MAX_QUESTION_CHARS && MarketplaceCivilClaimIntent.topic?(question)
      end

      def evidence(sources)
        return {} if Date.current > REVIEW_AFTER

        Array(sources).each_with_object({}) do |source, selected|
          next unless source.is_a?(Hash)
          next if stale?(source)

          number = source_number(source)
          next unless number && canonical_binding?(source, number)

          language = field(source, :language_id)
          next unless language.is_a?(Integer)

          signature = BODY_SIGNATURES[[number, language]]
          next unless signature

          body = field(source, :article_text, :text, :full_text, :content)
          next unless body.is_a?(String) && body.valid_encoding? && body.length <= MAX_SOURCE_CHARS
          next unless Digest::SHA256.hexdigest(body) == signature

          selected[number] ||= true
        end
      end

      def evaluate(answer, question, sources)
        grounded = topic?(question) ? evidence(sources) : {}
        return { applicable: false, missing_conditions: [], version: VERSION } if grounded.empty?

        missing = []
        promise_only = promise_without_established_refusal?(question)
        civil_only = Array(sources).none? { |source| criminal_law_source?(source) }
        if grounded['5.233'] && promise_only && sentences(without_exception_list_items(answer)).any? { |sentence| affirmative_refusal?(sentence) }
          missing << 'marketplace_invented_seller_refusal'
        end
        missing << 'marketplace_oral_notice_sufficient' if grounded['5.231'] && oral_notice_sufficient?(answer)
        missing << 'marketplace_amount_indexation_asserted' if grounded['590'] && amount_indexation_asserted?(answer)
        missing.concat(ProcedureClaims.missing(answer, grounded))
        sentences(answer).each do |sentence|
          missing << 'marketplace_unrepresented_lawyer_fee_entitlement' if grounded['1022'] && unrepresented_fee_entitlement?(sentence)
          missing << 'marketplace_criminal_status_asserted' if civil_only && criminal_status?(sentence)
          missing << 'marketplace_fee_exception_inverted' if grounded['1022'] && fee_exception_inverted?(sentence)
        end
        { applicable: true, missing_conditions: CONDITION_CODES & missing, version: VERSION }
      end

      def corrective_feedback(missing_conditions, language: 'nl')
        codes = Array(missing_conditions).map(&:to_s) & CONDITION_CODES
        return nil if codes.empty?

        copy = FEEDBACK_COPY.fetch(language.to_s, FEEDBACK_COPY.fetch('nl'))
        "#{codes.map { |code| copy.fetch(code) }.join(' ')} [#{codes.join(', ')}]"
      end

      private

      def sentences(text)
        text.to_s[0, MAX_ANSWER_CHARS].gsub(/```[\s\S]*?```/, '').gsub(/^[ \t]*>.*$/, '')
            .gsub(/\[([^\]]+)\]\([^)]+\)/, '\\1').gsub(%r{https?://\S+}, '')
            .gsub(/[*_`]/, '').split(/(?<=[!?;])\s+|\n|(?<=\.)\s+(?=[[:upper:]])|\b(?:maar|echter|but|however|cependant|toutefois|aber|jedoch)\b/iu)
            .map(&:strip).reject(&:empty?)
      end

      # List items directly under a lead that states the notice is not
      # required ("Een ingebrekestelling is niet vereist als:") name the
      # statutory exceptions, not facts of this case. The list ends at a
      # blank line, a heading, a rule or the first line that is no deeper
      # item; any later statement is judged on its own (Codex 20:30).
      def without_exception_list_items(answer)
        lines = answer.to_s[0, MAX_ANSWER_CHARS].split("\n")
        skipped = []
        lines.each_with_index do |line, index|
          lead = plain_line(line)
          next unless lead.end_with?(':') && lead.match?(EXCEPTION_FRAME_PATTERN) && lead.match?(NOTICE_PATTERN)

          lead_item = line.match(LIST_ITEM_PATTERN)
          lead_indent = lead_item ? lead_item[1].length : nil
          lines[(index + 1)..].each_with_index do |following, offset|
            item = following.match(LIST_ITEM_PATTERN)
            break unless item && !following.strip.start_with?('#')
            break if lead_indent && item[1].length <= lead_indent
            next if plain_line(following).match?(CASE_OWNED_PATTERN)

            skipped << (index + 1 + offset)
          end
        end
        lines.reject.with_index { |_line, index| skipped.include?(index) }.join("\n")
      end

      def plain_line(line)
        line.to_s.sub(LIST_ITEM_PATTERN, '').gsub(/\[([^\]]+)\]\([^)]+\)/, '\\1').gsub(/[*_`]/, '').strip
      end

      # Article 5.231 defines the notice by its content; no supplied text
      # makes an oral notice sufficient. The oral conciliation request of
      # Article 732, written notice as evidence and statements that the
      # source prescribes no form stay available.
      def oral_notice_sufficient?(answer)
        answer.to_s[0, MAX_ANSWER_CHARS].split("\n").any? do |line|
          previous = nil
          plain_line(line).split(/(?<=[.!?])\s+(?=\p{Lu})/).any? do |sentence|
            notice = sentence.match?(NOTICE_PATTERN) || (previous.to_s.match?(NOTICE_PATTERN) && sentence.match?(ANAPHOR_PATTERN))
            previous = sentence
            notice && sentence.match?(ORAL_SUFFICIENCY_PATTERN) && !sentence.match?(ORAL_EXCLUSION_PATTERN)
          end
        end
      end

      # Article 590 states EUR 5000 and that the King CAN adjust it; an
      # automatic annual indexation or a "current amount" is not in it. A
      # bare "(peildatum ...)" is left alone: the shared prompt's rule 3 asks
      # the model to check the rule on the reference date.
      def amount_indexation_asserted?(answer)
        sentences(answer).any? do |sentence|
          next false unless sentence.match?(AMOUNT_CONTEXT_PATTERN)

          # The hedge governs only its own clause: "De Koning kan het bedrag
          # aanpassen en het bedrag wordt jaarlijks geindexeerd" still
          # asserts the automatic indexation (Codex 20:36).
          sentence.split(INDEXATION_CLAUSE_PATTERN).any? do |clause|
            clause.match?(INDEXATION_ASSERTION_PATTERN) && !clause.match?(INDEXATION_HEDGE_PATTERN)
          end
        end
      end

      def promise_without_established_refusal?(question)
        question.to_s.match?(PROMISE_PATTERN) && sentences(question).none? { |sentence| affirmative_refusal?(sentence) }
      end

      def affirmative_refusal?(sentence)
        return false if sentence.end_with?('?') || sentence.match?(EXAMPLE_PATTERN) || sentence.match?(REFUSAL_DENIAL_PATTERN)
        return false if sentence.match?(/\A["“«„][\s\S]*["”»“]\z/)

        actor = sentence.match(ACTOR_PATTERN)
        return false unless actor

        prefix = sentence[0...actor.begin(0)].split(CLAUSE_BOUNDARY_PATTERN).last.to_s
        return false if prefix.match?(CONDITIONAL_PATTERN) || prefix.match?(UNESTABLISHED_PATTERN)

        # Only a local asserted seller/refusal/delivery relation, never an
        # incidental word elsewhere in a long answer or a general exception.
        relation = sentence[actor.begin(0), 360]
        return false if relation.match?(/\A#{ACTOR_PATTERN.source}\s+(?:als|if|si|wenn)\b/iu)

        refusal = relation.match(REFUSAL_PATTERN)
        return false unless refusal
        return false if relation[0...refusal.begin(0)].match?(UNESTABLISHED_PATTERN)

        relation.match?(EXPLICIT_DELIVERY_REFUSAL_PATTERN) ||
          relation[refusal.end(0), 180].to_s.match?(NEGATIVE_DELIVERY_PATTERN)
      end

      def unrepresented_fee_entitlement?(sentence)
        return false if sentence.end_with?('?') || sentence.match?(EXAMPLE_PATTERN) || sentence.match?(FEE_DENIAL_PATTERN)
        return false if sentence.match?(/\A["“«„][\s\S]*["”»“]\z/)

        adverse_recipient = sentence.match?(ADVERSE_COST_PATTERN) || sentence.match?(ADVERSE_PRONOUN_PATTERN)
        return false if adverse_recipient && !sentence.match?(DIRECT_RECIPIENT_PATTERN)

        sentence.match?(FEE_PATTERN) && sentence.match?(UNREPRESENTED_PATTERN) && sentence.match?(FEE_ENTITLEMENT_PATTERN)
      end

      def criminal_status?(sentence)
        return false if sentence.end_with?('?') || sentence.match?(EXAMPLE_PATTERN)
        return false if sentence.match?(/\A["“«„][\s\S]*["”»“]\z/)

        [NOT_CRIMINAL_PATTERN, IS_CRIMINAL_PATTERN].any? do |pattern|
          sentence.to_enum(:scan, pattern).any? do
            match = Regexp.last_match
            before = sentence[[match.begin(0) - 60, 0].max...match.begin(0)]
            !before.match?(STATUS_UNCERTAINTY_PATTERN) && !match.post_match.match?(STATUS_INSUFFICIENCY_PATTERN) &&
              !match.post_match.match?(STATUS_MODAL_PATTERN)
          end
        end
      end

      # "Geen rechtsplegingsvergoeding zonder advocaat, ook bij
      # tweedelijnsbijstand" states the separate no-lawyer condition.
      def fee_exception_inverted?(sentence)
        sentence.match?(FEE_ABSENCE_PATTERN) && sentence.match?(FEE_EXCEPTION_CONTEXT_PATTERN) &&
          !sentence.match?(UNREPRESENTED_PATTERN)
      end

      def criminal_law_source?(source)
        return false unless source.is_a?(Hash)

        field(source, :numac).to_s == CRIMINAL_CODE_NUMAC ||
          %i[law_title title].any? { |key| field(source, key).to_s.match?(CRIMINAL_LAW_SOURCE_PATTERN) }
      end

      def source_number(source)
        numbers = %i[article_number article_title].filter_map do |key|
          value = field(source, key)
          next if value.nil?

          match = value.to_s.match(/\A\s*(?:Art(?:ikel|icle)?\.?\s*)?(5\.233|5\.231|1022|1017|728|732|590)\.?\s*\z/i)
          return nil unless match

          match[1]
        end
        numbers.first if numbers.any? && numbers.uniq.one?
      end

      def canonical_binding?(source, number)
        expected = SOURCE_BINDINGS.fetch(number)
        return false unless field(source, :numac).to_s == expected
        return false if field(source, :content_numac).present? && field(source, :content_numac).to_s != expected

        anchor = "#art-#{number.tr('.', '-')}"
        return false if %i[article_anchor anchor].any? { |key| field(source, key).present? && field(source, key).to_s != anchor }

        %i[link url].all? do |key|
          value = field(source, key)
          value.blank? || value.to_s.match?(%r{\A(?:https://(?:wetwijzer|lisloi|gesetzguide|lexlibera)\.be)?/laws/#{expected}(?:\?language_id=#{field(source, :language_id)})?#{Regexp.escape(anchor)}\z})
        end
      end

      def stale?(source)
        %i[is_abolished abolished historical is_historical stale].any? { |key| [true, 1, '1', 'true'].include?(field(source, key)) } ||
          %i[current is_current].any? { |key| [false, 0, '0', 'false'].include?(field(source, key)) }
      end

      def field(source, *keys)
        keys.each do |key|
          return source[key] unless source[key].nil?
          return source[key.to_s] unless source[key.to_s].nil?
        end
        nil
      end
    end

    FEEDBACK_COPY = {
      'nl' => {
        'marketplace_invented_seller_refusal' => 'CORRECTIE: verzin geen leveringsweigering uit de enkele belofte van de verkoper om het te regelen. Maak een uitzondering van artikel 5.233 afhankelijk van werkelijk vastgestelde feiten. Herschrijf de gemarkeerde onjuiste toepassing inhoudelijk en voorwaardelijk met de aangeleverde bronnen, zonder deze correctie te vermelden.',
        'marketplace_unrepresented_lawyer_fee_entitlement' => 'CORRECTIE: beloof een partij zonder advocaat geen rechtsplegingsvergoeding of minimum daarvoor; artikel 1022 betreft een bijdrage in advocaatkosten. Onderscheid gewone gerechtskosten, vertegenwoordiging en het risico kosten van de tegenpartij te moeten betalen. Herschrijf de gemarkeerde toepassing met de aangeleverde bron zonder deze correctie te vermelden.',
        'marketplace_criminal_status_asserted' => 'CORRECTIE: de aangeleverde burgerlijke bronnen maken een strafklacht geen voorwaarde voor de burgerlijke vordering, maar kunnen niet vaststellen of uitsluiten dat de feiten een misdrijf zoals oplichting vormen. Zeg dus niet dat het wel of geen strafbaar feit is; herschrijf zonder deze correctie te vermelden.',
        'marketplace_fee_exception_inverted' => 'CORRECTIE: de uitzonderingen van artikel 1022 gaan over het bedrag (verlaging of verhoging bij bijzonder gemotiveerde beslissing, en het minimum voor een verliezende partij met tweedelijnsbijstand tenzij de situatie kennelijk onredelijk is), niet over het ontbreken van elke vergoeding; ook een titel of lijstlabel is een bewering. Herschrijf zonder deze correctie te vermelden.',
        'marketplace_oral_notice_sufficient' => 'CORRECTIE: de aangeleverde bepaling over de ingebrekestelling omschrijft haar inhoud (een duidelijke en ondubbelzinnige eis tot nakoming), niet dat een mondelinge ingebrekestelling volstaat. Stel geen vormregel uit het geheugen voor; een gedateerde schriftelijke ingebrekestelling mag u als praktisch bewijs aanraden. Herschrijf zonder deze correctie te vermelden.',
        'marketplace_amount_indexation_asserted' => 'CORRECTIE: de aangeleverde bevoegdheidsbepaling noemt 5.000 euro en dat de Koning dat bedrag kan aanpassen; zij zegt niet dat het jaarlijks automatisch wordt geïndexeerd en geeft geen actueel bedrag op een peildatum. Vermeld alleen wat de tekst zegt. Herschrijf zonder deze correctie te vermelden.',
        'marketplace_lawyer_requirement_invented' => 'CORRECTIE: de aangeleverde bepaling zegt dat partijen in persoon of bij advocaat verschijnen; zij geeft de rechter geen bevoegdheid om een advocaat te verplichten. Schrijf die bevoegdheid niet. Herschrijf zonder deze correctie te vermelden.',
        'marketplace_cost_exception_unrestricted' => 'CORRECTIE: volgens de aangeleverde kostenbepaling wordt de in het ongelijk gestelde partij in de kosten verwezen tenzij bijzondere wetten anders bepalen, en kan de rechter de kosten alleen in de genoemde gevallen omslaan; schrijf niet dat de rechter algemeen anders kan beslissen. Herschrijf zonder deze correctie te vermelden.',
        'marketplace_aided_party_not_losing' => 'CORRECTIE: het minimum van de rechtsplegingsvergoeding geldt volgens de aangeleverde bepaling wanneer de in het ongelijk gestelde partij tweedelijns juridische bijstand geniet; vermeld die voorwaarde. Herschrijf zonder deze correctie te vermelden.',
        'marketplace_conciliation_mechanics_changed' => 'CORRECTIE: volgens de aangeleverde bepaling roept de griffier de partijen op verzoek bij gewone brief op om binnen een maand te verschijnen op dag en uur door de rechter bepaald; schrijf niet dat de oproep zelf binnen een maand volgt of dat de rechter rechtstreeks oproept. Herschrijf zonder deze correctie te vermelden.',
        'marketplace_jurisdiction_blanket_exclusion' => 'CORRECTIE: de aangeleverde bevoegdheidsbepaling noemt 5.000 euro als gewone geldelijke bevoegdheid, behalve wat de wet aan de vrederechter onttrekt; schrijf niet dat hij voor geen enkele vordering boven 5.000 euro bevoegd is. Herschrijf zonder deze correctie te vermelden.'
      },
      'fr' => {
        'marketplace_invented_seller_refusal' => 'CORRECTION : ne transformez pas la simple promesse du vendeur de régler le problème en un refus établi de livrer. Toute exception de l’article 5.233 dépend des faits réellement établis. Corrigez l’application signalée à partir des sources fournies et donnez une réponse substantielle et conditionnelle sans mentionner cette correction.',
        'marketplace_unrepresented_lawyer_fee_entitlement' => 'CORRECTION : ne promettez pas une indemnité de procédure, même minimale, à une partie sans avocat ; l’article 1022 concerne une contribution aux frais d’avocat. Distinguez les frais de justice ordinaires, la représentation et le risque de payer les frais adverses. Corrigez l’application signalée avec la source fournie sans mentionner cette correction.',
        'marketplace_criminal_status_asserted' => 'CORRECTION : les sources civiles fournies ne font pas d’une plainte pénale une condition de l’action civile, mais elles ne permettent ni d’établir ni d’exclure que les faits constituent une infraction comme une escroquerie. Ne dites donc pas que c’est ou que ce n’est pas une infraction ; réécrivez sans mentionner cette correction.',
        'marketplace_fee_exception_inverted' => 'CORRECTION : les exceptions de l’article 1022 portent sur le montant (réduction ou augmentation par décision spécialement motivée, et le minimum pour une partie succombante bénéficiant de l’aide juridique de deuxième ligne sauf situation manifestement déraisonnable), pas sur l’absence de toute indemnité ; un titre ou un intitulé de liste est aussi une affirmation. Réécrivez sans mentionner cette correction.',
        'marketplace_oral_notice_sufficient' => 'CORRECTION : la disposition fournie sur la mise en demeure en décrit le contenu (une exigence claire et non équivoque d’exécution), elle ne dit pas qu’une mise en demeure orale suffit. N’énoncez aucune règle de forme de mémoire ; une mise en demeure écrite et datée peut être conseillée comme preuve pratique. Réécrivez sans mentionner cette correction.',
        'marketplace_amount_indexation_asserted' => 'CORRECTION : la disposition fournie sur la compétence cite 5.000 euros et indique que le Roi peut adapter ce montant ; elle ne dit pas qu’il est indexé automatiquement chaque année et ne donne aucun montant actuel à une date de référence. Ne reprenez que ce que dit le texte. Réécrivez sans mentionner cette correction.',
        'marketplace_lawyer_requirement_invented' => 'CORRECTION : la disposition fournie dit que les parties comparaissent en personne ou par avocat ; elle ne donne au juge aucun pouvoir d’imposer un avocat. N’écrivez pas ce pouvoir. Réécrivez sans mentionner cette correction.',
        'marketplace_cost_exception_unrestricted' => 'CORRECTION : selon la disposition fournie sur les dépens, la partie succombante est condamnée aux dépens sauf si des lois particulières en disposent autrement, et le juge ne peut compenser les dépens que dans les cas cités ; n’écrivez pas que le juge peut en décider autrement de manière générale. Réécrivez sans mentionner cette correction.',
        'marketplace_aided_party_not_losing' => 'CORRECTION : selon la disposition fournie, le minimum de l’indemnité de procédure s’applique lorsque la partie succombante bénéficie de l’aide juridique de deuxième ligne ; mentionnez cette condition. Réécrivez sans mentionner cette correction.',
        'marketplace_conciliation_mechanics_changed' => 'CORRECTION : selon la disposition fournie, sur demande, le greffier convoque les parties par pli simple à comparaître dans le mois aux jour et heure fixés par le juge ; n’écrivez pas que la convocation elle-même suit dans le mois ni que le juge convoque directement. Réécrivez sans mentionner cette correction.',
        'marketplace_jurisdiction_blanket_exclusion' => 'CORRECTION : la disposition fournie sur la compétence cite 5.000 euros comme compétence pécuniaire ordinaire, sauf ce que la loi soustrait au juge de paix ; n’écrivez pas qu’il n’est compétent pour aucune demande supérieure à 5.000 euros. Réécrivez sans mentionner cette correction.'
      },
      'de' => {
        'marketplace_invented_seller_refusal' => 'KORREKTUR: Machen Sie aus dem bloßen Versprechen des Verkäufers, die Sache zu regeln, keine feststehende Lieferverweigerung. Eine Ausnahme nach Artikel 5.233 hängt von den tatsächlich festgestellten Umständen ab. Korrigieren Sie die beanstandete Anwendung anhand der bereitgestellten Quellen und geben Sie eine inhaltliche, bedingte Antwort ohne Hinweis auf diese Korrektur.',
        'marketplace_unrepresented_lawyer_fee_entitlement' => 'KORREKTUR: Versprechen Sie einer Partei ohne Anwalt keine Verfahrensentschädigung, auch keinen Mindestbetrag ; Artikel 1022 betrifft einen Beitrag zu Anwaltskosten. Unterscheiden Sie normale Gerichtskosten, anwaltliche Vertretung und das Risiko gegnerischer Kosten. Korrigieren Sie die beanstandete Anwendung anhand der bereitgestellten Quelle ohne Hinweis auf diese Korrektur.',
        'marketplace_criminal_status_asserted' => 'KORREKTUR: Die bereitgestellten zivilrechtlichen Quellen machen eine Strafanzeige nicht zur Voraussetzung der Zivilklage, können aber weder feststellen noch ausschließen, dass der Sachverhalt eine Straftat wie Betrug ist. Sagen Sie daher nicht, dass es eine oder keine Straftat ist; überarbeiten Sie ohne Hinweis auf diese Korrektur.',
        'marketplace_fee_exception_inverted' => 'KORREKTUR: Die Ausnahmen von Artikel 1022 betreffen den Betrag (Herabsetzung oder Erhöhung durch besonders begründete Entscheidung, und den Mindestbetrag für eine unterliegende Partei mit Rechtshilfe der zweiten Linie, außer in offensichtlich unvernünftigen Fällen), nicht das Fehlen jeder Entschädigung; auch eine Überschrift oder Listenbezeichnung ist eine Aussage. Überarbeiten Sie ohne Hinweis auf diese Korrektur.',
        'marketplace_oral_notice_sufficient' => 'KORREKTUR: Die bereitgestellte Bestimmung über die Inverzugsetzung beschreibt ihren Inhalt (eine klare und eindeutige Erfüllungsforderung), nicht dass eine mündliche Inverzugsetzung genügt. Stellen Sie keine Formregel aus dem Gedächtnis auf; eine datierte schriftliche Inverzugsetzung dürfen Sie als praktischen Beweis empfehlen. Überarbeiten Sie ohne Hinweis auf diese Korrektur.',
        'marketplace_amount_indexation_asserted' => 'KORREKTUR: Die bereitgestellte Zuständigkeitsbestimmung nennt 5.000 Euro und dass der König diesen Betrag anpassen kann; sie sagt nicht, dass er jährlich automatisch indexiert wird, und nennt keinen aktuellen Betrag zu einem Stichtag. Geben Sie nur wieder, was der Text sagt. Überarbeiten Sie ohne Hinweis auf diese Korrektur.',
        'marketplace_lawyer_requirement_invented' => 'KORREKTUR: Die bereitgestellte Bestimmung sagt, dass die Parteien persönlich oder durch einen Anwalt erscheinen; sie gibt dem Richter keine Befugnis, einen Anwalt vorzuschreiben. Nennen Sie diese Befugnis nicht. Überarbeiten Sie ohne Hinweis auf diese Korrektur.',
        'marketplace_cost_exception_unrestricted' => 'KORREKTUR: Nach der bereitgestellten Kostenbestimmung trägt die unterliegende Partei die Kosten, sofern besondere Gesetze nichts anderes bestimmen, und der Richter kann die Kosten nur in den genannten Fällen verteilen; schreiben Sie nicht, dass der Richter allgemein anders entscheiden kann. Überarbeiten Sie ohne Hinweis auf diese Korrektur.',
        'marketplace_aided_party_not_losing' => 'KORREKTUR: Nach der bereitgestellten Bestimmung gilt der Mindestbetrag der Verfahrensentschädigung, wenn die unterliegende Partei Rechtshilfe der zweiten Linie erhält; nennen Sie diese Voraussetzung. Überarbeiten Sie ohne Hinweis auf diese Korrektur.',
        'marketplace_conciliation_mechanics_changed' => 'KORREKTUR: Nach der bereitgestellten Bestimmung lädt die Geschäftsstelle die Parteien auf Antrag mit einfachem Brief vor, innerhalb eines Monats an dem vom Richter bestimmten Tag und zur bestimmten Stunde zu erscheinen; schreiben Sie nicht, dass die Ladung selbst innerhalb eines Monats folgt oder der Richter unmittelbar lädt. Überarbeiten Sie ohne Hinweis auf diese Korrektur.',
        'marketplace_jurisdiction_blanket_exclusion' => 'KORREKTUR: Die bereitgestellte Zuständigkeitsbestimmung nennt 5.000 Euro als gewöhnliche Wertzuständigkeit, ausgenommen was das Gesetz dem Friedensrichter entzieht; schreiben Sie nicht, dass er für keine Forderung über 5.000 Euro zuständig ist. Überarbeiten Sie ohne Hinweis auf diese Korrektur.'
      },
      'en' => {
        'marketplace_invented_seller_refusal' => 'CORRECTION: do not turn the seller’s mere promise to sort matters out into an established refusal to deliver. Any Article 5.233 exception depends on actual established facts. Correct the flagged application using the supplied sources and give a substantive, conditional answer without mentioning this correction.',
        'marketplace_unrepresented_lawyer_fee_entitlement' => 'CORRECTION: do not promise a self-represented party a statutory lawyer-fee contribution or its minimum; Article 1022 concerns a contribution to lawyer costs. Distinguish ordinary court costs, lawyer representation and the risk of paying the opponent’s costs. Correct the flagged application using the supplied source without mentioning this correction.',
        'marketplace_criminal_status_asserted' => 'CORRECTION: the supplied civil sources do not make a criminal complaint a precondition of the civil claim, but they can neither establish nor exclude that the facts are an offence such as fraud. Do not say that it is or is not a criminal offence; rewrite without mentioning this correction.',
        'marketplace_fee_exception_inverted' => 'CORRECTION: the Article 1022 exceptions concern the amount (reduction or increase by a specially reasoned decision, and the minimum for a losing party on second-line legal aid unless the situation is manifestly unreasonable), not the absence of any contribution; a heading or list label is a claim too. Rewrite without mentioning this correction.',
        'marketplace_oral_notice_sufficient' => 'CORRECTION: the supplied provision on the formal notice describes its content (a clear and unambiguous demand for performance), not that an oral notice suffices. State no form rule from memory; a dated written notice may be recommended as practical evidence. Rewrite without mentioning this correction.',
        'marketplace_amount_indexation_asserted' => 'CORRECTION: the supplied competence provision states EUR 5,000 and that the King can adjust that amount; it does not say the amount is indexed automatically every year and gives no current amount at a reference date. State only what the text says. Rewrite without mentioning this correction.',
        'marketplace_lawyer_requirement_invented' => 'CORRECTION: the supplied provision says the parties appear in person or through a lawyer; it gives the judge no power to require a lawyer. Do not state that power. Rewrite without mentioning this correction.',
        'marketplace_cost_exception_unrestricted' => 'CORRECTION: under the supplied costs provision the losing party is ordered to pay the costs unless special laws provide otherwise, and the judge may split costs only in the listed cases; do not write that the judge may generally decide otherwise. Rewrite without mentioning this correction.',
        'marketplace_aided_party_not_losing' => 'CORRECTION: under the supplied provision the minimum procedural indemnity applies when the losing party has second-line legal aid; state that condition. Rewrite without mentioning this correction.',
        'marketplace_conciliation_mechanics_changed' => 'CORRECTION: under the supplied provision, on request, the clerk calls the parties by ordinary letter to appear within a month on a day and hour set by the judge; do not write that the summons itself follows within a month or that the judge summons directly. Rewrite without mentioning this correction.',
        'marketplace_jurisdiction_blanket_exclusion' => 'CORRECTION: the supplied competence provision states EUR 5,000 as the ordinary monetary competence, except what the law takes from the justice of the peace; do not write that he is competent for no claim above EUR 5,000. Rewrite without mentioning this correction.'
      }
    }.transform_values(&:freeze).freeze
  end
end
