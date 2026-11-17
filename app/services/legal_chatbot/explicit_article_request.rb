# frozen_string_literal: true

module LegalChatbot
  # A question that names a Belgian instrument (by NUMAC, or the Constitution by name) together with article numbers:
  # "Zoek de Belgische Grondwet (NUMAC 1994021048), artikel 10", "artikelen 10 en 11 van de Grondwet", "Citeer
  # artikel 9999 van de Belgische Grondwet". Sol 2026-11-16 16:49:59Z: the Belgian lane never looked such an article up;
  # "10" fell out of the keyword list and the NUMAC became one more full-text OR term, so a customs decree ranked first.
  #
  # Which instrument an article number belongs to (Sol 18:15:39Z):
  # 1. its governing phrase: an instrument named right after it with only linking words between ("artikel 10 van het
  #    EVRM", "l'article 10 de la CEDH", "Art. 19 of the Constitution");
  # 2. else the nearest instrument named in the question (following first on a tie): "Grondwet (NUMAC 1994021048),
  #    artikel 10".
  # A foreign constitution ("la Constitution française", "de Franse grondwet") is another instrument; an unqualified
  # constitution is the Belgian one. The European Convention on Human Rights is named like the Constitution ("artikel 10
  # EVRM", "l'article 10 de la CEDH"): its consolidated text is held under NUMAC 1950110452 (Sol 2026-11-16 20:34:53Z,
  # Q7: "artikel 19 van de Belgische Grondwet en artikel 10 EVRM" must retrieve both). A protocol named with the
  # Convention is the protocol, not the Convention: the first Protocol ("het Eerste Protocol bij het EVRM", "Protocol
  # nr. 1", "le Protocole additionnel à la CEDH") is held under NUMAC 1952032050; another protocol stays unresolved.
  # Only targets tied to a NUMAC, the Belgian Constitution, the Convention or its first Protocol are returned. Article
  # strings this parser does not support ("artikelen 1 tot 20", "art. 10000") yield no target rather than a mangled
  # one. Pure: no database access.
  module ExplicitArticleRequest
    CONSTITUTION = '1994021048'
    ECHR = '1950110452'
    ECHR_NAME = /\b(?:evrm|echr|cedh|emrk)\b|
                 \b(?:europees\s+)?verdrag\s+(?:tot|voor)\s+(?:de\s+)?bescherming\s+van\s+de\s+rechten\s+van\s+de\s+mens\b|
                 \bconvention\s+(?:europ[ée]enne\s+des|de\s+sauvegarde\s+des)\s+droits\s+de\s+l['’]homme\b|
                 \beuropean\s+convention\s+(?:on|for\s+the\s+protection\s+of)\s+human\s+rights\b|
                 \beurop[äa]ische[nr]?\s+menschenrechtskonvention\b/ix
    # The Convention's name right after a protocol ("het Eerste Protocol bij het EVRM", "le Protocole n° 12 à la
    # CEDH", "Protocol No. 1 to the ECHR") names that protocol, a distinct instrument: no Convention article is guessed.
    # Ordinals that name a protocol other than the first ("het tweede aanvullend protocol", "le deuxième protocole").
    NON_FIRST_ORDINAL = '(?:tweede|derde|vierde|vijfde|zesde|zevende|achtste|negende|tiende|elfde|twaalfde|dertiende|' \
                        'veertiende|vijftiende|zestiende|deuxi[eè]me|second|troisi[eè]me|third|quatri[eè]me|fourth|' \
                        'cinqui[eè]me|fifth|sixi[eè]me|sixth|septi[eè]me|seventh|huiti[eè]me|eighth|neuvi[eè]me|ninth|' \
                        'dixi[eè]me|tenth|onzi[eè]me|eleventh|douzi[eè]me|twelfth|treizi[eè]me|thirteenth|' \
                        'quatorzi[eè]me|fourteenth|quinzi[eè]me|fifteenth|seizi[eè]me|sixteenth|zweite[nrs]?|' \
                        'dritte[nrs]?|\d{1,2}(?:e|de|ste|[èe]me|th|nd|rd))'
    PROTOCOL_QUALIFIER = "(?:\\b(?:eerste|premier|first|erste[nrs]?|#{NON_FIRST_ORDINAL}|aanvullend\\p{L}*|additione\\p{L}*|additional)\\s+)*".freeze
    # The protocol phrase ends at a sentence break ("Geef artikel 1 van het Eerste Protocol. Geef ook EVRM artikel 10.")
    # and never crosses another instrument, an article reference or a conjunction.
    PROTOCOL_BEFORE = /#{PROTOCOL_QUALIFIER}\bprotocol\p{L}*\b
                       (?:(?!\b(?:evrm|echr|cedh|emrk|art\p{L}*|verdrag|convention|treaty|en|et|and|und)\b|(?-i:\.\s+\p{Lu}))[^;?!\n]){0,60}?
                       (?:\b(?:bij|aan|van|tot|à|a|au|du|de|to|of|zum|zur|zu)\s+(?:(?:het|la|le|l['’]|the|der|dem|de)\s*)?)?\z/ix
    # "het EVRM-protocol nr. 1", "EVRM protocol 1", "EVRM-aanvullend protocol 12": the Convention's name qualifies a
    # protocol that follows it.
    PROTOCOL_AFTER = /\A[\s-]*#{PROTOCOL_QUALIFIER}protocol\p{L}*\b(?:\s*(?:(?:nr|n[°º]|no)\.?\s*)?\d{1,2}\b)?/i
    # A protocol phrase as words of a lookup ("het Eerste Protocol", "Protocol nr. 1"), for ExplicitArticleAnswers.
    PROTOCOL_PHRASE = /#{PROTOCOL_QUALIFIER}\bprotocol\p{L}*\b(?:\s*(?:(?:nr|n[°º]|no)\.?\s*)?\d{1,2}\b)?/i
    FIRST_PROTOCOL = '1952032050'
    PROTOCOL_NUMBER = /\b(?:nr|n[°º]|no|nummer|number|num[ée]ro)\.?\s*(\d{1,2})\b|\bprotocol\p{L}*\s+(\d{1,2})\b/i
    FIRST_PROTOCOL_WORD = /\b(?:eerste|premier|first|erste[ns]?|aanvullend|additioneel|additionnel|additional|zusatz\p{L}*)\b/i
    NUMAC = /\b(\d{4}[0-9A-Z]\d{5})\b/i
    FOREIGN = /(?:frans\p{L}*|duits\p{L}*|nederlands\p{L}*|amerikaans\p{L}*|europe?s\p{L}*|spaans\p{L}*|italiaans\p{L}*|
               luxemburgs\p{L}*|brits\p{L}*|fran[çc]ais\p{L}*|allemand\p{L}*|n[ée]erlandais\p{L}*|am[ée]ricain\p{L}*|
               europ[ée]en\p{L}*|espagnol\p{L}*|italien\p{L}*|luxembourgeois\p{L}*|britannique\p{L}*|french|german|dutch|
               american|european|spanish|italian|luxembourg\p{L}*|british|US|U\.S\.|deutsch\p{L}*|franz[öo]sisch\p{L}*|
               niederl[äa]ndisch\p{L}*|amerikanisch\p{L}*|europ[äa]isch\p{L}*)/x
    # "de Franse grondwet", "la Constitution française", "la Constitution des États-Unis", "the French constitution".
    FOREIGN_CONSTITUTION = /\b(?:#{FOREIGN.source})\s+(?:grondwet|constitution|verfassung)\b|
                            \b(?:grondwet|constitution|verfassung)\s+(?:(?:van|de|des|du|der|of)\s+(?:het|la|le|l['’]|the|den)?\s*)?
                            (?:#{FOREIGN.source}|[ée]tats[-\s]unis|frankrijk|france|duitsland|allemagne|germany|nederland|
                            pays[-\s]bas|netherlands|verenigde\s+staten|united\s+states|luxemburg|luxembourg)\b/ix
    # Any other qualifier is read as foreign too (Sol 19:02:40Z, "la Constitution suisse"): an adjective right after
    # "Constitution" in French, a nationality adjective right before "grondwet" or "Constitution". The Belgian
    # qualifiers and ordinary words that follow the noun stay Belgian.
    BELGIAN_QUALIFIER = /\A(?:belge|belgische?n?|belgisch|belgian|f[ée]d[ée]rale|coordonn[ée]e|gecoördineerde|gecoordineerde|huidige|actuelle|
                          onze|notre|de|het|la|le|the|our|current)\z/ix
    QUALIFIED_AFTER = /\b(?i:constitution|verfassung)\s+(\p{Ll}\p{L}+(?:aise|ais|ienne|ien|oise|ois|ande|and|aine|ain|ole|ol|
                        uisse|isse|que|ote|ane|ise|eque|aque|ène|ene|ine))\b/x
    QUALIFIED_BEFORE = /\b(\p{L}+(?:se|sche|ese|aanse|ische|ian|ish|ese|ch|ss|an))\s+(?:grondwet|constitution|verfassung)\b/i
    CONSTITUTION_NAME = /\b(?:grondwet|constitution|verfassung)\b/i
    # Other instruments an article number can belong to; they only take numbers away from a Belgian target.
    OTHER_INSTRUMENT = /\b(?:evrm|echr|cedh|ehrm|emrk|verdrag|trait[ée]|treaty|convention(?!\s+belge)|richtlijn|directive|
                          verordening|r[èe]glement|regulation|avg|gdpr|rgpd|wetboek|code|wet|loi|gesetz|decreet|d[ée]cret|
                          ordonnantie|ordonnance|besluit|arr[êe]t[ée]|handvest|charte|charter|vweu|tfeu|tfue|veu|teu|tue|
                          protocol\p{L}*|wer|bw|sw|wib|ger\.?\s*w|gw)\b/ix
    # Words between an article number and the instrument it belongs to: "van het", "de la", "of the", "der".
    LINK = /\A[\s,]*(?:(?:van|in|uit|de|des|du|der|des|of|from|the|het|la|le|l['’]|den|dem|belgische|belgisch|belge|belgian|
                       belgischen|gecoördineerde|coordonn[ée]e)\s*)*\z/ix
    SUFFIX = '(?:\s?(?:bis|ter|quater|quinquies|sexies|septies|octies|novies|decies))?(?:/\d+)?'
    # "10", "11bis", "32quater/2", "VI.49", "5.233", "2:9". A number running on ("10000", "10a") is no match.
    NUMBER = "(?:[IVXLC]{1,6}\\.|\\d{1,2}[.:])?\\d{1,4}#{SUFFIX}(?![\\p{L}\\d])".freeze
    RANGE = '\s*(?:tot(?:\s+en\s+met)?|t\s*/\s*m|à|au|jusqu[\'’]?\s*(?:à|au)|-|–|through|to|bis)\s*(?:(?:het|l[\'’]|art(?:ikel|icle)?\.?)\s*)?\d'
    ARTICLE = /\bart(?:ikel(?:en)?|icles?|\.|s?\b)\s*(#{NUMBER}(?:\s*(?:,|en|et|and|und|&)\s*#{NUMBER})*)(?![\d\p{L}]|#{RANGE})/i

    ANY_ARTICLE = /\bart(?:ikel(?:en)?|icles?|\.|s?\b)\s*(?:[IVXLC]{1,6}\.|\d)/i

    module_function

    # [[numac, article number], ...] in question order, unique. Article numbers are kept as written apart from spaces
    # ("10", "11bis", "32quater/2", "VI.49").
    def targets(question) = analyze(question)[:targets]

    # { targets: [[numac, number], ...], others: article numbers tied to another instrument or to none }. A question
    # with others is a mixed request: the shortcut for a missing Belgian article must not answer it alone.
    def analyze(question)
      text = question.to_s.gsub(/[[:space:]]+/, ' ')
      instruments = instrument_mentions(text)
      targets = []
      others = 0
      other_numbers = []
      text.to_enum(:scan, ARTICLE).each do
        match = Regexp.last_match
        owner = governing(instruments, text, match.end(0)) || nearest(instruments, match.begin(0), match.end(0))
        list = numbers(match[1])
        if owner&.fetch(:numac)
          targets.concat(list.map { |number| [owner[:numac], number] })
        else
          others += list.size
          other_numbers.concat(list)
        end
      end
      # An article mention this parser does not read ("artikelen 1 tot 20", "art. 10000") is another request too.
      parsed = text.to_enum(:scan, ARTICLE).count
      others += [text.scan(ANY_ARTICLE).size - parsed, 0].max
      { targets: targets.uniq, others: others, other_numbers: other_numbers.uniq }
    end

    def instrument_mentions(text)
      mentions = []
      foreign = text.to_enum(:scan, FOREIGN_CONSTITUTION).map { mention(Regexp.last_match, nil) }
      text.to_enum(:scan, QUALIFIED_AFTER).each do
        foreign << mention(Regexp.last_match, nil) unless Regexp.last_match[1].match?(BELGIAN_QUALIFIER)
      end
      text.to_enum(:scan, QUALIFIED_BEFORE).each do
        foreign << mention(Regexp.last_match, nil) unless Regexp.last_match[1].match?(BELGIAN_QUALIFIER)
      end
      mentions.concat(foreign)
      text.to_enum(:scan, NUMAC).each { mentions << mention(Regexp.last_match, Regexp.last_match[1].upcase) }
      text.to_enum(:scan, CONSTITUTION_NAME).each do
        match = Regexp.last_match
        next if foreign.any? { |f| match.begin(0) >= f[:from] && match.end(0) <= f[:to] }

        mentions << mention(match, CONSTITUTION)
      end
      echr = text.to_enum(:scan, ECHR_NAME).map { echr_mention(text, Regexp.last_match) }
      mentions.concat(echr)
      numacs = mentions.select { |instrument| instrument[:numac] && ![CONSTITUTION, ECHR, FIRST_PROTOCOL].include?(instrument[:numac]) }
      text.to_enum(:scan, OTHER_INSTRUMENT).each do
        named = mention(Regexp.last_match, nil)
        # "EVRM", or "Verdrag" inside the Convention's full name, is the Convention already.
        next if echr.any? { |e| named[:from] >= e[:from] && named[:to] <= e[:to] }

        # "het Eerste Protocol bij het EVRM": the protocol word names the protocol its Convention name qualifies.
        qualified = echr.find { |e| e[:span]&.cover?(named[:from]) }
        named[:numac] = qualified ? qualified[:numac] : labelling_numac(text, named, numacs)
        mentions << named
      end
      mentions
    end

    # A NUMAC written right next to an instrument's name labels that instrument, in either order: "het Wetboek van
    # economisch recht (NUMAC 2013A11134)", "NUMAC 2013A11134, het Wetboek van economisch recht" (Sol 19:02:40Z).
    LABEL_BETWEEN_AFTER = /\A[\p{L}\s.,'’-]{0,70}\(?\s*(?:numac\s*:?\s*)?\z/i
    LABEL_BETWEEN_BEFORE = /\A\s*\)?\s*[,:]?\s*(?:(?:het|de|la|le|l['’]|the)\s+)?\z/i

    def labelling_numac(text, named, numacs)
      after = numacs.find { |numac| numac[:from] >= named[:to] && text[named[:to]...numac[:from]].match?(LABEL_BETWEEN_AFTER) }
      return after[:numac] if after

      before = numacs.rfind { |numac| numac[:to] <= named[:from] && text[numac[:to]...named[:from]].match?(LABEL_BETWEEN_BEFORE) }
      before&.fetch(:numac)
    end

    def mention(match, numac) = { from: match.begin(0), to: match.end(0), numac: numac }

    # The Convention's name, or a protocol it qualifies: the protocol phrase right before it ("het Eerste Protocol bij
    # het EVRM") or right after it ("het EVRM-protocol nr. 1"). :span covers the protocol phrase and the name.
    def echr_mention(text, match)
      start = [match.begin(0) - 80, 0].max
      before = text[start...match.begin(0)].match(PROTOCOL_BEFORE)
      after = before ? nil : text[match.end(0)..].to_s.match(PROTOCOL_AFTER)
      return mention(match, ECHR) unless before || after

      found = mention(match, protocol_numac((before || after)[0]))
      found[:span] = before ? (start + before.begin(0))...match.end(0) : match.begin(0)...(match.end(0) + after.end(0))
      found
    end

    # The first Protocol by number or by name; any other protocol has no target.
    def protocol_numac(qualifier)
      # "het tweede aanvullend protocol": a named later protocol is never the first, whatever else it says.
      return nil if qualifier.match?(/\b#{NON_FIRST_ORDINAL}\b/i)

      found = qualifier.match(PROTOCOL_NUMBER)
      number = found && (found[1] || found[2])
      return (number == '1' ? FIRST_PROTOCOL : nil) if number

      qualifier.match?(FIRST_PROTOCOL_WORD) ? FIRST_PROTOCOL : nil
    end

    # The instrument named right after the article number with only linking words between, if any.
    def governing(instruments, text, article_end)
      following = instruments.select { |instrument| instrument[:from] >= article_end }.min_by { |instrument| instrument[:from] }
      return unless following && following[:from] - article_end <= 40

      following if text[article_end...following[:from]].match?(LINK)
    end

    # The instrument closest to the article mention; on equal distance the one that follows.
    def nearest(instruments, from, to)
      instruments.min_by do |instrument|
        gap = instrument[:from] >= to ? instrument[:from] - to : from - instrument[:to]
        [gap.abs, instrument[:from] >= to ? 0 : 1]
      end
    end

    def numbers(list)
      list.split(/\s*(?:,|\ben\b|\bet\b|\band\b|\bund\b|&)\s*/i).map { |part| part.delete(' ') }.reject(&:empty?)
    end
  end
end
