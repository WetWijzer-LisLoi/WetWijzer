# frozen_string_literal: true

# == Errors Controller
#
# Handles custom error pages for the application. This controller is responsible
# for rendering user-friendly error pages when exceptions occur.
#
# @see https://guides.rubyonrails.org/layouts_and_rendering.html#the-status-option
# @see ApplicationController
class ErrorsController < ApplicationController
  # Renders the 404 Not Found error page
  #
  # This action is typically triggered when a user attempts to access a route
  # that doesn't exist or when a record cannot be found.
  #
  # @example
  #   # Visiting a non-existent route like '/non-existent-route' will trigger this action
  #   # and render the 'errors/not_found' view with a 404 status code
  #
  # @return [void]
  # @note The view template should be located at 'app/views/errors/not_found.html.erb'
  def not_found
    @page_title = t('errors.not_found.title', default: 'Page Not Found')
    respond_to do |format|
      format.html { render status: :not_found }
      format.any { head :not_found }
    end
  end

  # Renders the 500 Internal Server Error page
  #
  # This action is triggered when an unexpected error occurs in the application.
  # It's the default 500 error handler.
  #
  # @example
  #   # When an unhandled exception occurs, this action will be triggered
  #   # and render the 'errors/internal_server_error' view with a 500 status code
  #
  # @return [void]
  # @note The view template should be located at 'app/views/errors/internal_server_error.html.erb'
  def internal_server_error
    @page_title = t('errors.internal_server_error.title', default: 'Internal Server Error')
    render status: :internal_server_error
  end

  # Renders the 422 Unprocessable Entity page
  #
  # This action is triggered when a request is well-formed but semantically
  # incorrect, such as when form validation fails.
  #
  # @example
  #   # When submitting a form with invalid data that fails model validations
  #   # this action will be triggered and render the 'errors/unprocessable_entity' view
  #   # with a 422 status code
  #
  # @return [void]
  # @note The view template should be located at 'app/views/errors/unprocessable_entity.html.erb'
  def unprocessable_entity
    @page_title = t('errors.unprocessable_entity.title', default: 'Unprocessable Entity')
    render status: :unprocessable_entity
  end

  # Renders the 403 Forbidden page (commented out but available for future use)
  #
  # Uncomment and implement this method when you need to handle 403 errors
  # def forbidden
  #   @page_title = t('errors.forbidden.title', default: 'Access Denied')
  #   render status: :forbidden
  # end

  # Renders the 401 Unauthorized page (commented out but available for future use)
  #
  # Uncomment and implement this method when you need to handle 401 errors
  # def unauthorized
  #   @page_title = t('errors.unauthorized.title', default: 'Unauthorized')
  #   render status: :unauthorized
  # end
end
