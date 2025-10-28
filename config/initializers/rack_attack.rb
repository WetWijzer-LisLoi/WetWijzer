# frozen_string_literal: true

# Configure Rack::Attack for rate limiting and request protection
# Documentation: https://github.com/rack/rack-attack

module Rack
  class Attack
    # Always allow requests from localhost (for health checks, monitoring)
    Rack::Attack.safelist('allow-localhost') do |req|
      %w[127.0.0.1 ::1].include?(req.ip)
    end

    # Allow developer/owner IP
    Rack::Attack.safelist('allow-owner') do |req|
      req.ip == '213.219.148.179'
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

    # Exponential backoff for repeated offenders
    Rack::Attack.blocklist('block-repeated-offenders') do |req|
      # Block if more than 5 throttled requests in 10 minutes
      Rack::Attack::Allow2Ban.filter(req.ip, maxretry: 5, findtime: 10.minutes, bantime: 1.hour) do
        # Return true if request should increment the counter
        Rack::Attack.cache.count("#{req.ip}:throttled", 10.minutes) > 5
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
