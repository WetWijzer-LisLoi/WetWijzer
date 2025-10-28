# frozen_string_literal: true

# == Schema Information
#
# Table name: contents
#
#  id                :integer          not null, primary key
#  language_id       :integer          not null
#  legislation_numac :string           not null
#  introd            :text
#  toc               :text
#  senate_dossier    :string(32)
#  chamber_dossier   :string(32)
#  preamble          :text
#  signature         :text
#  parliamentary_work :text
#  report_to_king    :text
#  other_external_links :text
#  publication_date  :string(32)       # v0.86: extracted from introd
#  dossier_number    :string(20)       # v0.86: extracted from introd
#  page_number       :string(10)       # v0.86: extracted from introd
#  source            :string(300)      # v0.86: extracted from introd
#  effective_date    :string(50)       # v0.86: extracted from introd
#  end_of_validity   :string(50)       # v0.86: extracted from introd
#  erratum           :text             # v0.86: extracted from introd
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#
# Indexes
#  index_contents_on_legislation_numac  (legislation_numac) UNIQUE
#
# Foreign Keys
#  fk_rails_...  (legislation_numac => legislation.numac)
#
# Content represents the textual content of legal documents in the system.
# It serves as a central model that connects legislation with its associated
# articles, executive decisions (exdecs), and updated laws.
#
# @example Creating content for legislation
#   legislation = Legislation.find_by(numac: '123456789')
#   content = Content.new(
#     legislation_numac: legislation.numac,
#     # ... other attributes ...
#   )
#   content.save
#
# @example Accessing related records
#   # Get all articles for a content
#   articles = content.articles
#
#   # Get all executive decisions for a content
#   decisions = content.exdecs
#
#   # Get all updated laws for a content
#   updates = content.updated_laws
#
# @see Legislation The associated legislation
# @see Article The associated articles
# @see Exdec The associated executive decisions
# @see UpdatedLaw The associated updated laws
class Content < ReadonlyRecord
  include HasLanguage

  # Explicit table name configuration
  self.table_name = 'contents'

  # Associations
  # ----------------------------------------------------------------------------

  # The Legislation this content belongs to.
  # @return [Legislation] The associated legislation
  # @note Uses custom foreign key to reference legislation.numac
  belongs_to :legislation,
             foreign_key: 'legislation_numac',
             primary_key: 'numac',
             inverse_of: :content,
             required: true

  # The executive decisions associated with this content.
  # @return [ActiveRecord::Relation<Exdec>] Collection of executive decisions
  has_many :exdecs,
           foreign_key: 'content_numac',
           primary_key: 'legislation_numac',
           inverse_of: :content,
           dependent: :destroy

  # The updated laws associated with this content.
  # @return [ActiveRecord::Relation<UpdatedLaw>] Collection of updated laws
  has_many :updated_laws,
           foreign_key: 'content_numac',
           primary_key: 'legislation_numac',
           inverse_of: :content,
           dependent: :destroy

  # The articles that make up this content.
  # @return [ActiveRecord::Relation<Article>] Collection of articles
  has_many :articles,
           foreign_key: 'content_numac',
           primary_key: 'legislation_numac',
           inverse_of: :content,
           dependent: :destroy

  # Validations
  # ----------------------------------------------------------------------------

  # Validates the presence of required fields
  validates :legislation_numac, presence: true, uniqueness: true

  # Validates the maximum length of text fields
  validates :introd, length: { maximum: 65_535 }, allow_blank: true
  validates :toc, length: { maximum: 65_535 }, allow_blank: true

  # Ensure the associated legislation exists and is valid
  validates_associated :legislation

  # Scopes
  # ----------------------------------------------------------------------------

  # Recently updated contents
  # @param limit [Integer] Number of records to return
  # @return [ActiveRecord::Relation]
  scope :recently_updated, ->(limit = 10) { order(updated_at: :desc).limit(limit) }

  # Contents with introduction text
  # @return [ActiveRecord::Relation]
  scope :with_introduction, -> { where.not(introd: ['', nil]) }

  # Contents with table of contents
  # @return [ActiveRecord::Relation]
  scope :with_toc, -> { where.not(toc: ['', nil]) }

  # Contents for specific legislation numac
  # @param numac [String] The legislation numac
  # @return [ActiveRecord::Relation]
  scope :for_legislation, ->(numac) { where(legislation_numac: numac) }

  # Contents with parliamentary dossiers
  # @return [ActiveRecord::Relation]
  scope :with_dossiers, lambda {
    where('senate_dossier IS NOT NULL OR chamber_dossier IS NOT NULL')
      .where.not(senate_dossier: '').or(where.not(chamber_dossier: ''))
  }

  # Class Methods
  # ----------------------------------------------------------------------------

  # Find content by legislation numac and language
  # @param numac [String] The legislation numac
  # @param language_id [Integer] The language ID
  # @return [Content, nil]
  def self.find_by_numac_and_language(numac, language_id)
    find_by(legislation_numac: numac, language_id: language_id)
  end

  # Count contents with articles
  # @return [Integer]
  def self.count_with_articles
    joins(:articles).distinct.count
  end

  # Instance Methods
  # ----------------------------------------------------------------------------

  # Checks if content has any articles
  # @return [Boolean]
  def articles?
    articles.exists?
  end

  # Checks if content has any executive decisions
  # @return [Boolean]
  def exdecs?
    exdecs.exists?
  end

  # Checks if content has any updated laws
  # @return [Boolean]
  def updates?
    updated_laws.exists?
  end

  # Returns the total count of articles
  # @return [Integer]
  def articles_count
    articles.count
  end

  # Checks if content has any parliamentary dossier information
  # @return [Boolean]
  def parliamentary_info?
    senate_dossier_label.present? || chamber_dossier_label.present?
  end

  # -- Parliamentary preparations (Senate / Chamber) ----------------------

  # @return [String, nil] "3-1734" or nil
  def senate_dossier_label
    return senate_dossier if respond_to?(:senate_dossier) && senate_dossier.present?
    # Fallback for legacy integer columns if present
    return "#{senate_leg}-#{senate_nr}" if respond_to?(:senate_leg) && respond_to?(:senate_nr) && senate_leg.present? && senate_nr.present?

    nil
  end

  # @param locale_sym [Symbol] :nl or :fr determines language parameter
  # @return [String, nil] URL to senate.be dossier page or nil
  def senate_dossier_url(locale_sym = :nl)
    pair = parse_senate_pair
    return nil unless pair

    leg, nr = pair
    lang = locale_sym.to_s == 'fr' ? 'fr' : 'nl'
    "https://www.senate.be/www/?MIval=/dossier&LEG=#{leg}&NR=#{nr}&LANG=#{lang}"
  end

  # @return [String, nil] "51-2799" or nil
  def chamber_dossier_label
    if respond_to?(:chamber_dossier) && chamber_dossier.present?
      # Return stored string as-is (we now store dash-separated like "51-2799")
      return chamber_dossier
    end
    # Fallback for legacy integer columns if present
    if respond_to?(:chamber_legislat) &&
       respond_to?(:chamber_dossier_id) &&
       chamber_legislat.present? &&
       chamber_dossier_id.present?
      # Prefer dash-separated when constructing from legacy ints
      return "#{chamber_legislat}-#{chamber_dossier_id}"
    end

    nil
  end

  # @param locale_sym [Symbol] :nl or :fr determines language parameters
  # @return [String, nil] URL to dekamer.be dossier page or nil
  def chamber_dossier_url(locale_sym = :nl)
    pair = parse_chamber_pair
    return nil unless pair

    legislat, dossier_id = pair
    lang_param = locale_sym.to_s == 'fr' ? 'fr' : 'nl'
    inner_lang = locale_sym.to_s == 'fr' ? 'F' : 'N'
    base = [
      'https://www.dekamer.be/kvvcr/showpage.cfm?section=/flwb',
      "&language=#{lang_param}",
      '&cfm=/site/wwwcfm/flwb/flwbn.cfm'
    ].join
    "#{base}?lang=#{inner_lang}&legislat=#{legislat}&dossierID=#{dossier_id}"
  end

  private

  # Returns [leg, nr] or nil
  def parse_senate_pair
    sd = respond_to?(:senate_dossier) ? senate_dossier : nil
    if sd.present?
      m = sd.to_s.match(/\A\s*(\d{1,3})\s*[-‑–—]\s*(\d{1,7})\s*\z/)
      return [m[1].to_i, m[2].to_i] if m
    end

    sl = respond_to?(:senate_leg) ? senate_leg : nil
    sn = respond_to?(:senate_nr) ? senate_nr : nil
    return [sl.to_i, sn.to_i] if sl.present? && sn.present?

    nil
  end

  # Returns [legislat, dossier_id] or nil
  def parse_chamber_pair
    cd = respond_to?(:chamber_dossier) ? chamber_dossier : nil
    if cd.present?
      # Accepts space-separated or dash-separated forms like "51 2799" or "51-2799"
      m = cd.to_s.match(/\b(\d{1,3})\b[ \t\u00A0\u202F\-‑–—]+(\d{1,7})\b/)
      return [m[1].to_i, m[2].to_i] if m
    end

    cl = respond_to?(:chamber_legislat) ? chamber_legislat : nil
    ci = respond_to?(:chamber_dossier_id) ? chamber_dossier_id : nil
    return [cl.to_i, ci.to_i] if cl.present? && ci.present?

    nil
  end
end
