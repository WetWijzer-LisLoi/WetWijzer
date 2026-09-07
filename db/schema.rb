# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2025_10_10_111300) do
  create_table "articles", force: :cascade do |t|
    t.integer "language_id", null: false
    t.string "content_numac", limit: 10, null: false
    t.string "article_type", limit: 3, null: false
    t.string "article_title", limit: 20, null: false
    t.string "article_text", limit: 20000, null: false
    t.string "created_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "updated_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "article_variant", limit: 32
    t.index ["content_numac", "language_id"], name: "index_article_on_content_numac_and_language_id"
    t.index ["content_numac"], name: "index_article_on_content_numac"
    t.index ["language_id", "content_numac"], name: "index_articles_on_language_id_and_content_numac"
    t.index ["language_id"], name: "index_articles_on_language_id"
  end

  create_table "articles_text_ngrams", primary_key: ["rowid", "gram"], force: :cascade do |t|
    t.integer "rowid", null: false
    t.text "gram", null: false
  end

  create_table "contents", force: :cascade do |t|
    t.integer "language_id", null: false
    t.string "legislation_numac", limit: 10, null: false
    t.string "introd", limit: 10000, null: false
    t.string "toc", limit: 10000, null: false
    t.string "created_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "updated_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "senate_dossier", limit: 32
    t.string "chamber_dossier", limit: 32
    t.text "preamble"
    t.text "signature"
    t.text "parliamentary_work"
    t.text "report_to_king"
    t.text "other_external_links"
    t.index ["chamber_dossier"], name: "index_contents_on_chamber_dossier"
    t.index ["language_id", "legislation_numac"], name: "index_contents_on_language_id_and_legislation_numac"
    t.index ["language_id"], name: "index_contents_on_language_id"
    t.index ["legislation_numac", "language_id"], name: "unique_index_content_on_legislation_numac_and_language_id", unique: true
    t.index ["legislation_numac"], name: "index_content_on_legislation_numac"
    t.index ["senate_dossier"], name: "index_contents_on_senate_dossier"
  end

  create_table "deletion_audit", id: false, force: :cascade do |t|
    t.text "ts", default: -> { "datetime('now')" }
    t.text "table_name"
    t.text "numac"
    t.integer "language_id"
    t.text "info"
  end

  create_table "document_number_lookups", force: :cascade do |t|
    t.string "document_number"
    t.string "numac"
    t.integer "content_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "language_id", default: 1, null: false
    t.index ["content_id"], name: "index_document_number_lookups_on_content_id"
    t.index ["document_number"], name: "index_document_number_lookups_on_document_number", unique: true
    t.index ["language_id"], name: "index_document_number_lookups_on_language_id"
  end

  create_table "exdecs", force: :cascade do |t|
    t.integer "language_id", null: false
    t.string "content_numac", limit: 10, null: false
    t.string "exdec_numac", limit: 10, null: false
    t.string "created_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "updated_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.index ["content_numac", "language_id", "exdec_numac"], name: "uniq_exdecs_on_content_lang_exdec", unique: true
    t.index ["content_numac"], name: "index_exdec_on_content_numac"
    t.index ["language_id", "content_numac"], name: "index_exdecs_on_language_id_and_content_numac"
    t.index ["language_id"], name: "index_exdecs_on_language_id"
  end

  create_table "languages", force: :cascade do |t|
    t.string "language", limit: 2, null: false
  end

  create_table "legislation", force: :cascade do |t|
    t.string "numac", limit: 10, null: false
    t.integer "law_type_id", null: false
    t.integer "year", null: false
    t.string "date", limit: 10, null: false
    t.string "title", limit: 10000, null: false
    t.string "justel", limit: 80, null: false
    t.string "mon", limit: 80, null: false
    t.string "mon_pdf", limit: 80, null: false
    t.string "ov_pdf", limit: 80, null: false
    t.string "reflex", limit: 80, null: false
    t.string "chamber", limit: 80, null: false
    t.integer "language_id", null: false
    t.string "created_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "updated_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.text "tags"
    t.integer "is_abolished", default: 0
    t.integer "is_empty_content", default: 0
    t.integer "is_modification", default: 0
    t.integer "translation_missing", default: 0
    t.text "senate", default: "N/A"
    t.index ["date"], name: "index_legislation_on_date"
    t.index ["language_id", "date"], name: "index_legislation_on_language_id_and_date"
    t.index ["language_id", "law_type_id"], name: "index_legislation_on_language_id_and_law_type_id"
    t.index ["language_id", "title"], name: "index_legislation_on_language_id_and_title"
    t.index ["law_type_id"], name: "index_legislation_on_law_type_id"
    t.index ["numac", "language_id"], name: "unique_index_legislation_on_numac_and_language_id", unique: true
    t.index ["numac"], name: "index_legislation_on_numac"
    t.index ["title"], name: "index_legislation_on_title"
    t.index ["year"], name: "index_legislation_on_year"
  end

  create_table "legislation_title_ngrams", primary_key: ["rowid", "gram"], force: :cascade do |t|
    t.integer "rowid", null: false
    t.text "gram", null: false
    t.index ["gram"], name: "idx_legislation_title_ngrams_gram"
  end

  create_table "types", force: :cascade do |t|
    t.string "law_type", limit: 11, null: false
  end

  create_table "updated_laws", force: :cascade do |t|
    t.integer "language_id", null: false
    t.string "content_numac", limit: 10, null: false
    t.string "update_numac", limit: 10, null: false
    t.string "created_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "updated_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.index ["content_numac", "language_id", "update_numac"], name: "uniq_updated_laws_on_content_lang_update", unique: true
    t.index ["content_numac"], name: "index_updated_law_on_content_numac"
    t.index ["language_id", "content_numac"], name: "index_updated_laws_on_language_id_and_content_numac"
    t.index ["language_id"], name: "index_updated_laws_on_language_id"
  end

  add_foreign_key "articles", "contents", column: "content_numac", primary_key: "legislation_numac"
  add_foreign_key "articles", "languages"
  add_foreign_key "contents", "languages"
  add_foreign_key "contents", "legislation", column: "legislation_numac", primary_key: "numac"
  add_foreign_key "document_number_lookups", "contents"
  add_foreign_key "exdecs", "contents", column: "content_numac", primary_key: "legislation_numac"
  add_foreign_key "exdecs", "languages"
  add_foreign_key "legislation", "languages"
  add_foreign_key "legislation", "types", column: "law_type_id"
  add_foreign_key "updated_laws", "contents", column: "content_numac", primary_key: "legislation_numac"
  add_foreign_key "updated_laws", "languages"

  # Virtual tables defined in this database.
  # Note that virtual tables may not work with other database engines. Be careful if changing database.
