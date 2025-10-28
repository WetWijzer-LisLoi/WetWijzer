# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('MAILER_FROM', 'noreply@wetwijzer.be')
  layout 'mailer'
end
