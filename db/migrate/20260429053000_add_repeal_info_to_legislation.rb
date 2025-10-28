# frozen_string_literal: true

# Stores Justel analytical modification history data directly on the legislation
# record so the view doesn't need to live-fetch from ejustice at render time.
#
# repeal_info is a JSON blob with structure:
#   {
#     "abolished_by": "Decreet Vlaamse Raad van 05-02-2016 ...",
#     "repeal_detail": { "abbreviation": "DVR", "doc_num": "2016-02-05/20",
#                        "article": "art. 17", "effective_date": "01-04-2017" },
#     "entries": [
#       { "label": "OPGEHEVEN DOOR", "text": "Decreet ...", "href": "https://...",
#         "articles": "art. 1-5, 7" }
#     ]
#   }
class AddRepealInfoToLegislation < ActiveRecord::Migration[7.1]
  def change
    add_column :legislation, :repeal_info, :text, default: nil
  end
end
