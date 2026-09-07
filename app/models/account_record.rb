# frozen_string_literal: true

# Base class for all account-related models.
# These models are stored in a separate 'accounts' database
# to keep user/auth data isolated from the large legislation database.
class AccountRecord < ActiveRecord::Base
  self.abstract_class = true

  connects_to database: { writing: :accounts, reading: :accounts }
end
