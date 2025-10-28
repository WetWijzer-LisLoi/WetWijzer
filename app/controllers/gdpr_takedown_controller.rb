# frozen_string_literal: true

# GDPR Art. 17: Takedown request form for data subjects who find
# personal data in pseudonymized court decisions.
# Accessible without login - data subjects may not have accounts.
class GdprTakedownController < ApplicationController
  skip_before_action :authenticate_user!, raise: false
  before_action :set_noindex

  # Rate limit: max 3 requests per IP per hour
  before_action :check_rate_limit, only: [:create]

  # GET /gdpr/takedown
  def new
    @takedown_request = GdprTakedownRequest.new
    @takedown_request.ecli = params[:ecli] if params[:ecli].present?
    @title = case I18n.locale when :fr then 'Demande de suppression de données personnelles' when :de then 'Antrag auf Löschung personenbezogener Daten' when :en then 'Personal data removal request' else 'Verwijderingsverzoek persoonsgegevens' end
  end

  # POST /gdpr/takedown
  def create
    @takedown_request = GdprTakedownRequest.new(takedown_params)
    @takedown_request.ip_hash = Digest::SHA256.hexdigest("#{request.remote_ip}:takedown")

    if @takedown_request.save
      # Send notification email to compliance team
      GdprTakedownMailer.new_request(@takedown_request).deliver_later
      flash[:notice] = takedown_success_message
      redirect_to gdpr_takedown_confirmation_path
    else
      @title = case I18n.locale when :fr then 'Demande de suppression de données personnelles' when :de then 'Antrag auf Löschung personenbezogener Daten' when :en then 'Personal data removal request' else 'Verwijderingsverzoek persoonsgegevens' end
      render :new, status: :unprocessable_entity
    end
  end

  # GET /gdpr/takedown/confirmation
  def confirmation
    @title = case I18n.locale when :fr then 'Demande reçue' when :de then 'Antrag eingegangen' when :en then 'Request received' else 'Verzoek ontvangen' end
  end

  private

  def takedown_params
    params.require(:gdpr_takedown_request).permit(:name, :email, :ecli, :description)
  end

  def set_noindex
    @noindex = true
  end

  def check_rate_limit
    ip_hash = Digest::SHA256.hexdigest("#{request.remote_ip}:takedown")
    recent_count = GdprTakedownRequest.where(ip_hash: ip_hash)
                                      .where('created_at > ?', 1.hour.ago)
                                      .count
    return unless recent_count >= 3

    flash[:alert] = case I18n.locale
                    when :fr then 'Vous avez déjà soumis une demande récemment. Veuillez réessayer plus tard.'
                    when :de then 'Sie haben kürzlich bereits einen Antrag eingereicht. Bitte versuchen Sie es später erneut.'
                    when :en then 'You have recently submitted a request. Please try again later.'
                    else 'U heeft recentelijk al een verzoek ingediend. Probeer het later opnieuw.'
                    end
    redirect_to gdpr_takedown_path
  end

  def takedown_success_message
    case I18n.locale
    when :fr then 'Votre demande de suppression a été reçue. Nous répondrons dans les 30 jours.'
    when :de then 'Ihr Löschantrag wurde erhalten. Wir antworten innerhalb von 30 Tagen.'
    when :en then 'Your removal request has been received. We will respond within 30 days.'
    else 'Uw verwijderingsverzoek is ontvangen. Wij reageren binnen 30 dagen.'
    end
  end
end
