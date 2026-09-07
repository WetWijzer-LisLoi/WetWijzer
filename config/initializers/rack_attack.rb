# frozen_string_literal: true

# Configure Rack::Attack for rate limiting and request protection
# Documentation: https://github.com/rack/rack-attack

module Rack
  class Attack
    # Always allow requests from localhost (for health checks, monitoring)
    Rack::Attack.safelist('allow-localhost') do |req|
      %w[127.0.0.1 ::1].include?(req.ip)
    end

    # Health checks must NEVER be throttled or auto-banned. The deploy canary
    # and external monitors call /up through the PUBLIC hostname, so req.ip is
    # the caller's real address and the localhost safelist above does not
    # cover them. On 2026-08-19 the host tripped its own Allow2Ban rule (1h,
    # 403) and every deploy then failed at the canary with
    # "app /up returned HTTP 403" until the ban was cleared by hand - a rate
    # limiter that can block its own deploys. /up is a static liveness probe
    # with no user data and no side effects, so exempting it costs nothing.
    Rack::Attack.safelist('allow-health-check') do |req|
      req.get? && req.path == '/up'
    end

    # Allow most auth routes (but NOT signup or password reset - those need throttling)
    Rack::Attack.safelist('allow-auth-routes') do |req|
      %w[/login /logout /confirm /account /pricing].any? { |path| req.path.start_with?(path) } &&
        !req.path.start_with?('/forgot-password', '/reset-password')
    end

    # Allow genuine STATIC .json files (e.g. /chatbot_questions.json) but NOT
    # dynamic controller routes that also render .json (/laws.json search &
    # pagination, /search, /api, jurisprudence, parliamentary) — those must stay
    # under the throttles + auto-ban, or a .json suffix bypasses all app-level
    # rate limiting.
    DYNAMIC_JSON_ROOTS = %w[/laws /search /api /jurisprudence /parliamentary].freeze
    Rack::Attack.safelist('allow-static-json') do |req|
      req.path.end_with?('.json') && req.get? && !req.path.include?('altcha-challenge') &&
        DYNAMIC_JSON_ROOTS.none? { |p| req.path.start_with?(p) }
    end

    # Throttle general requests by IP (1000 requests per 5 minutes = ~200/min)
    # Allows normal browsing including lazy-loaded Turbo Frames
    throttle('req/ip', limit: 1000, period: 5.minutes) do |req|
      req.ip unless req.path.start_with?('/assets', '/vite', '/favicon.ico')
    end

    # Anonymous sample-question click beacons: atomic limiter in the shared
    # Rack::Attack store (FBL-043), replacing the controller-side
    # fetch-then-increment cache counter.
    throttle('sample-clicks/ip', limit: 30, period: 1.minute) do |req|
      req.ip if req.post? && req.path == '/api/sample_question_clicks'
    end

    # Throttle search requests (200 requests per minute)
    # Search is computationally cheap with indexed queries
    throttle('search/ip', limit: 200, period: 1.minute) do |req|
      req.ip if %w[/laws /laws.json].include?(req.path) && req.get? && req.params['title'].present?
    end

    # Throttle the unified /search endpoint (unindexed LIKE + COUNT, expensive).
    throttle('unified_search/ip', limit: 30, period: 1.minute) do |req|
      req.ip if req.path == '/search' && req.get? && req.params['q'].present?
    end

    # Throttle rapid pagination crawling (30 page requests per minute per IP)
    # Generous for humans (who browse ~2-3 pages/min) but catches bots
    # crawling all 4800 pages sequentially
    throttle('pagination/ip', limit: 30, period: 1.minute) do |req|
      req.ip if %w[/laws /laws.json].include?(req.path) && req.get? && req.params['page'].present?
    end

    # Throttle Word document exports (10 requests per minute per IP)
    # Document generation is CPU-intensive, limit to prevent abuse
    throttle('export/ip', limit: 10, period: 1.minute) do |req|
      req.ip if req.path.include?('/export_word')
    end

    # Throttle password reset requests (5 per hour per IP)
    # Prevents brute force and email bombing
    throttle('password_reset/ip', limit: 5, period: 1.hour) do |req|
      req.ip if req.path == '/forgot-password' && req.post?
    end

    # Throttle password reset by email (3 per hour per email)
    # Prevents targeted email bombing
    throttle('password_reset/email', limit: 3, period: 1.hour) do |req|
      req.params['email']&.downcase&.strip if req.path == '/forgot-password' && req.post?
    end

    # Throttle login attempts (10 per minute per IP)
    throttle('login/ip', limit: 10, period: 1.minute) do |req|
      req.ip if req.path == '/login' && req.post?
    end

    # Throttle login by email (5 per minute per email)
    # Prevents brute force on specific accounts
    throttle('login/email', limit: 5, period: 1.minute) do |req|
      req.params['email']&.downcase&.strip if req.path == '/login' && req.post?
    end

    # Throttle signup (10 per hour per IP)
    throttle('signup/ip', limit: 10, period: 1.hour) do |req|
      req.ip if req.path == '/signup' && req.post?
    end

    # Throttle signup by email (3 per hour per email)
    # Prevents targeted email bombing via registration
    throttle('signup/email', limit: 3, period: 1.hour) do |req|
      req.params.dig('user', 'email')&.downcase&.strip if req.path == '/signup' && req.post?
    end

    # Throttle confirmation email resends (3 per hour per IP)
    # Prevents email bombing via the resend confirmation button
    throttle('resend_confirmation/ip', limit: 3, period: 1.hour) do |req|
      req.ip if req.path == '/resend-confirmation' && req.post?
    end

    # Anonymous donation checkout creates a provider-side payment resource.
    # Keep ordinary retries possible while preventing API/storage abuse.
    throttle('donations/ip', limit: 20, period: 1.hour) do |req|
      req.ip if req.path == '/donations' && req.post?
    end

    # Throttle the chatbot LLM/cost endpoints (ask, deep_analysis, report) - the
    # ones that run rate_limit_check and consume the shared global cost budget.
    # Lightweight CRUD endpoints (conversations, settings, consent) are NOT throttled.
    # NB: all three share one per-IP counter, so a single IP cannot flood an
    # unthrottled sibling endpoint to trip the global cap (see rate_limit_check).
    CHATBOT_COST_PATHS = %w[/api/chatbot/ask /api/chatbot/deep_analysis /api/chatbot/report].freeze
    throttle('chatbot/ip', limit: 20, period: 1.minute) do |req|
      req.ip if CHATBOT_COST_PATHS.include?(req.path) && req.post?
    end

    # Stricter chatbot limit per hour (200 requests per hour per IP)
    # Prevents sustained abuse - generous enough for power users
    throttle('chatbot/ip/hour', limit: 200, period: 1.hour) do |req|
      req.ip if CHATBOT_COST_PATHS.include?(req.path) && req.post?
    end

    # Rating updates are cheap and deliberately NOT part of CHATBOT_COST_PATHS:
    # sharing the paid counter would let a user who rates several answers lose
    # their remaining question budget. A rating costs no provider call.
    #
    # The discriminator is the raw IP, matching every other throttle in this
    # file. The plan suggested a one-way discriminator; that would make this
    # the only hashed throttle here and buys nothing, because a Rack::Attack
    # key already expires with its period and contains only the throttle name
    # plus this value - never the token, the score, the reasons or content,
    # which is the constraint that actually matters.
    throttle('chatbot_rating/ip', limit: 60, period: 1.minute) do |req|
      req.ip if req.path == '/api/chatbot/rating' && (req.put? || req.patch?)
    end

    # Throttle ALTCHA challenge generation (10 per minute per IP)
    # Prevents abuse of the proof-of-work challenge endpoint
    throttle('geo_challenge/ip', limit: 10, period: 1.minute) do |req|
      req.ip if req.path == '/altcha-challenge.json' && req.get?
    end

    # Throttle geo-challenge verification (5 per minute per IP)
    # Prevents brute-force attempts on the challenge solution
    throttle('geo_verify/ip', limit: 5, period: 1.minute) do |req|
      req.ip if req.path == '/geo-challenge' && req.post?
    end

    # Throttle admin login (3 attempts per 15 minutes per IP)
    # Most sensitive endpoint - strictest limits
    throttle('admin_login/ip', limit: 3, period: 15.minutes) do |req|
      req.ip if req.path == '/admin/login' && req.post?
    end

    # Throttle admin actions (60 per minute per IP)
    # Prevents rapid-fire admin operations (mass delete, etc.)
    throttle('admin_actions/ip', limit: 60, period: 1.minute) do |req|
      req.ip if req.path.start_with?('/admin') && !req.get?
    end

    # Search-engine crawlers legitimately request far faster than a human, so
    # they trip the throttles and then the hour-long ban below. Measured on
    # 2026-08-19: Googlebot was getting ~1,180 HTTP 403 against 129 HTTP 200,
    # i.e. ~90% of Google's crawl refused with the ban page, across five
    # genuine 66.249.x addresses. A 403 tells Google the URL is forbidden and
    # de-indexes it; a 429 (what the throttles answer) is the documented
    # "slow down" signal every major crawler honours. So crawlers stay
    # THROTTLED but are never BANNED. Spoofing the user agent gains nothing:
    # such a request is still rate-limited, it just cannot trip the ban.
    CRAWLER_USER_AGENT = /googlebot|bingbot|duckduckbot|applebot|yandexbot|baiduspider|slurp|petalbot/i

    def self.search_engine_crawler?(request)
      CRAWLER_USER_AGENT.match?(request.user_agent.to_s)
    end

    # Exponential backoff for repeated offenders
    # Only ban truly abusive behavior (50+ violations in 5 minutes = automated attacks)
    Rack::Attack.blocklist('block-repeated-offenders') do |req|
      # Crawlers are exempt from the BAN (they remain throttled) - see above.
      if Rack::Attack.search_engine_crawler?(req)
        false
      else
        # Block if more than 50 throttled requests in 5 minutes (ban for 1 hour)
        # This catches bots/scrapers but allows normal human browsing patterns
        Rack::Attack::Allow2Ban.filter(req.ip, maxretry: 50, findtime: 5.minutes, bantime: 1.hour) do
          # Return true if request should increment the counter
          Rack::Attack.cache.count("#{req.ip}:throttled", 5.minutes) > 50
        end
      end
    end

    # Custom response for throttled requests
    self.throttled_responder = lambda do |request|
      match_data = request.env['rack.attack.match_data']
      now = match_data[:epoch_time]

      headers = {
        'RateLimit-Limit' => match_data[:limit].to_s,
        'RateLimit-Remaining' => '0',
        'RateLimit-Reset' => (now + (match_data[:period] - (now % match_data[:period]))).to_s,
        'Content-Type' => 'application/json'
      }

      [429, headers, [{ error: 'Rate limit exceeded. Please try again later.' }.to_json]]
    end

    # Custom response for blocked requests (temporary ban)
    # Domain-based: lisloi.be = French, wetwijzer.be = Dutch (both include English)
    self.blocklisted_responder = lambda do |request|
      is_french = request.host&.include?('lisloi')

      title = is_french ? 'Temporairement Bloqué - LisLoi' : 'Tijdelijk Geblokkeerd - WetWijzer'
      h1 = is_french ? '⚠️ Temporairement Bloqué' : '⚠️ Tijdelijk Geblokkeerd'
      msg1 = is_french ? 'Votre adresse IP est temporairement bloquée en raison d\'une activité inhabituelle.' : 'Uw IP-adres is tijdelijk geblokkeerd vanwege ongebruikelijke activiteit.'
      msg2 = is_french ? 'Le blocage sera <strong>automatiquement levé après 1 heure</strong>.' : 'De blokkering wordt <strong>automatisch opgeheven na 1 uur</strong>.'

      [403, { 'Content-Type' => 'text/html; charset=utf-8' }, [<<~HTML
        <!DOCTYPE html>
        <html lang="#{is_french ? 'fr' : 'nl'}">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>#{title}</title>
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 600px; margin: 80px auto; padding: 30px; background: #f5f5f5; color: #333; }
            .container { background: white; padding: 40px; border-radius: 12px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
            h1 { color: #d32f2f; margin-top: 0; font-size: 24px; }
            p { line-height: 1.6; color: #555; margin: 10px 0; }
            .en { color: #888; font-style: italic; font-size: 14px; margin-top: 5px; }
            strong { color: #333; }
          </style>
        </head>
        <body>
          <div class="container">
            <h1>#{h1}</h1>
            <p>#{msg1}</p>
            <p class="en">Your IP address is temporarily blocked due to unusual activity.</p>
            <p>#{msg2}</p>
            <p class="en">The block will be automatically lifted after 1 hour.</p>
          </div>
        </body>
        </html>
      HTML
      ]]
    end

    # Log blocked and throttled requests
    ActiveSupport::Notifications.subscribe('rack.attack') do |_name, _start, _finish, _request_id, payload|
      req = payload[:request]
      case req.env['rack.attack.match_type']
      when :throttle
        Rails.logger.warn("Throttled request from #{req.ip} to #{req.path}")
      when :blocklist
        Rails.logger.error("Blocked request from #{req.ip} to #{req.path}")
      end
    end
  end
end

# Enable Rack::Attack in all environments
Rails.application.config.middleware.use Rack::Attack
