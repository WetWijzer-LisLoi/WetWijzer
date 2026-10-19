# frozen_string_literal: true

# The normal production hook boots an isolated candidate while the predecessor
# still serves requests. Validate its pinned, separately published EU artifact
# at that point, before the service/worktree transition. No provider is called.
Rails.application.config.after_initialize do
  if Rails.env.production?
    readiness = LegalChatbot::EuCorpus.default.verify!
    Rails.logger.info("[EUR-Lex] verified immutable corpus: #{readiness[:documents]} editions, " \
                      "#{readiness[:chunks]} units (#{readiness[:eligible_chunks]} eligible)")
  end
end
