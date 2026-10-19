# frozen_string_literal: true

module LegalChatbot
  # Narrow evidence check for the BV-capital error. This does not decide
  # company-law questions generally: it only applies when the retrieved
  # canonical WVV Art. 5:1 text establishes that a BV has no capital.
  class FormationBvCapitalGrounding
    NUMAC = '2019A40586'
    ARTICLE = '5:1'
    VERSION = 1
    MAX_SOURCE_CHARS = 1000
    CONDITION_CODES = %w[bv_capital_requirement].freeze

    NO_CAPITAL_NL = /\b(?:besloten\s+vennootschap|bv)\b[^.!?\n]{0,180}\b(?:zonder|geen)\s+(?:maatschappelijk\s+)?kapitaal\b|\b(?:zonder|geen)\s+(?:maatschappelijk\s+)?kapitaal\b[^.!?\n]{0,180}\b(?:besloten\s+vennootschap|bv)\b/i
    NO_CAPITAL_FR = /\b(?:soci[eé]t[eé]\s+[aà]\s+responsabilit[eé]\s+limit[eé]e|srl)\b[^.!?\n]{0,180}\b(?:sans|d[eé]pourvue?\s+de)\s+capital\b|\b(?:sans|d[eé]pourvue?\s+de)\s+capital\b[^.!?\n]{0,180}\b(?:soci[eé]t[eé]\s+[aà]\s+responsabilit[eé]\s+limit[eé]e|srl)\b/i
    CAPITAL_TERM = /\b(?:kapitaal|maatschappelijk\s+kapitaal|minimumkapitaal(?:verplichtingen)?|minimum\s+kapitaal|capital|capital\s+minimum|minimum\s+capital|capital\s+social)\b/i
    CAPITAL_REQUIREMENT = /(?:verplicht\w*|vereist\w*|moet|dient|mandatory|required|must|obligatoire|doit|exig[eé]\w*)/i
    POSITIVE_CAPITAL = /(?:#{CAPITAL_TERM.source}[^.!?\n]{0,100}#{CAPITAL_REQUIREMENT.source}\b|\b#{CAPITAL_REQUIREMENT.source}[^.!?\n]{0,100}#{CAPITAL_TERM.source}|\b(?:minimumkapitaal|minimum\s+kapitaal|capital\s+minimum|minimum\s+capital)(?:\s*(?:is|wordt|est|is|=))?\s*#{CAPITAL_REQUIREMENT.source}\b)/i
    MANDATORY_STATUTES_LIST = /\b(?:verplicht|vereist|mandatory|required|must|obligatoire|doit|exig[eé])\b[^.!?\n]{0,120}\b(?:statut(?:en|s)?|articles?(?: |\s+de\s+la\s+soci[eé]t[eé])?)\b[^.!?\n]{0,180}\b(?:kapitaal|maatschappelijk\s+kapitaal|capital|capital\s+social)\b/i
    NEGATED_CAPITAL = /(?:\b(?:geen|zonder|no|without|pas\s+de|sans)\s+(?:(?:verplicht|vereist|required|mandatory)\s+)?#{CAPITAL_TERM.source}|#{CAPITAL_TERM.source}\s+(?:is|zijn|wordt|est|sont|n['’]est)\s+(?:niet|not|pas)\s+(?:vereist|verplicht|nodig|required|mandatory|obligatoire|n[eé]cessaire)\b|\b(?:niet|not)\s+(?:over|aan|het|de)\s+#{CAPITAL_TERM.source})/i
    CONDITIONAL_CAPITAL = /\b(?:in\s+voorkomend\s+geval|in\s+het\s+voorkomende\s+geval|le\s+cas\s+[eé]ch[eé]ant|if\s+applicable|where\s+applicable|as\s+applicable|si\s+n[eé]cessaire)\b/i
    STATUTES_PATTERN = /\b(?:statuten|statuts|articles\s+of\s+association)\b/i
    OTHER_FORM_PATTERN = /\b(?:nv|naamloze\s+vennootschap|soci[eé]t[eé]\s+anonyme|(?-i:SA))\b/i

    class << self
      def evidence(sources)
        Array(sources).each do |source|
          next unless field(source, :numac).to_s == NUMAC
          next unless article_number(source) == ARTICLE

          language_id = field(source, :language_id)
          next unless language_id.is_a?(Integer) && [1, 2].include?(language_id)
          next unless canonical_anchor?(source, language_id)
          next if field(source, :truncated, :is_truncated) == true

          text = field(source, :article_text, :text, :full_text, :content).to_s
          next if text.length > MAX_SOURCE_CHARS || text.match?(/(?:\.\.\.|…)[ \t]*\z/)
          next unless text.strip.end_with?('.', '!', '?')
          next unless language_id == 1 ? text.match?(NO_CAPITAL_NL) : text.match?(NO_CAPITAL_FR)

          return { source: source, language_id: language_id }
        end
        nil
      end

      def applicable_question?(question)
        text = question.to_s
        normalized = text.gsub(/[[:space:]]+/, ' ')
        normalized.match?(LegalChatbot::LegislationSearch::FORMATION_DEED_PATTERN) &&
          LegalChatbot::LegislationSearch.formation_deed_entity_context?(normalized) &&
          LegalChatbot::LegislationSearch.formation_deed_explicit_form(normalized) == :bv
      end

      def evaluate(answer, question, sources)
        grounded = applicable_question?(question) && evidence(sources)
        return { applicable: false, missing_conditions: [], version: VERSION } unless grounded

        missing = []
        visible = answer.to_s.gsub(/\[([^\]]+)\]\([^)]+\)/, '\\1')
        visible = visible.gsub(/(\*{1,3}|_{1,3})(?=\S)(.+?)(?<=\S)\1/m, '\\2')
        missing << 'bv_capital_requirement' if unsafe_capital_requirement?(visible)
        { applicable: true, missing_conditions: missing.uniq, version: VERSION }
      end

      def corrective_feedback(codes, language: 'nl')
        return nil unless Array(codes).map(&:to_s).intersect?(CONDITION_CODES)

        {
          'nl' => 'CORRECTIE: de aangeleverde tekst van WVV art. 5:1 beschrijft de BV als een vennootschap zonder kapitaal. Verwar dit niet met een toereikend aanvangsvermogen of met de kapitaalregels van een NV. Schrijf het antwoord opnieuw op basis van de aangeleverde bron en citeer art. 5:1; verzin geen minimumbedrag.',
          'fr' => 'CORRECTION : le texte fourni de l’art. 5:1 du CSA décrit la SRL comme une société sans capital. Ne confondez pas cette règle avec l’existence de fonds propres suffisants ni avec les règles de capital de la SA. Réécrivez la réponse sur la base de la source fournie et citez l’art. 5:1, sans inventer de montant minimum.',
          'de' => 'KORREKTUR: Der bereitgestellte Text von Art. 5:1 WVV beschreibt die BV als Gesellschaft ohne Kapital. Verwechseln Sie dies nicht mit ausreichendem Eigenvermögen oder den Kapitalregeln der NV. Schreiben Sie die Antwort anhand der bereitgestellten Quelle neu und zitieren Sie Art. 5:1; erfinden Sie keinen Mindestbetrag.',
          'en' => 'CORRECTION: the supplied text of WVV Article 5:1 describes the BV as a company without capital. Do not confuse this with sufficient starting equity or the capital rules for an NV. Rewrite from the supplied source and cite Article 5:1; do not invent a minimum amount.'
        }.fetch(language.to_s, nil)
      end

      def fallback(question, sources, language: 'nl')
        grounded = applicable_question?(question) && evidence(sources)
        return nil unless grounded

        text = field(grounded.fetch(:source), :article_text, :text, :full_text, :content).to_s
        clause = text.split(/(?<=[.!?])\s+|\n/).find { |sentence| grounded.fetch(:language_id) == 1 ? sentence.match?(NO_CAPITAL_NL) : sentence.match?(NO_CAPITAL_FR) }
        return nil if clause.to_s.strip.empty?

        intro = {
          'nl' => 'Dit is de exacte aangeleverde definitie van de BV zonder kapitaal uit WVV art. 5:1. Beoordeel andere vereisten afzonderlijk aan de hand van de aangeleverde bronnen.',
          'fr' => 'Voici la définition exacte fournie de la SRL sans capital, tirée de l’art. 5:1 du CSA. Examinez séparément les autres exigences dans les sources fournies.',
          'de' => 'Dies ist die exakt bereitgestellte Definition der BV ohne Kapital aus Art. 5:1 WVV. Prüfen Sie andere Anforderungen anhand der bereitgestellten Quellen.',
          'en' => 'This is the exact supplied definition of the BV without capital from WVV Article 5:1. Assess other requirements separately from the supplied sources.'
        }.fetch(language.to_s, nil)
        return nil unless intro

        "#{intro}\n\n> #{clause.strip}\n> — [Art. 5:1](/laws/#{NUMAC}#art-5-1)"
      end

      private

      def unsafe_capital_requirement?(text)
        mandatory_heading = false
        text.to_s.lines.any? do |line|
          if line.match?(/\A\s*\#{1,6}\s+/) || line.strip.end_with?(':')
            mandatory_heading = line.match?(STATUTES_PATTERN) && line.match?(CAPITAL_REQUIREMENT) &&
                                !line.match?(NEGATED_CAPITAL) && !line.match?(/\b(?:niet|not|pas|optional|optioneel|facultatif)\b/i)
          end
          line.split(/(?<=[.!?])\s+|;|,\s*(?:maar|but|mais|aber)\b/i).any? do |sentence|
            next false unless sentence.match?(CAPITAL_TERM)
            next false if sentence.match?(NEGATED_CAPITAL) || sentence.match?(CONDITIONAL_CAPITAL)
            next false if sentence.match?(OTHER_FORM_PATTERN)

            sentence.match?(POSITIVE_CAPITAL) || sentence.match?(MANDATORY_STATUTES_LIST) || mandatory_heading
          end
        end
      end

      def article_number(source)
        value = field(source, :article_number, :article_title).to_s.gsub(/\s+/, ' ').strip
        value.match(/\A(?:Art(?:ikel|icle)?\.?\s*)?(\d+:\d+)\.?\z/i)&.[](1)
      end

      def canonical_anchor?(source, language_id)
        anchor = '#art-5-1'
        supplied_anchor = field(source, :article_anchor, :anchor)
        return false if supplied_anchor.present? && supplied_anchor.to_s != anchor

        link = field(source, :link, :url)
        return true if link.blank?

        match = link.to_s.match(%r{\A(?:https://(?:wetwijzer|lisloi|gesetzguide|lexlibera)\.be)?/laws/#{NUMAC}(?:\?language_id=([12]))?#{Regexp.escape(anchor)}\z})
        match && (!match[1] || match[1].to_i == language_id)
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
