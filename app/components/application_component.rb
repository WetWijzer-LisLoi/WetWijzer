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

  # Helper method to generate CSS classes for components
  # @param classes [String, Array<String>] CSS classes to combine
  # @return [String] Combined and deduplicated CSS classes
  # @example
  #   class_names("btn", "btn-primary") # => "btn btn-primary"
  #   class_names(["btn", "btn-primary"]) # => "btn btn-primary"
  #   class_names("btn", { "btn-active": active? }) # => "btn btn-active" if active? is true
  def class_names(*classes)
    classes.flatten.map { |c| c.to_s.strip }
           .reject(&:empty?)
           .join(' ')
  end

  # Helper method to generate HTML attributes for components
  # @param attrs [Hash] HTML attributes
  # @return [String] HTML attributes as a string
  # @example
  #   html_attributes(class: "btn", data: { action: "click->modal#open" })
  #   # => "class=\"btn\" data-action=\"click->modal#open\""
  def html_attributes(attrs = {})
    attrs.map do |key, value|
      value = value.map { |k, v| "#{k}:#{v.to_s.gsub('"', '&quot;')}" }.join(' ') if value.is_a?(Hash)
      "#{key}=\"#{value}\""
    end.join(' ')
  end
end
