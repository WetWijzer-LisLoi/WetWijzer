# frozen_string_literal: true

# Filter sensitive parameters from log files.
# question/answer/original_answer/context_messages/title: chatbot content is
# legal PII (names, case details) — the code guarantees it is never logged
# (see Api::ChatbotController#log_chatbot_request), which the request params
# log line would otherwise violate on every /api/chatbot/ask call.
Rails.application.config.filter_parameters += %i[
  passw email secret token _key crypt salt certificate otp ssn cvv cvc
  question answer original_answer context_messages title encrypted_messages encrypted_title
  name address phone vat company billing
]
