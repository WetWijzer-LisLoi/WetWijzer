# frozen_string_literal: true

# Puma configuration - https://puma.io/puma/Puma/DSL.html

threads_count = ENV.fetch('RAILS_MAX_THREADS', 3)
threads threads_count, threads_count

# Worker processes (clustered mode, not supported on Windows)
# 2 workers x 5 threads = 10 concurrent (4GB RAM)
# 3 workers x 5 threads = 15 concurrent (8GB / 4 vCPU CAX21)
web_concurrency = Integer(ENV.fetch('WEB_CONCURRENCY') { Gem.win_platform? ? 0 : 3 })
workers web_concurrency if web_concurrency.positive?

# Preload the application only when using multi-worker mode
preload_app! if web_concurrency.positive?

# Bind to localhost only on Linux (defense-in-depth: prevents direct public access bypassing nginx)
if Gem.win_platform?
  port ENV.fetch('PORT', 3000)
else
  bind "tcp://127.0.0.1:#{ENV.fetch('PORT', 3000)}"
end

# Chatbot requests can take 60-90s (FAISS search + bilingual translations + LLM with high reasoning).
# Default worker_timeout is 60s which kills these requests. Set to 120s.
worker_timeout ENV.fetch('PUMA_WORKER_TIMEOUT', 120).to_i

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Run the Solid Queue supervisor inside of Puma for single-server deployments
plugin :solid_queue if ENV['SOLID_QUEUE_IN_PUMA']

# PID file (defaults to tmp/pids/server.pid in development)
pidfile ENV['PIDFILE'] if ENV['PIDFILE']

# ── Memory Management - PumaWorkerKiller ──
# Auto-recycle workers that exceed memory thresholds.
# Prevents memory bloat (1.4GB+ per worker) causing staging 502s.
if web_concurrency.positive?
  begin
    require 'puma_worker_killer'

    PumaWorkerKiller.config do |config|
      config.ram           = ENV.fetch('PUMA_RAM_LIMIT_MB', 2048).to_i # Total RSS limit (MB) for all Puma processes
      config.frequency     = 30                                          # Check every 30 seconds
      config.percent_usage = 0.90                                        # Trigger at 90% of ram limit
      config.rolling_restart_frequency = 6 * 3600                        # Rolling restart every 6 hours
      config.reaper_status_logs = true                                   # Log RSS status on each check
    end

    PumaWorkerKiller.start
  rescue LoadError
    # puma_worker_killer not installed (development/Windows) - skip silently
  end
end
