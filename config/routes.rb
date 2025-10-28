# frozen_string_literal: true

Rails.application.routes.draw do
  # Geo-challenge (ALTCHA proof-of-work for non-EU visitors)
  get 'geo-challenge', to: 'geo_challenges#show', as: 'geo_challenge'
  post 'geo-challenge', to: 'geo_challenges#create'
  get 'altcha-challenge.json', to: 'geo_challenges#challenge_json', as: 'altcha_challenge'

  # Bookmarks page (server-side for logged-in users)
  get 'bookmarks', to: 'laws#bookmarks', as: 'bookmarks'

  resources :laws, param: :numac, only: %i[index show] do
    member do
      get :articles
      get :article_exdecs
      get :related_sources
      get :export_word
      get :compare
      get :export_word_compare
    end
  end

  get :up, to: 'rails/health#show'

  # Route for domain-specific favicons
  get 'favicon.ico', to: 'favicons#show'

  # Named route used by views (show_law_path)
  get '/laws/:numac', to: 'laws#show', as: 'show_law'

  # SEO: 301 redirect doubled-numac pattern (e.g. /laws/2021022601/2021022601 → /laws/2021022601)
  get '/laws/:numac/:dup', to: redirect(status: 301) { |params, _req| "/laws/#{params[:numac]}" },
                           constraints: { numac: /\d{7,}/, dup: /\d{7,}/ }

  # Jurisprudence (court cases)
  get 'jurisprudence', to: 'jurisprudence#index', as: 'jurisprudence_index'
  # ECLI-based URLs: /jurisprudence/ECLI:BE:CASS:2015:ARR.20150619.1
  # Uses *ecli glob because ECLI contains colons; format: false prevents stripping .NNN suffix
  get 'jurisprudence/*ecli/image/:filename', to: 'jurisprudence#case_image', as: 'jurisprudence_image', format: false, constraints: { filename: %r{[^/]+} }
  get 'jurisprudence/*ecli/export_word', to: 'jurisprudence#export_word', as: 'export_word_jurisprudence', format: false
  get 'jurisprudence/*ecli', to: 'jurisprudence#show', as: 'jurisprudence', format: false


  # Parliamentary preparatory works
  get 'parliamentary_work', to: 'parliamentary#index', as: 'parliamentary_work'
  get 'parliamentary_work/:id', to: 'parliamentary#show', as: 'parliamentary', constraints: { id: /\d+/ }

  # SEO: 301 redirect old chamber URL format (e.g. /parliamentary_work/chamber/4611 → /parliamentary_work/4611)
  get 'parliamentary_work/chamber/:id', to: redirect(status: 301) { |params, _req| "/parliamentary_work/#{params[:id]}" },
                                        constraints: { id: /\d+/ }
  get 'parliamentary_work/chamber', to: redirect(status: 301, path: '/parliamentary_work')

  # MP directory & hemicycle visualization
  get 'mps', to: 'parliamentary#mps', as: 'mp_directory'
  get 'mps/hemicycle', to: 'parliamentary#hemicycle_history', as: 'hemicycle_history'
  get 'mps/:key', to: 'parliamentary#mp_show', as: 'mp_profile'

  # Vlaams Parlement
  get 'vlaams-parlement', to: 'vlpar#index', as: 'vlpar_index'

  # Unified search (all sources)
  get 'search', to: 'unified_search#index', as: 'unified_search'

  # Authentication
  get 'login', to: 'sessions#new', as: 'login'
  post 'login', to: 'sessions#create'
  delete 'logout', to: 'sessions#destroy', as: 'logout'
  get 'signup', to: 'registrations#new', as: 'signup'
  post 'signup', to: 'registrations#create'
  get 'confirm/:token', to: 'registrations#confirm', as: 'confirm_email'
  get 'registered', to: 'registrations#registered', as: 'registered'
  post 'resend-confirmation', to: 'registrations#resend_confirmation', as: 'resend_confirmation'
  post 'reactivate', to: 'sessions#reactivate', as: 'reactivate_account'
  get 'reactivate/:token', to: 'sessions#confirm_reactivation', as: 'confirm_reactivation'

  # Password reset
  get 'forgot-password', to: 'password_resets#new', as: 'new_password_reset'
  post 'forgot-password', to: 'password_resets#create', as: 'password_reset'
  get 'reset-password/:token', to: 'password_resets#edit', as: 'edit_password_reset'
  patch 'reset-password/:token', to: 'password_resets#update'

  # Subscriptions, Pricing & Credits (only when chatbot/billing is enabled)
  if Rails.application.config.chatbot_enabled
    get 'pricing', to: 'subscriptions#pricing', as: 'pricing'
    get 'subscription', to: 'subscriptions#show', as: 'subscription'
    get 'checkout/:tier', to: 'subscriptions#checkout', as: 'checkout'
    get 'subscription/success', to: 'subscriptions#success', as: 'subscription_success'
    post 'subscription/cancel', to: 'subscriptions#cancel', as: 'cancel_subscription'
    post 'subscription/reactivate', to: 'subscriptions#reactivate', as: 'reactivate_subscription'

    # Crypto checkout (CoinGate)
    get 'checkout/:tier/crypto', to: 'subscriptions#crypto_checkout', as: 'crypto_checkout'
    get 'subscription/crypto-success', to: 'subscriptions#crypto_success', as: 'crypto_subscription_success'

    get 'credits', to: 'credits#index', as: 'credits'
    post 'credits/purchase', to: 'credits#purchase', as: 'credits_purchase'
    get 'credits/success', to: 'credits#success', as: 'credits_success'
    get 'credits/cancel', to: 'credits#cancel', as: 'credits_cancel'
    post 'credits/crypto-purchase', to: 'credits#crypto_purchase', as: 'credits_crypto_purchase'
    get 'credits/crypto-success', to: 'credits#crypto_success', as: 'credits_crypto_success'
  end

  # Payment webhooks — always reachable (processes billing events for existing subscriptions)
  post 'webhooks/stripe', to: 'webhooks/stripe#create'
  post 'webhooks/coingate', to: 'webhooks/coin_gate#create', as: 'webhooks_coingate'

  # Account management (GDPR)
  get 'account', to: 'account#show', as: 'account'
  get 'account/edit', to: 'account#edit', as: 'edit_account'
  patch 'account', to: 'account#update'
  patch 'account/preferences', to: 'account#update_preferences'
  get 'account/export', to: 'account#export_data', as: 'export_data'
  delete 'account', to: 'account#destroy', as: 'delete_account'
  patch 'account/cancel_deletion', to: 'account#cancel_deletion', as: 'cancel_deletion_account'

  if Rails.application.config.chatbot_enabled
    # Stripe Customer Portal
    get 'account/billing', to: 'account#billing_portal', as: 'billing_portal'

    # Billing info for PEPPOL e-invoicing
    get 'account/billing-info', to: 'account#billing_info', as: 'billing_info'
    patch 'account/billing-info', to: 'account#update_billing_info', as: 'update_billing_info'

    # Invoice download
    get 'account/invoices', to: 'invoices#index', as: 'invoices'
    get 'account/invoices/:id/download', to: 'invoices#download', as: 'download_invoice'
    get 'account/invoices/:id/download_xml', to: 'invoices#download_xml', as: 'download_invoice_xml'
  end

  # Security & Activity
  get 'account/activity', to: 'account#activity_log', as: 'activity_log'
  get 'account/2fa/setup', to: 'two_factor#setup', as: 'setup_2fa'
  post 'account/2fa/enable', to: 'two_factor#enable', as: 'enable_2fa'
  delete 'account/2fa/disable', to: 'two_factor#disable', as: 'disable_2fa'
  get 'account/2fa/challenge', to: 'two_factor#challenge', as: 'challenge_2fa'
  post 'account/2fa/verify', to: 'two_factor#verify', as: 'verify_2fa'

  # Admin — accessible via admin.wetwijzer.be subdomain OR /admin path on staging
  admin_constraint = if ENV['WETWIJZER_ADMIN_SUBDOMAIN'] == 'false'
                       ->(_req) { true } # No subdomain check (staging)
                     else
                       ->(req) { req.subdomain == 'admin' }
                     end

  constraints admin_constraint do
    namespace :admin do
      # Admin-specific login (separate from regular user login)
      get 'login', to: 'sessions#new', as: 'login'
      post 'login', to: 'sessions#create'
      delete 'logout', to: 'sessions#destroy', as: 'logout'

      get '/', to: 'dashboard#index', as: 'dashboard'
      post 'clear_all_rate_limits', to: 'dashboard#clear_all_rate_limits', as: 'clear_all_rate_limits'
      resources :users, only: %i[index new create show destroy] do
        member do
          post :add_credits
          post :remove_credits
          post :toggle_lock
          post :reset_free_credits
          post :reset_pro_credits
          post :confirm_user
          post :send_password_reset
          post :cancel_deletion
          post :toggle_active
          post :update_tier
          post :set_credits
          post :resend_verification
          post :clear_rate_limits
        end
        collection do
          post :cleanup_unverified
        end
      end
      get 'chatbot_analytics', to: 'chatbot_analytics#index', as: 'chatbot_analytics'
      get 'conversation_audit_log', to: 'conversation_audit_log#index', as: 'conversation_audit_log'
      resources :chatbot_reports, only: %i[index show update destroy], path: 'reports'

      resources :invoices, only: %i[index show new create destroy] do
        member do
          get :download
          get :download_xml
          post :regenerate
          post :send_email
          post :sync_octopus
          get :check_octopus_status
          post :push_to_dms
        end
        collection do
          get :export
          get :export_pdfs
          get :export_xml
          post :sync_all_octopus
          post :push_all_to_dms
        end
      end
    end
  end



  # Chatbot test interface (feature-flagged)
  if Rails.application.config.chatbot_enabled
    get 'chatbot', to: 'chatbot#index'
    post 'chatbot', to: 'chatbot#create' # Hero form POST → session handoff → redirect to GET
    post 'chatbot/ask', to: 'chatbot#ask', as: 'chatbot_ask'
  end



  # API routes
  namespace :api do
    # Global search (header quick-search)
    get 'search', to: 'global_search#search'

    # Anonymous sample question click tracking (no auth, fire-and-forget)
    post 'sample_question_clicks', to: 'sample_question_clicks#create'

    # AI chatbot API (feature-flagged)
    if Rails.application.config.chatbot_enabled
      # OpenAI version (requires API key, costs money)
      post 'chatbot/ask', to: 'chatbot#ask'
      get 'chatbot/ask', to: 'chatbot#ask' # For SSE streaming
      get 'chatbot/health', to: 'chatbot#health'
      post 'chatbot/feedback', to: 'chatbot#feedback'
      post 'chatbot/report', to: 'chatbot#report'
      post 'chatbot/save', to: 'chatbot#save'
      get 'chatbot/saved', to: 'chatbot#saved'
      delete 'chatbot/saved/:id', to: 'chatbot#destroy_saved'
      get 'chatbot/cost_dashboard', to: 'chatbot#cost_dashboard'
      post 'chatbot/deep_analysis', to: 'chatbot#deep_analysis'
      post 'chatbot/log_slow_query', to: 'chatbot#log_slow_query'

      # Conversation management (server-side history + zero-knowledge)
      get 'chatbot/conversations', to: 'chatbot#conversations'
      get 'chatbot/conversations/:token', to: 'chatbot#show_conversation'
      delete 'chatbot/conversations/:token', to: 'chatbot#destroy_conversation'
      patch 'chatbot/conversations/:token', to: 'chatbot#update_conversation'
      patch 'chatbot/conversations/:token/encrypted', to: 'chatbot#update_encrypted_payload'
      post 'chatbot/conversations/consent', to: 'chatbot#grant_consent'
      delete 'chatbot/conversations/consent', to: 'chatbot#revoke_consent'
      post 'chatbot/conversations/import', to: 'chatbot#import_conversations'
      get 'chatbot/zk_key_material', to: 'chatbot#zk_key_material'

      # Local version (free, uses Ollama)
      post 'local_chatbot/ask', to: 'local_chatbot#ask'
      get 'local_chatbot/health', to: 'local_chatbot#health'
    end

    # Bookmarks API (server-side, requires login)
    get 'bookmarks', to: 'bookmarks#index'
    post 'bookmarks', to: 'bookmarks#create'
    delete 'bookmarks/:numac', to: 'bookmarks#destroy', constraints: { numac: %r{[^/]+} }
    patch 'bookmarks/:numac', to: 'bookmarks#update', constraints: { numac: %r{[^/]+} }
    post 'bookmarks/import', to: 'bookmarks#import'
    get 'bookmarks/check', to: 'bookmarks#check'

    # UI Preferences API (server-side, replaces ALL localStorage)
    get 'preferences', to: 'preferences#show'
    patch 'preferences', to: 'preferences#update'
    delete 'preferences', to: 'preferences#destroy'

    # Search alerts
    post 'search_alerts', to: 'search_alerts#create'
    get 'search_alerts/confirm/:token', to: 'search_alerts#confirm', as: 'search_alert_confirm'
    get 'search_alerts/unsubscribe/:token', to: 'search_alerts#unsubscribe', as: 'search_alert_unsubscribe'
    delete 'search_alerts/unsubscribe/:token', to: 'search_alerts#unsubscribe'

    # Partner app API (JWT authenticated)
    post 'partner/authorize', to: 'partner#authorize'
    post 'partner/refresh', to: 'partner#refresh'
    delete 'partner/revoke', to: 'partner#revoke'
    get 'partner/me', to: 'partner#me'
    get 'partner/saved_answers', to: 'partner#saved_answers'
    get 'partner/question_history', to: 'partner#question_history'
    get 'partner/bookmarks', to: 'partner#bookmarks'
    post 'partner/bookmarks', to: 'partner#sync_bookmarks'
    delete 'partner/bookmarks/:numac', to: 'partner#remove_bookmark'
    get 'partner/status', to: 'partner#status'
    post 'partner/chatbot/ask', to: 'partner#chatbot_ask' if Rails.application.config.chatbot_enabled
    post 'partner/chatbot/deep_analysis', to: 'partner#deep_analysis' if Rails.application.config.chatbot_enabled
    get 'partner/search', to: 'partner#search'
  end

  root to: 'laws#index'

  # Legal pages — served through application layout
  get 'contact', to: 'legal_pages#contact', as: 'contact'
  get 'about', to: 'legal_pages#about', as: 'about'
  get 'faq', to: 'legal_pages#faq', as: 'faq'
  get 'terms-of-service', to: 'legal_pages#terms', as: 'terms_of_service'
  get 'privacy-policy', to: 'legal_pages#privacy', as: 'privacy_policy'
  get 'ai-security', to: 'legal_pages#ai_security', as: 'ai_security'
  get 'imprint', to: 'legal_pages#imprint', as: 'imprint'
  get 'accessibility-statement', to: 'legal_pages#accessibility', as: 'accessibility_statement'
  get 'legal-changes', to: 'legal_pages#legal_changes', as: 'legal_changes'

  # ELI (European Legislation Identifier) routes — 301 permanent redirects
  # Belgian Justel ELI format: /eli/{type}/{yyyy}/{mm}/{dd}/{numac}/justel
  # Examples:
  #   /eli/wet/1967/10/10/1967101055/justel
  #   /eli/loi/1804/03/21/1804032150/justel
  #   /eli/grondwet/1831/02/07/1831020701/justel
  get 'eli/:type/:year/:month/:day/:numac/justel', to: redirect(status: 301) { |path_params, _request|
    lang = %w[loi arrete decret ordonnance constitution code circulaire].any? { |t| path_params[:type].downcase.start_with?(t) } ? 2 : 1
    "/laws/#{path_params[:numac]}?language_id=#{lang}"
  }
  get 'eli/:type/:year/:month/:day/:numac', to: redirect(status: 301) { |path_params, _request|
    lang = %w[loi arrete decret ordonnance constitution code circulaire].any? { |t| path_params[:type].downcase.start_with?(t) } ? 2 : 1
    "/laws/#{path_params[:numac]}?language_id=#{lang}"
  }

  # SEO: dynamic robots.txt (blocks staging subdomains from indexing)
  get 'robots.txt', to: 'robots#show', defaults: { format: :text }

  # Sitemaps (SEO)
  get 'sitemap.xml', to: 'sitemaps#index', defaults: { format: :xml }
  get 'sitemap-static.xml', to: 'sitemaps#static', defaults: { format: :xml }
  get 'sitemap-laws-:page.xml', to: 'sitemaps#laws', defaults: { format: :xml }, constraints: { page: /\d+/ }

  # GDPR takedown request (Art. 17 — accessible without login)
  get 'gdpr/takedown', to: 'gdpr_takedown#new', as: 'gdpr_takedown'
  post 'gdpr/takedown', to: 'gdpr_takedown#create'
  get 'gdpr/takedown/confirmation', to: 'gdpr_takedown#confirmation', as: 'gdpr_takedown_confirmation'

  # Error pages (used by config.exceptions_app = routes)
  match '/404', to: 'errors#not_found', via: :all
  match '/422', to: 'errors#unprocessable_entity', via: :all
  match '/500', to: 'errors#internal_server_error', via: :all

  # Route for unmatched paths (catch-all 404)
  match '*unmatched', to: 'errors#not_found', via: :all
end
