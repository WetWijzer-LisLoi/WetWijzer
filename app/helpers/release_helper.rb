# frozen_string_literal: true

# The application's release identity for the pages that show it: the
# version from the one VERSION source (docs/VERSIONING_POLICY.md) and, in
# the admin header, the deployed commit beside it. Neither is invented: an
# unreadable source renders nothing.
module ReleaseHelper
  def application_version_label
    "v#{WetWijzer::Version.string}"
  rescue WetWijzer::Version::Invalid
    nil
  end

  # The first seven characters of the exact deployed commit, the independent
  # authority of /api/release; read once per process (REVISION only changes
  # with a restart).
  def release_short_sha
    ReleaseHelper.release_short_sha
  end

  def self.release_short_sha
    return @release_short_sha if defined?(@release_short_sha)

    @release_short_sha = ChatbotQualityProvenance.release_sha.first(7)
  rescue ChatbotQualityProvenance::Unavailable
    @release_short_sha = nil
  end

  def self.reset_release_short_sha!
    remove_instance_variable(:@release_short_sha) if defined?(@release_short_sha)
  end
end
