# frozen_string_literal: true

# Updates every locally-current Mollie subscription to the current callback
# URL before an old webhook token is removed. The URL itself is never logged or
# returned because it contains the callback credential.
class MollieWebhookRotationService
  class RotationError < StandardError; end

  Result = Data.define(:eligible, :updated, :failures) do
    def complete?
      failures.empty? && updated == eligible
    end
  end

  DEFAULT_LIMIT = 1_000

  def initialize(client: MollieApiClient.new, webhook_url: MollieConfiguration.webhook_url,
                 limit: DEFAULT_LIMIT)
    @client = client
    @webhook_url = webhook_url
    @limit = Integer(limit)
  end

  def call(dry_run: false)
    scope = Subscription.where(payment_method: 'mollie')
                        .where.not(status: 'canceled')
                        .where.not(mollie_customer_id: [nil, ''])
                        .where.not(mollie_subscription_id: [nil, ''])
                        .order(:id)
    eligible = scope.count
    if eligible > @limit
      raise RotationError, "webhook rotation has #{eligible} subscriptions; limit is #{@limit}"
    end
    return Result.new(eligible:, updated: 0, failures: []) if dry_run

    updated = 0
    failures = []
    scope.find_each(batch_size: 100) do |subscription|
      response = @client.update_subscription_webhook(
        customer_id: subscription.mollie_customer_id,
        subscription_id: subscription.mollie_subscription_id,
        webhook_url: @webhook_url
      )
      unless response['id'] == subscription.mollie_subscription_id &&
             response['webhookUrl'] == @webhook_url
        raise MollieApiClient::InvalidResponseError,
              'Mollie did not confirm the subscription webhook update'
      end

      updated += 1
    rescue MollieApiClient::Error => e
      failures << { subscription_id: subscription.id, error: e.class.name }
    end

    Result.new(eligible:, updated:, failures:)
  end
end
