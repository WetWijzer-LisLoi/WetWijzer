# frozen_string_literal: true

# Rebuilds the eventually consistent analytics projection from the settled
# accounts ledger. Both the analytics token and accounts projected marker make
# retries safe across crashes between the two databases.
class BillingAnalyticsReconciliationJob < ApplicationJob
  queue_as :default

  def perform(reservation_id = nil)
    if reservation_id
      reservation = BillingReservation.find_by(id: reservation_id)
      return unless reservation
      return unless reservation.settled? && reservation.credit?
      return unless reservation.app.to_s.start_with?(BillingReservation::BROWSER_APP_PREFIX)

      reservation.project_analytics!
    else
      BillingReservation.reconcile_settled_browser_analytics!
    end
  end
end
