# frozen_string_literal: true

require 'active_support/core_ext/integer/time'

Rails.application.configure do
  # Staging environment - similar to production but with some debugging enabled

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance.
  config.eager_load = true

  # Use secret_key_base from environment (no master.key needed on staging)
  config.secret_key_base = ENV['SECRET_KEY_BASE'] if ENV['SECRET_KEY_BASE'].present?

  # Show full error reports for easier debugging in staging.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry.
  config.public_file_server.headers = { 'cache-control' => "public, max-age=#{1.year.to_i}" }

  # Store uploaded files on the local file system.
  config.active_storage.service = :local

  # Assume SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force SSL in staging too.
  config.force_ssl = true

  # Log to staging.log file + STDOUT (for journalctl)
  config.log_tags = [:request_id]
  file_logger = ActiveSupport::Logger.new(Rails.root.join('log', 'staging.log'), 5, 50.megabytes)
  broadcast_logger = ActiveSupport::BroadcastLogger.new(file_logger, ActiveSupport::Logger.new($stdout))
  config.logger = ActiveSupport::TaggedLogging.new(broadcast_logger)

  # More verbose logging for staging debugging.
  config.log_level = ENV.fetch('RAILS_LOG_LEVEL', 'debug')

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = '/up'

  # Report deprecations for debugging.
  config.active_support.report_deprecations = true

  # Use in-memory cache store.
  config.cache_store = :memory_store, {
    size: 128 * 1024 * 1024 # 128 MB
  }

  # ActionMailer configuration (Migadu SMTP - staging uses same)
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.perform_deliveries = true
  config.action_mailer.raise_delivery_errors = true
  config.action_mailer.default_url_options = { host: 'staging.wetwijzer.be', protocol: 'https' }
  config.action_mailer.smtp_settings = {
    address: 'smtp.migadu.com',
    port: 587,
    domain: 'wetwijzer.be',
    user_name: ENV.fetch('SMTP_USERNAME', nil),
    password: ENV.fetch('SMTP_PASSWORD', nil),
    authentication: :plain,
    enable_starttls_auto: true
  }

  # Enable locale fallbacks for I18n.
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections.
  config.active_record.attributes_for_inspect = [:id]

  # Allow staging hosts.
  config.hosts = [
    'staging.wetwijzer.be',
    'staging.lisloi.be',
    'staging.gesetzguide.be',
    /.*\.wetwijzer\.be/,
    /.*\.lisloi\.be/,
    /.*\.gesetzguide\.be/,
    'localhost',
    '127.0.0.1',
    /\A127\.0\.0\.1(:\d+)?\z/ # Allow 127.0.0.1 with any port
  ]

  # Skip DNS rebinding protection for the health check endpoint.
  config.host_authorization = { exclude: ->(request) { request.path == '/up' } }
end
