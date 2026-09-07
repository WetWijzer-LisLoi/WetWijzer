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

# Worker lifecycle is managed by systemd and Puma itself. The former
# puma_worker_killer hook started before Puma's cluster existed, so its scheduled
# thread crashed instead of recycling workers. Reintroduce memory-based
# recycling only after measuring real RSS/PSS and validating the lifecycle in
# staging.
