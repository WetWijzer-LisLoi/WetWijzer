# frozen_string_literal: true

module Api
  # Server-side UI preferences storage.
  # Replaces ALL localStorage/sessionStorage usage.
  # Anonymous users: in-memory only (nothing persists).
  # Logged-in users: preferences saved here.
  #
  # GDPR: Art. 6(1)(b) - necessary for service delivery (remembering UI settings).
  # No sensitive PII stored. Data deleted when user account is deleted.
  class PreferencesController < ApplicationController
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
    # Merges provided preferences with existing ones (partial update).
    # Body: { preferences: { theme: "dark", sidebar_collapsed: true, ... } }
    #
    # FBL-042: every key is validated against UiPreferenceSchema (types,
    # enums, nested keys, byte caps) with stable error codes, and the merge
    # itself is atomic in SQLite so concurrent tabs cannot lose unrelated
    # keys. A JSON null deletes its key.
    def update
      prefs = params[:preferences]
      return render json: { error: { code: 'missing_preferences' } }, status: :bad_request unless prefs.is_a?(ActionController::Parameters) || prefs.is_a?(Hash)

      raw = prefs.is_a?(ActionController::Parameters) ? prefs.to_unsafe_h : prefs
      result = UiPreferenceSchema.validate(raw)
      unless result.valid?
        return render json: { error: { code: 'invalid_preferences', details: result.errors } },
                      status: :unprocessable_entity
      end

      merged = current_user.merge_ui_prefs!(result.patch)
      render json: { success: true, preferences: merged }
    rescue ActiveRecord::RecordInvalid
      render json: { error: { code: 'preferences_too_large' } }, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error("[Preferences] Save failed for user #{current_user.id}: #{e.class}")
      render json: { error: { code: 'save_failed' } }, status: :internal_server_error
    end

    # DELETE /api/preferences
    # Clears all stored preferences
    def destroy
      current_user.update!(ui_preferences: nil)
      render json: { success: true }
    end

    private

    def require_user
      return if current_user

      render json: { error: 'Login required' }, status: :unauthorized
    end
  end
end
