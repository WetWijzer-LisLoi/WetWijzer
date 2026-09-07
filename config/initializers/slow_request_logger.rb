# frozen_string_literal: true

# == Slow Request Logger
#
# Subscribes to Rails' process_action notification to log all request timings.
# Any request exceeding SLOW_REQUEST_THRESHOLD_MS is logged as a warning with
# full details (URL, controller, action, duration, DB time, view time, status).
#
# All requests are logged at DEBUG level; slow requests are logged at WARN level.
#
# Threshold can be configured via the WW_SLOW_REQUEST_MS environment variable.
# Default: 1000ms (1 second).
#
# Log output goes to a dedicated log file: log/performance.log
#
ActiveSupport::Notifications.subscribe('process_action.action_controller') do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  payload = event.payload

  # Skip asset/health requests
  next if payload[:controller] == 'Rails::HealthController'
  next if payload[:path]&.start_with?('/assets/', '/packs/')

  duration_ms = event.duration.round(1)
  db_ms       = (payload[:db_runtime] || 0).round(1)
  view_ms     = (payload[:view_runtime] || 0).round(1)
  status      = payload[:status] || (payload[:exception] ? 500 : nil)
  method      = payload[:method]
  path        = payload[:path]
  controller  = payload[:controller]
  action      = payload[:action]
  format      = payload[:format]

  # Extract useful request params for diagnostics
  req_params  = payload[:params] || {}
  numac       = req_params['numac']
  lang_id     = req_params['language_id']
  page        = req_params['page']
  param_str   = [numac && "numac=#{numac}", lang_id && "lang=#{lang_id}", page && "page=#{page}"].compact.join(' ')
  param_str   = " (#{param_str})" if param_str.present?

  threshold = ENV.fetch('WW_SLOW_REQUEST_MS', '1000').to_i

  log_line = format(
    '%<method>s %<path>s -> %<controller>s#%<action>s [%<status>s] ' \
    '| Total: %<duration>sms | DB: %<db>sms | View: %<view>sms | Format: %<fmt>s%<params>s',
    method: method, path: path, controller: controller, action: action,
    status: status, duration: duration_ms, db: db_ms, view: view_ms, fmt: format,
    params: param_str
  )

  # Use a dedicated performance logger to avoid cluttering the main log
  perf_logger = SlowRequestLogger.instance

  if duration_ms >= threshold
    perf_logger.warn("[SLOW] #{log_line}")
    Rails.logger.warn("[SLOW REQUEST] #{log_line}")
  else
    perf_logger.debug(log_line)
  end
end

# Dedicated performance logger singleton
class SlowRequestLogger
  include Singleton

  def initialize
    log_path = Rails.root.join('log', 'performance.log')
    @logger = ActiveSupport::Logger.new(log_path, 5, 10.megabytes)
    @logger.formatter = proc do |severity, datetime, _progname, msg|
      "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity} #{msg}\n"
    end
  end

  def warn(msg)
    @logger.warn(msg)
  end

  def debug(msg)
    @logger.debug(msg)
  end

  def info(msg)
    @logger.info(msg)
  end
end
