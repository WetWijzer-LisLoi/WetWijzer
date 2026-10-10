# frozen_string_literal: true

require 'timeout'

module LegalChatbot
  # German answers v3, first fix (owner decision 2026-09-28, to-do 7.5): on
  # gesetzguide.be a German question is translated into French BEFORE
  # anything else runs, so that the embedding, HyDE, keyword search, the
  # guards and the reasoning are exactly the lisloi path on a French question.
  #
  # The graded run of German answers v2 (docs/ops/german-answers-v2-eval-2026-09-29.md)
  # found the main cause of the German path's wrong answers upstream of any
  # answer translation: retrieval ran on the German question and returned
  # other sources. The median overlap of its sources with lisloi's was 0.15,
  # the reference article was among them for 20 to 24 answers of 45 against
  # 30 on lisloi, and a German question answered by the French path (what
  # gesetzguide serves today) was correct 9 times against lisloi's 18.
  #
  # One mistral-small call, the same pinned model and budget as the answer
  # translation. The French question is checked before it is used: the same
  # numbers, each as often; the same number of negations (NegationTally,
  # German against French); no article reference the German question does
  # not make; the same regions and Community named, and a question the
  # answer path refuses still refused; not longer than a question may be. On
  # a failed check, an error or a timeout, the reader's German question goes
  # through as before.
  #
  # The regional guards read the question text (RegionalSearch): an explicit
  # region scopes the regional evidence, and family benefits asked for the
  # German-speaking Community are refused before retrieval, because no source
  # of that Community is in the corpus and another region's regime would be
  # stated with apparent support. "Ostbelgien" rendered as "les Cantons de
  # l'Est" passes every other check and names no Community the guards know,
  # so the regions named and the refusal are compared too.
  #
  # The reader never sees the French question. The conversation shows the
  # German question as typed; the French one travels beside it
  # (CONTEXT_KEY: in the result, which the browser keeps with the user turn,
  # and in the stored message), so the history the model is given on a
  # follow-up is French, as on lisloi. The log line holds status, reason,
  # time, tokens and cost, never the text.
  #
  # Switched by WW_GERMAN_QUESTION_TRANSLATION (default off), independently
  # of WW_GERMAN_ANSWERS: with this one alone, gesetzguide still answers in
  # French, but on the French question. Browser requests on gesetzguide only;
  # signed service requests never.
  #
  # Version 4 (the graded v3 run, docs/ops/german-answers-v3-eval-2026-09-29.md):
  # 7 of 42 translated questions were unfaithful or untranslated and no check
  # fired, and every question that fell back to German was answered wrongly
  # (5 of 5). So the checks now also refuse:
  #
  # - German left as it was: "Erlöschende Verjährung?" came back as
  #   "Erlöschende Verjährung ?" labelled translated (q0774). The unchanged
  #   comparison ignores the spacing before "?!:;", and an output whose words
  #   are mostly the German question's, or whose German function words
  #   outnumber its French ones, is still German.
  # - A number written as a word dropped or changed: "drei Kinder" (q20).
  #   Number words and spelled-out years count as their value on both sides
  #   (NumberWords), so "deux mille seize" is 2016 (q03).
  # - A sentence dropped, or the question made a statement: "Meine
  #   Partnerin hat letzten Monat ... Wie viele Tage ...?" lost the birth
  #   date (q09), "Ich habe drei Kinder. Über welchen Teil ...?" became a
  #   statement (q20). The French keeps the German's sentences and question
  #   marks.
  # - A status, employer, remedy or notice indemnity the German names and
  #   the French does not (GermanLegalGlossary::QUESTION_TERMS): Angestellter
  #   became travailleur (q06, q07), "als Arbeitnehmer" was dropped (q11),
  #   Einspruch became recours (q0377 t2), Abfindung became "indemnité de
  #   congé", which retrieval read as holiday pay (q1083).
  #
  # A rhetorical "Ist die Forderung nicht schon verjährt?" is no negation
  # (NegationTally, question: true): v3 refused a faithful French question on
  # it (q19). And a refused translation is tried once more, with the failure
  # named, before the German question goes through: the retry is a second
  # paid call (about 180 micro-euro), recorded in the call's record
  # (attempts, retry_reason, tokens and cost of both calls) so the
  # evaluation measures it.
  class GermanQuestionTranslation
    SWITCH_ENV = 'WW_GERMAN_QUESTION_TRANSLATION'

    # The interrogative of the German question must survive in the French:
    # grader 3 of the v8 run (2026-10-05) found three served retries that
    # dropped the "wie lange" and turned a duration question into a
    # yes-or-no one, which every other check passed. Each row: the German
    # form, the French forms that carry it, the retry hint.
    INTERROGATIVES = [
      [/\bwie\s+lange\b/i,
       /\bcombien\s+de\s+temps\b|\bquelle\s+(?:est\s+la\s+)?dur[ée]e\b|\bpendant\s+combien\b|\bjusqu['’]à\s+quand\b|
        \bd[ée]lais?\b|\bdur[ée]e\b|\bcombien\s+(?:de\s+|d['’])(?:jours|semaines|mois|ans|ann[ée]es|heures)\b/xi,
       'the German asks how long ("wie lange"): keep the duration question (combien de temps, quelle durée).'],
      # "wie viel Kündigungsfrist" is a duration question too (q1083, every
      # run: "quelle est la durée du délai de préavis"), "wie viel
      # Mindestkapital" a "quel est le montant minimum" (q16, every run): any
      # interrogative pronoun keeps the quantity question; the defect is the
      # yes-or-no question it becomes without one.
      [/\bwie\s+viele?\b/i,
       /\bcombien\b|\bquel(?:le|s|les)?\b|\blequel\b|\blaquelle\b|\blesquel(?:s|les)\b/i,
       'the German asks how much or how many ("wie viel"): keep the quantity question (combien, quel montant).'],
      [/\b(?:ab\s+|seit\s+|bis\s+)?wann\b/i,
       /\bquand\b|\bà\s+quel\s+moment\b|\bà\s+partir\s+de\b|\bd[èe]s\s+quand\b|\bdate\b|\bmoment\b|\bd[ée]lais?\b|\bjusqu['’]à\b/i,
       'the German asks when ("wann"): keep the time question (quand, à partir de quand).']
    ].freeze
    SWITCH_ON_VALUES = GermanAnswerTranslation::SWITCH_ON_VALUES
    BRAND = GermanAnswerTranslation::BRAND

    MODEL = GermanAnswerTranslation::MODEL
    # A question is at most LegalChatbotService::MAX_QUESTION_LENGTH (2000)
    # characters; its French runs a little longer.
    MAX_OUTPUT_TOKENS = 1536
    TEMPERATURE = 0.0
    TIMEOUT_SECONDS = 15
    # Below this the call is not attempted: the German question goes through.
    MIN_TIME_BUDGET_SECONDS = 3
    # French runs about as long as German; beyond these bounds the model
    # answered, explained or dropped something. Judged on questions long
    # enough for a ratio to mean something.
    LENGTH_RATIO_RANGE = (0.5..2.0)
    LENGTH_RATIO_MIN_CHARS = 40
    # The sentence rule, as the owner chose it on 2026-09-29 (the looser of
    # the two the v4 report put to them): a French question with FEWER
    # sentences than the German one is refused only when it is also this much
    # shorter. The model often joins two German sentences into one French
    # sentence and keeps every fact; the strict count refused seven faithful
    # questions for that. A dropped sentence shrinks the text, and what a
    # short dropped sentence carried (a number, a status, a negation) the
    # other checks catch. More sentences than the German is still refused.
    JOINED_SENTENCE_MAX_SHRINK = 0.15
    # The other direction, from the re-review of 2026-10-04: a comma splice,
    # lower-case typing or a sentence ending in a digit ("Mein Sohn ist 17.")
    # undercount the German side, and the French then has one sentence more
    # while saying the same. More sentences are refused only when the French
    # also grew by more than this; French runs longer than German as it is.
    ADDED_SENTENCE_MAX_GROWTH = 0.25

    STATUS_TRANSLATED = 'translated'
    STATUS_ORIGINAL = 'original'

    # The result keys: the call's record (status, reason, model, time,
    # tokens, cost; never text), and the French question for history replay.
    RECORD_KEY = :german_question
    CONTEXT_KEY = :question_context_content

    # The chatbot widget on a law page puts the page's law in front of the
    # question (app/javascript/controllers/chatbot_controller.js,
    # _enrichQuestionWithLawContext). It is not the reader's question: it is
    # kept as it is and only the question after it is translated.
    LAW_CONTEXT_PREFIX = /\A\[Context: [^\n]*\]\n\n/

    SYSTEM_PROMPT = <<~PROMPT.strip
      You translate questions asked to a Belgian legal information service from German into French, so that they can be searched in the French texts of Belgian law.

      The user message is one question, usually from a reader in the German-speaking Community of Belgium. Your only task is a faithful French translation of it. Never answer it, never add, remove, explain or correct anything, even when the question seems incomplete or wrong.

      Rules:
      1. Write the French a Belgian lawyer would write, in the same person and tone as the question. Keep every sentence, with every fact it states, and its line breaks, in the same order: never join, drop or summarise a sentence. A question stays a question.
      2. Keep every number exactly as written: amounts, percentages, periods, dates, ages and article numbers keep the same digits. A number written in digits stays in digits; a number written in words stays in words.
      3. Keep every negation and exception with its exact meaning: "nicht", "kein", "nichts", "nie", "ohne", "außer", "es sei denn", "weder ... noch" become "ne ... pas", "aucun", "rien", "jamais", "sans", "sauf", "à moins que", "ni ... ni".
      4. Never add an article reference, a law or a date the question does not name.
      5. Use the French terms of Belgian law. These German terms, in any grammatical form, are translated with exactly these French terms:
      #{GermanLegalGlossary.question_prompt_lines.map { |line| "   #{line}" }.join("\n")}
      6. If the question is already in French, reply with it unchanged. If it is in another language, translate it into French in the same way.
      7. Reply with the French question only: no introduction, no quotation marks, no note, no code fence.
    PROMPT

    # The message a refused translation is retried with, the failures named.
    RETRY_INSTRUCTION = 'Your French translation was refused by a mechanical check: %<failures>s ' \
                        'Translate the German question again, faithfully and completely, following every rule. ' \
                        'Reply with the French question only.'
    MAX_ATTEMPTS = 2

    # Words that mark a German or a French sentence, for the check that the
    # output is French at all.
    GERMAN_FUNCTION_WORDS = %w[
      der die das den dem des und oder ist sind ich mein meine meinem meinen meiner mir mich wie was wer wann
      welche welcher welches welchen für mit von bei auf zu zum zur im ein eine einen einem nicht kein keine
      kann muss darf habe hat haben wird werden nach über gegen aus auch noch schon wenn dass als sie wir es
    ].to_set.freeze
    FRENCH_FUNCTION_WORDS = %w[
      le la les l de des du d un une et ou est sont je j mon ma mes me m moi que qu qui quel quelle quels quelles
      pour avec dans sur au aux en ne n pas se s il elle nous vous ce cette y a peut puis dois doit
    ].to_set.freeze
    # A period after these ends no sentence ("Art. 37", "z. B.", "Nr. 3").
    # German nouns are capitalised, so "ggf. Anspruch" or "bzgl. Kündigung"
    # looks like the start of a sentence: without its abbreviation here, a
    # faithful one-sentence French question was refused as a sentence
    # dropped, and the retry could not repair it. Every entry is a word that
    # never ends a question; "vol" (theft) is left out on purpose.
    GERMAN_ABBREVIATIONS = %w[
      Abs Abschn abzgl allg Anh Anl Anm Art Artt Aufl Az Bd Bl bspw Buchst bzgl bzw ca dgl Dr ebd einschl entspr
      etc evtl exkl Fa ff Fr gem ggf ggfs ggü Hr Hrn Hrsg inkl insb insbes jur Kap lfd lt max min mind Mio Mrd Nr
      Nrn od Prof Rdnr Rn Rz sog Sp St Std Str Tel Tsd usw vgl vs Ziff zit zz zzgl zzt
    ].freeze
    FRENCH_ABBREVIATIONS = %w[al art av bd cf cfr chap env ex éd Me Mlle MM Mme Mmes Mr No n° resp sect sq sqq ss suiv tél voy].freeze
    ABBREVIATION = /(?:\A|[\s(])(?:[[:alpha:]]|#{(GERMAN_ABBREVIATIONS + FRENCH_ABBREVIATIONS).map { |word| Regexp.escape(word) }.join('|')})\z/i
    SENTENCE_TERMINATOR = /[.!?…]+/
    SENTENCE_FOLLOWER = /\A[\s»"“”'’)\]]*(?:\z|[ \t\u00a0\n]+[«"“„(]?[[:upper:]¿¡])/
    SPACE_BEFORE_PUNCTUATION = /[\s\u00a0\u202f]+(?=[?!:;])/

    Outcome = Struct.new(:question, :french, :record, :rejected, :rejected_retry, keyword_init: true)

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
        GermanAnswerTranslation::Client.new
      end

      # Sentences, counted by their end: a period, "?" or "!" before the end
      # of the text or before a capital, never after a digit ("3. Juli") or an
      # abbreviation. A text without final punctuation ends one more.
      def sentence_count(text)
        body = text.to_s.strip
        return 0 if body.empty?

        count = body.to_enum(:scan, SENTENCE_TERMINATOR).count do
          match = Regexp.last_match
          next false unless body[match.end(0)..].match?(SENTENCE_FOLLOWER)
          next true unless match[0].start_with?('.')

          before = body[0...match.begin(0)]
          !before.match?(/\d\z/) && !before.match?(ABBREVIATION)
        end
        body.match?(/[.!?…][\s»"“”'’)\]]*\z/) ? count : count + 1
      end

      def question_marks(text)
        text.to_s.count('?')
      end
    end

    def initialize(client: nil, logger: Rails.logger,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @client = client || self.class.build_client
      @logger = logger
      @clock = clock
    end

    # The question the reasoning path is given: the French one, or the
    # reader's own when the translation is refused twice, fails or is
    # skipped. Never raises a StandardError.
    #
    # @return [Outcome] question: what to ask; french: the translated
    #   question (without a law-page prefix), nil unless translated; record:
    #   for the result and the log; rejected and rejected_retry: the
    #   translations the checks refused, first and retried (for the
    #   evaluation runner only).
    def apply(question, time_budget: TIMEOUT_SECONDS)
      started = @clock.call
      prefix, body = split_law_context(question.to_s)
      return original(question, reason: 'empty', started: started) if body.strip.empty?
      return original(question, reason: 'no_time', started: started) if time_budget.to_f < MIN_TIME_BUDGET_SECONDS

      @spent = nil
      @rejected = []
      attempt(question, prefix, body, started, time_budget.to_f)
    rescue Timeout::Error
      original(question, reason: 'timeout', started: started, rejected: @rejected, **(@spent || {}))
    rescue StandardError => e
      original(question, reason: "error:#{e.class.name}", started: started, rejected: @rejected, **(@spent || {}))
    end

    # The result with the call's record, and, when the question was
    # translated, the French question for history replay and the German
    # follow-up suggestions of the reader's question (the answer path made
    # French ones from the French question). Never mutates `result`.
    def annotate(result, outcome, question:)
      return result unless result.is_a?(Hash) && outcome

      out = result.merge(RECORD_KEY => outcome.record)
      return out unless outcome.french

      out[CONTEXT_KEY] = outcome.french
      out[:suggestions] = GermanAnswerTranslation.german_suggestions(question) if result[:suggestions].is_a?(Array) && result[:suggestions].any?
      out
    end

    # nil when the French question may replace the German one, else the name
    # of the first check it fails. Public so the tests can pin each check.
    def check_failure(german, french, prefix: '')
      check_failures(german, french, prefix: prefix).first&.first
    end

    # Every check the French question fails, in order, as [name, what to fix]:
    # the first names the refusal, all of them go into the retry.
    def check_failures(german, french, prefix: '')
      failures = []
      german_figures = GermanAnswerTranslation.figures(german, language: 'de')
      french_figures = GermanAnswerTranslation.figures(french, language: 'fr')
      unless french_figures == german_figures
        failures << ['numbers', "it must state exactly the numbers of the German question (#{figure_list(german_figures)}), " \
                                "and it states #{figure_list(french_figures)}."]
      end
      german_negations = NegationTally.german(german, question: true)
      french_negations = NegationTally.french(french, question: true)
      # v6 grader 3: the question side read the bare counts, so "ai-je
      # l'interdiction de conduire" (0) for "darf ich nicht mehr fahren" (1)
      # fell back four times; the answer side's equivalences apply here too.
      if french_negations != german_negations &&
         !NegationTally.within_equivalences?(french, german, german_negations - french_negations)
        failures << ['negations', "the German question has #{german_negations} negations or exceptions " \
                                  "#{negated_sentences_detail(german)}and the French has #{french_negations}: keep each one " \
                                  'in the clause it stands in, with its exact meaning; never negate the question itself to ' \
                                  'make up the count.']
      elsif NegationTally.negation_moved_out_of_relative_clause?(german, french)
        # v5 q14: the retry negated the question's own verb ("pour ne pas
        # me rétracter") for a dropped "die mir nicht gefallen".
        failures << ['negations', "the German negates inside a relative clause #{negated_sentences_detail(german)}and " \
                                  'the French negates the question itself: keep the negation in its clause ("qui ne ... pas"), ' \
                                  'never negate the question\'s own verb.']
      end
      added = GermanAnswerTranslation.article_references(french) - GermanAnswerTranslation.article_references(german)
      failures << ['article_references', 'it names an article the German question does not name.'] unless added.empty?
      unless RegionalSearch.named_regions(french) == RegionalSearch.named_regions(german)
        failures << ['regions', 'it must name the same regions and Community as the German question.']
      end
      if unsupported_corpus_lost?(german, french)
        failures << ['unsupported_corpus', 'it must name the German-speaking Community and the family benefits as the ' \
                                           'German question does.']
      end
      failures << ['unchanged', 'it is the German question, not a French translation.'] if unchanged?(german, french)
      failures << ['german', 'it is still German: translate it into French.'] if still_german?(german, french)
      GermanLegalGlossary.question_failures(german, french).each do |term|
        failures << ["glossary:#{term.name}:missing", "\"#{term.german_label}\" must be translated as \"#{term.french_label}\"."]
      end
      if prefix.length + french.length > LegalChatbotService::MAX_QUESTION_LENGTH
        failures << ['too_long', 'it is far too long: translate only, never answer or explain.']
      end
      if length_out_of_range?(german, french)
        failures << ['length', 'it is much longer or shorter than the German question: translate only, add and drop nothing.']
      end
      german_sentences = self.class.sentence_count(german)
      french_sentences = self.class.sentence_count(french)
      if sentences_lost?(german, french, german_sentences, french_sentences)
        failures << ['sentences', "the German question has #{german_sentences} sentences and the French has " \
                                  "#{french_sentences}: keep every sentence and every fact in it."]
      end
      german_marks = self.class.question_marks(german)
      french_marks = self.class.question_marks(french)
      # Only a LOST question is a failure: readers type questions without
      # their "?" all the time, and the model's French has one. Two question
      # marks where the German had none is still the model's own addition.
      if french_marks < german_marks || (german_marks.zero? && french_marks > 1)
        failures << ['question', "the German question asks #{german_marks} question(s) and the French " \
                                 "#{french_marks}: keep it a question."]
      end
      INTERROGATIVES.each do |german_form, french_forms, detail|
        failures << ['interrogative', detail] if german.match?(german_form) && !french.match?(french_forms)
      end
      failures
    end

    private

    # One call, and one more with the failures named when a check refuses the
    # first translation and there is time left for it.
    def attempt(question, prefix, body, started, time_budget)
      messages = [{ role: 'system', content: SYSTEM_PROMPT }, { role: 'user', content: body }]
      rejected = @rejected
      first_failure = nil
      (1..MAX_ATTEMPTS).each do |attempt_number|
        remaining = attempt_number == 1 ? time_budget : time_budget - (@clock.call - started)
        break if attempt_number > 1 && (remaining < MIN_TIME_BUDGET_SECONDS || !german_question?(body))

        response = @client.call(messages, timeout: [remaining, TIMEOUT_SECONDS].min, max_tokens: MAX_OUTPUT_TOKENS)
        @spent = add_usage(@spent, response, attempt_number)
        french = clean_output(response[:text])
        if response[:incomplete] || french.empty?
          return original(question, reason: 'incomplete', started: started, rejected: rejected, retry_reason: first_failure,
                                    **@spent)
        end

        # Never given to the model or kept as history if it is provider
        # reasoning (raises, and the rescue keeps the German question).
        ChatbotAnswerSafety.validate_visible_answer!(french)
        failures = check_failures(body, french, prefix: prefix)
        if failures.empty?
          return finish(Outcome.new(question: "#{prefix}#{french}", french: french, rejected: rejected[0],
                                    rejected_retry: rejected[1]),
                        status: STATUS_TRANSLATED, reason: nil, started: started, retry_reason: first_failure, **@spent)
        end

        rejected << french
        first_failure ||= failures.first.first
        messages += [{ role: 'assistant', content: french }, { role: 'user', content: retry_instruction(failures) }]
      end
      last_reason = rejected.any? ? check_failure(body, rejected.last, prefix: prefix) : first_failure
      original(question, reason: "check_failed:#{last_reason}", started: started, rejected: rejected,
                         retry_reason: rejected.length > 1 ? first_failure : nil, **@spent)
    end

    # The German sentences that carry a negation, quoted for the retry.
    def negated_sentences_detail(german)
      quoted = NegationTally.sentences(german).select { |sentence| NegationTally.german(sentence, question: true).positive? }
      return '' if quoted.empty?

      "(in: #{quoted.first(2).map { |sentence| "\"#{sentence.strip.truncate(160)}\"" }.join(' ')}) "
    end

    def retry_instruction(failures)
      format(RETRY_INSTRUCTION, failures: failures.map(&:last).join(' '))
    end

    def figure_list(tally)
      return 'none' if tally.empty?

      tally.sort_by { |value, _| value.to_i }.map { |value, count| count > 1 ? "#{value} (#{count} times)" : value }.join(', ')
    end

    # The tokens of every call added up, and how many calls were made.
    def add_usage(spent, response, attempts)
      tokens = response[:tokens]
      total = spent&.dig(:tokens)
      if tokens.is_a?(Hash)
        total = { input: total.to_h[:input].to_i + tokens[:input].to_i,
                  output: total.to_h[:output].to_i + tokens[:output].to_i }
      end
      { tokens: total, provider_model: response[:provider_model] || spent&.dig(:provider_model), attempts: attempts }
    end

    def split_law_context(question)
      prefix = question[LAW_CONTEXT_PREFIX].to_s
      [prefix, question.delete_prefix(prefix)]
    end

    def original(question, reason:, started:, rejected: [], retry_reason: nil, tokens: nil, provider_model: nil, attempts: nil)
      rejected = Array(rejected)
      finish(Outcome.new(question: question, french: nil, rejected: rejected[0], rejected_retry: rejected[1]),
             status: STATUS_ORIGINAL, reason: reason, started: started, tokens: tokens, provider_model: provider_model,
             attempts: attempts, retry_reason: retry_reason)
    end

    def finish(outcome, status:, reason:, started:, tokens: nil, provider_model: nil, attempts: nil, retry_reason: nil)
      latency_ms = started ? ((@clock.call - started) * 1000).round : nil
      token_usage = tokens.is_a?(Hash) ? { input: tokens[:input].to_i, output: tokens[:output].to_i } : nil
      cost = GermanAnswerTranslation.cost_microeur(token_usage, model: MODEL)
      outcome.record = {
        status: status, reason: reason, model: provider_model, latency_ms: latency_ms, tokens: token_usage,
        cost_microeur: cost, attempts: attempts, retry_reason: retry_reason
      }.compact
      # Status, reason, sizes, time and cost only: never the question.
      @logger&.info(
        "[GermanQuestion] status=#{status} reason=#{reason || '-'} latency_ms=#{latency_ms || '-'} " \
        "in=#{token_usage&.dig(:input) || '-'} out=#{token_usage&.dig(:output) || '-'} cost_microeur=#{cost || '-'}" \
        "#{" attempts=#{attempts} retry_reason=#{retry_reason || '-'}" if attempts.to_i > 1}"
      )
      outcome
    end

    # A fence, and one pair of quotation marks around the whole question,
    # are removed.
    QUOTE_PAIRS = { '"' => '"', '«' => '»', '“' => '”', '„' => '“' }.freeze

    def clean_output(text)
      cleaned = text.to_s.gsub("\r\n", "\n").strip
      fenced = cleaned.match(/\A```[a-z]*\n(?<inner>.*)\n```\z/m)
      cleaned = fenced[:inner].strip if fenced
      closing = QUOTE_PAIRS[cleaned[0]]
      return cleaned unless closing && cleaned.length > 2 && cleaned.end_with?(closing)

      inner = cleaned[1...-1]
      inner.include?(cleaned[0]) || inner.include?(closing) ? cleaned : inner.strip
    end

    # The same text once whitespace, the French space before "?!:;" and case
    # are set aside (q0774: "Erlöschende Verjährung ?").
    def unchanged?(german, french)
      comparable(german) == comparable(french)
    end

    def comparable(text)
      text.gsub(SPACE_BEFORE_PUNCTUATION, '').gsub(/\s+/, ' ').strip.downcase
    end

    # A question the reader typed in French already comes back unchanged, as
    # the prompt asks, and goes through as it is: no retry for it.
    def german_question?(text)
      words = text.downcase.scan(/[[:alpha:]]+/)
      words.count { |word| GERMAN_FUNCTION_WORDS.include?(word) } >= words.count { |word| FRENCH_FUNCTION_WORDS.include?(word) }
    end

    # Most of its words copied from the German question, or more German
    # function words than French ones: not a French question.
    def still_german?(german, french)
      words = french.downcase.scan(/[[:alpha:]]+/)
      return false if words.empty?

      german_words = german.downcase.scan(/[[:alpha:]]+/).to_set
      long_words = words.select { |word| word.length >= 3 }
      copied = long_words.count { |word| german_words.include?(word) }
      return true if long_words.any? && copied * 2 > long_words.length

      words.count { |word| GERMAN_FUNCTION_WORDS.include?(word) } > words.count { |word| FRENCH_FUNCTION_WORDS.include?(word) }
    end

    def length_out_of_range?(german, french)
      return false if german.length < LENGTH_RATIO_MIN_CHARS

      !LENGTH_RATIO_RANGE.cover?(french.length.to_f / german.length)
    end

    # See JOINED_SENTENCE_MAX_SHRINK: fewer sentences is a join unless the
    # text shrank with them; more sentences is never the German's.
    def sentences_lost?(german, french, german_sentences, french_sentences)
      return false if french_sentences == german_sentences
      return french.length > german.length * (1 + ADDED_SENTENCE_MAX_GROWTH) if french_sentences > german_sentences

      french.length < german.length * (1 - JOINED_SENTENCE_MAX_SHRINK)
    end

    # The answer path refuses the German question before retrieval, and would
    # answer the French one. The other way round is the French path's own
    # refusal of the French question, as on lisloi.
    def unsupported_corpus_lost?(german, french)
      RegionalSearch.unsupported_corpus_question?(german) && !RegionalSearch.unsupported_corpus_question?(french)
    end
  end
end
