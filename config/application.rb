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

require_relative '../lib/encryption_key_contract'

module WetWijzer
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    config.autoload_lib(ignore: %w[assets tasks encryption_key_contract.rb])

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

    # Authentication remains in signed cookies. Rails still needs an enabled
    # session for its authenticity-token checks, so keep a minimal encrypted,
    # host-only, browser-session cookie for CSRF state. It contains no
    # authentication or business data.
    config.session_store :cookie_store,
                         key: '_wetwijzer_csrf_session',
                         secure: %w[production staging].include?(Rails.env),
                         httponly: true,
                         same_site: :lax

    # Flash remains cookie-backed through CookieFlash; loading Rails' session
    # flash middleware would duplicate that state.
    config.middleware.delete ActionDispatch::Flash
    # Keep ActionDispatch::Cookies for signed authentication and flash cookies.

    # Gzip compression for all responses.
    # Turbo Frame HTML (e.g. 4MB Strafwetboek articles) compresses ~80%.
    # Supplements nginx gzip and ensures compression for direct Puma connections.
    # SSE (text/event-stream) is excluded: the chatbot streams heartbeats via
    # ActionController::Live, and running those through the deflater risks
    # events sitting in the compression buffer instead of reaching the client.
    config.middleware.use Rack::Deflater, if: lambda { |_env, _status, headers, _body|
      content_type = headers['content-type'] || headers['Content-Type']
      !content_type.to_s.include?('text/event-stream')
    }

    # ActiveRecord::Encryption at rest - user PII, OTP secrets, chatbot
    # conversations, invoices. Keys come from env vars (systemd
    # EnvironmentFile), never source control. EncryptionKeyContract makes
    # production and staging fail to BOOT when any of the three values is
    # missing, blank, or one of the public development placeholders; before
    # it, those environments silently fell back to keys that are readable in
    # this repository. Development and test keep the public defaults.
    encryption_keys = EncryptionKeyContract.fetch!(Rails.env)
    config.active_record.encryption.primary_key = encryption_keys['AR_ENCRYPTION_PRIMARY_KEY']
    config.active_record.encryption.deterministic_key = encryption_keys['AR_ENCRYPTION_DETERMINISTIC_KEY']
    config.active_record.encryption.key_derivation_salt = encryption_keys['AR_ENCRYPTION_KEY_DERIVATION_SALT']
    # FBL-011 Release B (2026-08-18): the placeholder-to-real rotation is
    # COMPLETE (final audit previous=0 plaintext=0 failed=0), so the legacy
    # previous-scheme shim is gone and plaintext passthrough is closed in
    # the enforced environments - a value that fails decryption there now
    # raises instead of silently returning ciphertext as text. Development
    # and test keep passthrough: the suite plants plaintext rows on purpose
    # to exercise the audit classifier, and those environments already run
    # on the public default keys. If keys ever rotate again, reintroduce a
    # previous scheme via an explicit key provider that pins the OLD
    # derivation salt (Rails derives through the global salt; see the
    # encryption-rotation runbook and git history of lib/encryption_rotation.rb),
    # and keep deterministic: { fixed: false } so the pass actually drains.
    config.active_record.encryption.support_unencrypted_data =
      !EncryptionKeyContract::ENFORCED_ENVIRONMENTS.include?(Rails.env.to_s)
  end
end
