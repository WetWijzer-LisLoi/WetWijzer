# frozen_string_literal: true

# == ApplicationComponent
#
# Base class for all view components in the application. This class inherits from
# ViewComponent::Base and provides common functionality shared across all components.
#
# View components are reusable, testable, and encapsulated units that render a
# part of the UI. They are an alternative to partials with additional benefits
# like type checking, testability, and encapsulation.
#
# @see https://viewcomponent.org/ ViewComponent documentation
# @abstract Subclass to create a new view component
#
# @example Basic component
#   # app/components/alert_component.rb
#   class AlertComponent < ApplicationComponent
#     def initialize(type: :info)
#       @type = type
#     end
#   end
#
#   # app/components/alert_component.html.erb
#   <div class="alert alert-<%= @type %>">
#     <%= content %>
#   </div>
#
#   # In a view
#   <%= render(AlertComponent.new(type: :success)) do %>
#     Your action was completed successfully!
#   <% end %>
class ApplicationComponent < ViewComponent::Base
  # Include application-wide helpers for use in components
  include ApplicationHelper

  # Include route helpers for generating URLs
  include Rails.application.routes.url_helpers

  # Set the default host for URL generation in components
  # @return [String] The default host for URL generation
  def default_url_options
    Rails.application.config.action_mailer.default_url_options || {}
  end
end
