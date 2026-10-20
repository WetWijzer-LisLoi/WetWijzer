# frozen_string_literal: true

module LegalPagesHelper
  PRICING_ACCESS_COPY = {
    nl: {
      starter: 'Bij uw eerste registratie ontvangt u eenmalig %{credits} gratis startcredits. Ze komen in hetzelfde saldo als gekochte en inbegrepen Pro-credits en kunnen worden gebruikt voor beschikbare combinaties waarvan de totaalprijs binnen uw saldo past. Een gewoon account heeft modeltoegang tot en met Grondig.',
      catalogue: '%{available} beschikbare modellen bij %{providers} providers · %{pending} modellen binnenkort · verwerking met Europees bereik',
      catalogue_available: '%{available} beschikbare modellen bij %{providers} providers · verwerking met Europees bereik',
      base_credit: 'basiscredit', base_credits: 'basiscredits',
      access: 'Een gewoon account kan alle beschikbare modellen en ondersteunde denkmodi van Snel, Gebalanceerd en Grondig gebruiken. Alleen Uitgebreid vereist daarnaast een actief Pro-abonnement. Elke vraag vereist voldoende credits; startcredits, gekochte credits en inbegrepen Pro-credits werken op dezelfde manier en vervallen niet.',
      source_access: 'Pro geeft ook toegang tot rechtspraak en parlementaire documenten in de chatbot. Zelf zoeken en documenten lezen op de website blijft gratis.',
      pending: 'Modellen met “Binnenkort” zijn nog niet beschikbaar en kunnen niet worden geselecteerd.'
    },
    fr: {
      starter: 'Lors de votre première inscription, vous recevez une seule fois %{credits} crédits de bienvenue gratuits. Ils rejoignent le même solde que les crédits achetés et inclus avec Pro et permettent d’utiliser les combinaisons disponibles dont le coût total ne dépasse pas votre solde. Un compte ordinaire a accès aux modèles jusqu’à Approfondie.',
      catalogue: '%{available} modèles disponibles chez %{providers} fournisseurs · %{pending} modèles bientôt disponibles · traitement à portée européenne',
      catalogue_available: '%{available} modèles disponibles chez %{providers} fournisseurs · traitement à portée européenne',
      base_credit: 'crédit de base', base_credits: 'crédits de base',
      access: 'Un compte ordinaire peut utiliser tous les modèles et modes de raisonnement pris en charge disponibles dans Rapide, Équilibrée et Approfondie. Seule Étendue nécessite aussi un abonnement Pro actif. Chaque question exige suffisamment de crédits ; les crédits de bienvenue, achetés et inclus avec Pro fonctionnent de la même manière et n’expirent pas.',
      source_access: 'Pro donne aussi accès à la jurisprudence et aux documents parlementaires dans le chatbot. La recherche et la lecture des documents sur le site restent gratuites.',
      pending: 'Les modèles marqués « Bientôt disponible » ne sont pas encore disponibles et ne peuvent pas être sélectionnés.'
    },
    de: {
      starter: 'Bei Ihrer ersten Registrierung erhalten Sie einmalig %{credits} kostenlose Startcredits. Sie kommen zum gleichen Guthaben wie gekaufte und in Pro enthaltene Credits und können für verfügbare Kombinationen genutzt werden, deren Gesamtpreis durch Ihr Guthaben gedeckt ist. Ein normales Konto hat Modellzugang bis einschließlich Gründlich.',
      catalogue: '%{available} verfügbare Modelle von %{providers} Anbietern · %{pending} Modelle demnächst · europäisch begrenzte Verarbeitung',
      catalogue_available: '%{available} verfügbare Modelle von %{providers} Anbietern · europäisch begrenzte Verarbeitung',
      base_credit: 'Basis-Credit', base_credits: 'Basis-Credits',
      access: 'Ein normales Konto kann alle verfügbaren Modelle und unterstützten Denkmodi in Schnell, Ausgewogen und Gründlich nutzen. Nur Umfassend erfordert zusätzlich ein aktives Pro-Abonnement. Jede Frage benötigt ausreichend Credits; Startcredits, gekaufte und in Pro enthaltene Credits funktionieren gleich und verfallen nicht.',
      source_access: 'Pro ermöglicht auch den Zugriff auf Rechtsprechung und parlamentarische Dokumente im Chatbot. Die Suche und das Lesen der Dokumente auf der Website bleiben kostenlos.',
      pending: 'Mit „Demnächst verfügbar“ gekennzeichnete Modelle sind noch nicht verfügbar und können nicht ausgewählt werden.'
    },
    en: {
      starter: 'On your first registration, you receive %{credits} free starter credits once. They join the same balance as purchased credits and credits included with Pro and can fund available combinations whose total price fits your balance. A regular account has model access through Thorough.',
      catalogue: '%{available} available models from %{providers} providers · %{pending} models coming soon · European-scoped processing',
      catalogue_available: '%{available} available models from %{providers} providers · European-scoped processing',
      base_credit: 'base credit', base_credits: 'base credits',
      access: 'A regular account can use all available models and supported reasoning modes in Quick, Balanced and Thorough. Only Extensive also requires an active Pro subscription. Every question needs sufficient credits; starter credits, purchased credits and credits included with Pro work in the same way and never expire.',
      source_access: 'Pro also unlocks case law and parliamentary documents in the chatbot. Searching and reading documents on the website remains free.',
      pending: 'Models marked “Coming soon” are not available yet and cannot be selected.'
    }
  }.freeze

  CHATBOT_PRICING_COPY = {
    en: {
      level: 'Level', base_credits: 'Base credits per question', models: 'Available models',
      total_credits: 'Total at the selected research depth', providers: 'Provider(s)', locations: 'Processing location',
      reasoning: 'Research depth', preview: 'Preview',
      reasoning_text: 'The bar and dropdown select the same model/reasoning combination and update each other. Each equally spaced tick is one choice, grouped by research depth and then by total cost within each group; a taller tick marks the first choice at a new total price. Combinations with the same price have separate steps. Your combination sets the research budget. Supported and used extra reasoning adds %{surcharges} credits to the model price; the exact total is always shown before sending. Source and citation checks always apply; a higher cost does not guarantee a better answer.'
    },
    nl: {
      level: 'Niveau', base_credits: 'Basiscredits per vraag', models: 'Beschikbare modellen',
      total_credits: 'Totaal bij gekozen onderzoeksdiepte', providers: 'Provider(s)', locations: 'Verwerkingslocatie',
      reasoning: 'Onderzoeksdiepte', preview: 'Testversie',
      reasoning_text: 'De balk en keuzelijst kiezen dezelfde model-denkwerkcombinatie en houden elkaar bij. Elk streepje is één keuze, op gelijke afstand, gegroepeerd per onderzoeksdiepte en daarbinnen op totale kosten; een hoger streepje markeert de eerste keuze met een nieuwe totaalprijs. Combinaties met dezelfde prijs hebben elk een eigen stap. Uw combinatie bepaalt het onderzoeksbudget. Ondersteund en gebruikt extra denkwerk kost %{surcharges} credits bovenop de modelprijs; het exacte totaal staat altijd vóór verzending bij uw keuze. Bron- en citaatcontrole gelden altijd; een hogere prijs garandeert geen beter antwoord.'
    },
    fr: {
      level: 'Niveau', base_credits: 'Crédits de base par question', models: 'Modèles disponibles',
      total_credits: 'Total selon la profondeur de recherche', providers: 'Fournisseur(s)', locations: 'Lieu de traitement',
      reasoning: 'Profondeur de recherche', preview: 'Version préliminaire',
      reasoning_text: 'La barre et la liste choisissent la même combinaison de modèle et de raisonnement et se mettent à jour mutuellement. Chaque trait est un choix, espacé régulièrement, regroupé par profondeur de recherche puis par coût total au sein de chaque groupe ; un trait plus haut marque le premier choix à un nouveau prix total. Les combinaisons au même prix ont des positions distinctes. Votre combinaison fixe le budget de recherche. Le raisonnement supplémentaire pris en charge et utilisé ajoute %{surcharges} crédits au prix du modèle ; le total exact est toujours affiché avant l’envoi. Les contrôles des sources et citations restent toujours applicables ; un prix supérieur ne garantit pas une meilleure réponse.'
    },
    de: {
      level: 'Stufe', base_credits: 'Basis-Credits pro Frage', models: 'Verfügbare Modelle',
      total_credits: 'Gesamt beim gewählten Rechercheumfang', providers: 'Anbieter', locations: 'Verarbeitungsort',
      reasoning: 'Rechercheumfang', preview: 'Vorschauversion',
      reasoning_text: 'Leiste und Auswahlliste wählen dieselbe Modell-Denkaufwand-Kombination und aktualisieren sich gegenseitig. Jeder Strich ist eine Auswahl mit gleichem Abstand, nach Rechercheumfang gruppiert und innerhalb jeder Gruppe nach Gesamtkosten sortiert; ein höherer Strich markiert die erste Auswahl mit einem neuen Gesamtpreis. Gleich teure Kombinationen haben eigene Schritte. Ihre Kombination bestimmt das Recherchebudget. Unterstützter und verwendeter zusätzlicher Denkaufwand kostet %{surcharges} Credits zusätzlich zum Modellpreis; die genaue Summe wird immer vor dem Absenden angezeigt. Quellen- und Zitatprüfungen gelten immer; ein höherer Preis garantiert keine bessere Antwort.'
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

  def pricing_access_copy(locale = I18n.locale)
    PRICING_ACCESS_COPY.fetch(locale.to_sym, PRICING_ACCESS_COPY[:en])
  end

  def chatbot_pricing_availability(rows = chatbot_pricing_rows)
    models = rows.flat_map { |row| row.fetch(:models) }
    available = models.reject { |model| LegalChatbotService::AVAILABLE_MODELS.fetch(model.fetch(:id))[:deployed] == false }
    { available: available.size, providers: available.map { |model| model.fetch(:provider) }.uniq.size,
      pending: models.size - available.size }
  end

  # The summary line of the pricing page. The "coming soon" clause appears
  # only while a configured model is not deployed; since 2026-10-19 none is.
  def chatbot_pricing_catalogue_summary(locale = I18n.locale, availability = chatbot_pricing_availability)
    key = availability.fetch(:pending).positive? ? :catalogue : :catalogue_available
    pricing_access_copy(locale).fetch(key) % availability
  end

  def chatbot_base_credit_label(values, locale = I18n.locale)
    minimum, maximum = Array(values).map(&:to_i).minmax
    amount = minimum == maximum ? minimum.to_s : "#{minimum}–#{maximum}"
    unit = minimum == maximum && minimum == 1 ? :base_credit : :base_credits
    "#{amount} #{pricing_access_copy(locale).fetch(unit)}"
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
    locale = :en unless %i[nl fr de en].include?(locale)

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
          provider: model_config.fetch(:provider),
          pro: model_config.fetch(:tier) == :pro,
          preview: model_config[:preview] == true
        }
      end
      providers = models.map { |model| model[:provider] }.uniq
      depths = models.flat_map do |model|
        efforts = LegalChatbotService.reasoning_levels_for_model(model[:id])
        efforts = ['fixed'] if efforts.empty?
        efforts.map { |effort| LegalChatbotService.research_depth_for_combination(model[:id], effort) }
      end.uniq.sort_by { |depth| LegalChatbotService::RESEARCH_DEPTHS.keys.index(depth) }

      {
        id: level_id,
        label: depths.map { |depth| I18n.t("chatbot.research_depth.options.#{depth}.label", locale: locale) }.join(' / '),
        description: depths.map { |depth| I18n.t("chatbot.research_depth.options.#{depth}.description", locale: locale) }.join(' '),
        pro: models.any? && models.all? { |model| model[:pro] },
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

  def chatbot_model_display_name(model_id, locale = I18n.locale)
    config = LegalChatbotService::AVAILABLE_MODELS.fetch(model_id)
    name = config.fetch(:name)
    return name unless config[:deployed] == false

    locale = locale.to_sym
    locale = :en unless %i[nl fr de en].include?(locale)
    "#{name} — #{I18n.t('chatbot.model_coming_soon', locale: locale)}"
  end

  def chatbot_model_names_for_provider(provider, locale = I18n.locale)
    LegalChatbotService::AVAILABLE_MODELS
      .select { |_model_id, config| config[:provider] == provider.to_sym }
      .map { |id, _config| chatbot_model_display_name(id, locale) }
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
      .map { |model| chatbot_model_display_name(model[:id], locale) }
      .join(' / ')
  end

  def chatbot_base_credit_range_for(level, locale = I18n.locale)
    row = chatbot_pricing_rows(locale).find { |pricing_row| pricing_row[:id] == level.to_s }
    chatbot_credit_range(row.fetch(:base_credits), locale)
  end

  def chatbot_model_names_for_access(tier, locale = I18n.locale)
    LegalChatbotService::AVAILABLE_MODELS
      .select { |_model_id, config| config[:tier] == tier.to_sym }
      .map { |id, _config| chatbot_model_display_name(id, locale) }
      .join(', ')
  end

  def chatbot_all_model_names(locale = I18n.locale)
    LegalChatbotService::AVAILABLE_MODELS.keys.map { |id| chatbot_model_display_name(id, locale) }.join(', ')
  end
end
