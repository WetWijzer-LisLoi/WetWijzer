# frozen_string_literal: true

module Api
  class BookmarksController < ApplicationController
    skip_forgery_protection
    before_action :require_user

    # GET /api/bookmarks
    def index
      bookmarks = current_user.bookmarks.recent
      bookmarks = bookmarks.by_folder(params[:folder]) if params[:folder].present?
      bookmarks = bookmarks.limit(params[:limit] || 500)

      render json: {
        bookmarks: bookmarks.map { |b| bookmark_json(b) },
        folders: Bookmark.folders_for_user(current_user)
      }
    end

    # POST /api/bookmarks
    def create
      bookmark = current_user.bookmarks.build(
        numac: params[:numac],
        title: params[:title],
        url: params[:url],
        folder: params[:folder],
        bookmarked_at: Time.current
      )

      if bookmark.save
        render json: { success: true, bookmark: bookmark_json(bookmark) }
      else
        render json: { error: bookmark.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end
    end

    # DELETE /api/bookmarks/:numac
    def destroy
      bookmark = current_user.bookmarks.find_by(numac: params[:numac] || params[:id])
      if bookmark&.destroy
        render json: { success: true }
      else
        render json: { error: 'Bookmark not found' }, status: :not_found
      end
    end

    # PATCH /api/bookmarks/:numac
    def update
      bookmark = current_user.bookmarks.find_by(numac: params[:numac] || params[:id])
      return render json: { error: 'Bookmark not found' }, status: :not_found unless bookmark

      bookmark.update!(folder: params[:folder])
      render json: { success: true, bookmark: bookmark_json(bookmark) }
    end

    # POST /api/bookmarks/import
    # Bulk import from localStorage migration
    def import
      items = params[:bookmarks]
      return render json: { error: 'No bookmarks provided' }, status: :bad_request unless items.is_a?(Array)

      imported = 0
      items.each do |item|
        next unless item[:numac].present?

        bookmark = current_user.bookmarks.find_or_initialize_by(numac: item[:numac])
        if bookmark.new_record?
          bookmark.assign_attributes(
            title: item[:title],
            url: item[:url],
            folder: item[:folder],
            bookmarked_at: item[:addedAt].present? ? Time.parse(item[:addedAt]) : Time.current
          )
          imported += 1 if bookmark.save
        end
      rescue StandardError => e
        Rails.logger.warn("[BookmarkImport] Skipped #{item[:numac]}: #{e.message}")
        next
      end

      render json: { success: true, imported: imported }
    end

    # GET /api/bookmarks/check
    # Quick check if a NUMAC is bookmarked (for toggle button state)
    def check
      numacs = params[:numacs]
      return render json: { error: 'numacs required' }, status: :bad_request unless numacs.is_a?(Array)

      bookmarked = current_user.bookmarks.where(numac: numacs).pluck(:numac)
      render json: { bookmarked: bookmarked }
    end

    private

    def require_user
      return if respond_to?(:current_user, true) && current_user

      render json: { error: 'Login required' }, status: :unauthorized
    end

    def bookmark_json(bookmark)
      {
        numac: bookmark.numac,
        title: bookmark.title,
        url: bookmark.url,
        folder: bookmark.folder,
        bookmarked_at: bookmark.bookmarked_at&.iso8601
      }
    end
  end
end
