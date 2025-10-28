# frozen_string_literal: true

require_relative 'boot'

require 'rails'
# Pick the frameworks you want:
require 'active_model/railtie'
require 'active_job/railtie'
require 'active_record/railtie'
require 'active_storage/engine'
require 'action_controller/railtie'
require 'action_mailer/railtie'
# require "action_mailbox/engine"
# require "action_text/engine"
require 'action_view/railtie'
# require "action_cable/engine"
require 'rails/test_unit/railtie'

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module WetWijzer
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil

    # Use SQL structure dump for SQLite FTS compatibility
    config.active_record.schema_format = :sql

    # Disable image variant processing (we don't use it)
    config.active_storage.variant_processor = :disabled

    # Custom settings worth keeping
    # Use the local timezone for display and ActiveSupport helpers
    config.time_zone = 'Brussels'
    # Route exceptions through the router to render custom error pages
    config.exceptions_app = routes

    # Minimal cookies for chatbot authentication only
    # We use signed cookies (not sessions) for auth tokens
    # No tracking, no analytics, just auth
    config.session_store :disabled
    config.middleware.delete ActionDispatch::Session::CookieStore
    config.middleware.delete ActionDispatch::Flash
    # Keep ActionDispatch::Cookies for signed cookie auth

    # Gzip compression for all responses.
    # Turbo Frame HTML (e.g. 4MB Strafwetboek articles) compresses ~80%.
    # Supplements nginx gzip and ensures compression for direct Puma connections.
    config.middleware.use Rack::Deflater

    # Praxis desktop WebView integration: conditionally relax CSP
    # frame-ancestors for embedded requests (?embedded=true)
    require Rails.root.join('app/middleware/praxis_embedded_middleware').to_s
    config.middleware.use PraxisEmbeddedMiddleware

    # ActiveRecord::Encryption at rest — encrypts chatbot conversation messages
    # Keys are stored in env vars (systemd EnvironmentFile), never in source control
    config.active_record.encryption.primary_key = ENV.fetch('AR_ENCRYPTION_PRIMARY_KEY', 'dev-only-primary-key-not-for-prod')
    config.active_record.encryption.deterministic_key = ENV.fetch('AR_ENCRYPTION_DETERMINISTIC_KEY', 'dev-only-deterministic-key-not-for-prod')
    config.active_record.encryption.key_derivation_salt = ENV.fetch('AR_ENCRYPTION_KEY_DERIVATION_SALT', 'dev-only-salt-not-for-prod')
    # Allow reading existing unencrypted data during transition (conversations expire in 24h)
    config.active_record.encryption.support_unencrypted_data = true
  end
end
