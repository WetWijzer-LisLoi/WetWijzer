# frozen_string_literal: true

# Court case from Belgian jurisprudence database
# Maps to 'cases' table in jurisprudence.db
class CourtCase < JurisprudenceRecord
  self.table_name = 'cases'

  has_many :case_chunks, foreign_key: 'case_id', dependent: :destroy

  scope :dutch, -> { where(language_id: 1) }
  scope :french, -> { where(language_id: 2) }
  scope :by_court, ->(court) { where(court: court) }
  scope :recent, -> { order(decision_date: :desc) }

  def ecli
    case_number
  end

  def display_title
    "#{court} #{decision_date&.year || 'n.d.'}"
  end

  def language_code
    language_id == 2 ? 'fr' : 'nl'
  end

  def language_name
    language_id == 1 ? 'Nederlands' : 'Français'
  end

  def clean_text(text)
    return '' if text.blank?

    text
      .gsub(/\s+/, ' ')
      .gsub(/[~`]+/, '')
      .gsub(/\.{3,}/, '...')
      .gsub(/_{2,}/, ' ')
      .gsub(/\*+/, '')
      .gsub(/p\.\s*\d+\s*$/, '')
      .gsub(/Niet te registreren/, '')
      .strip
  end

  def display_summary
    if summary.present?
      clean_text(summary)
    elsif full_text.present?
      text = full_text

      if ecli?
        match = text.match(/(?:En cause|In zake)\s*:\s*(.{50,300})/m)
        return clean_text(match[1]) if match
      end

      if arrestendatabank?
        match = text.match(/(?:In de zaak van|Gelet op|Gezien)\s+(.{50,300})/m)
        return clean_text(match[1]) if match
      end

      clean_text(text[200..500] || text[0..300])
    else
      ''
    end
  end

  def display_case_number
    if ecli?
      if (match = case_number.match(/ECLI:BE:GHCC:(\d{4}):ARR\.(\d+)/))
        "Arrest #{match[2].to_i}/#{match[1]}"
      else
        case_number
      end
    else
      case_number.gsub(/^ARR:/, '').strip
    end
  end

  def court_type
    if court&.include?('Grondwettelijk') || court&.include?('Constitutionnelle')
      :constitutional
    elsif court&.include?('Cassatie')
      :cassation
    elsif court&.include?('Beroep')
      :appeal
    elsif court&.include?('eerste aanleg')
      :first_instance
    elsif court&.include?('Raad van State')
      :council_of_state
    else
      :other
    end
  end

  def court_short_name
    return court if court.blank?

    court
      .gsub('Grondwettelijk Hof / Cour Constitutionnelle', 'Grondwettelijk Hof')
      .gsub('Rechtbank eerste aanleg ', 'Rb. ')
      .gsub('Hof van Beroep ', 'Hof v. Beroep ')
      .gsub('Hof van Cassatie ', 'Hof v. Cassatie ')
  end

  def truncated_text(length = 500)
    return '' if full_text.blank?

    clean_text(full_text.truncate(length))
  end

  def ecli?
    case_number&.start_with?('ECLI:')
  end

  def arrestendatabank?
    case_number&.start_with?('ARR:')
  end
end
