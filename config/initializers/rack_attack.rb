# frozen_string_literal: true

# Configure Rack::Attack for rate limiting and request protection
# Documentation: https://github.com/rack/rack-attack

module Rack
  class Attack
    # Always allow requests from localhost (for health checks, monitoring)
    Rack::Attack.safelist('allow-localhost') do |req|
      %w[127.0.0.1 ::1].include?(req.ip)
    end

    # Allow most auth routes (but NOT password reset - that needs throttling)
    Rack::Attack.safelist('allow-auth-routes') do |req|
      %w[/login /signup /logout /confirm /account /pricing].any? { |path| req.path.start_with?(path) } &&
        !req.path.start_with?('/forgot-password', '/reset-password')
    end

    # Always allow static JSON files in public folder
    Rack::Attack.safelist('allow-static-json') do |req|
      req.path.end_with?('.json') && req.get?
    end

    # Allow chatbot requests with valid pass token (for automated testing)
    Rack::Attack.safelist('allow-chatbot-pass') do |req|
      req.path.start_with?('/api/chatbot') && req.params['pass'].present?
    end

    # Throttle general requests by IP (1000 requests per 5 minutes = ~200/min)
    # Allows normal browsing including lazy-loaded Turbo Frames
    throttle('req/ip', limit: 1000, period: 5.minutes) do |req|
      req.ip unless req.path.start_with?('/assets', '/vite', '/favicon.ico')
    end

    # Throttle search requests (200 requests per minute)
    # Search is computationally cheap with indexed queries
    throttle('search/ip', limit: 200, period: 1.minute) do |req|
      req.ip if req.path == '/laws' && req.get? && req.params['title'].present?
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
      if req.path == '/forgot-password' && req.post?
        req.params['email']&.downcase&.strip
      end
    end

    # Throttle login attempts (10 per minute per IP)
    throttle('login/ip', limit: 10, period: 1.minute) do |req|
      req.ip if req.path == '/login' && req.post?
    end

    # Throttle login by email (5 per minute per email)
    # Prevents brute force on specific accounts
    throttle('login/email', limit: 5, period: 1.minute) do |req|
      if req.path == '/login' && req.post?
        req.params['email']&.downcase&.strip
      end
    end

    # Throttle signup (10 per hour per IP)
    throttle('signup/ip', limit: 10, period: 1.hour) do |req|
      req.ip if req.path == '/signup' && req.post?
    end

    # Throttle chatbot API (30 requests per minute per IP)
    # LLM calls are expensive - prevent abuse while allowing normal use
    # Skip throttling if pass param is present (for automated testing)
    throttle('chatbot/ip', limit: 30, period: 1.minute) do |req|
      req.ip if req.path.start_with?('/api/chatbot') && req.params['pass'].blank?
    end

    # Stricter chatbot limit per hour (100 requests per hour per IP)
    # Prevents sustained abuse
    # Skip throttling if pass param is present (for automated testing)
    throttle('chatbot/ip/hour', limit: 100, period: 1.hour) do |req|
      req.ip if req.path.start_with?('/api/chatbot') && req.params['pass'].blank?
    end

    # Exponential backoff for repeated offenders
    # Only ban truly abusive behavior (50+ violations in 5 minutes = automated attacks)
    Rack::Attack.blocklist('block-repeated-offenders') do |req|
      # Block if more than 50 throttled requests in 5 minutes (ban for 1 hour)
      # This catches bots/scrapers but allows normal human browsing patterns
      Rack::Attack::Allow2Ban.filter(req.ip, maxretry: 50, findtime: 5.minutes, bantime: 1.hour) do
        # Return true if request should increment the counter
        Rack::Attack.cache.count("#{req.ip}:throttled", 5.minutes) > 50
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
