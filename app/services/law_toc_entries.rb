# frozen_string_literal: true

# WW-WER-01 (Codex inbox 2026-10-07 19:17 CEST): the logical entries of a
# stored table of contents.
#
# The updater stored Justel's TOC rows node by node. One row,
#   <A>Titel 1.</A> [<sup>1</sup> Algemene definities]<sup>1</sup><BR>
# became five lines ("Titel 1.", " [", "1", "     Algemene definities]",
# "1"), with blank lines between rows. The page rendered every fragment as
# an entry of its own: the Wetboek van economisch recht showed 4,989 list
# items, and its heading links ("Titel 1." -> section-titel-1) matched no
# section, because the article text names the heading in full
# (section-titel-1-1-algemene-definities). The importer is fixed, but the
# stored corpus keeps the old shape until it is reimported.
#
# Only recognized fragments are joined to the entry they belong to, and only
# within one row: a blank line always ends an entry.
# - A lone opening bracket "[", and what follows it until the bracket closes
#   (the editorial insertion), at most MAX_FRAGMENTS lines. The first text
#   after "[" or "[1" is joined even when it starts like a heading.
# - An editorial marker number ("1", "[1", "1]") right after "[" or "]".
# - A dash subtitle ("- Definities", "- [") right after a heading line that
#   has none yet.
# - The rest of an amendment note that a line opened with "<" (<Inséré par
#   L 2007-04-25/30, art. 1, En vigueur : 26-04-2007>), until it closes.
# A line that starts an article ("Art. I.1") or a heading ("HOOFDSTUK 2.")
# is never joined to an earlier line. Nothing is dropped but blank lines and
# the fragments merged into their entry, so a table of contents without
# these fragments comes back line for line, each line stripped as the page
# always showed it.
module LawTocEntries
  MAX_FRAGMENTS = 8
  ORDINAL = '(?:(?:eerste|tweede|derde|vierde|vijfde|zesde|zevende|achtste|negende|tiende|' \
            'premier|premi[èe]re|deuxi[èe]me|troisi[èe]me|quatri[èe]me|cinqui[èe]me|sixi[èe]me|' \
            'septi[èe]me|huiti[èe]me|neuvi[èe]me|dixi[èe]me|first|second|third|fourth|fifth|' \
            'sixth|seventh|eighth|ninth|tenth|[ivxlc]+)\s+)?'
  HEADING_WORDS = 'DEEL|BOEK|PART|PARTIE|LIVRE|HOOFDSTUK|CHAPITRE|CHAPTER|TITEL|TITRE|TITLE|AFDELING|' \
                  'ONDERAFDELING|SECTION|SOUS-SECTION|PARAGRAAF|PARAGRAPHE|BIJLAGE|BIJLAGEN|ANNEXE|' \
                  'ANNEXES|ANNEX|TEIL|BUCH|KAPITEL|ABSCHNITT|UNTERABSCHNITT|ANLAGE'
  HEADING_START = /\A#{ORDINAL}(?:#{HEADING_WORDS})\b/io
  ARTICLE_START = /\A(?:Art(?:ikel|icle)?\b|Art\.)/i
  MARKER = /\A\[?\d{1,3}\]?\z/
  JUST_OPENED = /\[\d{0,3}\z/
  DASH = /\A[-–—](?:\s|\[|\z)/
  DASHED_HEADING = /\A\S+(?:\s+\S+){0,3}\s+[-–—](?:\s|\[)/

  module_function

  # The entries, in order, as strings.
  def call(toc)
    entries = []
    current = nil
    joined = 0
    toc.to_s.each_line do |raw|
      line = raw.chomp
      fragment = line.strip
      if fragment.empty?
        entries << finish(current, joined) if current
        current = nil
        next
      end

      if current && joined < MAX_FRAGMENTS && continuation?(current, fragment)
        current << line
        joined += 1
      else
        entries << finish(current, joined) if current
        current = line.dup
        joined = 0
      end
    end
    entries << finish(current, joined) if current
    entries
  end

  def continuation?(current, fragment)
    text = current.strip
    # The text of an editorial insertion that has just opened ("[" or "[1")
    # belongs to it, whatever word it starts with ("[1 Titel II van boek X]").
    return true if text.match?(JUST_OPENED)
    return false if fragment.match?(ARTICLE_START) || fragment.match?(HEADING_START)
    return true if fragment == '['
    return true if text.count('[') > text.count(']')
    return true if fragment.match?(MARKER) && text.end_with?('[', ']')
    return true if text.count('<') > text.count('>')

    fragment.match?(DASH) && text.match?(HEADING_START) && !text.match?(DASHED_HEADING)
  end

  # A single line is returned as the page always showed it; a joined entry
  # gets its whitespace runs collapsed (the fragments carry the source's
  # indentation).
  def finish(text, joined)
    joined.zero? ? text.strip : text.gsub(/[[:space:]]+/, ' ').strip
  end
end
