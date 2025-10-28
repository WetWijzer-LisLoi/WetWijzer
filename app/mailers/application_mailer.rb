# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('MAILER_FROM', 'noreply@wetwijzer.be')
  layout 'mailer'
  helper BrandingHelper

  private

  # Shared pattern: set @locale from user and wrap mail() in I18n.with_locale
  # Eliminates 6 repetitions of the same locale-wrapping boilerplate across mailers.
  #
  # @param user [User] user whose locale determines the email language
  # @param subject_key [String] I18n key for the email subject
  # @param subject_opts [Hash] interpolation options for the subject translation
  # @yield optional block for additional mail options
  # @return [Mail::Message]
  def localized_mail(user, subject_key, subject_opts: {}, **mail_opts)
    @user = user
    @locale = user.locale || 'nl'

    I18n.with_locale(@locale) do
      mail(
        to: user.email,
        from: noreply_email(@locale),
        subject: t(subject_key, **subject_opts),
        **mail_opts
      )
    end
  end

  # Returns the noreply email address for the user's locale/brand
  # @param locale [String, Symbol] the user's locale
  # @return [String] noreply email (e.g. noreply@wetwijzer.be)
  def noreply_email(locale = 'nl')
    case locale.to_sym
    when :fr then 'noreply@lisloi.be'
    when :de then 'noreply@gesetzguide.be'
    else 'noreply@wetwijzer.be'
    end
  end
end
