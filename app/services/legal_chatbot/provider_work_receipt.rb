# frozen_string_literal: true

module LegalChatbot
  # One browser question's paid-AI dispatch evidence (owner policy
  # 2026-10-18: "charge once the provider request was sent"). The controller
  # creates one receipt per ask and hands it explicitly to every client that
  # can send a paid request (answer generation, HyDE, question embedding and
  # both German translations). Each send site calls #before_provider_dispatch!
  # after its own local preflight and connection opening and immediately
  # before writing the request.
  #
  # The first dispatch is admitted by BillingReservation#admit_work_dispatch!
  # under the account's row lock, which also decides the request's real
  # eligibility (account still active, conversation claim still owned) and
  # records the work durably BEFORE the request is written. Any uncertainty
  # there fails closed: no request is sent, and no later attempt of this
  # question may send either. Every dispatch re-checks cancellation. The
  # durable marker precedes the socket write, so a crash between the two
  # charges a question whose packets may never have left the server; that is
  # the owner's chosen conservative side, and it is not proof that the
  # provider accepted or invoiced the request.
  class ProviderWorkReceipt
    # Raised instead of sending: nothing was written to the provider.
    class PreDispatchRefused < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason.to_s
        super("provider request not sent: #{@reason}")
      end
    end

    KINDS = %w[question_embedding hyde generation question_translation answer_translation].freeze

    attr_reader :reservation, :dispatch_count, :first_kind

    # reservation: the browser BillingReservation (nil for unbilled service
    # requests, which are tracked in memory only).
    # eligibility: callable taking the locked account and returning true while
    # the request may still start paid work; asked once, inside the admission.
    def initialize(reservation:, eligibility: nil)
      @reservation = reservation
      @eligibility = eligibility
      @mutex = Mutex.new
      @dispatched = false
      @dispatch_count = 0
      @first_kind = nil
      @cancelled = false
      @refusal = nil
    end

    def before_provider_dispatch!(kind)
      kind = kind.to_s
      raise ArgumentError, "unknown provider work kind: #{kind}" unless KINDS.include?(kind)

      # Deferred, not ignored: a kill or Timeout that arrives while the marker
      # is being recorded is seen by the admission (Thread.pending_interrupt?),
      # which then records nothing, and it fires as soon as this block ends,
      # before any request is written.
      Thread.handle_interrupt(Object => :never) do
        @mutex.synchronize do
          raise PreDispatchRefused, @refusal if @refusal

          refuse!('cancelled') if cancelled?

          unless @dispatched
            refuse!('work_marker_unavailable') unless admit(kind)
            @first_kind = kind
            @dispatched = true
          end
          @dispatch_count += 1
        end
      end
      true
    end

    # Called by the controller's supervisor or outer rescue, from another
    # thread: never blocks, so the supervisor's bounded termination stays
    # bounded. A later dispatch attempt in a still-running thread is refused;
    # work already sent stands.
    def cancel!
      @cancelled = true
    end

    def cancelled?
      @cancelled || Thread.current[:chatbot_cancelled] == true
    end

    # Non-blocking as well: the request thread reads it while the query
    # thread may be inside an admission.
    def dispatched?
      @dispatched
    end

    private

    def refuse!(reason)
      @refusal = reason
      raise PreDispatchRefused, reason
    end

    # True when this question's first paid request may be written. Without a
    # reservation (service traffic) only cancellation is checked. Any failure
    # of the admission (storage, lock wait limit, the eligibility check) is a
    # refusal, never an untracked request. Cancellation is read again after
    # the eligibility check, which may have waited, and once more by the
    # admission at its commit boundary: a cancel! that lands anywhere before
    # the marker commits records nothing.
    # The accounts and chatbot connections the admission needs are leased
    # first, with a bounded and cancellable wait, and released right after
    # it: a provider call takes up to minutes, and a query thread must not
    # hold a lane connection for it, nor wait a pool's full checkout timeout
    # inside a deferred-interrupt region.
    def admit(kind)
      return !cancelled? unless @reservation

      outcome = ConversationStorageBoundary.with_bounded_lane_connections(cancelled: -> { cancelled? }) do
        @reservation.admit_work_dispatch!(kind: kind, abandoned: -> { cancelled? }) do |account|
          next false if cancelled?
          next false unless @eligibility.nil? || @eligibility.call(account) == true

          !cancelled?
        end
      end
      outcome == :admitted
    rescue StandardError => e
      Rails.logger.error("[ProviderWork] dispatch admission failed: #{e.class}")
      false
    end
  end
end
