# frozen_string_literal: true

# Base class for all jurisprudence models
# Connects to separate jurisprudence database
class JurisprudenceRecord < ApplicationRecord
  self.abstract_class = true
  connects_to database: { writing: :jurisprudence, reading: :jurisprudence }

  def readonly?
    true
  end
end
