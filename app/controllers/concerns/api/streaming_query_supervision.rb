# frozen_string_literal: true

module Api
  # The streaming query supervisor: a hard, clamped wall-clock deadline on
  # provider work with worker-thread termination. The supervisor must win
  # before the browser/proxy gives up so the terminal timeout event and the
  # credit refund can still be delivered. Extracted verbatim from
  # Api::ChatbotController (FBL-060 step 6); names and receiver unchanged
  # because the white-box supervisor tests drive these methods directly, and
  # the constants stay resolvable as Api::ChatbotController::* through
  # ancestry.
  module StreamingQuerySupervision
    extend ActiveSupport::Concern

    STREAMING_QUERY_TIMEOUT_DEFAULT_SECONDS = 175.0
    STREAMING_QUERY_TIMEOUT_MIN_SECONDS = 30.0
    STREAMING_QUERY_TIMEOUT_MAX_SECONDS = 175.0
    STREAMING_QUERY_TIMEOUT_HEADER = 'X-Chatbot-Stream-Hard-Timeout-Seconds'

    private

    # The outer supervisor must win before the browser/proxy gives up. Ruby's
    # asynchronous Timeout inside a worker thread is not a reliable boundary
    # for every blocking provider socket operation.
    def streaming_query_timeout_seconds
      configured = Float(
        ENV.fetch('CHATBOT_STREAM_HARD_TIMEOUT_SECONDS', STREAMING_QUERY_TIMEOUT_DEFAULT_SECONDS.to_s),
        exception: false
      )

      return STREAMING_QUERY_TIMEOUT_DEFAULT_SECONDS unless configured&.finite?

      configured.clamp(STREAMING_QUERY_TIMEOUT_MIN_SECONDS, STREAMING_QUERY_TIMEOUT_MAX_SECONDS)
    end

    def wait_for_streaming_query(thread, timeout_seconds: streaming_query_timeout_seconds)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      loop do
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        remaining = timeout_seconds.to_f - elapsed
        return false if remaining <= 0
        return true if thread.join([10.0, remaining].min)

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        return false if elapsed >= timeout_seconds.to_f

        yield elapsed.round if block_given?
      end
    end

    def terminate_chatbot_query_thread(thread)
      return unless thread

      thread.kill if thread.alive?
      thread.join(1)
    rescue StandardError => e
      Rails.logger.warn("Could not terminate chatbot query thread: #{e.class}")
    end
  end
end
