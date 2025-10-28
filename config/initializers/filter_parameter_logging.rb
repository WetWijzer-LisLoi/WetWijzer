# frozen_string_literal: true

# Filter sensitive parameters from log files
Rails.application.config.filter_parameters += %i[
  passw email secret token _key crypt salt certificate otp ssn cvv cvc
]
