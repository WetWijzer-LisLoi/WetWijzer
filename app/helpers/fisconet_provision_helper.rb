# frozen_string_literal: true

# The Fisconet page's provision heading and body (FisconetProvision), for the view: the label of a row and of its
# contents entry, the sanitized block-safe body with in-page article links (numbered provisions only: a reference
# inside an implementing instrument names that instrument's own article, never the code's, so it is not linked;
# LegalChatbot::FisconetSearch applies the same rule to its citations), and the plain-text fallback's leading lines.
module FisconetProvisionHelper
  def fisconet_provision_label(article)
    FisconetProvision.label(article[:article_number], article[:article_title])
  end

  def fisconet_toc_label(article)
    FisconetProvision.toc_label(article[:article_number], article[:article_title])
  end

  def fisconet_numbered_provision?(article)
    FisconetProvision.numbered?(article[:article_number])
  end

  # The code's names (FisconetProvision.code_names): the legislation's stored document type and titles plus the
  # registry's names of the code (FisconetCodeRegistry: attested abbreviations, catalogue titles, attested source
  # names); the positive evidence a leading title line must EQUAL to be dropped. Nothing is derived from the rows.
  def fisconet_code_names(law, info = {})
    code = info[:base_code].presence || law.try(:code).presence || info[:document_type].presence || law.try(:document_type)
    stored = [law.try(:document_type), law.try(:title), info[:document_type], info[:title_nl], info[:title_fr]]
    (FisconetProvision.code_names(stored) + FisconetCodeRegistry.names(code)).uniq
  end

  # nil when the row has no usable HTML or the source exceeds the parser's depth limit: the caller renders the text.
  def fisconet_provision_body(article, valid_article_numbers, code_names: [])
    body = FisconetProvision.body_html(fisconet_reduce_inline_styles(article[:html].to_s.strip),
                                       number: article[:article_number], title: article[:article_title], code_names: code_names)
    return nil if body.blank?

    body = linkify_tax_article_refs(body, valid_article_numbers) if fisconet_numbered_provision?(article)
    body.html_safe # sanitized by FisconetProvision with the view's own allowlists
  end

  def fisconet_plain_lines(lines, article, code_names: [])
    FisconetProvision.strip_leading_heading_lines(lines, number: article[:article_number], title: article[:article_title], code_names: code_names)
  end
end
