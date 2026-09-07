# frozen_string_literal: true

# The Sortable concern provides a standardized way to sort ActiveRecord models
# based on URL parameters. It's designed to work with the `sort_link_to` helper
# in the application's views.
#
# @example Including the concern in a model
#   class Article < ApplicationRecord
#     include Sortable
#
#     # Define a custom sort scope
#     scope :order_by_title, ->(direction = :asc) { order(title: direction) }
#   end
#
# @example Using in a controller
#   def index
#     @articles = Article.apply_sort(params)
#   end
#
# @example Generating sort links in a view
#   <%= sort_link_to 'Title', :title %>
#   <%= sort_link_to 'Date', :created_at %>
#
# @note The sort direction toggles between :asc and :desc when clicking the same column
# @see ApplicationHelper#sort_link_to
module Sortable
  extend ActiveSupport::Concern

  # Class methods that will be added to the including class
  included do
    # Applies sorting based on the provided parameters
    # @param params [ActionController::Parameters, Hash] The request parameters containing sort info
    # @option params [String] :sort The field to sort by, optionally prefixed with '-' for descending
    # @return [ActiveRecord::Relation] The sorted relation
    #
    # @example Basic usage
    #   Article.apply_sort(sort: 'title')      # Sorts by title ascending
    #   Article.apply_sort(sort: '-created_at') # Sorts by created_at descending
    #
    # @example With custom sort scope
    #   # In the model:
    #   scope :order_by_author_name, ->(direction = :asc) {
    #     joins(:author).order("authors.name #{direction}")
    #   }
    #
    #   # In the controller:
    #   @articles = Article.apply_sort(sort: 'author_name')
    def self.apply_sort(params)
      # Extract the sort parameter and handle nil case
      sort = params[:sort].to_s
      return all if sort.blank?

      # Default to ascending order unless the field is prefixed with '-'
      direction = :asc
      if sort.start_with?('-')
        sort = sort[1..]
        direction = :desc
      end

      # Build the scope name (e.g., 'order_by_title' for 'title' sort field)
      scope = "order_by_#{sanitize_sql_like(sort)}"

      # Use the scope if it's defined, otherwise return the default scope
      return send(scope, direction) if respond_to?(scope, true)

      # Fallback to default scope if the requested sort scope doesn't exist
      all
    end
  end
end
