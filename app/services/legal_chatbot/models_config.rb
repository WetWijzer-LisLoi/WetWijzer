# frozen_string_literal: true

require 'bigdecimal'
require 'fileutils'

# AI model definitions, tier hierarchy, and access control for LegalChatbotService.
# Extracted from the monolith to isolate model configuration from business logic.
#
# ═══════════════════════════════════════════════════════════════════════════════
# THIS FILE IS THE SINGLE SOURCE OF TRUTH FOR MODEL DEFINITIONS.
# WHEN ADDING/REMOVING AI MODELS - checklist:
# ═══════════════════════════════════════════════════════════════════════════════
#  1. HERE → AVAILABLE_MODELS           (model definition, provider, cost, data_region)
#  2. HERE → INTELLIGENCE_LEVELS        (tier assignment + credit cost)
#  3. HERE → MODEL_DAILY_CAPS           (per-model daily spending limit)
#  4. HERE → REASONING_CAPABLE_MODELS   (auto-derived from provider - no manual edit)
#  5. llm_client.rb → AZURE_DEPLOYMENT_NAMES   (if Azure deployment name ≠ model ID)
#  6. llm_client.rb → mistral_model_id case    (if Mistral: internal ID → API model ID)
#  7. HERE → :bedrock_inference_profile       (if Bedrock: exact geographic profile)
#  8. index.html.erb  → auto-derived via REASONING_CAPABLE_MODELS (no manual edit)
#  9. Browser model names and pricing cards → auto-derived from this registry
# 10. api/chatbot_controller.rb → DEEP_ANALYSIS_MODELS (auto-derived - no manual edit)
# 11. api/partner_controller.rb → DEEP_MODELS (auto-derived - no manual edit)
# 12. legal_chatbot_service.rb → reasoning checks (auto-derived - no manual edit)
# ═══════════════════════════════════════════════════════════════════════════════
#
# ARCHITECTURE NOTE (June 2026 - GDPR Cleanup):
#   All config here is LIVE infrastructure:
#   - CHAT_MODEL, cost_per_query_eur, MODEL_DAILY_CAPS → cost protection
#   - Tier hierarchy, extra_credits, model_allowed? → user access control
#   - HMAC service auth in chatbot_controller.rb for app-level service access
#
#   gpt-5.4-nano and gpt-5.4-mini REMOVED (June 2026 GDPR audit):
#   Only GlobalStandard SKU available in Sweden Central - data may leave EU.
#   No Standard or DataZoneStandard SKU. Not GDPR compliant for legal data.
module LegalChatbot
  module ModelsConfig
    extend ActiveSupport::Concern

    class BudgetLimitExceeded < StandardError
      attr_reader :reason, :model, :provider

      def initialize(reason:, model:, provider: nil)
        @reason = reason
        @model = model
        @provider = provider
        super("AI budget reservation rejected: #{reason} (#{model})")
      end
    end

    EMBEDDING_MODEL = 'text-embedding-3-large'
    EMBEDDING_DIMENSIONS = 3072 # Must match articles_large_pq.faiss
    CHAT_MODEL = 'mistral-small'
    # The selection a fresh browser shows before any saved or explicit
    # choice (owner 2026-10-18): Gebalanceerd with GPT-6 Luna at low effort,
    # priced by the ordinary credit calculation. It is a rendering default
    # only: saved preferences, explicit requests, CHAT_MODEL and the API's
    # missing-parameter fallback are unchanged, and Mistral stays selectable.
    UI_DEFAULT_SELECTION = { intelligence: 'genius', model: 'gpt-6-luna', reasoning_effort: 'low' }.freeze
    # Deprecated IDs are rejected before billing so stale clients cannot be
    # silently charged at a replacement model's price. Browser preferences
    # migrate these IDs explicitly and then resubmit with the new tier/cost.
    RETIRED_MODEL_REPLACEMENTS = {
      'o4-mini' => 'gpt-6-luna',
      'gpt-5-mini' => 'gpt-6-luna',
      'gpt-5.6-luna' => 'gpt-6-luna',
      'gpt-5' => 'gpt-6.1-sol',
      'gpt-5.4' => 'gpt-6.1-sol',
      'gpt-5.5' => 'gpt-6.1-sol',
      'gpt-5.6-terra' => 'gpt-6.1-sol',
      'gpt-5.6-sol' => 'gpt-6.1-sol',
      'gpt-6-sol' => 'gpt-6.1-sol',
      'mistral-large-3' => 'mistral-large-4',
      'claude-4.5-haiku' => 'claude-haiku-5-5',
      'claude-sonnet-4-6' => 'claude-sonnet-5-5',
      'claude-opus-4-6' => 'claude-opus-5-5'
    }.freeze
    # Historical analytics rows outlive the active catalogue. Keep their
    # provider classification explicit for reporting only; this map is never
    # consulted by model selection or provider dispatch.
    RETIRED_MODEL_PROVIDERS = {
      'o4-mini' => :openai,
      'gpt-5-mini' => :openai,
      'gpt-5.6-luna' => :openai,
      'gpt-5' => :openai,
      'gpt-5.4' => :openai,
      'gpt-5.5' => :openai,
      'gpt-5.6-terra' => :openai,
      'gpt-5.6-sol' => :openai,
      'gpt-6-sol' => :openai,
      'mistral-large-3' => :mistral,
      'claude-4.5-haiku' => :bedrock,
      'claude-sonnet-4-6' => :bedrock,
      'claude-opus-4-6' => :bedrock
    }.freeze
    # Display-only metadata keeps past analytics readable. These IDs are not
    # offered, authorized or dispatched by the active model catalogue.
    RETIRED_MODEL_NAMES = {
      'o4-mini' => 'o4-mini',
      'gpt-5-mini' => 'GPT-5 Mini',
      'gpt-5' => 'GPT-5',
      'gpt-5.4' => 'GPT-5.4',
      'gpt-5.5' => 'GPT-5.5',
      'gpt-5.6-luna' => 'GPT-5.6 Luna',
      'gpt-5.6-terra' => 'GPT-5.6 Terra',
      'gpt-5.6-sol' => 'GPT-5.6 Sol',
      'gpt-6-sol' => 'GPT-6 Sol',
      'mistral-large-3' => 'Mistral Large 3',
      'claude-4.5-haiku' => 'Claude Haiku 4.5',
      'claude-sonnet-4-6' => 'Claude Sonnet 4.6',
      'claude-opus-4-6' => 'Claude Opus 4.6'
    }.freeze
    MAX_CONTEXT_ARTICLES = 12 # Increased from 5 for better topic coverage (May 2026 benchmark)

    # Intelligence keys remain for API compatibility and canonical model grouping.
    # Linked clients derive the bounded retrieval profile from the chosen model's
    # group and select an exact supported reasoning variant independently.
    # Each internal tier has a base credit cost.
    # intelligence=smart|genius|mastermind|omniscient (internal keys)
    #   → maps to model(s) + base credit cost (per-model overrides possible)
    # Legacy clients choose Low/Medium/High directly. New clients choose an
    # independent research-depth profile when linked_research is absent, mapped
    # to supported reasoning effort and its existing surcharge.
    #
    # Access: all deployed models and supported reasoning variants through
    #          Meesterbrein/Grondig are available to accounts with credits.
    #          Alwetend/Uitgebreid remains Pro; pending models stay unavailable.
    #
    # ARCHITECTURE NOTE (June 2026 - 4-Tier Consolidation + Per-Model Credits):
    #   Models within a tier can override the tier-level credit cost via :credits.
    #   credits_for_model(level, model) checks model-specific :credits first,
    #   then falls back to the tier's base :credits.
    #
    #   Exact current per-model costs and credit prices are defined below.
    INTELLIGENCE_LEVELS = {
      'smart' => {
        credits: 1,
        tier: :free,
        icon: '',
        reasoning_effort: 'low',
        supports_reasoning: true, # Mistral Small 4 supports reasoning
        tag: nil,
        labels: { nl: 'Slim', fr: 'Malin', de: 'Schlau', en: 'Smart' },
        descriptions: { nl: 'Snel & betrouwbaar', fr: 'Rapide & fiable', de: 'Schnell & zuverlässig', en: 'Fast & reliable' },
        default_model: 'mistral-small',
        models: {
          'mistral-small' => { name: 'Mistral Small 4', tier: :free, credits: 1, estimated_seconds: 8 }
        }
      },
      'genius' => {
        # A model-specific credit price overrides this tier fallback.
        credits: 4,
        tier: :free,
        icon: '',
        reasoning_effort: 'medium',
        supports_reasoning: true,
        tag: nil,
        labels: { nl: 'Geniaal', fr: 'Génial', de: 'Genial', en: 'Genius' },
        descriptions: { nl: 'Diepgaande analyse', fr: 'Analyse approfondie', de: 'Tiefgehende Analyse', en: 'Deep analysis' },
        default: true,
        default_model: 'gpt-6-luna',
        models: {
          'gpt-6-luna' => { name: 'GPT-6 Luna', tier: :free, credits: 2, estimated_seconds: 20 },
          'claude-haiku-5-5' => { name: 'Claude Haiku 5.5', tier: :free, credits: 2, estimated_seconds: 12 },
          'mistral-large-4' => { name: 'Mistral Large 4', tier: :free, credits: 4, estimated_seconds: 14, preview: true }
        }
      },
      'mastermind' => {
        credits: 5,
        tier: :free,
        icon: '',
        reasoning_effort: 'medium',
        supports_reasoning: true,
        tag: nil,
        labels: { nl: 'Meesterbrein', fr: 'Cerveau', de: 'Meisterhirn', en: 'Mastermind' },
        descriptions: { nl: 'Uitgebreide analyse', fr: 'Analyse étendue', de: 'Umfassende Analyse', en: 'Extended analysis' },
        default_model: 'gpt-6.1-sol',
        models: {
          'claude-sonnet-5-5' => { name: 'Claude Sonnet 5.5', tier: :free, credits: 6, estimated_seconds: 20 },
          'gpt-6.1-sol' => { name: 'GPT-6.1 Sol', tier: :free, credits: 6, estimated_seconds: 15 }
        }
      },
      'omniscient' => {
        credits: 12,
        tier: :subscriber,
        icon: '',
        reasoning_effort: 'medium', # Claude Opus 5.5 supports adaptive reasoning
        supports_reasoning: true,
        tag: nil,
        labels: { nl: 'Alwetend', fr: 'Omniscient', de: 'Allwissend', en: 'Omniscient' },
        descriptions: { nl: 'Geavanceerde modelopties', fr: 'Options de modèles avancées', de: 'Fortgeschrittene Modelloptionen', en: 'Advanced model options' },
        default_model: 'claude-opus-5-5',
        models: {
          'claude-opus-5-5' => { name: 'Claude Opus 5.5', tier: :pro, credits: 12, estimated_seconds: 25 }
        }
      }
    }.freeze

    INTELLIGENCE_RESEARCH_DEPTHS = {
      'smart' => 'quick', 'genius' => 'balanced',
      'mastermind' => 'thorough', 'omniscient' => 'extensive'
    }.freeze

    # Research categories describe a retrieval budget, not a demonstrated
    # ranking of answer quality. Extra supported thinking on Small is a
    # balanced combination; low/none keeps its quick budget and base price.
    MODEL_REASONING_RESEARCH_DEPTHS = {
      'mistral-small' => { 'high' => 'balanced' }.freeze
    }.freeze

    # Reasoning levels with credit surcharges.
    # Higher reasoning = more chain-of-thought tokens = higher API cost.
    # Surcharge is ADDED to the intelligence tier's base credits.
    # Example: Level II (3cr) + High (+2cr) = 5cr total.
    REASONING_LEVELS = {
      'low' => {
        surcharge: 0,
        icon: '',
        estimated_seconds: 15,
        labels: { nl: 'Snel', fr: 'Rapide', de: 'Schnell', en: 'Fast' },
        cost_labels: { nl: '+0 credits', fr: '+0 crédit', de: '+0 Credits', en: '+0 credits' },
        descriptions: { nl: 'Snelle antwoorden', fr: 'Réponses rapides', de: 'Schnelle Antworten', en: 'Quick answers' },
        recommended_for: %w[smart],
        warning_for: []
      },
      'medium' => {
        surcharge: 1,  # +1 credit for moderate chain-of-thought reasoning
        icon: '⚖️',
        estimated_seconds: 25,
        labels: { nl: 'Gebalanceerd', fr: 'Équilibré', de: 'Ausgewogen', en: 'Balanced' },
        cost_labels: { nl: '+1 credit', fr: '+1 crédit', de: '+1 Credit', en: '+1 credit' },
        descriptions: { nl: 'Meer nadenken', fr: 'Plus de réflexion', de: 'Mehr Nachdenken', en: 'More thinking' },
        recommended_for: %w[genius mastermind],
        warning_for: %w[smart]
      },
      'high' => {
        surcharge: 2,  # +2 credits for maximum reasoning depth
        icon: '🔬',
        estimated_seconds: 45,
        labels: { nl: 'Diepgaand', fr: 'Approfondi', de: 'Tiefgehend', en: 'Deep' },
        cost_labels: { nl: '+2 credits', fr: '+2 crédits', de: '+2 Credits', en: '+2 credits' },
        descriptions: { nl: 'Maximaal redeneren', fr: 'Raisonnement maximal', de: 'Maximales Denken', en: 'Maximum reasoning' },
        recommended_for: %w[mastermind],
        warning_for: %w[smart]
      }
    }.freeze

    # Bounded research profiles are independent of selected source categories.
    # Linked clients derive the profile from the canonical model group; older
    # clients may still supply a depth directly under the same access boundary.
    # These are bounded relevance budgets, not promised source counts. Every
    # stop keeps the same citation/quote/scope guards and mandatory legal packs.
    # Retrieval itself has no surcharge; only an actually supported/used
    # reasoning mode uses the existing +0/+1/+2 credit schedule.
    RESEARCH_DEPTHS = {
      'quick' => {
        reasoning_effort: 'low', max_article_chars: 1800,
        legislation: 5, jurisprudence: 1, parliamentary: 1, fisconet: 3, regional: 3,
        legislation_candidates: 15, keyword_candidates: 5, keyword_passes: 1,
        jurisprudence_candidates: 3, parliamentary_candidates: 3,
        fisconet_candidates: 4, regional_candidates: 3, lexical_quota: 2
      }.freeze,
      'balanced' => {
        reasoning_effort: 'medium', max_article_chars: 2000,
        legislation: 6, jurisprudence: 2, parliamentary: 2, fisconet: 3, regional: 3,
        legislation_candidates: 18, keyword_candidates: 7, keyword_passes: 1,
        jurisprudence_candidates: 4, parliamentary_candidates: 4,
        fisconet_candidates: 5, regional_candidates: 3, lexical_quota: 2
      }.freeze,
      'thorough' => {
        reasoning_effort: 'high', max_article_chars: 2200,
        legislation: 7, jurisprudence: 2, parliamentary: 2, fisconet: 3, regional: 3,
        legislation_candidates: 21, keyword_candidates: 9, keyword_passes: 2,
        jurisprudence_candidates: 5, parliamentary_candidates: 5,
        fisconet_candidates: 6, regional_candidates: 6, lexical_quota: 3
      }.freeze,
      'extensive' => {
        reasoning_effort: 'high', max_article_chars: 2500,
        legislation: 8, jurisprudence: 3, parliamentary: 3, fisconet: 3, regional: 3,
        legislation_candidates: 24, keyword_candidates: 12, keyword_passes: 3,
        jurisprudence_candidates: 6, parliamentary_candidates: 6,
        fisconet_candidates: 7, regional_candidates: 6, lexical_quota: 3
      }.freeze
    }.freeze

    # Available AI models with tier requirements and credit costs
    AVAILABLE_MODELS = {
      'gpt-6-luna' => {
        name: 'GPT-6 Luna',
        provider: :openai,
        reasoning_support: :openai_effort,
        tier: :free,
        deployed: true,
        data_region: :eu,
        deployment_type: :data_zone_standard,
        deployment_version: '2026-09-22',
        azure_capacity_units: 100,
        extra_credits: 0,
        input_usd_per_million_tokens: 0.12,
        output_usd_per_million_tokens: 0.60,
        cost_per_query_eur: 0.004,
        description_nl: 'GPT-6 Luna - efficiënt redeneren',
        description_fr: 'GPT-6 Luna - raisonnement efficace',
        description_en: 'GPT-6 Luna - efficient reasoning'
      },
      'gpt-6.1-sol' => {
        name: 'GPT-6.1 Sol',
        provider: :openai,
        reasoning_support: :openai_effort,
        tier: :free,
        deployed: true,
        data_region: :eu, # DataZoneStandard; processing may route within Microsoft's EU boundary
        deployment_type: :data_zone_standard,
        deployment_version: '2026-09-29',
        azure_capacity_units: 100,
        extra_credits: 0,
        input_usd_per_million_tokens: 2.40,
        output_usd_per_million_tokens: 12.00,
        cost_per_query_eur: 0.072,
        description_nl: 'GPT-6.1 Sol - geavanceerde analyse',
        description_fr: 'GPT-6.1 Sol - analyse avancée',
        description_en: 'GPT-6.1 Sol - advanced analysis'
      },
      'mistral-small' => {
        name: 'Mistral Small 4',
        provider: :mistral,
        # Pin the provider deployment for reproducible legal-answer captures;
        # never route a quality-sensitive release through the moving -latest alias.
        api_model: 'mistral-small-2603',
        reasoning_support: :mistral_effort, # reasoning_effort: high/none (Mistral Small 4)
        reasoning_levels: %w[low high], # Product low/high map one-to-one to provider none/high
        tier: :free,
        deployed: true,
        data_region: :eu, # Routed only through api.eu.mistral.ai; no global endpoint fallback
        extra_credits: 0,
        input_usd_per_million_tokens: 0.165,
        output_usd_per_million_tokens: 0.66,
        cost_per_query_eur: 0.004, # EU regional rates imply about $0.004 at the standard 12k/3k envelope
        description_nl: 'Mistral Small 4 - snel · regionaal EU/EFTA-eindpunt',
        description_fr: 'Mistral Small 4 - rapide · point de terminaison régional UE/AELE',
        description_en: 'Mistral Small 4 - fast · EU/EFTA regional endpoint'
      },
      'mistral-large-4' => {
        name: 'Mistral Large 4',
        provider: :mistral,
        api_model: 'mistral-large-4',
        # Initial preview is deliberately fixed to documented non-reasoning
        # mode. Never leave the provider default free to consume the answer
        # envelope entirely on thinking, or charge an unsupported UI surcharge.
        reasoning_support: nil,
        fixed_reasoning_effort: 'none',
        slow_completion: true,
        tier: :free,
        deployed: true,
        preview: true,
        data_region: :eu,
        extra_credits: 0,
        input_usd_per_million_tokens: 1.496,
        output_usd_per_million_tokens: 4.598,
        cost_per_query_eur: 0.035,
        description_nl: 'Mistral Large 4 - krachtige Europese AI (testversie)',
        description_fr: 'Mistral Large 4 - IA européenne puissante (aperçu)',
        description_en: 'Mistral Large 4 - powerful European AI (preview)'
      },
      'claude-haiku-5-5' => {
        name: 'Claude Haiku 5.5',
        provider: :bedrock,
        bedrock_inference_profile: 'eu.anthropic.claude-haiku-5-5',
        # Claude 5.5 uses adaptive thinking; manual budget_tokens are rejected.
        reasoning_support: :bedrock_adaptive,
        tier: :free,
        planned_intelligence_level: 'genius',
        planned_credits: 2,
        deployed: false, # Enable only after the WW Frankfurt runtime probe passes.
        data_region: :eu,
        extra_credits: 1,
        # WW PUBLIC EU offer verified 2026-10-11, USD per million tokens.
        # Above 100k prompt tokens, both higher rates apply to the whole request.
        input_usd_per_million_tokens: 0.11,
        output_usd_per_million_tokens: 0.55,
        long_context_threshold_tokens: 100_000,
        long_context_input_usd_per_million_tokens: 0.55,
        long_context_output_usd_per_million_tokens: 2.75,
        cost_per_query_eur: 0.004, # Standard 12k/3k envelope at the conservative EUR/USD accounting floor.
        description_nl: 'Claude Haiku 5.5 - snel & nauwkeurig',
        description_fr: 'Claude Haiku 5.5 - rapide & précis',
        description_en: 'Claude Haiku 5.5 - fast & accurate'
      },
      'claude-sonnet-5-5' => {
        name: 'Claude Sonnet 5.5',
        provider: :bedrock,
        bedrock_inference_profile: 'eu.anthropic.claude-sonnet-5-5',
        reasoning_support: :bedrock_adaptive, # thinking adaptive + output_config effort low/medium/high
        tier: :free,
        planned_intelligence_level: 'mastermind',
        planned_credits: 6,
        deployed: false, # Enable only after the WW Frankfurt runtime probe passes.
        data_region: :eu,
        extra_credits: 3,
        input_usd_per_million_tokens: 2.20,
        output_usd_per_million_tokens: 11.00,
        cost_per_query_eur: 0.066, # WW PUBLIC EU offer; standard 12k/3k envelope with conservative FX.
        description_nl: 'Claude Sonnet 5.5 - topkwaliteit analyse',
        description_fr: 'Claude Sonnet 5.5 - analyse de premier ordre',
        description_en: 'Claude Sonnet 5.5 - top-tier analysis'
      },
      'claude-opus-5-5' => {
        name: 'Claude Opus 5.5',
        provider: :bedrock,
        bedrock_inference_profile: 'eu.anthropic.claude-opus-5-5',
        reasoning_support: :bedrock_adaptive, # Always on; output_config effort low/medium/high
        tier: :pro,
        planned_intelligence_level: 'omniscient',
        planned_credits: 12,
        deployed: false, # Enable only after the WW Frankfurt runtime probe passes.
        data_region: :eu,
        extra_credits: 11,
        input_usd_per_million_tokens: 4.40,
        output_usd_per_million_tokens: 22.00,
        # WW PUBLIC EU offer; conservative 12k-input/3k-output envelope.
        # Pre-I/O byte ceilings cover larger tokenizers and reasoning headroom.
        cost_per_query_eur: 0.131,
        description_nl: 'Claude Opus 5.5 - geavanceerde analyse',
        description_fr: 'Claude Opus 5.5 - analyse avancée',
        description_en: 'Claude Opus 5.5 - advanced analysis'
      }
    }.freeze

    # ═══════════════════════════════════════════════════════════════════
    # REASONING_CAPABLE_MODELS - single source of truth
    # ═══════════════════════════════════════════════════════════════════
    # Models that accept some form of reasoning control:
    #   :openai_effort   -> reasoning_effort: low/medium/high (Azure OpenAI)
    #   :mistral_effort  -> reasoning_effort: high/none (Mistral Small 4+)
    #   :bedrock_budgeted -> legacy fixed-budget capability, not in the offered portfolio
    #   :bedrock_adaptive -> thinking: {type: "adaptive"} + output_config effort (pending Claude 5.5)
    #
    # AUTO-DERIVED from AVAILABLE_MODELS[:reasoning_support]. When you add or remove
    # a model, this set updates automatically - no other files to touch.
    #
    # Consumers:
    #   - llm_client.rb         -> decides how to send reasoning params per provider
    #   - index.html.erb        -> data-supports-reasoning attribute on <option> elements
    #   - chatbot_controller.js -> shows/hides reasoning slider per-model (reads data attr)
    # ═══════════════════════════════════════════════════════════════════
    REASONING_CAPABLE_MODELS = AVAILABLE_MODELS
                               .select { |_id, cfg| cfg[:reasoning_support].present? }
                               .keys
                               .freeze

    # Models whose completions need the long service timeout even though they
    # take no reasoning parameters. Reasoning-capability was used as a proxy
    # for "slow provider call", which handed mistral-large-3 - the slowest
    # wired model - the SHORT 90s budget: on the 2026-08-13 tax capture the
    # same 17 of 40 questions deterministically hit the service timeout while
    # successful answers ran up to 89.09s. Derived from a :slow_completion
    # flag so adding a model updates this set automatically.
    SLOW_COMPLETION_MODELS = AVAILABLE_MODELS
                             .select { |_id, cfg| cfg[:slow_completion] }
                             .keys
                             .freeze

    # Tier hierarchy for model access
    TIER_HIERARCHY = {
      free: 0,
      pro: 1
    }.freeze

    # Application-side provider spend ceilings. These are deliberately named
    # as estimates: provider invoice rounding, discounts, taxes, cache loss and
    # foreign-exchange settlement are outside this process. Before network I/O
    # we reserve a conservative token-envelope estimate; after a response with
    # complete usage metadata we reconcile it to published token rates.
    # Raised 50 -> 100 on 2026-07-28: with paid accounts covering marginal
    # provider cost (credits per ask, no anonymous tier), the ceiling only
    # needs to catch runaway spend, not to sit near normal monthly volume
    # (~EUR 12 across all providers in July incl. quality campaigns).
    #
    # The running monthly total lives in the analytics database
    # (AiProviderMonthlySpend), not in Rails.cache: until 2026-09-27 the
    # production cache was cleared weekly, and a monthly ceiling kept there
    # restarted every week. The per-model DAILY breakers below stay in the
    # cache on purpose; they are 25-hour runaway detectors, not a monthly
    # spend record. The weekly jobs no longer clear the store, they remove
    # the related-sources panel by prefix and prune expired entries only
    # (Linkage::JurisprudenceCacheInvalidation, CacheMaintenance), so a live
    # daily counter outlives them.
    PROVIDER_MONTHLY_BUDGET_EUR = {
      openai: 100.0, # Azure OpenAI EU Data Zone
      mistral: 100.0, # Mistral EU/EFTA regional endpoint
      bedrock: 100.0 # AWS Bedrock EU geographic profile
    }.freeze

    # ===========================================
    # PER-MODEL DAILY CIRCUIT BREAKERS (prevent one route running away)
    # Each model has both a token-usage-aware €1.67 estimated-spend ceiling and
    # a secondary query-count breaker derived from its standard-query estimate.
    # These are not a shared provider/day budget; the monthly provider counter
    # below is shared.
    # ===========================================
    # Raised 1.67 -> 10.0 on 2026-07-28: the old value sat below one active
    # day of legitimate paid traffic (a capture run alone was ~EUR 1.9) and
    # denied answers to paying users whose credits already cover the marginal
    # provider cost. The breaker's job is catching a runaway loop or abused
    # secret, so it belongs well above any plausible legitimate peak.
    MODEL_DAILY_BUDGET_EUR = 10.0
    MODEL_DAILY_CAPS = AVAILABLE_MODELS.transform_values do |configuration|
      [(MODEL_DAILY_BUDGET_EUR / configuration.fetch(:cost_per_query_eur)).floor, 1].max
    end.freeze

    # Counters must remain integers for atomic increments (cache and ledger).
    # One unit is one millionth of a euro, preserving sub-cent requests such
    # as Mistral Small (€0.004) that rounded to zero in the former cents key.
    PROVIDER_SPEND_UNITS_PER_EUR = 1_000_000

    # Budget counter keys with this prefix address a row of the durable
    # monthly ledger (provider_spend_ledger:<provider>:<YYYYMM>) instead of a
    # Rails.cache entry. Reservations carry the key they were made against,
    # so a reservation that straddles midnight on the last day of a month
    # still reconciles against the month it was charged to.
    PROVIDER_SPEND_LEDGER_KEY_PREFIX = 'provider_spend_ledger'
    PROVIDER_SPEND_LEDGER_KEY = /\A#{PROVIDER_SPEND_LEDGER_KEY_PREFIX}:([a-z_]+):(\d{6})\z/

    # Provider prices above are published in USD. Use a deliberately high
    # application accounting rate and never allow runtime configuration to
    # lower that safety floor. This is a budget estimate, not an FX guarantee.
    PROVIDER_BUDGET_USD_TO_EUR_FLOOR = 1.10
    PROVIDER_BUDGET_PROCESS_MUTEX = Mutex.new
    EMBEDDING_INPUT_USD_PER_MILLION_TOKENS = 0.13

    included do
      # Class methods for model access control
    end

    class_methods do
      # Intelligence-level access historically used two names for the same
      # entitlement (:pro and :subscriber). Keep the mapping in one fail-closed
      # predicate so a newly configured tier cannot silently become selectable
      # or, as happened with :pro, render disabled for an entitled subscriber.
      def intelligence_tier_accessible?(tier, pro:, purchased:)
        case tier&.to_sym
        when :free
          true
        when :purchased
          purchased || pro
        when :pro, :subscriber
          pro
        else
          false
        end
      end

      # Get models available for a given user tier
      def models_for_tier(tier)
        tier_level = TIER_HIERARCHY[tier.to_sym] || 0
        AVAILABLE_MODELS.select do |_key, config|
          config[:deployed] != false && TIER_HIERARCHY[config[:tier]] <= tier_level
        end
      end

      # Check if a model is valid for a given tier
      def model_allowed?(model, tier)
        return true if model == CHAT_MODEL # Default always allowed

        config = AVAILABLE_MODELS[model]
        return false unless config && config[:deployed] != false

        tier_level = TIER_HIERARCHY[tier.to_sym] || 0
        model_tier_level = TIER_HIERARCHY[config[:tier]] || 0
        tier_level >= model_tier_level
      end

      # Get extra credit cost for a model
      def extra_credits_for(model)
        AVAILABLE_MODELS.dig(model, :extra_credits) || 0
      end

      # Get estimated cost per query in EUR for a model
      def cost_per_query_eur(model)
        AVAILABLE_MODELS.dig(model, :cost_per_query_eur) || 0.009
      end

      # Get daily cap for a model (nil = no per-model cap)
      def daily_cap_for(model)
        MODEL_DAILY_CAPS[model]
      end

      # An evaluation run (scripts/ops/german_answer_eval.rb and the capture
      # scripts, started with CHATBOT_BENCHMARK_RUN=1 in their own process)
      # is legitimate paid traffic that must never deny live users, so it
      # stays outside the per-model daily CALL COUNT breaker: its cheap
      # translation calls spend that count three times faster than the spend
      # ceiling (2026-10-04: four paired runs of about 640 calls each reached
      # the 2,500 calls of mistral-small, and the breaker would have refused
      # every live question on the default model until the day change). The
      # daily spend ceiling, the monthly provider ledger and the fault keys
      # still count every call of such a run. The flag is read per process:
      # the web and job processes never carry it.
      def benchmark_run?
        ENV['CHATBOT_BENCHMARK_RUN'].to_s == '1'
      end

      # Check if a model has hit its daily cap
      def model_at_daily_cap?(model)
        cap = daily_cap_for(model)
        return false unless cap
        return true if Rails.cache.read(model_daily_budget_fault_key(model))

        count = Rails.cache.read(model_daily_count_key(model)) || 0
        spend_units = Rails.cache.read(model_daily_spend_key(model)).to_i
        next_query_units = model_budget_reservation_units(model)
        at_call_cap = !benchmark_run? && count >= cap
        at_call_cap || spend_units + next_query_units > model_daily_budget_units
      end

      # Atomically reserve one provider call before network I/O. The LLM client
      # supplies the exact provider output ceiling (including reasoning tokens)
      # and serialized messages. A byte-based input ceiling is conservative for
      # provider tokenizers while avoiding a provider-side tokenize round trip.
      #
      # The post-increment comparison serializes concurrent callers at each
      # counter (cache counters for the daily breakers, one database upsert
      # for the monthly provider ledger). A reservation beyond a ceiling is
      # rolled back before provider dispatch.
      def reserve_model_budget!(model, reasoning_effort: nil, max_output_tokens: nil, messages: nil)
        cap = daily_cap_for(model)
        provider = provider_for_model(model)
        raise ArgumentError, "Unknown chatbot model: #{model}" unless cap && provider
        if Rails.cache.read(model_daily_budget_fault_key(model)) || Rails.cache.read(provider_monthly_budget_fault_key(provider))
          raise BudgetLimitExceeded.new(reason: :budget_accounting_unavailable, model: model, provider: provider)
        end

        reservation = {
          model: model,
          provider: provider,
          reasoning_effort: reasoning_effort,
          max_output_tokens: max_output_tokens,
          counters: [],
          state: :reserving
        }

        cost_units = model_budget_reservation_units(
          model,
          max_output_tokens: max_output_tokens,
          messages: messages
        )

        unless benchmark_run?
          model_key = model_daily_count_key(model)
          model_count = mutate_budget_counter(model_key, 1, expires_in: 25.hours)
          raise BudgetLimitExceeded.new(reason: :cache_unavailable, model: model, provider: provider) if model_count.nil?

          reservation[:counters] << [model_key, 1]
          raise BudgetLimitExceeded.new(reason: :model_daily_cap, model: model, provider: provider) if model_count > cap
        end

        daily_spend_key = model_daily_spend_key(model)
        daily_spend_units = mutate_budget_counter(daily_spend_key, cost_units, expires_in: 25.hours)
        raise BudgetLimitExceeded.new(reason: :cache_unavailable, model: model, provider: provider) if daily_spend_units.nil?

        reservation[:counters] << [daily_spend_key, cost_units]
        reservation[:daily_spend_key] = daily_spend_key
        if daily_spend_units > model_daily_budget_units
          raise BudgetLimitExceeded.new(reason: :model_daily_spend_ceiling, model: model, provider: provider)
        end

        monthly_key = provider_monthly_spend_key(provider)
        current_units = mutate_budget_counter(monthly_key, cost_units, expires_in: 32.days)
        raise BudgetLimitExceeded.new(reason: :cache_unavailable, model: model, provider: provider) if current_units.nil?

        reservation[:counters] << [monthly_key, cost_units]
        reservation[:spend_key] = monthly_key
        reservation[:reserved_units] = cost_units

        budget_units = provider_monthly_budget_units(provider)
        total_units = current_units + legacy_provider_monthly_spend_units(provider)
        raise BudgetLimitExceeded.new(reason: :provider_monthly_cap, model: model, provider: provider) if total_units > budget_units

        reservation[:state] = :reserved
        reservation
      rescue StandardError
        release_model_budget!(reservation) if reservation
        raise
      end

      # Replace a conservative pre-I/O reservation with the cost calculated
      # from provider-published input/output token counts and published prices.
      # Missing, malformed or model-mismatched usage is intentionally not
      # refunded: billing is ambiguous, so the conservative reservation stays.
      #
      # An unexpected upward adjustment is written before checking the ceiling.
      # It is never rolled back (that would under-report incurred spend), and a
      # crossing raises loudly so subsequent work is stopped rather than making
      # the overrun invisible. Correct provider token ceilings should make this
      # path exceptional.
      def reconcile_model_budget!(reservation, token_usage)
        return reservation if reservation.blank? || reservation[:state] != :reserved

        unless complete_budget_token_usage?(reservation, token_usage)
          reservation[:state] = :retained_ambiguous
          Rails.logger.warn(
            "[AI BUDGET] Retaining conservative reservation: incomplete usage " \
            "model=#{reservation[:model]} provider=#{reservation[:provider]}"
          )
          return reservation
        end

        actual_units = model_token_cost_units(
          reservation[:model],
          input_tokens: token_usage[:input],
          output_tokens: token_usage[:output]
        )
        reserved_units = reservation.fetch(:reserved_units)
        delta = actual_units - reserved_units

        if delta.positive?
          daily_units = retry_budget_counter_mutation(reservation.fetch(:daily_spend_key), delta, expires_in: 25.hours)
          provider_units = retry_budget_counter_mutation(reservation.fetch(:spend_key), delta, expires_in: 32.days)
          if daily_units.nil? || provider_units.nil?
            conservatively_record_partial_reconciliation!(
              reservation,
              daily_failed: daily_units.nil?,
              provider_failed: provider_units.nil?
            )
            reservation[:actual_units] = actual_units
            reservation[:state] = :reconciled_accounting_fault
            Rails.logger.error(
              "[AI BUDGET] Could not record provider usage over reservation " \
              "model=#{reservation[:model]} provider=#{reservation[:provider]} delta_units=#{delta}"
            )
            raise BudgetLimitExceeded.new(
              reason: :cache_unavailable_during_reconciliation,
              model: reservation[:model],
              provider: reservation[:provider]
            )
          end

          provider_total_units = provider_units + legacy_provider_monthly_spend_units(reservation[:provider])
          crossed_daily = daily_units > model_daily_budget_units
          crossed_provider = provider_total_units > provider_monthly_budget_units(reservation[:provider])
          if crossed_daily || crossed_provider
            reservation[:actual_units] = actual_units
            reservation[:state] = :reconciled_over_ceiling
            Rails.logger.error(
              "[AI BUDGET] Actual token cost crossed application spend ceiling " \
              "model=#{reservation[:model]} provider=#{reservation[:provider]} " \
              "daily_units=#{daily_units} provider_units=#{provider_total_units}"
            )
            raise BudgetLimitExceeded.new(
              reason: crossed_provider ? :provider_monthly_ceiling_crossed_during_reconciliation : :model_daily_ceiling_crossed_during_reconciliation,
              model: reservation[:model],
              provider: reservation[:provider]
            )
          end
        elsif delta.negative?
          daily_units = retry_budget_counter_mutation(reservation.fetch(:daily_spend_key), delta, expires_in: 25.hours)
          provider_units = retry_budget_counter_mutation(reservation.fetch(:spend_key), delta, expires_in: 32.days)
          if daily_units.nil? || provider_units.nil?
            # A failed refund is conservative; do not fail a valid answer.
            reservation[:state] = :retained_cache_error
            Rails.logger.warn(
              "[AI BUDGET] Could not refund unused reservation; retaining it " \
              "model=#{reservation[:model]} provider=#{reservation[:provider]}"
            )
            return reservation
          end
        end

        reservation[:actual_units] = actual_units
        reservation[:state] = :reconciled
        reservation
      end

      # Reserve provider spend for calls that are not the final answer model,
      # notably Azure question embeddings. Keeping this separate prevents the
      # answer reservation from being counted twice while still accounting for
      # every cache-miss provider request.
      def reserve_auxiliary_provider_budget!(provider:, operation:, reserved_units:)
        raise ArgumentError, "Unknown provider: #{provider}" unless PROVIDER_MONTHLY_BUDGET_EUR.key?(provider)
        raise ArgumentError, 'reserved_units must be positive' unless Integer(reserved_units).positive?

        model = "auxiliary:#{operation}"
        if Rails.cache.read(provider_monthly_budget_fault_key(provider))
          raise BudgetLimitExceeded.new(reason: :budget_accounting_unavailable, model: model, provider: provider)
        end

        reservation = {
          model: model,
          provider: provider,
          operation: operation,
          counters: [],
          state: :reserving
        }
        spend_key = provider_monthly_spend_key(provider)
        current_units = mutate_budget_counter(spend_key, Integer(reserved_units), expires_in: 32.days)
        raise BudgetLimitExceeded.new(reason: :cache_unavailable, model: model, provider: provider) if current_units.nil?

        reservation[:counters] << [spend_key, Integer(reserved_units)]
        reservation[:spend_key] = spend_key
        reservation[:reserved_units] = Integer(reserved_units)
        total_units = current_units + legacy_provider_monthly_spend_units(provider)
        if total_units > provider_monthly_budget_units(provider)
          raise BudgetLimitExceeded.new(reason: :provider_monthly_cap, model: model, provider: provider)
        end

        reservation[:state] = :reserved
        reservation
      rescue StandardError
        release_model_budget!(reservation) if reservation
        raise
      end

      def reconcile_auxiliary_provider_budget!(reservation, actual_units:)
        return reservation if reservation.blank? || reservation[:state] != :reserved

        unless actual_units.present? && Integer(actual_units) >= 0
          reservation[:state] = :retained_ambiguous
          Rails.logger.warn(
            "[AI BUDGET] Retaining auxiliary reservation: incomplete usage " \
            "operation=#{reservation[:operation]} provider=#{reservation[:provider]}"
          )
          return reservation
        end

        actual = [Integer(actual_units), 1].max
        delta = actual - reservation.fetch(:reserved_units)
        if delta.positive?
          provider_units = retry_budget_counter_mutation(reservation.fetch(:spend_key), delta, expires_in: 32.days)
          if provider_units.nil?
            conservatively_record_partial_reconciliation!(
              reservation,
              daily_failed: false,
              provider_failed: true
            )
            reservation[:actual_units] = actual
            reservation[:state] = :reconciled_accounting_fault
            raise BudgetLimitExceeded.new(
              reason: :cache_unavailable_during_reconciliation,
              model: reservation[:model],
              provider: reservation[:provider]
            )
          end

          total_units = provider_units + legacy_provider_monthly_spend_units(reservation[:provider])
          if total_units > provider_monthly_budget_units(reservation[:provider])
            reservation[:actual_units] = actual
            reservation[:state] = :reconciled_over_ceiling
            raise BudgetLimitExceeded.new(
              reason: :provider_monthly_ceiling_crossed_during_reconciliation,
              model: reservation[:model],
              provider: reservation[:provider]
            )
          end
        elsif delta.negative?
          provider_units = retry_budget_counter_mutation(reservation.fetch(:spend_key), delta, expires_in: 32.days)
          if provider_units.nil?
            reservation[:state] = :retained_cache_error
            return reservation
          end
        end

        reservation[:actual_units] = actual
        reservation[:state] = :reconciled
        reservation
      rescue ArgumentError, TypeError
        reservation[:state] = :retained_ambiguous
        reservation
      end

      # Release only reservations for which provider network I/O never began.
      # Once a request is on the wire its billing outcome is ambiguous, so the
      # conservative estimated spend remains counted.
      def release_model_budget!(reservation)
        return if reservation.blank? || %i[released reconciled reconciled_over_ceiling reconciled_accounting_fault retained_ambiguous retained_cache_error].include?(reservation[:state])

        results = reservation[:counters].reverse_each.map do |key, amount|
          ttl = key == reservation[:spend_key] ? 32.days : 25.hours
          mutate_budget_counter(key, -amount, expires_in: ttl)
        end
        reservation[:state] = results.all? ? :released : :retained_cache_error
      end

      # ActiveSupport::Cache::FileStore#increment locks the value file that it
      # then atomically replaces. That can fail on Windows and lets newcomers
      # lock the replacement inode while older waiters still hold the old one.
      # Use a separate stable flock plus read/write for FileStore. Other cache
      # stores retain their native atomic increment/decrement primitives.
      #
      # A monthly provider ledger key is written to the database instead, in
      # one atomic upsert that clamps at zero. Any failure returns nil, which
      # every caller treats as "accounting unavailable" and fails closed.
      def mutate_budget_counter(key, amount, expires_in:)
        if (ledger = provider_spend_ledger_address(key))
          return AiProviderMonthlySpend.adjust!(**ledger, amount: amount)
        end

        cache = Rails.cache
        if cache.is_a?(ActiveSupport::Cache::FileStore)
          with_budget_file_store_lock(cache) do
            updated = [cache.read(key).to_i + Integer(amount), 0].max
            cache.write(key, updated, expires_in: expires_in) ? updated : nil
          end
        elsif amount.negative?
          updated = cache.decrement(key, -amount, expires_in: expires_in)
          return nil if updated.nil?

          # Some stores initialize a missing decrement at a negative value.
          # Add back only the underflow; concurrent positive increments remain.
          updated.negative? ? cache.increment(key, -updated, expires_in: expires_in) : updated
        else
          cache.increment(key, amount, expires_in: expires_in)
        end
      rescue StandardError => e
        Rails.logger.error("[AI BUDGET] Counter mutation failed key=#{key}: #{e.class}")
        nil
      end

      def retry_budget_counter_mutation(key, amount, expires_in:, attempts: 3)
        attempts.times do
          updated = mutate_budget_counter(key, amount, expires_in: expires_in)
          return updated unless updated.nil?
        end
        nil
      end

      # If one upward reconciliation counter succeeds and the other cannot be
      # updated, saturate the failed counter and set a fail-closed marker. This
      # never leaves a terminal state whose dashboard/enforcement understates
      # the provider call already incurred.
      def conservatively_record_partial_reconciliation!(reservation, daily_failed:, provider_failed:)
        if daily_failed
          saturated = saturate_budget_counter(
            reservation.fetch(:daily_spend_key),
            model_daily_budget_units,
            expires_in: 25.hours
          )
          Rails.cache.write(model_daily_budget_fault_key(reservation[:model]), true, expires_in: 25.hours)
          Rails.logger.error('[AI BUDGET] Daily counter saturated after reconciliation failure') if saturated.nil?
        end
        if provider_failed
          saturated = saturate_budget_counter(
            reservation.fetch(:spend_key),
            provider_monthly_budget_units(reservation[:provider]),
            expires_in: 32.days
          )
          Rails.cache.write(provider_monthly_budget_fault_key(reservation[:provider]), true, expires_in: 32.days)
          Rails.logger.error('[AI BUDGET] Provider counter saturated after reconciliation failure') if saturated.nil?
        end
      rescue StandardError => e
        Rails.logger.error("[AI BUDGET] Could not mark reconciliation fault: #{e.class}")
      end

      def saturate_budget_counter(key, ceiling_units, expires_in:)
        if (ledger = provider_spend_ledger_address(key))
          return AiProviderMonthlySpend.saturate!(**ledger, floor_units: ceiling_units)
        end

        cache = Rails.cache
        if cache.is_a?(ActiveSupport::Cache::FileStore)
          with_budget_file_store_lock(cache) do
            updated = [cache.read(key).to_i, Integer(ceiling_units)].max
            cache.write(key, updated, expires_in: expires_in) ? updated : nil
          end
        else
          # Adding a full ceiling is intentionally conservative and preserves
          # concurrent increments without a non-portable compare-and-set API.
          cache.increment(key, Integer(ceiling_units), expires_in: expires_in)
        end
      rescue StandardError => e
        Rails.logger.error("[AI BUDGET] Counter saturation failed key=#{key}: #{e.class}")
        nil
      end

      def with_budget_file_store_lock(cache)
        PROVIDER_BUDGET_PROCESS_MUTEX.synchronize do
          FileUtils.mkdir_p(cache.cache_path)
          lock_path = File.join(cache.cache_path, '.wetwijzer-ai-budget.lock')
          File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
            lock.flock(File::LOCK_EX)
            yield
          ensure
            lock&.flock(File::LOCK_UN)
          end
        end
      end

      # Published list-price cost in application micro-euro accounting units.
      # Cached-input discounts are intentionally ignored, which errs toward
      # blocking early. Both token counts must be non-negative integers.
      def model_token_cost_units(model, input_tokens:, output_tokens:)
        config = AVAILABLE_MODELS.fetch(model)
        input = Integer(input_tokens)
        output = Integer(output_tokens)
        raise ArgumentError, 'Token counts must be non-negative' if input.negative? || output.negative?

        long_context = config[:long_context_threshold_tokens] && input > config.fetch(:long_context_threshold_tokens)
        input_rate_key = long_context ? :long_context_input_usd_per_million_tokens : :input_usd_per_million_tokens
        output_rate_key = long_context ? :long_context_output_usd_per_million_tokens : :output_usd_per_million_tokens
        input_rate = BigDecimal(config.fetch(input_rate_key).to_s)
        output_rate = BigDecimal(config.fetch(output_rate_key).to_s)
        fx = BigDecimal(provider_budget_usd_to_eur_rate.to_s)

        # USD/MTok * tokens * EUR/USD equals micro-euro units directly.
        [((input_rate * input) + (output_rate * output)).then { |usd_micro| (usd_micro * fx).ceil }, 1].max
      end

      def embedding_token_cost_units(input_tokens)
        input = Integer(input_tokens)
        raise ArgumentError, 'Token count must be non-negative' if input.negative?

        rate = BigDecimal(EMBEDDING_INPUT_USD_PER_MILLION_TOKENS.to_s)
        fx = BigDecimal(provider_budget_usd_to_eur_rate.to_s)
        [(rate * input * fx).ceil, 1].max
      end

      def embedding_budget_reservation_units(text)
        # A UTF-8 byte ceiling plus request framing safely exceeds ordinary
        # tokenizer counts without making a second provider request.
        embedding_token_cost_units(text.to_s.bytesize + 128)
      end

      def model_budget_reservation_units(model, max_output_tokens: nil, messages: nil)
        flat_units = (cost_per_query_eur(model) * PROVIDER_SPEND_UNITS_PER_EUR).ceil
        return flat_units if max_output_tokens.nil? || messages.nil?

        token_envelope_units = model_token_cost_units(
          model,
          input_tokens: estimated_input_token_ceiling(messages),
          output_tokens: max_output_tokens
        )
        [flat_units, token_envelope_units].max
      end

      def estimated_input_token_ceiling(messages)
        serialized_bytes = JSON.generate(Array(messages)).bytesize
        # Covers provider chat-template framing and request metadata while the
        # serialized-byte count already bounds ordinary byte-fallback tokens.
        serialized_bytes + (Array(messages).length * 16) + 512
      end

      def provider_budget_usd_to_eur_rate
        configured = Float(ENV.fetch('CHATBOT_BUDGET_USD_TO_EUR_RATE', PROVIDER_BUDGET_USD_TO_EUR_FLOOR.to_s))
        [configured, PROVIDER_BUDGET_USD_TO_EUR_FLOOR].max
      rescue ArgumentError, TypeError
        PROVIDER_BUDGET_USD_TO_EUR_FLOOR
      end

      def provider_monthly_budget_units(provider)
        (PROVIDER_MONTHLY_BUDGET_EUR.fetch(provider) * PROVIDER_SPEND_UNITS_PER_EUR).round
      end

      def model_daily_budget_units
        (MODEL_DAILY_BUDGET_EUR * PROVIDER_SPEND_UNITS_PER_EUR).round
      end

      def complete_budget_token_usage?(reservation, token_usage)
        return false unless token_usage.is_a?(Hash)
        return false unless token_usage[:billing_complete] == true
        return false unless token_usage[:model].to_s == reservation[:model].to_s

        Integer(token_usage[:input]) >= 0 && Integer(token_usage[:output]) >= 0
      rescue ArgumentError, TypeError
        false
      end

      def model_daily_count_key(model)
        "model_daily_count:#{model}:#{Date.current}"
      end

      def model_daily_spend_key(model)
        "model_daily_spend_micro_eur:#{model}:#{Date.current}"
      end

      def model_daily_budget_fault_key(model)
        "model_daily_budget_accounting_fault:#{model}:#{Date.current}"
      end

      # Address of this month's row in the durable provider spend ledger.
      # Counters kept in Rails.cache by earlier releases are added at read
      # time instead of copied into the ledger: that avoids a seed-then-
      # increment race and still observes usage an older process wrote.
      def provider_monthly_spend_key(provider)
        "#{PROVIDER_SPEND_LEDGER_KEY_PREFIX}:#{provider}:#{AiProviderMonthlySpend.budget_month_for(Date.current)}"
      end

      # { provider:, budget_month: } for a ledger key, nil for a cache key.
      def provider_spend_ledger_address(key)
        match = PROVIDER_SPEND_LEDGER_KEY.match(key.to_s)
        return nil unless match

        { provider: match[1], budget_month: match[2] }
      end

      def provider_monthly_budget_fault_key(provider)
        month = Date.current.strftime('%Y%m')
        "provider_monthly_budget_accounting_fault:#{provider}:#{month}"
      end

      # ── Provider-level application spend ceiling ──

      # Resolve model → provider symbol (:openai, :mistral, :bedrock)
      def provider_for_model(model)
        AVAILABLE_MODELS.dig(model, :provider)
      end

      # Fast advisory preflight for controllers. The authoritative, concurrent
      # model/effort/token-envelope reservation happens in LlmClient immediately
      # before provider I/O.
      def provider_at_monthly_cap?(model)
        provider = provider_for_model(model)
        return false unless provider
        return true if Rails.cache.read(provider_monthly_budget_fault_key(provider))

        budget = PROVIDER_MONTHLY_BUDGET_EUR[provider]
        return false unless budget

        spend_units = provider_monthly_spend_units(provider)
        next_query_units = (cost_per_query_eur(model) * PROVIDER_SPEND_UNITS_PER_EUR).round
        budget_units = provider_monthly_budget_units(provider)

        spend_units + next_query_units > budget_units
      end

      # Get current monthly spend for a provider in EUR (for dashboard)
      def provider_monthly_spend(provider)
        provider_monthly_spend_units(provider).fdiv(PROVIDER_SPEND_UNITS_PER_EUR)
      end

      # An unreadable ledger reads as a spent budget: the advisory preflight
      # then refuses, which is the same fail-closed answer the authoritative
      # reservation gives when it cannot write.
      def provider_monthly_spend_units(provider)
        ledger_units = provider_monthly_ledger_units(provider)
        return provider_monthly_budget_units(provider) if ledger_units.nil?

        total_units = ledger_units + legacy_provider_monthly_spend_units(provider)
        return [total_units, provider_monthly_budget_units(provider)].max if Rails.cache.read(provider_monthly_budget_fault_key(provider))

        total_units
      end

      def provider_monthly_ledger_units(provider)
        AiProviderMonthlySpend.units_for(
          provider: provider,
          budget_month: AiProviderMonthlySpend.budget_month_for(Date.current)
        )
      rescue StandardError => e
        Rails.logger.error("[AI BUDGET] Provider spend ledger unreadable provider=#{provider}: #{e.class}")
        nil
      end

      # Spend that earlier releases recorded in Rails.cache for this month:
      # the micro-euro counter used until the ledger existed, plus the older
      # cents or euro counter. Nothing writes these any more; they only carry
      # the deploy month's earlier spend forward until they expire.
      def legacy_provider_monthly_spend_units(provider)
        month = Date.current.strftime('%Y%m')
        micro_units = Rails.cache.read("provider_monthly_spend_micro_eur:#{provider}:#{month}").to_i
        legacy_cents = Rails.cache.read("provider_monthly_spend_cents:#{provider}:#{month}")
        return micro_units + (legacy_cents.to_i * (PROVIDER_SPEND_UNITS_PER_EUR / 100)) unless legacy_cents.nil?

        legacy_eur = Rails.cache.read("provider_monthly_spend:#{provider}:#{month}").to_f
        micro_units + (legacy_eur * PROVIDER_SPEND_UNITS_PER_EUR).round
      end

      # Get current daily model usage (for dashboard)
      def model_daily_usage
        AVAILABLE_MODELS.keys.each_with_object({}) do |model, hash|
          count = Rails.cache.read(model_daily_count_key(model)) || 0
          cap = MODEL_DAILY_CAPS[model]
          spend_units = Rails.cache.read(model_daily_spend_key(model))
          spend_units = model_daily_budget_units if Rails.cache.read(model_daily_budget_fault_key(model))
          cost_estimate = if spend_units.nil?
                            count * (AVAILABLE_MODELS[model][:cost_per_query_eur] || 0.009)
                          else
                            spend_units.to_i.fdiv(PROVIDER_SPEND_UNITS_PER_EUR)
                          end
          hash[model] = {
            count: count,
            cap: cap,
            cost_estimate: cost_estimate,
            spend_budget_eur: MODEL_DAILY_BUDGET_EUR
          }
        end
      end

      # Get provider monthly usage summary (for dashboard)
      def provider_monthly_usage
        PROVIDER_MONTHLY_BUDGET_EUR.each_with_object({}) do |(provider, budget), hash|
          spend = provider_monthly_spend(provider)
          hash[provider] = {
            spend_eur: spend.round(2),
            budget_eur: budget,
            percentage: budget.positive? ? ((spend / budget) * 100).round(1) : 0,
            at_cap: spend >= budget
          }
        end
      end

      def ui_default_selection
        UI_DEFAULT_SELECTION
      end

      # The fresh selection's displayed and reserved price: the model's own
      # credits plus its effort surcharge, never the tier fallback.
      def ui_default_credits
        selection = UI_DEFAULT_SELECTION
        credits_for_model(selection[:intelligence], selection[:model]) +
          reasoning_surcharge_for_model(selection[:model], selection[:reasoning_effort])
      end

      def ui_default_research_depth
        research_depth_for_combination(UI_DEFAULT_SELECTION[:model], UI_DEFAULT_SELECTION[:reasoning_effort])
      end

      # Resolve intelligence level to its current default model ID.
      def model_for_intelligence(level)
        config = INTELLIGENCE_LEVELS[level.to_s]
        return CHAT_MODEL unless config

        config[:default_model] || config[:models]&.keys&.first || CHAT_MODEL
      end

      # Get base credit cost for an intelligence level (e.g. 'genius' → 4)
      def credits_for_intelligence(level)
        INTELLIGENCE_LEVELS.dig(level.to_s, :credits) || 1
      end

      # Get credit cost for a specific model within a tier.
      # Returns model-specific :credits if defined, otherwise falls back to tier :credits.
      # Example: credits_for_model('mastermind', 'gpt-6.1-sol') → 6
      #          credits_for_model('genius', 'gpt-6-luna') → 2
      #          credits_for_model('genius') → 4 (no model override, uses tier base)
      def credits_for_model(level, model = nil)
        tier_config = INTELLIGENCE_LEVELS[level.to_s]
        return 1 unless tier_config

        if model.present? && tier_config[:models]&.key?(model)
          tier_config[:models][model][:credits] || tier_config[:credits]
        elsif model.present?
          # A controller must reject a model/tier mismatch, but never let a
          # mismatched caller turn an expensive model into the selected tier's
          # cheap fallback price. Resolve the model's canonical configured
          # price as a defence-in-depth billing floor.
          canonical_credits_for_model(model, fallback: tier_config[:credits])
        else
          tier_config[:credits]
        end
      end

      def model_in_intelligence_level?(level, model)
        INTELLIGENCE_LEVELS.dig(level.to_s, :models)&.key?(model.to_s) == true
      end

      def intelligence_level_for_model(model)
        INTELLIGENCE_LEVELS.find { |_level, config| config.fetch(:models).key?(model.to_s) }&.first
      end

      def research_depth_for_intelligence(level)
        INTELLIGENCE_RESEARCH_DEPTHS[level.to_s]
      end

      def research_depth_for_model(model)
        research_depth_for_intelligence(intelligence_level_for_model(model))
      end

      def research_depth_for_combination(model, reasoning_effort = nil)
        depth = research_depth_for_model(model)
        return unless depth

        effective = effective_reasoning_effort_for_model(model, reasoning_effort)
        MODEL_REASONING_RESEARCH_DEPTHS.dig(model.to_s, effective) || depth
      end

      # The ruler is a curated shortcut, not the complete model selector.
      # Small/high and Large 4 (owner 2026-10-18, every mode) remain
      # supported, priced and selectable in Settings, Large 4 marked as a
      # preview (Testversie); neither is a ruler recommendation.
      def research_bar_combination?(model, reasoning_effort = nil)
        return false if model.to_s == 'mistral-large-4'

        !(model.to_s == 'mistral-small' && reasoning_effort.to_s == 'high')
      end

      def canonical_credits_for_model(model, fallback: nil)
        canonical_prices = INTELLIGENCE_LEVELS.values.filter_map do |config|
          config.dig(:models, model.to_s, :credits)
        end
        canonical_prices.max || fallback || (1 + extra_credits_for(model))
      end

      # Get total credits including reasoning surcharge
      # e.g. credits_with_reasoning('genius', 'medium', 'gpt-6-luna') → 2 + 1 = 3
      # e.g. credits_with_reasoning('genius', 'medium', 'claude-haiku-5-5') → 2 + 1 = 3 (when deployed)
      # e.g. credits_with_reasoning('smart', 'medium', 'mistral-small') → 1 (unsupported, not charged)
      # e.g. credits_with_reasoning('mastermind', 'medium', 'gpt-6.1-sol') → 6 + 1 = 7
      def credits_with_reasoning(level, reasoning = nil, model = nil)
        base = credits_for_model(level, model)
        return base unless reasoning.present? && REASONING_LEVELS.key?(reasoning.to_s)

        # Per-model check: charge only for an effort that this model actually
        # sends to its provider. This prevents unsupported aliases (notably
        # Mistral "medium") from being charged as if they changed behaviour.
        if model.present?
          return base unless model_supports_reasoning_effort?(model, reasoning)
        else
          # Fallback to tier-level check when model not specified
          supports = INTELLIGENCE_LEVELS.dig(level.to_s, :supports_reasoning)
          return base unless supports
        end

        base + (REASONING_LEVELS.dig(reasoning.to_s, :surcharge) || 0)
      end

      # Get reasoning surcharge for a given reasoning level
      def reasoning_surcharge(reasoning)
        REASONING_LEVELS.dig(reasoning.to_s, :surcharge) || 0
      end

      # Get default reasoning effort for an intelligence level
      # Returns nil for tiers that don't support reasoning (Claude)
      def reasoning_effort_for_intelligence(level)
        INTELLIGENCE_LEVELS.dig(level.to_s, :reasoning_effort)
      end

      # Check if a tier supports reasoning level selection (UI-level).
      # NOTE: For API parameter and billing decisions, use model_supports_reasoning?
      # which checks whether the specific model accepts reasoning_effort.
      def supports_reasoning?(level)
        INTELLIGENCE_LEVELS.dig(level.to_s, :supports_reasoning) == true
      end

      # Validate intelligence level
      def valid_intelligence_level?(level)
        INTELLIGENCE_LEVELS.key?(level.to_s)
      end

      # Validate reasoning level
      def valid_reasoning_level?(level)
        REASONING_LEVELS.key?(level.to_s)
      end

      # nil deliberately means legacy client/service behaviour. Supplied but
      # malformed values select the bounded default rather than accepting an
      # arbitrary effort, budget or expensive provider setting.
      def normalize_research_depth(value)
        return nil if value.nil?

        depth = value.is_a?(String) || value.is_a?(Symbol) ? value.to_s.strip : ''
        RESEARCH_DEPTHS.key?(depth) ? depth : 'balanced'
      end

      def reasoning_effort_for_research_depth(depth, model:, reasoning_access: true)
        normalized = normalize_research_depth(depth)
        return nil unless normalized
        return nil if normalized == 'extensive' && !reasoning_access

        requested = RESEARCH_DEPTHS.fetch(normalized).fetch(:reasoning_effort)
        effective_reasoning_effort_for_model(model, requested)
      end

      # Check if a specific model supports any form of reasoning control.
      # Uses REASONING_CAPABLE_MODELS (auto-derived from AVAILABLE_MODELS[:reasoning_support]).
      def model_supports_reasoning?(model_id)
        reasoning_levels_for_model(model_id).any?
      end

      # Product reasoning levels that map to distinct, documented provider
      # behaviours for a specific model. Models default to all global levels;
      # providers with a smaller enum declare :reasoning_levels explicitly.
      def reasoning_levels_for_model(model_id)
        config = AVAILABLE_MODELS[model_id.to_s]
        return [] unless config&.dig(:reasoning_support)

        Array(config[:reasoning_levels] || REASONING_LEVELS.keys).map(&:to_s)
      end

      def model_supports_reasoning_effort?(model_id, effort)
        reasoning_levels_for_model(model_id).include?(effort.to_s)
      end

      # Resolve stale or unsupported client preferences without ever upgrading
      # them to a more expensive provider mode. Mistral medium therefore falls
      # back to low/none, while valid high remains high.
      def effective_reasoning_effort_for_model(model_id, effort)
        levels = reasoning_levels_for_model(model_id)
        return nil if levels.empty?

        requested = effort.to_s
        return requested if levels.include?(requested)

        levels.include?('low') ? 'low' : levels.first
      end

      # Model-aware surcharge used by controllers and any API client billing.
      # Unsupported levels always cost zero and must be treated as non-reasoning
      # by the provider client as well.
      def reasoning_surcharge_for_model(model_id, effort)
        return 0 unless model_supports_reasoning_effort?(model_id, effort)

        reasoning_surcharge(effort)
      end

      # Get the reasoning support type for a model (:openai_effort,
      # :mistral_effort, :bedrock_budgeted, :bedrock_adaptive, or nil).
      def reasoning_support_type(model_id)
        AVAILABLE_MODELS.dig(model_id.to_s, :reasoning_support)
      end
    end
  end
end
