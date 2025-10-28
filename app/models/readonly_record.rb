# frozen_string_literal: true

# Base class for read-only models (legislation data managed by scrapers)
# These models should never be modified through the Rails app
class ReadonlyRecord < ApplicationRecord
  self.abstract_class = true

  def readonly?
    true
  end
end
