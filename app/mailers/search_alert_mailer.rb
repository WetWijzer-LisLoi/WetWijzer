# frozen_string_literal: true

# Mailer for search alert notifications
class SearchAlertMailer < ApplicationMailer
  default from: -> { default_from_email }

  # Sends a confirmation email when a user creates a new search alert
  # @param alert [SearchAlert] The search alert to confirm
  def confirmation(alert)
    @alert = alert
    @confirm_url = api_search_alert_confirm_url(token: alert.confirmation_token)
    
    mail(
      to: alert.email,
      subject: I18n.t('search_alerts.mailer.confirmation.subject', app: app_name)
    )
  end

  # Sends notification when new laws match a search alert
  # @param alert [SearchAlert] The search alert
  # @param laws [Array<Legislation>] New matching laws
  def new_results(alert, laws)
    @alert = alert
    @laws = laws
    @unsubscribe_url = api_search_alert_unsubscribe_url(token: alert.unsubscribe_token)
    @search_url = laws_url(title: alert.query, **alert.filters.symbolize_keys)
    
    mail(
      to: alert.email,
      subject: I18n.t('search_alerts.mailer.new_results.subject', 
                      count: laws.size, 
                      query: alert.query.truncate(30),
                      app: app_name)
    )
  end

  private

  def app_name
    I18n.locale == :fr ? 'LisLoi' : 'WetWijzer'
  end

  def default_from_email
    I18n.locale == :fr ? 'noreply@lisloi.be' : 'noreply@wetwijzer.be'
  end
end
