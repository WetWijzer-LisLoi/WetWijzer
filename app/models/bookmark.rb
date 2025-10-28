# frozen_string_literal: true

# == Bookmark
#
# Server-side bookmark storage for laws. Replaces localStorage-based bookmarks.
# Contains public law metadata only (NUMAC, title) — no encryption needed.
# Requires user account.
#
# Columns:
#   user_id      - Owner
#   numac        - Belgian Official Gazette number (unique per user)
#   title        - Law title (display purposes)
#   url          - Full URL to the law page
#   folder       - Optional folder for organization
#   bookmarked_at - When the bookmark was created
class Bookmark < AccountRecord
  belongs_to :user

  validates :numac, presence: true,
                    length: { maximum: 50 },
                    uniqueness: { scope: :user_id, message: 'already bookmarked' }
  validates :title, length: { maximum: 500 }
  validates :url, length: { maximum: 1000 }
  validates :folder, length: { maximum: 100 }

  scope :recent, -> { order(bookmarked_at: :desc) }
  scope :by_folder, ->(folder) { where(folder: folder) if folder.present? }
  scope :uncategorized, -> { where(folder: [nil, '']) }

  def self.folders_for_user(user)
    where(user: user).where.not(folder: [nil, '']).distinct.pluck(:folder).sort
  end
end
