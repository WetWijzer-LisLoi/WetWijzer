# frozen_string_literal: true

module LegalChatbot
  # Sol 2026-11-23 06:49:36Z and 09:24:52Z (#1591, "Wat is een privacyverklaring?", live 1.1.93 and 1.1.94): the answer
  # led with art. 37 of the Belgian act of 30 July 2018 as the general authority for a privacy notice, quoted it, and
  # gave the investigative exceptions of arts. 37 and 38 without their scope; the cards also showed art. 138 and art.
  # 10/1. Read on 2026-11-23 (2018040581, NL): every heading of the act, and in full arts. 10/1, 25, 26, 37, 38 and 138.
  # By its heading, Title 2 (arts. 25 to 71) protects persons when the authorities competent for criminal matters
  # process their data (art. 25: it transposes Directive 2016/680; art. 26, 7°, lists those authorities: the police,
  # the courts and the public prosecutor, customs, the Passenger Information Unit, the financial intelligence unit, the
  # prison administration and others); by their headings, Title 3 (arts. 72 to 185) and its subtitles cover the
  # intelligence and security services, the armed forces, security clearances, the threat analysis body (OCAD) and the
  # Passenger Information Unit, and Title 7 (arts. 231 to 251) the supervisory body for police information; art. 10/1
  # allows recording electronic communications as proof of a transaction and in call centres.
  # Such a part stands in an answer only when the question raises its context. A law the reader views, an article
  # pinned for the question and the act named by its NUMAC keep every article: LegislationSearch decides those first.
  module DataProtectionPartScope
    ACT = '2018040581'
    B = '(?<![[:alnum:]])'
    E = '(?![[:alnum:]])'
    # The authorities of Title 2 and criminal procedure. Not "straf" alone: a fine for a missing privacy notice is no
    # criminal matter. "politiek" is politics, "vervolgens" means "then", "privacy policies" and "une police
    # d'assurance" are no police. Sol 2026-11-23 14:42:44Z: the financial intelligence unit (CFI/CTIF) is one of the
    # competent authorities of Title 2 (art. 26, 7°, g), read in full NL and FR on 2026-11-23), named or by its initials.
    CRIMINAL_JUSTICE = %r{#{B}(?:politie(?!k)\p{L}*|\p{L}+politie(?!k)\p{L}*|politione\p{L}*|parket\p{L}*|procureur\p{L}*|
                        openbaar\s+ministerie|onderzoeksrechter\p{L}*|strafrecht\p{L}*|strafza\p{L}*|strafonderzoek\p{L}*|
                        strafprocedure\p{L}*|strafvordering\p{L}*|strafuitvoering\p{L}*|strafregister\p{L}*|
                        strafba(?:a|re)\s+feit\p{L}*|misdrijf|misdrijven|misdaad\p{L}*|verdachte\p{L}*|opsporing\p{L}*|
                        vervolging\p{L}*|gevangen\p{L}*|gedetineerd\p{L}*|penitentiair\p{L}*|douane\p{L}*|witwas\p{L}*|
                        controleorgaan\p{L}*|police(?!\s+d.assurance)|policier\p{L}*|polici[èe]re\p{L}*|parquet\p{L}*|
                        minist[èe]re\s+public|juge\s+d.instruction|
                        (?:droit|proc[ée]dure|enqu[êe]te|affaire|mati[èe]re|poursuites?)\s+p[ée]nale?s?|casier\s+judiciaire|
                        infractions?\s+p[ée]nales?|suspects?|prisons?|d[ée]tenus?|p[ée]nitentiaire\p{L}*|blanchiment|
                        organe\s+de\s+contr[ôo]le|polizei\p{L}*|staatsanwalt\p{L}*|ermittlungsverfahren\p{L}*|strafverfahren\p{L}*|
                        strafverfolgung\p{L}*|strafsache\p{L}*|verd[äa]chtig\p{L}*|gef[äa]ngnis\p{L}*|
                        h[äa]ftling\p{L}*|zoll\p{L}*|geldw[äa]sche\p{L}*|prosecut\p{L}*|investigating\s+judge|
                        criminal\s+(?:proceedings|investigations?|cases?|records?|law|matters?|offen[cs]es?|justice)|
                        detainees?|customs|money\s+laundering|law\s+enforcement|2016/680|cel\s+voor\s+financi[ëe]le\s+informatieverwerking|(?-i:CFI|CTIF)|
                        cellule\s+de\s+traitement\s+des\s+informations\s+financi[èe]res|
                        financial\s+intelligence\s+(?:processing\s+)?unit)#{E}}iux
    # The services of Title 3. Sol 2026-11-23 14:42:44Z: "inlichtingen" and "renseignements" are also plain information
    # ("Welke inlichtingen moet een privacyverklaring bevatten?", "Quels renseignements doit contenir une déclaration de
    # confidentialité ?"), and "intelligence" is also artificial intelligence, so they count only as a service or its work.
    INTELLIGENCE = /#{B}(?:inlichtingendienst\p{L}*|inlichtingen-?\s+en\s+veiligheids\p{L}*|inlichtingenwerk\p{L}*|
                    inlichtingenofficier\p{L}*|veiligheidsdienst\p{L}*|staatsveiligheid|(?-i:ADIV|SGRS|VSSE|OCAD|OCAM|CUTA|PNR)|
                    krijgsmacht\p{L}*|leger|defensie\p{L}*|militair\p{L}*|dreigingsanalyse\p{L}*|veiligheidsmachtiging\p{L}*|
                    veiligheidsattest\p{L}*|veiligheidsadvie\p{L}*|veiligheidsverificatie\p{L}*|geclassificeerd\p{L}*|
                    passagier\p{L}*|passagers?|terroris\p{L}*|radicalis\p{L}*|radikalis\p{L}*|extremis\p{L}*|
                    services?\s+(?:g[ée]n[ée]ral\s+)?(?:de|du)\s+renseignement\p{L}*|
                    renseignement\s+(?:et\s+de\s+(?:la\s+)?s[ée]curit[ée]|militaire)|s[ûu]ret[ée]\s+de\s+l.[ée]tat|
                    forces\s+arm[ée]es|arm[ée]e|
                    habilitations?\s+de\s+s[ée]curit[ée]|attestations?\s+de\s+s[ée]curit[ée]|avis\s+de\s+s[ée]curit[ée]|
                    classifi[ée]\p{L}*|nachrichtendienst\p{L}*|geheimdienst\p{L}*|staatssicherheit|streitkr[äa]fte\p{L}*|
                    armee\p{L}*|milit[äa]r\p{L}*|sicherheitserm[äa]chtigung\p{L}*|sicherheits[üu]berpr[üu]fung\p{L}*|
                    (?:security\s+and\s+)?intelligence\s+(?:and\s+security\s+)?(?:services?|agenc(?:y|ies)|officers?)|
                    security\s+services?|military\s+intelligence|state\s+security|armed\s+forces|army|
                    security\s+clearances?|passengers?)#{E}/iux
    # Art. 10/1: a communication recorded, or a call centre
    COMMUNICATION = /#{B}(?:\p{L}*gesprek\p{L}*|telefo\p{L}*|oproep\p{L}*|communicatie\p{L}*|calls?|appels?|communications?|
                     conversations?|t[ée]l[ée]phon\p{L}*|gespr[äa]ch\p{L}*|anruf\p{L}*|kommunikation\p{L}*|phone\p{L}*)#{E}/iux
    RECORDING = /#{B}(?:opname\p{L}*|opnem\p{L}*|opgenomen|registr\p{L}*|enregistr\p{L}*|aufzeichn\p{L}*|aufgezeichnet|
                 aufnahme\p{L}*|recordings?|record|recorded|recording)#{E}/iux
    CALL_CENTRE = /#{B}(?:callcent\p{L}*|call\s+cent(?:er|re)s?|centres?\s+d.appels?|centres?\s+d.appel)#{E}/iux

    PARTS = [[25..71, :criminal_justice], [72..185, :intelligence], [231..251, :criminal_justice]].freeze

    module_function

    def source_relevant?(article, question)
      found = part(article)
      found.nil? || raised?(found, question)
    end

    # An article of a part the question raises
    def raised_part?(article, question)
      found = part(article)
      !found.nil? && raised?(found, question)
    end

    # The part of the act an article belongs to; nil for the introductory title and Titles 1, 4 to 6 and 8 (art. 10/1
    # apart)
    def part(article)
      return nil unless field(article, :numac, :content_numac) == ACT

      number = field(article, :article_title).sub(/\A\s*Art(?:ikel|icle)?\.?\s*/i, '').delete(' ')
      return :communication_recording if number.match?(%r{\A10/1(?!\d)})

      leading = number[/\A\d+/]
      leading && PARTS.find { |range, _part| range.cover?(leading.to_i) }&.last
    end

    def raised?(part, question)
      text = question.to_s
      case part
      when :criminal_justice then text.match?(CRIMINAL_JUSTICE)
      when :intelligence then text.match?(INTELLIGENCE)
      when :communication_recording
        text.match?(CALL_CENTRE) || (text.match?(COMMUNICATION) && text.match?(RECORDING))
      else true
      end
    end

    def field(article, *keys)
      return '' unless article.is_a?(Hash)

      keys.each do |key|
        value = article[key] || article[key.to_s]
        return value.to_s if value.present?
      end
      ''
    end
    private_class_method :field
  end
end
