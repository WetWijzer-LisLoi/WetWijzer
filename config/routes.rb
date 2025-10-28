# frozen_string_literal: true

Rails.application.routes.draw do
  # Bookmarks page (client-side only, no database)
  get 'bookmarks', to: 'laws#bookmarks', as: 'bookmarks'

  resources :laws, param: :numac, only: %i[index show] do
    member do
      get :articles
      get :article_exdecs
      get :export_word
      get :compare
      get :export_word_compare
    end
  end

  get :up, to: 'rails/health#show'

  # Route for domain-specific favicons
  get 'favicon.ico', to: 'favicons#show'

  get '/laws/:numac', to: 'laws#show', as: 'show_law'
  # Example constraints for legacy routes:
  # constraints: { id: /[A-Z]\d{10}/ } # change id to numac or delete line

  # Jurisprudence (court cases)
  resources :jurisprudence, only: [:index, :show]
  get 'rechtspraak', to: 'jurisprudence#index', as: 'rechtspraak'

  # Parliamentary preparatory works
  resources :parliamentary, only: [:index, :show], path: 'parliamentary_work'
  get 'parliamentary_work', to: 'parliamentary#index', as: 'parliamentary_work'

  # Unified search (all sources)
  get 'zoeken', to: 'unified_search#index', as: 'unified_search'

  # Legal tools
  get 'tools', to: 'tools#index', as: 'tools'
  get 'tools/termijncalculator', to: 'tools#deadline_calculator', as: 'tools_deadline_calculator'
  get 'tools/rente', to: 'tools#interest_calculator', as: 'tools_interest_calculator'
  get 'tools/rechtbank', to: 'tools#court_finder', as: 'tools_court_finder'
  get 'tools/woordenboek', to: 'tools#glossary', as: 'tools_glossary'
  get 'tools/verjaring', to: 'tools#limitations', as: 'tools_limitations'
  get 'tools/conclusiekalender', to: 'tools#conclusion_calendar', as: 'tools_conclusion_calendar'
  get 'tools/rolrechten', to: 'tools#court_fees', as: 'tools_court_fees'
  get 'tools/checklist', to: 'tools#checklist', as: 'tools_checklist'
  get 'tools/feestdagen/:year', to: 'tools#holidays', as: 'tools_holidays'
  get 'tools/feestdagen', to: 'tools#holidays'

  # Authentication
  get 'login', to: 'sessions#new', as: 'login'
  post 'login', to: 'sessions#create'
  delete 'logout', to: 'sessions#destroy', as: 'logout'
  get 'signup', to: 'registrations#new', as: 'signup'
  post 'signup', to: 'registrations#create'
  get 'confirm/:token', to: 'registrations#confirm', as: 'confirm_email'
  post 'resend-confirmation', to: 'registrations#resend_confirmation', as: 'resend_confirmation'

  # Password reset
  get 'forgot-password', to: 'password_resets#new', as: 'new_password_reset'
  post 'forgot-password', to: 'password_resets#create', as: 'password_reset'
  get 'reset-password/:token', to: 'password_resets#edit', as: 'edit_password_reset'
  patch 'reset-password/:token', to: 'password_resets#update'

  # Subscriptions & Pricing
  get 'pricing', to: 'subscriptions#pricing', as: 'pricing'
  get 'subscription', to: 'subscriptions#show', as: 'subscription'
  get 'checkout/:tier', to: 'subscriptions#checkout', as: 'checkout'
  get 'subscription/success', to: 'subscriptions#success', as: 'subscription_success'
  post 'subscription/cancel', to: 'subscriptions#cancel', as: 'cancel_subscription'
  post 'subscription/reactivate', to: 'subscriptions#reactivate', as: 'reactivate_subscription'

  # Credits
  get 'credits', to: 'credits#index', as: 'credits'
  get 'credits/buy', to: 'credits#buy', as: 'credits_buy'
  post 'credits/purchase', to: 'credits#purchase', as: 'credits_purchase'
  get 'credits/success', to: 'credits#success', as: 'credits_success'
  get 'credits/cancel', to: 'credits#cancel', as: 'credits_cancel'

  # Account management (GDPR)
  get 'account', to: 'account#show', as: 'account'
  get 'account/edit', to: 'account#edit', as: 'edit_account'
  patch 'account', to: 'account#update'
  patch 'account/preferences', to: 'account#update_preferences'
  get 'account/export', to: 'account#export_data', as: 'export_data'
  delete 'account', to: 'account#destroy', as: 'delete_account'
  
  # Stripe Customer Portal
  get 'account/billing', to: 'account#billing_portal', as: 'billing_portal'
  
  # Billing info for PEPPOL e-invoicing
  get 'account/billing-info', to: 'account#billing_info', as: 'billing_info'
  patch 'account/billing-info', to: 'account#update_billing_info', as: 'update_billing_info'
  
  # Security & Activity
  get 'account/activity', to: 'account#activity_log', as: 'activity_log'
  get 'account/2fa/setup', to: 'two_factor#setup', as: 'setup_2fa'
  post 'account/2fa/enable', to: 'two_factor#enable', as: 'enable_2fa'
  delete 'account/2fa/disable', to: 'two_factor#disable', as: 'disable_2fa'
  get 'account/2fa/challenge', to: 'two_factor#challenge', as: 'challenge_2fa'
  post 'account/2fa/verify', to: 'two_factor#verify', as: 'verify_2fa'

  # Stripe webhooks
  post 'webhooks/stripe', to: 'webhooks/stripe#create'

  # Chatbot test interface
  get 'chatbot', to: 'chatbot#index'
  post 'chatbot/ask', to: 'chatbot#ask', as: 'chatbot_ask'

  # API routes for AI chatbot
  namespace :api do
    # Global search (header quick-search)
    get 'search', to: 'global_search#search'
    # OpenAI version (requires API key, costs money)
    post 'chatbot/ask', to: 'chatbot#ask'
    get 'chatbot/ask', to: 'chatbot#ask' # For SSE streaming
    get 'chatbot/health', to: 'chatbot#health'
    post 'chatbot/feedback', to: 'chatbot#feedback'
    post 'chatbot/save', to: 'chatbot#save'
    get 'chatbot/saved', to: 'chatbot#saved'
    delete 'chatbot/saved/:id', to: 'chatbot#destroy_saved'

    # Local version (free, uses Ollama)
    post 'local_chatbot/ask', to: 'local_chatbot#ask'
    get 'local_chatbot/health', to: 'local_chatbot#health'

    # Search alerts
    post 'search_alerts', to: 'search_alerts#create'
    get 'search_alerts/confirm/:token', to: 'search_alerts#confirm', as: 'search_alert_confirm'
    get 'search_alerts/unsubscribe/:token', to: 'search_alerts#unsubscribe', as: 'search_alert_unsubscribe'
    delete 'search_alerts/unsubscribe/:token', to: 'search_alerts#unsubscribe'
  end

  root to: 'laws#index'

  # Legal pages - redirect to locale-specific static files
  get 'privacy-policy', to: redirect { |params, request|
    locale = request.host.include?('lisloi') ? 'fr' : 'nl'
    "/privacy-#{locale}.html"
  }
  get 'terms', to: redirect { |params, request|
    locale = request.host.include?('lisloi') ? 'fr' : 'nl'
    "/terms-#{locale}.html"
  }

  # Route for 404 errors
  match '*unmatched', to: 'errors#not_found', via: :all
end
