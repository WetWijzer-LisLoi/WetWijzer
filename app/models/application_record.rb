# frozen_string_literal: true

# == Schema Information
#
# This is an abstract base class for all application models.
# It provides common functionality and configuration that's shared across all models.
#
# @abstract
# @see https://guides.rubyonrails.org/active_record_basics.html#overriding-the-naming-conventions
class ApplicationRecord < ActiveRecord::Base
  # Indicates that this is an abstract class and should not be instantiated directly
  self.abstract_class = true

  # Makes all models read-only by default as a security measure
  # @return [Boolean] Always returns true to enforce read-only behavior
  # @note This can be overridden in individual models if write operations are needed
  # @example
  #   record = MyModel.first
  #   record.readonly? #=> true
  #   record.update(name: 'New Name') #=> Raises ActiveRecord::ReadOnlyRecord
  def readonly?
    true
  end

  # Uncomment and configure for database sharding if needed
  # connects_to database: { reading: :primary, writing: :primary }
  #
  # @note This is a placeholder for database sharding configuration
  # @see https://guides.rubyonrails.org/active_record_multiple_databases.html
  # connnects_to database: { reading: :primary }
end
