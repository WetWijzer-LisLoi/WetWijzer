# frozen_string_literal: true

# RSS Helper
# Provides helper methods for generating RSS feeds
module RssHelper
  # The types table (seeded by the updater, ids stable since the corpus was
  # built): 1 grondwet, 2 wet, 3 decreet, 4 ordonnantie, 5 besluit,
  # 6 constitution, 7 loi, 8 decret, 9 ordonnance, 10 arrete, 11 misc,
  # 12 verfassung, 13 gesetz, 14 dekret, 15 verordnung, 16 erlass, 17 misc_de.
  # The old id switch here started at 0 and called id 2 a decree; it was one
  # off for every Dutch type and wrong for every French one. Resolve through
  # the row's law_type instead, so the ids never have to be right twice.
  LAW_TYPE_I18N_KEYS = {
    'grondwet' => :constitution, 'constitution' => :constitution, 'verfassung' => :constitution,
    'wet' => :law, 'loi' => :law, 'gesetz' => :law,
    'decreet' => :decree, 'decret' => :decree, 'dekret' => :decree,
    'ordonnantie' => :ordinance, 'ordonnance' => :ordinance, 'verordnung' => :ordinance,
    'besluit' => :decision, 'arrete' => :decision, 'erlass' => :decision,
    'misc' => :misc, 'misc_de' => :misc
  }.freeze

  # Returns human-readable, localised law type name
  # @param type_id [Integer] The law type ID
  # @return [String] Law type name, '' when the id is unknown
  def law_type_name(type_id)
    @law_type_codes ||= Type.pluck(:id, :law_type).to_h # 17 rows, once per render
    key = LAW_TYPE_I18N_KEYS[@law_type_codes[type_id.to_i].to_s]
    key ? t(key) : ''
  end

  # rss_title and rss_description are called from app/views/laws/index.rss.builder.
  # A dead-code sweep on 2026-07-04 (1818ed8d) removed them because it grepped
  # only .erb and .rb, and the RSS feed then answered 500 to every reader until
  # 2026-08-17. Builder templates are call sites too; the feed is now covered
  # by a request test so this cannot happen silently again.
  #
  # The feed describes the type filters only. It never carried a per-query
  # item set (the controller's scope ignores q), and its rendered XML is
  # cached for an hour under a key built from the type filters, so echoing
  # ?q= here put the first requester's text into every reader's feed title
  # for the hour. Nothing request-specific beyond the type filters belongs in
  # the body; the controller's key and this text now agree.

  # @return [String] RSS feed title
  def rss_title
    suffix = if any_type_filter?
               active_type_filters.join(', ')
             else
               case I18n.locale
               when :fr then 'Dernières lois'
               when :de then 'Neueste Gesetze'
               when :en then 'Latest laws'
               else 'Laatste wetten'
               end
             end
    "#{t(:app_title)} - #{suffix}"
  end

  # @return [String] RSS feed description
  def rss_description
    case I18n.locale
    when :fr then 'Législation, jurisprudence et travaux parlementaires belges'
    when :de then 'Belgische Gesetzgebung, Rechtsprechung und parlamentarische Arbeit'
    when :en then 'Belgian legislation, case law and parliamentary work'
    else 'Belgische wetgeving, rechtspraak en parlementaire stukken'
    end
  end

  private

  def any_type_filter?
    %w[constitution law decree ordinance decision misc].any? { |t| params[t] == '1' }
  end

  def active_type_filters
    types = []
    types << t(:constitution) if params[:constitution] == '1'
    types << t(:law) if params[:law] == '1'
    types << t(:decree) if params[:decree] == '1'
    types << t(:ordinance) if params[:ordinance] == '1'
    types << t(:decision) if params[:decision] == '1'
    types << t(:misc) if params[:misc] == '1'
    types
  end
end
