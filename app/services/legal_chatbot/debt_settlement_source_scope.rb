# frozen_string_literal: true

module LegalChatbot
  # Sol 2026-11-26 07:05:47Z (#2797 "Hoelang duurt een collectieve schuldenregeling?", live 1.1.108): art. XX.46 of the
  # Economic Law Code, on the judicial reorganisation of an enterprise, still appeared as a source card on this
  # personal-debt sample. On live 1.1.106 its cards also held arts. XX.83/22 (a restructuring expert at the request of an
  # enterprise) and XVII.63 (the limitation period under collective redress; Sol 2026-11-25 23:21:19Z).
  # Read in the corpus on 2026-11-26: Judicial Code art. 1675/2 (1967101056) opens the collective debt settlement to a
  # natural person who is no merchant ("koopman"; its note refers to art. 254 of the law of 15 April 2018), and to a
  # former merchant six months after the end of the trade or after the close of a bankruptcy. Book XX of the Economic Law
  # Code (2013A11134) holds the insolvency of enterprises, Book XVII collective redress.
  # A question about a collective debt settlement leaves Book XX out unless it raises an enterprise, a merchant, a
  # bankruptcy or a reorganisation, and Book XVII unless it raises collective redress. Every other question is not
  # judged here.
  module DebtSettlementSourceScope
    CODE = '2013A11134'
    B = '(?<![[:alnum:]])'
    E = '(?![[:alnum:]])'
    DEBT_SETTLEMENT = /#{B}(?:\p{L}*schuldenregeling\p{L}*|r[èe]glement\s+collectif\s+de\s+dettes|kollektive\p{L}*\s+schuldenregelung\p{L}*|
                       collective\s+debt\s+settlement\p{L}*|schuldbemiddel\p{L}*|m[ée]diat\p{L}*\s+de\s+dettes|debt\s+mediat\p{L}*)#{E}/iux
    # Book XX: an enterprise, a merchant or a self-employed person, a bankruptcy, a reorganisation or insolvency
    ENTERPRISE = /#{B}(?:\p{L}*onderneming\p{L}*|ondernemer\p{L}*|vennootschap\p{L}*|bedrijf\p{L}*|handelaar\p{L}*|koopman|kooplieden|
                  zelfstandig\p{L}*|faillissement\p{L}*|failliet\p{L}*|faillie\p{L}*|reorganisatie\p{L}*|herstructurering\p{L}*|
                  (?-i:WCO)|boek\s+XX|entreprise\p{L}*|entrepreneur\p{L}*|soci[ée]t[ée]\p{L}*|commer[çc]ant\p{L}*|ind[ée]pendant\p{L}*|
                  faillite\p{L}*|failli\p{L}*|r[ée]organisation\p{L}*|restructuration\p{L}*|livre\s+XX|unternehm\p{L}*|gesellschaft\p{L}*|
                  kaufmann|kaufleute|selbst[äa]ndig\p{L}*|insolvenz\p{L}*|konkurs\p{L}*|sanierung\p{L}*|buch\s+XX|enterprise\p{L}*|
                  business\p{L}*|compan(?:y|ies)|merchants?|traders?|self-employed|bankrupt\p{L}*|insolven\p{L}*|reorgani[sz]\p{L}*|
                  restructur\p{L}*|book\s+XX)#{E}/iux
    # Book XVII: collective redress
    COLLECTIVE_REDRESS = /#{B}(?:collectief\s+herstel|groepsvordering\p{L}*|r[ée]paration\s+collective|actions?\s+de\s+groupe|
                          sammelklage\p{L}*|kollektive\p{L}*\s+rechtsschutz|collective\s+redress|class\s+actions?|
                          representative\s+actions?|boek\s+XVII|livre\s+XVII|buch\s+XVII|book\s+XVII)#{E}/iux
    BOOKS = { 'XX' => ENTERPRISE, 'XVII' => COLLECTIVE_REDRESS }.freeze
    BOOK = /\AArt\.?\s*(XVII|XX)\.\d/

    module_function

    def source_relevant?(article, question)
      found = book(article)
      return true unless found

      text = question.to_s
      !text.match?(DEBT_SETTLEMENT) || text.match?(BOOKS.fetch(found))
    end

    # The book (XX or XVII) of an Economic Law Code article, nil for any other article
    def book(article)
      return nil unless article.is_a?(Hash)
      return nil unless (article[:numac] || article['numac']).to_s == CODE

      (article[:article_title] || article['article_title']).to_s.strip[BOOK, 1]
    end
  end
end
