# frozen_string_literal: true

# Exact catalogue names for statutes whose official titles use different wording.
module LawCommonNames
  NUMAC_BY_NAME = {
    'camerawet' => '2007000528',
    'camera wet' => '2007000528',
    'camera-wet' => '2007000528',
    'loi cameras' => '2007000528',
    'camera act' => '2007000528',
    'kameragesetz' => '2007000528',
    'drugwet' => '1921022450',
    'drugswet' => '1921022450',
    'loi drogues' => '1921022450',
    'drug act' => '1921022450',
    'drogengesetz' => '1921022450'
  }.freeze

  def self.numacs_for(query)
    name = query.to_s.squish.downcase.unicode_normalize(:nfd).gsub(/\p{Mn}/, '')
    Array(NUMAC_BY_NAME[name])
  end
end
