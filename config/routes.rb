# frozen_string_literal: true

Rails.application.routes.draw do
  resources :laws, param: :numac, only: %i[index show] do
    member do
      get :articles
      get :article_exdecs
      get :export_word
    end
  end

  get :up, to: 'rails/health#show'

  # Route for domain-specific favicons
  get 'favicon.ico', to: 'favicons#show'

  get '/laws/:numac', to: 'laws#show', as: 'show_law'
  # Example constraints for legacy routes:
  # constraints: { id: /[A-Z]\d{10}/ } # change id to numac or delete line

  root to: 'laws#index'

  # Route for 404 errors
  match '*unmatched', to: 'errors#not_found', via: :all
end
