# frozen_string_literal: true

source 'https://rubygems.org'

ruby '4.0.5'

# Ruby 4.0 removed these from default gems
gem 'csv'
gem 'ostruct'

# Use the Puma web server [https://github.com/puma/puma]
gem 'puma'
# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem 'rails'
# Use sqlite3 as the database for Active Record
gem 'sqlite3'

# W7 (FBL-070): PostgreSQL for the four mutable lanes. Optional group so a
# machine without libpq (this Windows box) skips the native build; CI and
# PG-mode hosts opt in with BUNDLE_WITH=postgres.
group :postgres, optional: true do
  gem 'pg', '~> 1.5'
end

# Durable background jobs (verification/reset emails, invoice sync). Runs inside
# Puma via `plugin :solid_queue` (config/puma.rb) — no separate worker process /
# systemd unit needed. Replaces the :async adapter, which lost queued jobs on
# every worker restart (silently dropped emails).
gem 'solid_queue'

# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem 'turbo-rails'

# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem 'stimulus-rails'

gem 'pagy'
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

# Two-factor authentication
gem 'rotp'      # Time-based one-time passwords
gem 'rqrcode'   # QR code generation

# JWT for partner API tokens
gem 'jwt'

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem 'tzinfo-data', platforms: %i[windows jruby]

gem 'dockerfile-rails', group: :development
gem 'dotenv-rails', groups: %i[development test]

gem 'http_accept_language'

# Rate limiting and attack protection
gem 'rack-attack'

# OpenAI API client for chatbot
gem 'ruby-openai'

# Security auditing (available in all envs for automated checks)
gem 'brakeman', require: false
gem 'bundler-audit', require: false

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
