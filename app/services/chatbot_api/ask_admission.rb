# frozen_string_literal: true

module ChatbotApi
  # Process-wide admission control for provider-calling asks (FBL-065).
  # Every browser ask must hold a slot for its full provider lifetime; when
  # the cap is saturated the request is refused up front - BEFORE any credit
  # reservation - with a retryable busy signal, instead of piling unbounded
  # worker threads onto one Puma process. The cap is read per acquisition so
  # tests and operators can tune it without a restart; 0 refuses everything
  # (maintenance drain), a negative or absent value falls back to the
  # default.
  module AskAdmission
    DEFAULT_MAX_CONCURRENT_ASKS = 8

    @lock = Mutex.new
    @active = 0

    class << self
      def capacity
        raw = ENV['CHATBOT_MAX_CONCURRENT_ASKS']
        return DEFAULT_MAX_CONCURRENT_ASKS if raw.nil? || raw.strip.empty?

        value = Integer(raw, exception: false)
        value && value >= 0 ? value : DEFAULT_MAX_CONCURRENT_ASKS
      end

      # true = admitted (caller MUST release in an ensure); false = saturated.
      def try_acquire
        @lock.synchronize do
          return false if @active >= capacity

          @active += 1
          true
        end
      end

      def release
        @lock.synchronize { @active = [@active - 1, 0].max }
      end

      def active
        @lock.synchronize { @active }
      end

      # Test hook: never use outside tests.
      def reset!
        @lock.synchronize { @active = 0 }
      end
    end
  end
end
