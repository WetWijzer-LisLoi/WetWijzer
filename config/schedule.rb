# frozen_string_literal: true

# Update document lookups every Sunday at 12 PM (noon)
every :sunday, at: '12:00 pm' do
  rake 'document_lookups:update'

  # Log the execution
  command "echo 'Document lookups update completed at $(date)' >> #{path}/log/document_lookups_cron.log"
end
