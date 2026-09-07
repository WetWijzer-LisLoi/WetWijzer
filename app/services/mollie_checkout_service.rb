# frozen_string_literal: true

# Creates Mollie-hosted checkout payments from durable local payment intents.
#
# A local MolliePayment is always created before the API call. Its stable
# idempotency key is reused after timeouts, so an ambiguous provider response
# cannot create a second charge. A partial unique database index permits only
# one active first-payment intent per subscription, so double clicks and
# concurrent application processes converge on the same durable contract.
class MollieCheckoutService
  class CheckoutError < StandardError; end

  REUSABLE_STATUSES = %w[created open pending authorized].freeze

  def initialize(user:, locale:, redirect_url:, cancel_url:, client: MollieApiClient.new)
    @user = user
    @locale = locale
    @redirect_url = redirect_url
    @cancel_url = cancel_url
    @client = client
  end

  def create_credit_purchase(purchase)
    ensure_checkout_enabled!
    intent = find_or_create_credit_purchase_intent!(purchase)

    if intent.mollie_payment_id.present?
      existing = @client.get_payment(intent.mollie_payment_id)
      return resume_remote_one_off_intent(intent, existing)
    end

    payment = create_remote_payment(
      intent,
      description: "WetWijzer credits ##{purchase.id}",
      metadata: {
        wetwijzer_payment_id: intent.id.to_s,
        user_id: @user.id.to_s,
        purchase_id: purchase.id.to_s,
        kind: 'credit_purchase'
      }
    )

    persist_remote_payment!(intent, payment)
  rescue MollieApiClient::Error,
         MollieConfiguration::ConfigurationError,
         ActiveRecord::ActiveRecordError => e
    Rails.logger.error("[Mollie Checkout] Credit checkout failed: #{e.class}")
    raise CheckoutError, 'credit checkout could not be created'
  end

  def create_donation(amount_cents:)
    ensure_checkout_enabled!
    amount_cents = normalize_donation_amount!(amount_cents)
    intent = MolliePayment.create!(
      user: @user,
      payment_type: 'donation',
      amount_cents: amount_cents,
      currency: 'EUR',
      sequence_type: 'oneoff',
      invoice_state: 'not_required'
    )

    payment = create_remote_payment(
      intent,
      description: "Voluntary WetWijzer/LisLoi donation ##{intent.id}",
      metadata: {
        wetwijzer_payment_id: intent.id.to_s,
        kind: 'donation'
      }
    )

    persist_remote_payment!(intent, payment)
  rescue MollieApiClient::Error,
         MollieConfiguration::ConfigurationError,
         ActiveRecord::ActiveRecordError => e
    Rails.logger.error("[Mollie Checkout] Donation checkout failed: #{e.class}")
    raise CheckoutError, 'donation checkout could not be created'
  end

  def create_subscription_first_payment(subscription)
    ensure_checkout_enabled!
    ensure_billable_user!
    customer_id = ensure_customer!(subscription)
    intent = find_or_create_subscription_intent!(subscription, customer_id)

    while intent.mollie_payment_id.present?
      existing = @client.get_payment(intent.mollie_payment_id)
      resumed = resume_remote_subscription_intent(intent, existing)
      return resumed if resumed

      # A terminal provider state frees the partial unique slot. A concurrent
      # request may win the replacement insert; RecordNotUnique handling below
      # adopts that winner rather than producing another remote payment.
      intent = find_or_create_subscription_intent!(subscription, customer_id)
    end

    ensure_billable_user!
    payment = create_remote_payment(
      intent,
      customer_id: customer_id,
      sequence_type: 'first',
      description: "WetWijzer Pro ##{subscription.id}",
      metadata: {
        wetwijzer_payment_id: intent.id.to_s,
        wetwijzer_subscription_id: subscription.id.to_s,
        user_id: @user.id.to_s,
        tier: 'pro',
        kind: 'subscription_initial'
      }
    )

    persist_remote_payment!(intent, payment)
  rescue MollieApiClient::Error,
         MollieConfiguration::ConfigurationError,
         ActiveRecord::ActiveRecordError => e
    Rails.logger.error("[Mollie Checkout] Subscription checkout failed: #{e.class}")
    raise CheckoutError, 'subscription checkout could not be created'
  end

  private

  def ensure_checkout_enabled!
    return if MollieConfiguration.checkout_enabled?

    raise MollieConfiguration::ConfigurationError, 'Mollie checkout is disabled'
  end

  def find_or_create_credit_purchase_intent!(purchase)
    with_billable_user_lock do
      unless purchase.user_id == @user.id &&
             purchase.payment_method == 'mollie' &&
             purchase.amount_cents.to_i.positive?
        raise CheckoutError, 'credit purchase contract is invalid'
      end

      existing = MolliePayment.where(
        credit_purchase_id: purchase.id,
        payment_type: 'credit_purchase'
      ).order(:id).first
      if existing
        unless existing.user_id == @user.id &&
               existing.amount_cents == purchase.amount_cents &&
               existing.currency == 'EUR' &&
               existing.sequence_type == 'oneoff'
          raise CheckoutError, 'credit payment intent contract mismatch'
        end

        next existing
      end

      raise CheckoutError, 'credit purchase is no longer pending' unless purchase.reload.pending?

      MolliePayment.create!(
        user: @user,
        credit_purchase: purchase,
        payment_type: 'credit_purchase',
        amount_cents: purchase.amount_cents,
        currency: 'EUR',
        sequence_type: 'oneoff'
      )
    end
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def normalize_donation_amount!(amount_cents)
    amount_cents = Integer(amount_cents)
    return amount_cents if MolliePayment::DONATION_AMOUNTS_CENTS.include?(amount_cents)

    raise CheckoutError, 'donation amount is not offered'
  rescue ArgumentError, TypeError
    raise CheckoutError, 'donation amount is invalid'
  end

  def find_or_create_subscription_intent!(subscription, customer_id)
    with_billable_user_lock do
      subscription.reload
      reusable_subscription_intent(subscription) || create_subscription_intent!(subscription, customer_id)
    end
  rescue ActiveRecord::RecordNotUnique
    reusable_subscription_intent(subscription) || raise
  end

  def reusable_subscription_intent(subscription)
    base = MolliePayment.where(
      subscription_id: subscription.id,
      payment_type: 'subscription_initial'
    )
    base.where(status: REUSABLE_STATUSES)
        .or(base.where(status: 'paid', fulfilled_at: nil))
        .order(created_at: :desc)
        .first
        .tap do |intent|
      next unless intent

      unless intent.user_id == @user.id && intent.mollie_customer_id == subscription.mollie_customer_id
        raise CheckoutError, 'subscription payment intent ownership mismatch'
      end
    end
  end

  def create_subscription_intent!(subscription, customer_id)
    MolliePayment.create!(
      user: @user,
      subscription: subscription,
      payment_type: 'subscription_initial',
      amount_cents: Subscription::TIER_CONFIG.fetch('pro').fetch(:price_monthly),
      currency: 'EUR',
      mollie_customer_id: customer_id,
      sequence_type: 'first'
    )
  end

  def resume_remote_subscription_intent(intent, existing)
    case existing['status'].to_s
    when 'open', 'pending'
      update_checkout_status!(intent, existing['status'])
      return local_return_result(intent) if locally_paid_or_fulfilled?(intent)

      checkout_result(intent, existing)
    when 'authorized'
      update_checkout_status!(intent, 'authorized')
      local_return_result(intent)
    when 'paid'
      MolliePaymentProcessor.new(existing).process!
      local_return_result(intent)
    when *MolliePayment::TERMINAL_STATUSES
      update_checkout_status!(intent, existing['status'])
      locally_paid_or_fulfilled?(intent) ? local_return_result(intent) : nil
    else
      raise CheckoutError, 'unknown Mollie payment status'
    end
  end

  def resume_remote_one_off_intent(intent, existing)
    case existing['status'].to_s
    when 'open', 'pending'
      update_checkout_status!(intent, existing['status'])
      return local_return_result(intent) if locally_paid_or_fulfilled?(intent)

      checkout_result(intent, existing)
    when 'authorized'
      update_checkout_status!(intent, 'authorized')
      local_return_result(intent)
    when 'paid'
      MolliePaymentProcessor.new(existing).process!
      local_return_result(intent)
    when *MolliePayment::TERMINAL_STATUSES
      update_checkout_status!(intent, existing['status'])
      return local_return_result(intent) if locally_paid_or_fulfilled?(intent)

      raise CheckoutError, 'credit payment is no longer payable'
    else
      raise CheckoutError, 'unknown Mollie payment status'
    end
  end

  def ensure_customer!(subscription)
    return subscription.mollie_customer_id if subscription.mollie_customer_id.present?

    idempotency_key = atomic_subscription_key!(
      subscription,
      :mollie_customer_idempotency_key
    )

    customer = @client.create_customer(
      name: mollie_customer_name,
      email: @user.email,
      locale: MollieConfiguration.locale_for(@locale),
      metadata: {
        wetwijzer_user_id: @user.id.to_s,
        wetwijzer_subscription_id: subscription.id.to_s
      },
      idempotency_key: idempotency_key
    )
    customer_id = customer.fetch('id')
    raise CheckoutError, 'invalid Mollie customer response' unless customer_id.match?(/\Acst_[A-Za-z0-9]+\z/)

    # A stable idempotency key makes concurrent/retried calls return the same
    # customer. The guarded update avoids overwriting an already-adopted id.
    Subscription.where(id: subscription.id, mollie_customer_id: [nil, ''])
                .update_all(mollie_customer_id: customer_id, updated_at: Time.current)
    subscription.reload.mollie_customer_id || customer_id
  end

  def atomic_subscription_key!(subscription, attribute)
    current = subscription.public_send(attribute).presence
    return current if current

    candidate = SecureRandom.uuid
    Subscription.where(id: subscription.id, attribute => [nil, '']).update_all(
      attribute => candidate,
      updated_at: Time.current
    )
    subscription.reload.public_send(attribute).presence ||
      raise(CheckoutError, 'subscription is no longer available')
  end

  def create_remote_payment(intent, description:, metadata:, customer_id: nil, sequence_type: 'oneoff')
    @client.create_payment(
      amount_cents: intent.amount_cents,
      currency: intent.currency,
      description: description,
      redirect_url: append_checkout_token(@redirect_url, intent.checkout_token),
      cancel_url: @cancel_url,
      webhook_url: MollieConfiguration.webhook_url,
      metadata: metadata,
      sequence_type: sequence_type,
      customer_id: customer_id,
      idempotency_key: intent.idempotency_key
    )
  end

  def persist_remote_payment!(intent, payment)
    remote_id = payment.fetch('id').to_s
    status = payment.fetch('status').to_s
    raise CheckoutError, 'invalid Mollie payment response' unless remote_id.match?(MolliePaymentProcessor::PAYMENT_ID)
    raise CheckoutError, 'invalid Mollie payment response' unless MolliePaymentProcessor::KNOWN_STATUSES.include?(status)

    # A very fast webhook may already have adopted and fulfilled this intent.
    # Persist under a short database lock and never let the older create
    # response regress a paid/fulfilled state.
    intent.with_lock do
      intent.reload
      if intent.mollie_payment_id.present? && intent.mollie_payment_id != remote_id
        raise CheckoutError, 'local payment intent is already bound to another provider payment'
      end

      attributes = {
        mollie_payment_id: remote_id,
        mollie_customer_id: payment['customerId'].presence || intent.mollie_customer_id,
        mollie_subscription_id: payment['subscriptionId'].presence || intent.mollie_subscription_id
      }
      unless intent.fulfilled_at? || intent.status == 'paid' ||
             MolliePayment::TERMINAL_STATUSES.include?(intent.status)
        attributes[:status] = status
      end
      intent.update!(attributes)
    end

    checkout_result(intent.reload, payment)
  rescue KeyError
    raise CheckoutError, 'incomplete Mollie payment response'
  end

  def ensure_billable_user!
    with_billable_user_lock { true }
  end

  def update_checkout_status!(intent, status)
    intent.with_lock do
      intent.reload
      next if locally_paid_or_fulfilled?(intent) ||
              MolliePayment::TERMINAL_STATUSES.include?(intent.status)

      intent.update!(status: status)
    end
  end

  def locally_paid_or_fulfilled?(intent)
    intent.reload
    intent.status == 'paid' || intent.fulfilled_at?
  end

  def local_return_result(intent)
    intent.reload
    {
      payment: intent,
      checkout_url: append_checkout_token(@redirect_url, intent.checkout_token)
    }
  end

  def with_billable_user_lock
    raise CheckoutError, 'authenticated user is required' unless @user

    @user.with_lock do
      # SELECT ... FOR UPDATE is a no-op on SQLite. A harmless write obtains
      # the database write lock so account fencing and intent creation cannot
      # both commit from stale reads.
      updated = User.where(id: @user.id).update_all(updated_at: Time.current)
      raise CheckoutError, 'account is no longer available' unless updated == 1

      @user.reload
      raise CheckoutError, 'account is not eligible for a new payment' unless
        @user.active? && @user.deletion_scheduled_for.nil?

      yield
    end
  end

  def checkout_result(intent, payment)
    {
      payment: intent,
      checkout_url: @client.checkout_url(payment)
    }
  end

  def append_checkout_token(url, token)
    uri = URI.parse(url)
    query = URI.decode_www_form(uri.query.to_s)
    query.reject! { |key, _value| key == 'payment_token' }
    query << ['payment_token', token]
    uri.query = URI.encode_www_form(query)
    uri.to_s
  end

  def mollie_customer_name
    (@user.name.presence || @user.email)
      .to_s
      .gsub(/[\u0000-\u001F\u007F]/, ' ')
      .squish
      .truncate(255)
  end
end
