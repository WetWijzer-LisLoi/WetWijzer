# frozen_string_literal: true

# The ids of the rows on a Fisconet page. An id used to come from the article number alone, while the regional codes hold
# the same numbers once per region, so most contents entries there opened another region's text: 1,237 of the 1,696
# articles of W.Reg. and 753 of the 1,035 of W.Succ. (measured on the live pages 2026-11-03, ledger item 46).
#
# A row of a region always has art_<number>--<region>, whatever else the page holds. A row without a region has
# art_<number>. A row whose id is already taken, by a repeated number or by two numbers that normalise alike, gets a
# running number after it. The first row of a number also answers to the plain art_<number>, and each row to the form an
# old bookmark used, such as art_145/33, as long as no other row has it. Chatbot citations open the row they cite, through
# these same ids (LegalChatbot::FisconetSearch#article_url, ledger item 47); answers from before that keep the plain form,
# which lands on the first region.
class FisconetArticleAnchors
  # What an old bookmark may hold; anything else was never written as an id.
  LEGACY_ID = %r{\A[[:alnum:]_.:/-]+\z}
  FEDERAL = 'federal'
  SEPARATOR = '--'

  # art_44 of a Walloon row is art_44--waals; a row without a region keeps art_44.
  def self.regional_id(canonical, region)
    slug = region.to_s.parameterize.presence
    slug ? "#{canonical}#{SEPARATOR}#{slug}" : canonical
  end

  # What the part of an id after art_ holds: 44--waals--2 is article 44, region waals, the second row with that id. An
  # article number never holds the separator, as normalising collapses it.
  def self.parse_fragment(fragment)
    number, *rest = fragment.to_s.split(SEPARATOR)
    [number.to_s, rest.find { |part| part.match?(/\A[[:alpha:]]/) }&.downcase]
  end

  # &canonical turns an article number into its plain id, as the page and the chatbot's links both derive it.
  def initialize(articles, &canonical)
    @canonical = canonical
    @ids = {}.compare_by_identity
    @aliases = {}.compare_by_identity
    @by_region = {}
    @by_number = {}
    @first_of_number = {}
    used = Set.new
    # Ids first, all of them: an alias must never take what is another row's own id.
    articles.each { |article| @ids[article] = claim_id(article, used) }
    articles.each { |article| @aliases[article] = claim_aliases(article, used) } # rubocop:disable Style/CombinableLoops
  end

  def id_of(article) = @ids.fetch(article)
  def aliases_of(article) = @aliases.fetch(article)

  # Where a reference to an article, written inside a row of this region, should lead. The number as written comes first,
  # wherever it stands: in this region, else the federal row, else the first row anywhere with it, because "art. 1/2" must
  # not become article 1.2 of this region just because both normalise to one id. Only a number no row has goes by that id:
  # this region, else federal, else the plain id. A number written alike twice in one scope reaches the first of them.
  def target(canonical_id, region, number: nil)
    written = number.to_s.downcase
    scopes = [slug(region), FEDERAL]
    exact = scopes.filter_map { |scope| @by_number[[scope, written]] }.first || @first_of_number[written]
    exact || scopes.filter_map { |scope| @by_region[[scope, canonical_id]] }.first || canonical_id
  end

  private

  def slug(region) = region.to_s.parameterize.presence

  def claim_id(article, used)
    canonical = @canonical.call(article[:article_number])
    return nil unless canonical

    region = slug(article[:region])
    base = self.class.regional_id(canonical, region)
    id = base
    id = "#{base}#{SEPARATOR}#{(2..).find { |n| used.exclude?("#{base}#{SEPARATOR}#{n}") }}" if used.include?(id)
    used << id
    @by_region[[region, canonical]] ||= id
    written = article[:article_number].to_s.downcase
    @by_number[[region, written]] ||= id
    @first_of_number[written] ||= id
    id
  end

  def claim_aliases(article, used)
    canonical = @canonical.call(article[:article_number])
    legacy = "art_#{article[:article_number]}"
    [canonical, (legacy if legacy.match?(LEGACY_ID))].compact.uniq.select { |candidate| used.add?(candidate) }
  end
end
