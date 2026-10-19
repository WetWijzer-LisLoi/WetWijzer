# frozen_string_literal: true

# Extracted from LegalChatbotService (Product Evolution Target #1)
# Language detection, follow-up question handling, and conversation expansion
module LegalChatbot
  module LanguageDetection
    extend ActiveSupport::Concern

    ANSWER_LANGUAGE_NAMES = {
      'nl' => %w[dutch nederlands néerlandais neerlandais niederländisch niederlandisch],
      'fr' => %w[french frans français francais französisch franzosisch],
      'de' => %w[german duits allemand deutsch],
      'en' => %w[english engels anglais englisch]
    }.freeze
    ANSWER_LANGUAGE_NAME_PATTERN = ANSWER_LANGUAGE_NAMES.values.flatten.sort_by { |name| -name.length }.map { |name| Regexp.escape(name) }.join('|').freeze
    ANSWER_LANGUAGE_REQUEST = /(?:\A|[.!?;,\n])\s*
      (?:(?:please|graag|bitte|veuillez|merci\s+de|svp)\s+)*
      (?:(?:(?:can|could|would|will)\s+you|kun(?:t)?\s+(?:u|je)|kan\s+(?:u|je)|pouvez-vous|peux-tu|können\s+Sie|kannst\s+du)\s+)?
      (?:(?:please|graag|bitte)\s+)*
      (?:answer|respond|reply|write|explain|antwoord(?:t|en)?|reageer|schrijf|geef\s+(?:een\s+)?antwoord|leg\s+(?:dit|het)\s+uit|répond(?:ez|s|re)|rédig(?:ez|e|er)|expliquez|écrivez|antwort(?:e|en|et)|schreib(?:e|en)|erklär(?:e|en))\b
      (?<modifiers>[^.!?;,\n]{0,48}?)\b(?:in|en|auf)\s+(?:het\s+)?(?<language>#{ANSWER_LANGUAGE_NAME_PATTERN})\b
    /ix
    ANSWER_LANGUAGE_SHORT_REQUEST = /(?:\A|[.!?;\n])\s*(?:in\s+(?:het\s+)?|en\s+|auf\s+)?
      (?<language>#{ANSWER_LANGUAGE_NAME_PATTERN})\s*,?\s*(?:please|graag|bitte|svp|s['’]il\s+vous\s+plaît)\b/ix
    INTERNATIONAL_LANGUAGE_EXCEPTION = "EN/INT INPUT-LANGUAGE EXCEPTION: If the user's own question prose is genuinely written outside Dutch, French, German and English, respond in that prose language, including headings and closing guidance. This exception does not apply to source quotations, pasted evidence, or a request for an unsupported answer language. For supported languages and ambiguous short follow-ups, keep the resolved answer language. Preserve exact source quotations and citation labels in their original language."

    # Only a direct request in the user's prose overrides the configured site.
    # Pasted evidence and quoted instructions never select an answer language.
    def self.requested_answer_language(question)
      prose = detection_prose(question)
      requests = [ANSWER_LANGUAGE_REQUEST, ANSWER_LANGUAGE_SHORT_REQUEST].flat_map do |pattern|
        prose.to_enum(:scan, pattern).filter_map do
          match = Regexp.last_match
          next if match.names.include?('modifiers') && match[:modifiers].match?(/\b(?:not|niet|pas|nicht|why|whether|waarom|pourquoi|warum)\b/i)

          code = ANSWER_LANGUAGE_NAMES.find { |_language, names| names.include?(match[:language].downcase) }&.first
          [match.begin(0), code] if code
        end
      end
      requests.max_by(&:first)&.last
    end

    def self.detection_prose(question)
      question.to_s.gsub(/```.*?```/m, ' ')
              .gsub(/~~~.*?~~~/m, ' ')
              .gsub(/^\s*>.*$/, ' ')
              .gsub(/`[^`\n]*`/, ' ')
              .gsub(/"(?:\\.|[^"\\])*"|“[^”]*”|„[^“]*“|«[^»]*»|‘[^’]*’/m, ' ')
              .gsub(/(?<!\p{L})'(?:\\.|[^'\\])*'(?!\p{L})/m, ' ')
              .gsub(%r{https?://\S+}, ' ')
    end

    FOLLOW_UP_RENTAL_PATTERNS = {
      'huur' => /\b(?:huur\p{L}*|verhuur\p{L}*)\b/,
      'locataire' => /\blocataires?\b/,
      'bail' => /\b(?:bail|baux|bailleurs?|loyers?)\b/,
      'rent' => /\b(?:rent(?:s|ed|ing|al|als)?|tenants?|landlords?|leas(?:e[ds]?|ing)|miet\p{L}*|vermiet\p{L}*)\b/
    }.freeze
    FOLLOW_UP_EMPLOYMENT_CONTEXT = /\b(?:employment|employers?|employees?|arbeid\p{L}*|werkgevers?|werknemers?|employeurs?|salarié\p{L}*|travailleurs?|contrats?\s+de\s+travail|arbeits\p{L}*|arbeitgeber\p{L}*|arbeitnehmer\p{L}*)\b/
    FOLLOW_UP_EMPLOYMENT_CONTRACT = /\b(?:contract\p{L}*|arbeidscontract\p{L}*|arbeidsovereenkomst\p{L}*|contrats?\s+de\s+travail|arbeitsvertr\p{L}*)\b/

    # Share topic selection with the German delivery path. Explicit rental
    # context must win over ambiguous notice/contract keywords, and "parent"
    # must not match the English rental keyword. Keep the established topic
    # lists; rent supplies their existing EN/DE equivalent when needed.
    def self.follow_up_suggestion_topic(question, suggestions_map, language: nil)
      text = question.to_s.downcase.gsub(/\s+/, ' ')
      rental_topic = FOLLOW_UP_RENTAL_PATTERNS.find { |keyword, pattern| suggestions_map.key?(keyword) && text.match?(pattern) }&.first
      if rental_topic
        return 'rent' if language && !suggestions_map.fetch(rental_topic).key?(language) && suggestions_map['rent']&.key?(language)

        return rental_topic
      end

      suggestions_map.each_key do |keyword|
        next if keyword == '_default'

        matched = case keyword
                  when 'contract'
                    text.match?(FOLLOW_UP_EMPLOYMENT_CONTEXT) && text.match?(FOLLOW_UP_EMPLOYMENT_CONTRACT)
                  when 'rent', 'huur', 'locataire', 'bail'
                    false # Rental keywords were checked with word boundaries above.
                  when 'vol'
                    text.match?(/\bvol\b/)
                  else
                    text.include?(keyword)
                  end
        return keyword if matched
      end

      '_default'
    end

    # Detect question language (en, fr, nl, de) based on common words
    def detect_question_language(question, fallback: @language, previous_question: nil)
      # Detect the user's prose, not a pasted contract, source quote or code.
      # The original question/evidence is never changed by this normalization.
      question = language_detection_prose(question)
      # English indicators - expanded list
      en_words = %w[what how when where why which who can may must should would could have has been the and for with from is an a are do does
                    did will about my your their this that these those it if or but not any all some i we you]
      # French indicators
      fr_words = %w[quel quelle quand comment pourquoi combien est-ce que puis-je ai-je le la les des une un pour avec dans sur je suis mon
                    ma mes et ce cette ces vous votre nos qui sont dois peut faut ou]
      # Dutch indicators - expanded with common Dutch words
      nl_words = %w[wat hoe wanneer waar waarom welke wie kan mag moet zou heb heeft zijn mijn het de een van voor met bij ik ben dit dat
                    deze die bepaalde tijd werk dagen jaren maanden hoeveel welk en wij u onze]
      # German indicators - EXPANDED with German-exclusive words not shared with Dutch
      de_words = %w[wann warum kann darf muss soll würde könnte habe hat mein das der eine für dies dieser ist und auch nicht aber wenn dann
                    oder noch sehr ich bin wir sie ihr uns euch ihm ihr ihnen nach bei aus zu von dem den des seiner ihrer zwischen
                    viele bezahlte pro jahr woche stunden tage arbeiten wohnung recht anspruch was wie]

      words = question.downcase.scan(/\p{L}+(?:[-'’]\p{L}+)*/)

      en_count = words.count { |w| en_words.include?(w) }
      fr_count = words.count { |w| fr_words.include?(w) }
      nl_count = words.count { |w| nl_words.include?(w) }
      de_count = words.count { |w| de_words.include?(w) }

      # English boosters - legal terms and common patterns
      if question.downcase =~ /\b(employment|dismissal|vacation|salary|employer|employee|rights|entitled|allowed|notice|period|leave|maternity|paternity|pension|insurance|tax|rent|tenant|landlord|divorce|custody|inheritance|company|director|shareholder|consumer|warranty|criminal|fine|prison|privacy)\b/
        en_count += 2
      end
      if question.downcase =~ /\b(i am|i'm|i have|i need|i want|my rights|at home|how long|how much|how many|am i|can i|may i|do i|does the|is it|is there|are there)\b/
        en_count += 1
      end

      # French boosters - legal terms and common patterns
      if question.downcase =~ /\b(licenciement|préavis|congé|employeur|salarié|pension|retraite|chômage|divorce|garde|succession|société|administrateur|consommateur|garantie|loyer|locataire|propriétaire|amende|prison)\b/
        fr_count += 2
      end
      fr_count += 1 if question.downcase =~ /\b(je suis|j'ai|je veux|mes droits|est-ce que|puis-je|ai-je|combien de|quelle est|quelles sont|y a-t-il)\b/

      # Dutch boosters - legal terms (less needed as fallback, but helps accuracy)
      if question.downcase =~ /\b(arbeidsovereenkomst|opzegtermijn|ontslag|werkgever|werknemer|vakantie|pensioen|werkloosheid|echtscheiding|voogdij|erfenis|vennootschap|bestuurder|consument|garantie|huur|huurder|verhuurder|boete|gevangenis)\b/
        nl_count += 2
      end
      nl_count += 1 if question.downcase =~ /\b(ik ben|ik heb|ik wil|mijn rechten|hoeveel dagen|hoe lang|mag ik|kan ik|moet ik|heb ik recht)\b/

      # Umlauts also occur in names quoted in non-German questions. Treat
      # them as supporting evidence, not stronger than the user's prose.
      de_count += 1 if question =~ /[äöüÄÖÜß]/

      # German legal terms
      if question.downcase =~ /\b(arbeitsvertrag|kündigung|kündigungsfrist|urlaub|urlaubstage|gehalt|arbeitgeber|arbeitnehmer|rechte|anspruch|frist|mutterschutz|elternzeit|rente|versicherung|steuer|miete|mieter|vermieter|scheidung|sorgerecht|erbschaft|gesellschaft|geschäftsführer|verbraucher|strafe|gefängnis|mindestlohn|gmbh|belgien)\b/
        de_count += 3
      end

      # German phrases - EXPANDED
      if question.downcase =~ /\b(ich bin|ich habe|ich will|ich muss|ich kann|meine rechte|wie lange|wie viel|wie viele|darf ich|kann ich|muss ich|habe ich|nach \d+ jahr|pro jahr|pro woche|bezahlte urlaubstage|in belgien|ohne grund)\b/
        de_count += 2
      end

      # German question starters - strong indicators
      de_count += 2 if question.downcase =~ /^(was |wie |wann |warum |kann |darf |muss |bin ich|habe ich)/

      # A one-word follow-up such as "Why?" or "Waarom?" is a deliberate
      # language signal. Shared tokens ("Wie?", "Contract?", "BV?") remain
      # ambiguous and inherit the preceding user turn instead.
      single_word = words.one? ? words.first : nil
      en_count += 2 if %w[what how why when where which who].include?(single_word)
      nl_count += 2 if %w[wat hoe waarom wanneer waar welke hoeveel].include?(single_word)
      fr_count += 2 if %w[quoi pourquoi quand combien].include?(single_word)
      de_count += 2 if %w[was wann warum].include?(single_word)

      # Compare all four scores. The previous French-first branch could win
      # even when English evidence was much stronger; ambiguous shared words
      # must not force a switch away from the conversation/interface language.
      scores = { en: en_count, fr: fr_count, nl: nl_count, de: de_count }
      ranked = scores.sort_by { |_language, score| -score }
      return ranked.first.first if ranked.first.last >= 2 && ranked.first.last > ranked[1].last

      if previous_question.present?
        requested = LanguageDetection.requested_answer_language(previous_question)
        return requested.to_sym if requested

        return detect_question_language(previous_question, fallback: fallback)
      end

      %w[nl fr de en].include?(fallback.to_s) ? fallback.to_sym : :nl
    end

    def language_detection_prose(question)
      LanguageDetection.detection_prose(question)
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

    # Generate follow-up suggestions based on detected keywords in question
    def generate_follow_up_suggestions(question)
      question_lower = question.downcase

      # Detect question language for suggestions
      lang_key = @resolved_answer_language&.to_sym || detect_question_language(question_lower)

      # FOLLOW_UP_SUGGESTIONS is defined in CoreLawMappings (peer module)
      suggestions_map = self.class::FOLLOW_UP_SUGGESTIONS

      topic = LanguageDetection.follow_up_suggestion_topic(question_lower, suggestions_map, language: lang_key)
      suggestions = suggestions_map.fetch(topic)
      suggestions[lang_key] || suggestions[:nl]
    end
  end
end
