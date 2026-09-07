# frozen_string_literal: true

# Extracted from LegalChatbotService (Product Evolution Target #1)
# Language detection, follow-up question handling, and conversation expansion
module LegalChatbot
  module LanguageDetection
    extend ActiveSupport::Concern

    # Detect question language (en, fr, nl, de) based on common words
    def detect_question_language(question)
      # English indicators - expanded list
      en_words = %w[what how when where why which who can may must should would could have has been the and for with from is an a are do does
                    did will about my your their this that these those it if or but not any all some]
      # French indicators
      fr_words = %w[quel quelle quand comment pourquoi combien est-ce que puis-je ai-je le la les des une un pour avec dans sur je suis mon
                    ma mes]
      # Dutch indicators - expanded with common Dutch words
      nl_words = %w[wat hoe wanneer waar waarom welke wie kan mag moet zou heb heeft zijn mijn het de een van voor met bij ik ben dit dat
                    deze die bepaalde tijd werk contract dagen jaren maanden hoeveel welk]
      # German indicators - EXPANDED with German-exclusive words not shared with Dutch
      de_words = %w[wann warum kann darf muss soll würde könnte habe hat mein das der eine für dies dieser ist und auch nicht aber wenn dann
                    oder noch sehr ich bin wir sie ihr uns euch ihm ihr ihnen nach bei aus zu von dem den des seiner ihrer zwischen
                    viele bezahlte pro jahr woche stunden tage arbeiten wohnung recht anspruch]

      words = question.downcase.gsub(/[?!.,]/, '').split(/\s+/)

      en_count = words.count { |w| en_words.include?(w) }
      fr_count = words.count { |w| fr_words.include?(w) }
      nl_count = words.count { |w| nl_words.include?(w) }
      de_count = words.count { |w| de_words.include?(w) }

      # English boosters - legal terms and common patterns
      if question.downcase =~ /\b(employment|contract|dismissal|vacation|salary|employer|employee|rights|entitled|allowed|notice|period|leave|maternity|paternity|pension|insurance|tax|rent|tenant|landlord|divorce|custody|inheritance|company|director|shareholder|consumer|warranty|criminal|fine|prison|privacy|gdpr)\b/
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

      # German boosters - STRENGTHENED
      # Umlauts are STRONG German indicators (+4 instead of +3)
      de_count += 4 if question =~ /[äöüÄÖÜß]/

      # German legal terms
      if question.downcase =~ /\b(arbeitsvertrag|kündigung|kündigungsfrist|urlaub|urlaubstage|gehalt|arbeitgeber|arbeitnehmer|rechte|anspruch|frist|mutterschutz|elternzeit|rente|versicherung|steuer|miete|mieter|vermieter|scheidung|sorgerecht|erbschaft|gesellschaft|geschäftsführer|verbraucher|garantie|strafe|gefängnis|mindestlohn|gmbh|belgien)\b/
        de_count += 3
      end

      # German phrases - EXPANDED
      if question.downcase =~ /\b(ich bin|ich habe|ich will|ich muss|ich kann|meine rechte|wie lange|wie viel|wie viele|darf ich|kann ich|muss ich|habe ich|nach \d+ jahr|pro jahr|pro woche|bezahlte urlaubstage|in belgien|ohne grund)\b/
        de_count += 2
      end

      # German question starters - strong indicators
      de_count += 2 if question.downcase =~ /^(was |wie |wann |warum |kann |darf |muss |bin ich|habe ich)/

      # Return detected language - Dutch/French are primary (Belgian law app)
      # German detection LOWERED threshold: now requires 2+ and more than Dutch (not 2x)
      if fr_count > nl_count && fr_count >= 2
        :fr
      elsif en_count > fr_count && en_count > nl_count && en_count >= 2
        :en
      elsif de_count >= 2 && de_count > nl_count && de_count > fr_count
        :de # German if clear evidence (2+ German indicators and more than Dutch/French)
      else
        # Default to Dutch for Belgian law context
        @language == 'fr' ? :fr : :nl
      end
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
      lang_key = detect_question_language(question_lower)

      # FOLLOW_UP_SUGGESTIONS is defined in CoreLawMappings (peer module)
      suggestions_map = self.class::FOLLOW_UP_SUGGESTIONS

      # Find matching topic based on keywords
      suggestions_map.each do |keyword, suggestions|
        next if keyword == '_default'
        if question_lower.include?(keyword)
          # Fall back to nl if language not available for this topic
          return suggestions[lang_key] || suggestions[:nl]
        end
      end

      # Return default suggestions if no topic matched
      suggestions_map['_default'][lang_key] || suggestions_map['_default'][:nl]
    end
  end
end
