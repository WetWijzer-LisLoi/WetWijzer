# frozen_string_literal: true

module Api
  class BookmarksController < ApplicationController
    before_action :require_user

    # FBL-041: shared bounded pagination contract. limit is clamped, the
    # cursor is an opaque keyset token on (bookmarked_at, id) descending -
    # the same order .recent always used - and the response carries explicit
    # page metadata so existing clients (which sent no params and got
    # everything up to 500) see identical results plus the metadata.
    MAX_PAGE = 500
    IMPORT_MAX_BYTES = 256 * 1024
    CHECK_LIMIT = 200
    NUMAC_FORMAT = /\A[0-9A-Za-z_-]{1,50}\z/

    # GET /api/bookmarks
    def index
      limit = params[:limit].presence&.to_i || MAX_PAGE
      return render_code('invalid_limit', :unprocessable_entity) unless limit.between?(1, MAX_PAGE)

      bookmarks = current_user.bookmarks.recent.order(id: :desc)
      bookmarks = bookmarks.by_folder(params[:folder]) if params[:folder].present?

      if params[:cursor].present?
        cursor_at, cursor_id = decode_cursor(params[:cursor])
        return render_code('invalid_cursor', :unprocessable_entity) unless cursor_id

        bookmarks = bookmarks.where(
          '(bookmarked_at < ?) OR (bookmarked_at = ? AND id < ?)',
          cursor_at, cursor_at, cursor_id
        )
      end

      page = bookmarks.limit(limit + 1).to_a
      has_more = page.size > limit
      page = page.first(limit)

      render json: {
        bookmarks: page.map { |b| bookmark_json(b) },
        folders: Bookmark.folders_for_user(current_user),
        page: {
          limit: limit,
          has_more: has_more,
          next_cursor: has_more ? encode_cursor(page.last) : nil
        }
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
    IMPORT_LIMIT = 1000 # localStorage migration is a one-shot; cap the batch so
    # an authenticated client can't hold the accounts write lock with a huge POST.

    def import
      if request.content_length.to_i > IMPORT_MAX_BYTES
        return render_code('payload_too_large', :content_too_large)
      end

      items = params[:bookmarks]
      return render_code('missing_bookmarks', :bad_request) unless items.is_a?(Array)
      return render_code('too_many_bookmarks', :unprocessable_entity) if items.size > IMPORT_LIMIT

      # FBL-041: observable import. Every item lands in exactly one bucket,
      # with a per-item error code instead of a silent rescue-and-continue.
      imported = 0
      skipped_existing = 0
      errors = []

      items.each_with_index do |item, index|
        numac = item[:numac].to_s.strip
        next errors << { index: index, code: 'invalid_numac' } unless NUMAC_FORMAT.match?(numac)

        bookmarked_at = parse_import_timestamp(item[:addedAt])
        next errors << { index: index, code: 'invalid_timestamp' } if bookmarked_at == :invalid

        bookmark = current_user.bookmarks.find_or_initialize_by(numac: numac)
        if bookmark.persisted?
          skipped_existing += 1
          next
        end

        bookmark.assign_attributes(
          title: item[:title].to_s.presence,
          url: item[:url].to_s.presence,
          folder: item[:folder].to_s.presence,
          bookmarked_at: bookmarked_at
        )
        if bookmark.save
          imported += 1
        else
          errors << { index: index, code: 'validation_failed' }
        end
      rescue StandardError => e
        Rails.logger.warn("[BookmarkImport] item #{index} failed: #{e.class}")
        errors << { index: index, code: 'internal_error' }
      end

      render json: {
        success: errors.empty?,
        imported: imported,
        skipped_existing: skipped_existing,
        errors: errors
      }
    end

    # GET /api/bookmarks/check
    # Quick check if a NUMAC is bookmarked (for toggle button state)
    def check
      # Single-numac form: the bookmark toggle button sends ?numac=X and
      # expects {bookmarked: boolean}. It had ALWAYS received a 400 here
      # (the action only accepted the array form), so every toggle's state
      # check silently failed; found by the FBL-041 client audit.
      if params[:numac].present?
        numac = params[:numac].to_s
        return render_code('invalid_numac', :unprocessable_entity) unless NUMAC_FORMAT.match?(numac)

        return render json: { bookmarked: current_user.bookmarks.exists?(numac: numac) }
      end

      numacs = params[:numacs]
      return render_code('missing_numacs', :bad_request) unless numacs.is_a?(Array)
      return render_code('too_many_numacs', :unprocessable_entity) if numacs.size > CHECK_LIMIT

      cleaned = numacs.map(&:to_s)
      return render_code('invalid_numac', :unprocessable_entity) unless cleaned.all? { |n| NUMAC_FORMAT.match?(n) }

      bookmarked = current_user.bookmarks.where(numac: cleaned).pluck(:numac)
      render json: { bookmarked: bookmarked }
    end

    private

    def render_code(code, status)
      render json: { error: { code: code } }, status: status
    end

    def encode_cursor(bookmark)
      timestamp = (bookmark.bookmarked_at || Time.at(0)).utc.iso8601(6)
      Base64.urlsafe_encode64("#{timestamp}|#{bookmark.id}", padding: false)
    end

    def decode_cursor(cursor)
      raw = Base64.urlsafe_decode64(cursor.to_s)
      timestamp, id = raw.split('|', 2)
      [Time.iso8601(timestamp), Integer(id)]
    rescue ArgumentError, TypeError
      [nil, nil]
    end

    # Imported timestamps must be real, bounded ISO 8601 instants; anything
    # else is a per-item error, never Time.parse guesswork.
    def parse_import_timestamp(value)
      return Time.current if value.blank?

      parsed = Time.iso8601(value.to_s)
      return :invalid unless parsed.between?(Time.utc(1990), 1.day.from_now)

      parsed
    rescue ArgumentError
      :invalid
    end

    def require_user
      return if current_user

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
