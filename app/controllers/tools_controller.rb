# frozen_string_literal: true

# Controller for legal tools (deadline calculator, etc.)
class ToolsController < ApplicationController
  # GET /tools - Tools landing page
  def index
    @title = I18n.locale == :fr ? 'Outils juridiques' : 'Juridische tools'
  end

  # GET /tools/rechtbank - Court finder
  def court_finder
    @title = I18n.locale == :fr ? 'Trouver le tribunal compétent' : 'Bevoegde rechtbank vinden'
    @districts = BelgianCourtService.judicial_districts

    return unless params[:case_type].present?

    @result = BelgianCourtService.find_competent_court(
      case_type: params[:case_type],
      amount: params[:amount].to_f,
      district: params[:district].presence
    )
  end

  # GET /tools/woordenboek - Legal glossary
  def glossary
    @title = I18n.locale == :fr ? 'Glossaire juridique NL↔FR' : 'Juridisch woordenboek NL↔FR'
    @query = params[:q].to_s.strip
    @terms = BelgianCourtService.search_glossary(@query)
  end

  # GET /tools/verjaring - Statute of limitations calculator
  def limitations
    @title = I18n.locale == :fr ? 'Calculateur de prescription' : 'Verjaringstermijnen'
    @categories = BelgianCourtService::LIMITATION_CATEGORIES
    @limitations = BelgianCourtService::STATUTE_OF_LIMITATIONS

    return unless params[:type].present? && params[:start_date].present?

    @result = BelgianCourtService.calculate_limitation(params[:type], params[:start_date])
  rescue ArgumentError => e
    @error = I18n.locale == :fr ? 'Date invalide' : 'Ongeldige datum'
  end

  # GET /tools/conclusiekalender - Conclusion calendar generator
  def conclusion_calendar
    @title = I18n.locale == :fr ? 'Calendrier de conclusions' : 'Conclusiekalender'
    @templates = BelgianCourtService::CONCLUSION_TEMPLATES

    return unless params[:intro_date].present?

    @result = BelgianCourtService.generate_conclusion_calendar(
      intro_date: params[:intro_date],
      rounds: params[:rounds] || 2,
      role: params[:role] || :plaintiff,
      procedure: params[:procedure] || :standard,
      days_per_round: params[:days].present? ? params[:days].to_i : nil
    )
  rescue ArgumentError => e
    @error = I18n.locale == :fr ? 'Date invalide' : 'Ongeldige datum'
  end

  # GET /tools/rolrechten - Court fees table
  def court_fees
    @title = I18n.locale == :fr ? 'Droits de rôle' : 'Rolrechten'
    @fees = BelgianCourtService::COURT_FEES
  end

  # GET /tools/checklist - Document checklists
  def checklist
    @title = I18n.locale == :fr ? 'Checklists documents' : 'Documentchecklists'
    @checklists = BelgianCourtService::DOCUMENT_CHECKLISTS
    @selected = params[:type]&.to_sym
    @checklist = @checklists[@selected] if @selected
  end

  # GET /tools/termijncalculator.ics - iCal export
  # GET /tools/termijncalculator
  def deadline_calculator
    respond_to do |format|
      format.html { render_deadline_calculator }
      format.ics { render_deadline_ical }
    end
  end

  # GET /tools/rente - Belgian legal interest calculator
  def interest_calculator
    @title = I18n.locale == :fr ? 'Calculateur d\'intérêts légaux' : 'Wettelijke rentecalculator'
    @rates = BelgianCourtService.legal_interest_rates

    return unless params[:principal].present? && params[:start_date].present?

    begin
      principal = params[:principal].to_f
      start_date = Date.parse(params[:start_date])
      end_date = params[:end_date].present? ? Date.parse(params[:end_date]) : Date.current
      rate_type = params[:rate_type].presence || 'civil'

      @result = BelgianCourtService.calculate_interest(principal, start_date, end_date, rate_type: rate_type)
      @result[:locale] = I18n.locale
    rescue ArgumentError
      @error = I18n.locale == :fr ? 'Données invalides' : 'Ongeldige gegevens'
    end
  end

  private

  def render_deadline_calculator
    @title = I18n.locale == :fr ? 'Calculateur de dates' : 'Datumcalculator'
    @courts = BelgianCourtService.courts_for_deadline_calculator(I18n.locale)
    @mode = params[:mode].presence || 'deadline'

    case @mode
    when 'deadline'
      calculate_deadline_mode
    when 'between'
      calculate_between_mode
    when 'add'
      calculate_add_mode
    end
  end

  # GET /tools/feestdagen/:year
  def holidays
    @year = params[:year].present? ? params[:year].to_i : Date.current.year
    @year = Date.current.year if @year < 1900 || @year > 2100

    @title = I18n.locale == :fr ? "Jours fériés #{@year}" : "Feestdagen #{@year}"
    @holidays = BelgianCourtService.public_holidays(@year).sort_by { |date, _| date }
  end

  def render_deadline_ical
    return head(:bad_request) unless params[:service_date].present? && params[:deadline_days].present?

    begin
      service_date = Date.parse(params[:service_date])
      deadline_days = params[:deadline_days].to_i
      apply_vacation = params[:apply_vacation] != '0'

      result = BelgianCourtService.calculate_deadline(service_date, deadline_days, apply_vacation_rule: apply_vacation)
      
      # Generate iCal content
      cal = <<~ICAL
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//WetWijzer//Deadline Calculator//NL
        BEGIN:VEVENT
        UID:deadline-#{service_date.iso8601}-#{deadline_days}@wetwijzer.be
        DTSTAMP:#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}
        DTSTART;VALUE=DATE:#{result[:final_deadline].strftime('%Y%m%d')}
        DTEND;VALUE=DATE:#{(result[:final_deadline] + 1).strftime('%Y%m%d')}
        SUMMARY:#{I18n.locale == :fr ? 'Délai légal' : 'Wettelijke termijn'} (#{deadline_days}#{I18n.locale == :fr ? 'j' : 'd'})
        DESCRIPTION:#{I18n.locale == :fr ? 'Délai calculé à partir du' : 'Termijn berekend vanaf'} #{service_date.strftime('%d/%m/%Y')}#{result[:extended] ? " - #{I18n.locale == :fr ? 'Prolongé' : 'Verlengd'}" : ''}
        END:VEVENT
        END:VCALENDAR
      ICAL

      send_data cal, 
                filename: "deadline-#{result[:final_deadline].iso8601}.ics",
                type: 'text/calendar',
                disposition: 'attachment'
    rescue ArgumentError
      head :bad_request
    end
  end

  def calculate_deadline_mode
    return unless params[:service_date].present? && params[:deadline_days].present?

    begin
      service_date = Date.parse(params[:service_date])
      deadline_days = params[:deadline_days].to_i
      apply_vacation = params[:apply_vacation] != '0'

      @result = BelgianCourtService.calculate_deadline(service_date, deadline_days, apply_vacation_rule: apply_vacation)
      @result[:mode] = 'deadline'
      @result[:locale] = I18n.locale

      # Add judicial vacation warning
      @result[:in_vacation] = BelgianCourtService.in_judicial_vacation?(@result[:final_deadline])
      @result[:vacation_warning] = @result[:in_vacation] && !apply_vacation
    rescue ArgumentError
      @error = I18n.locale == :fr ? 'Date invalide' : 'Ongeldige datum'
    end
  end

  def calculate_between_mode
    return unless params[:start_date].present? && params[:end_date].present?

    begin
      start_date = Date.parse(params[:start_date])
      end_date = Date.parse(params[:end_date])

      @result = BelgianCourtService.days_between(start_date, end_date)
      @result[:mode] = 'between'
      @result[:locale] = I18n.locale
      
      # Add week numbers
      @result[:start_week] = BelgianCourtService.week_number(start_date)
      @result[:end_week] = BelgianCourtService.week_number(end_date)
      @result[:start_day_of_year] = BelgianCourtService.day_of_year(start_date)
      @result[:end_day_of_year] = BelgianCourtService.day_of_year(end_date)
    rescue ArgumentError
      @error = I18n.locale == :fr ? 'Date invalide' : 'Ongeldige datum'
    end
  end

  def calculate_add_mode
    return unless params[:start_date].present? && params[:days_to_add].present?

    begin
      start_date = Date.parse(params[:start_date])
      days = params[:days_to_add].to_i.abs
      workdays_only = params[:workdays_only] == '1'

      @result = BelgianCourtService.add_days(start_date, days, workdays_only: workdays_only)
      @result[:mode] = 'add'
      @result[:locale] = I18n.locale
      @result[:end_week] = BelgianCourtService.week_number(@result[:end_date])
    rescue ArgumentError
      @error = I18n.locale == :fr ? 'Date invalide' : 'Ongeldige datum'
    end
  end
end
