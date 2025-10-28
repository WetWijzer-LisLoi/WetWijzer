# frozen_string_literal: true

class UserMailer < ApplicationMailer
  def confirmation_email(user)
    @user = user
    @confirmation_url = confirm_email_url(token: user.confirmation_token)
    @locale = user.locale || 'nl'

    I18n.with_locale(@locale) do
      mail(
        to: user.email,
        subject: t('mailer.confirmation.subject')
      )
    end
  end

  def password_reset(user, token)
    @user = user
    @reset_url = edit_password_reset_url(token: token)
    @locale = user.locale || 'nl'

    I18n.with_locale(@locale) do
      mail(
        to: user.email,
        subject: t('mailer.password_reset.subject')
      )
    end
  end

  def welcome_email(user)
    @user = user
    @locale = user.locale || 'nl'

    I18n.with_locale(@locale) do
      mail(
        to: user.email,
        subject: t('mailer.welcome.subject')
      )
    end
  end

  def usage_warning(user, usage_percent)
    @user = user
    @usage_percent = usage_percent
    @locale = user.locale || 'nl'
    @upgrade_url = pricing_url

    I18n.with_locale(@locale) do
      mail(
        to: user.email,
        subject: t('mailer.usage_warning.subject', percent: usage_percent)
      )
    end
  end

  def security_alert(user, event_type, request_info = {})
    @user = user
    @event_type = event_type
    @ip_address = request_info[:ip]
    @user_agent = request_info[:user_agent]
    @locale = user.locale || 'nl'

    I18n.with_locale(@locale) do
      mail(
        to: user.email,
        subject: t("mailer.security_alert.#{event_type}.subject")
      )
    end
  end
end
