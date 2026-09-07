# frozen_string_literal: true

# System prompt construction and language detection for LegalChatbotService.
# Contains all prompt templates (NL, FR, EN, DE) and locale-specific response helpers.
#
# Extracted from the monolith to isolate prompt engineering
# from the search and RAG pipeline logic.
module LegalChatbot
  module Prompts
    extend ActiveSupport::Concern

    private

    # NOTE: this module once held per-language header/label helpers
    # (language_name, language_headers, main_rule_header, exceptions_header,
    # legal_basis_header, not_in_sources_text, domain_default_language) and a
    # detect_question_language copy. All were dead code — no callers; the live
    # prompt text is built inline in LegalChatbotService#build_system_prompt,
    # language detection lives in LegalChatbot::LanguageDetection, and the
    # JURIDISCHE BASIS section they referenced is no longer requested (UI
    # source cards carry the citations since commits 95a3c34e/c0151db4).

    # Response when no relevant articles found.
    #
    # These refusals are correct decisions judged POOR purely for opacity: the
    # old text said only that nothing was found, which reads as "we have no
    # idea" and gives the reader nothing to act on.
    #
    # What it deliberately does NOT do is name a missing domain. The obvious
    # design was to detect the subject (collective agreements, case law) and say
    # the corpus lacks it. Checking that against the corpus killed the idea:
    # "CAO nr. 109 matters" were filed as outside the statutory corpus, yet
    # CAO 109 is present as NUMAC 2014A01545 with 24 article-level rows, and the
    # 2024 dismissal-motivation law sits alongside it. A domain-gap message
    # would have stated, confidently and in the product, that we lack something
    # we hold. A wrong explanation is worse than no explanation.
    #
    # The wording below names ONLY Belgian consolidated legislation, and that
    # narrowness is the point. An earlier version enumerated "legislation, case
    # law, parliamentary documents and tax sources" on the stated premise that
    # this path is reached only after all of them returned nothing. That premise
    # is wrong: execute_parallel_searches runs jurisprudence only when
    # sources.include?(:jurisprudence), parliamentary only when
    # sources.include?(:parliamentary), and fisconet only when is_tax_question?.
    # The default request is source: 'legislation' -> sources == [:legislation],
    # so for a plain non-tax question the refusal asserted that four source
    # families had been searched when exactly one had. That is the same class of
    # confident in-product falsehood the domain-gap wording was rejected for, and
    # it was introduced by the very commit that rejected it. Legislation is the
    # one family always searched, so it is the only one safe to name here.
    def no_answer_response(retrieval_status: 'no_results')
      message = if retrieval_status == 'unsupported_corpus'
                  unsupported_corpus_message
                else
                  no_governing_rule_message
                end

      result = {
        answer: message,
        sources: [],
        language: @language
      }
      if @include_quality_evidence
        result[:quality_evidence] = ChatbotQualityEvidence.skipped(retrieval_status: retrieval_status)
      end
      result
    end

    # Everything searched came back empty. State what was searched and give the
    # two realistic reasons, so the reader can act instead of guessing.
    def no_governing_rule_message
      case @language
      when 'fr'
        "Je n'ai trouvé, dans la législation belge consolidée que j'ai consultée, aucune " \
          "disposition qui règle directement cette question.\n\nCela peut vouloir dire que la matière est réglée en dehors de ces sources, par exemple " \
          'par une convention collective sectorielle, un contrat individuel ou un règlement communal, ou ' \
          "simplement que la question gagnerait à être reformulée avec le terme juridique ou le numéro d'article."
      when 'en'
        'I found no provision directly governing this question in the Belgian consolidated ' \
          "legislation I searched.\n\nThat can mean the " \
          'matter is governed outside those sources, for example by a sectoral collective agreement, an ' \
          'individual contract or a municipal regulation, or simply that the question would work better ' \
          'phrased with the legal term or the article number.'
      when 'de'
        'In der durchsuchten konsolidierten belgischen Gesetzgebung habe ich keine Bestimmung ' \
          "gefunden, die diese Frage unmittelbar regelt.\n\n" \
          'Das kann bedeuten, dass die Materie außerhalb dieser Quellen geregelt ist, etwa durch ein ' \
          'sektorales Kollektivabkommen, einen Einzelvertrag oder eine Gemeindeverordnung, oder dass die Frage ' \
          'mit dem juristischen Fachbegriff oder der Artikelnummer besser formuliert wäre.'
      else
        'Ik vond in de Belgische geconsolideerde wetgeving die ik heb doorzocht geen bepaling ' \
          "die deze vraag rechtstreeks regelt.\n\nDat kan betekenen " \
          'dat de kwestie buiten die bronnen geregeld wordt, bijvoorbeeld door een sectorale cao, een ' \
          'individuele overeenkomst of een gemeentelijk reglement. Het kan ook helpen de vraag te herformuleren ' \
          'met de juridische term of het artikelnummer.'
      end
    end

    # A specific, verified gap rather than a guess. The German-speaking
    # Community's family-allowance instrument is genuinely absent from the
    # corpus: searching it returns nothing, while 172 of the Community's other
    # post-2020 decrees are present. Child benefit became a Community
    # competence with the Sixth State Reform, so the federal acts that remain in
    # the corpus are the pre-reform ones and would be actively misleading here.
    def unsupported_corpus_message
      case @language
      when 'fr'
        'Les allocations familiales relèvent de la Communauté germanophone, et sa réglementation propre en ' \
          "la matière ne figure pas dans mes sources.\n\nLes textes fédéraux que je possède datent d'avant la " \
          'Sixième Réforme de l\'État et ne sont plus applicables ici, je préfère donc ne pas répondre sur ' \
          'cette base. Adressez-vous au service compétent de la Communauté germanophone.'
      when 'en'
        'Child benefit is a competence of the German-speaking Community, and its own rules on this are not ' \
          "in my sources.\n\nThe federal texts I do hold predate the Sixth State Reform and no longer apply " \
          'here, so I would rather not answer on that basis. The German-speaking Community\'s own service is ' \
          'the right place to ask.'
      when 'de'
        'Das Kindergeld fällt in die Zuständigkeit der Deutschsprachigen Gemeinschaft, und deren eigene ' \
          "Regelung dazu ist in meinen Quellen nicht enthalten.\n\nDie vorhandenen föderalen Texte stammen aus " \
          'der Zeit vor der Sechsten Staatsreform und gelten hier nicht mehr, deshalb antworte ich lieber ' \
          'nicht auf dieser Grundlage. Wenden Sie sich an den zuständigen Dienst der Deutschsprachigen ' \
          'Gemeinschaft.'
      else
        'Kinderbijslag is een bevoegdheid van de Duitstalige Gemeenschap, en haar eigen regeling daarover zit ' \
          "niet in mijn bronnen.\n\nDe federale teksten die ik wel heb, dateren van voor de zesde " \
          'staatshervorming en gelden hier niet meer, dus antwoord ik liever niet op die basis. Richt u tot de ' \
          'bevoegde dienst van de Duitstalige Gemeenschap.'
      end
    end

    # Fail-closed response for questions that require a sealed official source
    # set which is unavailable in the selected answer language.
    def authoritative_source_unavailable_response
      message = case @language
                when 'fr'
                  'Je ne peux pas répondre de manière fiable à cette question, car les sources officielles du ' \
                    'RGPD requises ne sont pas disponibles dans cette langue.'
                when 'en'
                  'I cannot answer this question reliably because the required official GDPR sources are unavailable ' \
                    'in this language.'
                when 'de'
                  'Ich kann diese Frage nicht zuverlässig beantworten, weil die erforderlichen offiziellen ' \
                    'DSGVO-Quellen in dieser Sprache nicht verfügbar sind.'
                else
                  'Ik kan deze vraag niet betrouwbaar beantwoorden omdat de vereiste officiële AVG-bronnen in deze ' \
                    'taal niet beschikbaar zijn.'
                end

      result = {
        answer: message,
        sources: [],
        language: @language,
        # The controller treats an explicit error as non-billable and refunds
        # any up-front credit reservation. A source-unavailable refusal must
        # never look like a successfully grounded paid answer.
        # Keep `error` user-safe: both JSON and SSE clients render this field
        # directly. The stable machine identifier remains separate.
        error: message,
        error_code: 'authoritative_source_unavailable'
      }
      result[:quality_evidence] = ChatbotQualityEvidence.skipped(
        retrieval_status: 'authoritative_source_unavailable'
      ) if @include_quality_evidence
      result
    end
  end
end
