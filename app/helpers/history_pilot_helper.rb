# frozen_string_literal: true

# The article-history pilot on the law page (ArticleHistoryPilot, LawsController#set_history_pilot): labels, dates
# and the links that carry its state. Every link keeps the language, the archive date (as_of) and the other
# articles' chosen versions, so Back and a shared link restore what the reader saw.
module HistoryPilotHelper
  HISTORY_LABELS = {
    nl: {
      close: 'Sluiten', details: 'Vergelijken en bron', shown_live: 'Getoonde tekst: de huidige tekst van WetWijzer.',
      live_same: 'Gelijk aan de bewaarde Justel-versie (opgehaald op %{captured}).',
      live_differs: 'Wijkt af van de laatst bewaarde Justel-versie (opgehaald op %{captured}); de vergelijking toont het verschil.',
      version_label: 'versie %{period}', off_date: 'gold niet op %{date}', no_previous: 'Er is geen oudere versie om mee te vergelijken.',
      undetermined: 'Inwerkingtreding niet bepaald: Justel vermeldt de wijziging, maar niet wanneer ze in werking treedt.',
      caveat_composed: 'Samengestelde weergave: geen bewaarde versie van Justel is op deze datum de volledige wet. Volgorde en opschriften komen uit %{page}.',
      caveat_unresolved: 'Onopgeloste data voor:', return_current: 'Huidige wet',
      archive: 'Archief op datum', versions: 'Versies', older: 'Ouder', newer: 'Nieuwer',
      back_to_law: 'Terug naar de versie van de wet', back_to_current: 'Terug naar de huidige wet',
      compare: 'Vergelijk met de vorige versie', hide_compare: 'Vergelijking verbergen',
      from: 'van', until: 'tot en met', open: 'nog van kracht', start_unknown: 'begin niet vermeld',
      end_unknown: 'einde niet vermeld', source: 'Bron: Justel', version: 'gearchiveerde versie',
      current: 'huidige tekst', archived_on: 'Archiefweergave op', no_snapshot: 'Voor deze datum toont het archief geen volledige versie.',
      available: 'Beschikbare data', justel_archive: 'Archief van Justel', show: 'Toon', date: 'Datum',
      window: 'geldig', toc: 'Inhoudstafel', published: 'gepubliceerd op', introduced: 'ingevoerd door',
      not_in_archive: 'Tekst niet in het archief', notes_only: 'enkel de nota\'s van Justel verschillen',
      superseded: 'vervangen voor de inwerkingtreding', no_change: 'in alle gearchiveerde versies ongewijzigd',
      earliest: 'De oudste tekst die het archief toont; de inwerkingtreding ervan vermeldt het archief niet.',
      authentic: 'Justel: geconsolideerde tekst zonder authentiek karakter; enkel het Belgisch Staatsblad is authentiek.',
      selected_version: 'Gekozen versie', removed: 'geschrapt', added: 'toegevoegd', or: 'of', not_before: 'niet vóór',
      exact_page: 'Op deze datum is %{page} van Justel de volledige wet.',
      composed: 'Geen bewaarde versie van Justel is op deze datum de volledige wet. Elk artikel toont de tekst die het archief voor deze datum geeft; volgorde en opschriften komen uit %{page}.',
      ambiguous: 'Het archief laat voor deze datum meer dan één tekst toe, omdat een begin- of einddatum niet vermeld is. Getoond: de tekst met de laatst gekende begindatum.',
      gap: 'Het archief toont de tekst van dit artikel voor deze datum niet',
      disputed: 'Inwerkingtreding betwist', disputed_days: 'Justel vermeldt twee data van inwerkingtreding',
      disputed_on: 'Of deze tekst op deze datum gold, staat niet vast; hij wordt hier niet als geldende tekst getoond.'
    },
    fr: {
      close: 'Fermer', details: 'Comparer et source', shown_live: 'Texte affiché : le texte actuel de WetWijzer.',
      live_same: 'Identique à la version Justel conservée (relevée le %{captured}).',
      live_differs: "Diffère de la dernière version Justel conservée (relevée le %{captured}) ; la comparaison montre l'écart.",
      version_label: 'version %{period}', off_date: "n'était pas en vigueur le %{date}", no_previous: "Il n'y a pas de version plus ancienne à comparer.",
      undetermined: "Entrée en vigueur non fixée : Justel mentionne la modification, mais pas sa date d'entrée en vigueur.",
      caveat_composed: "Vue composée : aucune version conservée de Justel n'est la loi complète à cette date. L'ordre et les intitulés viennent de %{page}.",
      caveat_unresolved: 'Dates non résolues pour :', return_current: 'Loi actuelle',
      archive: 'Archives par date', versions: 'Versions', older: 'Plus ancienne', newer: 'Plus récente',
      back_to_law: 'Revenir à la version de la loi', back_to_current: 'Revenir à la loi actuelle',
      compare: 'Comparer avec la version précédente', hide_compare: 'Masquer la comparaison',
      from: 'du', until: 'au', open: 'toujours en vigueur', start_unknown: 'début non mentionné',
      end_unknown: 'fin non mentionnée', source: 'Source : Justel', version: 'version archivée',
      current: 'texte actuel', archived_on: 'Vue des archives au', no_snapshot: "Pour cette date, l'archive ne montre aucune version complète.",
      available: 'Dates disponibles', justel_archive: 'Archives de Justel', show: 'Afficher', date: 'Date',
      window: 'en vigueur', toc: 'Table des matières', published: 'publié le', introduced: 'introduit par',
      not_in_archive: "Texte absent de l'archive", notes_only: 'seules les notes de Justel diffèrent',
      superseded: 'remplacé avant son entrée en vigueur', no_change: 'inchangé dans toutes les versions archivées',
      earliest: "Le plus ancien texte que montre l'archive ; son entrée en vigueur n'y figure pas.",
      authentic: 'Justel : texte consolidé sans caractère authentique ; seul le Moniteur belge fait foi.',
      selected_version: 'Version choisie', removed: 'supprimé', added: 'ajouté', or: 'ou', not_before: 'pas avant le',
      exact_page: 'À cette date, %{page} de Justel est la loi complète.',
      composed: "Aucune version conservée de Justel n'est la loi complète à cette date. Chaque article montre le texte que l'archive donne pour cette date ; l'ordre et les intitulés viennent de %{page}.",
      ambiguous: "L'archive admet plus d'un texte pour cette date, faute de date de début ou de fin. Affiché : le texte dont la date de début connue est la plus récente.",
      gap: "L'archive ne montre pas le texte de cet article pour cette date",
      disputed: 'Entrée en vigueur contestée', disputed_days: "Justel mentionne deux dates d'entrée en vigueur",
      disputed_on: "Il n'est pas établi que ce texte était en vigueur à cette date ; il n'est pas présenté ici comme le texte en vigueur."
    },
    en: {
      close: 'Close', details: 'Compare and source', shown_live: 'Text shown: the current WetWijzer text.',
      live_same: 'Same as the saved Justel version (captured on %{captured}).',
      live_differs: 'Differs from the last saved Justel version (captured on %{captured}); the comparison shows the difference.',
      version_label: 'version %{period}', off_date: 'not in force on %{date}', no_previous: 'There is no older version to compare with.',
      undetermined: 'Commencement not fixed: Justel names the change but not when it takes effect.',
      caveat_composed: 'Composed view: no saved Justel version is the complete law on this date. Order and headings come from %{page}.',
      caveat_unresolved: 'Unresolved dates for:', return_current: 'Current law',
      archive: 'Archive by date', versions: 'Versions', older: 'Older', newer: 'Newer',
      back_to_law: 'Return to the law version', back_to_current: 'Return to current law',
      compare: 'Compare with the previous version', hide_compare: 'Hide the comparison',
      from: 'from', until: 'to', open: 'still in force', start_unknown: 'start not stated',
      end_unknown: 'end not stated', source: 'Source: Justel', version: 'archived version',
      current: 'current text', archived_on: 'Archive view for', no_snapshot: 'The archive shows no complete version for this date.',
      available: 'Available dates', justel_archive: 'Justel archive', show: 'Show', date: 'Date',
      window: 'in force', toc: 'Table of contents', published: 'published on', introduced: 'introduced by',
      not_in_archive: 'Text not in the archive', notes_only: "only Justel's notes differ",
      superseded: 'replaced before it took effect', no_change: 'unchanged in every archived version',
      earliest: 'The oldest text the archive shows; the archive does not state when it took effect.',
      authentic: 'Justel: consolidated text without official force; only the Belgian Official Gazette is authentic.',
      selected_version: 'Selected version', removed: 'removed', added: 'added', or: 'or', not_before: 'not before',
      exact_page: 'On this date, Justel %{page} is the complete law.',
      composed: 'No saved Justel version is the complete law on this date. Each article shows the text the archive gives for this date; order and headings come from %{page}.',
      ambiguous: 'The archive allows more than one text for this date because a start or end date is not stated. Shown: the text with the latest known start.',
      gap: "The archive does not show this article's text for this date",
      disputed: 'Entry into force disputed', disputed_days: 'Justel states two entry-into-force dates',
      disputed_on: 'Whether this text was in force on this date is not established; it is not shown here as the text in force.'
    }
  }.freeze

  # The interface language: Dutch and French as on those sites, English for the English and German interfaces.
  def history_label(key)
    labels = HISTORY_LABELS.fetch(I18n.locale.to_sym) { HISTORY_LABELS[:en] }
    labels.fetch(key)
  end

  def history_day(iso)
    iso.present? ? Date.iso8601(iso).strftime('%d-%m-%Y') : nil
  end

  # "van 03-02-2014 tot en met 02-08-2017", "van begin niet vermeld, nog van kracht".
  def history_period(version)
    unknown = history_label(:start_unknown)
    unknown = "#{unknown} (#{history_label(:not_before)} #{history_day(version.not_before)})" if version.not_before.present?
    start = "#{history_label(:from)} #{history_day(version.valid_from) || unknown}"
    return "#{start}, #{history_label(:open)}" if version.current?

    "#{start} #{history_label(:until)} #{history_day(version.valid_until) || history_label(:end_unknown)}"
  end

  def history_snapshot_label(snapshot)
    name = snapshot.current? ? history_label(:current) : "#{history_label(:version)} #{snapshot.label}"
    window = [history_day(snapshot.window_from), history_day(snapshot.window_until) || history_label(:open)]
    "#{name}: #{history_label(:window)} #{history_label(:from)} #{window[0]} #{history_label(:until)} #{window[1]}"
  end

  # The law page's address with the pilot's state changed: as_of: nil drops the date, versions: replaces the
  # per-article choices, compare: the compared articles.
  # focus: [key, step] keeps that article's Versions control open with the focus on the step (see LawsController).
  def history_law_path(law, as_of: @history_as_of, versions: @history_versions, compare: @history_compare, # rubocop:disable Metrics/ParameterLists
                       anchor: nil, focus: nil)
    law_path(law, **history_state_params(as_of: as_of, versions: versions, compare: compare, focus: focus), anchor: anchor)
  end

  def history_state_params(as_of: @history_as_of, versions: @history_versions, compare: @history_compare, focus: nil)
    state = { language_id: @language_id }
    state[:as_of] = as_of if as_of.present?
    state[:art_version] = versions if versions.present?
    state[:art_compare] = compare.index_with { '1' } if compare.present?
    state[:history_focus] = focus.join(':') if focus
    state
  end

  # The frame's own address: the same state, so the articles render as the page says.
  def history_frame_params
    return {} unless @history_pilot

    history_state_params(focus: @history_focus).except(:language_id)
  end

  def history_focus?(key, step = nil)
    @history_focus.present? && @history_focus[0] == key && (step.nil? || @history_focus[1] == step)
  end

  def history_permalink(key, body)
    article_permalink_for(Struct.new(:article_title, :article_text, :article_type).new(key, body, 'ART'))
  end

  # The pilot's state of one article key on the page:
  #   versions   its wordings (text periods), oldest first;
  #   selected   the wording the archive gives: the reader's choice (chosen true) when it names one, else, with an
  #              archive date, the wording that applies that day, else the current wording; nil for a gap;
  #   live_body  on the live page, the live row's text (shown unless the reader chose a wording);
  #   shown_body the text displayed; compare_base: the wording a comparison starts from (the one before the shown
  #              text; for live text that differs from the saved current wording, that saved wording);
  #   disputes   its disputed stretches; dispute: the one holding the archive date (not presented as in force);
  #   gap        an 'unknown' period holding the date; ambiguous: covering periods disagree and no page settles it;
  #   undetermined the shown wording's commencement is 'onbepaald'; off_date: a chosen wording does not apply on the
  #              archive date; absent: no period covers the date.
  # A choice that names no wording is ignored, so the date's own state, dispute included, still shows.
  ArticleState = Struct.new(:key, :versions, :selected, :chosen, :disputes, :dispute, :gap, :ambiguous, :absent,
                            :undetermined, :off_date, :live_body, :shown_body, :compare_base, keyword_init: true) do
    def live? = !live_body.nil? && !chosen
    def unresolved? = dispute.present? || gap.present? || ambiguous || undetermined
  end

  # page / page_text_id: the archive view's structure page and its wording for the key (evidence for
  # ArticleHistoryPilot#day_state, the day resolver the chatbot shares).
  # live_body: the live row's text on the current-law page.
  def history_article_state(key, page: nil, page_text_id: nil, live_body: nil)
    return unless @history_pilot && key.to_s.match?(LawsController::HISTORY_KEY)

    numac = params[:numac].to_s
    @history_article_versions ||= {}
    versions = @history_article_versions[key] ||= @history_pilot.article_versions(numac, @history_language, key)
    return if versions.empty?

    @history_article_disputes ||= {}
    disputes = @history_article_disputes[key] ||= @history_pilot.article_disputes(numac, @history_language, key)
    state = ArticleState.new(key: key, versions: versions, disputes: disputes, chosen: false, ambiguous: false,
                             absent: false, undetermined: false, off_date: false, live_body: live_body)
    chosen = @history_versions[key]
    state.selected = versions.find { |version| ArticleHistoryPilot.version_name(version) == chosen } if chosen
    if state.selected
      state.chosen = true
      state.off_date = @history_as_of.present? && !state.selected.covers?(@history_as_of)
    elsif @history_as_of.present?
      day = @history_pilot.day_state(numac, @history_language, key, @history_as_of,
                                     page: page, page_text_id: page_text_id)
      return state.tap { state.absent = true } if day.absent

      found = day.found
      state.ambiguous = day.ambiguous
      case found.status
      when 'text' then state.selected = found
      when 'disputed'
        state.dispute = found
        state.selected = versions.rfind { |version| version.text_id == found.text_id }
      else state.gap = found
      end
    else
      state.selected = versions.find(&:current?) || versions.last
    end
    state.undetermined = state.selected&.valid_from_basis == 'undetermined' && !state.chosen
    history_texts(state)
  end

  def history_texts(state)
    index = state.selected && state.versions.index(state.selected)
    previous = state.versions[index - 1] if index&.positive?
    if state.live?
      state.shown_body = state.live_body
      same = state.selected && ArticleHistoryPilot.plain(state.live_body) == ArticleHistoryPilot.plain(state.selected.body)
      state.compare_base = same ? previous : state.selected
    else
      state.shown_body = state.selected&.body
      state.compare_base = previous
    end
    state
  end

  def history_open?(key) = history_focus?(key) && @history_focus[1] != 'close'

  # The article's printed text with the quiet Versions link put right after its number (span.article-number).
  def history_with_link(article_html, link_html)
    html = article_html.to_s
    placed = html.sub(%r{(<span class="article-number[^"]*"[^>]*>.*?</span>)}m) { "#{Regexp.last_match(1)} #{link_html}" }
    (placed == html ? "#{link_html}#{html}" : placed).html_safe
  end

  # "01-06-2022 (gearchiveerde versie 024) of 30-04-2023 (gearchiveerde versie 027)": a disputed stretch's days, each
  # with the page that states it.
  def history_dispute_days(stretch)
    ArticleHistoryPilot.dispute_days(stretch.note).map do |day, version|
      source = version == 'current' ? history_label(:current) : "#{history_label(:version)} #{version}"
      "#{history_day(day)} (#{source})"
    end.join(" #{history_label(:or)} ")
  end

  # The article keys of the archive view of a day, in the structure page's order: its headings and articles, the
  # articles absent on the day left out, and keys that apply on the day but are not on that page put in number order.
  # [[key, kind, body, text_id]]: body and text_id are the page's own (an article's is used only when the pilot holds no period for
  # it; nil for an article added because it applies on the day).
  def history_snapshot_entries(snapshot)
    numac = params[:numac].to_s
    items = @history_pilot.items(snapshot)
    on_day = @history_pilot.keys_on(numac, @history_language, @history_as_of)
    entries = items.map { |item| [item.key, item.kind, item.body, item.text_id] }
    (on_day - items.map(&:key)).each do |key|
      position = entries.rindex { |entry_key, kind, _| kind == 'article' && (history_order(entry_key) <=> history_order(key)) <= 0 }
      entries.insert(position ? position + 1 : entries.size, [key, 'article', nil, nil])
    end
    entries
  end

  # [[key, kind, body, state]]: the entries with each article's state on the archive date (nil for a heading, or
  # for an article the pilot holds no period for).
  def history_snapshot_rows(structure)
    history_snapshot_entries(structure).map do |key, kind, body, page_text_id|
      next [key, kind, body, nil] if kind == 'heading'

      [key, kind, body, history_article_state(key, page: structure, page_text_id: page_text_id)]
    end
  end

  def history_order(key)
    article, variant = ArticleHistoryPilot.split_variant(key)
    match = article.match(/\AArt\.(\d+)(.*)\z/)
    match ? [match[1].to_i, match[2], variant] : [10**6, article, variant]
  end

  # The other language's key of a regional or future-law variant (Art.42_WAALS_GEWEST <-> Art.42_REGION_WALLONNE).
  HISTORY_VARIANT_PAIRS = { 'WAALS_GEWEST' => 'REGION_WALLONNE', 'VLAAMS_GEWEST' => 'REGION_FLAMANDE',
                            'BRUSSELS_HOOFDSTEDELIJK_GEWEST' => 'REGION_DE_BRUXELLES-CAPITALE',
                            'TOEKOMSTIG RECHT' => 'DROIT FUTUR' }.freeze

  def self.history_key_for(key, language)
    article, variant = ArticleHistoryPilot.split_variant(key)
    return key if variant.empty?

    target = language == 'fr' ? HISTORY_VARIANT_PAIRS.fetch(variant, variant) : HISTORY_VARIANT_PAIRS.invert.fetch(variant, variant)
    "#{article}#{target.include?(' ') ? ' ' : '_'}#{target}"
  end
end
