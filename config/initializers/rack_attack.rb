# frozen_string_literal: true

# Configure Rack::Attack for rate limiting and request protection
# Documentation: https://github.com/rack/rack-attack

module Rack
  class Attack
    # Always allow requests from localhost (for health checks, monitoring)
    Rack::Attack.safelist('allow-localhost') do |req|
      %w[127.0.0.1 ::1].include?(req.ip)
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

    # Exponential backoff for repeated offenders
    # Only ban truly abusive behavior (50+ violations in 5 minutes = automated attacks)
    Rack::Attack.blocklist('block-repeated-offenders') do |req|
      # Block if more than 50 throttled requests in 5 minutes (ban for 15 minutes)
      # This catches bots/scrapers but allows normal human browsing patterns
      Rack::Attack::Allow2Ban.filter(req.ip, maxretry: 50, findtime: 5.minutes, bantime: 15.minutes) do
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
    self.blocklisted_responder = lambda do |_request|
      [403, { 'Content-Type' => 'text/html; charset=utf-8' }, [<<~HTML
        <!DOCTYPE html>
        <html lang="nl">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>Tijdelijk Geblokkeerd - WetWijzer</title>
          <style>
            body { 
              font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
              max-width: 600px; margin: 80px auto; padding: 30px;
              background: #f5f5f5; color: #333;
            }
            .container { background: white; padding: 40px; border-radius: 12px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
            h1 { color: #d32f2f; margin-top: 0; font-size: 24px; }
            p { line-height: 1.6; color: #555; }
            .info { background: #fff3cd; border-left: 4px solid #ffc107; padding: 15px; margin: 20px 0; }
            .success { background: #d4edda; border-left: 4px solid #28a745; padding: 15px; margin: 20px 0; }
            strong { color: #333; }
            code { background: #f5f5f5; padding: 2px 6px; border-radius: 3px; font-family: monospace; }
          </style>
        </head>
        <body>
          <div class="container">
            <h1>⚠️ Tijdelijk Geblokkeerd</h1>
            <p>Uw IP-adres is tijdelijk geblokkeerd vanwege ongebruikelijke activiteit.</p>
            
            <div class="info">
              <strong>Waarom gebeurde dit?</strong><br>
              U heeft de limiet voor aanvragen meerdere keren overschreden in een korte periode.
              Dit mechanisme beschermt de website tegen automatische bots en scraping.
            </div>
            
            <div class="success">
              <strong>Wat kunt u doen?</strong><br>
              De blokkering wordt <strong>automatisch opgeheven na 15 minuten</strong>.<br>
              U hoeft niets te doen, wacht gewoon even en probeer het opnieuw.
            </div>
            
            <p style="font-size: 14px; color: #888; margin-top: 30px;">
              Als u meent dat dit een fout is of regelmatig problemen ondervindt,<br>
              neem dan contact op via de website.
            </p>
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
