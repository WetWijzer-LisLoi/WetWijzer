# frozen_string_literal: true

module LegalChatbot
  # Source-bound correction for payment-card answers. Art. VI.7/4 concerns
  # offering at least one electronic payment method; it does not establish
  # that every named card or network must be accepted.
  class PaymentAcceptanceGrounding
    NUMAC = '2013A11134'
    ARTICLE = 'VI.7/4'
    VERSION = 1

    INSTRUMENT_PATTERN = /\b(?:kaartbetaling|betaling\s+(?:per|met)\s+kaart|betalen\s+met\s+kaart|betaalkaart|bankkaart|creditcard|kredietkaart|credit\s+card|debit\s+card|payment\s+card|carte\s+(?:bancaire|de\s+cr[eé]dit)|carte\s+de\s+paiement|paiement\s+par\s+carte|payer\s+par\s+carte|kreditkarte|zahlungskarte)\b/i
    REFUSAL_PATTERN = /\b(?:weig(?:er|eren|ert)|niet\s+aanvaard(?:en)?|niet\s+accepteren|verplicht\s+aanvaarden|moet\s+aanvaarden|refus(?:er|e)|accepter|obligatoire|refuse|accept|must\s+accept|required\s+to\s+accept|ablehnen|akzeptieren|muss\s+akzeptieren)\b/i
    NL_METHOD_PATTERN = /\been\s+elektronisch\s+betaalmiddel\b/i
    FR_METHOD_PATTERN = /\bun\s+moyen\s+de\s+paiement\s+[eé]lectronique\b/i
    EN_METHOD_PATTERN = /[^.!?\n]{0,240}\bat\s+least\s+one\s+electronic\s+payment\s+method\b[^.!?\n]{0,240}[.!?]/i
    SPECIFIC_CARD_CLAIM = /(?:\b(?:elke|iedere|alle|toute?s?|jede|geen(?:\s+enkele)?|any|every|all|each|no|aucune?|specific(?:e)?|particular)\s+[^.!?\n]{0,40}(?:kaartbetaling|kaart|card|carte|paiement\s+par\s+carte|kreditkarte|karte)\b[^.!?\n]{0,80}\b(?:weig(?:er|eren|ert)|aanvaard(?:en)?|accepteren|accept|refus(?:er|e)|must|moet|doit|muss)\b|\b(?:kaartbetaling|kaart|card|carte|paiement\s+par\s+carte|kreditkarte|karte)\b[^.!?\n]{0,80}\b(?:niet\s+weigeren|cannot\s+refuse|can't\s+refuse|must\s+accept|moet\s+aanvaarden|doit\s+accepter|muss\s+akzeptieren)\b|\b(?:cannot|can't|ne\s+peut\s+pas|kan\s+niet|mag\s+niet|darf\s+nicht)\s+(?:refuse|refuser|weigeren|aanvaarden|accepter|accept)\b[^.!?\n]{0,60}(?:kaartbetaling|kaart|card|carte|paiement\s+par\s+carte|kreditkarte|karte)\b)/i
    QUALIFIED_METHOD = /\b(?:een|un(?:e)?|an|one|ein(?:e)?)[^.!?\n]{0,70}\b(?:elektronisch(?:e|es)?\s+betaal(?:middel|methode)|moyen\s+de\s+paiement\s+[eé]lectronique|electronic\s+payment\s+method|elektronische[sr]?\s+Zahlungsmittel)\b/i
    # A measured answer inserted commas and "en principe" between the modal
    # and refusal. That still asserts the same unsupported card-specific rule.
    QUALIFIED_REFUSAL_CLAIM = /\bne\s+peut(?:\s+pas)?[^.!?\n]{0,40}\brefuser\b[^.!?\n]{0,80}\b(?:paiement\s+par\s+carte|carte\s+bancaire)\b/i

    class << self
      def topic?(question)
        text = question.to_s
        text.match?(INSTRUMENT_PATTERN) && text.match?(REFUSAL_PATTERN)
      end

      def evidence(sources)
        Array(sources).each do |source|
          next unless field(source, :numac).to_s == NUMAC

          title = field(source, :article_number, :article_title).to_s
          next unless title.match?(%r{\A(?:Art(?:ikel|icle)?\.?\s*)?VI\.\s*7/4\z}i)

          language_id = field(source, :language_id)
          next unless language_id.is_a?(Integer) && [1, 2].include?(language_id)

          text = field(source, :article_text, :text, :full_text, :content).to_s
          clause = extract_method_sentence(text, language_id == 1 ? NL_METHOD_PATTERN : FR_METHOD_PATTERN)
          return { source: source, clause: clause, language_id: language_id } if clause
        end
        nil
      end

      def evaluate(answer, question, sources)
        grounded = topic?(question) && evidence(sources)
        return { applicable: false, missing_conditions: [], version: VERSION } unless grounded

        text = answer.to_s
        missing = []
        missing << 'specific_card_acceptance_claim' if text.split(/(?<=[.!?])\s+|\n/).any? { |sentence| unsafe_specific_card_claim?(sentence) }
        missing << 'payment_acceptance_source_citation' unless answer.to_s.match?(%r{\[[^\]]+\]\(/laws/#{NUMAC}#art-VI-7-4\)}i)
        { applicable: true, missing_conditions: missing.uniq, version: VERSION }
      end

      def corrective_feedback(missing_conditions, language: 'nl')
        return nil unless Array(missing_conditions).map(&:to_s).intersect?(%w[specific_card_acceptance_claim payment_acceptance_source_citation])

        {
          'nl' => 'CORRECTIE: de aangeleverde bron zegt dat een elektronisch betaalmiddel ter beschikking moet worden gesteld. Dat betekent niet automatisch dat elke specifieke kaart of kaartaanbieder moet worden aanvaard. Schrijf het antwoord opnieuw met dit onderscheid en citeer Art. VI.7/4; verzin geen regel over contante betaling of een specifieke kaart.',
          'fr' => 'CORRECTION : la source fournie exige qu’un moyen de paiement électronique soit mis à disposition. Cela ne signifie pas automatiquement que toute carte ou tout réseau particulier doit être accepté. Réécrivez la réponse en conservant cette distinction et citez l’art. VI.7/4, sans inventer une règle sur les espèces ou une carte déterminée.',
          'de' => 'KORREKTUR: Die bereitgestellte Quelle verlangt, dass ein elektronisches Zahlungsmittel zur Verfügung gestellt wird. Daraus folgt nicht automatisch, dass jede bestimmte Karte oder jedes Netzwerk akzeptiert werden muss. Schreiben Sie die Antwort mit dieser Unterscheidung neu und zitieren Sie Art. VI.7/4.',
          'en' => 'CORRECTION: the supplied source requires an electronic payment method to be made available. That does not automatically mean every specific card or network must be accepted. Rewrite with that distinction, cite Article VI.7/4, and do not invent a cash or card-specific rule.'
        }.fetch(language.to_s, nil)
      end

      def fallback(question, sources, language: 'nl')
        return nil unless topic?(question)

        grounded = evidence(sources)
        return nil unless grounded

        copy = {
          'nl' => 'De aangeleverde tekst ondersteunt alleen de regel dat een elektronisch betaalmiddel beschikbaar moet zijn. Daaruit volgt niet dat elke specifieke kaart moet worden aanvaard.',
          'fr' => 'Le texte fourni établit seulement qu’un moyen de paiement électronique doit être mis à disposition. Il ne permet pas d’en déduire que toute carte particulière doit être acceptée.',
          'de' => 'Der bereitgestellte Text belegt nur, dass ein elektronisches Zahlungsmittel angeboten werden muss. Daraus folgt nicht, dass jede bestimmte Karte akzeptiert werden muss.',
          'en' => 'The supplied text establishes only that an electronic payment method must be made available. It does not establish that every specific card must be accepted.'
        }.fetch(language.to_s, nil)
        return nil unless copy

        "#{copy}\n\n> #{grounded.fetch(:clause)}\n> — [Art. VI.7/4](/laws/#{NUMAC}#art-VI-7-4)"
      end

      private

      def unsafe_specific_card_claim?(sentence)
        return false unless sentence.match?(SPECIFIC_CARD_CLAIM) || sentence.match?(QUALIFIED_REFUSAL_CLAIM)

        # A sentence explicitly denying the broad claim is safe. Evaluate per
        # sentence so a correct qualification elsewhere cannot launder a
        # contradictory card-specific conclusion.
        if sentence.match?(/(?:niet|geen|no|not|ne\s+(?:peut|doit)\s+pas|cannot|can't|nicht|darf\s+nicht).{0,45}(?:elke|iedere|alle|toute?s?|jede|any|every|all|each|specific(?:e)?|particular|geen(?:\s+enkele)?|no|aucune?).{0,55}(?:kaartbetaling|kaart|card|carte|paiement\s+par\s+carte|kreditkarte|karte).{0,70}(?:aanvaard|accep|accept|weig|refus|must|moet|doit|muss)/i)
          return false
        end

        # The French fallback deliberately explains that the source does not
        # permit the broader card-specific conclusion. Keep this exception
        # local to that explicit evidentiary phrase; a generic "pas" must not
        # launder an unsafe claim elsewhere in an answer.
        if sentence.match?(/\bne\s+permet\s+pas\s+d['’]en\s+d[eé]duire\b.{0,100}\b(?:toute?s?|aucune?)\s+(?:carte|carte\s+particuli[eè]re)\b.{0,70}\b(?:accept[ée]e?|accepter)\b/i)
          return false
        end

        true
      end

      def extract_method_sentence(text, pattern)
        text.to_s.split(/(?<=[!?])\s+|\n/).find { |sentence| sentence.match?(pattern) }&.strip
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
