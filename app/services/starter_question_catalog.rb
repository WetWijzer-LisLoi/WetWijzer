# frozen_string_literal: true

require 'json'

# WW-PRIV-01: the starter questions a reader can click, and so the only texts
# the anonymous click counter (SampleQuestionClick) may store. The catalogue
# is public/chatbot_questions.json, which feeds the question pills and the
# question panel, plus the welcome card's three starters per language. Those
# live here (WELCOME) for app/views/chatbot/_messages_area.html.erb and are
# mirrored by chatbot_controller.js for a cleared chat; a test keeps the two
# copies equal. Before this check any same-origin caller could store 500
# characters of free text under a valid category.
module StarterQuestionCatalog
  SOURCE = Rails.root.join('public/chatbot_questions.json')
  LANGUAGES = %w[nl fr de en].freeze
  NONE = Set.new.freeze

  # The welcome card's starters: [category, question] per language.
  WELCOME = {
    'nl' => [
      ['arbeidsrecht', 'Wat zijn mijn rechten bij ontslag?'],
      ['huurrecht', 'Mag mijn verhuurder de huurprijs verhogen?'],
      ['familierecht', 'Hoe verloopt een nalatenschap zonder testament?']
    ],
    'fr' => [
      ['arbeidsrecht', 'Quels sont mes droits en cas de licenciement ?'],
      ['huurrecht', 'Mon bailleur peut-il augmenter le loyer ?'],
      ['familierecht', 'Comment se règle une succession sans testament ?']
    ],
    'de' => [
      ['arbeidsrecht', 'Welche Rechte habe ich bei einer Kündigung?'],
      ['huurrecht', 'Darf mein Vermieter die Miete erhöhen?'],
      ['familierecht', 'Wie wird ein Nachlass ohne Testament geregelt?']
    ],
    'en' => [
      ['arbeidsrecht', 'What are my rights if I am dismissed?'],
      ['huurrecht', 'Can my landlord increase the rent?'],
      ['familierecht', 'How is an estate settled without a will?']
    ]
  }.freeze

  class << self
    def canonical?(language, text)
      catalogue.fetch(language.to_s, NONE).include?(text.to_s.strip)
    end

    private

    def catalogue
      @catalogue ||= build_catalogue
    end

    def build_catalogue
      entries = JSON.parse(SOURCE.read)
      LANGUAGES.to_h do |language|
        texts = entries.filter_map { |entry| entry[language].to_s.strip.presence }
        texts.concat(WELCOME.fetch(language).map(&:last))
        [language, texts.to_set.freeze]
      end.freeze
    end
  end
end
