# frozen_string_literal: true

# Filter sensitive parameters from log files.
# question/answer/original_answer/context_messages/title: chatbot content is
# legal PII (names, case details); the code guarantees it is never logged
# (see Api::ChatbotController#log_chatbot_request), which the request params
# log line would otherwise violate on every /api/chatbot/ask call.
# signup_proof: the one-time registration proof of work stays out of the
# logs (WW-ABUSE-01).
Rails.application.config.filter_parameters += %i[
  passw email secret token _key crypt salt certificate otp ssn cvv cvc
  question answer original_answer context_messages title encrypted_messages encrypted_title
  name address phone vat company billing
  signup_proof
]

# WW-PRIV-04: search terms and the chatbot hero form's question travel as q,
# query or search; Rails' Started and Parameters lines would write them in
# full. Exact names only: a bare :q would also mask every key containing a q.
Rails.application.config.filter_parameters += [/\Aq\z/, /\Aquery\z/, /\Asearch\z/]
# The hero form redirects to /chatbot#q=<question>: the fragment never reaches
# a server, but Rails' "Redirected to" line would write it.
Rails.application.config.filter_redirect << %r{/chatbot#}

# WW-SEC-07: the chatbot's metadata fields are logged as sent only when they
# hold a known value; any other text a client puts in them is masked like a
# filtered parameter. Request parameters only: model inspection passes no
# third argument.
Rails.application.config.filter_parameters << lambda do |key, value, original_params|
  next if original_params.nil? || !value.is_a?(String)
  next unless %w[source language intelligence feedback_type].include?(key.to_s)

  value.replace('[FILTERED]') unless ChatbotMetadataVocabulary.loggable?(key, value)
end
