# frozen_string_literal: true

Rails.application.routes.draw do
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

  # Chatbot test interface
  get 'chatbot', to: 'chatbot#index'
  post 'chatbot/ask', to: 'chatbot#ask', as: 'chatbot_ask'

  # API routes for AI chatbot
  namespace :api do
    # OpenAI version (requires API key, costs money)
    post 'chatbot/ask', to: 'chatbot#ask'
    get 'chatbot/ask', to: 'chatbot#ask' # For SSE streaming
    get 'chatbot/health', to: 'chatbot#health'

    # Local version (free, uses Ollama)
    post 'local_chatbot/ask', to: 'local_chatbot#ask'
    get 'local_chatbot/health', to: 'local_chatbot#health'
  end

  root to: 'laws#index'

  # Route for 404 errors
  match '*unmatched', to: 'errors#not_found', via: :all
end
