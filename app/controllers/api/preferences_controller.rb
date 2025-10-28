# frozen_string_literal: true

module Api
  # Server-side UI preferences storage.
  # Replaces ALL localStorage/sessionStorage usage.
  # Anonymous users: in-memory only (nothing persists).
  # Logged-in users: preferences saved here.
  #
  # GDPR: Art. 6(1)(b) — necessary for service delivery (remembering UI settings).
  # No sensitive PII stored. Data deleted when user account is deleted.
  class PreferencesController < ApplicationController
    skip_forgery_protection
    before_action :require_user

    # GET /api/preferences
    # Returns all stored UI preferences as JSON
    def show
      render json: {
        preferences: current_user.ui_prefs,
        consent: current_user.conversation_storage_consented?
      }
    end

    # PATCH /api/preferences
    # Merges provided preferences with existing ones (partial update)
    # Body: { preferences: { theme: "dark", sidebar_collapsed: true, ... } }
    def update
      prefs = params[:preferences]
      return render json: { error: 'No preferences provided' }, status: :bad_request unless prefs.is_a?(ActionController::Parameters) || prefs.is_a?(Hash)

      # Sanitize: only accept known preference keys to prevent abuse
      allowed = prefs.to_unsafe_h.slice(
        # Theme & display
        'theme', 'dark_mode', 'font_size', 'article_view',
        # Sidebar
        'sidebar_collapsed', 'sidebar_auto_open',
        # Article preferences
        'article_preferences',
        # TOC
        'toc_collapsed', 'toc_position',
        # Chatbot
        'chatbot', 'chatbot_widget',
        # Reference display
        'reference_style', 'reference_highlight',
        # Bookmarks
        'bookmarks_view',
        # Copy style
        'copy_format'
      )

      result = current_user.merge_ui_prefs!(allowed)
      render json: { success: true, preferences: result }
    rescue StandardError => e
      Rails.logger.error("[Preferences] Save failed for user #{current_user.id}: #{e.message}")
      render json: { error: 'Failed to save preferences' }, status: :internal_server_error
    end

    # DELETE /api/preferences
    # Clears all stored preferences
    def destroy
      current_user.update!(ui_preferences: nil)
      render json: { success: true }
    end

    private

    def require_user
      return if respond_to?(:current_user, true) && current_user

      render json: { error: 'Login required' }, status: :unauthorized
    end
  end
end
