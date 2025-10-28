# frozen_string_literal: true

# Additional security headers beyond CSP
Rails.application.config.action_dispatch.default_headers.merge!(
  # Prevent clickjacking
  'X-Frame-Options' => 'DENY',
  
  # Prevent MIME type sniffing
  'X-Content-Type-Options' => 'nosniff',
  
  # Enable XSS filter (legacy browsers)
  'X-XSS-Protection' => '1; mode=block',
  
  # Referrer policy - don't leak URLs to external sites
  'Referrer-Policy' => 'strict-origin-when-cross-origin',
  
  # Permissions policy - disable unnecessary browser features
  'Permissions-Policy' => 'camera=(), microphone=(), geolocation=(), payment=()'
)

# HSTS - force HTTPS in production (2 years, include subdomains)
if Rails.env.production?
  Rails.application.config.action_dispatch.default_headers['Strict-Transport-Security'] = 
    'max-age=63072000; includeSubDomains; preload'
end
