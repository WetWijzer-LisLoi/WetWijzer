# frozen_string_literal: true

# The five tax codes the Fisconet walk corpus serves, as validated metadata that already lives in this repository, so
# that a code's page can name its identifier, its title, the legal form of the instrument and its subject as separate
# facts instead of repeating the short code under three labels (the owner's report of 2026-10-26, via Sol 12:44:51
# UTC), and so that the provision rendering (FisconetProvision) has positive, independently documented evidence of the
# names a code goes by. Nothing here is derived at runtime from the corpus's own article titles, and nothing is
# invented for a code outside this closed set (FisconetSearchService::REAL_NUMACS): an unknown code has no entry.
#
# Provenance of each field:
#   catalogue_key  the entry of the popular-laws catalogue (app/views/laws/_popular_laws.html.erb, the tax group,
#                  labelled `popular_laws.categories.tax`); its Dutch and French titles are copied here verbatim (the
#                  registry test asserts they still occur in that partial), its English and German titles are
#                  PopularLawsHelper::POPULAR_LAW_CATALOGUE_TITLES, read at runtime;
#   abbreviations  PopularLawsHelper::POPULAR_LAW_ABBREVIATIONS (config/data/popular_law_abbreviations.yml, the
#                  evidence-backed badges audited 2026-10-08, each with its sources), read at runtime, never copied;
#   legal form     what the catalogue title names the instrument, a code ("Wetboek", "Code") or a royal decree ("KB",
#                  "AR"); the Justel entry of FisconetSearchService::REAL_NUMACS identifies the instrument;
#   source names   the way the Fisconet source's own article headings name the code, as observed in the public
#                  capture of 2026-10-26 08:21 UTC (tmp/opus_v8/next-release/qa/fisconet-2026-10-26/baseline-excerpts/
#                  btw-art_1.html: "Artikel 1, Wetboek van de Btw"); listed only where captured, never inferred.
module FisconetCodeRegistry
  Entry = Struct.new(:code, :catalogue_key, :title_nl, :title_fr, :legal_form_nl, :legal_form_fr, :source_names, keyword_init: true)

  ENTRIES = {
    'WIB 92' => Entry.new(code: 'WIB 92', catalogue_key: 'tax_wib92',
                          title_nl: 'Wetboek van de Inkomstenbelastingen 1992', title_fr: 'Code des impôts sur les revenus 1992',
                          legal_form_nl: 'Wetboek', legal_form_fr: 'Code', source_names: []),
    'KB/WIB 92' => Entry.new(code: 'KB/WIB 92', catalogue_key: 'tax_kb_wib92',
                             title_nl: 'KB tot uitvoering van het WIB 92', title_fr: "AR d'exécution du CIR 92",
                             legal_form_nl: 'Koninklijk besluit', legal_form_fr: 'Arrêté royal', source_names: []),
    'BTW' => Entry.new(code: 'BTW', catalogue_key: 'tax_vat',
                       title_nl: 'BTW-Wetboek', title_fr: 'Code de la TVA',
                       legal_form_nl: 'Wetboek', legal_form_fr: 'Code', source_names: ['Wetboek van de Btw']),
    'W.Reg.' => Entry.new(code: 'W.Reg.', catalogue_key: 'tax_registration',
                          title_nl: 'Wetboek der Registratie-, Hypotheek- en Griffierechten',
                          title_fr: "Code des droits d'enregistrement, d'hypothèque et de greffe",
                          legal_form_nl: 'Wetboek', legal_form_fr: 'Code', source_names: []),
    'W.Succ.' => Entry.new(code: 'W.Succ.', catalogue_key: 'tax_succession',
                           title_nl: 'Wetboek der Successierechten', title_fr: 'Code des droits de succession',
                           legal_form_nl: 'Wetboek', legal_form_fr: 'Code', source_names: [])
  }.freeze
  SUBJECT_KEY = 'popular_laws.categories.tax'

  module_function

  # The entry of a code, or of an edition of it ('WIB 92 (inkomsten 2027)' with base_code 'WIB 92'); nil when unknown.
  def entry(document_type, base_code: nil)
    ENTRIES[base_code.to_s] || ENTRIES[document_type.to_s]
  end

  # The validated catalogue title in the text language (1 Dutch, 2 French); nil for an unknown code.
  def title(document_type, language_id, base_code: nil)
    e = entry(document_type, base_code: base_code)
    return nil unless e

    language_id.to_i == 2 ? e.title_fr : e.title_nl
  end

  # The legal form of the instrument in the text language; nil for an unknown code.
  def legal_form(document_type, language_id, base_code: nil)
    e = entry(document_type, base_code: base_code)
    return nil unless e

    language_id.to_i == 2 ? e.legal_form_fr : e.legal_form_nl
  end

  # The evidence-backed abbreviation of the code in the text language (the popular-laws badge); nil when none is attested.
  def abbreviation(document_type, language_id, base_code: nil)
    e = entry(document_type, base_code: base_code)
    return nil unless e

    labels = PopularLawsHelper::POPULAR_LAW_ABBREVIATIONS.dig(e.catalogue_key, 'labels')
    label = labels.is_a?(Hash) && labels[language_id.to_i == 2 ? 'fr' : 'nl']
    label.is_a?(String) && label.present? ? label : nil
  end

  # The subject of the existing taxonomy (the tax group of the popular-laws catalogue) in the text language; nil for an
  # unknown code.
  def subject(document_type, language_id, base_code: nil)
    return nil unless entry(document_type, base_code: base_code)

    I18n.t(SUBJECT_KEY, locale: language_id.to_i == 2 ? :fr : :nl, default: nil)
  end

  # Every name the code goes by, normalized as FisconetProvision compares them: the identifier, the attested
  # abbreviations, the catalogue titles in every language, the attested source names. [] for an unknown code.
  def names(document_type, base_code: nil)
    e = entry(document_type, base_code: base_code)
    return [] unless e

    labels = PopularLawsHelper::POPULAR_LAW_ABBREVIATIONS.dig(e.catalogue_key, 'labels')
    labels = labels.is_a?(Hash) ? labels.values : []
    catalogue = PopularLawsHelper::POPULAR_LAW_CATALOGUE_TITLES.fetch(e.catalogue_key, {}).values
    FisconetProvision.code_names(e.code, labels, e.title_nl, e.title_fr, catalogue, e.source_names)
  end
end
