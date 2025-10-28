# frozen_string_literal: true

source 'https://rubygems.org'

ruby '3.4.7'

# required?
gem 'ostruct'
gem 'fiddle' # Ruby 3.5+ will not include fiddle by default
# Use the Puma web server [https://github.com/puma/puma]
gem 'puma'
# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem 'rails'
# Use sqlite3 as the database for Active Record
gem 'csv'
gem 'sqlite3'

# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem 'turbo-rails'

# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem 'stimulus-rails'

gem 'pagy' # Update to latest
gem 'view_component'
gem 'vite_rails'

# Build JSON APIs with ease [https://github.com/rails/jbuilder]
# gem "jbuilder"

# Use Redis adapter to run Action Cable in production
# gem "redis"

# Use Kredis to get higher-level data types in Redis [https://github.com/rails/kredis]
# gem "kredis"

# Use Active Storage to manage file uploads
gem 'activestorage'

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem 'bcrypt'

# Stripe for payments
gem 'stripe'

# Two-factor authentication
gem 'rotp'      # Time-based one-time passwords
gem 'rqrcode'   # QR code generation

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem 'tzinfo-data', platforms: %i[windows jruby]

gem 'dockerfile-rails', group: :development
gem 'dotenv-rails', groups: [:development, :test]

gem 'msgpack'

## Sessions are disabled app-wide; drop session store gem
# gem 'activerecord-session_store'
gem 'http_accept_language'

# Date/Time validation
gem 'timeliness'

# Rate limiting and attack protection
gem 'rack-attack'

# OpenAI API client for chatbot
gem 'ruby-openai'

# Development tools
group :development do
  # Add development-specific gems here if needed
  gem 'rubocop', require: false
  gem 'ruby-lsp', require: false
end
gem 'whenever', group: :development

# Test tools (for system/integration tests)
group :test do
  gem 'capybara'
  gem 'cuprite'
  gem 'rails-controller-testing'
end
