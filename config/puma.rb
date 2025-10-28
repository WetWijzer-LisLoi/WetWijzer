# frozen_string_literal: true

# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.
#
# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# You can control the number of workers using ENV["WEB_CONCURRENCY"]. You
# should only set this value when you want to run 2 or more workers. The
# default is already 1.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# prioritize throughput over latency.
#
# As a rule of thumb, increasing the number of threads will increase how much
# traffic a given process can handle (throughput), but due to CRuby's
# Global VM Lock (GVL) it has diminishing returns and will degrade the
# response time (latency) of the application.
#
# The default is set to 3 threads as it's deemed a decent compromise between
# throughput and latency for the average Rails application.
#
# Any libraries that use a connection pool or another resource pool should
# be configured to provide at least as many connections as the number of
# threads. This includes Active Record's `pool` parameter in `database.yml`.
threads_count = ENV.fetch('RAILS_MAX_THREADS', 3)
threads threads_count, threads_count

# Configure worker processes via WEB_CONCURRENCY
# - Worker (clustered) mode is not supported on Windows (no fork)
# - Production/staging: 2 workers recommended (4GB RAM) or 3 (8GB RAM)
# - Each worker runs its own Ruby process with RAILS_MAX_THREADS threads
# - Chatbot requests are IO-bound (Azure API calls take 5-30s), so more
#   threads per worker is beneficial despite CRuby's GVL
# - 2 workers × 5 threads = 10 concurrent requests (minimum for chatbot workload)
# - 3 workers × 5 threads = 15 concurrent (recommended for 8GB / 4 vCPU CAX21)
web_concurrency = Integer(ENV.fetch('WEB_CONCURRENCY') { Gem.win_platform? ? 0 : 3 })
workers web_concurrency if web_concurrency.positive?

# Preload the application only when using multi-worker mode
preload_app! if web_concurrency.positive?

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch('PORT', 3000)

# Chatbot requests can take 60-90s (FAISS search + bilingual translations + LLM with high reasoning).
# Default worker_timeout is 60s which kills these requests. Set to 120s.
worker_timeout ENV.fetch('PUMA_WORKER_TIMEOUT', 120).to_i

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Run the Solid Queue supervisor inside of Puma for single-server deployments
plugin :solid_queue if ENV['SOLID_QUEUE_IN_PUMA']

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV['PIDFILE'] if ENV['PIDFILE']

# ============================================
# MEMORY MANAGEMENT — PumaWorkerKiller
# ============================================
# Auto-recycle workers that exceed memory thresholds.
# Prevents the memory bloat (1.4GB+ per worker) that causes
# staging 502s when production workers starve the shared server.
#
# How it works:
# - Checks total Puma RSS every 30 seconds
# - If total RSS exceeds `ram` limit → kills the largest worker (Puma replaces it)
# - Every `rolling_restart_frequency` seconds → graceful rolling restart of all workers
# - Zero downtime: workers are replaced one at a time
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
    # puma_worker_killer not installed (development/Windows) — skip silently
  end
end
