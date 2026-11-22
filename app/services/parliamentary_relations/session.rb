# frozen_string_literal: true

module ParliamentaryRelations
  # Whether a dossier reference ("K:55-1234" in parliamentary_refs, "55-1234" in a contents row) can be a link to a
  # dossier's official page (Sol 2026-11-22 06:15:51Z, 08:35:50Z and 09:08:02Z).
  #
  # The Chamber and the Senate number their dossiers by legislature since the elections of 21 May 1995: the Chamber
  # from its 49th legislature, the Senate from its 1st. For older laws Justel's parliamentary work names a session's
  # documents and their dates instead. For the Judicial Code of 10 October 1967 it lists the Chamber's "Amendement nr.
  # 59-2 tot 59-57" and a bill "du 7-4-1965", which became the references "K:59-2" and "7-4": an amendment's number and
  # a date, read as legislature and dossier. The first was a link to dossier 2 of a 59th legislature, which opened the
  # current 56K0002 "Taalgroepen", a list of members by language group.
  #
  # A reference whose legislature is not one the house numbers dossiers by is no link. Otherwise only what the Chamber
  # corpus establishes removes a link: a dossier it holds with a type that prepares no law (a resolution, a coalition
  # agreement, the house's rules, ...), or a budget document (a list or table, a policy note, a general explanation, a
  # report) referenced by a law that is no budget law. 56K0002 is held as TABELLEN OF LIJSTEN. A dossier the corpus
  # does not hold (not scraped yet, or of legislatures 49 to 52), a blank type and a type not listed here leave the
  # reference as it was: automatically linked and unverified. A corpus that cannot be read establishes nothing, so a
  # caller links no dossier it could not check (Verdict :unreadable). A later legislature than the law's own is no
  # evidence either way: a legislature alone cannot tell whether that dossier amended the law.
  #
  # Sol 2026-11-22 09:33:40Z: the Chamber also files lists that prepare nothing under the budget types ("Taalgroepen.",
  # its political composition, the order of precedence), so a budget-type dossier is a budget document only by its
  # own title; a law title that is missing is no evidence against one (55K1579, a budget justification); and 56K0002
  # stays unrelated whatever the corpus holds or fails to hold.
  module Session
    # The elections that opened each numbered legislature, as art. 1 of the royal decree convening the electoral
    # colleges sets them: 1995000294, 1999000344, 2003021083, 2007000387, 2010021063, 2014021051, 2019012696 and
    # 2024005134. The Chamber's 49th legislature and the Senate's 1st opened on the first.
    ELECTIONS = %w[1995-05-21 1999-06-13 2003-05-18 2007-06-10 2010-06-13 2014-05-25 2019-05-26 2024-06-09]
                .map { |day| Date.iso8601(day) }.freeze
    FIRST_LEGISLATURE = { 'chamber' => 49, 'senate' => 1 }.freeze
    # The Chamber corpus's dossier types (dossiers.type) that prepare no law
    NO_LAW_TYPES = ['VOORSTEL VAN RESOLUTIE', 'REGEERAKKOORD', 'VOORSTEL REGLEMENT', 'VOORSTEL ONDERZOEKSCOMMISSIE',
                    'VOORDRACHT VAN KANDIDATEN', 'SUBSIDIARITEITSADVIES', 'LIJST VAN VERZOEKSCHRIFTEN', 'VERKIEZINGEN',
                    'BELEIDSVERKLARING', 'STATISTISCHE OPGAVE', 'STAND VAN DE SCHATKIST'].freeze
    # Types that accompany a budget bill: a law that is no budget law has none of them as its preparation
    BUDGET_TYPES = ['TABELLEN OF LIJSTEN', 'BELEIDSNOTA', 'ALGEMENE TOELICHTING', 'VERSLAG'].freeze
    BUDGET_LAW = /begroting|rijksmiddelen|budget/i
    # A budget document's own title (dossiers.titel): the budget, its justification or its policy notes
    BUDGET_DOCUMENT = /begroting|rijksmiddelen|budget|verantwoording|beleidsnota/i
    # Dossiers established to prepare no law, whatever the corpus holds: 56K0002 "Taalgroepen."
    KNOWN_NO_LAW = { 56 => [2] }.freeze

    module_function

    # [the first day, the next legislature's first day or nil] of a numbered legislature, else nil
    def period(parliament, legislature)
      first = FIRST_LEGISLATURE[parliament.to_s]
      return nil unless first

      index = legislature.to_i - first
      return nil if index.negative? || index >= ELECTIONS.size

      [ELECTIONS[index], ELECTIONS[index + 1]]
    end

    def numbered?(parliament, legislature) = !period(parliament, legislature).nil?

    # What the Chamber corpus db establishes about a Chamber dossier for the law titled law_title:
    #   :no_law     a dossier known to prepare no law, a type that prepares no law, a budget type whose own title is no
    #               budget document, or a budget document for a law whose title says it is no budget law
    #   :open       nothing against it: a bill, a dossier it does not hold, a blank or unlisted type, a budget document
    #               for a budget law or a law without a title
    #   :unreadable no corpus; a corpus that fails raises SQLite3::Exception, for the caller to report (the panel shows
    #               its part unavailable, the metadata links nothing it could not check)
    def verdict(db, legislature, number, law_title)
      return :no_law if KNOWN_NO_LAW.fetch(legislature.to_i, []).include?(number.to_i)
      return :unreadable if db.nil?

      type, title = db.get_first_row('SELECT type, titel FROM dossiers WHERE legislature = ? AND nummer = ? LIMIT 1',
                                     [legislature.to_i, number.to_i])
      type = type.to_s.strip.upcase
      return :no_law if NO_LAW_TYPES.include?(type)
      return :open unless BUDGET_TYPES.include?(type)
      return :no_law unless title.to_s.match?(BUDGET_DOCUMENT)
      return :no_law if law_title.present? && !law_title.to_s.match?(BUDGET_LAW)

      :open
    end

    # The law's title, from any language row of its NUMAC
    def law_title(numac) = Legislation.where(numac: numac.to_s).where.not(title: [nil, '']).pick(:title)
  end
end
