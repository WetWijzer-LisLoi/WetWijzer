# frozen_string_literal: true

# Parses parliamentary dossier references from various text formats
# and structured URLs found on Justel/Reflex pages.
class ParliamentaryPreparationsParser
  # Extract Senate dossier label from a senate.be URL
  # Example: "https://www.senate.be/www/?MIval=/dossier&LEG=5&NR=2841&LANG=nl"
  # Returns: "5-2841"
  def self.parse_senate_url(url)
    return nil if url.blank?

    leg = url[/\bLEG=(\d+)/i, 1]
    nr = url[/\bNR=(\d+)/i, 1]
    return "#{leg}-#{nr}" if leg && nr

    nil
  end

  # Extract Chamber dossier label from a dekamer/lachambre URL
  # Example: "https://www.dekamer.be/...&legislat=55&dossierID=2799"
  # Returns: "55-2799"
  def self.parse_chamber_url(url)
    return nil if url.blank?

    legislat = url[/\blegislat=(\d+)/i, 1]
    dossier = url[/\bdossierID=(\d+)/i, 1]
    return "#{legislat}-#{dossier}" if legislat && dossier

    nil
  end

  # Extract dossier references from free-text parliamentary work description
  # Belgian parliamentary work text sometimes contains references like:
  #   "Kamer van volksvertegenwoordigers (55-1234)"
  #   "Doc. 55 1234/001"
  #   "Senaat: zitting 5-2841"
  def self.parse_text(text)
    return { chamber: nil, senate: nil } if text.blank?

    chamber = nil
    senate = nil

    # Chamber: "Kamer" or "Chambre" followed by a dossier reference
    if (m = text.match(%r{(?:Kamer|Chambre).{0,200}?(\d{2})\s*[-/]\s*(\d{3,5})}im))
      chamber = "#{m[1]}-#{m[2]}"
    end

    # Senate: "Senaat" or "Sénat" followed by a dossier reference
    if (m = text.match(%r{(?:Senaat|S[eé]nat).{0,200}?(\d{1,2})\s*[-/]\s*(\d{1,5})}im))
      senate = "#{m[1]}-#{m[2]}"
    end

    { chamber: chamber, senate: senate }
  end
end
