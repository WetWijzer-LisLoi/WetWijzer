# frozen_string_literal: true

require 'timeout'

module LegalChatbot
  # German answers on gesetzguide.be, second version (owner decision
  # 2026-09-28, to-do 7.5).
  #
  # The first version (08efb353d, ff4b262a9) had the model answer in German
  # from the French evidence. It was rolled back within the hour (b3d911413):
  # asked for the notice period after five years of service, the German path
  # answered 15 weeks, then the pre-2014 regime, and called the periods
  # optional where the quoted text says public order, while the same question
  # in French on lisloi answered 18 weeks with a verified quote of Art. 37/2 of
  # the Law of 3 July 1978 (NUMAC 1978070303). Retrieval was the same in both
  # languages: answering in one language from evidence in another degraded the
  # answering model's reasoning, and the guards cannot see that.
  #
  # So gesetzguide REASONS exactly as lisloi does. The controller keeps
  # language 'fr' for retrieval, prompts, guards and repairs, and only the
  # final, already guarded French answer passes through #apply:
  #
  # - Every blockquote (the verbatim law quotations), with the lines that
  #   continue it without ">" while its quotation mark is open (.quotations),
  #   is replaced by a placeholder before the call and put back byte for byte
  #   afterwards, so the translation model never sees, and cannot change, a
  #   quotation.
  # - A dedicated call translates the prose, the headers and the fixed closing
  #   lines. It is told to copy every Markdown link and every article
  #   reference and number unchanged.
  # - A mechanical check then compares the German text with the French one:
  #   the same quotations and the same links (same text, same order), no
  #   article reference the French answer does not make, and the same numbers,
  #   each as often. If the check fails, or the call errors or runs out of time, the
  #   French answer is served with a short German note that it is shown in
  #   French. A wrong German answer is worse than a French one.
  # - Messages the code writes itself (the timeout, the "no provision found"
  #   answer, the refusals) have a German twin already; they are swapped for
  #   it without a call. The retrieval notice is re-rendered in German from the
  #   same degraded sources, so history replay and the free-answer note still
  #   recognise it.
  # - Follow-up questions reason on the French answer too. The result carries
  #   it next to the German one (CONTEXT_KEY); the browser sends it back with
  #   the turn in context_messages, a stored conversation keeps it in the
  #   message, and history replay hands it to the model in place of the text
  #   the reader saw. The French path's prompt therefore holds the same
  #   assistant turns as on lisloi, and a translation error never feeds into
  #   the next answer.
  #
  # Switched by WW_GERMAN_ANSWERS (default off: gesetzguide keeps answering in
  # French, as production did before). With it on, browser requests on
  # gesetzguide get the German answer; signed service requests never do.
  #
  # Version 3 (the graded v2 run, docs/ops/german-answers-v2-eval-2026-09-29.md):
  # 7 of 32 translations were unfaithful and 13 of 45 answers fell back to
  # French, 11 of them because the model translated the text of a prose link
  # and 2 because it turned the no-quote line into placeholders. So:
  #
  # - Every Markdown link in the prose is a placeholder too (%%LINK_n%%), put
  #   back byte for byte, text and target: the model never sees link text.
  # - Lines the code or the answer prompt writes word for word (the no-quote
  #   line of the quote guard, the follow-up tip, the privacy tip and the
  #   disclaimer) are placeholders (%%LINE_n%%) restored as one fixed German
  #   wording, without the model.
  # - The Belgian German glossary (GermanLegalGlossary) is in the prompt and
  #   is enforced on the output, and the negations are counted on both sides
  #   (NegationTally): a translation that drops a "sauf" or a "ne ... pas", or
  #   uses "Tarifvertrag" for a CCT, is refused like one that changes a number.
  # - The German text a check refused is kept on the instance (last_rejected)
  #   for the evaluation runner. It never goes into the result or the log.
  #
  # Version 4 (the graded v3 run, docs/ops/german-answers-v3-eval-2026-09-29.md):
  # 11 of 45 answers fell back to French, 9 of them on faithful German, and 3
  # of the 34 served translations changed a legal term no check knew. So:
  #
  # - Numbers written as words count as their value (NumberWords): "5ᵉ
  #   année" and "fünfte", "4 premières années" and "ersten vier" agree
  #   (incident t1 and t2, whose correct German was withheld).
  # - Negations are compared line by line, with the equivalent wordings the
  #   report found (NegationTally.line_mismatches).
  # - The glossary has the terms the served translations got wrong:
  #   autocar/Reisebus and autobus/Linienbus (q0841, which extended the
  #   coach limit to city buses), cohabitation légale/gesetzliches
  #   Zusammenwohnen (q09), compte arrêté/Rechnungsabschluss and
  #   cédule/Schuldschein (q19), cour d'appel/Appellationshof; and
  #   pension_age no longer matches "pension anticipée" (q11).
  # - A quotation is protected at any indentation: two quotations indented
  #   four spaces in a nested list were translated and shown as the article
  #   text (q0377 t1).
  # - The refusal line the answer prompt dictates and the verified-sources
  #   fallback block have fixed German twins (q0015 t2 lost "the sources",
  #   q17 implied the sources answer the question), and an answer made only
  #   of such lines, links and quotations is German without a call.
  # - A translation a check refuses is tried once more, with the failure
  #   named, before the French answer is served: a second paid call (about
  #   400 micro-euro), in the record as attempts and retry_reason.
  class GermanAnswerTranslation
    SWITCH_ENV = 'WW_GERMAN_ANSWERS'
    SWITCH_ON_VALUES = %w[1 true on].freeze
    BRAND = 'gesetzguide'

    # The translation model: pinned (mistral-small-2603 via ModelsConfig), on
    # the EU endpoint, reasoning none. A translation needs no reasoning, and
    # the call goes through LlmClient#call_llm, so it is reserved against and
    # reconciled with the same daily and monthly budgets as every answer.
    MODEL = 'mistral-small'
    MAX_OUTPUT_TOKENS = 6144
    TEMPERATURE = 0.0
    # The call's own deadline. The caller may pass less (what is left of the
    # streaming supervisor's budget); below MIN_TIME_BUDGET_SECONDS the call is
    # not attempted and the French answer is served with the note.
    TIMEOUT_SECONDS = 45
    MIN_TIME_BUDGET_SECONDS = 8
    # German runs longer than French; beyond these bounds the model either
    # dropped or added text. Only judged on answers long enough for a ratio to
    # mean something.
    LENGTH_RATIO_RANGE = (0.6..1.9)
    LENGTH_RATIO_MIN_CHARS = 400

    STATUS_TRANSLATED = 'translated'
    STATUS_MAPPED = 'mapped'
    STATUS_FRENCH = 'french_fallback'
    STATUS_NO_ANSWER = 'no_answer'

    # The French answer the reader's answer was made from, for history replay
    # (LegalChatbotService#conversation_messages). Set whenever the delivered
    # answer is not the French one as generated: translated, swapped for its
    # German twin, or under the shown-in-French note.
    CONTEXT_KEY = :context_content

    # What the progress bar shows while the call runs. The client prints a
    # server `message` as the label as it is, so this needs no Vite build.
    PROGRESS_PHASE = :translating
    PROGRESS_FIELDS = { percent: 97, message: 'Antwort wird ins Deutsche übersetzt' }.freeze

    # Leads the French answer whenever it is served untranslated. No cause and
    # no model name, as for the retrieval notice.
    FRENCH_NOTE = '**Hinweis:** Diese Antwort wird auf Französisch angezeigt, weil die Übersetzung ' \
                  'ins Deutsche nicht verfügbar war.'
    FRENCH_NOTE_PARAGRAPH = /\A[\s>*_]*Hinweis:[\s*_]*Diese Antwort wird auf Französisch angezeigt/

    QUOTE_TOKEN_PREFIX = '%%QUOTE_'
    LINK_TOKEN_PREFIX = '%%LINK_'
    LINE_TOKEN_PREFIX = '%%LINE_'
    NOTICE_TOKEN = '%%NOTICE%%'
    TOKEN_PATTERN = /%%(?:QUOTE_\d+|LINK_\d+|LINE_\d+|NOTICE)%%/
    TOKEN_PREFIX_PATTERN = /%%(?:QUOTE_|LINK_|LINE_|NOTICE)/
    RESTORE_PATTERN = /%%(QUOTE|LINK|LINE)_(\d+)%%/

    # Lines with a fixed wording, French pattern -> German text, swapped
    # without the model. The no-quote line comes from the quote guard
    # (AnswerGuards#missing_quote_message, rendered in both languages, see
    # .fixed_lines); the others are the closing lines the answer prompts
    # dictate (LegalChatbotService: the French follow-up tip, privacy tip and
    # disclaimer, with the German prompt's wording). The follow-up tip is a
    # UI hint the model sometimes rewords ("niveau d'intensité", "via les
    # paramètres ⚙"), so any line that starts like it is the tip. The long
    # privacy tip comes before the short one it extends.
    FOLLOW_UP_TIP_DE = '💡 Stellen Sie eine Folgefrage für mehr Details. Unter Einstellungen ⚙ wählen Sie Ihre ' \
                       'Modell-Denkmodus-Kombination mit der gekoppelten Leiste oder Liste; prüfen Sie die angezeigten Credits vor Senden.'
    # The earlier wordings of the German tip (c51720259, 4dde7f2ee). German
    # answers recorded or kept in a conversation before 2026-10-11 still end
    # with one; prose strips them like the current line, as
    # FOLLOW_UP_TIP_FR_TEXT recognises the older French tip. Left in, the
    # line moved the negation tally's line pairing, and the replay of every
    # served German answer since v3 refused faithful translations
    # ("negations", q0377 t1).
    LEGACY_FOLLOW_UP_TIPS_DE = [
      '💡 Stellen Sie gerne eine Folgefrage für mehr Details, oder probieren Sie ein höheres ' \
      'Intelligenz- und/oder Denkniveau (falls möglich) über die Einstellungen ⚙.',
      '💡 Stellen Sie eine Folgefrage für mehr Details. Unter Einstellungen ⚙ wählen Sie Modell ' \
      'und Rechercheumfang getrennt; prüfen Sie die angezeigten Credits vor Senden.'
    ].freeze
    PRIVACY_TIP_FR = '⚠️ Conseil: évitez les données personnelles dans vos questions.'
    PRIVACY_TIP_DE = '⚠️ Tipp: vermeiden Sie persönliche Daten in Ihren Fragen.'
    PRIVACY_NOTICE_FR = "#{PRIVACY_TIP_FR} WetWijzer n'enregistre pas votre question par défaut; pour y répondre, " \
                        "votre question et le contexte nécessaire sont transmis au fournisseur d'IA choisi, qui les " \
                        'traite. Voir la politique de confidentialité.'.freeze
    PRIVACY_NOTICE_DE = "#{PRIVACY_TIP_DE} WetWijzer speichert Ihre Frage standardmäßig nicht; zur Beantwortung " \
                        'werden Ihre Frage und der nötige Kontext an den gewählten KI-Anbieter übermittelt und dort ' \
                        'verarbeitet. Siehe Datenschutzerklärung.'.freeze
    # The line the French answer prompt dictates when the sources hold
    # nothing on the subject (LegalChatbotService#build_french_system_prompt),
    # with or without its second sentence. It attributes the gap to the
    # sources; the model's own German ("Zu diesem Thema liegen keine
    # Informationen vor", q0015 t2 of the v3 run) did not.
    NO_INFORMATION_FR = /Les sources disponibles ne contiennent pas d['’]informations? sur ce sujet\./
    NO_INFORMATION_RETRY_FR = /[ \t]*Essayez de reformuler votre question ou d['’]utiliser d['’]autres termes de recherche\./
    NO_INFORMATION_DE = 'Die verfügbaren Quellen enthalten keine Informationen zu diesem Thema.'
    NO_INFORMATION_RETRY_DE = 'Versuchen Sie, Ihre Frage umzuformulieren oder andere Suchbegriffe zu verwenden.'
    # The lines of the verified-sources fallback (TopicCitations: the
    # citation guard's source list and the appended verified source), whose
    # German twins the service renders itself. q17 of the v3 run turned "pour
    # reprendre la question prudemment" into "um die Frage sorgfältig zu
    # beantworten", as if the listed sources answered it.
    RENDERED_FIXED_LINES = %i[
      localized_guarded_source_list_fallback_intro localized_guarded_source_list_statement_fallback_intro
      localized_verified_fallback_heading
      high_confidence_citation_heading localized_consulted_source_note
    ].freeze
    # Retain recognition of older French histories as well as the new research
    # depth hint; neither footer is left to an unconstrained model translation.
    FOLLOW_UP_TIP_FR_TEXT = "(?:N['’]hésitez pas à poser une question complémentaire|Posez une question complémentaire)[^\\n]*?"
    FIXED_LINE_PATTERNS = [
      [Regexp.new(NO_INFORMATION_FR.source + NO_INFORMATION_RETRY_FR.source), "#{NO_INFORMATION_DE} #{NO_INFORMATION_RETRY_DE}"],
      [NO_INFORMATION_FR, NO_INFORMATION_DE],
      [Regexp.new(Regexp.escape(PRIVACY_NOTICE_FR)), PRIVACY_NOTICE_DE],
      # Up to the end of the line. Bold or italic markers around the whole
      # line stay in place; markers around the emoji alone ("**💡** N'hésitez",
      # v4 q0014, which the model then translated itself) or around the text
      # alone go with the line, so that none is left unpaired.
      [/(?:[*_]+💡[*_]+[ \t]*#{FOLLOW_UP_TIP_FR_TEXT}|💡[ \t]*(?<tip_markers>[*_]*)#{FOLLOW_UP_TIP_FR_TEXT}\k<tip_markers>)(?=[*_]*[ \t]*$)/,
       FOLLOW_UP_TIP_DE],
      [Regexp.new(Regexp.escape(PRIVACY_TIP_FR)), PRIVACY_TIP_DE],
      [/Ceci n['’]est pas un avis juridique officiel\./, 'Dies ist keine offizielle Rechtsberatung.'],
      # The quote guard's note before f208ec24a (2026-10-12), still in answers
      # recorded or kept in a conversation before then: a fixed line like its
      # successor (AnswerGuards#missing_quote_message, read through
      # RENDERED_FIXED_LINES), or its "Aucune" moved the negation tally's line
      # pairing (v8 q0181 t2).
      [/Aucune citation exacte disponible dans les sources consultées\./,
       'In den konsultierten Quellen ist kein exaktes Zitat verfügbar.']
    ].freeze

    # A quotation (.quotations): its blockquote lines, as
    # Orchestrator::MARKDOWN_BLOCKQUOTE_PATTERN reads them, and the lines that
    # continue it without ">" while a quotation mark it opened is still open.
    # The answers quote a law's items (1°, 2°) or its next sentence that way,
    # closed by the mark and the attribution link on the last line; in the
    # graded v2 run 13 of 208 quotations did, over 32 unmarked lines. A blank
    # line ends a quotation, as it ends a Markdown blockquote. The quote guard
    # verifies the blockquote lines only, so the continued lines reach the
    # reader as generated, in French, on lisloi as here.
    #
    # At any indentation (v4): an answer nests quotations in lists, and two
    # indented four spaces were translated and shown as the law's text in
    # the graded v3 run (q0377 t1).
    # A list marker before the ">" still opens a quotation (v6 q07: four
    # statutory quotations set as list items reached the model).
    BLOCKQUOTE_LINE = /\A[ \t]*(?:(?:[-*+]|\d{1,2}[.)])[ \t]+)?>/
    BLANK_LINE = /\A[ \t]*\r?\n?\z/
    # Straight marks are counted for parity; the paired marks, opening
    # against closing.
    PAIRED_QUOTATION_MARKS = [%w[« »], %w[“ ”]].freeze
    LINK_PATTERN = Orchestrator::MARKDOWN_LINK_PATTERN
    ARTICLE_SPACE = Orchestrator::ARTICLE_SPACE_SOURCE
    ARTICLE_NUMBER = Orchestrator::ARTICLE_NUMBER_TOKEN_SOURCE
    # French, German and Dutch article prefixes, "Artikeln" (German dative
    # plural) included, and the list and range words of all three, in the
    # shape of the citation gate's ARTICLE_CITATION_SEQUENCE_PATTERN. Used on
    # both texts alike, so a wider pattern only makes the check stricter.
    ARTICLE_PREFIX = '(?i:Art(?:t|s)?\.?|Artikel(?:en|n|s)?|Articles?)'
    ARTICLE_LIST_WORD = '(?i:en|et|and|und|of|ou|oder|à|bis|tot)'
    ARTICLE_SEPARATOR = "(?:#{ARTICLE_SPACE}*[,;&+]#{ARTICLE_SPACE}*(?:#{ARTICLE_LIST_WORD}#{ARTICLE_SPACE}+)?|" \
                        "#{ARTICLE_SPACE}+#{ARTICLE_LIST_WORD}#{ARTICLE_SPACE}+)".freeze
    ARTICLE_REFERENCE_PATTERN = Regexp.new(
      "\\b#{ARTICLE_PREFIX}#{ARTICLE_SPACE}*(?:(?i:(?:nrs?|nos?)\\.)|n[°º])?#{ARTICLE_SPACE}*" \
      "(?<numbers>#{ARTICLE_NUMBER}(?:#{ARTICLE_SEPARATOR}(?:#{ARTICLE_PREFIX}#{ARTICLE_SPACE}*)?#{ARTICLE_NUMBER})*)"
    )
    ARTICLE_NUMBER_PATTERN = Regexp.new(ARTICLE_NUMBER)
    ARTICLE_SPACE_PATTERN = Regexp.new(ARTICLE_SPACE)

    SYSTEM_PROMPT = <<~PROMPT.strip
      You translate answers of a Belgian legal information service from French into German, for readers in the German-speaking Community of Belgium.

      The user message is one French answer. It has already been checked against its legal sources. Your only task is a faithful translation of its prose. Never add, remove, correct, complete or comment on legal content, even when you think the French answer is wrong or incomplete.

      Rules:
      1. Translate the prose into formal German (Sie). Keep every paragraph, heading, list item and line break, in the same order, and keep the Markdown formatting (bold, italics, lists).
      2. %%QUOTE_1%%, %%LINE_1%% and %%NOTICE%% are placeholders for text that is inserted later: a quotation, a fixed line, a notice. Copy each placeholder exactly, once, in the same place and on its own line when it stands on its own line. Never start a line with ">" and never add a quotation.
      3. %%LINK_1%%, %%LINK_2%% and so on are placeholders for links to legal sources (for example an article of a law), inserted later with their own text. Copy each one exactly, once, in the same order, where the link belongs in the German sentence. Do not add "Artikel" or an article number next to it: the link already names it. Never write a Markdown link yourself.
      4. Copy every article reference and every number exactly as written: article numbers (for example 37/2, 1675/12, 2bis), amounts, percentages, periods and dates keep the same digits. A number written in digits stays in digits; a number written in words stays in words. Never convert, round or recalculate.
      5. Translate these headings exactly:
         RÈGLE PRINCIPALE -> HAUPTREGEL
         EXCEPTIONS -> AUSNAHMEN
         DIFFÉRENCES RÉGIONALES -> REGIONALE UNTERSCHIEDE
         Réponse vérifiée -> Geprüfte Antwort
         Dispositions légales consultées -> Konsultierte gesetzliche Bestimmungen
      6. The closing lines of the French answer (the tip starting with 💡, the privacy tip starting with ⚠️ and the disclaimer) reach you as %%LINE_n%% placeholders: copy the placeholders and never write those lines yourself.
      7. Use the terminology of the official German translations of Belgian law, never the terms of the law of Germany. Translate these French terms with exactly these German terms, in the grammatical form the sentence needs, and keep the meaning of every negation and exception ("sauf", "sauf si", "à moins que", "ne ... pas", "sans", "aucun", "ni"):
      #{GermanLegalGlossary.answer_prompt_lines.map { |line| "   #{line}" }.join("\n")}
      8. Reply with the German translation only: no introduction, no note, no code fence.
    PROMPT

    class << self
      def enabled?(env = ENV)
        SWITCH_ON_VALUES.include?(env.fetch(SWITCH_ENV, '').to_s.strip.downcase)
      end

      # The one decision: a browser request on gesetzguide with the switch on.
      # The brand comes from SiteBrand (request.host), never from a parameter.
      def applies_to?(brand:, service_bypass:, env: ENV)
        !service_bypass && brand.to_s == BRAND && enabled?(env)
      end

      def build_client
        Client.new
      end

      # The article numbers a text refers to, in French, German or Dutch
      # (the set), for the check that a translation adds no article.
      def article_references(text)
        text.to_s.to_enum(:scan, ARTICLE_REFERENCE_PATTERN).flat_map do
          Regexp.last_match[:numbers].scan(ARTICLE_NUMBER_PATTERN).map { |number| normalize_article_number(number) }
        end.to_set
      end

      # "1er" (French for the first article) and "1" are the same article.
      def normalize_article_number(number)
        number.to_s.downcase.gsub(ARTICLE_SPACE_PATTERN, '').sub(/(?<=\d)(?:er|re)\z/, '')
      end

      # Every quotation of a text, in order, as [offset, text]: the offset in
      # characters, the text with its line breaks. See BLOCKQUOTE_LINE.
      def quotations(text)
        found = []
        current = nil
        offset = 0
        text.to_s.each_line do |line|
          if current && (line.match?(BLOCKQUOTE_LINE) || (quotation_open?(current.last) && !line.match?(BLANK_LINE)))
            current.last << line
          elsif line.match?(BLOCKQUOTE_LINE)
            current = [offset, +line]
          elsif current
            found << current
            current = nil
          end
          offset += line.length
        end
        found << current if current
        found
      end

      # The text with each quotation replaced by the block's value.
      def replace_quotations(text)
        text = text.to_s
        replaced = +''
        position = 0
        quotations(text).each do |offset, quotation|
          replaced << text[position...offset] << yield(quotation)
          position = offset + quotation.length
        end
        replaced << text[position..]
      end

      def quotation_open?(text)
        text.count('"').odd? || PAIRED_QUOTATION_MARKS.any? { |open, close| text.count(open) > text.count(close) }
      end

      # Every digit run with its count (see .figures).
      def numbers(text)
        text.to_s.scan(/\d+/).tally
      end

      # What a call cost, from its tokens, in the provider budget's accounting
      # units (micro-euro at the budget's list prices and its deliberately
      # high USD to EUR rate, LegalChatbotService.model_token_cost_units): an
      # upper estimate, the same one the daily and monthly budgets reconcile.
      # nil without token counts.
      def cost_microeur(tokens, model: MODEL)
        return nil unless tokens.is_a?(Hash) && tokens.key?(:input) && tokens.key?(:output)

        LegalChatbotService.model_token_cost_units(model, input_tokens: tokens[:input].to_i,
                                                          output_tokens: tokens[:output].to_i)
      rescue StandardError
        nil
      end

      # History replay (LegalChatbotService#conversation_messages) must not
      # hand the note back to the model, which would echo it into the next
      # answer. Returns the same string when there is nothing to remove.
      def without_french_note(text)
        return text unless text.is_a?(String) && text.include?('Französisch')

        paragraphs = text.split(/\n{2,}/)
        kept = paragraphs.grep_v(FRENCH_NOTE_PARAGRAPH)
        return text if kept.length == paragraphs.length || kept.empty?

        kept.join("\n\n").strip
      end

      # German follow-up suggestions whatever the question's language (the
      # reader is on the German site), with the general German list for topics
      # without one. Topic selection is shared with the ordinary delivery path.
      def german_suggestions(question)
        map = LegalChatbotService::FOLLOW_UP_SUGGESTIONS
        default = map.fetch('_default').fetch(:de)
        topic = LegalChatbot::LanguageDetection.follow_up_suggestion_topic(question, map, language: :de)
        map.fetch(topic)[:de] || default
      end

      # French text -> German text for every message the code writes as a
      # whole answer. Built by running the same methods in both languages, so
      # every pair is exact by construction.
      def code_built_messages
        @code_built_messages ||= begin
          french = LegalChatbotService.new(language: 'fr')
          german = LegalChatbotService.new(language: 'de')
          pairs = %i[timeout_answer no_governing_rule_message unsupported_corpus_message
                     unsupported_article_citation_message].map do |name|
            [french.send(name), german.send(name)]
          end
          pairs << [french.send(:authoritative_source_unavailable_response)[:answer],
                    german.send(:authoritative_source_unavailable_response)[:answer]]
          pairs << [LlmClient.incomplete_response_message('fr'), LlmClient.incomplete_response_message('de')]
          pairs << [ChatbotAnswerSafety.blocked_message('fr'), ChatbotAnswerSafety.blocked_message('de')]
          pairs.to_h.freeze
        end
      end

      def retrieval_notice_renderers
        @retrieval_notice_renderers ||= {
          'fr' => LegalChatbotService.new(language: 'fr'),
          'de' => LegalChatbotService.new(language: 'de')
        }.freeze
      end

      # [French pattern, German text] for every line swapped without the
      # model: the quote guard's no-quote line and the lines of the
      # verified-sources fallback (RENDERED_FIXED_LINES), each rendered by the
      # same method in both languages, then FIXED_LINE_PATTERNS.
      def fixed_lines
        @fixed_lines ||= begin
          renderers = retrieval_notice_renderers
          rendered = %i[missing_quote_message].concat(RENDERED_FIXED_LINES).map do |name|
            french, german = %w[fr de].map { |language| renderers.fetch(language).send(name) }
            [rendered_line_pattern(french), german.freeze]
          end
          [*rendered, *FIXED_LINE_PATTERNS].map(&:freeze).freeze
        end
      end

      # The exact French text; a heading's " :" also without its space.
      def rendered_line_pattern(french)
        Regexp.new(Regexp.escape(french).gsub('\\ :', "[ \u00a0]?:"))
      end

      # Every figure of a text with its count: the digit runs anywhere, and
      # the numbers written as words (NumberWords) in `prose`, the text the
      # model translated. Values are strings ("18", "2016").
      #
      # Counted, not a set: a set misses a changed figure whenever its old
      # and its new value both occur elsewhere in the answer (a date, an
      # article number, a link anchor, the other figure of the rule), which
      # is the incident's failure class: 3 weeks rendered as 18 next to "3.
      # Juli" and a main rule of 18 weeks. Counted, each such change moves a
      # tally; and since v4 a figure keeps its value in words ("drei" is 3).
      #
      # Residual, which only the graded evaluation catches: two figures that
      # trade places (the 18-week rule stated as 15 and the 15-week band as
      # 18) keep every count. Their order is not compared because German
      # sentences legitimately put a figure elsewhere than French ones do.
      def figures(text, language:, prose: text)
        words = language.to_s == 'de' ? NumberWords.german(prose) : NumberWords.french(prose)
        numbers(text).merge(words) { |_value, digits, spelled| digits + spelled }
      end

      GERMAN_BOTH_WORD = /(?<![[:alpha:]])beide[mnrs]?(?![[:alpha:]])/i
      FRENCH_FIRST_WORD = /(?<![[:alpha:]])premi(?:er|ers|ère|ères)(?![[:alpha:]])/i

      # The tallies agree, or differ only in the ways the v4 run showed to be
      # faithful (docs/ops/german-answers-v4-eval-2026-10-04.md): a German
      # "beide" (2) for a French "père et mère" with no "deux"; a French
      # "premier" or "première" (1) the German states as the thing itself
      # ("les 5 premières années" / "ab dem 5. Jahr", "au premier degré" /
      # "in gerader Linie"); a figure the French repeats that the German
      # states once ("nées en 1962" three times / "diese Personengruppe"). A
      # figure the German adds, or drops entirely, still fails.
      def figures_agree?(french_figures, german_figures, french_prose, german_prose)
        french = french_figures.transform_values(&:to_i)
        german = german_figures.transform_values(&:to_i)
        if german['2'].to_i > french['2'].to_i
          # "beide" counts as 2 and the French may say "père et mère" for one
          # of them while saying "les deux" for another on the same text.
          german['2'] -= [german_prose.scan(GERMAN_BOTH_WORD).length, german['2'] - french['2'].to_i].min
        end
        french['1'] -= [french_prose.scan(FRENCH_FIRST_WORD).length, french['1'] - german['1'].to_i].min if french['1'].to_i > german['1'].to_i
        (french.keys | german.keys).all? do |value|
          counted = french[value].to_i
          translated = german[value].to_i
          counted == translated || (translated.positive? && counted > translated)
        end
      end

      # Any French fixed line, as one alternation in the order above (the
      # first alternative that matches at a position wins), one named group
      # per line so the match says which German text restores it.
      def fixed_line_pattern
        @fixed_line_pattern ||= Regexp.new(
          fixed_lines.each_with_index.map { |(pattern, _), index| "(?<line#{index}>#{pattern.source})" }.join('|')
        )
      end

      # The German text of a match of fixed_line_pattern.
      def fixed_line_german(match)
        index = fixed_lines.each_index.find { |candidate| match["line#{candidate}"] }
        fixed_lines.fetch(index).last
      end
    end

    # The real translation client: one provider call through LlmClient, so
    # budget reservation, token accounting and the EU route are the answer's
    # own. The answer's token usage (Thread.current[:last_chat_tokens], which
    # the controller records in analytics) is restored afterwards; the
    # translation's usage is returned instead.
    class Client
      # The browser question's dispatch receipt and what these calls are for
      # it (owner policy 2026-10-18); given to every client built per call.
      attr_accessor :provider_work_receipt, :provider_work_kind

      def initialize(llm_factory: nil)
        @llm_factory = llm_factory || lambda {
          LlmClient.new(model_override: MODEL, language: 'de', reasoning_effort: 'low')
        }
      end

      # @return [Hash] text:, tokens:, incomplete:, provider_model:
      def call(messages, timeout:, max_tokens:)
        answer_tokens = Thread.current[:last_chat_tokens]
        begin
          llm = @llm_factory.call
          if llm.respond_to?(:provider_work_receipt=)
            llm.provider_work_receipt = provider_work_receipt
            llm.provider_work_kind = provider_work_kind
          end
          text = Timeout.timeout(timeout) do
            llm.call_llm(messages, temperature: TEMPERATURE, max_tokens: max_tokens)
          end
          {
            text: text,
            tokens: Thread.current[:last_chat_tokens],
            incomplete: llm.last_response_incomplete?,
            provider_model: llm.last_provider_model
          }
        ensure
          Thread.current[:last_chat_tokens] = answer_tokens
        end
      end
    end

    # The German texts the checks refused in the last #apply, in order: the
    # first translation, then its retry (the model output as returned when
    # its placeholders were wrong, else the restored German answer). For the
    # evaluation runner only: never in the result, never logged, reset by
    # every #apply.
    attr_reader :rejected_attempts

    # The message a refused translation is retried with, the failures named.
    RETRY_INSTRUCTION = 'Your German translation was refused by a mechanical check: %<failures>s ' \
                        'Translate the French text again from the start, following every rule, and correct this. ' \
                        'Reply with the complete German translation only.'
    MAX_ATTEMPTS = 2
    # How much of a line the retry message quotes.
    RETRY_LINE_CHARS = 160

    def initialize(client: nil, logger: Rails.logger,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @client = client || self.class.build_client
      @logger = logger
      @clock = clock
      @rejected_attempts = []
    end

    # The browser question's paid-AI dispatch receipt (owner policy
    # 2026-10-18), passed explicitly by the controller.
    def provider_work_receipt=(receipt)
      return unless @client.respond_to?(:provider_work_receipt=)

      @client.provider_work_receipt = receipt
      @client.provider_work_kind = 'answer_translation'
    end

    # The last German text a check refused, or nil (see #rejected_attempts).
    def last_rejected
      @rejected_attempts.last
    end

    # The result to deliver: the German answer, or the French one with the
    # note. Never raises a StandardError and never mutates `result`, so a
    # caller that loses this call (a supervisor timeout) still holds the
    # French result intact.
    def apply(result, question:, time_budget: TIMEOUT_SECONDS)
      started = @clock.call
      @rejected_attempts = []
      @spent = {}
      french = result[:answer]
      return tag(result, status: STATUS_NO_ANSWER) unless french.is_a?(String) && french.strip != ''

      text, german_notice = tokenize_notice(french, result[:retrieval_degraded])
      mapped = map_code_built(text, german_notice)
      return deliver(result, mapped, status: STATUS_MAPPED, question: question, started: started) if mapped

      return fallback(result, reason: 'placeholder_collision', question: question, started: started) if french.match?(TOKEN_PREFIX_PATTERN)

      text, kept = tokenize(text)
      # Only fixed lines, links and quotations: German without the model.
      unless text.gsub(TOKEN_PATTERN, ' ').match?(/[[:alpha:]]/)
        return deliver(result, restore(text, kept, german_notice), status: STATUS_MAPPED, question: question, started: started)
      end
      return fallback(result, reason: 'no_time', question: question, started: started) if time_budget.to_f < MIN_TIME_BUDGET_SECONDS

      translate(result, french, text, kept, german_notice, question: question, started: started,
                                                           time_budget: time_budget.to_f)
    rescue Timeout::Error
      fallback(result, reason: 'timeout', question: question, started: started, **@spent)
    rescue StandardError => e
      fallback(result, reason: "error:#{e.class.name}", question: question, started: started, **@spent)
    end

    # The French answer with the German note on top. Public for the
    # controller's supervisor-timeout salvage.
    def fallback(result, reason:, question:, started: nil, tokens: nil, provider_model: nil, attempts: nil,
                 retry_reason: nil)
      french = result[:answer]
      # A note with nothing under it would be the whole answer.
      return tag(result, status: STATUS_NO_ANSWER) unless french.is_a?(String) && french.strip != ''

      shown = [FRENCH_NOTE, french].reject { |part| part.strip.empty? }.join("\n\n")
      out = result.merge(answer: shown, CONTEXT_KEY => french)
      out[:error] = shown if result[:error].is_a?(String) && result[:error] == french
      out[:suggestions] = self.class.german_suggestions(question) if german_suggestions?(result)
      finish(out, status: STATUS_FRENCH, reason: reason, started: started, tokens: tokens, provider_model: provider_model,
                  attempts: attempts, retry_reason: retry_reason)
    end

    # nil when the German text may be served, else the name of the first check
    # it fails. Public so the tests can pin each check on its own.
    def check_failure(french, german)
      check_failures(french, german).first&.first
    end

    # Every check the German text fails, in order, as [name, what to fix]:
    # the first names the refusal, all of them go into the retry.
    #
    # The negation and glossary checks read prose only (#prose): the
    # quotations and link texts are French in both texts, and the lines the
    # code swaps have a fixed wording of their own. So do the number words;
    # the digits are counted everywhere.
    def check_failures(french, german)
      failures = []
      unless blockquotes(german) == blockquotes(french)
        failures << ['blockquotes', 'never write a quotation or a line starting with ">" yourself, and keep each ' \
                                    '%%QUOTE_n%% placeholder on its own line.']
      end
      failures << ['links', 'never write a Markdown link yourself.'] unless links(german) == links(french)
      added = article_references(german) - article_references(french)
      failures << ['article_references', "never add an article reference: you added #{added.to_a.join(', ')}."] unless added.empty?

      french_prose = prose(french)
      german_prose = prose(german)
      french_figures = self.class.figures(french, language: 'fr', prose: french_prose)
      german_figures = self.class.figures(german, language: 'de', prose: german_prose)
      unless self.class.figures_agree?(french_figures, german_figures, french_prose, german_prose)
        failures << ['numbers', numbers_detail(french_figures, german_figures)]
      end

      # Compared as prose: the fixed lines are German in any case.
      if squish(german_prose) == squish(french_prose) && french_prose.match?(/[[:alpha:]]/)
        failures << ['unchanged', 'the text was not translated into German.']
      end
      mismatches = NegationTally.line_mismatches(french_prose, german_prose)
      failures << ['negations', negations_detail(mismatches)] if mismatches.any?

      GermanLegalGlossary.failures(french_prose, german_prose).each do |failure|
        failures << ["glossary:#{failure}", glossary_detail(failure, german_prose, french_prose)]
      end
      if duplicated_fixed_line?(french, german)
        failures << ['fixed_lines', 'the closing lines (the tip, the privacy tip and the disclaimer) are inserted for you: ' \
                                    'copy their placeholders and never write them yourself.']
      end
      failures << ['length', 'the German is much longer or shorter than the French: translate everything, add nothing.'] if length_out_of_range?(french, german)
      failures
    end

    # The text the model translated, in either language: quotations, the
    # retrieval notice's paragraph, links and the fixed lines removed.
    def prose(text)
      text = self.class.replace_quotations(text) { "\n" }
      text = text.split(/\n{2,}/).grep_v(Orchestrator::RETRIEVAL_NOTICE_PARAGRAPH).join("\n\n")
      text = text.gsub(LINK_PATTERN, ' ').gsub(self.class.fixed_line_pattern, ' ')
      (self.class.fixed_lines.map(&:last) + LEGACY_FOLLOW_UP_TIPS_DE).uniq.reduce(text) { |stripped, line| stripped.gsub(line, ' ') }
    end

    private

    # One call, and one more with the failures named when a check refuses the
    # first translation and there is time left for it.
    def translate(result, french, text, kept, german_notice, question:, started:, time_budget:)
      expected_tokens = text.scan(TOKEN_PATTERN)
      messages = [{ role: 'system', content: SYSTEM_PROMPT }, { role: 'user', content: text }]
      first_failure = nil
      last_failure = nil
      (1..MAX_ATTEMPTS).each do |attempt|
        remaining = attempt == 1 ? time_budget : time_budget - (@clock.call - started)
        break if attempt > 1 && remaining < MIN_TIME_BUDGET_SECONDS

        response = @client.call(messages, timeout: [remaining, TIMEOUT_SECONDS].min, max_tokens: MAX_OUTPUT_TOKENS)
        add_usage(response, attempt)
        output = clean_output(response[:text])
        if response[:incomplete] || output.empty?
          return fallback(result, reason: 'incomplete', question: question, started: started, retry_reason: first_failure,
                                  **@spent)
        end

        # The same final boundary as every generated answer: provider
        # reasoning is never shown (raises, and #apply serves the French answer).
        ChatbotAnswerSafety.validate_visible_answer!(output)
        german, failures = judge(french, output, expected_tokens, kept, german_notice)
        if failures.empty?
          return deliver(result, german, status: STATUS_TRANSLATED, question: question, started: started,
                                         retry_reason: first_failure, **@spent)
        end

        @rejected_attempts << german
        last_failure = failures.first.first
        first_failure ||= last_failure
        messages += [{ role: 'assistant', content: output }, { role: 'user', content: retry_instruction(failures) }]
      end
      fallback(result, reason: "check_failed:#{last_failure}", question: question, started: started,
                       retry_reason: @rejected_attempts.length > 1 ? first_failure : nil, **@spent)
    end

    # [the German text, its failures]: the output as returned when its
    # placeholders are wrong, else the restored answer and what the checks
    # find in it.
    def judge(french, output, expected_tokens, kept, german_notice)
      return [output, [['placeholders', placeholders_detail(expected_tokens)]]] unless output.scan(TOKEN_PATTERN) == expected_tokens

      german = restore(output, kept, german_notice)
      [german, check_failures(french, german)]
    end

    def retry_instruction(failures)
      format(RETRY_INSTRUCTION, failures: failures.map(&:last).join(' '))
    end

    # A fixed German line written by the model on top of the one its
    # placeholder restores: two answers of the v4 run carried the tip, the
    # privacy tip and the disclaimer twice.
    def duplicated_fixed_line?(french, german)
      self.class.fixed_lines.any? do |pattern, line|
        german.scan(line).length > french.scan(pattern).length
      end
    end

    def placeholders_detail(expected_tokens)
      "copy every placeholder exactly once, in this order: #{expected_tokens.join(', ')}."
    end

    def numbers_detail(french_figures, german_figures)
      missing = french_figures.filter_map { |value, count| value if german_figures[value].to_i < count }
      added = german_figures.filter_map { |value, count| value if french_figures[value].to_i < count }
      parts = []
      parts << "#{missing.join(', ')} of the French text #{missing.length == 1 ? 'is' : 'are'} missing or changed" if missing.any?
      parts << "#{added.join(', ')} #{added.length == 1 ? 'is' : 'are'} not in the French text" if added.any?
      "the numbers differ (#{parts.join('; ')}): keep every figure as it is."
    end

    def negations_detail(mismatches)
      lines = mismatches.first(3).map do |mismatch|
        where = mismatch[:line] ? "in line #{mismatch[:line]}, " : ''
        "#{where}the French \"#{mismatch[:french].truncate(RETRY_LINE_CHARS)}\" has #{mismatch[:french_count]} negations " \
          "or exceptions and your German \"#{mismatch[:german].truncate(RETRY_LINE_CHARS)}\" has #{mismatch[:german_count]}"
      end
      "#{lines.join('; ')}. Translate every negation and exception where the French has one (\"sauf si\" is " \
        '"es sei denn", never "sofern"), and add none the French does not have.'
    end

    # v6 grader 3: two retries repeated the refused text word for word; the
    # message now quotes the competing word the German used.
    def glossary_detail(failure, german_prose = '', french_prose = '')
      name, kind = failure.split(':')
      term = GermanLegalGlossary::TERMS.find { |candidate| candidate.name == name }
      return 'use the Belgian German legal terms of the glossary.' unless term
      return banned_detail(term, german_prose) if kind == 'banned'

      found = term.competing_pattern && german_prose.to_s[term.competing_pattern]
      # v8, graders 2 and 3: "on every line" made a retry replace a right
      # Zustellung where the French said signification; the hint quotes the
      # refused lines (v9 grader 2: all of them, a one-line hint left three
      # wrong lines and the row fell back) and asks for those lines only.
      if kind == 'line'
        lines = GermanLegalGlossary.refused_lines(term, french_prose, german_prose)
        noun = lines.length == 1 ? 'the line' : 'the lines'
        quoted = lines.any? ? " (#{noun} #{lines.first(4).map { |line| "\"#{line[0, 160]}\"" }.join(', ')})" : ''
        word = lines.any? && term.competing_pattern ? lines.first[term.competing_pattern] : found
        where = lines.length == 1 ? 'that line' : 'those lines'
        return "you wrote \"#{word}\"#{quoted} where the French says \"#{term.french}\": write \"#{term.german}\" " \
               "on #{where}, the Belgian term; where the French says another word, keep yours."
      end
      # v9, grader 2: the whole-text hint made a retry replace every
      # Arbeitnehmer, those standing for "travailleurs" included; the hint
      # spares the competing word where the French says another word.
      if found && term.competing_french
        return "you wrote \"#{found}\": write \"#{term.german}\" for \"#{term.french}\", the Belgian term; keep " \
               "\"#{found}\" where the French says another word."
      end
      return "you wrote \"#{found}\": write \"#{term.german}\" for \"#{term.french}\", the Belgian term." if found

      # v10 grader 3 (q09): a retry answering the bare hint dropped a clause;
      # the hint quotes the French line that names the term.
      line = french_prose.to_s.split("\n").map(&:strip).find { |candidate| term.french_pattern.match?(candidate) }
      quoted = line ? " (the French line \"#{line[0, 160]}\", translated whole)" : ''
      "write \"#{term.german}\" for \"#{term.french}\"#{quoted}."
    end

    # The weekly run of 2026-10-05 (q07 run 2): a hint naming only the banned
    # nouns made the retry replace "Kollektivvertrag" and keep the adjective
    # "kollektivvertraglichen"; the hint quotes every word the German writes
    # with a banned stem in it, and the lines that hold them, as the line hint
    # does.
    def banned_detail(term, german_prose)
      words, lines = banned_words(term, german_prose)
      plain = "never write #{term.banned.join(' or ')}: write \"#{term.german}\" for \"#{term.french}\"."
      return plain if words.empty?

      noun = lines.length == 1 ? 'the line' : 'the lines'
      quoted = lines.any? ? " (#{noun} #{lines.first(4).map { |line| "\"#{line[0, RETRY_LINE_CHARS]}\"" }.join(', ')})" : ''
      "you wrote #{words.map { |word| "\"#{word}\"" }.join(', ')}#{quoted}: #{plain} Rephrase every word made from them " \
        'too, the adjectives included.'
    end

    def banned_words(term, german_prose)
      return [[], []] unless term.banned_pattern

      whole = /[[:alpha:]]*(?:#{term.banned_pattern.source})[[:alpha:]]*/i
      text = german_prose.to_s
      words = text.to_enum(:scan, whole).map { Regexp.last_match[0] }.uniq
      lines = text.split("\n").map(&:strip).grep(term.banned_pattern)
      [words, lines]
    end

    # The tokens of every call added up, and how many calls were made.
    def add_usage(response, attempt)
      tokens = response[:tokens]
      total = @spent[:tokens]
      if tokens.is_a?(Hash)
        total = { input: total.to_h[:input].to_i + tokens[:input].to_i,
                  output: total.to_h[:output].to_i + tokens[:output].to_i }
      end
      @spent = { tokens: total, provider_model: response[:provider_model] || @spent[:provider_model], attempts: attempt }
    end

    def tag(result, status:)
      result.merge(german_answer: { status: status })
    end

    def deliver(result, german, status:, question:, started:, tokens: nil, provider_model: nil, attempts: nil,
                retry_reason: nil)
      out = result.merge(answer: german, CONTEXT_KEY => result[:answer])
      out[:error] = german if result[:error].is_a?(String) && result[:error] == result[:answer]
      out[:suggestions] = self.class.german_suggestions(question) if german_suggestions?(result)
      finish(out, status: status, reason: nil, started: started, tokens: tokens, provider_model: provider_model,
                  attempts: attempts, retry_reason: retry_reason)
    end

    def finish(out, status:, reason:, started:, tokens:, provider_model:, attempts: nil, retry_reason: nil)
      latency_ms = started ? ((@clock.call - started) * 1000).round : nil
      token_usage = tokens.is_a?(Hash) ? { input: tokens[:input].to_i, output: tokens[:output].to_i } : nil
      out[:german_answer] = {
        status: status, reason: reason, model: provider_model, latency_ms: latency_ms, tokens: token_usage,
        cost_microeur: self.class.cost_microeur(token_usage), attempts: attempts, retry_reason: retry_reason
      }.compact
      # Status, reason, sizes and time only: never the question or the answer.
      @logger&.info(
        "[GermanAnswer] status=#{status} reason=#{reason || '-'} latency_ms=#{latency_ms || '-'} " \
        "in=#{token_usage&.dig(:input) || '-'} out=#{token_usage&.dig(:output) || '-'} " \
        "cost_microeur=#{out[:german_answer][:cost_microeur] || '-'}" \
        "#{" attempts=#{attempts} retry_reason=#{retry_reason || '-'}" if attempts.to_i > 1}"
      )
      out
    end

    # An error result has no suggestions to replace.
    def german_suggestions?(result)
      result[:suggestions].is_a?(Array) && result[:suggestions].any?
    end

    # The retrieval notice (Orchestrator#apply_retrieval_notice!) becomes a
    # placeholder, and its German twin is rendered from the same degraded
    # sources. retry_later is tried first: its text extends the other one.
    def tokenize_notice(french, degraded)
      sources = Array(degraded).map { |source| source.to_s.to_sym }
      return [french, nil] if sources.empty?

      renderers = self.class.retrieval_notice_renderers
      [true, false].each do |retry_later|
        french_notice = renderers.fetch('fr').retrieval_notice_text(sources, retry_later: retry_later)
        next unless french.include?(french_notice)

        german_notice = renderers.fetch('de').retrieval_notice_text(sources, retry_later: retry_later)
        return [french.sub(french_notice) { NOTICE_TOKEN }, german_notice]
      end
      [french, nil]
    end

    def map_code_built(text, german_notice)
      body = text.sub(NOTICE_TOKEN, '').strip
      german_body = self.class.code_built_messages[body]
      return nil unless german_body

      mapped = text.sub(body) { german_body }
      german_notice ? mapped.sub(NOTICE_TOKEN) { german_notice } : mapped
    end

    # The text the model is sent, and what each placeholder stands for:
    # quotations first, continuation lines included (a link inside a
    # quotation, its attribution too, is part of the quotation), then the
    # links of the prose, then the fixed lines, whose placeholders restore
    # their German wording.
    def tokenize(text)
      kept = { 'QUOTE' => [], 'LINK' => [], 'LINE' => [] }
      text = self.class.replace_quotations(text) do |block|
        token = keep(kept['QUOTE'], block.chomp, QUOTE_TOKEN_PREFIX)
        block.end_with?("\n") ? "#{token}\n" : token
      end
      text = text.gsub(LINK_PATTERN) { |link| keep(kept['LINK'], link, LINK_TOKEN_PREFIX) }
      text = text.gsub(self.class.fixed_line_pattern) do
        keep(kept['LINE'], self.class.fixed_line_german(Regexp.last_match), LINE_TOKEN_PREFIX)
      end
      [text, kept]
    end

    def keep(list, value, prefix)
      list << value
      "#{prefix}#{list.length}%%"
    end

    def restore(output, kept, german_notice)
      restored = output.gsub(RESTORE_PATTERN) do
        kept.fetch(Regexp.last_match(1)).fetch(Regexp.last_match(2).to_i - 1)
      end
      german_notice ? restored.sub(NOTICE_TOKEN) { german_notice } : restored
    end

    # A ">" the model wrote before a placeholder is layout, not a quotation
    # (v10 grader 3: two faithful attempts refused for it); it is dropped.
    QUOTE_MARK_BEFORE_TOKEN = /^([ \t]*(?:(?:[-*+]|\d{1,2}[.)])[ \t]+)?)>[ \t]*(?=%%[A-Z]+_\d+%%|%%NOTICE%%)/
    # A placeholder the model wrote in square brackets or with single percent
    # signs ("[%LINK_1%]", "[%%LINK_1%%]") is the placeholder: the weekly run of
    # 2026-10-05 lost both q09 answers to the French fallback, four attempts
    # faithful but for an inline link of the French rebuilt as "([%LINK_1%])".
    # It is written back as the placeholder, before the ">" is read.
    BRACKETED_TOKEN = /\[?%{1,2}(QUOTE|LINK|LINE)_(\d+)%{1,2}\]?/

    def clean_output(text)
      cleaned = text.to_s.gsub("\r\n", "\n").strip
      fenced = cleaned.match(/\A```[a-z]*\n(?<inner>.*)\n```\z/m)
      (fenced ? fenced[:inner].strip : cleaned).gsub(BRACKETED_TOKEN, '%%\1_\2%%').gsub(QUOTE_MARK_BEFORE_TOKEN, '\1')
    end

    # The quotations, continuation lines included: a changed item of a
    # quoted law is a changed quotation.
    # Compared without the indentation of their lines: a placeholder the
    # model set deeper or shallower in a list moves the quotation, it does
    # not change it.
    def blockquotes(text)
      self.class.quotations(text).map { |_offset, quotation| quotation.chomp.gsub(/^[ \t]+/, '') }
    end

    def links(text)
      text.scan(LINK_PATTERN)
    end

    def article_references(text)
      self.class.article_references(text)
    end

    def squish(text)
      text.gsub(/\s+/, ' ').strip
    end

    def length_out_of_range?(french, german)
      return false if french.length < LENGTH_RATIO_MIN_CHARS

      !LENGTH_RATIO_RANGE.cover?(german.length.to_f / french.length)
    end
  end
end
