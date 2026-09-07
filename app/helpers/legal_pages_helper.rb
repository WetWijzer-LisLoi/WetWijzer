# frozen_string_literal: true

module LegalPagesHelper
  CHATBOT_PRICING_COPY = {
    en: {
      level: 'Level', base_credits: 'Base credits per question', models: 'Available models',
      total_credits: 'Total with optional reasoning', providers: 'Provider(s)', locations: 'Processing location',
      reasoning: 'Reasoning',
      reasoning_text: 'Supported reasoning modes add %{surcharges} credits. A surcharge is charged only when the selected model supports and uses that mode; the exact total is shown before sending.'
    },
    nl: {
      level: 'Niveau', base_credits: 'Basiscredits per vraag', models: 'Beschikbare modellen',
      total_credits: 'Totaal met optioneel redeneren', providers: 'Provider(s)', locations: 'Verwerkingslocatie',
      reasoning: 'Redeneren',
      reasoning_text: 'Ondersteunde redeneringsmodi kosten %{surcharges} credits extra. Een toeslag wordt alleen aangerekend wanneer het gekozen model die modus ondersteunt en gebruikt; het exacte totaal staat vóór verzending in beeld.'
    },
    fr: {
      level: 'Niveau', base_credits: 'Crédits de base par question', models: 'Modèles disponibles',
      total_credits: 'Total avec raisonnement facultatif', providers: 'Fournisseur(s)', locations: 'Lieu de traitement',
      reasoning: 'Raisonnement',
      reasoning_text: 'Les modes de raisonnement pris en charge ajoutent %{surcharges} crédits. Un supplément est facturé uniquement si le modèle choisi prend en charge et utilise ce mode ; le total exact est affiché avant l’envoi.'
    },
    de: {
      level: 'Stufe', base_credits: 'Basis-Credits pro Frage', models: 'Verfügbare Modelle',
      total_credits: 'Gesamt mit optionalem Denken', providers: 'Anbieter', locations: 'Verarbeitungsort',
      reasoning: 'Denktiefe',
      reasoning_text: 'Unterstützte Denkmodi kosten %{surcharges} Credits zusätzlich. Ein Aufschlag wird nur berechnet, wenn das gewählte Modell diesen Modus unterstützt und verwendet; die genaue Summe wird vor dem Absenden angezeigt.'
    }
  }.freeze

  CHATBOT_PROVIDER_LABELS = {
    openai: 'Azure OpenAI',
    mistral: 'Mistral AI',
    bedrock: 'AWS Bedrock'
  }.freeze

  CHATBOT_PROVIDER_LOCATIONS = {
    en: { openai: 'Azure EU Data Zone (DataZoneStandard)', mistral: 'EU/EFTA regional API endpoint', bedrock: 'AWS EU geographic profile' },
    nl: { openai: 'Azure EU Data Zone (DataZoneStandard)', mistral: 'regionaal EU/EFTA-API-eindpunt', bedrock: 'AWS EU-geografieprofiel' },
    fr: { openai: 'zone de données UE Azure (DataZoneStandard)', mistral: 'point de terminaison API régional UE/AELE', bedrock: 'profil géographique UE AWS' },
    de: { openai: 'Azure EU Data Zone (DataZoneStandard)', mistral: 'regionaler EU/EFTA-API-Endpunkt', bedrock: 'AWS-EU-Geografieprofil' }
  }.freeze

  CHATBOT_PROVIDER_SCOPE_BADGES = {
    en: { openai: 'Azure · EU-scoped', mistral: 'Mistral · EU/EFTA API', bedrock: 'AWS · EU profile' },
    nl: { openai: 'Azure · EU-bereik', mistral: 'Mistral · EU/EFTA-API', bedrock: 'AWS · EU-profiel' },
    fr: { openai: 'Azure · portée UE', mistral: 'Mistral · API UE/AELE', bedrock: 'AWS · profil UE' },
    de: { openai: 'Azure · EU-begrenzt', mistral: 'Mistral · EU/EFTA-API', bedrock: 'AWS · EU-Profil' }
  }.freeze

  CHATBOT_PROCESSING_SUMMARIES = {
    en: 'AI requests use European-scoped processing. All offered Azure models use DataZoneStandard in the Azure EU Data Zone; requests may route within Microsoft\'s documented EU boundary. AWS Bedrock uses EU geographic inference profiles. Mistral requests use api.eu.mistral.ai, whose documented regional boundary is EU/EFTA rather than EU-member-state-only; Mistral also states that some features or subprocessors can involve safeguarded temporary transfers outside that region.',
    nl: 'AI-vragen gebruiken verwerking met een Europees bereik. Alle aangeboden Azure-modellen gebruiken DataZoneStandard in de Azure EU Data Zone; vragen kunnen binnen Microsofts gedocumenteerde EU-grens routeren. AWS Bedrock gebruikt geografische EU-inferentieprofielen. Mistral-vragen gebruiken api.eu.mistral.ai, waarvan de gedocumenteerde regiogrens EU/EFTA is en dus niet uitsluitend EU-lidstaten omvat; Mistral vermeldt ook dat bepaalde functies of subverwerkers tijdelijk beveiligde doorgiften buiten die regio kunnen meebrengen.',
    fr: 'Les requêtes IA utilisent un traitement à portée européenne. Tous les modèles Azure proposés utilisent DataZoneStandard dans la zone de données UE Azure ; les requêtes peuvent être routées dans la limite UE documentée par Microsoft. AWS Bedrock utilise des profils d’inférence géographiques UE. Les requêtes Mistral utilisent api.eu.mistral.ai, dont la limite régionale documentée est UE/AELE et non exclusivement les États membres de l’UE ; Mistral indique aussi que certaines fonctionnalités ou certains sous-traitants peuvent impliquer des transferts temporaires encadrés hors de cette région.',
    de: 'KI-Anfragen werden mit europäisch begrenzter Verarbeitung ausgeführt. Alle angebotenen Azure-Modelle nutzen DataZoneStandard in der Azure EU Data Zone; Anfragen können innerhalb der von Microsoft dokumentierten EU-Grenze geroutet werden. AWS Bedrock nutzt geografische EU-Inferenzprofile. Mistral-Anfragen verwenden api.eu.mistral.ai, dessen dokumentierte Regionsgrenze EU/EFTA und nicht ausschließlich EU-Mitgliedstaaten umfasst; Mistral weist außerdem darauf hin, dass bestimmte Funktionen oder Unterauftragsverarbeiter vorübergehende, abgesicherte Übermittlungen außerhalb dieser Region mit sich bringen können.'
  }.freeze

  def chatbot_pricing_copy(locale = I18n.locale)
    CHATBOT_PRICING_COPY.fetch(locale.to_sym, CHATBOT_PRICING_COPY[:en])
  end

  def chatbot_processing_location_summary(locale = I18n.locale)
    CHATBOT_PROCESSING_SUMMARIES.fetch(locale.to_sym, CHATBOT_PROCESSING_SUMMARIES[:en])
  end

  def chatbot_provider_location(provider, locale = I18n.locale)
    CHATBOT_PROVIDER_LOCATIONS
      .fetch(locale.to_sym, CHATBOT_PROVIDER_LOCATIONS[:en])
      .fetch(provider.to_sym)
  end

  def chatbot_provider_scope_badge(provider, locale = I18n.locale)
    CHATBOT_PROVIDER_SCOPE_BADGES
      .fetch(locale.to_sym, CHATBOT_PROVIDER_SCOPE_BADGES[:en])
      .fetch(provider.to_sym)
  end

  def chatbot_pricing_rows(locale = I18n.locale)
    locale = locale.to_sym

    LegalChatbotService::INTELLIGENCE_LEVELS.map do |level_id, level|
      models = level.fetch(:models).map do |model_id, tier_model|
        model_config = LegalChatbotService::AVAILABLE_MODELS.fetch(model_id)
        base_credits = LegalChatbotService.credits_for_model(level_id, model_id)
        supported_efforts = LegalChatbotService.reasoning_levels_for_model(model_id)
        totals = if supported_efforts.empty?
                   [base_credits]
                 else
                   supported_efforts.map do |effort|
                     LegalChatbotService.credits_with_reasoning(level_id, effort, model_id)
                   end
                 end

        {
          id: model_id,
          name: tier_model[:name] || model_config[:name],
          base_credits: base_credits,
          total_credits: totals,
          provider: model_config.fetch(:provider)
        }
      end
      providers = models.map { |model| model[:provider] }.uniq

      {
        id: level_id,
        label: level.fetch(:labels).fetch(locale, level.fetch(:labels).fetch(:en)),
        models: models,
        base_credits: models.map { |model| model[:base_credits] },
        total_credits: models.flat_map { |model| model[:total_credits] },
        providers: providers.map { |provider| CHATBOT_PROVIDER_LABELS.fetch(provider) },
        locations: providers.map { |provider| CHATBOT_PROVIDER_LOCATIONS.fetch(locale, CHATBOT_PROVIDER_LOCATIONS[:en]).fetch(provider) }
      }
    end
  end

  def chatbot_credit_range(values, locale = I18n.locale)
    values = Array(values).map(&:to_i)
    minimum, maximum = values.minmax
    amount = minimum == maximum ? minimum.to_s : "#{minimum}–#{maximum}"
    singular = minimum == maximum && minimum == 1
    unit = case locale.to_sym
           when :fr then singular ? 'crédit' : 'crédits'
           when :de then singular ? 'Credit' : 'Credits'
           else singular ? 'credit' : 'credits'
           end
    "#{amount} #{unit}"
  end

  def chatbot_reasoning_surcharge_list
    LegalChatbotService::REASONING_LEVELS.values
      .map { |level| level.fetch(:surcharge) }
      .uniq
      .sort
      .map { |surcharge| "+#{surcharge}" }
      .join(' / ')
  end

  def chatbot_overall_credit_range(locale = I18n.locale)
    chatbot_credit_range(chatbot_pricing_rows(locale).flat_map { |row| row[:total_credits] }, locale)
  end

  def chatbot_model_names_for_provider(provider)
    LegalChatbotService::AVAILABLE_MODELS
      .select { |_model_id, config| config[:provider] == provider.to_sym }
      .values
      .map { |config| config.fetch(:name) }
      .join(', ')
  end

  def chatbot_level_labels_for_provider(provider, locale = I18n.locale)
    chatbot_pricing_rows(locale)
      .select { |row| row[:models].any? { |model| model[:provider] == provider.to_sym } }
      .map { |row| row[:label] }
      .join(' / ')
  end

  def chatbot_model_names_for_level(level, locale = I18n.locale)
    chatbot_pricing_rows(locale)
      .find { |row| row[:id] == level.to_s }
      .fetch(:models)
      .map { |model| model[:name] }
      .join(' / ')
  end

  def chatbot_base_credit_range_for(level, locale = I18n.locale)
    row = chatbot_pricing_rows(locale).find { |pricing_row| pricing_row[:id] == level.to_s }
    chatbot_credit_range(row.fetch(:base_credits), locale)
  end

  def chatbot_model_names_for_access(tier)
    LegalChatbotService::AVAILABLE_MODELS
      .select { |_model_id, config| config[:tier] == tier.to_sym }
      .values
      .map { |config| config.fetch(:name) }
      .join(', ')
  end

  def chatbot_all_model_names
    LegalChatbotService::AVAILABLE_MODELS.values.map { |config| config.fetch(:name) }.join(', ')
  end
end
