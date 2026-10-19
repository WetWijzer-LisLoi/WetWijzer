# frozen_string_literal: true

module LegalChatbot
  class MarketplaceCivilClaimGrounding
    # Five measured procedure claims of the accepted v5 Snel marketplace answer
    # (Codex 2026-10-18 07:07). Each is a rejection check for one unsupported
    # assertion shape, bound to its own sealed article body through
    # MarketplaceCivilClaimGrounding.evidence; none verifies an answer, and
    # none infers a legal power from a statute's silence. A question, a quote,
    # a denial ("de bron zegt niet dat ...") or a faithful qualified summary
    # is not the assertion.
    module ProcedureClaims
      JUDGE = '(?:(?:vrede)?rechter|judge|court|juge|Richter|Gericht)'
      ARTICLE = '(?:de\s+|the\s+|le\s+|la\s+|der\s+|das\s+)?'
      LAWYER = '(?:advocaat|advocaten|lawyer|attorney|avocat|avocats|Anwalt|Anwältin|Rechtsanwalt)'
      REQUIRE = '(?:verplicht\p{L}*|oplegt|opleggen|eist|eisen|vereist|vereisen|beveelt|requires?|orders?|impos\p{L}*|exig\p{L}*|l[\'’]exige|verlangt|verlangen|anordnet|anordnen|vorschreibt|vorschreiben)'
      NEGATION = /\b(?:geen|niet|nooit|not|no|never|pas|jamais|kein\p{L}*|nicht|nie)\b/iu
      DENIAL = /\b(?:zegt|bepaalt|stelt|vermeldt|schrijft|regelt|voorziet\s+in|staat)\s+(?:\p{L}+\s+){0,3}?niet\b|\bniet\s+dat\b|\bnergens\b|\bgeen\s+(?:bepaling|bron|regel|grond|bevoegdheid)\b|\bdoes\s+not\s+(?:say|state|provide|allow|give)\b|\bno\s+(?:provision|source|rule|power)\b|\bne\s+(?:dit|prévoit|permet|précise|donne)\s+pas\b|\bsagt\s+nicht\b|\bsieht\s+nicht\s+vor\b|\bnicht,?\s+dass\b/iu

      # 1. Article 728: parties appear in person or by lawyer; no supplied
      # text gives the judge a power to require a lawyer.
      LAWYER_UNLESS_JUDGE = /\b(?:tenzij|behalve\s+(?:als|wanneer)|unless|sauf\s+si|à\s+moins\s+que|es\s+sei\s+denn,?)\s+#{ARTICLE}#{JUDGE}\s+(?:\p{L}+\s+){0,4}?#{REQUIRE}/iu
      LAWYER_JUDGE_POWER = /\b#{JUDGE}\s+(?:kan|mag|zal|can|may|could|peut|pourra|kann|darf)\s+(?:\p{L}+\s+){0,4}?#{LAWYER}\s+(?:\p{L}+\s+){0,2}?#{REQUIRE}|\b(?:kan|mag|zal|can|may|peut|kann)\s+#{ARTICLE}#{JUDGE}\s+(?:\p{L}+\s+){0,3}?(?:een\s+|a\s+|un\s+|einen\s+)?#{LAWYER}\s+(?:\p{L}+\s+){0,2}?#{REQUIRE}/iu
      LAWYER_WORD = /\b#{LAWYER}\b/iu

      # 2. Article 1017: the losing party bears the costs "unless special
      # laws provide otherwise"; the judge may split them only in the listed
      # cases. Generic judicial discretion over that rule is not supplied.
      COSTS = /\b(?:kosten|gerechtskosten|proceskosten|costs|frais|d[ée]pens|Kosten|Gerichtskosten|Verfahrenskosten)\b/iu
      LOSING = /\b(?:in\s+het\s+ongelijk\s+gesteld\p{L}*|in\s+het\s+ongelijk\s+wordt\s+gesteld|verliez\p{L}*|verliest|verloren|losing|loser|loses|lost|succombant\p{L}*|succombe\p{L}*|perdant\p{L}*|perd|unterlieg\p{L}*|verlier\p{L}*|verliert)\b/iu
      GENERIC_DISCRETION = /\btenzij\s+de\s+(?:vrede)?rechter\s+(?:\p{L}+\s+){0,2}?anders\s+(?:beslist|oordeelt|bepaalt|beslissen)\b|\bunless\s+the\s+(?:judge|court)\s+(?:\p{L}+\s+){0,2}?(?:decides|orders|rules|determines)\s+otherwise\b|\bsauf\s+(?:si\s+le\s+juge\s+en\s+d[ée]cide\s+autrement|d[ée]cision\s+contraire\s+du\s+juge)\b|\bes\s+sei\s+denn,?\s+(?:das\s+Gericht|der\s+Richter)\s+entscheidet\s+anders\b/iu

      # 3. Article 1022: the minimum applies when the LOSING party has
      # second-line legal aid. The condition may stand in the sentence or
      # in the immediately preceding one ("Als de verkoper verliest. ...").
      AID = /\b(?:tweedelijns\p{L}*\s+juridische\s+bijstand|juridische\s+tweedelijnsbijstand|tweedelijnsbijstand|second[-\s]line\s+legal\s+aid|aide\s+juridique\s+de\s+deuxi[èe]me\s+ligne|Rechtshilfe\s+der\s+zweiten\s+Linie|juristische\s+Hilfe\s+der\s+zweiten\s+Linie)\b/iu
      MINIMUM = /\b(?:minimum\p{L}*|minimaal|minimale|minimal\p{L}*|Mindest\p{L}*)\b/iu
      MINIMUM_DENIAL = /\b(?:niet\s+(?:altijd|steeds|noodzakelijk|automatisch)|geen\s+(?:\p{L}+\s+)?minimum\p{L}*|not\s+(?:always|necessarily|automatically)|pas\s+(?:toujours|n[ée]cessairement|automatiquement)|nicht\s+(?:immer|notwendigerweise|automatisch))\b/iu
      PARTY = '(?:verkoper|koper|tegenpartij|eiser|verweerder|schuldenaar|schuldeiser|seller|buyer|opponent|claimant|defendant|vendeur|acheteur|Verkäufer|Käufer|Gegner)'
      PRONOUN = /\A(?:hij|zij|ze|die\s+partij|deze\s+partij|he|she|that\s+party|il|elle|cette\s+partie|er|sie|diese\s+Partei)\z/iu
      GENERIC_PARTIES = /\A(?:partij|partijen|party|parties|partie|parties|Partei|Parteien)\z/iu
      # An unnamed losing party; it clears only a pronoun for the aided party.
      GENERIC_LOSER = /\b(?:in\s+het\s+ongelijk\s+gestelde\s+partij|verliezende\s+partij|partij\s+die\s+(?:de\s+zaak\s+|het\s+geding\s+)?verliest|losing\s+party|party\s+that\s+loses|partie\s+(?:succombante|perdante)|unterliegenden?\s+Partei)\b/iu
      # Losing the case: the verb ends its clause ("Als de verkoper verliest.",
      # "…, dan …"), never "verliest zijn kasticket".
      LITIGATION_LOSS = /\b(?:de\s+|uw\s+|the\s+|le\s+|la\s+|der\s+|die\s+)?(#{PARTY}|hij|zij|he|she|il|elle|er|sie)\s+(?:de\s+zaak\s+|het\s+geding\s+|het\s+proces\s+|the\s+case\s+|le\s+procès\s+|den\s+Prozess\s+)?(?:verliest|verliezen|in\s+het\s+ongelijk\s+wordt\s+gesteld|loses|perd|verliert|unterliegt)(?=\s*(?:[.,;!]|\z|\s+(?:en|and|et|und|dan|then|alors)\b))/iu
      BENEFICIARY_FOR = /\b(?:voor|for|pour|für)\s+(?:de\s+|uw\s+|the\s+|le\s+|la\s+|les\s+|den\s+|die\s+)?(#{PARTY}|partij|partijen|party|parties|partie|Partei|Parteien|die\s+partij|deze\s+partij)\s+(?:met|die|with|who|avec|qui|mit|die)\b/iu
      BENEFICIARY_SUBJECT = /\b(?:als|indien|wanneer|if|when|si|wenn|falls)\s+(?:de\s+|uw\s+|the\s+|le\s+|la\s+|der\s+|die\s+)?(#{PARTY}|hij|zij|he|she|il|elle|er|sie)\s+(?:\p{L}+\s+){0,2}?(?:tweedelijns|tweedelijnsbijstand|second[-\s]line|l['’]aide|Rechtshilfe|juridische)/iu
      BENEFICIARY_PLAIN = /\b(?:de\s+|uw\s+|the\s+|le\s+|la\s+|der\s+|die\s+)?(#{PARTY})\s+(?:met|with|avec|mit)\s+(?:\p{L}+\s+){0,1}?(?:tweedelijns\p{L}*|second[-\s]line|l['’]aide|Rechtshilfe)/iu
      # "De koper is de verliezende partij": the named party that loses.
      NAMED_LOSER = /\b(?:de\s+|uw\s+|the\s+|le\s+|la\s+|der\s+|die\s+)?(#{PARTY})\s+(?:is|wordt|was|est|ist)\s+(?:de|the|la|die)\s+(?:verliezende|in\s+het\s+ongelijk\s+gestelde|losing|succombante|perdante|unterliegende)\s+(?:partij|party|partie|Partei)\b/iu
      # The losing label attached to the aided party itself.
      LOSER_DESIGNATION = '(?:in\s+het\s+ongelijk\s+gestelde|verliezende|losing|succombante|perdante|unterliegende[n]?)\s+(?:partij|party|partie|Partei)'
      LOSER_AS_BENEFICIARY = [
        /\b(?:voor|for|pour|für)\s+(?:de\s+|the\s+|la\s+|die\s+)?#{LOSER_DESIGNATION}\s+(?:met|die|with|who|avec|qui|mit)\b/iu,
        /\b#{LOSER_DESIGNATION}\s+(?:(?!#{PARTY}\b)\p{L}+\s+){0,4}?(?:tweedelijns\p{L}*|second[-\s]line|l['’]aide|Rechtshilfe)/iu,
        /\b(?:tweedelijns\p{L}*(?:\s+juridische\s+bijstand)?|second[-\s]line\s+legal\s+aid|aide\s+juridique\s+de\s+deuxi[èe]me\s+ligne|Rechtshilfe\s+der\s+zweiten\s+Linie)\s+(?:van|of|de|der)\s+(?:de\s+|the\s+|la\s+|der\s+)?(?:verliezer|loser|#{LOSER_DESIGNATION})/iu
      ].freeze

      # 4. Article 732: on a request the clerk calls the parties by ordinary
      # letter to appear within a month, on a day and hour the judge fixes.
      JUDGE_SUMMONS = /\b#{JUDGE}\s+(?:\p{L}+\s+){0,2}?(?:kan|zal|moet|roept|will|can|shall|summons|calls|convoque|peut|lädt|ruft|wird|kann)\s+(?:\p{L}+\s+){0,5}?(?:oproep\p{L}*|op\b|summon\p{L}*|call\p{L}*|convoqu\p{L}*|lad\p{L}*|vorlad\p{L}*)|\b#{JUDGE}\s+(?:\p{L}+\s+){0,2}?(?:convoque|summons|lädt\s+(?:\p{L}+\s+){0,3}?vor)\b/iu
      MONTH = /\b(?:binnen\s+(?:een|één|1)\s+maand|within\s+(?:a|one|1)\s+month|dans\s+(?:le\s+mois|un\s+d[ée]lai\s+d['’]un\s+mois)|innerhalb\s+(?:eines|1)\s+Monats)\b/iu
      CLERK = /\b(?:griffi\p{L}*|clerk|registry|greff\p{L}*|Geschäftsstelle|Kanzlei)\b/iu
      CONCILIATION_RELATION = /\b(?:oproep\p{L}*|roept|op\s+te\s+roepen|verschijn\p{L}*|verzoening\p{L}*|minnelijke|summon\p{L}*|appear\p{L}*|conciliation|convoc\p{L}*|convoqu\p{L}*|compara[iî]t\p{L}*|Ladung|lädt|vorlad\p{L}*|erschein\p{L}*|Güteverfahren|Schlichtung\p{L}*)\b/iu
      MONTH_AFTER_SUMMONS = /\b(?:binnen\s+(?:een|één|1)\s+maand\s+na\s+(?:de\s+|het\s+)?(?:oproep\p{L}*|verzoek)|within\s+(?:a|one|1)\s+month\s+(?:of|after|from)\s+the\s+(?:summons|call|request)|dans\s+le\s+mois\s+(?:de\s+la|suivant\s+la)\s+(?:convocation|demande)|innerhalb\s+eines\s+Monats\s+nach\s+der\s+(?:Ladung|Anfrage))\b/iu

      # 5. Article 590: EUR 5000 is the ordinary monetary competence "except
      # what the law takes from it"; it does not make every larger claim
      # fall outside the justice of the peace.
      BLANKET = /\b(?:niet|nooit)\s+bevoegd\b[^.!?\n]{0,80}\b(?:hoger|meer|boven)\s+(?:\p{L}+\s+){0,2}?(?:dan\s+)?(?:€\s*)?5[ .]?000|\b(?:hoger|meer|boven)\s+(?:dan\s+)?(?:€\s*)?5[ .]?000\s*(?:euro|EUR)?\b[^.!?\n]{0,60}\b(?:(?:bent|is)\s+(?:u|de\s+vrederechter)\s+niet\s+bevoegd|moet\s+u\s+naar\s+de\s+(?:rechtbank|burgerlijke))|\bnot\s+competent\b[^.!?\n]{0,60}\b(?:above|over|more\s+than|exceeding)\s+(?:€\s*|EUR\s*)?5[ ,.]?000|\bpas\s+comp[ée]tent\p{L}*\b[^.!?\n]{0,60}\b(?:sup[ée]rieur\p{L}*|plus\s+de|d[ée]pass\p{L}*)\s+(?:à\s+)?(?:€\s*)?5[ .]?000|\bnicht\s+zust[äa]ndig\b[^.!?\n]{0,60}\b(?:über|mehr\s+als|höher\s+als)\s+(?:€\s*)?5[ .]?000/iu
      CLAUSE_SPLIT = /[,;]|\s+(?:en|maar|and|but|et|mais|und|aber)\s+/iu
      EXCEPTION_CLAUSE = /\A(?:behalve|tenzij|behoudens|except|unless|sauf|à\s+moins|außer|es\s+sei\s+denn)\b/iu
      LOCAL_QUALIFIER = /\bin\s+beginsel\b|\bals\s+(?:algemene|gewone)\s+regel\b|\bop\s+grond\s+van\s+(?:het|dat|dit)\s+bedrag\b|\b(?:gewone|geldelijke)\s+bevoegdheid\b|\b(?:behalve|tenzij|behoudens)\b[^.!?\n]{0,80}\b(?:bijzondere|andere|specifieke)\s+(?:bevoegdheid\p{L}*|regel\p{L}*|bepaling\p{L}*|wet\p{L}*)|\bongeacht\s+het\s+bedrag\b|\bin\s+principle\b|\bas\s+a\s+general\s+rule\b|\bordinary\s+(?:monetary\s+)?(?:jurisdiction|competence)\b|\ben\s+principe\b|\bgrunds[äa]tzlich\b/iu

      module_function

      def missing(answer, grounded)
        # The original sentence order is kept for the one-sentence antecedent
        # of check 3; questions and quotes are never judged as assertions.
        all = MarketplaceCivilClaimGrounding.send(:sentences, answer)
        list = all.reject { |sentence| skipped?(sentence) }
        codes = []
        codes << 'marketplace_lawyer_requirement_invented' if grounded['728'] && list.any? { |sentence| lawyer_requirement?(sentence) }
        codes << 'marketplace_cost_exception_unrestricted' if grounded['1017'] && list.any? { |sentence| cost_exception?(sentence) }
        codes << 'marketplace_aided_party_not_losing' if grounded['1022'] && aided_not_losing?(all)
        codes << 'marketplace_conciliation_mechanics_changed' if grounded['732'] && list.any? { |sentence| conciliation_mechanics?(sentence) }
        codes << 'marketplace_jurisdiction_blanket_exclusion' if grounded['590'] && list.any? { |sentence| blanket_exclusion?(sentence) }
        codes
      end

      def skipped?(sentence)
        sentence.end_with?('?') || sentence.match?(/\A["“«„][\s\S]*["”»“]\z/)
      end

      # The asserted span must not be negated itself or denied just before.
      def asserted?(sentence, match)
        return false unless match
        return false if match[0].match?(NEGATION)

        !sentence[0...match.begin(0)].split(/[;:]/).last.to_s.match?(DENIAL)
      end

      def lawyer_requirement?(sentence)
        return false unless sentence.match?(LAWYER_WORD)

        asserted?(sentence, sentence.match(LAWYER_UNLESS_JUDGE)) || asserted?(sentence, sentence.match(LAWYER_JUDGE_POWER))
      end

      def cost_exception?(sentence)
        sentence.match?(COSTS) && sentence.match?(LOSING) && asserted?(sentence, sentence.match(GENERIC_DISCRETION))
      end

      # The aided party must be the party that loses the case: named as the
      # losing party, or losing the case in this sentence or the one directly
      # before it (original order), as the same party or a pronoun for it.
      # "verliest zijn kasticket" is not losing the case; another party's
      # loss does not cover the aided party (Codex 07:19).
      def aided_not_losing?(all)
        all.each_with_index.any? do |sentence, index|
          next false if skipped?(sentence) || !sentence.match?(AID) || !sentence.match?(MINIMUM)
          next false if sentence.match?(MINIMUM_DENIAL) || sentence[0, sentence.index(AID) || 0].match?(DENIAL)
          next false if LOSER_AS_BENEFICIARY.any? { |pattern| sentence.match?(pattern) }

          beneficiary = beneficiary(sentence)
          loser = litigation_loser(sentence)
          loser ||= litigation_loser(all[index - 1]) if index.positive? && !skipped?(all[index - 1])
          !same_party?(loser, beneficiary)
        end
      end

      # A party that loses the case: "Als de verkoper verliest", "De koper is
      # de verliezende partij", or (:generic) an unnamed losing party.
      def litigation_loser(sentence)
        named = sentence.match(NAMED_LOSER) || sentence.match(LITIGATION_LOSS)
        return named[1].downcase if named
        return :generic if sentence.match?(GENERIC_LOSER)

        nil
      end

      def beneficiary(sentence)
        [BENEFICIARY_FOR, BENEFICIARY_SUBJECT, BENEFICIARY_PLAIN].each do |pattern|
          match = sentence.match(pattern)
          return match[1].downcase if match
        end
        nil
      end

      # The aided party must be identified and be the loser: the same named
      # party, or a pronoun for a party just shown to lose. An unparsed
      # beneficiary, a different party or a generic loser for a named
      # beneficiary does not prove the losing condition (Codex 07:43).
      def same_party?(loser, beneficiary)
        return false if loser.nil? || beneficiary.nil?
        return true if PRONOUN.match?(beneficiary)
        return false if loser == :generic || GENERIC_PARTIES.match?(beneficiary)

        loser == beneficiary
      end

      # Only a summons, appearance or conciliation sentence states Article
      # 732's mechanics; a document delivered "within a month" does not.
      def conciliation_mechanics?(sentence)
        return false unless sentence.match?(CONCILIATION_RELATION)
        return true if asserted?(sentence, sentence.match(MONTH_AFTER_SUMMONS))

        sentence.match?(MONTH) && !sentence.match?(CLERK) && asserted?(sentence, sentence.match(JUDGE_SUMMONS))
      end

      # The claim is itself negative ("niet bevoegd"), so only a denial
      # before it, or a qualifier of its own clause (or of a following
      # "behalve/tenzij" clause), takes it back; a qualifier of another
      # statement in the same sentence does not (Codex 07:19).
      def blanket_exclusion?(sentence)
        match = sentence.match(BLANKET)
        return false unless match
        return false if sentence[0...match.begin(0)].split(/[;:]/).last.to_s.match?(DENIAL)

        clauses = sentence.split(CLAUSE_SPLIT)
        position = 0
        own = clauses.index do |clause|
          start = sentence.index(clause, position) || position
          position = start + clause.length
          match.begin(0) < position
        end.to_i
        scope = [clauses[own]] + clauses[(own + 1)..].to_a.take_while { |clause| clause.strip.match?(EXCEPTION_CLAUSE) }
        scope.none? { |clause| clause.match?(LOCAL_QUALIFIER) }
      end
    end
  end
end
