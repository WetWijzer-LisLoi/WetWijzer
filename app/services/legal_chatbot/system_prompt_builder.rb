# frozen_string_literal: true

module LegalChatbot
  # Constructs system prompts for the LLM based on source type,
  # detected language, and query characteristics.
  #
  # This is a thin delegation layer - the actual prompt content lives
  # in the main LegalChatbotService until the full extraction is complete.
  # The service delegates to this class for all prompt construction.
  class SystemPromptBuilder
    include Prompts
    include Profiles

    # Code-owned prompt version (RAT-003). Ratings collected under different
    # prompt text are not comparable, so BUMP THIS whenever prompt wording
    # changes - and note that the prompt is assembled from three places:
    # this class, LegalChatbotService#build_system_prompt (which it delegates
    # to), and Profiles::CHATBOT_PROFILES. A change in any of them counts.
    #
    # It is a version label, never a hash of the prompt: a prompt hash would
    # be a content fingerprint, which the privacy contract forbids.
    PROMPT_VERSION = 'prompt_2026_08'

    def initialize(language: 'nl', concise: false, case_context: nil, profile: 'general')
      @language = language
      @concise = concise
      @case_context = case_context
      @profile = profile
    end

    # Build the appropriate system prompt for the given context.
    # Delegates to the main service's build_system_prompt until full extraction.
    def build(source_type, detected_lang: nil, question: nil)
      # This method is called by LlmClient.
      # During the transition phase, the actual prompt building logic
      # remains in LegalChatbotService.build_system_prompt.
      # After full extraction, this will contain the prompt logic directly.
      #
      # For now, we construct a temporary service instance to access the prompt.
      # This avoids duplicating 300+ lines of domain-specific prompt text.
      service = LegalChatbotService.new(language: @language, concise: @concise, case_context: @case_context)
      prompt = service.send(:build_system_prompt, source_type, detected_lang: detected_lang, question: question)

      # Legal-application guardrails: derived from the 50 material_legal_error
      # judgments of the 2026-07/08 quality runs. The dominant failure (40%)
      # was anchoring the asked concept to a retrieved but inapplicable
      # article; the rest split over niche-regime overgeneralization,
      # outdated law as current, uncalibrated confidence without sources,
      # and missed exceptions inside the model's own quotes.
      prompt = "#{prompt}\n\n#{legal_application_guardrails}"

      # Append the domain-specialization block for the selected profile
      # (Profiles::CHATBOT_PROFILES). Appending here covers both the default
      # and the French base prompts with one injection point. 'general' (and
      # unknown profiles) contribute nothing.
      addition = self.class.build_profile_prompt(@profile)
      return prompt if addition.blank?

      "#{prompt}\n\n=== PROFIEL-SPECIALISATIE / SPÉCIALISATION PROFIL ===\n#{addition}"
    end

    private

    def legal_application_guardrails
      if @language == 'fr'
        <<~PROMPT.strip
          === RÈGLES D'APPLICATION JURIDIQUE (obligatoires) ===
          1. CONTRÔLE DE CONCEPT : avant d'utiliser un article comme fondement, détermine quelle notion juridique cet article régit réellement. Utilise-le uniquement si cette notion correspond à la question posée. Si aucune source ne régit la notion demandée, dis-le explicitement ; ne présente jamais un article voisin comme s'il régissait la question.
          2. CHAMP D'APPLICATION : si une source ne vaut que pour une région, un secteur ou un régime particulier, nomme cette limite dans la première phrase de la réponse et ne présente jamais un régime particulier comme la règle générale.
          3. ACTUALITÉ : vérifie que la règle est encore en vigueur à la date de référence. Les régimes abrogés, transitoires ou de crise doivent être explicitement marqués comme historiques.
          4. PRUDENCE CALIBRÉE : si les sources ne couvrent pas la question, dis que les sources ne la règlent pas. N'affirme jamais une règle - même négative - sans source. Montants, taux et délais uniquement avec référence.
          5. EXCEPTIONS : quand tu cites une disposition, lis aussi les exceptions et conditions contenues dans ce même texte et applique-les.
        PROMPT
      else
        <<~PROMPT.strip
          === JURIDISCHE TOEPASSINGSREGELS (verplicht) ===
          1. CONCEPT-CHECK: bepaal vóór je een artikel als grondslag gebruikt welk rechtsbegrip dat artikel werkelijk regelt. Gebruik het alleen als dat begrip samenvalt met wat gevraagd wordt. Regelt geen enkele bron het gevraagde begrip, zeg dat dan expliciet; presenteer nooit een aanverwant artikel alsof het de vraag regelt.
          2. TOEPASSINGSGEBIED: geldt een bron alleen voor een gewest, sector of bijzonder stelsel, benoem die beperking dan in de eerste zin van het antwoord en presenteer een bijzonder stelsel nooit als de hoofdregel.
          3. ACTUALITEIT: controleer of de regeling op de peildatum nog geldt. Opgeheven, tijdelijke of crisisregelingen markeer je uitdrukkelijk als historisch.
          4. GEKALIBREERDE VOORZICHTIGHEID: dekken de bronnen de vraag niet, zeg dan dat de bronnen dit niet regelen. Stel nooit een regel - ook geen ontkennende - zonder bron. Bedragen, tarieven en termijnen alleen met bronvermelding.
          5. UITZONDERINGEN: citeer je een bepaling, lees dan ook de uitzonderingen en voorwaarden in datzelfde citaat en pas ze toe.
        PROMPT
      end
    end
  end
end
