# frozen_string_literal: true

# The durable state of a pending second-factor challenge (WW-SEC-12): one row
# per account and purpose, the newest challenge's nonce digest and expiry.
# Only PendingSecondFactor reads or writes it, under the account row lock.
class PendingSecondFactorChallenge < AccountRecord
  self.table_name = 'pending_second_factors'

  belongs_to :user
end
