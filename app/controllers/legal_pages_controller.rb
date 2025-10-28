# frozen_string_literal: true

class LegalPagesController < ApplicationController
  # No authentication required for legal pages
  # These pages are publicly accessible

  def contact
    @title = t('legal_pages.contact.title', default: 'Contact')
    @meta_description = t('legal_pages.contact.description', default: 'Contact information')
    render_legal_page(:contact)
  end

  def about
    @title = t('legal_pages.about.title', default: 'About')
    @meta_description = t('legal_pages.about.description', default: 'About the platform and its founder')
    render_legal_page(:about)
  end

  def faq
    raise ActionController::RoutingError, 'Not Found' unless Rails.application.config.chatbot_enabled

    @title = t('legal_pages.faq.title', default: 'FAQ')
    @meta_description = t('legal_pages.faq.description', default: 'Frequently asked questions')
    render_legal_page(:faq)
  end

  def terms
    @title = t('legal_pages.terms.title', default: 'Terms of Service')
    @meta_description = t('legal_pages.terms.description', default: 'Terms of service and conditions of use')
    render_legal_page(:terms)
  end

  def privacy
    @title = t('legal_pages.privacy.title', default: 'Privacy Policy')
    @meta_description = t('legal_pages.privacy.description', default: 'Privacy policy and data protection')
    render_legal_page(:privacy)
  end

  def ai_security
    @title = t('legal_pages.ai_security.title', default: 'AI Security & Privacy')
    @meta_description = t('legal_pages.ai_security.description', default: 'How your chatbot conversations are protected with enterprise-grade encryption')
    render_legal_page(:ai_security)
  end

  def imprint
    @title = t('legal_pages.imprint.title', default: 'Imprint')
    @meta_description = t('legal_pages.imprint.description', default: 'Legal imprint and contact information')
    render_legal_page(:imprint)
  end

  def accessibility
    @title = t('legal_pages.accessibility.title', default: 'Accessibility')
    @meta_description = t('legal_pages.accessibility.description', default: 'Accessibility statement')
    render_legal_page(:accessibility)
  end

  def support
    @title = t('legal_pages.support.title', default: 'Support')
    @meta_description = t('legal_pages.support.description', default: 'Support the project through subscriptions, donations, or spreading the word')
    render_legal_page(:support)
  end

  def legal_changes
    @title = t('legal_pages.legal_changes.title', default: 'Legal Changes')
    @meta_description = t('legal_pages.legal_changes.description', default: 'History of changes to our legal documents')
    render_legal_page(:legal_changes)
  end

  private

  def render_legal_page(page_type)
    locale = I18n.locale.to_s
    # Map locale to view: faq -> faq_nl, faq_fr, faq_en, faq_de
    view_name = "#{page_type}_#{locale}"

    # Fallback to NL if locale-specific view doesn't exist
    unless template_exists?(view_name, 'legal_pages')
      Rails.logger.warn("[LegalPages] Template #{view_name} not found, falling back to #{page_type}_nl")
      view_name = "#{page_type}_nl"
    end

    # Legal pages are static content - cache for 1 hour
    expires_in 1.hour, public: true

    render view_name
  end
end
