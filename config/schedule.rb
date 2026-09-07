# frozen_string_literal: true

# Document lookups are intentionally not scheduled through Whenever. The
# release-managed ww-document-lookups.timer owns that database-writing job and
# serializes it with the legislation pipeline through pipeline.lock.
# This legacy block retains only the independent privacy scrub.
every :sunday, at: '12:00 pm' do
  rake 'gdpr:scrub_pii'

  # Log the execution
  command "echo 'Sunday maintenance completed at $(date)' >> #{path}/log/document_lookups_cron.log"
end
