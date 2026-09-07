# frozen_string_literal: true

# Configuration for law page optimization
#
# These settings control when article-exdec mapping is disabled
# to improve performance for laws with many executive decisions.

module LawOptimization
  # Threshold for disabling article-exdec mapping
  # Laws with more than this many exdecs will have the mapping disabled by default
  # Users can still opt-in to load references via URL parameter
  #
  # Threshold for number of executive decisions before disabling article-exdec mapping
  # Raised to 2000 after SQL optimization (was 500)
  # With SQL pre-filtering, we can handle much larger laws efficiently
  # Can be overridden via environment variable: LAW_EXDEC_THRESHOLD=3000
  EXDEC_THRESHOLD = ENV.fetch('LAW_EXDEC_THRESHOLD', 2000).to_i

  # Estimated processing time per exdec (in seconds)
  # Used to calculate estimated load time for progress bar
  SECONDS_PER_EXDEC = 0.02 # 50 exdecs per second

  # Maximum estimated time to show in UI (in seconds)
  # Longer estimates are capped to avoid scary numbers
  MAX_ESTIMATED_SECONDS = 120

  def self.exdec_threshold
    EXDEC_THRESHOLD
  end

  def self.estimate_load_time(exdec_count)
    estimated = (exdec_count * SECONDS_PER_EXDEC).round
    [estimated, MAX_ESTIMATED_SECONDS].min
  end

  def self.format_load_time(seconds)
    if seconds > 60
      minutes = (seconds / 60.0).round
      "#{minutes} min"
    else
      "#{seconds}s"
    end
  end

  def self.should_disable_mapping?(exdec_count, force_load: false)
    return false if force_load

    exdec_count > exdec_threshold
  end
end

# Log configuration on startup
Rails.logger.info "Law Optimization: Exdec threshold set to #{LawOptimization.exdec_threshold}"
