# frozen_string_literal: true

# D12 follow-up (Codex inbox 2026-10-07 18:15 CEST): Rails' own request line,
# 'Started GET "/" for <address> at <time>', was the one line that still
# wrote a full client address into log/production.log, which rotates by size
# only. It now carries the network, in the format SecurityLog owns for every
# log line (IPv4 /24, IPv6 /48). Retention::LogAddressRedaction masks what
# older lines left.
class RequestLogLine < Rails::Rack::Logger
  private

  def started_request_message(request)
    format('Started %<method>s "%<path>s" for %<network>s at %<time>s',
           method: request.raw_request_method, path: request.filtered_path,
           network: SecurityLog.network(request.remote_ip), time: Time.now)
  end
end

Rails.application.config.middleware.swap Rails::Rack::Logger, RequestLogLine, Rails.application.config.log_tags
