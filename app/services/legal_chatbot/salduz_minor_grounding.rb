# frozen_string_literal: true

module LegalChatbot
  # Source-bound check for the narrow minor/Salduz failure mode. This class
  # does not decide arbitrary criminal-procedure questions: it only rejects a
  # claim that a minor may waive the lawyer-presence safeguard when the
  # retrieved Art. 47bis source supports the contrary, and supplies a safe
  # source-bound correction.
  class SalduzMinorGrounding
    NUMAC = '1808111701'
    ARTICLE = '47bis'
    VERSION = 2

    MINOR_PATTERN = /\b(?:minderjarig(?:e|en)?|mineur(?:e)?s?|minor(?:s)?|minderj[aä]hrig(?:e[rsnm]?)?)\b/i
    INTERROGATION_PATTERN = /\b(?:verhoor|politieverhoor|verhoren|verhoord|interrogat(?:ie|ion)|audition|interrogatoire|entendu|question(?:ing|ed)?|vernehmung(?:en)?|vernommen|verh[oö]r)\b/i
    LAWYER_PATTERN = /\b(?:advocaat|advocaten|avocat(?:e)?s?|lawyer(?:s)?|counsel|anwalt(?:s)?|rechtsbijstand)\b/i
    NL_PRESENCE_CLAUSE = /Het verhoor van (?:de|een) minderjarige kan (?:enkel gebeuren|slechts plaatsvinden) in aanwezigheid van zijn advocaat\./i
    FR_PRESENCE_CLAUSE = /L['’]audition du mineur ne peut avoir lieu qu['’]en présence de son avocat\./i
    WAIVER_PATTERN = /\b(?:afstand\s+doen|afstand\s+van|waive|waives|waiver|renonc(?:er|e|ement)|verzicht|verzichten|verzichtet|verzichten)\b/i
    WITHOUT_LAWYER_PATTERN = /\b(?:zonder\s+(?:een\s+)?advocaat|sans\s+avocat|without\s+(?:a\s+)?lawyer|ohne\s+(?:einen\s+)?anwalt)\b/i
    LEGAL_ASSISTANCE_PATTERN = /
      \b(?:
        rechtsbijstand|advoca(?:at|ten)bijstand|juridische\s+bijstand|verplichte\s+bijstand|
        (?:bijstand|aanwezigheid)\s+(?:van|door)\s+(?:een|de|zijn|haar)?\s*advocaat|
        assistance\s+(?:juridique|obligatoire)|présence\s+(?:d['’]un|de\s+son|de\s+l['’])\s*avocat|
        (?:legal|mandatory)\s+(?:legal\s+)?assistance|lawyer\s+(?:assistance|presence)|
        presence\s+of\s+(?:a|the|their|his|her)\s+lawyer|
        anwaltlich\w*\s+(?:beistand|hilfe|anwesenheit)|anwesenheit\s+(?:eines|des|seines)\s+anwalts
      )\b
    /ix
    ABSOLUTE_PATTERN = /\b(?:absolute|absolut(?:e|ement)?|absolu(?:e|es|ment)?|absoluut|ausnahmslos)\b/i
    NO_EXCEPTIONS_PATTERN = /
      \b(?:
        (?:no|without)\s+(?:any\s+)?exceptions?|
        (?:does|do)\s+not\s+(?:provide|allow|recognize)\s+(?:any\s+)?exceptions?|
        geen\s+(?:enkele\s+)?uitzondering(?:en)?|zonder\s+uitzondering(?:en)?|
        aucune?\s+exceptions?|sans\s+exceptions?|ne\s+(?:prévoit|permet|comporte)\s+(?:pas\s+)?(?:d['’])?exceptions?|
        keine\w*\s+ausnahme(?:n)?|ohne\s+ausnahme(?:n)?|ausnahmslos
      )\b
    /ix
    QUESTIONING_SCOPE_PATTERN = /
      \b(?:
        als\s+(?:minderjarige\s+)?verdachte|minderjarige\s+verdachte|
        (?:in|volgens)\s+(?:deze|die|de\s+(?:aangeleverde|geraadpleegde))\s+(?:bepaling|tekst)|
        (?:en\s+tant\s+que|en\s+qualité\s+de)\s+(?:mineur\s+)?suspect|mineur\s+suspect|
        (?:visée?|régi[ée]?|couverte?)\s+par\s+(?:cette\s+disposition|la\s+présente\s+disposition|la\s+disposition\s+fournie)|
        (?:dans|selon)\s+(?:cette\s+disposition|la\s+présente\s+disposition|la\s+disposition\s+fournie)|
        (?:as\s+(?:a|the)\s+(?:minor\s+)?suspect|minor\s+suspect)|
        (?:covered|addressed|governed|regulated)\s+by\s+(?:(?:the|this|that|supplied|consulted|provided)\s+){0,3}(?:article|provision)|
        (?:in|under|within)\s+(?:this|that|the\s+(?:supplied|consulted|provided))\s+(?:article|provision)|
        als\s+(?:minderjährig\w*\s+)?beschuldigt\w*|minderjährig\w*\s+beschuldigt\w*|
        in\s+dieser\s+bestimmung|(?:dort|hier)\s+geregelt\w*
      )\b
    /ix

    class << self
      def topic?(question)
        text = question.to_s
        text.match?(MINOR_PATTERN) && text.match?(INTERROGATION_PATTERN) &&
          (text.match?(LAWYER_PATTERN) || text.match?(/\b(?:salduz|politie|police|polizei)\b/i))
      end

      def evidence(sources)
        Array(sources).each do |source|
          next unless field(source, :numac).to_s == NUMAC

          title = field(source, :article_number, :article_title).to_s
          next unless title.match?(/\A\s*(?:Art(?:ikel|icle)?\.?\s*)?47bis\.?\s*\z/i)

          language_id = field(source, :language_id)
          next unless language_id.is_a?(Integer) && [1, 2].include?(language_id)

          text = field(source, :article_text, :text, :full_text, :content).to_s
          clause = language_id == 1 ? text[NL_PRESENCE_CLAUSE] : text[FR_PRESENCE_CLAUSE]
          return { source: source, clause: clause, language_id: language_id } if clause
        end
        nil
      end

      def evaluate(answer, question, sources)
        grounded = topic?(question) && evidence(sources)
        return { applicable: false, missing_conditions: [], version: VERSION } unless grounded

        text = answer.to_s
        missing = []
        missing << 'minor_waiver_claim' if affirmative_minor_waiver?(text)
        missing << 'minor_without_lawyer_claim' if affirmative_minor_without_lawyer?(text)
        missing << 'minor_unqualified_all_questioning_claim' if unqualified_all_questioning?(text)
        missing << 'salduz_minor_source_citation' unless answer.to_s.match?(%r{\]\(/laws/#{NUMAC}(?:\?language_id=[12])?#art-47bis\)}i)
        { applicable: true, missing_conditions: missing.uniq, version: VERSION }
      end

      def corrective_feedback(missing_conditions, language: 'nl')
        codes = Array(missing_conditions).map(&:to_s) & %w[minor_waiver_claim minor_without_lawyer_claim minor_unqualified_all_questioning_claim salduz_minor_source_citation]
        return nil if codes.empty?

        {
          'nl' => 'CORRECTIE: de aangeleverde bron ondersteunt geen vrijwillige afstand door een minderjarige van deze advocaatwaarborg. Schrijf het antwoord opnieuw en zeg alleen wat uit Art. 47bis blijkt over de vereiste bijstand/aanwezigheid van een advocaat bij het daarin bedoelde verhoor. Gebruik de bronlink en verzin geen uitzondering. Reikwijdte: veralgemeen deze bepaling niet tot elk verhoor van een minderjarige, ongeacht of die verdachte, getuige of slachtoffer is. Noem de bijstand niet absoluut of zonder uitzonderingen voor alle verhoren; beperk de uitspraak tot de verhoorsituatie die de aangeleverde bepaling regelt.',
          'fr' => 'CORRECTION : la source fournie ne permet pas d’affirmer qu’un mineur peut renoncer volontairement à cette garantie d’avocat. Réécrivez la réponse en vous limitant à l’art. 47bis fourni et à l’assistance/la présence de l’avocat prévue pour l’audition qu’il vise. Citez la source et n’inventez aucune exception. Portée : ne généralisez pas cette disposition à toute audition d’un mineur, qu’il soit suspect, témoin ou victime. Ne présentez pas l’assistance comme absolue ou sans exception pour toutes les auditions ; limitez l’affirmation à la situation régie par la disposition fournie.',
          'de' => 'KORREKTUR: Die bereitgestellte Quelle erlaubt keine Aussage, dass ein Minderjähriger freiwillig auf diese anwaltliche Garantie verzichten kann. Schreiben Sie die Antwort anhand des bereitgestellten Art. 47bis neu und erfinden Sie keine Ausnahme. Geltungsbereich: Verallgemeinern Sie diese Bestimmung nicht auf jede Vernehmung eines Minderjährigen als Beschuldigter, Zeuge oder Opfer. Bezeichnen Sie den Beistand nicht als absolut oder ausnahmslos für alle Vernehmungen; begrenzen Sie die Aussage auf die von der bereitgestellten Bestimmung geregelte Vernehmungssituation.',
          'en' => 'CORRECTION: the supplied source does not support saying that a minor may voluntarily waive this lawyer safeguard. Rewrite only what the supplied Art. 47bis establishes about the required lawyer assistance/presence, cite the source, and do not invent an exception. Scope: do not generalize this provision to every interview, regardless of whether the minor is a suspect, witness or victim. Do not describe assistance as absolute or without exceptions for all interviews; limit the claim to the questioning situation covered by the supplied article.'
        }.fetch(language.to_s, nil)
      end

      def fallback(question, sources, language: 'nl')
        return nil unless topic?(question)

        grounded = evidence(sources)
        return nil unless grounded

        copy = {
          'nl' => 'De geraadpleegde tekst van artikel 47bis bevat de onderstaande advocaatwaarborg voor het daarin bedoelde verhoor van een minderjarige. Raadpleeg de volledige actuele bepaling om te bepalen of deze verhoorsituatie van toepassing is; dit is geen algemene regel voor elk contact met de politie.',
          'fr' => 'Le texte consulté de l’article 47bis contient la garantie suivante pour l’audition du mineur visée par cette disposition. Consultez le texte complet et actuel pour déterminer si cette situation d’audition est applicable ; il ne s’agit pas d’une règle générale pour tout contact avec la police.',
          'de' => 'Der konsultierte Art. 47bis enthält die folgende anwaltliche Garantie für die dort geregelte Vernehmung eines Minderjährigen. Prüfen Sie anhand der vollständigen aktuellen Bestimmung, ob diese Vernehmungssituation vorliegt; dies ist keine allgemeine Regel für jeden Polizeikontakt.',
          'en' => 'The consulted Article 47bis contains the following lawyer safeguard for the minor’s questioning addressed by that provision. Check the complete current article to determine whether that questioning situation applies; this is not a general rule for every police contact.'
        }.fetch(language.to_s, nil)
        return nil unless copy

        "#{copy}\n\n> #{grounded.fetch(:clause)}\n> — [Art. 47bis](/laws/#{NUMAC}#art-47bis)"
      end

      private

      # The observed German response asserted that the safeguard applies to
      # all interviews irrespective of their nature. The supplied suspect
      # provision alone cannot establish that broader witness/victim claim.
      def unqualified_all_questioning?(text)
        claims = text.split(/(?<=[.!?])\s+|\n+/)
        claims.each_with_index.any? do |claim, index|
          universal = claim.match?(/\b(?:alle|elk(?:e)?|ieder(?:e)?|all|every|toutes?|jed(?:e[rsnm]?)?)\s+(?:[^.!?\n]{0,20}\s+)?#{INTERROGATION_PATTERN.source}/i)
          unrestricted = claim.match?(/\b(?:ongeacht|regardless|irrespective|ind[eé]pendamment|unabh[aä]ngig)\b/i)
          absolute_stage = claim.match?(/\brequirement\s+is\s+absolute\b.{0,80}\b(?:regardless|irrespective)\s+of\s+the\s+stage\b/i)
          next false if negated_universal_claim?(claim)
          next true if (universal && unrestricted) || absolute_stage

          previous = index.positive? ? claims[index - 1] : ''
          questioning_context = minor_lawyer_questioning_claim?(claim) || minor_lawyer_questioning_claim?(previous)
          no_exceptions = questioning_context && claim.match?(NO_EXCEPTIONS_PATTERN)
          absolute_assistance = claim.match?(LEGAL_ASSISTANCE_PATTERN) && claim.match?(ABSOLUTE_PATTERN)
          next false unless no_exceptions || absolute_assistance

          # A standalone anaphoric conclusion can inherit the immediately
          # preceding scope, not a remote qualified paragraph. A new claim
          # about minors/questioning must carry its own limiting scope.
          inherited_scope = claim.length <= 240 && !claim.match?(MINOR_PATTERN) &&
                            !claim.match?(INTERROGATION_PATTERN) && previous.match?(QUESTIONING_SCOPE_PATTERN)
          !claim.match?(QUESTIONING_SCOPE_PATTERN) && !inherited_scope
        end
      end

      def minor_lawyer_questioning_claim?(claim)
        claim.match?(MINOR_PATTERN) && claim.match?(INTERROGATION_PATTERN) &&
          (claim.match?(LAWYER_PATTERN) || claim.match?(LEGAL_ASSISTANCE_PATTERN))
      end

      def negated_universal_claim?(claim)
        claim.match?(/\b(?:niet|not|pas|nicht)\s+(?:voor\s+|for\s+|pour\s+|f[uü]r\s+)?(?:alle|elk(?:e)?|all|every|toutes?|jede)\b/i) ||
          claim.match?(/\b(?:not|niet|pas|nicht)\s+(?:(?:an|een|une?|eine?)\s+)?#{ABSOLUTE_PATTERN.source}/i) ||
          claim.match?(/\b(?:no|geen|aucune?|kein\w*)\s+(?:basis|grond|base|fondement|grundlage)\b.{0,100}#{ABSOLUTE_PATTERN.source}/i) ||
          claim.match?(/\b(?:cannot|can['’]t|does\s+not|do\s+not)\s+(?:establish|mean|conclude|show|prove|say|claim)\b.{0,100}#{NO_EXCEPTIONS_PATTERN}/i)
      end

      def affirmative_minor_waiver?(text)
        text.split(/(?<=[.!?])\s+|\n+/).any? do |claim|
          claim.match?(MINOR_PATTERN) && claim.match?(WAIVER_PATTERN) &&
            !claim.match?(/(?:kan\s+niet|cannot|can['’]t|may\s+not|ne\s+peut\s+pas|ne\s+peuvent\s+pas|darf\s+nicht|kann\s+nicht).{0,80}#{WAIVER_PATTERN.source}/i)
        end
      end

      def affirmative_minor_without_lawyer?(text)
        text.split(/(?<=[.!?])\s+|\n+/).any? do |claim|
          claim.match?(MINOR_PATTERN) && claim.match?(WITHOUT_LAWYER_PATTERN) &&
            !claim.match?(/(?:niet|geen|cannot|can't|ne\s+peut\s+pas|nicht|darf\s+nicht).{0,80}#{WITHOUT_LAWYER_PATTERN.source}/i)
        end
      end

      def field(source, *keys)
        keys.each do |key|
          if source.respond_to?(:[])
            [key, key.to_s].each do |candidate|
              value = source[candidate]
              return value unless value.nil?
            rescue IndexError, TypeError, NameError
              nil
            end
          end
          return source.public_send(key) if source.respond_to?(key) && !source.public_send(key).nil?
        end
        nil
      end
    end
  end
end
