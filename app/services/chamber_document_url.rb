# frozen_string_literal: true

# A Chamber document's link that opens that document. Rows scraped before 1.1.37 store the dossier page with parameters
# dekamer.be does not have ("legislession=54&dession=0816&suession=2"); the Chamber answers them with a page saying
# "dossier = 56K0000 not found" and HTTP 200, so the link looked fine and opened nothing (Sol 2026-11-20 08:06:10Z,
# 54/1031/002 and 54/0816/002). Such a link becomes the document's official PDF when the stored pdf_url names exactly
# that legislature, dossier and document ("https://www.dekamer.be/FLWB/PDF/54/0816/54K0816002.pdf"), else the dossier
# page with the parameters the Chamber reads (legislat= and dossierID=, as lib/tasks/scrape_kamer.py builds it).
module ChamberDocumentUrl
  DEFECTIVE = /[?&](?:legislession|dession|suession)=/i
  PDF = %r{\Ahttps://www\.dekamer\.be/FLWB/PDF/(\d{2})/(\d{4})/\1K\2(\d{3})\.pdf\z}i

  module_function

  def repair(url, pdf_url: nil, legislature: nil, dossier: nil, document: nil)
    return url unless url.to_s.match?(DEFECTIVE)

    legislature = legislature.to_s[/\A\d{2}\z/] || url.to_s[/[?&]legislession=(\d{2})/i, 1]
    dossier = dossier.to_s[/\A\d{1,4}\z/]&.rjust(4, '0') || url.to_s[/[?&]dession=(\d{1,4})/i, 1]&.rjust(4, '0')
    document = document.to_s[/\A\d{1,3}\z/]&.rjust(3, '0') || url.to_s[/[?&]suession=(\d{1,3})/i, 1]&.rjust(3, '0')
    return url if legislature.nil? || dossier.nil?

    pdf = PDF.match(pdf_url.to_s)
    return pdf_url if pdf && pdf[1] == legislature && pdf[2] == dossier && pdf[3] == document

    'https://www.dekamer.be/kvvcr/showpage.cfm?section=/flwb&language=nl&cfm=/site/wwwcfm/flwb/flwbn.cfm' \
      "?legislat=#{legislature}&dossierID=#{dossier}"
  end
end
