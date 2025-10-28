# frozen_string_literal: true

class UserMailer < ApplicationMailer
  def confirmation_email(user)
    @confirmation_url = confirm_email_url(token: user.confirmation_token)
    localized_mail(user, 'mailer.confirmation.subject')
  end

  def password_reset(user, token)
    @reset_url = edit_password_reset_url(token: token)
    localized_mail(user, 'mailer.password_reset.subject')
  end

  def usage_warning(user, usage_percent)
    @usage_percent = usage_percent
    @upgrade_url = pricing_url
    localized_mail(user, 'mailer.usage_warning.subject', subject_opts: { percent: usage_percent })
  end

  def security_alert(user, event_type, request_info = {})
    @event_type = event_type
    @ip_address = request_info[:ip]
    @user_agent = request_info[:user_agent]
    localized_mail(user, "mailer.security_alert.#{event_type}.subject")
  end

  def unverified_warning(user, warning_type = :first)
    @warning_type = warning_type
    # Regenerate token so the confirmation link still works
    user.generate_confirmation_token!
    @confirmation_url = confirm_email_url(token: user.confirmation_token)
    subject_key = warning_type == :final ? 'mailer.unverified_warning.subject_final' : 'mailer.unverified_warning.subject'
    localized_mail(user, subject_key)
  end

  def deletion_scheduled(user)
    @deletion_date = user.deletion_scheduled_for
    @cancel_url = cancel_deletion_account_url
    # Generate reactivation token so user can cancel without logging in
    token = user.generate_confirmation_token!
    @reactivation_url = confirm_reactivation_url(token: token)
    localized_mail(user, 'mailer.deletion_scheduled.subject')
  end

  def reactivation_email(user, token)
    @reactivation_url = confirm_reactivation_url(token: token)
    localized_mail(user, 'mailer.reactivation.subject')
  end

  def deletion_final_warning(user)
    @deletion_date = user.deletion_scheduled_for
    @cancel_url = cancel_deletion_account_url
    # Generate fresh reactivation token for last-chance cancellation
    token = user.generate_confirmation_token!
    @reactivation_url = confirm_reactivation_url(token: token)
    localized_mail(user, 'mailer.deletion_final_warning.subject')
  end

  def deletion_completed(email, locale)
    @locale = locale || 'nl'
    I18n.with_locale(@locale) do
      mail(to: email, from: noreply_email(@locale), subject: t('mailer.deletion_completed.subject'))
    end
  end

  def subscription_welcome(user)
    @chatbot_url = root_url
    localized_mail(user, 'mailer.subscription_welcome.subject')
  end

  def subscription_cancelled(user, reason = nil)
    @cancellation_reason = reason
    @period_end = user.subscription&.current_period_end
    @resubscribe_url = pricing_url
    localized_mail(user, 'mailer.subscription_cancelled.subject')
  end

  def payment_failed(user, decline_reason = nil)
    @decline_reason = decline_reason
    @update_payment_url = billing_portal_url
    @pricing_url = pricing_url
    localized_mail(user, 'mailer.payment_failed.subject')
  end
end
