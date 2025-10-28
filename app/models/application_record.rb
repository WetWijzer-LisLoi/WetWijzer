# frozen_string_literal: true

# == Schema Information
#
# This is an abstract base class for all application models.
# It provides common functionality and configuration that's shared across all models.
#
# @abstract
# @see https://guides.rubyonrails.org/active_record_basics.html#overriding-the-naming-conventions
class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end
