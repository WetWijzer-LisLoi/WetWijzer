# frozen_string_literal: true

module LegalChatbot
  # The article-history pilot's dated answers (Sol 2026-11-20 10:21:43Z), local only like the pilot itself:
  # ArticleHistoryPilot.available? is false in production, and without it this class answers nothing. A Dutch or French
  # question that names an article of a law the pilot covers and one or two days, or the law reader's context (law,
  # article, day, language, region), gets each day's wording from ArticleHistoryPilot#day_state, the resolver the
  # reader's archive view uses. An undated question never reaches the archive. A day the archive leaves open is said to
  # be unverified, with the official archive page; the current wording is never put in its place.
  class DatedArticleAnswer
    JUDICIAL_CODE_PART_I = '1967101052'
    LAW_NAMES = { JUDICIAL_CODE_PART_I => { 'nl' => 'het Gerechtelijk Wetboek', 'fr' => 'du Code judiciaire' } }.freeze
    LAW_IN_QUESTION = {
      JUDICIAL_CODE_PART_I => /gerechtelijk\s+wetboek|(?<![[:alnum:]])ger\.\s?w(?:etb)?\.|code\s+judiciaire|(?<![[:alnum:]])c\.\s?jud\./i
    }.freeze
    ARTICLE = %r{(?<![[:alnum:]])(?:artikel|article|art\.)\s*(\d{1,4})(?![\d/]|\.\d|\s*(?:bis|ter|quater)(?![[:alnum:]]))}i
    MONTHS = {
      'januari' => 1, 'janvier' => 1, 'februari' => 2, 'février' => 2, 'fevrier' => 2, 'maart' => 3, 'mars' => 3,
      'april' => 4, 'avril' => 4, 'mei' => 5, 'mai' => 5, 'juni' => 6, 'juin' => 6, 'juli' => 7, 'juillet' => 7,
      'augustus' => 8, 'août' => 8, 'aout' => 8, 'september' => 9, 'septembre' => 9, 'oktober' => 10, 'octobre' => 10,
      'november' => 11, 'novembre' => 11, 'december' => 12, 'décembre' => 12, 'decembre' => 12
    }.freeze
    MONTH = MONTHS.keys.sort_by { |name| -name.length }.map { |name| Regexp.escape(name) }.join('|')
    DAY_PATTERNS = [
      [/(?<![[:alnum:]])(\d{1,2})(?:er|e)?\s+(#{MONTH})\s+(\d{4})(?![[:alnum:]])/i, ->(m) { [m[3], MONTHS[m[2].downcase], m[1]] }],
      [/(?<![\d-])(\d{4})-(\d{2})-(\d{2})(?![\d-])/, ->(m) { [m[1], m[2], m[3]] }],
      [%r{(?<![\d/.])(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})(?![\d/.])}, ->(m) { [m[3], m[2], m[1]] }]
    ].freeze
    REGIONS = { /waals|wallon/i => /WAALS|WALLONNE/, /vlaams|flamand/i => /VLAAMS|FLAMANDE/,
                /brussel|bruxelles/i => /BRUSSELS|BRUXELLES/ }.freeze
    REGION_NAMES = { 'WAALS_GEWEST' => 'Waals Gewest', 'VLAAMS_GEWEST' => 'Vlaams Gewest',
                     'BRUSSELS_HOOFDSTEDELIJK_GEWEST' => 'Brussels Hoofdstedelijk Gewest', 'REGION_WALLONNE' => 'Région wallonne',
                     'REGION_FLAMANDE' => 'Région flamande', 'REGION_DE_BRUXELLES-CAPITALE' => 'Région de Bruxelles-Capitale',
                     'REGION_BRUXELLES-CAPITALE' => 'Région de Bruxelles-Capitale' }.freeze
    ACTS = { 'nl' => { 'WET' => 'wet', 'KB' => 'koninklijk besluit', 'DWG' => 'decreet van het Waals Gewest' },
             'fr' => { 'LOI' => 'loi', 'AR' => 'arrêté royal', 'DRW' => 'décret de la Région wallonne' } }.freeze
    TEXT = {
      'nl' => {
        heading: '**Artikel %<article>s%<region>s van %<law>s op %<day>s**', region: ' (%<name>s)',
        valid: 'Geldig: van %<from>s tot en met %<until>s.', valid_open: 'Geldig: vanaf %<from>s, nog van kracht.',
        open: 'nog van kracht',
        start_basis: { 'listing' => 'volgens de lijst van gearchiveerde versies van Justel', 'note' => 'volgens een nota van Justel',
                       'unknown' => 'Justel vermeldt geen begindatum', 'undetermined' => 'inwerkingtreding onbepaald' },
        start_unknown: 'begin niet vermeld', first_shown: 'Deze tekst verschijnt voor het eerst in gearchiveerde versie %<version>s.',
        introduced: 'Gewijzigd door: %<act>s, bekendgemaakt op %<published>s.',
        published_apart: 'Deze tekst werd pas op %<published>s bekendgemaakt, maar geldt volgens Justel al vanaf %<from>s ' \
                         '(terugwerkende kracht): op %<from>s zelf was hij nog niet bekendgemaakt.',
        page: 'Officiële tekst op die datum: [Justel, %<page>s](%<url>s), %<window>s.',
        page_window: 'de wet zoals ze gold van %<from>s tot en met %<until>s', current_page: 'huidige versie',
        version: 'gearchiveerde versie %<label>s', reader: '[Lees artikel %<article>s op %<day>s in %<site>s](%<path>s)',
        not_verified: '%<site>s kan de tekst van artikel %<article>s op %<day>s niet verifiëren.',
        dispute: 'Justel vermeldt twee data van inwerkingtreding: %<days>s. Daarom wordt voor die dag geen tekst als geldende tekst gegeven.',
        gap: 'Het archief van Justel toont geen tekst van dit artikel voor de periode van %<from>s tot en met %<until>s.',
        ambiguous: 'Het archief laat voor die dag meer dan één tekst toe, omdat een begin- of einddatum niet vermeld is.',
        undetermined: 'Justel vermeldt de wijziging, maar niet wanneer ze in werking treedt.',
        start_open: 'De tekst die het archief toont, verschijnt voor het eerst in gearchiveerde versie %<version>s en Justel vermeldt er geen begindatum voor; of hij op die dag al gold, staat niet vast.',
        absent: 'Het archief bevat geen periode van dit artikel die die dag dekt.',
        not_covered: 'De pilot met gedateerde teksten omvat voor deze wet alleen de artikelen %<articles>s.',
        law_not_covered: 'De pilot met gedateerde teksten omvat deze wet niet.', official: 'Officiële bron: [Justel](%<url>s).',
        archive: 'Officiële archiefpagina: [%<page>s](%<url>s).', or: 'of',
        same: 'Op beide dagen gold dezelfde tekst.', changed: 'Tussen beide dagen veranderde de tekst: zie de twee versies hierboven.'
      },
      'fr' => {
        heading: '**Article %<article>s%<region>s %<law>s au %<day>s**', region: ' (%<name>s)',
        valid: 'En vigueur : du %<from>s au %<until>s.', valid_open: 'En vigueur : depuis le %<from>s, toujours en vigueur.',
        open: 'toujours en vigueur',
        start_basis: { 'listing' => 'selon la liste des versions archivées de Justel', 'note' => 'selon une note de Justel',
                       'unknown' => "Justel n'indique pas de date de début", 'undetermined' => 'entrée en vigueur indéterminée' },
        start_unknown: 'début non mentionné', first_shown: 'Ce texte apparaît pour la première fois dans la version archivée %<version>s.',
        introduced: 'Modifié par : %<act>s, publié le %<published>s.',
        published_apart: "Ce texte n'a été publié que le %<published>s, mais il s'applique selon Justel dès le %<from>s " \
                         "(effet rétroactif) : le %<from>s, il n'était pas encore publié.",
        page: 'Texte officiel à cette date : [Justel, %<page>s](%<url>s), %<window>s.',
        page_window: 'la loi telle qu’elle était en vigueur du %<from>s au %<until>s', current_page: 'version actuelle',
        version: 'version archivée %<label>s', reader: "[Lire l'article %<article>s au %<day>s sur %<site>s](%<path>s)",
        not_verified: "%<site>s ne peut pas vérifier le texte de l'article %<article>s au %<day>s.",
        dispute: "Justel mentionne deux dates d'entrée en vigueur : %<days>s. Aucun texte n'est donc donné comme texte en vigueur à cette date.",
        gap: "L'archive de Justel ne montre pas de texte de cet article pour la période du %<from>s au %<until>s.",
        ambiguous: "L'archive admet plus d'un texte pour cette date, faute de date de début ou de fin.",
        undetermined: 'Justel mentionne la modification, mais pas la date de son entrée en vigueur.',
        start_open: "Le texte que montre l'archive apparaît pour la première fois dans la version archivée %<version>s et Justel n'en indique pas la date de début ; il n'est pas établi qu'il était déjà en vigueur à cette date.",
        absent: "L'archive ne contient aucune période de cet article couvrant cette date.",
        not_covered: 'Pour cette loi, le projet pilote de textes datés ne couvre que les articles %<articles>s.',
        law_not_covered: 'Le projet pilote de textes datés ne couvre pas cette loi.', official: 'Source officielle : [Justel](%<url>s).',
        archive: "Page d'archive officielle : [%<page>s](%<url>s).", or: 'ou',
        same: 'Le même texte était en vigueur aux deux dates.', changed: 'Le texte a changé entre les deux dates : voir les deux versions ci-dessus.'
      }
    }.freeze

    # The dated answer, or nil when the pilot is absent, the question is undated or names no covered law and article.
    # context: the law reader's { numac:, article:, as_of:, language:, variant: } (LawsController / chat widget).
    def self.call(question, language:, context: {}, site_name: 'WetWijzer', pilot_path: nil)
      language = (context[:language].presence || language).to_s
      return unless %w[nl fr].include?(language)
      return unless pilot_path || ArticleHistoryPilot.available?

      # The chat widget puts the law page's title before a first question ([Context: ... "<title>"]); a title such as
      # "10 OKTOBER 1967. - Gerechtelijk Wetboek ... (art. 1 tot 57)" must not give the question a day or an article.
      question = question.to_s.sub(/\A\[Context:[^\n]*\]\n\n/, '')
      days = days_in(question)
      days = [context[:as_of].to_s] if days.empty? && valid_day?(context[:as_of])
      return if days.empty?

      # A law the question names comes before the page the reader asks from.
      numac = LAW_IN_QUESTION.find { |_numac, pattern| question.match?(pattern) }&.first || context[:numac].presence
      number = question[ARTICLE, 1] || context[:article].to_s[/\AArt\.(\d+)/, 1]
      return if numac.blank? || number.blank?

      pilot = ArticleHistoryPilot.new(pilot_path || ArticleHistoryPilot.db_path)
      begin
        dated = new(pilot, numac, language, number, days.first(2), question, context, site_name)
        return dated.answer if pilot.covers?(numac)

        # The reader's own law, outside the pilot: say so rather than answer from the current text.
        dated.law_not_covered_answer if context[:numac].present?
      ensure
        pilot.close
      end
    end

    # The ISO days a question names, in the order it names them (Dutch or French month names, ISO or day/month/year).
    def self.days_in(text)
      found = DAY_PATTERNS.flat_map do |pattern, parts|
        text.to_s.to_enum(:scan, pattern).map do
          match = Regexp.last_match
          year, month, day = parts.call(match).map(&:to_i)
          [match.begin(0), Date.valid_date?(year, month, day) ? format('%04d-%02d-%02d', year, month, day) : nil]
        end
      end
      found.select(&:last).sort_by(&:first).map(&:last).uniq
    end

    def self.valid_day?(value)
      value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(value.to_s)
    rescue Date::Error
      false
    end

    def initialize(pilot, numac, language, number, days, question, context, site_name)
      @pilot = pilot
      @numac = numac
      @language = language
      @number = number
      @days = days
      @question = question.to_s
      @context = context
      @site_name = site_name
      @text = TEXT.fetch(language)
    end

    def answer
      key = article_key
      return result(not_covered_sections, []) unless key

      states = @days.map { |day| @pilot.day_state(@numac, @language, key, day) }
      sections = states.map { |state| day_section(key, state) }
      sections << comparison(states) if states.size == 2 && states.all?(&:verified?)
      result(sections, sources(key, states))
    end

    def law_not_covered_answer
      justel = Legislation.where(numac: @numac, language_id: @language == 'fr' ? 2 : 1).pick(:justel).to_s
      official = format(@text[:official], url: justel) if justel.start_with?('https://www.ejustice.just.fgov.be/')
      sections = @days.map do |day|
        [format(@text[:not_verified], site: @site_name, article: @number, day: long_day(day)), @text[:law_not_covered], official]
          .compact.join("\n\n")
      end
      result(sections, [])
    end

    private

    def result(sections, sources)
      { answer: sections.join("\n\n"), sources: sources, language: @language, model_used: 'article-history-pilot',
        answer_provenance: 'article_history_pilot', response_time: 0.0 }
    end

    # 'Art.42_WAALS_GEWEST' when the question or the reader names a region the article has a variant for, else 'Art.42'.
    # nil when the pilot holds no period for the article in this language.
    def article_key
      article = "Art.#{@number}"
      return unless @pilot.articles(@numac, @language).include?(article)

      variants = @pilot.variants(@numac, @language, article).reject(&:empty?)
      # The reader's key names its region ('Art.42_WAALS_GEWEST') when it is that article's.
      context_article, context_variant = ArticleHistoryPilot.split_variant(@context[:article].to_s)
      wanted = context_article == article && variants.find { |variant| variant == context_variant }
      unless wanted
        region = REGIONS.find { |words, _name| @question.match?(words) }
        wanted = region && variants.find { |variant| variant.match?(region.last) }
      end
      wanted ? @pilot.period_key(article, wanted) : article
    end

    def heading(key, day)
      _article, variant = ArticleHistoryPilot.split_variant(key)
      region = variant.empty? ? '' : format(@text[:region], name: REGION_NAMES.fetch(variant, variant))
      format(@text[:heading], article: @number, region: region, law: law_name, day: long_day(day))
    end

    def law_name
      LAW_NAMES.dig(@numac, @language) || (@language == 'fr' ? "de la loi #{@numac}" : "de wet #{@numac}")
    end

    def day_section(key, state)
      lines = [heading(key, state.day)]
      if state.verified?
        lines << "> #{ArticleHistoryPilot.plain(state.wording.body)}"
        lines << wording_facts(state)
      else
        lines << format(@text[:not_verified], site: @site_name, article: @number, day: long_day(state.day))
        lines << reason(state)
        lines << archive_line
      end
      lines.compact.join("\n\n")
    end

    def wording_facts(state)
      wording = state.wording
      from = wording.valid_from ? "#{long_day(wording.valid_from)} (#{@text[:start_basis].fetch(wording.valid_from_basis, wording.valid_from_basis)})" : @text[:start_unknown]
      facts = [if wording.valid_until
                 format(@text[:valid], from: from, until: long_day(wording.valid_until))
               else
                 format(@text[:valid_open], from: from)
               end]
      facts << format(@text[:first_shown], version: format('%03d', wording.first_version)) if wording.first_version
      act = act_name(wording.introduced_by)
      facts << format(@text[:introduced], act: act, published: long_day(wording.published)) if act && wording.published
      # Sol 2026-11-20 11:57:26Z: a wording published after the day it applies from (article 19's 014: in force on
      # 3 February 2014, published on 15 May 2014) took effect retroactively; what had been published on that day is a
      # different question. Read in full: the amending act of 28 February 2014 (2014009267), arts. 1 to 3, NL and FR.
      if wording.published && wording.valid_from && wording.published > wording.valid_from
        facts << format(@text[:published_apart], from: long_day(wording.valid_from), published: long_day(wording.published))
      end
      facts << page_line(state.structure) if state.structure
      facts << format(@text[:reader], article: @number, day: long_day(state.day), site: @site_name, path: reader_path(state))
      facts.map { |fact| "- #{fact}" }.join("\n")
    end

    def reason(state)
      if state.dispute
        days = ArticleHistoryPilot.dispute_days(state.dispute.note).map do |day, version|
          page = version == 'current' ? @text[:current_page] : format(@text[:version], label: version)
          "#{long_day(day)} (#{page})"
        end
        format(@text[:dispute], days: days.join(" #{@text[:or]} "))
      elsif state.gap
        format(@text[:gap], from: long_day(state.gap.valid_from) || @text[:start_unknown], until: state.gap.valid_until ? long_day(state.gap.valid_until) : @text[:open])
      elsif state.absent then @text[:absent]
      elsif state.ambiguous then @text[:ambiguous]
      elsif state.undetermined? then @text[:undetermined]
      else format(@text[:start_open], version: format('%03d', state.wording&.first_version.to_i))
      end
    end

    def not_covered_sections
      articles = @pilot.articles(@numac, @language).map { |article| article.delete_prefix('Art.') }
      @days.map do |day|
        [format(@text[:not_verified], site: @site_name, article: @number, day: long_day(day)),
         format(@text[:not_covered], articles: articles.join(', ')), archive_line].join("\n\n")
      end
    end

    def comparison(states)
      same = ArticleHistoryPilot.plain(states[0].wording.body) == ArticleHistoryPilot.plain(states[1].wording.body)
      same ? @text[:same] : @text[:changed]
    end

    def page_line(page)
      name = page.current? ? @text[:current_page] : format(@text[:version], label: page.label)
      window = format(@text[:page_window], from: long_day(page.window_from), until: page.window_until ? long_day(page.window_until) : @text[:open])
      format(@text[:page], page: name, url: page.url, window: window)
    end

    def archive_line
      url = @pilot.archive_url(@numac, @language)
      return unless url

      label = url[/arch=(\d{3})/, 1]
      format(@text[:archive], page: label ? "Justel, #{format(@text[:version], label: label)}" : 'Justel', url: url)
    end

    # "wet van 28 februari 2014" out of "WET 2014-02-28 (archived version 013)"; nil when the listing names no act.
    def act_name(introduced_by)
      match = introduced_by.to_s.match(/\A([A-Z]+)\s+(\d{4}-\d{2}-\d{2})/)
      return unless match

      type = ACTS.dig(@language, match[1]) || match[1]
      @language == 'fr' ? "#{type} du #{long_day(match[2])}" : "#{type} van #{long_day(match[2])}"
    end

    def reader_path(state)
      body = state.wording&.body.to_s
      anchor = ApplicationController.helpers.article_permalink_for(Struct.new(:article_title, :article_text, :article_type)
                                                                         .new(state.key, body, 'ART'))
      Rails.application.routes.url_helpers.law_path(@numac, language_id: @language == 'fr' ? 2 : 1, as_of: state.day,
                                                            anchor: anchor)
    end

    def sources(key, states)
      states.select(&:verified?).map do |state|
        page = state.structure
        { source: 'legislation', numac: @numac, law_title: law_name,
          title: [heading(key, state.day).delete('*'), page && (page.current? ? @text[:current_page] : format(@text[:version], label: page.label))].compact.join(' - '),
          article_title: key, url: page&.url, article_text: ArticleHistoryPilot.plain(state.wording.body),
          language: @language.upcase, as_of: state.day }
      end
    end

    # "2 februari 2014", "1er février 2014".
    def long_day(iso)
      return if iso.blank?

      date = Date.iso8601(iso)
      day = @language == 'fr' && date.day == 1 ? '1er' : date.day.to_s
      "#{day} #{I18n.t('date.month_names', locale: @language.to_sym)[date.month]} #{date.year}"
    end
  end
end
